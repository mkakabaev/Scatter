import AppKit
import SwiftUI

extension CanvasView {
    var emptyCanvasContextMenuItems: [WindowBackgroundDragView.MenuItem] {
        let items = store.visibleItems
        let settings = store.state.settings
        let size = canvasSize
        return [
            .init(title: "Add…") { point in pickAndAdd(at: point) },
            .separator(),
            .submenu(title: "Layout", children: [
                .init(
                    title: "Delete Row",
                    isEnabled: { point in
                        let cell = SnapToGrid.hitTestCell(
                            at: point,
                            items: items,
                            settings: settings,
                            canvasSize: size
                        )
                        // Enabled only for a fully empty row that delete would collapse.
                        return SnapToGrid.canDeleteEmptyRow(cell.row, items: items)
                    },
                    action: { point in
                        let cell = SnapToGrid.hitTestCell(
                            at: point,
                            items: store.visibleItems,
                            settings: store.state.settings,
                            canvasSize: canvasSize
                        )
                        store.deleteEmptyRow(cell.row)
                    }
                ),
                .init(
                    title: "Delete Column",
                    isEnabled: { point in
                        let cell = SnapToGrid.hitTestCell(
                            at: point,
                            items: items,
                            settings: settings,
                            canvasSize: size
                        )
                        // Enabled only for a fully empty column that delete would collapse.
                        return SnapToGrid.canDeleteEmptyColumn(cell.column, items: items)
                    },
                    action: { point in
                        let cell = SnapToGrid.hitTestCell(
                            at: point,
                            items: store.visibleItems,
                            settings: store.state.settings,
                            canvasSize: canvasSize
                        )
                        store.deleteEmptyColumn(cell.column)
                    }
                ),
            ]),
        ]
    }

    /// AppKit item menu (icons / bold work; SwiftUI `.contextMenu` maps to NSMenu and drops both).
    func itemAppKitContextMenu(_ item: LauncherItem) -> [WindowBackgroundDragView.MenuItem] {
        if store.isSelectingItems {
            return selectionModeAppKitContextMenu(item)
        }
        return normalAppKitContextMenu(item)
    }

    private func selectionModeAppKitContextMenu(_ item: LauncherItem) -> [WindowBackgroundDragView.MenuItem] {
        let targets = contextMenuTargetIDs(for: item)
        let selectedID = store.selectedCollection?.id
        let moveChildren = store.sortedCollections.map { collection in
            WindowBackgroundDragView.MenuItem(
                title: collection.name,
                isEnabled: { _ in collection.id != selectedID },
                action: { _ in store.moveItems(targets, toCollection: collection.id) }
            )
        }
        return [
            .submenu(title: "Move to Collection", children: moveChildren),
            .init(title: "Remove from Collection") { _ in store.removeItems(targets) },
        ]
    }

    private func normalAppKitContextMenu(_ item: LauncherItem) -> [WindowBackgroundDragView.MenuItem] {
        var items: [WindowBackgroundDragView.MenuItem] = [
            .init(title: openTitle(for: item)) { _ in
                ItemOpener.open(item, settings: store.state.settings, keepWindowOpen: false, store: store)
            },
        ]
        if item.kind != .url {
            items.append(.init(title: "Reveal in Finder") { _ in
                ItemOpener.reveal(item, keepWindowOpen: false, store: store)
            })
        }
        if item.supportsOpenWith {
            items.append(.separator())
            if item.kind == .url {
                items.append(contentsOf: urlOpenWithAppKitMenus(for: item))
            } else {
                items.append(.init(title: "Open With…") { _ in pickOpenWith(for: item) })
            }
            if item.hasOpenWith {
                items.append(.init(title: "Clear Open With") { _ in
                    store.setOpenWith(for: item.id, bundleID: nil, bookmark: nil)
                })
            }
        }
        items.append(.separator())
        items.append(.init(title: "Rename…") { _ in
            renameText = item.displayName
            renameItemID = item.id
        })
        items.append(.init(title: "Background…") { _ in
            store.selectedItemID = item.id
            store.backgroundPickerItemID = item.id
        })
        items.append(.init(
            title: timeZoneMenuTitle,
            isOn: item.applyTimeZone,
            action: { _ in store.setApplyTimeZone(for: item.id, enabled: !item.applyTimeZone) }
        ))
        items.append(.separator())
        if store.visibleItems.count > 1 {
            items.append(.init(title: "Select…") { _ in
                store.enterItemSelection(seeding: [item.id])
            })
        }
        let visible = store.visibleItems
        items.append(.submenu(title: "Layout", children: [
            .init(
                title: "Insert Row Above",
                isEnabled: { _ in SnapToGrid.canInsertEmptyRow(before: item.gridRow, items: visible) },
                action: { _ in store.insertEmptyRow(beforeItem: item.id) }
            ),
            .init(title: "Insert Column to the Left") { _ in
                store.insertEmptyColumn(beforeItem: item.id)
            },
        ]))
        let selectedID = store.selectedCollection?.id
        items.append(.submenu(title: "Move to Collection", children: store.sortedCollections.map { collection in
            .init(
                title: collection.name,
                isEnabled: { _ in collection.id != selectedID },
                action: { _ in store.moveItem(item.id, toCollection: collection.id) }
            )
        }))
        items.append(.init(title: "Remove from Collection") { _ in
            store.removeItem(item.id)
        })
        return items
    }

    /// IDs the context menu’s Move / Remove should operate on.
    private func contextMenuTargetIDs(for item: LauncherItem) -> Set<UUID> {
        if store.isSelectingItems, store.selectedItemIDs.contains(item.id) {
            return store.selectedItemIDs
        }
        return [item.id]
    }

    private var timeZoneMenuTitle: String {
        guard let identifier = store.state.settings.timeZoneIdentifier,
              TimeZone(identifier: identifier) != nil else {
            return "Time Zone"
        }
        let city = identifier.split(separator: "/").last.map {
            $0.replacingOccurrences(of: "_", with: " ")
        } ?? identifier
        return "Time Zone (\(city))"
    }

    private func openTitle(for item: LauncherItem) -> String {
        guard item.supportsOpenWith, item.hasOpenWith else { return "Open" }
        if let name = OpenWithResolver.resolve(for: item)?.displayName {
            return "Open in \(name)"
        }
        // Open With is set but missing on disk — keep “Open in …” so the label matches failure behavior.
        if let bookmark = item.openWithBookmarkData,
           let url = MinimalBookmark.resolve(bookmark)?.url {
            return "Open in \(FileDisplayName.of(url))"
        }
        return "Open in Missing App"
    }

    /// URL Open With / Always Open in — AppKit so browser icons + bold selection show.
    private func urlOpenWithAppKitMenus(for item: LauncherItem) -> [WindowBackgroundDragView.MenuItem] {
        let browsers = BrowserLocator.installedBrowsers
        let selected = OpenWithResolver.resolve(for: item)?.url.standardizedFileURL
        return [
            .submenu(title: "Open With", children: urlBrowserAppKitChoices(browsers, selected: selected) { browser in
                open(item, withApplicationAt: browser.url, always: false)
            }),
            .submenu(title: "Always Open in", children: urlBrowserAppKitChoices(browsers, selected: selected) { browser in
                open(item, withApplicationAt: browser.url, always: true)
            }),
        ]
    }

    private func urlBrowserAppKitChoices(
        _ browsers: [BrowserLocator.Browser],
        selected: URL?,
        action: @escaping (BrowserLocator.Browser) -> Void
    ) -> [WindowBackgroundDragView.MenuItem] {
        if browsers.isEmpty {
            return [.init(title: "No Browsers Found", isEnabled: { _ in false }, action: { _ in })]
        }
        return browsers.map { browser in
            .init(
                title: browser.displayName,
                image: IconProvider.icon(forApplicationAt: browser.url),
                isBold: selected == browser.url,
                action: { _ in action(browser) }
            )
        }
    }

    private func pickOpenWith(for item: LauncherItem) {
        guard let result = OpenWithPanel.run() else { return }
        open(item, withApplicationAt: result.applicationURL, always: result.alwaysOpenIn)
    }

    private func open(_ item: LauncherItem, withApplicationAt appURL: URL, always: Bool) {
        if always, item.supportsOpenWith {
            store.setOpenWith(
                for: item.id,
                bundleID: Bundle(url: appURL)?.bundleIdentifier,
                bookmark: MinimalBookmark.data(for: appURL)
            )
        }
        ItemOpener.open(
            item,
            withApplicationAt: appURL,
            settings: store.state.settings,
            keepWindowOpen: true,
            store: store
        )
    }
}
