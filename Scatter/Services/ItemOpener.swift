import AppKit
import Darwin

struct DraggedWebLink {
    var url: URL
    var title: String?
}

enum ItemOpener {
    /// Launch only — never modifies, updates, or deletes the target app/file/folder.
    /// Uses the item’s saved Open With app when set; otherwise the system default.
    static func open(_ item: LauncherItem, settings: AppState.Settings, keepWindowOpen: Bool, store: AppStore) {
        open(item, withApplicationAt: nil, settings: settings, keepWindowOpen: keepWindowOpen, store: store)
    }

    /// Open with an explicit app (one-shot or after Always Open in). `nil` uses saved Open With / system default.
    /// Hides the launcher only after a successful open when `keepWindowOpen` is false. Failures keep/show the window with an alert.
    static func open(
        _ item: LauncherItem,
        withApplicationAt applicationURL: URL?,
        settings: AppState.Settings,
        keepWindowOpen: Bool,
        store: AppStore
    ) {
        guard let url = item.resolvedURL() else {
            Task { @MainActor in
                store.reportOpenFailure(
                    itemName: item.displayName,
                    message: "The item’s location could not be resolved."
                )
            }
            return
        }

        // Missing targets / Open With apps: do not call NSWorkspace — Launch Services often returns
        // a misleading error (blames the wrong side) and may also surface a Finder alert.
        if item.kind != .url, !FileManager.default.fileExists(atPath: url.path) {
            Task { @MainActor in
                store.reportOpenFailure(
                    itemName: item.displayName,
                    message: missingTargetMessage(for: item.kind)
                )
            }
            return
        }

        let wantsOpenWith = applicationURL != nil
            || item.openWithBundleIdentifier != nil
            || item.openWithBookmarkData != nil
        let resolvedOpenWith: URL?
        if let applicationURL {
            resolvedOpenWith = applicationExists(at: applicationURL) ? applicationURL : nil
        } else if item.kind == .app {
            resolvedOpenWith = nil
        } else {
            resolvedOpenWith = resolveOpenWithApp(for: item)
        }
        if wantsOpenWith, item.kind != .app, resolvedOpenWith == nil {
            Task { @MainActor in
                store.reportOpenFailure(
                    itemName: item.displayName,
                    message: missingOpenWithMessage(for: item, applicationURL: applicationURL)
                )
            }
            return
        }

        let configuration = openConfiguration(item: item, settings: settings)
        let hideOnSuccess = !keepWindowOpen
        let injectsTimeZone = item.applyTimeZone
            && !launchEnvironment(timeZoneIdentifier: settings.timeZoneIdentifier).isEmpty

        let finish: (Error?) -> Void = { error in
            Task { @MainActor in
                store.endExternalLaunch()
                if let error {
                    store.reportOpenFailure(
                        itemName: item.displayName,
                        message: error.localizedDescription
                    )
                } else if hideOnSuccess {
                    store.hideMainWindow()
                }
            }
        }

        // Prepare on the main actor *before* calling LS so we never race focus steal vs launch.
        // Stay visible/active until LS accepts the handoff — hiding an LSUIElement app first can
        // abort or bounce-then-kill some target apps.
        Task { @MainActor in
            store.beginExternalLaunch()

            if let openWithURL = resolvedOpenWith {
                NSWorkspace.shared.open([url], withApplicationAt: openWithURL, configuration: configuration) { _, error in
                    finish(error)
                }
            } else if item.kind == .app {
                launchApp(
                    at: url,
                    itemName: item.displayName,
                    configuration: configuration,
                    injectsTimeZone: injectsTimeZone,
                    hideOnSuccess: hideOnSuccess,
                    store: store
                )
            } else {
                NSWorkspace.shared.open(url, configuration: configuration) { _, error in
                    finish(error)
                }
            }
        }
    }

    /// Apps without TZ use `/usr/bin/open` (Finder’s launcher). TZ needs `OpenConfiguration.environment`, so that path stays on NSWorkspace.
    private static func launchApp(
        at url: URL,
        itemName: String,
        configuration: NSWorkspace.OpenConfiguration,
        injectsTimeZone: Bool,
        hideOnSuccess: Bool,
        store: AppStore
    ) {
        if injectsTimeZone {
            NSWorkspace.shared.open(url, configuration: configuration) { app, error in
                if let error {
                    reportAppLaunchFailure(
                        bundleURL: url,
                        itemName: itemName,
                        fallbackMessage: error.localizedDescription,
                        store: store
                    )
                    return
                }
                confirmAppStillRunning(
                    bundleURL: url,
                    launched: app,
                    itemName: itemName,
                    hideOnSuccess: hideOnSuccess,
                    store: store
                )
            }
            return
        }

        openAppViaOpenCommand(
            url: url,
            itemName: itemName,
            hideOnSuccess: hideOnSuccess,
            store: store
        )
    }

    /// Spawn `/usr/bin/open` so the target is not launched as a subordinate of our LSUIElement process.
    private static func openAppViaOpenCommand(
        url: URL,
        itemName: String,
        hideOnSuccess: Bool,
        store: AppStore
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [url.path]
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    reportAppLaunchFailure(
                        bundleURL: url,
                        itemName: itemName,
                        fallbackMessage: "“open” failed with status \(process.terminationStatus).",
                        store: store
                    )
                    return
                }
                confirmAppStillRunning(
                    bundleURL: url,
                    launched: nil,
                    itemName: itemName,
                    hideOnSuccess: hideOnSuccess,
                    store: store
                )
            } catch {
                reportAppLaunchFailure(
                    bundleURL: url,
                    itemName: itemName,
                    fallbackMessage: error.localizedDescription,
                    store: store
                )
            }
        }
    }

    /// Gatekeeper / crash-on-launch often completes with `error == nil` before the process dies.
    private static func confirmAppStillRunning(
        bundleURL: URL,
        launched: NSRunningApplication?,
        itemName: String,
        hideOnSuccess: Bool,
        store: AppStore
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            let stillRunning: Bool
            if let launched, !launched.isTerminated {
                stillRunning = true
            } else {
                stillRunning = isApplicationRunning(at: bundleURL)
            }

            Task { @MainActor in
                store.endExternalLaunch()
                if stillRunning {
                    if hideOnSuccess { store.hideMainWindow() }
                } else {
                    reportAppLaunchFailure(
                        bundleURL: bundleURL,
                        itemName: itemName,
                        fallbackMessage: "The application quit immediately after launching.",
                        store: store
                    )
                }
            }
        }
    }

    private static func reportAppLaunchFailure(
        bundleURL: URL,
        itemName: String,
        fallbackMessage: String,
        store: AppStore
    ) {
        let blocking = launchBlockingAttributes(at: bundleURL)
        let message: String
        let command: String?
        if blocking.isEmpty {
            message = fallbackMessage
            command = nil
        } else {
            let listed = blocking.joined(separator: ", ")
            // Quarantine often lives on Contents/MacOS/executable, not the .app root — clear recursively.
            let clearCommand = "xattr -cr \(shellSingleQuoted(bundleURL.path))"
            command = clearCommand
            message = """
            \(fallbackMessage)

            Blocking extended attributes (\(listed)) were found inside the app bundle (not only on the .app icon).

            Clear them recursively in Terminal (\(AppIdentity.displayName) will not modify other apps), then try again:

            \(clearCommand)
            """
        }
        Task { @MainActor in
            store.reportOpenFailure(itemName: itemName, message: message, recoveryCommand: command)
        }
    }

    /// Quarantine / provenance flags that commonly prevent Launch Services from keeping an app running.
    private static let launchBlockingAttributeNames = [
        "com.apple.quarantine",
        "com.apple.provenance",
    ]

    /// Check the bundle root and common nested paths — Finder may clear only the root flag.
    private static func launchBlockingAttributes(at url: URL) -> [String] {
        var present = Set<String>()
        var candidates = [
            url,
            url.appendingPathComponent("Contents", isDirectory: true),
            url.appendingPathComponent("Contents/MacOS", isDirectory: true),
        ]
        if let executable = Bundle(url: url)?.executableURL {
            candidates.append(executable)
        }
        for candidate in candidates {
            for name in extendedAttributeNames(at: candidate) where launchBlockingAttributeNames.contains(name) {
                present.insert(name)
            }
        }
        return launchBlockingAttributeNames.filter { present.contains($0) }
    }

    private static func extendedAttributeNames(at url: URL) -> [String] {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return [] }
            let size = listxattr(path, nil, 0, 0)
            guard size > 0 else { return [] }
            var buffer = [CChar](repeating: 0, count: size)
            let written = listxattr(path, &buffer, buffer.count, 0)
            guard written > 0 else { return [] }
            return buffer[..<written]
                .split(separator: 0)
                .compactMap { chunk -> String? in
                    guard !chunk.isEmpty else { return nil }
                    return String(decoding: chunk.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
        }
    }

    private static func shellSingleQuoted(_ string: String) -> String {
        "'\(string.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func isApplicationRunning(at bundleURL: URL) -> Bool {
        let target = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let bundleID = Bundle(url: target)?.bundleIdentifier
        return NSWorkspace.shared.runningApplications.contains { app in
            if let bundleID, app.bundleIdentifier == bundleID {
                return true
            }
            guard let running = app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL else { return false }
            return running == target
        }
    }

    /// `TZ` for a new app instance. Empty when the preference is system / unset / unknown.
    /// `__XPC_TZ` is intentionally omitted: Core Foundation reads `TZ` (then `TZFILE`), and this
    /// OS has no `__XPC_TZ` consumer in the dyld shared cache.
    static func launchEnvironment(timeZoneIdentifier: String?) -> [String: String] {
        guard let timeZoneIdentifier, TimeZone(identifier: timeZoneIdentifier) != nil else { return [:] }
        return ["TZ": timeZoneIdentifier]
    }

    private static func missingTargetMessage(for kind: LauncherItem.Kind) -> String {
        switch kind {
        case .folder:
            return "This folder no longer exists."
        case .file:
            return "This file no longer exists."
        case .app:
            return "This application no longer exists."
        case .url:
            return "The item’s location could not be resolved."
        }
    }

    private static func missingOpenWithMessage(for item: LauncherItem, applicationURL: URL?) -> String {
        let name = applicationURL.map { OpenWithPanel.displayName(forApplicationAt: $0) }
            ?? OpenWithPanel.displayName(
                bundleID: item.openWithBundleIdentifier,
                bookmark: item.openWithBookmarkData
            )
        if let name {
            return "“\(name)” could not be found."
        }
        return "The Open With application could not be found."
    }

    private static func applicationExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private static func openConfiguration(item: LauncherItem, settings: AppState.Settings) -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Allow Gatekeeper / consent UI when needed (Finder shows these; silent openApplication often will not).
        configuration.promptsUserIfNeeded = true
        guard item.applyTimeZone else { return configuration }
        let environment = launchEnvironment(timeZoneIdentifier: settings.timeZoneIdentifier)
        if !environment.isEmpty {
            // Setting `environment` replaces inheritance — only attach when TZ injection is requested.
            configuration.environment = environment
        }
        return configuration
    }

    /// Shows the item in Finder. No-op for URL items (nothing on disk to reveal).
    /// Hides the launcher after a successful reveal when `keepWindowOpen` is false — same as Open.
    static func reveal(_ item: LauncherItem, keepWindowOpen: Bool, store: AppStore) {
        guard item.kind != .url else { return }
        guard let url = item.resolvedURL() else {
            Task { @MainActor in
                store.reportOpenFailure(
                    itemName: item.displayName,
                    message: "The item’s location could not be resolved."
                )
            }
            return
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            Task { @MainActor in
                store.reportOpenFailure(
                    itemName: item.displayName,
                    message: missingTargetMessage(for: item.kind)
                )
            }
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        if !keepWindowOpen {
            Task { @MainActor in
                store.hideMainWindow()
            }
        }
    }

    static func primaryActionTitle(for item: LauncherItem) -> String {
        if let name = OpenWithPanel.displayName(
            bundleID: item.openWithBundleIdentifier,
            bookmark: item.openWithBookmarkData
        ) {
            return "Open in \(name)"
        }
        return "Open"
    }

    static func resolveOpenWithApp(for item: LauncherItem) -> URL? {
        if let bookmark = item.openWithBookmarkData {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), applicationExists(at: url) {
                return url
            }
        }
        if let bundleID = item.openWithBundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           applicationExists(at: url) {
            return url
        }
        return nil
    }

    /// Read-only bookmark (no security scope). Sandbox is off; we only need a stable path reference for launching.
    static func bookmark(forApplicationAt url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.minimalBookmark],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// http(s) link on the drag pasteboard. Safari writes `public.url` here; the item provider is often only a `.webloc` file promise.
    static func draggedWebLink() -> DraggedWebLink? {
        let pasteboard = NSPasteboard(name: .drag)
        guard let url = webURL(on: pasteboard) else { return nil }
        return DraggedWebLink(url: url, title: pasteboard.string(forType: urlNameType))
    }

    /// `public.url-name` from the drag pasteboard (page title), when the browser provided one.
    static func draggedWebTitle() -> String? {
        NSPasteboard(name: .drag).string(forType: urlNameType)
    }

    private static let urlNameType = NSPasteboard.PasteboardType("public.url-name")

    private static func webURL(on pasteboard: NSPasteboard) -> URL? {
        if let string = pasteboard.string(forType: .URL), let url = httpURL(from: string) {
            return url
        }
        guard let data = pasteboard.data(forType: .URL) else { return nil }
        if let string = String(data: data, encoding: .utf8), let url = httpURL(from: string) {
            return url
        }
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? String,
           let url = httpURL(from: plist) {
            return url
        }
        if let url = URL(dataRepresentation: data, relativeTo: nil), isHTTP(url) {
            return url
        }
        return nil
    }

    private static func httpURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), isHTTP(url) else { return nil }
        return url
    }

    private static func isHTTP(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    static func webDisplayName(title: String?, url: URL) -> String {
        if let title {
            let collapsed = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if !collapsed.isEmpty, collapsed != url.absoluteString {
                return collapsed
            }
        }
        return url.host ?? url.absoluteString
    }

    static func makeItem(from url: URL, at position: CGPoint, title: String? = nil) -> LauncherItem? {
        if isHTTP(url) {
            return LauncherItem(
                kind: .url,
                urlString: url.absoluteString,
                displayName: webDisplayName(title: title, url: url),
                position: .init(position)
            )
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }

        let kind: LauncherItem.Kind
        if url.pathExtension.lowercased() == "app" || (isDir.boolValue && url.path.hasSuffix(".app")) {
            kind = .app
        } else if isDir.boolValue {
            kind = .folder
        } else {
            kind = .file
        }

        // Minimal bookmark only — never `.withSecurityScope` (that can trigger App Management TCC).
        let bookmark = try? url.bookmarkData(
            options: [.minimalBookmark],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        // Strip extension for apps and files (folders without an extension are unchanged).
        let name = url.deletingPathExtension().lastPathComponent

        return LauncherItem(
            kind: kind,
            bookmarkData: bookmark,
            urlString: url.absoluteString,
            displayName: name,
            position: .init(position)
        )
    }
}
