import Foundation
import CoreGraphics

struct LauncherItem: Codable, Identifiable, Equatable {

    enum Kind: String, Codable {
        case app
        case file
        case folder
        case url

        /// Files and folders get the Finder-drop Open With confirmation; apps and URLs do not.
        var offersOpenWithOnDrop: Bool {
            self == .file || self == .folder
        }

        var missingTargetMessage: String {
            switch self {
            case .folder:
                return "This folder no longer exists."
            case .file:
                return "This file no longer exists."
            case .app:
                return "This application no longer exists."
            case .url:
                return "The item’s location could not be resolved."
            }
        }
    }

    /// Named tile-background swatches. 
    enum BackgroundSwatch: String, CaseIterable, Identifiable {
        case red, orange, gold, green, teal, blue, purple, pink, slate

        var id: String { rawValue }

        var name: String {
            switch self {
            case .red: return "Red"
            case .orange: return "Orange"
            case .gold: return "Gold"
            case .green: return "Green"
            case .teal: return "Teal"
            case .blue: return "Blue"
            case .purple: return "Purple"
            case .pink: return "Pink"
            case .slate: return "Slate"
            }
        }

        /// Dark enough that the white item title stays readable on the tile.
        var color: ColorHex {
            switch self {
            case .red: return ColorHex(rawValue: "#9E2B2B")!
            case .orange: return ColorHex(rawValue: "#A85B12")!
            case .gold: return ColorHex(rawValue: "#7A5E12")!
            case .green: return ColorHex(rawValue: "#1E7A45")!
            case .teal: return ColorHex(rawValue: "#0E6E74")!
            case .blue: return ColorHex(rawValue: "#2458A6")!
            case .purple: return ColorHex(rawValue: "#5C3D8A")!
            case .pink: return ColorHex(rawValue: "#9A3D66")!
            case .slate: return ColorHex(rawValue: "#4A5160")!
            }
        }

        init?(color: ColorHex) {
            guard let match = Self.allCases.first(where: { $0.color == color }) else { return nil }
            self = match
        }
    }

    struct CodablePoint: Codable, Equatable {
        var x: Double
        var y: Double

        var cgPoint: CGPoint { CGPoint(x: x, y: y) }

        init(_ point: CGPoint) {
            x = point.x
            y = point.y
        }
    }

    var id: UUID
    var kind: Kind
    var bookmarkData: Data?
    var urlString: String?
    var displayName: String
    var position: CodablePoint
    /// Stable grid coordinates. Absolute `position` is derived from these + empty-row compression.
    var gridColumn: Int
    var gridRow: Int
    var openWithBookmarkData: Data?
    var openWithBundleIdentifier: String?
    var backgroundColor: ColorHex?
    var applyTimeZone: Bool
    /// In-memory favicon PNG for a URL item (`nil` = generic HTML icon).
    /// Persisted as `icons/<id>.png` via `ItemIconStore` — not written into `state.json`.
    var iconPNGData: Data?

    init(
        id: UUID = UUID(),
        kind: Kind,
        bookmarkData: Data? = nil,
        urlString: String? = nil,
        displayName: String,
        position: CodablePoint,
        gridColumn: Int = 0,
        gridRow: Int = 0,
        openWithBookmarkData: Data? = nil,
        openWithBundleIdentifier: String? = nil,
        backgroundColor: ColorHex? = nil,
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
        self.backgroundColor = backgroundColor
        self.applyTimeZone = applyTimeZone
        self.iconPNGData = iconPNGData
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, bookmarkData, urlString, displayName, position
        case gridColumn, gridRow
        case openWithBookmarkData, openWithBundleIdentifier
        case backgroundColor, applyTimeZone
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        bookmarkData = try c.decodeIfPresent(Data.self, forKey: .bookmarkData)
        urlString = try c.decodeIfPresent(String.self, forKey: .urlString)
        displayName = try c.decode(String.self, forKey: .displayName)
        position = try c.decode(CodablePoint.self, forKey: .position)
        gridColumn = try c.decodeIfPresent(Int.self, forKey: .gridColumn) ?? 0
        gridRow = try c.decodeIfPresent(Int.self, forKey: .gridRow) ?? 0
        openWithBookmarkData = try c.decodeIfPresent(Data.self, forKey: .openWithBookmarkData)
        openWithBundleIdentifier = try c.decodeIfPresent(String.self, forKey: .openWithBundleIdentifier)
        backgroundColor = try c.decodeIfPresent(ColorHex.self, forKey: .backgroundColor)
        applyTimeZone = try c.decodeIfPresent(Bool.self, forKey: .applyTimeZone) ?? false
        iconPNGData = nil
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
        try c.encodeIfPresent(backgroundColor, forKey: .backgroundColor)
        if applyTimeZone {
            try c.encode(true, forKey: .applyTimeZone)
        }
    }

    var hasOpenWith: Bool {
        openWithBundleIdentifier != nil || openWithBookmarkData != nil
    }

    /// Open With is for files, folders, and URLs — never apps.
    var supportsOpenWith: Bool { kind != .app }
}
