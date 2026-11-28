import Foundation
import SwiftUI

extension AppStore {
    /// Persist refreshed `.minimalBookmark` bytes after a stale resolve (item target and/or Open With).
    func refreshStaleBookmarks(for itemID: UUID, itemBookmark: Data?, openWithBookmark: Data?) {
        guard itemBookmark != nil || openWithBookmark != nil else { return }
        mutate {
            for ci in $0.collections.indices {
                guard let ii = $0.collections[ci].items.firstIndex(where: { $0.id == itemID }) else { continue }
                if let itemBookmark {
                    $0.collections[ci].items[ii].bookmarkData = itemBookmark
                    if let url = MinimalBookmark.resolve(itemBookmark)?.url {
                        $0.collections[ci].items[ii].urlString = url.absoluteString
                    }
                }
                if let openWithBookmark {
                    $0.collections[ci].items[ii].openWithBookmarkData = openWithBookmark
                }
                return
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

    /// Add a web link, then fill favicon / page title once the HTML fetch completes.
    func addWebLink(_ item: LauncherItem) {
        addItemFromFinder(item, openWithCursor: false)
        guard item.kind == .url, let pageURL = ItemURLResolver.resolve(item) else { return }
        webLinkEnricher.enrich(
            item: item,
            pageURL: pageURL,
            itemExists: { [weak self] id in self?.findItem(id) != nil },
            setIcon: { [weak self] id, png in self?.setItemIcon(id, pngData: png) },
            setDisplayName: { [weak self] id, name, expected in
                self?.setItemDisplayName(id, to: name, onlyIfCurrentEquals: expected)
            }
        )
    }

    func setItemIcon(_ itemID: UUID, pngData: Data) {
        // Memory icon must match the sidecar — skip session update when disk write fails.
        guard ItemIconStore.save(itemID: itemID, pngData: pngData) else { return }
        mutate {
            for ci in $0.collections.indices {
                guard let ii = $0.collections[ci].items.firstIndex(where: { $0.id == itemID }) else { continue }
                $0.collections[ci].items[ii].iconPNGData = pngData
                return
            }
        }
    }

    /// Async favicon/title path: only rename if the user has not already changed the label.
    func setItemDisplayName(_ itemID: UUID, to name: String, onlyIfCurrentEquals expected: String) {
        mutate {
            for ci in $0.collections.indices {
                guard let ii = $0.collections[ci].items.firstIndex(where: { $0.id == itemID }) else { continue }
                guard $0.collections[ci].items[ii].displayName == expected else { return }
                $0.collections[ci].items[ii].displayName = name
                return
            }
        }
    }

    func addItemFromFinder(_ item: LauncherItem, openWithCursor: Bool) {
        var prepared = item
        if openWithCursor {
            guard let url = CursorLocator.applicationURL else { return }
            prepared.openWithBundleIdentifier = Bundle(url: url)?.bundleIdentifier ?? CursorLocator.bundleIdentifier
            prepared.openWithBookmarkData = MinimalBookmark.data(for: url)
        }
        // Place with collision-aware insert into current collection.
        let canvas = canvasSizeFromWindowSettings()
        guard let collection = selectedCollection else { return }
        let proposed = prepared.position.cgPoint
        // Provisional grid from the drop point so empty-row geometry matches the visual target
        // before `placeReplacing` commits (defaults of 0,0 skew half-height strips).
        let provisional = SnapToGrid.hitTestCell(
            at: proposed,
            items: collection.items,
            settings: state.settings,
            canvasSize: canvas
        )
        prepared.gridColumn = provisional.column
        prepared.gridRow = provisional.row
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
        removeItems([itemID])
    }

    func removeItems(_ itemIDs: Set<UUID>) {
        guard !itemIDs.isEmpty else { return }
        webLinkEnricher.cancel(itemIDs: itemIDs)
        ItemIconStore.remove(itemIDs: itemIDs)
        withAnimation(Self.layoutAnimation) {
            mutate {
                for ci in $0.collections.indices {
                    let before = $0.collections[ci].items.count
                    $0.collections[ci].items.removeAll { itemIDs.contains($0.id) }
                    guard $0.collections[ci].items.count != before else { continue }
                    SnapToGrid.applyCompressedPositions(
                        items: &$0.collections[ci].items,
                        settings: $0.settings
                    )
                }
            }
        }
        if let id = selectedItemID, itemIDs.contains(id) {
            selectedItemID = nil
        }
        selectedItemIDs.subtract(itemIDs)
        if isSelectingItems, selectedItemIDs.isEmpty {
            exitItemSelection()
        }
    }

    /// Insert an empty grid row before `itemID`, shifting that item and everything below down.
    func insertEmptyRow(beforeItem itemID: UUID) {
        withAnimation(Self.layoutAnimation) {
            mutate {
                for ci in $0.collections.indices {
                    guard let item = $0.collections[ci].items.first(where: { $0.id == itemID }) else {
                        continue
                    }
                    SnapToGrid.insertEmptyRow(
                        before: item.gridRow,
                        items: &$0.collections[ci].items,
                        settings: $0.settings
                    )
                    return
                }
            }
        }
    }

    /// Insert an empty grid column before `itemID`, shifting that item and everything to its right.
    func insertEmptyColumn(beforeItem itemID: UUID) {
        withAnimation(Self.layoutAnimation) {
            mutate {
                for ci in $0.collections.indices {
                    guard let item = $0.collections[ci].items.first(where: { $0.id == itemID }) else {
                        continue
                    }
                    SnapToGrid.insertEmptyColumn(
                        before: item.gridColumn,
                        items: &$0.collections[ci].items,
                        settings: $0.settings
                    )
                    return
                }
            }
        }
    }

    /// Delete a fully empty grid row in the selected collection (items below shift up).
    func deleteEmptyRow(_ row: Int) {
        guard let collectionID = selectedCollection?.id else { return }
        withAnimation(Self.layoutAnimation) {
            mutate {
                guard let ci = $0.collections.firstIndex(where: { $0.id == collectionID }) else { return }
                SnapToGrid.deleteEmptyRow(
                    row,
                    items: &$0.collections[ci].items,
                    settings: $0.settings
                )
            }
        }
    }

    /// Delete a fully empty grid column in the selected collection (items to the right shift left).
    func deleteEmptyColumn(_ column: Int) {
        guard let collectionID = selectedCollection?.id else { return }
        withAnimation(Self.layoutAnimation) {
            mutate {
                guard let ci = $0.collections.firstIndex(where: { $0.id == collectionID }) else { return }
                SnapToGrid.deleteEmptyColumn(
                    column,
                    items: &$0.collections[ci].items,
                    settings: $0.settings
                )
            }
        }
    }

    func moveItem(_ itemID: UUID, toCollection collectionID: UUID) {
        moveItems([itemID], toCollection: collectionID)
    }

    func moveItems(_ itemIDs: Set<UUID>, toCollection collectionID: UUID) {
        guard !itemIDs.isEmpty else { return }
        guard state.collections.contains(where: { $0.id == collectionID }) else { return }
        var moving: [LauncherItem] = []
        for id in itemIDs {
            if let item = findItem(id) { moving.append(item) }
        }
        guard !moving.isEmpty else { return }
        moving.sort {
            if $0.gridRow != $1.gridRow { return $0.gridRow < $1.gridRow }
            return $0.gridColumn < $1.gridColumn
        }
        withAnimation(Self.layoutAnimation) {
            mutate {
                guard let dest = $0.collections.firstIndex(where: { $0.id == collectionID }) else { return }
                for ci in $0.collections.indices {
                    let before = $0.collections[ci].items.count
                    $0.collections[ci].items.removeAll { itemIDs.contains($0.id) }
                    guard $0.collections[ci].items.count != before else { continue }
                    SnapToGrid.applyCompressedPositions(
                        items: &$0.collections[ci].items,
                        settings: $0.settings
                    )
                }
                let prefs = $0.settings
                var occupied = Set($0.collections[dest].items.map { SnapToGrid.cell(of: $0) })
                let canvas = canvasSizeFromWindowSettings()
                let bounds = SnapToGrid.gridBounds(canvasSize: canvas, settings: prefs)
                for var item in moving {
                    let free = SnapToGrid.nearestFreeCell(
                        from: .init(column: 0, row: 0),
                        occupied: occupied,
                        bounds: bounds
                    )
                    item.gridColumn = free.column
                    item.gridRow = free.row
                    occupied.insert(free)
                    $0.collections[dest].items.append(item)
                }
                SnapToGrid.applyCompressedPositions(
                    items: &$0.collections[dest].items,
                    settings: $0.settings
                )
                $0.settings.selectedCollectionID = collectionID
            }
        }
        if let id = selectedItemID, itemIDs.contains(id) {
            selectedItemID = nil
        }
        // Destination collection switch ends multi-select (same as `selectCollection`).
        exitItemSelection()
    }

    func setItemBackground(_ itemID: UUID, color: ColorHex?) {
        mutate {
            for ci in $0.collections.indices {
                if let ii = $0.collections[ci].items.firstIndex(where: { $0.id == itemID }) {
                    $0.collections[ci].items[ii].backgroundColor = color
                    return
                }
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
                    // App items never store Open With (launch always opens the app itself).
                    if !$0.collections[ci].items[ii].supportsOpenWith,
                       bundleID != nil || bookmark != nil {
                        return
                    }
                    $0.collections[ci].items[ii].openWithBundleIdentifier = bundleID
                    $0.collections[ci].items[ii].openWithBookmarkData = bookmark
                    return
                }
            }
        }
    }
}
