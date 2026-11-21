import SwiftUI
import AppKit

struct FreeformCanvasView: View {
    @EnvironmentObject private var store: AppStore
    @State private var dragOrigins: [UUID: CGPoint] = [:]
    @State private var dragMoved: Set<UUID> = []
    @State private var dropTargetFrame: CGRect?
    @State private var renameItemID: UUID?
    @State private var renameText: String = ""
    @State private var canvasSize: CGSize = .zero
    @State private var pendingDrop: PendingDrop?

    private struct PendingDrop: Identifiable {
        let id = UUID()
        let items: [LauncherItem]

        init(items: [LauncherItem]) {
            self.items = items
        }

        init(item: LauncherItem) {
            self.items = [item]
        }
    }

    private var iconSize: CGFloat { store.state.settings.iconSize }
    private var labelSize: CGFloat { store.state.settings.labelSize }
    private var itemWidth: CGFloat { TileMetrics.itemWidth(iconSize: iconSize) }
    private var itemHeight: CGFloat { TileMetrics.itemHeight(iconSize: iconSize, labelSize: labelSize) }

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
                    onClick: { store.selectedItemID = nil },
                    contextMenuItems: [
                        .init(title: "Add…") { point in pickAndAdd(at: point) },
                    ],
                    onURLsDropped: { urls, point in
                        handleCanvasURLs(urls, at: point)
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
                    LauncherItemView(
                        item: item,
                        iconSize: iconSize,
                        labelSize: labelSize,
                        isSelected: store.selectedItemID == item.id
                    )
                    .frame(width: itemWidth, height: itemHeight, alignment: .top)
                    .offset(x: item.position.cgPoint.x, y: item.position.cgPoint.y)
                    .animation(dragMoved.contains(item.id) ? nil : AppStore.layoutAnimation, value: item.position)
                    .zIndex(dragMoved.contains(item.id) ? 1_000 : 0)
                    .gesture(itemPointerGesture(item))
                    .contextMenu { itemContextMenu(item) }
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
                        selectedHex: target.backgroundColorHex,
                        isSampling: store.isSamplingItemBackground,
                        onSelect: { hex in
                            store.setItemBackground(target.id, hex: hex)
                            store.backgroundPickerItemID = nil
                        },
                        onPickFromScreen: {
                            store.sampleItemBackground(for: target.id)
                        }
                    )
                    .offset(pickerOffset(for: target))
                    .zIndex(1_600)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .padding(.top, 12)
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { _, newSize in canvasSize = newSize }
            .onChange(of: store.visibleItems.map(\.id)) { _, ids in
                if let id = store.backgroundPickerItemID, !ids.contains(id) {
                    store.backgroundPickerItemID = nil
                }
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
                commitPendingDrop(openWithCursor: true)
            }
            Button("Cancel", role: .cancel) {
                pendingDrop = nil
            }
        } message: {
            Text("Choose how this item opens by default.")
        }
    }

    private var openChoiceTitle: String {
        guard let items = pendingDrop?.items, let first = items.first else {
            return "Open With"
        }
        if items.count == 1 {
            return "Open “\(first.displayName)”"
        }
        return "Open \(items.count) Items"
    }

    private func commitPendingDrop(openWithCursor: Bool) {
        guard let pending = pendingDrop else { return }
        for item in pending.items {
            store.addItemFromFinder(item, openWithCursor: openWithCursor)
        }
        pendingDrop = nil
    }

    /// `canvasPoint` is the right-click location in the empty-canvas view (tile centers on it, same as drop).
    private func pickAndAdd(at canvasPoint: CGPoint) {
        let dropPoint = CGPoint(
            x: max(0, canvasPoint.x - itemWidth / 2),
            y: max(0, canvasPoint.y - itemHeight / 2)
        )
        guard let urls = AddItemsPanel.run() else { return }
        var awaitingOpenChoice: [LauncherItem] = []
        for url in urls {
            guard let item = ItemOpener.makeItem(from: url, at: dropPoint) else { continue }
            if item.kind == .file || item.kind == .folder {
                awaitingOpenChoice.append(item)
            } else {
                store.addItemFromFinder(item, openWithCursor: false)
            }
        }
        if !awaitingOpenChoice.isEmpty {
            pendingDrop = PendingDrop(items: awaitingOpenChoice)
        }
    }

    private func handleClick(_ item: LauncherItem) {
        store.selectedItemID = item.id
        let flags = NSEvent.modifierFlags
        let keepOpen = flags.contains(.option)
        if flags.contains(.command) {
            ItemOpener.reveal(item, keepWindowOpen: keepOpen, store: store)
            return
        }
        ItemOpener.open(item, settings: store.state.settings, keepWindowOpen: keepOpen, store: store)
    }

    /// Drag starts after a small pointer shift; a click with little/no movement opens the item.
    private func itemPointerGesture(_ item: LauncherItem) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
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
                let proposed = CGPoint(x: max(0, start.x + dx), y: max(0, start.y + dy))
                store.updateItemPosition(item.id, to: proposed)
                updateDropTarget(for: item.id, proposed: proposed)
            }
            .onEnded { value in
                let moved = dragMoved.contains(item.id)
                let start = dragOrigins[item.id]
                defer {
                    dragOrigins[item.id] = nil
                    dragMoved.remove(item.id)
                    dropTargetFrame = nil
                }
                if moved, let start {
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
        var x = item.position.x
        var y = item.position.y + itemHeight + 6
        let maxX = max(margin, canvasSize.width - width - margin)
        let maxY = max(margin, canvasSize.height - height - margin)
        if y > maxY {
            y = item.position.y - height - 6
        }
        x = min(max(margin, x), maxX)
        y = min(max(margin, y), maxY)
        return CGSize(width: x, height: y)
    }

    private var timeZoneMenuTitle: String {
        guard let identifier = store.state.settings.timeZoneIdentifier,
              TimeZone(identifier: identifier) != nil else {
            return "Time Zone"
        }
        let city = identifier.split(separator: "/").last.map {
            $0.replacingOccurrences(of: "_", with: " ")
        } ?? identifier
        return "Time Zone (\(city))"
    }

    @ViewBuilder
    private func itemContextMenu(_ item: LauncherItem) -> some View {
        Button(ItemOpener.primaryActionTitle(for: item)) {
            ItemOpener.open(item, settings: store.state.settings, keepWindowOpen: false, store: store)
        }
        if item.kind != .url {
            Button("Reveal in Finder") {
                ItemOpener.reveal(item, keepWindowOpen: false, store: store)
            }
        }
        Divider()
        if item.kind == .url {
            urlOpenWithMenu(for: item)
        } else {
            Button("Open With…") { pickOpenWith(for: item) }
        }
        if item.openWithBundleIdentifier != nil || item.openWithBookmarkData != nil {
            Button("Clear Open With") {
                store.setOpenWith(for: item.id, bundleID: nil, bookmark: nil)
            }
        }
        Divider()
        Button("Rename…") {
            renameText = item.displayName
            renameItemID = item.id
        }
        Button("Background…") {
            store.selectedItemID = item.id
            store.backgroundPickerItemID = item.id
        }
        Toggle(timeZoneMenuTitle, isOn: Binding(
            get: { item.applyTimeZone },
            set: { enabled in store.setApplyTimeZone(for: item.id, enabled: enabled) }
        ))
        Divider()
        Menu("Move to Collection") {
            ForEach(store.sortedCollections) { collection in
                Button(collection.name) {
                    store.moveItem(item.id, toCollection: collection.id)
                }
                .disabled(collection.id == store.selectedCollection?.id)
            }
        }
        Button("Remove from Collection", role: .destructive) {
            store.removeItem(item.id)
        }
    }

    @ViewBuilder
    private func urlOpenWithMenu(for item: LauncherItem) -> some View {
        let browsers = BrowserLocator.installedBrowsers
        Menu("Open With") {
            if browsers.isEmpty {
                Text("No Browsers Found")
            } else {
                ForEach(browsers, id: \.path) { browser in
                    Button(OpenWithPanel.displayName(forApplicationAt: browser)) {
                        open(item, withApplicationAt: browser, always: false)
                    }
                }
            }
        }
        Menu("Always Open in") {
            if browsers.isEmpty {
                Text("No Browsers Found")
            } else {
                ForEach(browsers, id: \.path) { browser in
                    Button(OpenWithPanel.displayName(forApplicationAt: browser)) {
                        open(item, withApplicationAt: browser, always: true)
                    }
                }
            }
        }
    }

    private func pickOpenWith(for item: LauncherItem) {
        guard let result = OpenWithPanel.run() else { return }
        open(item, withApplicationAt: result.applicationURL, always: result.alwaysOpenIn)
    }

    private func open(_ item: LauncherItem, withApplicationAt appURL: URL, always: Bool) {
        if always {
            store.setOpenWith(
                for: item.id,
                bundleID: Bundle(url: appURL)?.bundleIdentifier,
                bookmark: ItemOpener.bookmark(forApplicationAt: appURL)
            )
        }
        ItemOpener.open(
            item,
            withApplicationAt: appURL,
            settings: store.state.settings,
            keepWindowOpen: true,
            store: store
        )
    }

    /// AppKit canvas drop: `location` is in the empty-canvas view (flipped).
    private func handleCanvasURLs(_ urls: [URL], at location: CGPoint) {
        let dropPoint = CGPoint(
            x: max(0, location.x - itemWidth / 2),
            y: max(0, location.y - itemHeight / 2)
        )
        let title = ItemOpener.draggedWebTitle()
        var awaitingOpenChoice: [LauncherItem] = []
        for url in urls {
            let linkTitle = url.isFileURL ? title : (ItemOpener.draggedWebLink()?.title ?? title)
            guard let item = ItemOpener.makeItem(from: url, at: dropPoint, title: linkTitle) else { continue }
            if item.kind == .file || item.kind == .folder {
                awaitingOpenChoice.append(item)
            } else if item.kind == .url {
                store.addWebLink(item)
            } else {
                store.addItemFromFinder(item, openWithCursor: false)
            }
        }
        if !awaitingOpenChoice.isEmpty {
            pendingDrop = PendingDrop(items: awaitingOpenChoice)
        }
    }
}
