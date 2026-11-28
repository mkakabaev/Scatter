import Foundation

struct AppState: Codable, Equatable {
    var collections: [Collection]
    var settings: Settings

    static let empty = AppState(collections: [], settings: .default)

    struct Collection: Codable, Identifiable, Equatable {
        var id: UUID
        var name: String
        var sortIndex: Int
        var items: [LauncherItem]

        init(id: UUID = UUID(), name: String, sortIndex: Int, items: [LauncherItem] = []) {
            self.id = id
            self.name = name
            self.sortIndex = sortIndex
            self.items = items
        }
    }

    struct Settings: Equatable {
        var backgroundColor: ColorHex
        var iconSize: Double
        var labelSize: Double
        var gridSpacingHorizontal: Double
        var gridSpacingVertical: Double
        var selectedCollectionID: UUID?
        /// Collection panel width. Restored on launch; see `SidebarLayout` for clamps.
        var sidebarWidth: Double
        var windowWidth: Double
        var windowHeight: Double
        /// IANA time zone (`America/Los_Angeles`). `nil` means the system zone — do not inject `TZ`.
        var timeZoneIdentifier: String?
        var launchAtLogin: Bool

        static let `default` = Settings(
            backgroundColor: ColorHex(rawValue: "#F21E1E1E")!,
            iconSize: 64,
            labelSize: 12,
            gridSpacingHorizontal: 6,
            gridSpacingVertical: 2,
            selectedCollectionID: nil,
            sidebarWidth: SidebarLayout.defaultWidth,
            windowWidth: 1042,
            windowHeight: 655,
            timeZoneIdentifier: nil,
            launchAtLogin: false
        )
    }
}

extension AppState.Settings: Codable {
    enum CodingKeys: String, CodingKey {
        case backgroundColor, iconSize, labelSize
        case gridSpacingHorizontal, gridSpacingVertical
        case selectedCollectionID, sidebarWidth, windowWidth, windowHeight
        case timeZoneIdentifier, launchAtLogin
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        backgroundColor = try c.decodeIfPresent(ColorHex.self, forKey: .backgroundColor)
            ?? Self.default.backgroundColor
        iconSize = (try c.decodeIfPresent(Double.self, forKey: .iconSize) ?? Self.default.iconSize).rounded()
        labelSize = (try c.decodeIfPresent(Double.self, forKey: .labelSize) ?? Self.default.labelSize).rounded()
        gridSpacingHorizontal = (try c.decodeIfPresent(Double.self, forKey: .gridSpacingHorizontal)
            ?? Self.default.gridSpacingHorizontal).rounded()
        gridSpacingVertical = (try c.decodeIfPresent(Double.self, forKey: .gridSpacingVertical)
            ?? Self.default.gridSpacingVertical).rounded()
        selectedCollectionID = try c.decodeIfPresent(UUID.self, forKey: .selectedCollectionID)
        sidebarWidth = try c.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? Self.default.sidebarWidth
        windowWidth = try c.decodeIfPresent(Double.self, forKey: .windowWidth) ?? Self.default.windowWidth
        windowHeight = try c.decodeIfPresent(Double.self, forKey: .windowHeight) ?? Self.default.windowHeight
        timeZoneIdentifier = try c.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(backgroundColor, forKey: .backgroundColor)
        try c.encode(iconSize, forKey: .iconSize)
        try c.encode(labelSize, forKey: .labelSize)
        try c.encode(gridSpacingHorizontal, forKey: .gridSpacingHorizontal)
        try c.encode(gridSpacingVertical, forKey: .gridSpacingVertical)
        try c.encodeIfPresent(selectedCollectionID, forKey: .selectedCollectionID)
        try c.encode(sidebarWidth, forKey: .sidebarWidth)
        try c.encode(windowWidth, forKey: .windowWidth)
        try c.encode(windowHeight, forKey: .windowHeight)
        try c.encodeIfPresent(timeZoneIdentifier, forKey: .timeZoneIdentifier)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
    }
}
