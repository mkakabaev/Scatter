import SwiftUI
import AppKit

struct SearchOverlayView: View {
    @EnvironmentObject private var store: AppStore

    private let cornerRadius: CGFloat = 12
    private let panelFill = Color(nsColor: NSColor(calibratedWhite: 0.28, alpha: 0.98))

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { store.clearSearch() }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.white.opacity(0.55))
                    SearchTextField(
                        text: Binding(
                            get: { store.searchQuery },
                            set: { store.setSearchQuery($0) }
                        ),
                        onSubmit: openSelected
                    )
                    .frame(height: 22)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.06))

                Divider().background(Color.white.opacity(0.14))

                if store.searchResults.isEmpty {
                    Text(emptyMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(store.searchResults) { hit in
                                    SearchResultRow(
                                        hit: hit,
                                        isSelected: store.selectedItemID == hit.item.id
                                    )
                                    .id(hit.item.id)
                                    .onTapGesture { open(hit) }
                                }
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 4)
                        }
                        .onChange(of: store.selectedItemID) { _, newID in
                            guard let newID else { return }
                            withAnimation(.easeOut(duration: 0.12)) {
                                proxy.scrollTo(newID, anchor: .center)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 520, maxHeight: 420)
            .background(panelFill)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
            .padding(28)
        }
    }

    private var emptyMessage: String {
        let q = store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? "Type to search" : "No matches for “\(q)”"
    }

    private func openSelected() {
        guard let id = store.selectedItemID,
              let hit = store.searchResults.first(where: { $0.item.id == id }) else { return }
        open(hit)
    }

    private func open(_ hit: SearchHit) {
        let flags = NSEvent.modifierFlags
        let keepOpen = flags.contains(.option)
        if flags.contains(.command) {
            ItemOpener.reveal(hit.item, keepWindowOpen: keepOpen, store: store)
        } else {
            ItemOpener.open(hit.item, preferences: store.state.preferences, keepWindowOpen: keepOpen, store: store)
        }
        if !keepOpen {
            store.clearSearch()
        }
    }
}

private struct SearchResultRow: View {
    let hit: SearchHit
    let isSelected: Bool

    private let iconSize: CGFloat = 48

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: IconProvider.icon(for: hit.item, size: iconSize))
                .resizable()
                .interpolation(.high)
                .frame(width: iconSize, height: iconSize)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(iconPlate)
                        .padding(-4)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.item.displayName)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                Text(hit.collectionName)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.35) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private var iconPlate: Color {
        guard let hex = hit.item.backgroundColorHex,
              let color = ItemBackgroundPicker.color(hex: hex) else { return .clear }
        return color
    }
}

/// Plain AppKit field: caret at end, never selects the whole query on focus.
private struct SearchTextField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 16)
        field.textColor = .white
        field.placeholderString = "Search all collections"
        field.delegate = context.coordinator
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        DispatchQueue.main.async {
            context.coordinator.focusCaretAtEnd(in: field)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        if field.stringValue != text {
            field.stringValue = text
            context.coordinator.focusCaretAtEnd(in: field)
        } else if field.window?.firstResponder !== field.currentEditor() {
            DispatchQueue.main.async {
                context.coordinator.focusCaretAtEnd(in: field)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit()
                return true
            }
            return false
        }

        func focusCaretAtEnd(in field: NSTextField) {
            field.window?.makeFirstResponder(field)
            let end = NSRange(location: field.stringValue.utf16.count, length: 0)
            field.currentEditor()?.selectedRange = end
        }
    }
}
