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

    /// Matches the canvas top padding (traffic-light clearance).
    private static let canvasTopInset: CGFloat = 12
    /// Right / bottom margin when expanding the window to fit clipped tiles.
    private static let fitContentMargin: CGFloat = SnapToGrid.origin.x

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
                    onURLsDropped: { urls, point in
                        handleCanvasURLs(urls, at: point)
                    },
                    itemFrames: store.isSelectingItems ? [] : orderedItems.map {
                        .init(
                            id: $0.id,
                            frame: CGRect(
                                x: $0.position.cgPoint.x,
                                y: $0.position.cgPoint.y,
                                width: itemWidth,
                                height: itemHeight
                            )
                        )
                    },
                    onItemContextMenuHighlight: { store.beginContextMenuHighlight(itemID: $0) },
                    onItemContextMenuHighlightClear: { store.clearContextMenuHighlight() }
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
                        isSelected: itemIsSelected(item)
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

    private var emptyCanvasContextMenuItems: [WindowBackgroundDragView.MenuItem] {
        let items = store.visibleItems
        let settings = store.state.settings
        let size = canvasSize
        return [
            .init(title: "Add…") { point in pickAndAdd(at: point) },
            .separator(),
            .submenu(title: "Layout", children: [
                .init(
                    title: "Delete Row",
                    isEnabled: { point in
                        let cell = SnapToGrid.hitTestCell(
                            at: point,
                            items: items,
                            settings: settings,
                            canvasSize: size
                        )
                        // Enabled only for a fully empty row that delete would collapse.
                        return SnapToGrid.canDeleteEmptyRow(cell.row, items: items)
                    },
                    action: { point in
                        let cell = SnapToGrid.hitTestCell(
                            at: point,
                            items: store.visibleItems,
                            settings: store.state.settings,
                            canvasSize: canvasSize
                        )
                        store.deleteEmptyRow(cell.row)
                    }
                ),
                .init(
                    title: "Delete Column",
                    isEnabled: { point in
                        let cell = SnapToGrid.hitTestCell(
                            at: point,
                            items: items,
                            settings: settings,
                            canvasSize: size
                        )
                        // Enabled only for a fully empty column that delete would collapse.
                        return SnapToGrid.canDeleteEmptyColumn(cell.column, items: items)
                    },
                    action: { point in
                        let cell = SnapToGrid.hitTestCell(
                            at: point,
                            items: store.visibleItems,
                            settings: store.state.settings,
                            canvasSize: canvasSize
                        )
                        store.deleteEmptyColumn(cell.column)
                    }
                ),
            ]),
        ]
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
        ItemOpener.open(item, settings: store.state.settings, keepWindowOpen: keepOpen, store: store)
    }

    /// Drag starts after a small pointer shift; a click with little/no movement opens the item.
    /// In select mode: click toggles membership; reposition drag is suppressed.
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
                let proposed = CGPoint(x: max(0, start.x + dx), y: max(0, start.y + dy))
                store.updateItemPosition(item.id, to: proposed)
                updateDropTarget(for: item.id, proposed: proposed)
            }
            .onEnded { value in
                if store.isSelectingItems {
                    store.toggleItemSelection(item.id)
                    return
                }
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

    /// Right / bottom edge hints when tiles are clipped by the window. Click expands to fit all.
    @ViewBuilder
    private func overflowChevrons(canvasSize: CGSize) -> some View {
        let overflow = overflowEdges(canvasSize: canvasSize)
        let bottomPad: CGFloat = store.isSelectingItems && !store.selectedItemIDs.isEmpty ? 64 : 6
        // `.position` keeps hit targets button-sized (no full-canvas frame intercept).
        ZStack {
            if overflow.right {
                overflowChevronButton(systemName: "chevron.right")
                    .position(x: canvasSize.width - 17, y: canvasSize.height / 2)
            }
            if overflow.bottom {
                overflowChevronButton(systemName: "chevron.down")
                    .position(x: canvasSize.width / 2, y: canvasSize.height - bottomPad - 14)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    private func overflowChevronButton(systemName: String) -> some View {
        Button {
            expandWindowToFitContent()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 22, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.45))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Resize window to show all items")
    }

    private func overflowEdges(canvasSize: CGSize) -> (right: Bool, bottom: Bool) {
        let bounds = SnapToGrid.contentBounds(items: store.visibleItems, settings: store.state.settings)
        guard bounds != .null else { return (false, false) }
        // Top inset shifts the framed canvas down; bottom clips that much sooner.
        let right = bounds.maxX > canvasSize.width + 0.5
        let bottom = bounds.maxY + Self.canvasTopInset > canvasSize.height + 0.5
        guard right || bottom else { return (false, false) }
        // Only show a chevron when the window can still grow on that axis.
        let room = growRoom(for: canvasSize)
        return (right && room.width > 0.5, bottom && room.height > 0.5)
    }

    /// How much the canvas can still grow before hitting the screen’s visible frame.
    private func growRoom(for canvasSize: CGSize) -> CGSize {
        guard let window = launcherWindow(),
              let screen = window.screen ?? NSScreen.main else {
            return CGSize(width: 10_000, height: 10_000)
        }
        let visible = screen.visibleFrame
        let contentW = window.contentView?.bounds.width ?? window.frame.width
        let contentH = window.contentView?.bounds.height ?? window.frame.height
        let chromeW = window.frame.width - contentW
        let chromeH = window.frame.height - contentH
        // Keep the window’s top-left fixed; remaining room is to the right and down.
        let maxContentW = max(0, visible.maxX - window.frame.minX - chromeW)
        let maxContentH = max(0, window.frame.maxY - visible.minY - chromeH)
        let sidebar = SidebarLayout.clamped(
            store.state.settings.sidebarWidth,
            containerWidth: Double(contentW)
        )
        let maxCanvasW = max(0, maxContentW - sidebar - SidebarLayout.splitterThickness)
        return CGSize(
            width: max(0, maxCanvasW - canvasSize.width),
            height: max(0, maxContentH - contentH)
        )
    }

    /// Expand the main window so every visible tile fits (clamped to the display).
    private func expandWindowToFitContent() {
        guard let window = launcherWindow() else { return }
        let bounds = SnapToGrid.contentBounds(items: store.visibleItems, settings: store.state.settings)
        guard bounds != .null else { return }

        let contentW = window.contentView?.bounds.width ?? window.frame.width
        let contentH = window.contentView?.bounds.height ?? window.frame.height
        let sidebar = SidebarLayout.clamped(
            store.state.settings.sidebarWidth,
            containerWidth: Double(contentW)
        )
        let neededCanvasW = bounds.maxX + Self.fitContentMargin
        let neededCanvasH = bounds.maxY + Self.fitContentMargin + Self.canvasTopInset
        var targetContent = CGSize(
            width: max(contentW, sidebar + SidebarLayout.splitterThickness + neededCanvasW),
            height: max(contentH, neededCanvasH)
        )

        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            let chromeW = window.frame.width - contentW
            let chromeH = window.frame.height - contentH
            let maxContentW = max(640, visible.maxX - window.frame.minX - chromeW)
            let maxContentH = max(400, window.frame.maxY - visible.minY - chromeH)
            targetContent.width = min(targetContent.width, maxContentW)
            targetContent.height = min(targetContent.height, maxContentH)
        }

        let deltaW = targetContent.width - contentW
        let deltaH = targetContent.height - contentH
        guard deltaW > 0.5 || deltaH > 0.5 else { return }

        var frame = window.frame
        frame.size.width += deltaW
        frame.size.height += deltaH
        frame.origin.y -= deltaH // keep top edge fixed (AppKit y grows upward)
        window.setFrame(frame, display: true, animate: true)
    }

    private func launcherWindow() -> NSWindow? {
        NSApp.windows.first(where: { $0 is LauncherWindow && $0.isVisible })
            ?? NSApp.windows.first(where: { $0 is LauncherWindow })
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

    /// IDs the context menu’s Move / Remove should operate on.
    private func contextMenuTargetIDs(for item: LauncherItem) -> Set<UUID> {
        if store.isSelectingItems, store.selectedItemIDs.contains(item.id) {
            return store.selectedItemIDs
        }
        return [item.id]
    }

    @ViewBuilder
    private func itemContextMenu(_ item: LauncherItem) -> some View {
        if store.isSelectingItems {
            // Keep multi-selection as-is; menu already batches when the tile is in the set.
            selectionModeItemContextMenu(item)
        } else {
            normalItemContextMenu(item)
        }
    }

    @ViewBuilder
    private func selectionModeItemContextMenu(_ item: LauncherItem) -> some View {
        let targets = contextMenuTargetIDs(for: item)
        Menu("Move to Collection") {
            ForEach(store.sortedCollections) { collection in
                Button(collection.name) {
                    store.moveItems(targets, toCollection: collection.id)
                }
                .disabled(collection.id == store.selectedCollection?.id)
            }
        }
        Button("Remove from Collection", role: .destructive) {
            store.removeItems(targets)
        }
    }

    @ViewBuilder
    private func normalItemContextMenu(_ item: LauncherItem) -> some View {
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
        if store.visibleItems.count > 1 {
            Button("Select…") {
                store.enterItemSelection(seeding: [item.id])
            }
        }
        Menu("Layout") {
            Button("Insert Row Above") {
                store.insertEmptyRow(beforeItem: item.id)
            }
            .disabled(!SnapToGrid.canInsertEmptyRow(before: item.gridRow, items: store.visibleItems))
            Button("Insert Column to the Left") {
                store.insertEmptyColumn(beforeItem: item.id)
            }
        }
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
        let title = ItemOpener.draggedWebLink()?.title
        ingestURLs(urls, proposing: dropPoint, linkTitle: title)
    }

    /// ⌘V: same ingest as drop. Prefer the cell under the pointer when it is over the canvas;
    /// otherwise the next free grid cell(s).
    private func pasteFromClipboard() {
        let pasteboard = NSPasteboard.general
        let urls = ItemOpener.urls(from: pasteboard)
        guard !urls.isEmpty else { return }
        let title = ItemOpener.clipboardWebLink()?.title

        if let location = canvasPointUnderMouse() {
            let dropPoint = CGPoint(
                x: max(0, location.x - itemWidth / 2),
                y: max(0, location.y - itemHeight / 2)
            )
            ingestURLs(urls, proposing: dropPoint, linkTitle: title)
            return
        }

        var proposing = SnapToGrid.nextFreePosition(
            items: store.visibleItems,
            settings: store.state.settings,
            canvasSize: canvasSize
        )
        var awaitingOpenChoice: [LauncherItem] = []
        var occupied = store.visibleItems
        for url in urls {
            guard let item = ItemOpener.makeItem(from: url, at: proposing, title: title) else { continue }
            if item.kind == .file || item.kind == .folder {
                awaitingOpenChoice.append(item)
                occupied.append(item)
            } else if item.kind == .url {
                store.addWebLink(item)
                occupied.append(item)
            } else {
                store.addItemFromFinder(item, openWithCursor: false)
                occupied.append(item)
            }
            proposing = SnapToGrid.nextFreePosition(
                items: occupied,
                settings: store.state.settings,
                canvasSize: canvasSize
            )
        }
        if !awaitingOpenChoice.isEmpty {
            pendingDrop = PendingDrop(items: awaitingOpenChoice)
        }
    }

    /// Pointer location in the canvas drop view when it sits over that view; else nil (sidebar / outside).
    private func canvasPointUnderMouse() -> CGPoint? {
        guard let window = NSApp.windows.first(where: { $0 is LauncherWindow && $0.isVisible })
                ?? NSApp.keyWindow,
              let canvas = Self.canvasDropView(in: window.contentView) else {
            return nil
        }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let local = canvas.convert(windowPoint, from: nil)
        guard canvas.bounds.contains(local) else { return nil }
        return local
    }

    private static func canvasDropView(in root: NSView?) -> WindowBackgroundDragNSView? {
        guard let root else { return nil }
        if let drag = root as? WindowBackgroundDragNSView, drag.onURLsDropped != nil {
            return drag
        }
        for child in root.subviews {
            if let found = canvasDropView(in: child) { return found }
        }
        return nil
    }

    private func ingestURLs(_ urls: [URL], proposing dropPoint: CGPoint, linkTitle: String?) {
        var awaitingOpenChoice: [LauncherItem] = []
        for url in urls {
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
