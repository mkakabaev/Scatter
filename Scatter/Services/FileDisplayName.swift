import Foundation

/// Finder-style label for an on-disk path or file URL (strips a trailing `.app`).
enum FileDisplayName {
    static func of(_ url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        guard name.lowercased().hasSuffix(".app") else { return name }
        return String(name.dropLast(4))
    }
}
