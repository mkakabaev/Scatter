import Foundation
import Combine
import AppKit
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var state: AppState
    @Published var searchQuery: String = ""
    @Published var selectedItemID: UUID?
    @Published var isMainWindowVisible: Bool = false
    /// Incremented each time Settings should be shown (edge-trigger-safe reopen).
    @Published private(set) var settingsRequestID: Int = 0
    /// Item whose background palette is open. Transient; not persisted.
    @Published var backgroundPickerItemID: UUID?
    /// True while the system eyedropper (`NSColorSampler`) is on screen.
    @Published private(set) var isSamplingItemBackground = false
    /// Transient launch failure shown as an alert on the main window. Not persisted.
    @Published var openFailure: OpenFailure?
    /// True while an external app launch is in flight. Suppresses main-panel raise on `applicationDidBecomeActive`.
    @Published private(set) var isLaunchingExternalApp = false
    private var colorSampler: NSColorSampler?

    struct OpenFailure: Equatable {
        var itemName: String
        var message: String
        /// Terminal command the user can run to clear blocking xattrs. Not executed by this app.
        var recoveryCommand: String? = nil
    }

    func requestSettings() {
        backgroundPickerItemID = nil
        settingsRequestID &+= 1
    }

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    var sortedCollections: [AppState.Collection] {
        state.collections.sorted { $0.sortIndex < $1.sortIndex }
    }

    var selectedCollection: AppState.Collection? {
        guard let id = state.settings.selectedCollectionID else {
            return sortedCollections.first
        }
        return state.collections.first { $0.id == id } ?? sortedCollections.first
    }

    /// Items on the active collection canvas (never filtered by search — search uses overlay).
    var visibleItems: [LauncherItem] {
        selectedCollection?.items ?? []
    }

    var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Saved-items search across **all** collections (no Spotlight).
    var searchResults: [SearchHit] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        var hits: [SearchHit] = []
        for collection in sortedCollections {
            for item in collection.items where item.displayName.lowercased().contains(q) {
                hits.append(SearchHit(item: item, collectionName: collection.name))
            }
        }
        return hits.sorted {
            $0.item.displayName.localizedCaseInsensitiveCompare($1.item.displayName) == .orderedAscending
        }
    }

    func clearSearch() {
        searchQuery = ""
        selectedItemID = nil
    }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(AppIdentity.applicationSupportFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("state.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(AppState.self, from: data) {
            state = decoded
        } else {
            state = .empty
        }

        let totalItems = state.collections.reduce(0) { $0 + $1.items.count }
        if totalItems == 0 {
            state = AppStore.makeStarterState()
            persistImmediately()
        }

        if state.settings.selectedCollectionID == nil {
            state.settings.selectedCollectionID = sortedCollections.first?.id
        }

        // Recompute absolute positions from stored grid coords (preserves empty rows).
        refreshCompressedPositionsOnLaunch()
    }

    /// Apply half-height empty rows from stored `gridRow`/`gridColumn`, collapsing
    /// consecutive empty rows to a single spacer. Never re-infer grid from absolute Y on
    /// launch — compressed positions map to the wrong uniform row and erase intentional
    /// single empty-row gaps across restarts.
    private func refreshCompressedPositionsOnLaunch() {
        var copy = state
        var changed = false
        for ci in copy.collections.indices {
            var items = copy.collections[ci].items
            guard !items.isEmpty else { continue }

            // Legacy-only: every item still at grid (0,0) but drawn elsewhere → bootstrap once.
            let allZeroGrid = items.allSatisfy { $0.gridColumn == 0 && $0.gridRow == 0 }
            let needsBootstrap = allZeroGrid && items.contains {
                hypot($0.position.x - SnapToGrid.origin.x, $0.position.y - SnapToGrid.origin.y) > 8
            }
            if needsBootstrap {
                for i in items.indices {
                    let inferred = SnapToGrid.cell(for: items[i].position.cgPoint, settings: copy.settings)
                    items[i].gridColumn = inferred.column
                    items[i].gridRow = inferred.row
                }
                changed = true
            }

            let beforePositions = items.map(\.position)
            let beforeRows = items.map(\.gridRow)
            SnapToGrid.applyCompressedPositions(items: &items, settings: copy.settings)
            if items.map(\.position) != beforePositions || items.map(\.gridRow) != beforeRows {
                changed = true
            }
            copy.collections[ci].items = items
        }
        if changed {
            state = copy
            persistImmediately()
        }
    }

    func showMainWindow() {
        isMainWindowVisible = true
        searchQuery = ""
    }

    func hideMainWindow() {
        isMainWindowVisible = false
        searchQuery = ""
        selectedItemID = nil
        backgroundPickerItemID = nil
        openFailure = nil
    }

    /// Keep / bring up the main window and show a launch-error alert.
    func reportOpenFailure(itemName: String, message: String, recoveryCommand: String? = nil) {
        isLaunchingExternalApp = false
        openFailure = OpenFailure(itemName: itemName, message: message, recoveryCommand: recoveryCommand)
        showMainWindow()
    }

    func clearOpenFailure() {
        openFailure = nil
    }

    func beginExternalLaunch() {
        isLaunchingExternalApp = true
    }

    func endExternalLaunch() {
        isLaunchingExternalApp = false
    }

    func selectCollection(_ id: UUID) {
        mutate { $0.settings.selectedCollectionID = id }
        selectedItemID = nil
        searchQuery = ""
        backgroundPickerItemID = nil
    }

    func selectCollection(index: Int) {
        let cols = sortedCollections
        guard cols.indices.contains(index) else { return }
        selectCollection(cols[index].id)
    }

    func selectAdjacentCollection(delta: Int) {
        let cols = sortedCollections
        guard let current = selectedCollection,
              let idx = cols.firstIndex(where: { $0.id == current.id }) else { return }
        let next = max(0, min(cols.count - 1, idx + delta))
        selectCollection(cols[next].id)
    }

    func addCollection(named name: String) {
        let nextIndex = (state.collections.map(\.sortIndex).max() ?? -1) + 1
        let collection = AppState.Collection(name: name, sortIndex: nextIndex)
        mutate {
            $0.collections.append(collection)
            $0.settings.selectedCollectionID = collection.id
        }
    }

    func renameCollection(_ id: UUID, to name: String) {
        mutate {
            guard let i = $0.collections.firstIndex(where: { $0.id == id }) else { return }
            $0.collections[i].name = name
        }
    }

    func deleteCollection(_ id: UUID) {
        mutate {
            $0.collections.removeAll { $0.id == id }
            if $0.settings.selectedCollectionID == id {
                $0.settings.selectedCollectionID = $0.collections.sorted { $0.sortIndex < $1.sortIndex }.first?.id
            }
            for i in $0.collections.indices {
                $0.collections[i].sortIndex = i
            }
        }
    }

    /// `index` is the slot among the other collections (`0` is the top). `sortIndex` is rewritten to match.
    func moveCollection(_ id: UUID, toInsertionIndex index: Int) {
        var cols = sortedCollections
        guard let from = cols.firstIndex(where: { $0.id == id }) else { return }
        let item = cols.remove(at: from)
        let destination = min(max(0, index), cols.count)
        guard destination != from else { return }
        cols.insert(item, at: destination)
        mutate {
            for i in cols.indices {
                cols[i].sortIndex = i
            }
            $0.collections = cols
        }
    }

    func addItem(_ item: LauncherItem, to collectionID: UUID? = nil) {
        let targetID = collectionID ?? selectedCollection?.id
        guard let targetID else { return }
        mutate {
            guard let i = $0.collections.firstIndex(where: { $0.id == targetID }) else { return }
            $0.collections[i].items.append(item)
        }
    }

    func updateItemPosition(_ itemID: UUID, to point: CGPoint) {
        mutate {
            for ci in $0.collections.indices {
                if let ii = $0.collections[ci].items.firstIndex(where: { $0.id == itemID }) {
                    $0.collections[ci].items[ii].position = .init(point)
                    return
                }
            }
        }
    }

    /// End of a drag: take the drop cell; displace others only as needed (gap-preserving row shift).
    func finalizeItemPlacement(_ itemID: UUID, at point: CGPoint, canvasSize: CGSize) {
        withAnimation(Self.layoutAnimation) {
            mutate {
                for ci in $0.collections.indices {
                    guard $0.collections[ci].items.contains(where: { $0.id == itemID }) else { continue }
                    $0.collections[ci].items = SnapToGrid.placeReplacing(
                        itemID: itemID,
                        proposed: point,
                        items: $0.collections[ci].items,
                        settings: $0.settings,
                        canvasSize: canvasSize
                    )
                    return
                }
            }
        }
    }

    /// Add a web link, then replace the generic icon once its favicon arrives.
    func addWebLink(_ item: LauncherItem) {
        addItemFromFinder(item, openWithCursor: false)
        guard item.kind == .url, let pageURL = item.resolvedURL() else { return }
        let itemID = item.id
        Task {
            guard let png = await FaviconFetcher.fetchPNG(for: pageURL) else { return }
            setItemIcon(itemID, pngData: png)
        }
    }

    func setItemIcon(_ itemID: UUID, pngData: Data) {
        mutate {
            for ci in $0.collections.indices {
                guard let ii = $0.collections[ci].items.firstIndex(where: { $0.id == itemID }) else { continue }
                $0.collections[ci].items[ii].iconPNGData = pngData
                return
            }
        }
    }

    func addItemFromFinder(_ item: LauncherItem, openWithCursor: Bool) {
        var prepared = item
        if openWithCursor, let url = CursorLocator.applicationURL {
            prepared.openWithBundleIdentifier = Bundle(url: url)?.bundleIdentifier ?? CursorLocator.bundleIdentifier
            prepared.openWithBookmarkData = ItemOpener.bookmark(forApplicationAt: url)
        }
        // Place with collision-aware insert into current collection.
        let sidebar = SidebarLayout.clamped(
            state.settings.sidebarWidth,
            containerWidth: state.settings.windowWidth
        )
        let canvas = CGSize(
            width: max(
                SidebarLayout.minimumCanvasWidth,
                state.settings.windowWidth - sidebar - SidebarLayout.splitterThickness
            ),
            height: state.settings.windowHeight
        )
        if let collection = selectedCollection {
            let proposed = prepared.position.cgPoint
            var items = collection.items
            items.append(prepared)
            items = SnapToGrid.placeReplacing(
                itemID: prepared.id,
                proposed: proposed,
                items: items,
                settings: state.settings,
                canvasSize: canvas
            )
            withAnimation(Self.layoutAnimation) {
                mutate {
                    guard let ci = $0.collections.firstIndex(where: { $0.id == collection.id }) else { return }
                    $0.collections[ci].items = items
                }
            }
        } else {
            addItem(prepared)
        }
    }

    func renameItem(_ itemID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate {
            for ci in $0.collections.indices {
                if let ii = $0.collections[ci].items.firstIndex(where: { $0.id == itemID }) {
                    $0.collections[ci].items[ii].displayName = trimmed
                    return
                }
            }
        }
    }

    func removeItem(_ itemID: UUID) {
        withAnimation(Self.layoutAnimation) {
            mutate {
                for ci in $0.collections.indices {
                    guard $0.collections[ci].items.contains(where: { $0.id == itemID }) else { continue }
                    $0.collections[ci].items.removeAll { $0.id == itemID }
                    SnapToGrid.applyCompressedPositions(
                        items: &$0.collections[ci].items,
                        settings: $0.settings
                    )
                }
            }
        }
        if selectedItemID == itemID { selectedItemID = nil }
    }

    func moveItem(_ itemID: UUID, toCollection collectionID: UUID) {
        guard var item = findItem(itemID) else { return }
        withAnimation(Self.layoutAnimation) {
            mutate {
                for ci in $0.collections.indices {
                    let had = $0.collections[ci].items.contains(where: { $0.id == itemID })
                    $0.collections[ci].items.removeAll { $0.id == itemID }
                    if had {
                        SnapToGrid.applyCompressedPositions(
                            items: &$0.collections[ci].items,
                            settings: $0.settings
                        )
                    }
                }
                guard let dest = $0.collections.firstIndex(where: { $0.id == collectionID }) else { return }
                let prefs = $0.settings
                let free = SnapToGrid.nearestFreeCell(
                    from: .init(column: 0, row: 0),
                    occupied: Set($0.collections[dest].items.map {
                        SnapToGrid.cell(of: $0, settings: prefs)
                    }),
                    bounds: SnapToGrid.gridBounds(canvasSize: nil, settings: prefs)
                )
                item.gridColumn = free.column
                item.gridRow = free.row
                $0.collections[dest].items.append(item)
                SnapToGrid.applyCompressedPositions(
                    items: &$0.collections[dest].items,
                    settings: $0.settings
                )
                $0.settings.selectedCollectionID = collectionID
            }
        }
    }

    func setItemBackground(_ itemID: UUID, hex: String?) {
        let stored: String?
        if let hex {
            guard let canonical = ItemBackgroundPalette.storedHex(hex) else { return }
            stored = canonical
        } else {
            stored = nil
        }
        mutate {
            for ci in $0.collections.indices {
                if let ii = $0.collections[ci].items.firstIndex(where: { $0.id == itemID }) {
                    $0.collections[ci].items[ii].backgroundColorHex = stored
                    return
                }
            }
        }
    }

    /// System loupe. No Screen Recording permission. Escape cancels and leaves the palette open.
    func sampleItemBackground(for itemID: UUID) {
        guard !isSamplingItemBackground else { return }
        let sampler = NSColorSampler()
        colorSampler = sampler
        isSamplingItemBackground = true
        sampler.show { [weak self] color in
            Task { @MainActor in
                guard let self else { return }
                self.colorSampler = nil
                self.isSamplingItemBackground = false
                guard let color else { return }
                self.setItemBackground(itemID, hex: color.hexString)
                self.backgroundPickerItemID = nil
            }
        }
    }

    func setApplyTimeZone(for itemID: UUID, enabled: Bool) {
        mutate {
            for ci in $0.collections.indices {
                if let ii = $0.collections[ci].items.firstIndex(where: { $0.id == itemID }) {
                    $0.collections[ci].items[ii].applyTimeZone = enabled
                    return
                }
            }
        }
    }

    func setOpenWith(for itemID: UUID, bundleID: String?, bookmark: Data?) {
        mutate {
            for ci in $0.collections.indices {
                if let ii = $0.collections[ci].items.firstIndex(where: { $0.id == itemID }) {
                    $0.collections[ci].items[ii].openWithBundleIdentifier = bundleID
                    $0.collections[ci].items[ii].openWithBookmarkData = bookmark
                    return
                }
            }
        }
    }

    static let layoutAnimation: Animation = .spring(response: 0.32, dampingFraction: 0.86)

    func updateSettings(_ update: (inout AppState.Settings) -> Void) {
        mutate {
            let before = $0.settings
            update(&$0.settings)
            // Appearance dimensions are whole points (prefs sliders step by 1).
            $0.settings.iconSize = $0.settings.iconSize.rounded()
            $0.settings.labelSize = $0.settings.labelSize.rounded()
            $0.settings.gridSpacingHorizontal = $0.settings.gridSpacingHorizontal.rounded()
            $0.settings.gridSpacingVertical = $0.settings.gridSpacingVertical.rounded()
            // Icon / spacing changes require recomputing absolute positions from grid coords.
            if before.iconSize != $0.settings.iconSize
                || before.labelSize != $0.settings.labelSize
                || before.gridSpacingHorizontal != $0.settings.gridSpacingHorizontal
                || before.gridSpacingVertical != $0.settings.gridSpacingVertical {
                for ci in $0.collections.indices {
                    SnapToGrid.applyCompressedPositions(
                        items: &$0.collections[ci].items,
                        settings: $0.settings
                    )
                }
            }
        }
    }

    func findItem(_ id: UUID) -> LauncherItem? {
        for collection in state.collections {
            if let item = collection.items.first(where: { $0.id == id }) {
                return item
            }
        }
        return nil
    }

    func appendTypedCharacter(_ character: Character) {
        if character == "\u{8}" {
            if !searchQuery.isEmpty {
                searchQuery.removeLast()
                syncSearchSelection()
            }
            return
        }
        guard !character.isNewline else { return }
        searchQuery.append(character)
        syncSearchSelection()
    }

    func setSearchQuery(_ query: String) {
        searchQuery = query
        syncSearchSelection()
    }

    func syncSearchSelection() {
        let hits = searchResults
        if let current = selectedItemID, hits.contains(where: { $0.item.id == current }) {
            return
        }
        selectedItemID = hits.first?.item.id
    }

    func selectAdjacentSearchResult(delta: Int) {
        let hits = searchResults
        guard !hits.isEmpty else { return }
        guard let current = selectedItemID,
              let idx = hits.firstIndex(where: { $0.item.id == current }) else {
            selectedItemID = hits.first?.item.id
            return
        }
        let next = max(0, min(hits.count - 1, idx + delta))
        selectedItemID = hits[next].item.id
    }

    private func mutate(_ body: (inout AppState) -> Void) {
        var copy = state
        body(&copy)
        state = copy
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            persistImmediately()
        }
    }

    private func persistImmediately() {
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("\(AppIdentity.displayName) save failed: \(error)")
        }
    }

    private static func makeStarterState() -> AppState {
        var prefs = AppState.Settings.default
        let occupiedRows: Set<Int> = [0]
        var items: [LauncherItem] = []
        let starterURLs = [
            URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
            URL(fileURLWithPath: "/Applications/Safari.app"),
        ]
        for (column, url) in starterURLs.enumerated() {
            let point = SnapToGrid.positionForGrid(
                row: 0,
                column: column,
                occupiedRows: occupiedRows,
                settings: prefs
            )
            guard var item = ItemOpener.makeItem(from: url, at: point) else { continue }
            item.gridColumn = column
            item.gridRow = 0
            items.append(item)
        }
        let apps = AppState.Collection(name: "Apps", sortIndex: 0, items: items)
        prefs.selectedCollectionID = apps.id
        return AppState(collections: [apps], settings: prefs)
    }
}
