import Foundation

extension AppStore {
    func updateSettings(_ update: (inout AppState.Settings) -> Void) {
        mutate {
            let before = $0.settings
            update(&$0.settings)
            // Appearance dimensions are whole points (prefs sliders step by 1).
            $0.settings.iconSize = $0.settings.iconSize.rounded()
            $0.settings.labelSize = $0.settings.labelSize.rounded()
            $0.settings.gridSpacingHorizontal = $0.settings.gridSpacingHorizontal.rounded()
            $0.settings.gridSpacingVertical = $0.settings.gridSpacingVertical.rounded()
            // Icon / spacing changes require recomputing absolute positions from grid coords.
            if before.iconSize != $0.settings.iconSize
                || before.labelSize != $0.settings.labelSize
                || before.gridSpacingHorizontal != $0.settings.gridSpacingHorizontal
                || before.gridSpacingVertical != $0.settings.gridSpacingVertical {
                for ci in $0.collections.indices {
                    SnapToGrid.applyCompressedPositions(
                        items: &$0.collections[ci].items,
                        settings: $0.settings
                    )
                }
            }
        }
    }
}
