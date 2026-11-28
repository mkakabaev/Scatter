import Foundation
import Combine
import AppKit
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var state: AppState
    @Published var searchQuery: String = ""
    /// True while the type-to-search overlay session is open (may have an empty query).
    /// Set via AppStore session APIs (extensions live in sibling files).
    @Published var isSearchSessionActive = false
    /// Highlight in the search overlay results list only — never drives canvas selection.
    @Published var searchSelectedItemID: UUID?
    @Published var selectedItemID: UUID?
    /// Transient accent target while an item context menu is open. Not persisted.
    /// When non-nil, canvas highlight follows this ID instead of `selectedItemID`.
    @Published var contextMenuItemID: UUID?
    /// Explicit multi-select mode for the open collection. Transient; not persisted.
    @Published var isSelectingItems = false
    /// IDs toggled while `isSelectingItems`. Transient; not persisted.
    @Published var selectedItemIDs: Set<UUID> = []
    @Published var isMainWindowVisible: Bool = false
    /// Incremented each time Settings should be shown (edge-trigger-safe reopen).
    @Published var settingsRequestID: Int = 0
    /// Incremented each time the canvas should paste from the clipboard (⌘V).
    @Published var pasteRequestID: Int = 0
    /// Item whose background palette is open. Transient; not persisted.
    @Published var backgroundPickerItemID: UUID?
    /// True while `ItemBackgroundPicker`’s system eyedropper is on screen (key / tap gating).
    @Published var isSamplingItemBackground = false
    /// Transient launch failure shown as an alert on the main window. Not persisted.
    @Published var openFailure: OpenFailure?
    /// Transient ingest failure (e.g. Cursor missing on drop). Not persisted.
    @Published var ingestFailureMessage: String?
    /// True while an external app launch is in flight. Suppresses main-panel raise on `applicationDidBecomeActive`.
    @Published var isLaunchingExternalApp = false
    /// Nested launch depth behind `isLaunchingExternalApp` (overlapping opens must not clear the guard early).
    var externalLaunchDepth = 0
    /// After ending search, field-editor teardown can re-enter `cancelOperation` in the same turn — ignore hide.
    var suppressHideFromCancel = false
    /// Finder-drop “Default / Open With Cursor” dialog is up. Suppresses launcher key handling.
    @Published var isPresentingItemOpenChoice = false
    /// Item Rename… alert is up. Suppresses launcher key handling (same as collection rename).
    @Published var isPresentingItemRename = false
    /// New Collection / Rename Collection alert is up. Suppresses Escape-hide via `handleMainWindowCancel`.
    @Published var isPresentingCollectionAlert = false
    /// Transient save failure shown as an alert on the main window. Not persisted.
    @Published var saveFailureMessage: String?
    /// Global frames for sidebar collection rows (canvas item-drag hit-testing). Not published — updated often during layout.
    var sidebarRowFramesGlobal: [UUID: CGRect] = [:]
    /// Collection under an in-progress normal-mode item drag (sidebar drop hover). Transient; not persisted.
    @Published var itemDragHoverCollectionID: UUID?

    let persister: StatePersister
    let webLinkEnricher = WebLinkEnricher()

    struct OpenFailure: Equatable {
        var itemName: String
        var message: String
        /// Terminal command the user can run to clear blocking xattrs. Not executed by this app.
        var recoveryCommand: String? = nil
    }

    static let layoutAnimation: Animation = .spring(response: 0.32, dampingFraction: 0.86)

    var sortedCollections: [AppState.Collection] {
        state.collections.sorted { $0.sortIndex < $1.sortIndex }
    }

    var selectedCollection: AppState.Collection? {
        guard let id = state.settings.selectedCollectionID else {
            return sortedCollections.first
        }
        return state.collections.first { $0.id == id } ?? sortedCollections.first
    }

    /// Items on the active collection canvas (never filtered by search — search uses overlay).
    var visibleItems: [LauncherItem] {
        selectedCollection?.items ?? []
    }

    /// Overlay session is open (query may be empty).
    var isSearching: Bool { isSearchSessionActive }

    init() {
        let persister = StatePersister()
        self.persister = persister
        state = persister.bootstrap()
        persister.onSaveFailure = { [weak self] _ in
            self?.reportSaveFailure(
                "Couldn’t save your layout. Check disk space and permissions for Application Support."
            )
        }
    }

    /// Canvas size implied by persisted window + sidebar (for placement without a live GeometryReader).
    func canvasSizeFromWindowSettings() -> CGSize {
        let sidebar = SidebarLayout.clamped(
            state.settings.sidebarWidth,
            containerWidth: state.settings.windowWidth
        )
        return CGSize(
            width: max(
                SidebarLayout.minimumCanvasWidth,
                state.settings.windowWidth - sidebar - SidebarLayout.splitterThickness
            ),
            height: state.settings.windowHeight
        )
    }

    func findItem(_ id: UUID) -> LauncherItem? {
        for collection in state.collections {
            if let item = collection.items.first(where: { $0.id == id }) {
                return item
            }
        }
        return nil
    }

    /// Cancel any pending debounce and write `state.json` now (e.g. on quit).
    func flushPendingSave() {
        persister.flush(state)
    }

    func mutate(_ body: (inout AppState) -> Void) {
        var copy = state
        body(&copy)
        state = copy
        // Skip write if `self` is gone — never fall back to this mutate’s snapshot (stale vs later mutates).
        persister.scheduleSave { [weak self] in
            self?.state
        }
    }
}
