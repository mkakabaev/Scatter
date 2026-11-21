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
                                        isSelected: store.selectedItemID == hit.item.id
                                    )
                                    .id(hit.item.id)
                                    .onTapGesture { open(hit) }
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
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
                Text(hit.collectionName)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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

    private var selectionFill: Color {
        guard isSelected else { return .clear }
        return Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.08)
    }

    private var iconPlate: Color {
        guard let hex = hit.item.backgroundColorHex,
              let color = ItemBackgroundPicker.color(hex: hex) else { return .clear }
        return color
    }
}

/// Shared field-editor chrome: clear, no spelling/completion UI (avoids frosted glass flash).
enum FieldEditorStyle {
    static func apply(_ editor: NSTextView) {
        editor.isFieldEditor = true
        editor.drawsBackground = false
        editor.backgroundColor = .clear
        editor.insertionPointColor = .labelColor
        editor.isRichText = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        if #available(macOS 14.0, *) {
            editor.isAutomaticTextCompletionEnabled = false
        }
        if let scroll = editor.enclosingScrollView {
            scroll.drawsBackground = false
            scroll.backgroundColor = .clear
            scroll.contentView.drawsBackground = false
            scroll.contentInsets = .init()
            scroll.scrollerInsets = .init()
        }
    }

    /// Attach/create the field editor once while `window` is still off-screen.
    static func warm(in window: NSWindow) {
        let probe = SearchNSTextField(frame: NSRect(x: -10_000, y: -10_000, width: 200, height: 30))
        probe.isBordered = false
        probe.isBezeled = false
        probe.drawsBackground = false
        probe.focusRingType = .none
        probe.stringValue = " "
        window.contentView?.addSubview(probe)
        if let editor = window.fieldEditor(true, for: probe) as? NSTextView {
            apply(editor)
        }
        window.makeFirstResponder(probe)
        if let editor = probe.currentEditor() as? NSTextView {
            apply(editor)
        }
        window.makeFirstResponder(nil)
        probe.removeFromSuperview()
    }
}

/// Borderless search field; sanitizes the shared field editor before it can paint glass chrome.
final class SearchNSTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        if let window, let editor = window.fieldEditor(true, for: self) as? NSTextView {
            FieldEditorStyle.apply(editor)
        }
        let ok = super.becomeFirstResponder()
        if let editor = currentEditor() as? NSTextView {
            FieldEditorStyle.apply(editor)
        }
        let end = NSRange(location: stringValue.utf16.count, length: 0)
        currentEditor()?.selectedRange = end
        return ok
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
