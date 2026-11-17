import SwiftUI
import AppKit
import KeyboardShortcuts

struct PreferencesView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Form {
            Section("General") {
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { store.state.preferences.launchAtLogin },
                        set: { enabled in
                            store.updatePreferences { $0.launchAtLogin = enabled }
                            LoginItemManager.setEnabled(enabled)
                        }
                    )
                )
                Picker(
                    "Time zone",
                    selection: Binding(
                        get: { timeZoneSelection },
                        set: { identifier in
                            store.updatePreferences {
                                $0.timeZoneIdentifier = identifier.isEmpty ? nil : identifier
                            }
                        }
                    )
                ) {
                    Text("System (\(TimeZone.current.identifier))").tag("")
                    ForEach(Self.timeZoneIDs, id: \.self) { identifier in
                        Text(timeZoneTitle(identifier)).tag(identifier)
                    }
                }
                Text("System follows this Mac. A chosen zone is passed as TZ only for items with Time Zone checked in the context menu, when a new instance starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Hotkey") {
                KeyboardShortcuts.Recorder("Toggle \(AppIdentity.displayName)", name: .toggleApp)
            }

            Section("Appearance") {
                ColorPicker(
                    "Background",
                    selection: Binding(
                        get: { Color(nsColor: NSColor(hex: store.state.preferences.backgroundColorHex) ?? .black) },
                        set: { newColor in
                            let ns = NSColor(newColor)
                            store.updatePreferences { $0.backgroundColorHex = ns.hexString }
                        }
                    ),
                    supportsOpacity: true
                )
                appearanceSlider(
                    title: "Icon size",
                    value: store.state.preferences.iconSize,
                    range: 36...128
                ) { value in
                    store.updatePreferences { $0.iconSize = value.rounded() }
                }
                appearanceSlider(
                    title: "Label size",
                    value: store.state.preferences.labelSize,
                    range: 10...18
                ) { value in
                    store.updatePreferences { $0.labelSize = value.rounded() }
                }
                appearanceSlider(
                    title: "Horizontal spacing",
                    value: store.state.preferences.gridSpacingHorizontal,
                    range: 0...48
                ) { value in
                    store.updatePreferences { $0.gridSpacingHorizontal = value.rounded() }
                }
                appearanceSlider(
                    title: "Vertical spacing",
                    value: store.state.preferences.gridSpacingVertical,
                    range: 0...48
                ) { value in
                    store.updatePreferences { $0.gridSpacingVertical = value.rounded() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
        .padding()
    }

    /// Fixed label column so every slider track shares the same width.
    private func appearanceSlider(
        title: String,
        value: Double,
        range: ClosedRange<Double>,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        HStack {
            Text(title)
                .frame(width: 140, alignment: .leading)
            Slider(
                value: Binding(
                    get: { value },
                    set: onChange
                ),
                in: range
            )
            Text("\(Int(value))")
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
        }
    }

    /// `""` is the system zone (inject nothing).
    private var timeZoneSelection: String {
        guard let identifier = store.state.preferences.timeZoneIdentifier,
              Self.timeZoneIDSet.contains(identifier) else { return "" }
        return identifier
    }

    private static let timeZoneIDs = TimeZone.knownTimeZoneIdentifiers.sorted()
    private static let timeZoneIDSet = Set(timeZoneIDs)

    private func timeZoneTitle(_ identifier: String) -> String {
        let name = identifier.replacingOccurrences(of: "_", with: " ")
        guard let zone = TimeZone(identifier: identifier) else { return name }
        let seconds = zone.secondsFromGMT()
        let sign = seconds >= 0 ? "+" : "-"
        let absolute = abs(seconds)
        return String(format: "%@ (GMT%@%d:%02d)", name, sign, absolute / 3600, (absolute / 60) % 60)
    }
}
