import Carbon
import Foundation

/// Physical-key remapping between English QWERTY and macOS Russian (ЙЦУКЕН, ISO).
/// Used so type-to-search matches when the wrong layout was active while typing.
enum SearchLayoutTranslit {
    /// When query length > 1 and a Russian keyboard input source is installed, returns
    /// the original query plus the EN↔RU layout alternate (same physical keys).
    static func matchQueries(for trimmedLowercasedQuery: String) -> [String] {
        guard trimmedLowercasedQuery.count > 1, isRussianInputInstalled else {
            return [trimmedLowercasedQuery]
        }
        let alternate = remap(trimmedLowercasedQuery)
        if alternate == trimmedLowercasedQuery {
            return [trimmedLowercasedQuery]
        }
        return [trimmedLowercasedQuery, alternate]
    }

    // MARK: - Detection

    /// True if any Russian keyboard layout / input source is installed (enabled or not).
    static var isRussianInputInstalled: Bool {
        if let cached = cachedRussianInstalled { return cached }
        let value = detectRussianInputInstalled()
        cachedRussianInstalled = value
        return value
    }

    /// Call if input sources may have changed (e.g. user added Russian mid-session).
    static func invalidateInstallationCache() {
        cachedRussianInstalled = nil
    }

    private static var cachedRussianInstalled: Bool?

    private static func detectRussianInputInstalled() -> Bool {
        if sourcesContainRussian(includeAllInstalled: false) { return true }
        return sourcesContainRussian(includeAllInstalled: true)
    }

    private static func sourcesContainRussian(includeAllInstalled: Bool) -> Bool {
        guard let cfList = TISCreateInputSourceList(nil, includeAllInstalled),
              let sources = cfList.takeRetainedValue() as? [TISInputSource]
        else { return false }

        for source in sources {
            if let opaque = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
                let id = Unmanaged<CFString>.fromOpaque(opaque).takeUnretainedValue() as String
                // com.apple.keylayout.Russian, RussianWin, Russian-Phonetic, Russian-ISO, …
                if id.localizedCaseInsensitiveContains("russian") { return true }
            }
            if let opaque = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) {
                let languages = Unmanaged<CFArray>.fromOpaque(opaque).takeUnretainedValue() as? [String] ?? []
                if languages.contains(where: { $0 == "ru" || $0.hasPrefix("ru-") }) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Remap

    /// Convert a string typed on one layout into the characters the same physical keys
    /// produce on the other. Direction: Cyrillic present → RU→EN; otherwise EN→RU.
    static func remap(_ string: String) -> String {
        let toEnglish = string.contains(where: \.isCyrillic)
        let table = toEnglish ? ruToEn : enToRu
        return String(string.map { table[$0] ?? $0 })
    }

    /// Same physical keys: English QWERTY ↔ macOS Russian ЙЦУКЕН (ISO letter rows).
    private static let layoutPairs: [(Character, Character)] = [
        ("`", "ё"),
        ("q", "й"), ("w", "ц"), ("e", "у"), ("r", "к"), ("t", "е"),
        ("y", "н"), ("u", "г"), ("i", "ш"), ("o", "щ"), ("p", "з"),
        ("[", "х"), ("]", "ъ"),
        ("a", "ф"), ("s", "ы"), ("d", "в"), ("f", "а"), ("g", "п"),
        ("h", "р"), ("j", "о"), ("k", "л"), ("l", "д"), (";", "ж"),
        ("'", "э"),
        ("z", "я"), ("x", "ч"), ("c", "с"), ("v", "м"), ("b", "и"),
        ("n", "т"), ("m", "ь"), (",", "б"), (".", "ю"), ("/", "."),
    ]

    private static let enToRu: [Character: Character] = Dictionary(uniqueKeysWithValues: layoutPairs)
    private static let ruToEn: [Character: Character] = Dictionary(uniqueKeysWithValues: layoutPairs.map { ($0.1, $0.0) })
}

private extension Character {
    var isCyrillic: Bool {
        unicodeScalars.contains { scalar in
            (0x0400...0x04FF).contains(scalar.value) // Cyrillic block
        }
    }
}
