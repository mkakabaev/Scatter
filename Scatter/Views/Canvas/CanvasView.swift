import SwiftUI
import AppKit

struct CanvasView: View {
    @EnvironmentObject var store: AppStore
    @State private var dragOrigins: [UUID: CGPoint] = [:]
    /// Live free-form positions while dragging — not persisted until `finalizeItemPlacement`.
    @State private var dragPositions: [UUID: CGPoint] = [:]
    @State private var dragMoved: Set<UUID> = []
    @State private var dropTargetFrame: CGRect?
    @State var renameItemID: UUID?
    @State var renameText: String = ""
    @State var canvasSize: CGSize = .zero
    @State var pendingDrop: PendingDrop?

    /// Held until Default / Open With Cursor / Cancel — whole batch is atomic.
    struct PendingDrop: Identifiable {
        let id = UUID()
        /// Files/folders that need the Open With Cursor confirmation.
        let openChoiceItems: [LauncherItem]
        /// Apps / URLs from the same drop or paste; committed only if the dialog confirms.
        let otherItems: [LauncherItem]
    }

    private var iconSize: CGFloat { store.state.settings.iconSize }
    private var labelSize: CGFloat { store.state.settings.labelSize }
    var itemWidth: CGFloat { TileMetrics.itemWidth(iconSize: iconSize) }
    var itemHeight: CGFloat { TileMetrics.itemHeight(iconSize: iconSize, labelSize: labelSize) }

    /// Matches the canvas top padding (traffic-light clearance).
    static let canvasTopInset: CGFloat = 12
    /// Right / bottom margin when expanding the window to fit clipped tiles.
    static let fitContentMargin: CGFloat = SnapToGrid.origin.x

    /// Small but intentional pointer travel before a drag begins.
    private let dragThreshold: CGFloat = 4

    /// Draw dragged icon last so it sits above every other tile.
    private var orderedItems: [LauncherItem] {
        let items = store.visibleItems
        guard let draggingID = dragMoved.first else { return items }
        var rest = items.filter { $0.id != draggingID }
        if let dragging = items.first(where: { $0.id == draggingID }) {
            rest.append(dragging)
        }
        return rest
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                WindowBackgroundDragView(
                    onClick: {
                        if store.isSelectingItems { return }
                        store.clearContextMenuHighlight()
                        store.selectedItemID = nil
                    },
                    contextMenuItems: emptyCanvasContextMenuItems,
                    onContextMenuOpen: {
                        store.clearSelectionForEmptyContextMenu()
                    },
                    onURLsDropped: { contents, point in
                        handleCanvasDrop(contents, at: point)
                    },
                    itemFrames: orderedItems.map {
                        let origin = visualPosition(for: $0)
                        return .init(
                            id: $0.id,
                            frame: CGRect(
                                x: origin.x,
                                y: origin.y,
                                width: itemWidth,
                                height: itemHeight
                            )
                        )
                    },
                    onItemContextMenuHighlight: { store.beginContextMenuHighlight(itemID: $0) },
                    onItemContextMenuHighlightClear: { store.clearContextMenuHighlight() },
                    itemContextMenuItems: { itemID in
                        guard let item = orderedItems.first(where: { $0.id == itemID }) else { return [] }
                        return itemAppKitContextMenu(item)
                    }
                )
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)

                if let dropTargetFrame, dropTargetFrame != .null {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.85), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.accentColor.opacity(0.14))
                        )
                        .frame(width: dropTargetFrame.width, height: dropTargetFrame.height)
                        .offset(x: dropTargetFrame.minX, y: dropTargetFrame.minY)
                        .allowsHitTesting(false)
                        .zIndex(500)
                }

                ForEach(orderedItems) { item in
                    let origin = visualPosition(for: item)
                    LauncherItemView(
                        item: item,
                        iconSize: iconSize,
                        labelSize: labelSize,
                        isSelected: itemIsSelected(item)
                    )
                    .frame(width: itemWidth, height: itemHeight, alignment: .top)
                    .offset(x: origin.x, y: origin.y)
                    .animation(dragMoved.contains(item.id) ? nil : AppStore.layoutAnimation, value: item.position)
                    .zIndex(dragMoved.contains(item.id) ? 1_000 : 0)
                    .gesture(itemPointerGesture(item))
                }

                if store.backgroundPickerItemID != nil {
                    Color.black.opacity(0.001)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if !store.isSamplingItemBackground {
                                store.backgroundPickerItemID = nil
                            }
                        }
                        .zIndex(1_500)
                }

                if let pickerID = store.backgroundPickerItemID,
                   let target = orderedItems.first(where: { $0.id == pickerID }) {
                    ItemBackgroundPicker(
                        selectedColor: target.backgroundColor,
                        isSampling: $store.isSamplingItemBackground,
                        onSelect: { color in
                            store.setItemBackground(target.id, color: color)
                            store.backgroundPickerItemID = nil
                        }
                    )
                    .offset(pickerOffset(for: target))
                    .zIndex(1_600)
                }

                if store.isSelectingItems, !store.selectedItemIDs.isEmpty {
                    selectionActionBar
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                        .zIndex(1_200)
                }

                if !store.isSearching {
                    overflowChevrons(canvasSize: geo.size)
                        .zIndex(1_100)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .padding(.top, Self.canvasTopInset)
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { _, newSize in canvasSize = newSize }
            .onChange(of: store.pasteRequestID) { _, _ in
                pasteFromClipboard()
            }
            .onChange(of: store.visibleItems.map(\.id)) { _, ids in
                if let id = store.backgroundPickerItemID, !ids.contains(id) {
                    store.backgroundPickerItemID = nil
                }
                store.pruneItemSelection(toVisibleIDs: Set(ids))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .alert("Rename", isPresented: Binding(
            get: { renameItemID != nil },
            set: { if !$0 { renameItemID = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameItemID = nil }
            Button("Rename") {
                if let id = renameItemID {
                    store.renameItem(id, to: renameText)
                }
                renameItemID = nil
            }
        }
        .onChange(of: renameItemID) { _, id in
            store.isPresentingItemRename = id != nil
        }
        .confirmationDialog(
            openChoiceTitle,
            isPresented: Binding(
                get: { pendingDrop != nil },
                set: { if !$0 { pendingDrop = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Default") {
                commitPendingDrop(openWithCursor: false)
            }
            Button("Open With Cursor") {
                guard CursorLocator.applicationURL != nil else {
                    pendingDrop = nil
                    store.reportIngestFailure("Cursor could not be found. Install Cursor or choose Default.")
                    return
                }
                commitPendingDrop(openWithCursor: true)
            }
            Button("Cancel", role: .cancel) {
                pendingDrop = nil
            }
        } message: {
            Text("Choose how this item opens by default.")
        }
        .onChange(of: pendingDrop != nil) { _, isPresenting in
            store.isPresentingItemOpenChoice = isPresenting
        }
        .onChange(of: store.isMainWindowVisible) { _, visible in
            // Hide must discard an unfinished batch so the dialog cannot resurrect on next show.
            if !visible { pendingDrop = nil }
        }
        .onDisappear {
            store.isPresentingItemOpenChoice = false
            store.isPresentingItemRename = false
        }
    }

    func visualPosition(for item: LauncherItem) -> CGPoint {
        dragPositions[item.id] ?? item.position.cgPoint
    }

    private func itemIsSelected(_ item: LauncherItem) -> Bool {
        if store.isSelectingItems {
            return store.selectedItemIDs.contains(item.id)
        }
        // While a context menu is open, only the menu target shows the accent stroke.
        if let menuID = store.contextMenuItemID {
            return item.id == menuID
        }
        return store.selectedItemID == item.id
    }

    private func handleClick(_ item: LauncherItem) {
        store.selectedItemID = item.id
        let flags = NSEvent.modifierFlags
        let keepOpen = flags.contains(.option)
        if flags.contains(.command) {
            ItemOpener.reveal(item, keepWindowOpen: keepOpen, store: store)
            return
        }
        // Shift-click enters multi-select (same seed as item Select…); ⌘ still reveals above.
        if flags.contains(.shift), store.visibleItems.count > 1 {
            store.enterItemSelection(seeding: [item.id])
            return
        }
        ItemOpener.open(item, settings: store.state.settings, keepWindowOpen: keepOpen, store: store)
    }

    /// Drag starts after a small pointer shift; a click with little/no movement opens the item.
    /// In select mode: click toggles membership; reposition drag is suppressed (no sidebar drop).
    /// Normal mode: pointer over another sidebar collection moves the item there on drop.
    private func itemPointerGesture(_ item: LauncherItem) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if store.isSelectingItems { return }
                if dragOrigins[item.id] == nil {
                    dragOrigins[item.id] = item.position.cgPoint
                    store.selectedItemID = item.id
                }
                guard let start = dragOrigins[item.id] else { return }
                let dx = value.location.x - value.startLocation.x
                let dy = value.location.y - value.startLocation.y
                let distance = hypot(dx, dy)
                guard distance >= dragThreshold else { return }
                dragMoved.insert(item.id)

                let hoverID = store.collectionID(atGlobalPoint: value.location)
                let droppingOnOther = hoverID != nil && hoverID != store.selectedCollection?.id
                store.setItemDragHoverCollection(droppingOnOther ? hoverID : nil)
                if droppingOnOther {
                    dropTargetFrame = nil
                    return
                }

                let proposed = CGPoint(x: max(0, start.x + dx), y: max(0, start.y + dy))
                dragPositions[item.id] = proposed
                updateDropTarget(for: item.id, proposed: proposed)
            }
            .onEnded { value in
                if store.isSelectingItems {
                    store.toggleItemSelection(item.id)
                    return
                }
                let moved = dragMoved.contains(item.id)
                let start = dragOrigins[item.id]
                let hoverID = store.itemDragHoverCollectionID
                defer {
                    dragOrigins[item.id] = nil
                    dragPositions[item.id] = nil
                    dragMoved.remove(item.id)
                    dropTargetFrame = nil
                    store.clearItemDragHover()
                }
                if moved, let hoverID, hoverID != store.selectedCollection?.id {
                    store.moveItem(item.id, toCollection: hoverID)
                } else if moved, let start {
                    let dx = value.location.x - value.startLocation.x
                    let dy = value.location.y - value.startLocation.y
                    store.finalizeItemPlacement(
                        item.id,
                        at: CGPoint(x: max(0, start.x + dx), y: max(0, start.y + dy)),
                        canvasSize: canvasSize
                    )
                } else {
                    handleClick(item)
                }
            }
    }

    private var selectionActionBar: some View {
        let count = store.selectedItemIDs.count
        return HStack(spacing: 12) {
            Text(count == 1 ? "1 Selected" : "\(count) Selected")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Menu("Move to Collection") {
                ForEach(store.sortedCollections) { collection in
                    Button(collection.name) {
                        store.moveItems(store.selectedItemIDs, toCollection: collection.id)
                    }
                    .disabled(collection.id == store.selectedCollection?.id)
                }
            }
            Button("Remove", role: .destructive) {
                store.removeItems(store.selectedItemIDs)
            }
            Button("Done") {
                store.exitItemSelection()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func updateDropTarget(for itemID: UUID, proposed: CGPoint) {
        guard let collection = store.selectedCollection else {
            dropTargetFrame = nil
            return
        }
        let frame = SnapToGrid.previewFrame(
            itemID: itemID,
            proposed: proposed,
            items: collection.items,
            settings: store.state.settings,
            canvasSize: canvasSize
        )
        dropTargetFrame = frame == .null ? nil : frame
    }

    private func pickerOffset(for item: LauncherItem) -> CGSize {
        let margin: CGFloat = 8
        let width = ItemBackgroundPicker.width
        let height = ItemBackgroundPicker.height
        let origin = visualPosition(for: item)
        var x = origin.x
        var y = origin.y + itemHeight + 6
        let maxX = max(margin, canvasSize.width - width - margin)
        let maxY = max(margin, canvasSize.height - height - margin)
        if y > maxY {
            y = origin.y - height - 6
        }
        x = min(max(margin, x), maxX)
        y = min(max(margin, y), maxY)
        return CGSize(width: x, height: y)
    }

    func launcherWindow() -> NSWindow? {
        NSApp.windows.first(where: { $0 is LauncherWindow && $0.isVisible })
            ?? NSApp.windows.first(where: { $0 is LauncherWindow })
    }
}
