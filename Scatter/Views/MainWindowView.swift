import SwiftUI
import AppKit

struct MainWindowView: View {
    @EnvironmentObject private var store: AppStore
    @State private var renameText: String = ""
    @State private var isRenaming = false
    @State private var newCollectionName = ""
    @State private var showNewCollection = false
    /// Live splitter width while dragging. Nil uses the saved preference.
    @State private var sidebarWidthOverride: Double?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(nsColor: NSColor(hex: store.state.settings.backgroundColorHex) ?? .black)

            GeometryReader { geo in
                let width = sidebarWidth(in: geo.size.width)
                HStack(spacing: 0) {
                    CollectionSidebar(
                        onRequestNew: { showNewCollection = true },
                        onRequestRename: { collection in
                            renameText = collection.name
                            isRenaming = true
                        }
                    )
                    .frame(width: width)

                    SidebarSplitter(
                        width: width,
                        containerWidth: geo.size.width,
                        onChange: { sidebarWidthOverride = $0 },
                        onEnd: { final in
                            store.updateSettings { $0.sidebarWidth = final }
                            sidebarWidthOverride = nil
                        }
                    )
                    .frame(width: CGFloat(SidebarLayout.splitterThickness))
                    .frame(maxHeight: .infinity)

                    FreeformCanvasView()
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }

            // Flush with window top-trailing (opposite traffic lights).
            Button {
                store.requestSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings")
            .padding(.top, 6)
            .padding(.trailing, 8)
            .opacity(store.isSearching ? 0.35 : 1)

            if store.isSearching {
                SearchOverlayView()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(.easeOut(duration: 0.12), value: store.isSearching)
        .ignoresSafeArea(edges: .top)
        .frame(minWidth: 640, minHeight: 400)
        .background(KeyMonitor(handler: handleKey))
        .alert(
            store.openFailure.map { "Couldn’t Open \($0.itemName)" } ?? "Couldn’t Open Item",
            isPresented: Binding(
                get: { store.openFailure != nil },
                set: { if !$0 { store.clearOpenFailure() } }
            )
        ) {
            Button("OK", role: .cancel) { store.clearOpenFailure() }
            if let command = store.openFailure?.recoveryCommand {
                Button("Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    store.clearOpenFailure()
                }
            }
        } message: {
            Text(store.openFailure?.message ?? "")
        }
        .alert("New Collection", isPresented: $showNewCollection) {
            TextField("Name", text: $newCollectionName)
            Button("Cancel", role: .cancel) { newCollectionName = "" }
            Button("Create") {
                let name = newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { store.addCollection(named: name) }
                newCollectionName = ""
            }
        }
        .alert("Rename Collection", isPresented: $isRenaming) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let id = store.selectedCollection?.id {
                    let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { store.renameCollection(id, to: name) }
                }
            }
        }
        .focusable()
    }

    private func sidebarWidth(in containerWidth: CGFloat) -> CGFloat {
        let stored = sidebarWidthOverride ?? store.state.settings.sidebarWidth
        return CGFloat(SidebarLayout.clamped(stored, containerWidth: Double(containerWidth)))
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard store.isMainWindowVisible else { return event }

        // The system eyedropper must receive Escape (cancel) and the sample click.
        if store.isSamplingItemBackground {
            return event
        }

        // While searching, let the TextField handle normal typing; only intercept navigation / escape / return.
        // (Must run before the text-editing bypass — search field is an NSTextField.)
        if store.isSearching {
            return handleSearchKey(event)
        }

        // Alerts (Rename / New Collection) and other text fields must keep arrows, Return, Escape, typing.
        if Self.isEditingText() {
            return event
        }

        if store.backgroundPickerItemID != nil {
            if event.keyCode == 53 { // escape — close the palette, keep the window
                store.backgroundPickerItemID = nil
                return nil
            }
            if event.modifierFlags.contains(.command) {
                return event
            }
            return nil
        }

        if event.modifierFlags.contains(.command) {
            if event.keyCode == 126 { // up
                store.selectAdjacentCollection(delta: -1)
                return nil
            }
            if event.keyCode == 125 { // down
                store.selectAdjacentCollection(delta: 1)
                return nil
            }
            if let chars = event.charactersIgnoringModifiers {
                if chars == "," {
                    store.requestSettings()
                    return nil
                }
                if let number = Int(chars), (1...9).contains(number) {
                    store.selectCollection(index: number - 1)
                    return nil
                }
            }
        }

        switch event.keyCode {
        case 53: // escape
            store.hideMainWindow()
            return nil
        case 36, 76: // return
            if let id = store.selectedItemID, let item = store.findItem(id) {
                ItemOpener.open(item, settings: store.state.settings, keepWindowOpen: false, store: store)
            }
            return nil
        case 123, 124, 125, 126: // arrows — canvas neighbor selection
            moveCanvasSelection(keyCode: event.keyCode)
            return nil
        case 51: // delete — start/continue search via backspace only if already searching
            return event
        default:
            break
        }

        // Type-to-search: first character opens the global search overlay.
        if let chars = event.charactersIgnoringModifiers, chars.count == 1,
           let ch = chars.first,
           !event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.option),
           !event.modifierFlags.contains(.control) {
            if ch.isLetter || ch.isNumber || ch == " " || ch == "." || ch == "-" || ch == "_" {
                store.appendTypedCharacter(ch)
                return nil
            }
        }
        return event
    }

    private func handleSearchKey(_ event: NSEvent) -> NSEvent? {
        switch event.keyCode {
        case 53: // escape — dismiss search first
            store.clearSearch()
            return nil
        case 36, 76: // return — open selected hit (TextField onSubmit also handles this)
            if let id = store.selectedItemID,
               let hit = store.searchResults.first(where: { $0.item.id == id }) {
                let keepOpen = event.modifierFlags.contains(.option)
                if event.modifierFlags.contains(.command) {
                    ItemOpener.reveal(hit.item, keepWindowOpen: keepOpen, store: store)
                } else {
                    ItemOpener.open(hit.item, settings: store.state.settings, keepWindowOpen: keepOpen, store: store)
                }
                if !keepOpen { store.clearSearch() }
                return nil
            }
            return event
        case 125: // down
            store.selectAdjacentSearchResult(delta: 1)
            return nil
        case 126: // up
            store.selectAdjacentSearchResult(delta: -1)
            return nil
        case 51: // delete/backspace — let TextField handle when focused; also sync via Binding
            return event
        default:
            // Let TextField receive typing / paste / etc.
            return event
        }
    }

    /// True when an alert TextField / field editor (or any NSText*) is first responder.
    private static func isEditingText() -> Bool {
        let responder = NSApp.keyWindow?.firstResponder
        return responder is NSTextView || responder is NSTextField
    }

    private func moveCanvasSelection(keyCode: UInt16) {
        let items = store.visibleItems
        guard !items.isEmpty else { return }
        let current = items.first(where: { $0.id == store.selectedItemID }) ?? items[0]
        let target: LauncherItem?
        switch keyCode {
        case 123: // left
            target = nearest(from: current, in: items) { $0.position.x < current.position.x && abs($0.position.y - current.position.y) < abs($0.position.x - current.position.x) * 2 }
        case 124: // right
            target = nearest(from: current, in: items) { $0.position.x > current.position.x && abs($0.position.y - current.position.y) < abs($0.position.x - current.position.x) * 2 }
        case 125: // down
            target = nearest(from: current, in: items) { $0.position.y > current.position.y && abs($0.position.x - current.position.x) < abs($0.position.y - current.position.y) * 2 }
        case 126: // up
            target = nearest(from: current, in: items) { $0.position.y < current.position.y && abs($0.position.x - current.position.x) < abs($0.position.y - current.position.y) * 2 }
        default:
            target = nil
        }
        if let target {
            store.selectedItemID = target.id
        }
    }

    private func nearest(from current: LauncherItem, in items: [LauncherItem], filter: (LauncherItem) -> Bool) -> LauncherItem? {
        items
            .filter { $0.id != current.id && filter($0) }
            .min { a, b in
                hypot(a.position.x - current.position.x, a.position.y - current.position.y)
                    < hypot(b.position.x - current.position.x, b.position.y - current.position.y)
            }
    }
}

/// Hairline between the collection panel and the canvas. Hit target is wider than the line.
/// Tracking uses AppKit so live width updates do not cancel the drag.
private struct SidebarSplitter: NSViewRepresentable {
    var width: CGFloat
    var containerWidth: CGFloat
    var onChange: (Double) -> Void
    var onEnd: (Double) -> Void

    func makeNSView(context: Context) -> SidebarSplitterView {
        SidebarSplitterView()
    }

    func updateNSView(_ view: SidebarSplitterView, context: Context) {
        view.currentWidth = width
        view.containerWidth = containerWidth
        view.onChange = onChange
        view.onEnd = onEnd
    }
}

private final class SidebarSplitterView: NSView {
    var currentWidth: CGFloat = SidebarLayout.defaultWidth
    var containerWidth: CGFloat = 900
    var onChange: ((Double) -> Void)?
    var onEnd: ((Double) -> Void)?

    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let startX = event.locationInWindow.x
        let startWidth = currentWidth
        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: NSEvent.foreverDuration,
            mode: .eventTracking
        ) { event, stop in
            guard let event else { return }
            let next = SidebarLayout.clamped(
                Double(startWidth + (event.locationInWindow.x - startX)),
                containerWidth: Double(self.containerWidth)
            )
            if event.type == .leftMouseUp {
                self.onEnd?(next)
                stop.pointee = true
            } else {
                self.onChange?(next)
            }
        }
    }
}
