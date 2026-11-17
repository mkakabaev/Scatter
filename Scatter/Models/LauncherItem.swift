import Foundation
import CoreGraphics

enum ItemKind: String, Codable, CaseIterable {
    case app
    case file
    case folder
    case url
}

struct SearchHit: Identifiable, Equatable {
    var id: UUID { item.id }
    var item: LauncherItem
    var collectionID: UUID
    var collectionName: String
}

struct CodablePoint: Codable, Equatable {
    var x: Double
    var y: Double

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

struct LauncherItem: Codable, Identifiable, Equatable {
    var id: UUID
    var kind: ItemKind
    var bookmarkData: Data?
    var urlString: String?
    var displayName: String
    var position: CodablePoint
    /// Stable grid coordinates. Absolute `position` is derived from these + empty-row compression.
    var gridColumn: Int
    var gridRow: Int
    var openWithBookmarkData: Data?
    var openWithBundleIdentifier: String?
    /// Tile fill. `nil` leaves the tile clear. Palette swatches or any `#RRGGBB` from the screen sampler.
    var backgroundColorHex: String?
    /// When true, launch injects `TZ` from Preferences. Default off.
    var applyTimeZone: Bool
    /// Favicon PNG for a URL item. `nil` uses the generic HTML icon.
    var iconPNGData: Data?

    init(
        id: UUID = UUID(),
        kind: ItemKind,
        bookmarkData: Data? = nil,
        urlString: String? = nil,
        displayName: String,
        position: CodablePoint,
        gridColumn: Int = 0,
        gridRow: Int = 0,
        openWithBookmarkData: Data? = nil,
        openWithBundleIdentifier: String? = nil,
        backgroundColorHex: String? = nil,
        applyTimeZone: Bool = false,
        iconPNGData: Data? = nil
    ) {
        self.id = id
        self.kind = kind
        self.bookmarkData = bookmarkData
        self.urlString = urlString
        self.displayName = displayName
        self.position = position
        self.gridColumn = gridColumn
        self.gridRow = gridRow
        self.openWithBookmarkData = openWithBookmarkData
        self.openWithBundleIdentifier = openWithBundleIdentifier
        self.backgroundColorHex = backgroundColorHex
        self.applyTimeZone = applyTimeZone
        self.iconPNGData = iconPNGData
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, bookmarkData, urlString, displayName, position
        case gridColumn, gridRow
        case openWithBookmarkData, openWithBundleIdentifier
        case backgroundColorHex, applyTimeZone, iconPNGData
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(ItemKind.self, forKey: .kind)
        bookmarkData = try c.decodeIfPresent(Data.self, forKey: .bookmarkData)
        urlString = try c.decodeIfPresent(String.self, forKey: .urlString)
        displayName = try c.decode(String.self, forKey: .displayName)
        position = try c.decode(CodablePoint.self, forKey: .position)
        gridColumn = try c.decodeIfPresent(Int.self, forKey: .gridColumn) ?? 0
        gridRow = try c.decodeIfPresent(Int.self, forKey: .gridRow) ?? 0
        openWithBookmarkData = try c.decodeIfPresent(Data.self, forKey: .openWithBookmarkData)
        openWithBundleIdentifier = try c.decodeIfPresent(String.self, forKey: .openWithBundleIdentifier)
        backgroundColorHex = try c.decodeIfPresent(String.self, forKey: .backgroundColorHex)
        applyTimeZone = try c.decodeIfPresent(Bool.self, forKey: .applyTimeZone) ?? false
        iconPNGData = try c.decodeIfPresent(Data.self, forKey: .iconPNGData)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(bookmarkData, forKey: .bookmarkData)
        try c.encodeIfPresent(urlString, forKey: .urlString)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(position, forKey: .position)
        try c.encode(gridColumn, forKey: .gridColumn)
        try c.encode(gridRow, forKey: .gridRow)
        try c.encodeIfPresent(openWithBookmarkData, forKey: .openWithBookmarkData)
        try c.encodeIfPresent(openWithBundleIdentifier, forKey: .openWithBundleIdentifier)
        try c.encodeIfPresent(backgroundColorHex, forKey: .backgroundColorHex)
        if applyTimeZone {
            try c.encode(true, forKey: .applyTimeZone)
        }
        try c.encodeIfPresent(iconPNGData, forKey: .iconPNGData)
    }

    func resolvedURL() -> URL? {
        // Prefer plain path/URL string first (launch-only; no security-scope access).
        if let urlString {
            if urlString.hasPrefix("/"), FileManager.default.fileExists(atPath: urlString) {
                return URL(fileURLWithPath: urlString)
            }
            if let url = URL(string: urlString) {
                if url.isFileURL, FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
                if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                    return url
                }
                if url.isFileURL {
                    return url
                }
            }
            // file URL may have been percent-encoded; try as path
            if urlString.hasPrefix("file:"), let url = URL(string: urlString) {
                return url
            }
        }
        if let bookmarkData {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url
            }
        }
        return nil
    }
}
