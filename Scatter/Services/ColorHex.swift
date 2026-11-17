import AppKit

extension NSColor {
    convenience init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6 || cleaned.count == 8 else { return nil }
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let a, r, g, b: Double
        if cleaned.count == 8 {
            a = Double((value & 0xFF000000) >> 24) / 255
            r = Double((value & 0x00FF0000) >> 16) / 255
            g = Double((value & 0x0000FF00) >> 8) / 255
            b = Double(value & 0x000000FF) / 255
        } else {
            a = 1
            r = Double((value & 0xFF0000) >> 16) / 255
            g = Double((value & 0x00FF00) >> 8) / 255
            b = Double(value & 0x0000FF) / 255
        }
        self.init(calibratedRed: r, green: g, blue: b, alpha: a)
    }

    /// Opaque colors stay `#RRGGBB` (swatch-friendly). Translucent colors use `#AARRGGBB`.
    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#1E1E1E" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        let a = Int(round(rgb.alphaComponent * 255))
        if a < 255 {
            return String(format: "#%02X%02X%02X%02X", a, r, g, b)
        }
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Black text contrasts better than white above this sRGB relative luminance.
    var isLightBackground: Bool {
        guard let rgb = usingColorSpace(.sRGB) else { return false }
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(rgb.redComponent)
            + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
        return luminance > 0.179
    }
}
