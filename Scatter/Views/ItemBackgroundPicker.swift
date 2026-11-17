import SwiftUI
import AppKit

enum ItemBackgroundPalette {
    struct Swatch: Identifiable, Equatable {
        var name: String
        var hex: String
        var id: String { hex }
    }

    /// Dark enough that the white item title stays readable on the tile.
    static let swatches: [Swatch] = [
        Swatch(name: "Red", hex: "#9E2B2B"),
        Swatch(name: "Orange", hex: "#A85B12"),
        Swatch(name: "Gold", hex: "#7A5E12"),
        Swatch(name: "Green", hex: "#1E7A45"),
        Swatch(name: "Teal", hex: "#0E6E74"),
        Swatch(name: "Blue", hex: "#2458A6"),
        Swatch(name: "Purple", hex: "#5C3D8A"),
        Swatch(name: "Pink", hex: "#9A3D66"),
        Swatch(name: "Slate", hex: "#4A5160"),
    ]

    static func canonicalHex(_ hex: String) -> String? {
        swatches.first { $0.hex.caseInsensitiveCompare(hex) == .orderedSame }?.hex
    }

    /// Palette spelling when it matches a swatch; otherwise the sRGB hex of any `#RRGGBB` / `#AARRGGBB`.
    static func storedHex(_ hex: String) -> String? {
        if let canonical = canonicalHex(hex) { return canonical }
        return NSColor(hex: hex)?.hexString
    }
}

struct ItemBackgroundPicker: View {
    let selectedHex: String?
    var isSampling: Bool
    var onSelect: (String?) -> Void
    var onPickFromScreen: () -> Void

    private let columns = Array(repeating: GridItem(.fixed(28), spacing: 8), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Background")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 0)
                screenSampleButton
            }

            LazyVGrid(columns: columns, spacing: 8) {
                swatchButton(hex: nil, name: "None")
                ForEach(ItemBackgroundPalette.swatches) { swatch in
                    swatchButton(hex: swatch.hex, name: swatch.name)
                }
            }
        }
        .padding(12)
        .frame(width: Self.width, height: Self.height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: NSColor(calibratedWhite: 0.22, alpha: 0.98)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }

    static let width: CGFloat = 196
    static let height: CGFloat = 128

    private var customColor: Color? {
        guard let selectedHex, ItemBackgroundPalette.canonicalHex(selectedHex) == nil else { return nil }
        return Self.color(hex: selectedHex)
    }

    private var screenSampleButton: some View {
        Button(action: onPickFromScreen) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "eyedropper")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                    .overlay(
                        Circle().stroke(Color.white.opacity(customColor == nil ? 0.35 : 0.95), lineWidth: customColor == nil ? 1 : 1.5)
                    )
                if let customColor {
                    Circle()
                        .fill(customColor)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Color.black.opacity(0.45), lineWidth: 0.5))
                        .offset(x: 2, y: 2)
                }
            }
            .frame(width: 26, height: 26)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isSampling)
        .help("Pick from screen")
        .accessibilityLabel("Pick from screen")
    }

    private func swatchButton(hex: String?, name: String) -> some View {
        let on = isOn(hex)
        return Button {
            onSelect(hex)
        } label: {
            ZStack {
                if let hex, let color = Self.color(hex: hex) {
                    Circle()
                        .fill(color)
                } else {
                    Circle()
                        .stroke(Color.white.opacity(0.75), lineWidth: 1.5)
                    Image(systemName: "circle.slash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(width: 22, height: 22)
            .padding(3)
            .overlay(
                Circle()
                    .stroke(on ? Color.white : Color.clear, lineWidth: 2)
            )
            .frame(width: 28, height: 28)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
    }

    private func isOn(_ hex: String?) -> Bool {
        switch (hex, selectedHex) {
        case (nil, nil):
            return true
        case let (candidate?, current?):
            return candidate.caseInsensitiveCompare(current) == .orderedSame
        default:
            return false
        }
    }

    static func color(hex: String) -> Color? {
        guard let ns = NSColor(hex: hex) else { return nil }
        return Color(nsColor: ns)
    }
}
