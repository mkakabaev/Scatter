# Scatter — Agent Spec

Machine-oriented product/engineering context for future development iterations.
Do not treat as end-user documentation.

## Identity

| Key | Value |
|-----|-------|
| Product name | Scatter (`AppIdentity.displayName`) |
| Bundle ID | `com.kakabaev.scatter` |
| Platform | macOS 14+ only |
| UI paradigm | Menu-bar / agent app (`LSUIElement=true`), no Dock icon |
| Inspired by | Stunt Software Overflow 3 (`com.stuntsoftware.Overflow3`) |
| Repo root | `/Users/murad/Work/Scatter` |
| Xcode project | `Scatter.xcodeproj` (generated via `project.yml` + XcodeGen) |
| Generate project | `xcodegen generate` |

## Goals

- Visual launcher for apps, files, folders, URLs in named collections.
- Hotkey popup, sidebar collections, icon canvas, global type-to-search overlay over saved items, menu-bar quick access.
- Grid-based icon positions. Dragging is free-form visually; drop commits to a cell via `placeReplacing` (no separate Snap to Grid command).
- Per-item **Open With** for files, folders, and URLs (folders → Cursor is a primary workflow via Finder-drop dialog). **App items never use Open With** (`supportsOpenWith == false`): no Open With UI, and launch always opens the app itself. No global Settings Open With default.
- First-launch starter seed: **Apps** collection with Finder + Safari when Scatter store is empty.

## Non-goals

- Quick Look / Space preview
- Spotlight / whole-disk / top-level search directory
- Sparkle / update checking
- Licensing / monetization / registration
- Windows / iOS / multi-platform
- **Modifying, updating, deleting, or managing other apps/files** — Scatter is launch-only. Never request App Management TCC, never use `.withSecurityScope` bookmarks on targets, never rewrite target bundles.

## Architecture

```txt
AppDelegate (NSStatusItem, nonactivating NSPanel main window, hotkey install)
  └─ AppStore (@MainActor ObservableObject) — single source of truth
       ├─ StatePersister (JSON load / debounced save / starter seed)
       ├─ Web/ (WebLinkEnricher, WebLinkFetcher, WebLinkHTTP, WebHTML, WebFavicon, WebDisplayName)
       ├─ ItemOpener / ItemURLResolver / LauncherItemFactory / OpenWithResolver /
       │  PasteboardIngest / MinimalBookmark / IconProvider / SnapToGrid / LoginItemManager
       └─ SwiftUI: MainWindowView, SettingsView
```

### Key files

| Path | Role |
|------|------|
| `Scatter/App/AppMain.swift` | `@main` App + AppDelegate adaptor |
| `Scatter/App/AppIdentity.swift` | Display name + Application Support folder name |
| `Scatter/App/AppDelegate.swift` | Status item, windows, visibility bridge, quick-access menu |
| `Scatter/Models/LauncherItem.swift` | `ItemKind`, `LauncherItem`, `CodablePoint`, `BackgroundSwatch`, Open With predicates |
| `Scatter/Models/ColorHex.swift` | `ColorHex` (canonical sRGB `#RRGGBB` / `#AARRGGBB`) + `NSColor` parse / format / luminance; parse uses `srgbRed:` so eyedropper / ColorPicker round-trips match |
| `Scatter/Models/SearchHit.swift` | `SearchHit` (type-to-search result) |
| `Scatter/Models/AppState.swift` | `AppState`, `AppState.Collection`, `AppState.Settings` |
| `Scatter/App/AppStore.swift` | `AppStore` core (`state`, queries, `mutate`, flush) |
| `Scatter/App/AppStore+Session.swift` | Window / Escape / selection / search / drag-hover session |
| `Scatter/App/AppStore+Collections.swift` | Collection select / CRUD / reorder |
| `Scatter/App/AppStore+Items.swift` | Item CRUD, placement, Open With, web-link add |
| `Scatter/App/AppStore+Settings.swift` | Settings mutation + layout recompute |
| `Scatter/Services/StatePersister.swift` | `state.json` load / debounce / flush / backups / starter seed / launch grid refresh |
| `Scatter/Services/Web/WebLinkEnricher.swift` | In-flight favicon/title fetch map; cancel on remove / hide |
| `Scatter/Services/SidebarLayout.swift` | Sidebar width clamps (alongside `TileMetrics`) |
| `Scatter/Services/TileMetrics.swift` | Tile / cell width & height from prefs; icon-size / chrome constants |
| `Scatter/Services/SnapToGrid.swift` | Grid layout math + content bounds for overflow fit |
| `Scatter/Services/ItemOpener.swift` | Open / reveal (+ launch diagnostics, TZ env) |
| `Scatter/Services/ItemURLResolver.swift` | Resolve item target URL + `.code-workspace` detection |
| `Scatter/Services/LauncherItemFactory.swift` | Build `LauncherItem` from a dropped / pasted / seeded URL |
| `Scatter/Services/OpenWithResolver.swift` | Resolve Open With → `Resolved(url, displayName)` (saved or one-shot) |
| `Scatter/Services/PasteboardIngest.swift` | Shared pasteboard parse for drop + ⌘V → `PasteboardContents` |
| `Scatter/Services/MinimalBookmark.swift` | Shared `.minimalBookmark` create / resolve (no security scope) |
| `Scatter/Services/IconProvider.swift` | Item icons + Open With badge + app URL icons + favicon framing |
| `Scatter/Services/Web/WebLinkFetcher.swift` | URL-item favicon + page title orchestrator (used by `WebLinkEnricher`) |
| `Scatter/Services/Web/WebLinkHTTP.swift` | Ephemeral session + capped HTML/image/manifest downloads |
| `Scatter/Services/Web/WebHTML.swift` | HTML charset decode + title/meta/attribute parsing |
| `Scatter/Services/Web/WebFavicon.swift` | Icon candidate discovery + PNG render (cap `max(TileMetrics.maxIconSize × 2, 512)`) |
| `Scatter/Services/ItemIconStore.swift` | Favicon PNG sidecars under `icons/<itemID>.png` (not inline in `state.json`) |
| `Scatter/Services/Web/WebDisplayName.swift` | HTTP(S) page-title / host labels (decoded text) + `URL.isHTTP` / `URL.httpURL(from:)` |
| `Scatter/Services/CursorLocator.swift` | Resolve Cursor.app for Finder-drop Open With |
| `Scatter/Services/BrowserLocator.swift` | Installed browsers for URL Open With — `Browser(url, displayName, isDefault)` (https ∩ HTML; standardized URLs; default first, then A–Z) |
| `Scatter/Services/FileDisplayName.swift` | Finder-style path/URL labels (strips trailing `.app`) |
| `Scatter/Services/SearchLayoutTranslit.swift` | EN↔RU QWERTY/ЙЦУКЕН (ISO) layout remap for type-to-search when Russian input is installed |
| `Scatter/Services/OpenWithPanel.swift` | NSOpenPanel + “Always Open in” accessory |
| `Scatter/Services/AddItemsPanel.swift` | NSOpenPanel for Add… (files + folders, empty canvas) |
| `Scatter/Services/HotkeyManager.swift` | KeyboardShortcuts name (`toggleApp`) |
| `Scatter/Services/LoginItemManager.swift` | `SMAppService` launch-at-login toggle |
| `Scatter/Views/MainWindowView.swift` | Main chrome, key handling, search/canvas shell |
| `Scatter/Views/Canvas/CanvasView.swift` | Icon canvas body, drag/placement, selection bar |
| `Scatter/Views/Canvas/CanvasContextMenus.swift` | Empty-canvas + item AppKit context menus |
| `Scatter/Views/Canvas/CanvasIngest.swift` | Drop / paste / Add… ingest + Open With Cursor batch dialog |
| `Scatter/Views/Canvas/CanvasOverflow.swift` | Overflow chevrons + expand window to fit content |
| `Scatter/Views/CollectionSidebar.swift` | Collections list + reorder + drop-to-move |
| `Scatter/Views/LauncherItemIconView.swift` | Shared item icon + Open With badge |
| `Scatter/Views/LauncherItemView.swift` | Tile chrome (icon, title, background) |
| `Scatter/Views/ItemBackgroundPicker.swift` | Item background palette UI + eyedropper (`NSColorSampler`) |
| `Scatter/Views/SearchOverlayView.swift` | Type-to-search overlay |
| `Scatter/Views/FieldEditorStyle.swift` | Clear field-editor chrome + `SearchNSTextField` (shared with AppDelegate) |
| `Scatter/Views/WindowBackgroundDragView.swift` | Empty-area window drag, AppKit drops, empty-canvas + item context menus |
| `Scatter/Views/KeyMonitor.swift` | `NSEvent` local monitor bridge |
| `Scatter/Views/SettingsView.swift` | Settings UI |
| `Scatter/Resources/Info.plist` | Bundle metadata (`LSUIElement`, ATS, etc.) |
| `Scatter/Resources/Scatter.entitlements` | Sandbox off |
| `SPEC.md` | This file — keep updated when behavior changes |

### Dependencies (SPM)

- `KeyboardShortcuts` (sindresorhus) — global hotkey recorder + registration

Sandbox: **off** (`Scatter.entitlements`) for personal Finder/bookmarks friction reduction.

## Persistence

- Path: `~/Library/Application Support/Scatter/state.json` (`AppIdentity.applicationSupportFolderName`)
- Favicons: `~/Library/Application Support/Scatter/icons/<itemID>.png` (not inline in JSON)
- Format: Codable `AppState` JSON
- Debounced save (~200ms) via `StatePersister.scheduleSave` (cancelled debounce must **not** write — `Task.sleep` cancel returns without `persistImmediately`; provider re-reads current `AppStore.state` at fire time and returns `nil` to skip if the store is gone — never fall back to a per-mutate snapshot); flush pending write on quit (`AppStore.flushPendingSave` → `StatePersister.flush` from `applicationWillTerminate`)
- Save write failure: log + `AppStore.reportSaveFailure` alert (do not silently ignore disk/permission errors)
- Undecodable `state.json`: rotate up to **3** backups (`state.json.bak`, `.bak.1`, `.bak.2`; newest → oldest), log, then seed starter state (do not silently destroy the unreadable file)
- Launch bootstrap also: strip Open With fields from **app** items; when a collection has **colliding** `gridColumn`/`gridRow` (typical pre-grid JSON defaulting every tile to `(0,0)`), rebuild grid from stored `position` via uniform full-row pitch (`SnapToGrid.legacyCellSize`), then `applyCompressedPositions`
- No auto-migration from other apps’ Application Support folders

### Domain model

Swift property names below. Where JSON keys differ, noted in comments.

```txt
AppState
  collections: [AppState.Collection]
  settings: AppState.Settings

AppState.Collection
  id, name, sortIndex, items: [LauncherItem]

LauncherItem
  id, kind(app|file|folder|url)
  bookmarkData?, urlString?, displayName
  position: CodablePoint {x,y}   // derived top-left of tile; collection-local
  gridColumn, gridRow            // stable grid source of truth; position from SnapToGrid.applyCompressedPositions
  openWithBookmarkData?, openWithBundleIdentifier?
  backgroundColor?      // ColorHex?; nil = clear tile
  applyTimeZone         // default false; encoded only when true; when true + Settings has IANA id → inject TZ on open
  iconPNGData?          // URL items: in-memory favicon only; on disk as icons/<id>.png (never in JSON)

AppState.Settings   // nested to avoid clashing with SwiftUI.Settings
  backgroundColor      // ColorHex; ColorPicker supports opacity
  iconSize, labelSize, gridSpacingHorizontal, gridSpacingVertical
  (icon/label/spacing are whole points)
  selectedCollectionID?, sidebarWidth, windowWidth/Height
  timeZoneIdentifier?   // IANA id; nil = system zone, inject nothing unless item.applyTimeZone
  launchAtLogin
```

**Defaults** (`AppState.Settings.default`): background `#F21E1E1E` (`#1E1E1E` @ 95% opacity), icon **64**, label **12**, h-spacing **6**, v-spacing **2**, sidebar `SidebarLayout.defaultWidth` (206), window **1042×655**, `timeZoneIdentifier` nil, `launchAtLogin` false.

Unknown keys in older `state.json` (e.g. removed `defaultOpenFoldersWithBundleID`) are ignored on decode and dropped on the next save.

### First-launch seed

When Scatter `state.json` is **missing**, **undecodable** (after backup), or has **zero collections**, `StatePersister.makeStarterState()` creates:

- Collection **Apps**
- Finder (`/System/Library/CoreServices/Finder.app`) and Safari (`/Applications/Safari.app`) on row 0, columns 0–1

Decodable layouts with existing (even empty) collections are kept — clearing every item does **not** wipe named collections on the next launch.

### Favicon persistence

URL-item favicons are files under `~/Library/Application Support/Scatter/icons/<itemID>.png` (`ItemIconStore`). `LauncherItem.iconPNGData` is session memory only and is **not** encoded into `state.json`. `setItemIcon` updates memory **only** after a successful sidecar write. On load, URL items hydrate favicons from sidecars. Sidecar files are deleted with the item/collection.

## UX behaviors

### Window / chrome

- Dark floating panel (`LauncherWindow`: `NSPanel` with `.nonactivatingPanel`, `hidesOnDeactivate = false`, `canBecomeKey = true`). Show with `makeKeyAndOrderFront` + `orderFrontRegardless` — **never** `NSApp.activate` on the main window path, so the previous app keeps the menu bar while Scatter stays key for type-to-search. Collection behavior includes `.moveToActiveSpace` so show/raise lands on the **current desktop Space** (not the Space where the panel last lived). Settings remains a normal activating `NSWindow`, ordered **above** the main panel (`level` + `order(.above)`); do not raise the main panel while Settings is visible (`applicationDidBecomeActive`). Settings also uses `.moveToActiveSpace` when shown.
- Traffic lights: **close only** (minimize/zoom hidden). Window stays `.resizable` for edge drag; no Dock miniaturize (agent app).
- Main content is `.focusable()` for type-to-search / arrows, with `.focusEffectDisabled()` (and hosting `focusRingType = .none`) so macOS does not draw the accent focus ring around the panel content.
- Default content size **1042×655**; minimum **640×400**. Content size persisted; each show **centers on the display under the mouse cursor** (not `NSScreen.main`).
- **Overflow chevrons**: when the window is smaller than the active collection’s tile bounds, small chevrons appear on the clipped edge(s) (right / bottom; 12pt top inset). Click animates resize so all tiles fit (margin = `SnapToGrid.origin`, top-left fixed, clamped to `visibleFrame`). Hide while searching, empty collection, or cannot grow further. APIs: `SnapToGrid.contentBounds`, `expandWindowToFitContent` in `CanvasOverflow`.
- Layout: left collections (default **206pt**, splitter 140–420, canvas never under 280pt); right free-form canvas. Window is `isMovableByWindowBackground`.
- Empty **canvas** (not on a tile): click clears selection; drag past ~4pt → `NSWindow.performDrag` (`WindowBackgroundDragView`). Right-click → **Add…** (`AddItemsPanel`, files + folders) then **Layout** → **Delete Row** / **Delete Column**. Add… uses the same ingest as Finder drop (apps immediate; files/folders Default vs Open With Cursor); placement at right-click point (tile-centered) then `placeReplacing`. Finder/URL drops stay on the AppKit empty layer — not SwiftUI `.onDrop`.
- **Delete Row / Column**: hit-test menu point (`SnapToGrid.hitTestCell`); enabled only if that row/column is fully empty **and** at least one item sits below / to the right. Layout parent disabled when every leaf is. `NSMenu.autoenablesItems = false`. Delete shifts then `applyCompressedPositions`. APIs: `AppStore.deleteEmptyRow` / `deleteEmptyColumn` (target `selectedCollection`, same fallback as the canvas), matching `SnapToGrid` helpers + `canDelete*`.
- Empty **sidebar** padding uses the same drag view (no Layout items). Collection rows: select / reorder / row context menu.
- Sidebar width is `settings.sidebarWidth`, restored on launch. A narrower window clamps live width without overwriting a wider saved width until the user drags the splitter.
- Sidebar collections are **drag-reorderable** (~6pt threshold). Order is `sortIndex` (menu-bar + ⌘1–9 follow it). Row context: **New Collection…** / **Rename…** / **Delete** (Delete disabled when only one collection — `deleteCollection` refuses the last). Rows show item counts. **New Collection** is sidebar context menu only. **Rename / Delete target the context-menu row** (`MainWindowView.renameCollectionID` / the row’s `collection.id`) — not necessarily `settings.selectedCollectionID`.
- **Normal mode:** drag an item onto another sidebar collection to move it (`itemPointerGesture` + `sidebarRowFramesGlobal`; hover via `itemDragHoverCollectionID`). Drop on the open collection / empty sidebar chrome keeps canvas snap. **Select mode:** no sidebar drop — multi-move via context menu / action-bar **Move to Collection**.
- Appearance: background hex (ColorPicker with opacity), icon size **36–128** (`TileMetrics`), label **10–18**, h/v spacing **0–48** (whole points). Cell width = `TileMetrics.itemWidth` (icon + title insets + padding) so spacing 0 makes neighbors touch. Main window `isOpaque = false`; SwiftUI paints preference color (alpha shows desktop).
- Remember window size. `applicationShouldHandleReopen` → `showMainWindow`.

### Launching items

Launch via `NSWorkspace.open(_:configuration:)` / `open(_:withApplicationAt:configuration:)` only. Target URLs via `ItemURLResolver`: prefer on-disk `urlString` (or http(s)); if stale, resolve `bookmarkData`. Bookmarks are `.minimalBookmark` (no security scope). When resolve reports `bookmarkDataIsStale`, persist refreshed bookmark bytes (and updated `urlString` / Open With bookmark) via `AppStore.refreshStaleBookmarks` before / around open.

**Apps:** Do **not** use `openApplication(at:)`. Default (no TZ): spawn `/usr/bin/open <app>` via `Process` (avoids Dock-bounce-then-die under `LSUIElement`). TZ on: `NSWorkspace.open(appURL, configuration:)` with `environment["TZ"]`. `promptsUserIfNeeded = true`. Only set `configuration.environment` when TZ injection is on. Open With does not apply — always open the app URL itself (`ItemOpener` forces `resolvedOpenWith = nil`).

**Focus:** Nest `AppStore.beginExternalLaunch` / `endExternalLaunch` around launch (`externalLaunchDepth`) so overlapping opens do not clear `isLaunchingExternalApp` early and `applicationDidBecomeActive` does not raise mid-launch. Do **not** hide the window before LS/`open` accepts the handoff. Hide on confirmed success when dismiss-on-open.

**Failures:** `AppStore.reportOpenFailure` (transient `openFailure`). Pre-check before `NSWorkspace`: (1) missing file/folder/app path → kind’s `missingTargetMessage`; (2) missing Open With app → ““{App}” could not be found.” Do not call `NSWorkspace` in those cases. `OpenWithResolver.resolve` only returns an on-disk app.

**App false-success:** Poll until the launched app appears in `NSRunningApplication` (budget ~3s, ~0.2s interval) by **exact bundle path** (not bundle ID alone — avoids masking a dead quarantined copy behind another already-running instance). Prefer the `NSRunningApplication` from the LS callback when present. Once seen, wait ~0.75s and re-check so bounce-then-die still fails. Never appeared by budget → failure. If not running, inspect quarantine/provenance xattrs on the bundle; offer **Copy Command** for `xattr -cr '<app>'` (advise only — never clear attrs; launch-only). Details in `ItemOpener`.

**Reveal in Finder:** Nest `beginExternalLaunch` / deferred `endExternalLaunch` around `activateFileViewerSelecting` so `applicationDidBecomeActive` does not re-raise the launcher mid-handoff.

**Time zone:** Settings → Time zone (IANA id; **System** = nil). Injection is opt-in: `LauncherItem.applyTimeZone` **and** a non-nil valid Settings IANA id → merge `TZ` onto a copy of `ProcessInfo.processInfo.environment` (setting `OpenConfiguration.environment` replaces inheritance — never pass `["TZ": …]` alone). Context menu **Time Zone** / **Time Zone (City)** toggles via checkbox (`MenuItem.isOn` / `AppStore.setApplyTimeZone`). Applies only to newly started app instances. Do **not** set `__XPC_TZ`.

Default click / Return / primary context action:
- **"Open"** — system default handler (no per-item Open With)
- **"Open in {App}"** — when `hasOpenWith` (and `supportsOpenWith` for showing Open With UI)

| Input | Behavior |
|-------|----------|
| Click | Primary action; hide window **only on success**. Option-click keeps window |
| Return (canvas) | Primary action; **always** hide on success (`keepWindowOpen: false`) |
| Return (search) | Open highlighted hit; Option keeps window |
| ⌘-click | Reveal in Finder (no-op for URLs); hide **only on success** (Option-⌘ keeps window) |
| Shift-click | Enter **select mode** seeded with that item (only when collection has **>1** items). ⌘ still wins if both held. Single-item collection → Open |
| Escape | Single path `AppStore.handleMainWindowCancel` (KeyMonitor + `LauncherWindow.cancelOperation` / Esc). Eyedropper active → no-op (loupe owns Esc). Open-failure / ingest-failure / save-failure / Open With Cursor dialog / item Rename / collection New·Rename alerts (`isPresentingCollectionAlert`) → no-op. Palette open → close. Select mode → exit. Search session → `clearSearch()` only (window stays; suppress a follow-up `cancelOperation` hide from field-editor teardown); else hide (silent) |
| ⌘↑ / ⌘↓ | Prev/next collection (not searching); wraps. Works in select mode |
| ⌘1–9 | Jump to collection N (not searching). Works in select mode |
| ⌘, | Open Settings |
| ⌘V | Paste Finder paths, VS Code/Cursor `code/file-list`, or http(s) onto current collection (same ingest as drop). Pointer over canvas → tile-centered `placeReplacing`; else next free cell(s). Empty usable clipboard → `NSSound.beep()`. While searching, ⌘V goes to the search field (query paste), not canvas ingest. Suppressed while alert TextFields editing |
| Arrows | Canvas: nearest-neighbor (**disabled in select mode**). Search: ↑/↓ move `searchSelectedItemID` only — **must not** change canvas `selectedItemID`. Not while rename/new-collection alert editing |
| Type | Opens **search overlay**. Matches saved items across all collections. First key: letter/digit/space/`.`/`-`/`_`. Suppressed while alert TextFields first responder or select mode |
| Delete / ⌫ | **Never** removes canvas items. Batch remove is UI-only (action bar / context menu) |

### Search overlay

- Trigger: typing an allowed character while the main window is open (or editing the overlay field) starts an explicit session (`isSearchSessionActive`). Empty query keeps the overlay (`"Type to search"`); clearing the query does **not** end the session.
- Scope: all collections’ `displayName` substring; results **A–Z**; canvas underneath is not filtered.
- **Layout translit**: when trimmed query length **> 1** and a Russian keyboard input source is installed (`SearchLayoutTranslit`), also match the EN↔RU physical-key alternate (macOS Russian ЙЦУКЕН ISO ↔ English QWERTY). English query → search English + Russian remap; Russian query → search Russian + English remap. Length ≤ 1 or no Russian input → original substring only. APIs: `SearchLayoutTranslit.matchQueries(for:)`.
- Highlight is `searchSelectedItemID` only — never canvas `selectedItemID`. Return / click opens; dismiss clears search highlight and leaves canvas selection alone.
- Exit: Escape (overlay only); click dimmed overlay; window resign key / hide; collection switch; Settings; enter select mode → `clearSearch()`.
- Silent open: `LauncherWindow.keyDown` must **not** call `super` (avoids NSBeep).
- UI regenerable from `SearchOverlayView` / `FieldEditorStyle` / `AppDelegate`: dimmed overlay + centered material panel; AppKit `SearchNSTextField`; 48pt icons via `LauncherItemIconView`; warm field editor in `setupMainWindow`. Row subtitle is collection name; URL items use `{Collection} • {URL}` (middle truncation).
- APIs: `isSearching` (== session), `isSearchSessionActive`, `searchResults: [SearchHit]`, `searchSelectedItemID`, `clearSearch()`, `setSearchQuery(_:)`, `selectAdjacentSearchResult(delta:)`.

### Login item

`SMAppService` is touched **only** when the user toggles “Launch at login” in Settings — never on cold launch. On register/unregister failure, revert `settings.launchAtLogin` to the previous value (do not leave the preference desynced). When Settings appears, **read** `SMAppService` status and mirror it into `launchAtLogin` if the preference drifted (still no register/unregister).

### Layout

- Drag: starts after ~4pt pointer travel; little movement = click/open. Global-coordinate drag. Dragging item drawn on top (`zIndex` + ordered last). Live free-form position stays in canvas view state only; `finalizeItemPlacement` is the first persistence write for the drop.
- **Drop target ghost**: dashed accent rect at landing cell (`SnapToGrid.previewFrame`). Row by nearest vertical strip center; ghost centered in strip. Preview must not treat the landing empty row as occupied. Origin row occupied until drop.
- Drop / Add… / ⌘V: same ingest. AppKit `WindowBackgroundDragView` owns Finder/URL drops (`isCanvasDropTarget` / `WindowBackgroundDragNSView.canvasDropTarget(in:)` for ⌘V pointer hit-test — sidebar chrome is not a drop target). Drag accept caches `PasteboardIngest.read` by pasteboard `changeCount` across `draggingUpdated`. ⌘V: `PasteboardIngest.read(from:)` → `PasteboardContents` (on-disk files first; else `code/file-list` with the same missing-path → empty rule; else http(s) / plain-text). Each `PasteboardContents.Item` is a URL + optional title (`public.url-name` for http(s)). Empty → beep. Placement: pointer over canvas → tile-centered + `placeReplacing`; else `SnapToGrid.nextFreePlacement` (sets provisional `gridColumn`/`gridRow` so reserved cells stay unique). Before `placeReplacing`, ingest assigns provisional grid via `hitTestCell` at the drop point. `AppStore.requestPaste()` / `pasteRequestID` edge-triggers the canvas handler (not while searching). Sidebar **Move to Collection** packs with `gridBounds` from persisted window/sidebar canvas size (`AppStore.canvasSizeFromWindowSettings`), not the nil fallback.
- Sidebar collection reorder via drag (`sortIndex`). Accent insertion line. Item → other collection move in normal mode only (hit-test, not SwiftUI `.onDrag`/`.onDrop`). Select mode / menus use **Move to Collection**.
- **Drop** (`SnapToGrid.placeReplacing`): text-insert; gaps to the right can condense. Vacate dragged item first. Free target → place only. Occupied → shift block from target to next empty on that row; beyond gap stays. No gap → +1 suffix shift with wrap. Final placement spring-animated. No separate Snap to Grid command.
- **Explicit empty row/column**: item **Layout** → Insert Row Above / Insert Column to the Left; empty-canvas **Layout** → Delete Row / Delete Column.
- **Empty row strips**: empty rows use half pitch (`emptyRowHeightFactor = 0.5`). Stable `gridColumn`/`gridRow`; `position` via `applyCompressedPositions` (collapses consecutive empties). Do not re-infer rows from absolute Y. On launch, re-apply compressed positions from stored grid coords.
- **Empty columns (intentional):** unlike rows, empty columns are **not** compressed and Insert Column is **not** insert-guarded — consecutive empty columns may accumulate. Delete Column still requires a fully empty column with items to the right.
- **Ingest helper:** Drop / ⌘V / Add… share `commitIngest` kind branching in `CanvasIngest` (Open With dialog / `addWebLink` / `addItemFromFinder`). Placement stays path-specific (same point vs `nextFreePosition` with reserved pending cells). When any file/folder in the batch needs the Open With dialog, **the whole batch** (including apps/URLs) waits for Default / Open With Cursor / Cancel — Cancel discards everything. While `pendingDrop` is set, further drop / paste / Add… is ignored (`NSSound.beep`) — do not replace the waiting batch. Hiding the main window clears `pendingDrop` so the dialog cannot resurrect. **Open With Cursor** with Cursor missing → `AppStore.reportIngestFailure` (“Couldn’t Add Items” alert) — **not** `reportOpenFailure`; items are **not** added.
- **Settings**: gear top-trailing; reopen via `settingsRequestID` or ⌘,. No Open With section. Title centered **Settings**. Content size fits `SettingsView` (`fittingSize` on show; seed rect ~512×572). Re-centered on mouse display every show; always above main panel. General includes **Time zone**.
- Item titles: max **2 lines**, tail truncation; tile height from `TileMetrics` (`iconSize + titleHeight + verticalChrome`). Full name via `.help`. Title white (0.92) on clear/dark backgrounds (`ColorHex.isLightBackground` false, sRGB relative luminance ≤ 0.185); black (0.88) + lighter shadow on light tints (`isLightBackground` when luminance > 0.185). Nine palette swatches stay on the white-title side.
- Icons (`IconProvider` + `LauncherItemIconView`): `*.code-workspace` → Cursor icon (no Open With badge). Other items with Open With show bottom-right badge. URL items use in-memory/`ItemIconStore` favicon else generic HTML. Favicon on Apple icon grid (**824/1024** body); web favicons only: continuous squircle clip (~22.37% radius of body) via `ImageRenderer`. Apps/files/folders and generic HTML keep system shape.
- Visibility: if main window **visible** and app activates → raise (`makeKeyAndOrderFront` + `orderFrontRegardless`, no `NSApp.activate`). Hotkey / status left-click: hidden → show centered on mouse display; visible and front → hide; visible but buried → raise only. Frontmost tracked across `windowDidBecomeKey` / deferred `windowDidResignKey`. **Show Scatter**: always show; if already visible, relocate to mouse display and raise.
- Canvas items: top-leading anchored (`offset`).
- **Rename…** edits `displayName` only (not on-disk). While item Rename / collection Rename / New Collection alerts are up, `KeyMonitor` and `handleMainWindowCancel` must not steal keys / hide (`AppStore.isPresentingItemRename` for item Rename; `AppStore.isPresentingCollectionAlert` mirrored from `MainWindowView` New/Rename Collection `@State`; also `isEditingText()` for `NSTextView`/`NSTextField`).
- **Background…**: palette beside item (`BackgroundSwatch` via `ItemBackgroundPicker`: None + nine + eyedropper). Sets `backgroundColor` via `AppStore.setItemBackground` and closes; **None** clears. Eyedropper is `NSColorSampler` (no Screen Recording). Sampled color stored as sRGB `#RRGGBB`. Escape in loupe cancels, leaves palette open. Non-swatch sample marked on eyedropper. Click outside / Escape dismisses. Tile background fills icon+title at cell width; bottom edge follows title (`iconSize + measuredTitleHeight + TileMetrics.verticalChrome`). Selection stroke uses same shape. Search rows tint icon background. Session: `backgroundPickerItemID` (not persisted). Closed on collection switch / hide / Settings. While open, non-command keys swallowed (except during loupe).
- **New items** (`LauncherItemFactory.makeItem`): files strip path extension for `displayName`; folders keep `lastPathComponent`; apps use `FileDisplayName`. Web links: `WebDisplayName` from `public.url-name` when usable; else host (upgraded from page fetch when still that host).
- **Finder drop** of file/folder: dialog **Default** vs **Open With Cursor**; choice saved as per-item Open With. Apps skip. **Open With Cursor** with Cursor missing → ingest-failure alert (“Cursor could not be found…”); items are **not** added.
- **Web link drop / paste:** Prefer on-disk file URLs; else `PasteboardIngest` (`public.url` / `public.url-name`, `code/file-list`, plain-text http(s)). Accept **http/https only** for web links. System handler (no Open With dialog). `WebLinkEnricher` tracks per-item tasks with a **concurrency cap of 4**; `WebLinkFetcher` does one capped HTML fetch → favicon via `AppStore.setItemIcon` → `ItemIconStore` (cap `max(TileMetrics.maxIconSize × 2, 512)` px; sidecar write failures are logged and **skip** in-memory `iconPNGData` so session and disk stay aligned) and optional title upgrade when tile still shows host. Fetches are **cancelled** on item/collection remove or hide main window (cooperative `Task.isCancelled` checks). `cancelAll` / per-item cancel only request cancellation — they must **not** zero `runningCount` or drop in-flight task slots; each Task’s `defer` owns the decrement so a hide→show→paste cannot under-count the cap. Candidate order lives in `WebFavicon` (Safari-oriented: square og:image, apple-touch-icon, manifest, link rel=icon, well-known paths); charset decode in `WebHTML`. `NSAllowsArbitraryLoads` for http/https fetches.

### Open With

- Resolution (file / folder / URL): per-item bookmark (on disk) → per-item bundle id (on disk) → system default when unset. If Open With **is** set but neither resolves → missing-app alert (no silent fallback).
- **App items:** Open With does not apply. No Open With UI / badge / “Open in {App}”. `setOpenWith` refuses non-nil for apps. Launch always opens the app itself.
- Context primary: `Open` or `Open in {App}` (latter when `hasOpenWith`, including when the Open With app is missing — label still says `Open in …`, open fails with missing-app alert, no silent system-default fallback); **Reveal in Finder** for app/file/folder only.
- Context groups: Open (+ Reveal when shown) → Open With… / Clear Open With (**omitted for apps**) → **Rename… / Background… / Time Zone toggle** → **Select…** (collection **>1** items) → **Layout** → Move / Remove.
- **Item context menu:** AppKit via `WindowBackgroundDragView` (`itemContextMenuItems`) so rows can use `NSMenuItem.image` / bold `attributedTitle` / `state`. **Highlight:** normal mode right-click sets `contextMenuItemID` (accent stroke); clear after menu tracking ends. Empty-canvas menu / empty click clears highlight + `selectedItemID`. Select mode: right-click does not change highlights.
- **Layout** (normal item menu): **Insert Row Above** / **Insert Column to the Left**. Row insert disabled when no-op after collapse (`canInsertEmptyRow`). Both animate with `layoutAnimation`. APIs: `AppStore.insertEmptyRow(beforeItem:)` / `insertEmptyColumn(beforeItem:)`, matching `SnapToGrid` helpers.
- **Select mode** (`isSelectingItems` / `selectedItemIDs`): enter via **Select…** or Shift-click (collection **>1**). Click toggles; deselecting last exits; empty-canvas click ignored; no open-on-click; no in-canvas reposition / multi-drag. Item menu: batch **Move to Collection** / **Remove from Collection**. Bottom bar: count + Move + Remove + Done. Exit: last deselect, Done, Escape, collection switch, hide, Settings, or start search. **No** keyboard delete/remove.
- Copy casing: **Open With**, **Open in {App}** / **Always Open in**.
- **Files / folders — Open With…** (`OpenWithPanel`): NSOpenPanel + **Always Open in** checkbox. Checked → save per-item Open With; unchecked → one-shot.
- **URL items — Open With** / **Always Open in** browser submenus (`BrowserLocator`). Open With one-shots; Always Open in saves + opens. Rows: 16pt app icon (`preferredImageVisibility` forced on macOS 26+); **current Open With browser is bold** via `attributedTitle` (`MenuItem.isBold`) — not a checkbox. No `NSOpenPanel` for URLs.
- **Clear Open With** → primary returns to `Open`.
- No “Open With Cursor” context-menu item (Cursor is on Finder-drop dialog only).
- Cursor locator: `com.todesktop.230313mzl4w4u92`, `com.cursor.Cursor`, `/Applications/Cursor.app` (LS first, then on-disk fallback).

### Menu bar

- Status item: SF Symbol `square.grid.2x2` (template)
- Left click / hotkey: show if hidden; hide if front; raise (no re-center) if visible but inactive
- Right click: Quick Access (collections by `sortIndex`; items within each **A–Z**), Settings… (⌘,), **Show Scatter**, Quit — text-only. Empty collections → disabled **Empty**. Quick Access opens use `keepWindowOpen: true`. At launch set `NSMenuEnableActionImages` = `false` (macOS 26+ SF Symbol injection).
- Default hotkey: ⌥⌘Space (`KeyboardShortcuts.Name.toggleApp`)

## Build / run

```bash
cd /Users/murad/Work/Scatter
xcodegen generate
xcodebuild -scheme Scatter -configuration Debug -derivedDataPath build build
open "build/Build/Products/Debug/Scatter.app"
```

Signing: ad-hoc (`CODE_SIGN_IDENTITY=-`) for local personal use.

## Extension hooks (future agents)

When changing behavior:

1. Update this `SPEC.md` in the same change set.
2. Prefer extending `AppStore` mutations over scattering side effects in views.
3. Keep first-launch starter seed simple; do not quietly re-import from other apps.
4. Keep drag free-form visually; drop commits via `placeReplacing` (no separate Snap to Grid command).
5. Do not reintroduce Quick Look / Spotlight / Sparkle / licensing without an explicit new product decision.
6. After Swift edits, build with `xcodebuild` before claiming done.
7. Visual target remains a dark sidebar + icon tiles launcher, not a generic settings dashboard.
8. Product display name in Swift UI/copy comes from `AppIdentity.displayName` — do not bake the product name into type/symbol identifiers.

## Known implementation notes

- Windows are AppKit-owned (`AppDelegate`); main is nonactivating `NSPanel`, Settings is `NSWindow`. SwiftUI `Settings` scene is an `EmptyView` stub for `@main` only — never present it. `CommandGroup(replacing: .appSettings)` routes Settings… / ⌘, to the AppKit window; `applicationShouldOpenUntitledFile` returns `false` so launch/reopen does not open the stub.
- Window visibility / Settings reopen: `AppDelegate` Combine sinks on `$isMainWindowVisible` (show/hide on transitions) and `$settingsRequestID` (`dropFirst` + increments → show Settings). No polling.
- Key handling via `KeyMonitor` (`NSEvent` local monitor) inside `MainWindowView`. Handler runs only when the key window is `LauncherWindow` (not while Settings or another window is key). Also suppressed while open-failure / ingest-failure / save-failure alerts, Finder-drop Open With choice (`isPresentingItemOpenChoice`), item Rename (`isPresentingItemRename`), or New/Rename Collection alerts (`isPresentingCollectionAlert`). `LauncherWindow` Esc / `cancelOperation` share the same `handleMainWindowCancel` gates.
- Collection delete rewrites `sortIndex` from **sorted** remaining order (same as `moveCollection`), not raw array index.
- Pasteboard: when file URLs **or** `code/file-list` paths are present but none exist on disk, ingest returns empty (beep) — do not fall through to http(s)/text. Generic `NSURL` / `.fileURL` fallbacks also drop missing file paths (keep non-file URLs); if that branch offered only missing files, return empty.
- AppKit context menus: `MenuItem.isBold` → bold title (URL Open With selection); `MenuItem.isOn` → checkbox (Time Zone toggle). Item accent highlight clears when `popUpContextMenu` returns (not via global menu tracking notifications).