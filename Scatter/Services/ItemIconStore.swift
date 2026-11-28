import Foundation

/// Favicon PNGs live beside `state.json` as `icons/<itemID>.png` — not inline in JSON.
enum ItemIconStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(AppIdentity.applicationSupportFolderName, isDirectory: true)
            .appendingPathComponent("icons", isDirectory: true)
    }

    static func fileURL(for itemID: UUID) -> URL {
        directory.appendingPathComponent("\(itemID.uuidString).png", isDirectory: false)
    }

    static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func load(itemID: UUID) -> Data? {
        try? Data(contentsOf: fileURL(for: itemID))
    }

    @discardableResult
    static func save(itemID: UUID, pngData: Data) -> Bool {
        ensureDirectory()
        do {
            try pngData.write(to: fileURL(for: itemID), options: [.atomic])
            return true
        } catch {
            NSLog("\(AppIdentity.displayName) favicon save failed (\(itemID.uuidString)): \(error)")
            return false
        }
    }

    static func remove(itemIDs: Set<UUID>) {
        guard !itemIDs.isEmpty else { return }
        let fm = FileManager.default
        for id in itemIDs {
            try? fm.removeItem(at: fileURL(for: id))
        }
    }
}
