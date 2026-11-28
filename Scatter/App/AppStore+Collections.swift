import Foundation

extension AppStore {
    func selectCollection(_ id: UUID) {
        mutate { $0.settings.selectedCollectionID = id }
        selectedItemID = nil
        clearContextMenuHighlight()
        clearItemDragHover()
        clearSearch()
        exitItemSelection()
        backgroundPickerItemID = nil
    }

    func selectCollection(index: Int) {
        let cols = sortedCollections
        guard cols.indices.contains(index) else { return }
        selectCollection(cols[index].id)
    }

    func selectAdjacentCollection(delta: Int) {
        let cols = sortedCollections
        guard !cols.isEmpty,
              let current = selectedCollection,
              let idx = cols.firstIndex(where: { $0.id == current.id }) else { return }
        let count = cols.count
        let next = ((idx + delta) % count + count) % count
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
        // Keep at least one collection so Finder drop / paste / Add… always have a target.
        guard state.collections.count > 1 else { return }
        let removedIDs = Set(state.collections.first(where: { $0.id == id })?.items.map(\.id) ?? [])
        webLinkEnricher.cancel(itemIDs: removedIDs)
        ItemIconStore.remove(itemIDs: removedIDs)
        mutate {
            $0.collections.removeAll { $0.id == id }
            var cols = $0.collections.sorted { $0.sortIndex < $1.sortIndex }
            if $0.settings.selectedCollectionID == id {
                $0.settings.selectedCollectionID = cols.first?.id
            }
            for i in cols.indices {
                cols[i].sortIndex = i
            }
            $0.collections = cols
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
}
