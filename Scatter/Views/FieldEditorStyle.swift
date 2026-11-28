import AppKit

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
