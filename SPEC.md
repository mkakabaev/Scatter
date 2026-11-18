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
- Per-item **Open With** (folders → Cursor is a primary workflow via Finder-drop dialog). No global Settings Open With default.
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
       ├─ JSON persistence
       ├─ ItemOpener / IconProvider / SnapToGrid / LoginItemManager
       └─ SwiftUI: MainWindowView, SettingsView
```

### Key files

| Path | Role |
|------|------|
| `Scatter/App/AppMain.swift` | `@main` App + AppDelegate adaptor |
| `Scatter/App/AppIdentity.swift` | Display name + Application Support folder name |
| `Scatter/App/AppDelegate.swift` | Status item, windows, visibility bridge, quick-access menu |
| `Scatter/Models/LauncherItem.swift` | `ItemKind`, `LauncherItem`, `CodablePoint` |
| `Scatter/Models/SearchHit.swift` | `SearchHit` (type-to-search result) |
| `Scatter/Models/AppState.swift` | `AppState`, `AppState.Collection`, `AppState.Settings` |
| `Scatter/Models/Store.swift` | `AppStore` mutations + persistence |
| `Scatter/Services/ColorHex.swift` | `NSColor` hex parse / format / luminance |
| `Scatter/Services/SidebarLayout.swift` | Sidebar width clamps (alongside `TileMetrics`) |
| `Scatter/Services/TileMetrics.swift` | Tile / cell width & height from prefs |
| `Scatter/Services/SnapToGrid.swift` | Grid layout math |
| `Scatter/Services/ItemOpener.swift` | Open / reveal / makeItem / bookmarks |
| `Scatter/Services/IconProvider.swift` | Item icons + Open With badge + favicon framing |
| `Scatter/Services/FaviconFetcher.swift` | URL-item favicon download → `iconPNGData` |
| `Scatter/Services/CursorLocator.swift` | Resolve Cursor.app for Finder-drop Open With |
| `Scatter/Services/BrowserLocator.swift` | Installed browsers (https ∩ HTML handlers) for URL Open With |
| `Scatter/Services/OpenWithPanel.swift` | NSOpenPanel + “Always Open in” accessory |
| `Scatter/Services/HotkeyManager.swift` | KeyboardShortcuts name (`toggleApp`) |
| `Scatter/Services/LoginItemManager.swift` | `SMAppService` launch-at-login toggle |
| `Scatter/Views/MainWindowView.swift` | Main chrome, key handling, search/canvas shell |
| `Scatter/Views/FreeformCanvasView.swift` | Icon canvas, drag/drop, item context menu |
| `Scatter/Views/CollectionSidebar.swift` | Collections list + reorder + drop-to-move |
| `Scatter/Views/LauncherItemView.swift` | Tile chrome (icon, title, background) |
| `Scatter/Views/ItemBackgroundPicker.swift` | Item background swatches + palette UI |
| `Scatter/Views/SearchOverlayView.swift` | Type-to-search overlay |
| `Scatter/Views/WindowBackgroundDragView.swift` | Empty-area window drag |
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
- Format: Codable `AppState` JSON
- Debounced save (~200ms) via `AppStore.scheduleSave`
- No auto-migration from other apps’ Application Support folders

### Domain model

```txt
AppState
  collections: [AppState.Collection]
  settings: AppState.Settings  // JSON key remains `preferences` for store compatibility

AppState.Collection
  id, name, sortIndex, items: [LauncherItem]

LauncherItem
  id, kind(app|file|folder|url)
  bookmarkData?, urlString?, displayName
  position: CodablePoint {x,y}   // derived top-left of tile; collection-local
  gridColumn, gridRow            // stable grid source of truth; position from SnapToGrid.applyCompressedPositions
  openWithBookmarkData?, openWithBundleIdentifier?
  backgroundColorHex?   // nil = clear tile; palette swatch or any #RRGGBB from NSColorSampler
  applyTimeZone         // default false; when true + Settings has IANA id → inject TZ on open
  iconPNGData?          // URL items: favicon PNG fetched at drop. nil = generic HTML icon

AppState.Settings   // nested to avoid clashing with SwiftUI.Settings
  backgroundColorHex   // `#RRGGBB` or `#AARRGGBB` (alpha); ColorPicker supports opacity
  iconSize, labelSize, gridSpacingHorizontal, gridSpacingVertical
  (icon/label/spacing are whole points)
  selectedCollectionID?, sidebarWidth, windowWidth/Height
  timeZoneIdentifier?   // IANA id; nil = system zone, inject nothing unless item.applyTimeZone
  launchAtLogin
```
Unknown keys in older `state.json` (e.g. removed `defaultOpenFoldersWithBundleID`) are ignored on decode and dropped on the next save.

### First-launch seed

When Scatter `state.json` is missing/undecodable or has zero items total, `AppStore.makeStarterState()` creates:

- Collection **Apps**
- Finder (`/System/Library/CoreServices/Finder.app`) and Safari (`/Applications/Safari.app`) on row 0, columns 0–1

## UX behaviors

### Window / chrome

- Dark floating panel (`LauncherWindow`: `NSPanel` with `.nonactivatingPanel`, `hidesOnDeactivate = false`, `canBecomeKey = true`). Show with `makeKeyAndOrderFront` + `orderFrontRegardless` — **never** `NSApp.activate` on the main window path, so the previous app keeps the menu bar while Scatter stays key for type-to-search. Settings remains a normal activating `NSWindow`, ordered **above** the main panel (`level` + `order(.above)`); do not raise the main panel while Settings is visible (`applicationDidBecomeActive`).
- Traffic lights: **close only** (minimize/zoom hidden). Window stays `.resizable` for edge drag; no Dock miniaturize (agent app).
- Default content size **1042×655**; minimum **640×400**. Content size persisted in preferences; each show **centers on the display under the mouse cursor** (not `NSScreen.main`).
- Left collections (default **206pt**, drag the splitter to resize, range 140–420 and never so wide the canvas is under 280pt); right free-form canvas
- Window is `isMovableByWindowBackground`. Empty **canvas** space (not on a tile): click clears selection; drag past ~4pt calls `NSWindow.performDrag` (`WindowBackgroundDragView`) so the panel moves. Finder/URL drops stay on that empty layer. Empty **sidebar** padding (top chrome above rows, and the fill below the last collection) uses the same drag view; collection rows keep select / reorder / row context menu. Item drag, splitter, gear, search overlay, and background-picker scrim are unchanged.
- Sidebar width is `settings.sidebarWidth`, restored on launch. A narrower window clamps the live width without overwriting a wider saved width until the user drags the splitter
- Sidebar collections are **drag-reorderable**. Order is `sortIndex` (menu-bar collection order and ⌘1–9 follow it) and is restored on launch
- Appearance prefs: background hex (ColorPicker with opacity; opaque `#RRGGBB`, translucent `#AARRGGBB`), icon size, label size, **horizontal** and **vertical** grid spacing (used by drop placement / auto-place / empty-row pitch). Icon size, label size, and both spacings are whole points (rounded on slider set, decode, and in `updateSettings`; no slider ticks). Horizontal **and** vertical spacing ranges are **0–48**. The grid cell width is the painted tile: icon + 8pt title room each side + 6pt horizontal padding each side (`TileMetrics.itemWidth`), so spacing 0 makes neighbors touch without the background overlapping. Main window is `isOpaque = false` with a clear AppKit background; SwiftUI paints the preference color (including alpha) so the desktop shows through when opacity < 1.
- Remember window size in preferences
- `applicationShouldHandleReopen` → `showMainWindow` (e.g. re-click from Launchpad / Finder while already running)

### Launching items

Launch via `NSWorkspace.open(_:configuration:)` / `open(_:withApplicationAt:configuration:)` only. Resolve paths from `urlString` first; bookmarks are `.minimalBookmark` (no security scope).

**Apps:** Do **not** use `openApplication(at:)`. Default (no TZ): spawn `/usr/bin/open <app>` via `Process` so the target is not a subordinate of our `LSUIElement` process (NSWorkspace launches from an agent app were Dock-bouncing then dying for some apps Finder could open). TZ on: `NSWorkspace.open(appURL, configuration:)` with `environment["TZ"]` (required for injection; `/usr/bin/open` cannot set the target’s env). Set `promptsUserIfNeeded = true`. Only set `configuration.environment` when TZ injection is on.

**Focus:** Main window is a nonactivating `NSPanel` (see Window / chrome). Set `AppStore.isLaunchingExternalApp` around the launch so `applicationDidBecomeActive` does **not** raise/steal focus mid-launch. Do **not** hide the window before LS/`open` accepts the handoff (hiding an agent app first can abort the launch). Hide on confirmed success when dismiss-on-open.

**Failures:** On error (or unresolved URL), call `AppStore.reportOpenFailure` (transient `openFailure`, not persisted), ensure the main window is visible, and show a SwiftUI alert (“Couldn’t Open {displayName}” + message). **Pre-check before `NSWorkspace`:** (1) file/folder/app target path missing → “This folder/file/application no longer exists.” (2) per-item or one-shot Open With app missing (bookmark resolves but gone, or bundle id unresolved) → ““{App}” could not be found.” — covers URL→browser, file/folder→helper, same as Cursor. Do **not** call `NSWorkspace` in those cases; otherwise Launch Services may blame the wrong side (missing folder blamed on Cursor, missing browser blamed on the URL) and Finder may show a second alert. `resolveOpenWithApp` only returns an on-disk app.

**App false-success:** After completion, wait ~0.9s and confirm the launched `NSRunningApplication` is not terminated (else match `runningApplications` by bundle URL or bundle ID). If nothing is running, inspect `listxattr` on the bundle **root, Contents, MacOS, and executable** for `com.apple.quarantine` / `com.apple.provenance` (Finder often clears only the root). When present, offer **Copy Command** for `xattr -cr '<app>'` (advise only — never clear attrs yourself; launch-only).

**Time zone:** Settings → Time zone picks the IANA id (default **System** = `timeZoneIdentifier == nil`, inject nothing). Injection is **opt-in per item**: `LauncherItem.applyTimeZone` must be `true` **and** Settings must have a non-nil valid IANA id; then `OpenConfiguration.environment["TZ"]` is set (including URL items so the handler launches with that configuration). Context menu **Time Zone** / **Time Zone (City)** toggles `applyTimeZone` (`AppStore.setApplyTimeZone`). Applies only when Launch Services creates a **new** app instance; an already-running app keeps the environment it started with. Do **not** set `__XPC_TZ` — Core Foundation reads `TZ` then `TZFILE`, and the system dyld cache has no `__XPC_TZ` consumer.

Default click / Return / primary context action:
- **"Open"** — system default handler (no per-item Open With)
- **"Open in {App}"** — when per-item Open With is set (`openWithBundleIdentifier` / bookmark)

| Input | Behavior |
|-------|----------|
| Click / Return | Primary action (Open / Open in App); hide window **only on success** |
| Option-click | Primary action, keep window |
| ⌘-click | Reveal in Finder (no-op for URL items — nothing on disk); hide window **only on success** (Option-⌘ keeps window, same as Open) |
| Escape | If the screen eyedropper is active: cancel the sample and leave the palette open. If background palette is open: close it. If searching: clear search overlay; else hide window (silent — no AppKit beep; `LauncherWindow.cancelOperation`) |
| ⌘↑ / ⌘↓ | Prev/next collection (when not searching) |
| ⌘1–9 | Jump to collection N (when not searching) |
| ⌘, | Open Settings |
| Arrows | Canvas: nearest-neighbor. Search overlay: ↑/↓ move selection in results. **Not** while a rename/new-collection alert (or other text field) is editing |
| Type | Opens **search overlay** (visible text field); matches **saved items across all collections** (no Spotlight). First key is letter/digit/space/`.`/`-`/`_` only. Suppressed while alert TextFields are first responder |

### Search overlay

- Trigger: typing an allowed character while the main window is open (or editing the overlay field). Allowed first characters: letters, digits, space, `.`, `-`, `_`.
- UI: dimmed full-window overlay + centered panel (`clipShape` rounded so list doesn’t square-clip corners); lighter panel fill; AppKit `SearchTextField` (caret at end — **do not** select initial character); no clear-button; results: **48pt** icons, **large regular** title, collection subtitle; tight row padding; **no** kind label (App/File/…).
- Query scope: all collections’ `displayName` substring match; results sorted **A–Z** by `displayName`; canvas underneath is **not** filtered.
- Silent open: `LauncherWindow.keyDown` must **not** call `super` (avoids NSBeep on type-to-search).
- Exit: Escape clears search; **click dimmed overlay** clears search; **window resign key** also `clearSearch()` (overlay dismisses on deactivate).
- APIs: `AppStore.isSearching`, `searchResults: [SearchHit]`, `clearSearch()`, `setSearchQuery(_:)`, `selectAdjacentSearchResult(delta:)`.
- View: `SearchOverlayView.swift`.

### Login item

`SMAppService` is touched **only** when the user toggles “Launch at login” in Settings — never on cold launch.

### Layout

- Drag: starts after ~4pt pointer travel (no long-press); click with little movement opens item. Global-coordinate drag so live moves stay stable.
- While dragging, the item is drawn on top (`zIndex` + ordered last in `ForEach`).
- **Drop target ghost**: dashed accent rounded rect at the landing cell (`SnapToGrid.previewFrame`). Row is chosen by nearest **vertical strip center** (full or half-height empty), probing the dragged tile’s center; ghost is vertically centered in that strip (OK to overlap neighbors on half-height empty rows). Preview geometry must **not** treat the landing empty row as occupied (that pinned the ghost to the previous row’s bottom). Origin row stays occupied until drop. Cleared on drag end.
- Drop Finder/browser items onto canvas → add at drop point
- Drag a sidebar collection to reorder (`sortIndex`, persisted). The drop slot is an index among the other rows (`0` is the top); an accent line marks it. Drag an item onto a sidebar collection to move it between collections
- **Drop** (`SnapToGrid.placeReplacing`): text-insert; **gaps to the right can condense**. Vacate dragged item first. Free target → place only (e.g. `A_XY_Z` → `AX_Y_Z`). Occupied target → shift only the block from the target up to the next empty cell on that row into that gap (e.g. `ABC_D` insert between A/B → `AXBCD`); items beyond the gap stay. No gap on the row → +1 shift of the suffix with wrap to the next row. Final placement uses spring **animation**. No separate Snap to Grid command — drop is the snap.
- **Empty row strips**: Fully empty grid row indices use **half** pitch (`emptyRowHeightFactor = 0.5`). Items store stable `gridColumn`/`gridRow`; absolute `position` is derived via `SnapToGrid.applyCompressedPositions`. That pass also **collapses consecutive empty rows into a single spacer** (leading empties pack to the top; at most one empty between occupied rows) — on drop commit, remove/move, prefs reflow, and launch. Drop targeting still addresses the live strip geometry while dragging. Do **not** re-infer rows from absolute Y during normal layout (compressed positions map to the wrong uniform row). **On launch**, re-apply compressed positions from stored grid. **Legacy exception:** if every item is still `gridColumn`/`gridRow == 0` but drawn away from origin, one-shot bootstrap infers grid from absolute Y, then compresses (`AppStore.refreshCompressedPositionsOnLaunch`).
- **Settings**: gear flush top-trailing (`ignoresSafeArea` top); reopen via `settingsRequestID` or **⌘,**. No Open With section. Settings window is **re-centered on the display under the mouse every time it is shown**, and always fronts **above** the main panel. No empty settings toolbar (that style is for tabbed settings and leaves a blank header strip). General includes **Time zone** (System, or an IANA zone used as `TZ` only for items with Time Zone checked in the context menu, when a new instance starts).
- Item titles: max **2 lines**, tail truncation; tile height from `TileMetrics` (icon + 2-line title). Canvas `.frame` must not clip to 1 line. Full `displayName` is exposed via tooltip (`.help`) on the tile. Title is white (0.92) when the tile has no background or a dark one (`NSColor.isLightBackground` false, relative luminance ≤ 0.179). A light tint uses black (0.88) with a lighter shadow (black 0.2, radius 1). Dark and missing backgrounds keep the stronger shadow (black 0.45, radius 2). The nine palette swatches stay on the white-title side.
- Icons (`IconProvider`): `*.code-workspace` files use **Cursor** as the main icon (no Open With badge). Other items with per-item Open With show a small Open With app icon badge at the **bottom-right** of the main icon. URL items use `iconPNGData` (the fetched favicon) and fall back to the generic HTML icon until it arrives. The favicon is drawn on Apple’s icon grid: an **824/1024** body (~80.5%) centered in the icon slot, with a transparent margin, so it matches neighboring app icons.
- If main window is **visible** and the app activates, **raise to front** (`makeKeyAndOrderFront` + `orderFrontRegardless`, no `NSApp.activate`). Hotkey / status **left-click**: if hidden → show centered on the mouse display as key (nonactivating); if visible and front → hide; if visible but inactive/buried → raise only (no re-center). Frontmost is tracked across `windowDidBecomeKey` / deferred `windowDidResignKey` so status-item clicks (which resign key before the action) still hide when the panel was already front. **Show Scatter**: always show; if already visible, relocate to the mouse display and raise.
- No main header; no sidebar “Collections” label / top spacer; **New Collection** via sidebar context menu only
- Canvas items: top-leading anchored (`offset`)
- **Rename…** context menu edits `displayName` only (does not rename the file on disk). While the rename (or New Collection) alert TextField is focused, `KeyMonitor` must **not** steal keys (arrows / Return / Escape / type-to-search) — check first responder is `NSTextView`/`NSTextField`.
- **Background…** context menu opens a small swatch palette beside the item (`ItemBackgroundPalette`: None + nine colors, plus an eyedropper). Choosing a swatch sets `backgroundColorHex` and closes the palette; **None** clears it. The eyedropper is `NSColorSampler` (system loupe; no Screen Recording permission or entitlement). It can sample any on-screen pixel. A chosen color is stored as sRGB `#RRGGBB` and closes the palette. Escape in the loupe cancels and leaves the palette open. A sampled color that is not one of the nine swatches is marked on the eyedropper. Click outside or Escape dismisses the palette without further change. The tile’s rounded background fills the item (icon and title) and is the same width as the grid cell. Its bottom edge follows the title: two lines keep the full tile (`icon + two-line slot + 20`). One line uses the measured text height in place of that slot, with the same `+ 20` chrome, so the extra 8pt under the title is included. The selection stroke and the light selection wash (when the item has no color) use that same shape. Search rows use the same color behind the icon. Palette session is `AppStore.backgroundPickerItemID` (not persisted). Switching collections, hiding the window, or opening Settings closes it. While it is open, non-command keys are swallowed so type-to-search does not start underneath — except while the loupe is active, when keys pass through.
- **New items** (`ItemOpener.makeItem`): files, folders, and apps use `displayName` of `deletingPathExtension().lastPathComponent` (no file extension in the label). A web link uses the drag’s `public.url-name` (page title) when that string is non-empty and not the URL itself; otherwise the host.
- **Finder drop** of file/folder: confirmation dialog **Default** vs **Open With Cursor**; choice saved as per-item Open With. Apps skip the dialog.
- **Web link drop:** read `public.url` and `public.url-name` synchronously from the drag pasteboard (`NSPasteboard.drag`). Safari writes the link there; its item provider is a `.webloc` file promise, and `loadItem` of `public.file-url` does not yield the http URL. Chrome puts `public.url` on that same pasteboard. Accept **http/https only**. A real on-disk file URL still wins, so a Finder or Chrome file drop is not turned into a bookmark. The link is added with the system handler (no Open With dialog). `FaviconFetcher` then loads favicon candidates (web app `rel=manifest` icons when present — tried first, largest `sizes` first, skipping SVG/monochrome; then `<link rel>` icon / apple-touch-icon from the fetched HTML; then `/favicon.ico` on the **dropped URL’s origin**, plus `/favicon.ico` on the final host after a cross-host redirect). Manifest support covers sites like ya.ru that only ship crisp 256–512px assets there. `/favicon.ico` on the dropped origin keeps icons working when HTML lands on an auth/SSO interstitial. It keeps the **largest decoded bitmap** (the biggest frame inside an `.ico`), stores a PNG up to **256 px** in `iconPNGData` (128 pt icon at 2x; smaller sources are not upscaled), and the tile updates. URLSession may fetch http and https (`NSAllowsArbitraryLoads`).

### Open With

- Resolution order: per-item bookmark (must exist on disk) → per-item bundle id (must exist on disk) → system default when no Open With is set. If Open With **is** set but neither resolves to an installed app, open fails with a missing-app alert (do not silently fall back to the system handler).
- Context menu primary: `Open` or `Open in {App}`; **Reveal in Finder** for app/file/folder only (omitted for URLs). Reveal hides the launcher on success, same as Open.
- Context menu groups: Open (and Reveal when shown) → Open With… / Clear Open With → **Rename… / Background… / Time Zone toggle** → Move / Remove
- Copy casing: **Open With** (feature / chooser), **Open in {App}** / **Always Open in** (`in` lowercase as destination preposition).
- **Apps / files / folders — Open With…** (`OpenWithPanel`): NSOpenPanel + accessory checkbox **Always Open in**
  - Checked on OK → save as per-item Open With; primary becomes `Open in {App}`
  - Unchecked → one-shot open with chosen app; do not change default
- **URL items — Open With** and sibling **Always Open in** menus of installed browsers (`BrowserLocator`: apps that handle both `https:` and HTML; system default first, then A–Z). **Open With** one-shots; **Always Open in** saves per-item Open With and opens. No `NSOpenPanel` for URLs.
- URL open uses the same per-item Open With browser when set (else system default), including TZ injection when enabled
- **Clear Open With** → removes per-item override; primary returns to `Open`
- No “Open With Cursor” context-menu item (Cursor choice is on Finder-drop dialog)
- Cursor locator: `com.todesktop.230313mzl4w4u92`, `com.cursor.Cursor`, `/Applications/Cursor.app`

### Menu bar

- Left click / hotkey: show if hidden; hide if front; raise (no re-center) if visible but inactive
- Right click: Quick Access (collections in `sortIndex` order; items within each collection **A–Z** by `displayName`), Settings… (⌘,), **Show Scatter**, Quit
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

- Windows are AppKit-owned (`AppDelegate`); main is nonactivating `NSPanel`, Settings is `NSWindow`. SwiftUI `Settings` scene is a stub for `@main`.
- Visibility polling via `MainActorWindowBridge` (50ms) bridges `AppStore.isMainWindowVisible` → main panel.
- Key handling via `KeyMonitor` (`NSEvent` local monitor) inside `MainWindowView`.
