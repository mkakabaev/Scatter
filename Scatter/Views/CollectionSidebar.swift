import SwiftUI

struct CollectionSidebar: View {
    @EnvironmentObject private var store: AppStore
    var onRequestNew: () -> Void
    var onRequestRename: (AppState.Collection) -> Void

    @State private var draggingCollectionID: UUID?
    @State private var dragTranslation: CGFloat = 0
    /// Index in the list after the dragged row is removed.
    @State private var insertionIndex: Int?
    @State private var rowFrames: [UUID: CGRect] = [:]

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Traffic-light / top chrome — not on a collection row.
                    WindowBackgroundDragView(onClick: {})
                        .frame(height: 30)
                        .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(store.sortedCollections) { collection in
                            collectionRow(collection)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .coordinateSpace(name: "collection-sidebar")
                    .overlay(alignment: .topLeading) { insertionLine }
                    .onPreferenceChange(CollectionRowFramesKey.self) { frames in
                        // The dragged row's frame follows the pointer. Ignore that so the gesture is not reset.
                        if let draggingCollectionID {
                            var stable = rowFrames
                            for (id, frame) in frames where id != draggingCollectionID {
                                stable[id] = frame
                            }
                            if stable != rowFrames { rowFrames = stable }
                        } else {
                            rowFrames = frames
                        }
                    }
                    .onPreferenceChange(CollectionRowGlobalFramesKey.self) { frames in
                        store.updateSidebarRowFrames(frames)
                    }

                    // Fill leftover viewport below the last row (collapses when the list is long).
                    WindowBackgroundDragView(onClick: {})
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minHeight: geo.size.height, alignment: .top)
                .animation(.easeOut(duration: 0.16), value: store.sortedCollections.map(\.id))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.opacity(0.35))
        .contextMenu {
            Button("New Collection…") { onRequestNew() }
        }
    }

    private func collectionRow(_ collection: AppState.Collection) -> some View {
        let isSelected = store.selectedCollection?.id == collection.id
        let isDropTarget = store.itemDragHoverCollectionID == collection.id
        return HStack {
            Text(collection.name)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(collection.items.count)")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(rowBackground(isSelected: isSelected, isDropTarget: isDropTarget))
        )
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectCollection(collection.id)
        }
        .background(rowFrameReader(collection.id))
        .offset(y: draggingCollectionID == collection.id ? dragTranslation : 0)
        .zIndex(draggingCollectionID == collection.id ? 1 : 0)
        .highPriorityGesture(reorderGesture(for: collection))
        .contextMenu {
            Button("New Collection…") { onRequestNew() }
            Button("Rename…") { onRequestRename(collection) }
            Divider()
            Button("Delete", role: .destructive) {
                store.deleteCollection(collection.id)
            }
            .disabled(store.state.collections.count <= 1)
        }
    }

    private func rowBackground(isSelected: Bool, isDropTarget: Bool) -> Color {
        if isDropTarget { return Color.accentColor.opacity(0.28) }
        if isSelected { return Color.white.opacity(0.12) }
        return .clear
    }

    private func rowFrameReader(_ id: UUID) -> some View {
        GeometryReader { geo in
            Color.clear
                .preference(
                    key: CollectionRowFramesKey.self,
                    value: [id: geo.frame(in: .named("collection-sidebar"))]
                )
                .preference(
                    key: CollectionRowGlobalFramesKey.self,
                    value: [id: geo.frame(in: .global)]
                )
        }
    }

    private func reorderGesture(for collection: AppState.Collection) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("collection-sidebar"))
            .onChanged { value in
                draggingCollectionID = collection.id
                dragTranslation = value.translation.height
                insertionIndex = insertionIndex(at: value.location.y, dragging: collection.id)
            }
            .onEnded { _ in
                if let draggingCollectionID, let insertionIndex {
                    store.moveCollection(draggingCollectionID, toInsertionIndex: insertionIndex)
                }
                draggingCollectionID = nil
                dragTranslation = 0
                insertionIndex = nil
            }
    }

    /// Index among the rows that are not being dragged. `0` inserts at the top.
    private func insertionIndex(at y: CGFloat, dragging: UUID) -> Int {
        var index = 0
        for collection in store.sortedCollections where collection.id != dragging {
            guard let frame = rowFrames[collection.id] else { continue }
            if y < frame.midY { return index }
            index += 1
        }
        return index
    }

    @ViewBuilder
    private var insertionLine: some View {
        if let draggingCollectionID,
           let insertionIndex,
           let from = store.sortedCollections.firstIndex(where: { $0.id == draggingCollectionID }),
           insertionIndex != from,
           let y = insertionLineY(dragging: draggingCollectionID, index: insertionIndex) {
            Capsule()
                .fill(Color.accentColor)
                .frame(height: 2)
                .padding(.horizontal, 10)
                .offset(y: y - 1)
                .allowsHitTesting(false)
        }
    }

    private func insertionLineY(dragging: UUID, index: Int) -> CGFloat? {
        let others = store.sortedCollections.filter { $0.id != dragging }
        if index <= 0, let frame = others.first.flatMap({ rowFrames[$0.id] }) {
            return frame.minY
        }
        if index >= others.count, let frame = others.last.flatMap({ rowFrames[$0.id] }) {
            return frame.maxY
        }
        if others.indices.contains(index), let frame = rowFrames[others[index].id] {
            return frame.minY
        }
        return nil
    }

}

private struct CollectionRowFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct CollectionRowGlobalFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
