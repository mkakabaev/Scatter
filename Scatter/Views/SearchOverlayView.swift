import SwiftUI
import AppKit

struct SearchOverlayView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.colorScheme) private var colorScheme

    private let cornerRadius: CGFloat = 24

    var body: some View {
        ZStack {
            Color.black.opacity(colorScheme == .dark ? 0.45 : 0.22)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { store.clearSearch() }

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.secondary)
                    SearchTextField(
                        text: Binding(
                            get: { store.searchQuery },
                            set: { store.setSearchQuery($0) }
                        ),
                        onSubmit: openSelected
                    )
                    .frame(height: 30)
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 14)

                Divider()
                    .opacity(0.55)

                if store.searchResults.isEmpty {
                    Text(emptyMessage)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(store.searchResults) { hit in
                                    SearchResultRow(
                                        hit: hit,
                                        isSelected: store.searchSelectedItemID == hit.item.id
                                    )
                                    .id(hit.item.id)
                                    .onTapGesture { open(hit) }
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                        }
                        .onChange(of: store.searchSelectedItemID) { _, newID in
                            guard let newID else { return }
                            withAnimation(.easeOut(duration: 0.12)) {
                                proxy.scrollTo(newID, anchor: .center)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 560, maxHeight: 440)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.22), radius: 28, y: 12)
            .padding(28)
        }
    }

    private var borderColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color.black.opacity(0.08)
    }

    private var emptyMessage: String {
        let q = store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? "Type to search" : "No matches for “\(q)”"
    }

    private func openSelected() {
        guard let id = store.searchSelectedItemID,
              let hit = store.searchResults.first(where: { $0.item.id == id }) else { return }
        open(hit)
    }

    private func open(_ hit: SearchHit) {
        let flags = NSEvent.modifierFlags
        let keepOpen = flags.contains(.option)
        if flags.contains(.command) {
            ItemOpener.reveal(hit.item, keepWindowOpen: keepOpen, store: store)
        } else {
            ItemOpener.open(hit.item, settings: store.state.settings, keepWindowOpen: keepOpen, store: store)
        }
        if !keepOpen {
            store.clearSearch()
        }
    }
}

private struct SearchResultRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let hit: SearchHit
    let isSelected: Bool

    private let iconSize: CGFloat = 48

    var body: some View {
        HStack(spacing: 12) {
            LauncherItemIconView(item: hit.item, size: iconSize, showsShadow: false)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(iconPlate)
                        .padding(-4)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.item.displayName)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selectionFill)
        )
        .contentShape(Rectangle())
    }

    /// Collection name; for URL items append ` • {url}`.
    private var subtitle: String {
        guard hit.item.kind == .url else { return hit.collectionName }
        let url = hit.item.urlString ?? ItemURLResolver.resolve(hit.item)?.absoluteString
        guard let url, !url.isEmpty else { return hit.collectionName }
        return "\(hit.collectionName) • \(url)"
    }

    private var selectionFill: Color {
        guard isSelected else { return .clear }
        return Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.08)
    }

    private var iconPlate: Color {
        hit.item.backgroundColor?.color ?? .clear
    }
}

/// Plain AppKit field: caret at end, never selects the whole query on focus.
private struct SearchTextField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void

    private static let fontSize: CGFloat = 24

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> SearchNSTextField {
        let field = SearchNSTextField(string: text)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        Self.applyChrome(to: field)
        DispatchQueue.main.async {
            context.coordinator.focusCaretAtEnd(in: field)
        }
        return field
    }

    func updateNSView(_ field: SearchNSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        Self.applyChrome(to: field)
        guard field.stringValue != text else { return }
        field.stringValue = text
        let end = NSRange(location: text.utf16.count, length: 0)
        field.currentEditor()?.selectedRange = end
    }

    private static func applyChrome(to field: SearchNSTextField) {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        field.font = font
        field.textColor = .labelColor
        field.placeholderAttributedString = NSAttributedString(
            string: "Search all collections",
            attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: font
            ]
        )
        if let editor = field.currentEditor() as? NSTextView {
            FieldEditorStyle.apply(editor)
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

        func focusCaretAtEnd(in field: SearchNSTextField) {
            guard let window = field.window else { return }
            window.makeFirstResponder(field)
        }
    }
}
