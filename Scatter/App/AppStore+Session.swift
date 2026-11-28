import Foundation
import AppKit

extension AppStore {
    func requestSettings() {
        backgroundPickerItemID = nil
        clearContextMenuHighlight()
        clearItemDragHover()
        clearSearch()
        exitItemSelection()
        settingsRequestID &+= 1
    }

    func updateSidebarRowFrames(_ frames: [UUID: CGRect]) {
        sidebarRowFramesGlobal = frames
    }

    /// Sidebar collection under `point` in global coordinates, if any.
    func collectionID(atGlobalPoint point: CGPoint) -> UUID? {
        var hit: UUID?
        for collection in sortedCollections {
            if let frame = sidebarRowFramesGlobal[collection.id], frame.contains(point) {
                hit = collection.id
            }
        }
        return hit
    }

    func setItemDragHoverCollection(_ id: UUID?) {
        if itemDragHoverCollectionID != id {
            itemDragHoverCollectionID = id
        }
    }

    func clearItemDragHover() {
        itemDragHoverCollectionID = nil
    }

    /// Highlight the item under an opening context menu (normal mode only).
    func beginContextMenuHighlight(itemID: UUID) {
        guard !isSelectingItems else { return }
        contextMenuItemID = itemID
    }

    func clearContextMenuHighlight() {
        contextMenuItemID = nil
    }

    /// Empty-canvas context menu: drop menu highlight and normal selection.
    func clearSelectionForEmptyContextMenu() {
        guard !isSelectingItems else { return }
        contextMenuItemID = nil
        selectedItemID = nil
    }

    func requestPaste() {
        backgroundPickerItemID = nil
        pasteRequestID &+= 1
    }

    /// Enter multi-select mode. `seed` is the initial set (item **Select…** seeds that tile).
    func enterItemSelection(seeding seed: Set<UUID> = []) {
        backgroundPickerItemID = nil
        clearContextMenuHighlight()
        clearItemDragHover()
        clearSearch()
        isSelectingItems = true
        selectedItemIDs = seed.filter { findItem($0) != nil }
    }

    func exitItemSelection() {
        isSelectingItems = false
        selectedItemIDs = []
    }

    func toggleItemSelection(_ itemID: UUID) {
        guard isSelectingItems else { return }
        if selectedItemIDs.contains(itemID) {
            selectedItemIDs.remove(itemID)
            if selectedItemIDs.isEmpty {
                exitItemSelection()
            }
        } else {
            selectedItemIDs.insert(itemID)
        }
    }

    /// Drop IDs that are no longer on the open collection canvas.
    func pruneItemSelection(toVisibleIDs ids: Set<UUID>) {
        guard isSelectingItems else { return }
        selectedItemIDs = selectedItemIDs.intersection(ids)
        if selectedItemIDs.isEmpty {
            exitItemSelection()
        }
    }

    func showMainWindow() {
        isMainWindowVisible = true
        clearSearch()
    }

    func hideMainWindow() {
        isMainWindowVisible = false
        clearSearch()
        webLinkEnricher.cancelAll()
        selectedItemID = nil
        clearContextMenuHighlight()
        clearItemDragHover()
        exitItemSelection()
        backgroundPickerItemID = nil
        openFailure = nil
        ingestFailureMessage = nil
        saveFailureMessage = nil
        isPresentingItemOpenChoice = false
        isPresentingItemRename = false
        isPresentingCollectionAlert = false
    }

    /// Single Escape / cancel hierarchy for KeyMonitor and `LauncherWindow`.
    /// Eyedropper sampling is a no-op here so the system loupe can own Escape.
    /// Search session active → close overlay only (never hide the window).
    func handleMainWindowCancel() {
        if isSamplingItemBackground { return }
        if openFailure != nil
            || ingestFailureMessage != nil
            || saveFailureMessage != nil
            || isPresentingItemOpenChoice
            || isPresentingItemRename
            || isPresentingCollectionAlert {
            return
        }
        if backgroundPickerItemID != nil {
            backgroundPickerItemID = nil
            return
        }
        if isSelectingItems {
            exitItemSelection()
            return
        }
        if isSearchSessionActive {
            clearSearch()
            return
        }
        if suppressHideFromCancel { return }
        hideMainWindow()
    }

    /// Keep / bring up the main window and show a launch-error alert.
    /// Callers that began an external launch must `endExternalLaunch` themselves (this does not nest-clear).
    func reportOpenFailure(itemName: String, message: String, recoveryCommand: String? = nil) {
        openFailure = OpenFailure(itemName: itemName, message: message, recoveryCommand: recoveryCommand)
        showMainWindow()
    }

    func clearOpenFailure() {
        openFailure = nil
    }

    func reportSaveFailure(_ message: String) {
        saveFailureMessage = message
        showMainWindow()
    }

    func clearSaveFailure() {
        saveFailureMessage = nil
    }

    /// Ingest aborted (e.g. Open With Cursor chosen but Cursor is missing). Does not use open-failure copy.
    func reportIngestFailure(_ message: String) {
        ingestFailureMessage = message
    }

    func clearIngestFailure() {
        ingestFailureMessage = nil
    }

    func beginExternalLaunch() {
        externalLaunchDepth += 1
        isLaunchingExternalApp = true
    }

    func endExternalLaunch() {
        externalLaunchDepth = max(0, externalLaunchDepth - 1)
        isLaunchingExternalApp = externalLaunchDepth > 0
    }

    // MARK: - Search

    /// Saved-items search across **all** collections (no Spotlight).
    var searchResults: [SearchHit] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let queries = SearchLayoutTranslit.matchQueries(for: q)
        var hits: [SearchHit] = []
        for collection in sortedCollections {
            for item in collection.items {
                let name = item.displayName.lowercased()
                guard queries.contains(where: { name.contains($0) }) else { continue }
                hits.append(SearchHit(item: item, collectionName: collection.name))
            }
        }
        return hits.sorted {
            $0.item.displayName.localizedCaseInsensitiveCompare($1.item.displayName) == .orderedAscending
        }
    }

    func clearSearch() {
        let endingSession = isSearchSessionActive
        searchQuery = ""
        searchSelectedItemID = nil
        isSearchSessionActive = false
        // Dismissing the overlay tears down the search field editor; AppKit may then send
        // `cancelOperation` again. Without this, that second call would hide the window.
        if endingSession {
            suppressHideFromCancel = true
            DispatchQueue.main.async { [weak self] in
                self?.suppressHideFromCancel = false
            }
        }
    }

    func beginSearchSessionIfNeeded() {
        guard !isSearchSessionActive else { return }
        SearchLayoutTranslit.invalidateInstallationCache()
        isSearchSessionActive = true
        if isSelectingItems {
            exitItemSelection()
        }
    }

    func appendTypedCharacter(_ character: Character) {
        guard !character.isNewline else { return }
        beginSearchSessionIfNeeded()
        searchQuery.append(character)
        syncSearchSelection()
    }

    func setSearchQuery(_ query: String) {
        if !query.isEmpty || isSearchSessionActive {
            beginSearchSessionIfNeeded()
        }
        searchQuery = query
        syncSearchSelection()
    }

    func syncSearchSelection() {
        let hits = searchResults
        if let current = searchSelectedItemID, hits.contains(where: { $0.item.id == current }) {
            return
        }
        searchSelectedItemID = hits.first?.item.id
    }

    func selectAdjacentSearchResult(delta: Int) {
        let hits = searchResults
        guard !hits.isEmpty else { return }
        guard let current = searchSelectedItemID,
              let idx = hits.firstIndex(where: { $0.item.id == current }) else {
            searchSelectedItemID = hits.first?.item.id
            return
        }
        let next = max(0, min(hits.count - 1, idx + delta))
        searchSelectedItemID = hits[next].item.id
    }
}
