import Foundation
import AppKit

/// JSON load / debounced save / starter seed / launch grid refresh for `AppState`.
@MainActor
final class StatePersister {
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?
    /// Invoked on the main actor when an atomic `state.json` write fails.
    var onSaveFailure: ((Error) -> Void)?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(AppIdentity.applicationSupportFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("state.json")
    }

    /// Load, hydrate icons, seed if needed, fix selection, refresh grid positions.
    /// Persists when seed / position refresh require a write.
    func bootstrap() -> AppState {
        var (state, needsStarterSeed) = loadRaw()

        Self.hydrateIcons(&state)
        let clearedOpenWith = Self.clearAppOpenWithFields(&state)

        if needsStarterSeed || state.collections.isEmpty {
            state = Self.makeStarterState()
            _ = persistImmediately(state)
        }

        Self.normalizeSelectedCollectionID(&state)

        let migratedGrid = Self.migrateCollidingGridFromPositions(&state)
        if let refreshed = Self.refreshedPositionsOnLaunch(state) {
            state = refreshed
            _ = persistImmediately(state)
        } else if migratedGrid || clearedOpenWith {
            _ = persistImmediately(state)
        }

        return state
    }

    /// Debounce ~200ms. `stateProvider` is read at fire time so the write matches current memory
    /// (cancelled debounce must not write). Returning `nil` skips the write (e.g. store torn down).
    func scheduleSave(stateProvider: @escaping () -> AppState?) {
        saveTask?.cancel()
        saveTask = Task {
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let state = stateProvider() else { return }
            _ = persistImmediately(state)
        }
    }

    /// Cancel any pending debounce and write `state.json` now (e.g. on quit).
    func flush(_ state: AppState) {
        saveTask?.cancel()
        saveTask = nil
        _ = persistImmediately(state)
    }

    @discardableResult
    func persistImmediately(_ state: AppState) -> Bool {
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: [.atomic])
            return true
        } catch {
            NSLog("\(AppIdentity.displayName) save failed: \(error)")
            onSaveFailure?(error)
            return false
        }
    }

    // MARK: - Load

    private func loadRaw() -> (AppState, needsStarterSeed: Bool) {
        guard let data = try? Data(contentsOf: fileURL) else {
            return (.empty, true)
        }
        if let decoded = try? JSONDecoder().decode(AppState.self, from: data) {
            return (decoded, false)
        }
        // Preserve unreadable bytes before seeding so a bad decode does not destroy the layout.
        Self.rotateStateBackups(writing: data, beside: fileURL)
        NSLog("\(AppIdentity.displayName): could not decode state.json; rotated state.json.bak*")
        return (.empty, true)
    }

    /// Load URL-item favicons from sidecar files into session memory.
    private static func hydrateIcons(_ state: inout AppState) {
        for ci in state.collections.indices {
            for ii in state.collections[ci].items.indices {
                let item = state.collections[ci].items[ii]
                guard item.kind == .url,
                      let png = ItemIconStore.load(itemID: item.id) else { continue }
                state.collections[ci].items[ii].iconPNGData = png
            }
        }
    }

    private static func normalizeSelectedCollectionID(_ state: inout AppState) {
        let sorted = state.collections.sorted { $0.sortIndex < $1.sortIndex }
        if let id = state.settings.selectedCollectionID,
           !state.collections.contains(where: { $0.id == id }) {
            state.settings.selectedCollectionID = sorted.first?.id
        } else if state.settings.selectedCollectionID == nil {
            state.settings.selectedCollectionID = sorted.first?.id
        }
    }

    /// Strip Open With fields from app items (legacy JSON / bad edits). Apps never use Open With.
    /// - Returns: `true` when any field was cleared.
    private static func clearAppOpenWithFields(_ state: inout AppState) -> Bool {
        var changed = false
        for ci in state.collections.indices {
            for ii in state.collections[ci].items.indices {
                guard state.collections[ci].items[ii].kind == .app else { continue }
                let item = state.collections[ci].items[ii]
                guard item.openWithBundleIdentifier != nil || item.openWithBookmarkData != nil else { continue }
                state.collections[ci].items[ii].openWithBundleIdentifier = nil
                state.collections[ci].items[ii].openWithBookmarkData = nil
                changed = true
            }
        }
        return changed
    }

    /// Pre-grid / hand-edited JSON can decode every item to `(0,0)` while `position` still
    /// differs. Detect shared grid cells and rebuild `gridColumn`/`gridRow` from absolute Y/X
    /// using uniform full-row pitch (legacy layouts had no half-height empty rows).
    /// - Returns: `true` when any collection was migrated.
    private static func migrateCollidingGridFromPositions(_ state: inout AppState) -> Bool {
        var changed = false
        for ci in state.collections.indices {
            var items = state.collections[ci].items
            guard items.count > 1 else { continue }
            let cells = items.map { SnapToGrid.cell(of: $0) }
            guard Set(cells).count < cells.count else { continue }

            let size = SnapToGrid.legacyCellSize(settings: state.settings)
            guard size.width > 0, size.height > 0 else { continue }
            for i in items.indices {
                let point = items[i].position.cgPoint
                items[i].gridColumn = max(0, Int(round((point.x - SnapToGrid.origin.x) / size.width)))
                items[i].gridRow = max(0, Int(round((point.y - SnapToGrid.origin.y) / size.height)))
            }
            state.collections[ci].items = items
            changed = true
        }
        return changed
    }

    /// Apply half-height empty rows from stored `gridRow`/`gridColumn`, collapsing
    /// consecutive empty rows to a single spacer. Never re-infer grid from absolute Y on
    /// launch — compressed positions map to the wrong uniform row and erase intentional
    /// single empty-row gaps across restarts.
    /// - Returns: updated state when anything changed; `nil` if unchanged.
    private static func refreshedPositionsOnLaunch(_ state: AppState) -> AppState? {
        var copy = state
        var changed = false
        for ci in copy.collections.indices {
            var items = copy.collections[ci].items
            guard !items.isEmpty else { continue }

            let beforePositions = items.map(\.position)
            let beforeRows = items.map(\.gridRow)
            SnapToGrid.applyCompressedPositions(items: &items, settings: copy.settings)
            if items.map(\.position) != beforePositions || items.map(\.gridRow) != beforeRows {
                changed = true
            }
            copy.collections[ci].items = items
        }
        return changed ? copy : nil
    }

    /// Keep up to 3 undecodable backups: `state.json.bak`, `.bak.1`, `.bak.2` (newest → oldest).
    private static func rotateStateBackups(writing data: Data, beside fileURL: URL) {
        let dir = fileURL.deletingLastPathComponent()
        let bak = dir.appendingPathComponent("state.json.bak")
        let bak1 = dir.appendingPathComponent("state.json.bak.1")
        let bak2 = dir.appendingPathComponent("state.json.bak.2")
        let fm = FileManager.default
        try? fm.removeItem(at: bak2)
        if fm.fileExists(atPath: bak1.path) {
            try? fm.moveItem(at: bak1, to: bak2)
        }
        if fm.fileExists(atPath: bak.path) {
            try? fm.moveItem(at: bak, to: bak1)
        }
        try? data.write(to: bak, options: [.atomic])
    }

    static func makeStarterState() -> AppState {
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
            guard var item = LauncherItemFactory.makeItem(from: url, at: point) else { continue }
            item.gridColumn = column
            item.gridRow = 0
            items.append(item)
        }
        let apps = AppState.Collection(name: "Apps", sortIndex: 0, items: items)
        prefs.selectedCollectionID = apps.id
        return AppState(collections: [apps], settings: prefs)
    }
}
