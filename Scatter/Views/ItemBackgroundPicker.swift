import AppKit
import SwiftUI

struct ItemBackgroundPicker: View {
    let selectedColor: ColorHex?
    @Binding var isSampling: Bool
    var onSelect: (ColorHex?) -> Void

    @State private var colorSampler: NSColorSampler?

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
                swatchButton(color: nil, name: "None")
                ForEach(LauncherItem.BackgroundSwatch.allCases) { swatch in
                    swatchButton(color: swatch.color, name: swatch.name)
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
        .onDisappear {
            colorSampler = nil
            isSampling = false
        }
    }

    static let width: CGFloat = 196
    static let height: CGFloat = 128

    private var customColor: Color? {
        guard let selectedColor, LauncherItem.BackgroundSwatch(color: selectedColor) == nil else { return nil }
        return selectedColor.color
    }

    private var screenSampleButton: some View {
        Button(action: pickFromScreen) {
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

    /// System loupe. No Screen Recording permission. Escape cancels and leaves the palette open.
    private func pickFromScreen() {
        guard !isSampling else { return }
        let sampler = NSColorSampler()
        colorSampler = sampler
        isSampling = true
        sampler.show { color in
            Task { @MainActor in
                colorSampler = nil
                isSampling = false
                guard let color, let color = ColorHex(color) else { return }
                onSelect(color)
            }
        }
    }

    private func swatchButton(color: ColorHex?, name: String) -> some View {
        let on = isOn(color)
        return Button {
            onSelect(color)
        } label: {
            ZStack {
                if let color {
                    Circle()
                        .fill(color.color)
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

    private func isOn(_ color: ColorHex?) -> Bool {
        color == selectedColor
    }
}
