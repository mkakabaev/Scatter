import AppKit
import Darwin

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
        guard let target = ItemURLResolver.resolveDetailed(item) else {
            Task { @MainActor in
                store.reportOpenFailure(
                    itemName: item.displayName,
                    message: "The item’s location could not be resolved."
                )
            }
            return
        }
        let url = target.url

        // Missing targets / Open With apps: do not call NSWorkspace — Launch Services often returns
        // a misleading error (blames the wrong side) and may also surface a Finder alert.
        if item.kind != .url, !FileManager.default.fileExists(atPath: url.path) {
            Task { @MainActor in
                store.reportOpenFailure(
                    itemName: item.displayName,
                    message: item.kind.missingTargetMessage
                )
            }
            return
        }

        // Apps never use Open With — ignore any explicit helper URL.
        let wantsOpenWith = item.supportsOpenWith && (applicationURL != nil || item.hasOpenWith)
        let resolvedOpenWith: OpenWithResolver.Resolved?
        if !item.supportsOpenWith {
            resolvedOpenWith = nil
        } else if let applicationURL {
            resolvedOpenWith = OpenWithResolver.resolve(applicationAt: applicationURL)
        } else {
            resolvedOpenWith = OpenWithResolver.resolve(for: item)
        }
        if wantsOpenWith, resolvedOpenWith == nil {
            Task { @MainActor in
                store.reportOpenFailure(
                    itemName: item.displayName,
                    message: missingOpenWithMessage(applicationURL: applicationURL)
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
            store.refreshStaleBookmarks(
                for: item.id,
                itemBookmark: target.refreshedBookmarkData,
                openWithBookmark: resolvedOpenWith?.refreshedBookmarkData
            )
            store.beginExternalLaunch()

            if let openWithURL = resolvedOpenWith?.url {
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

    /// How long to wait for a cold-start app to appear in `NSRunningApplication`.
    private static let appLaunchAppearBudget: TimeInterval = 3.0
    /// After first sighting, re-check so bounce-then-die (Gatekeeper) still fails.
    private static let appLaunchStabilityDelay: TimeInterval = 0.75
    private static let appLaunchPollInterval: TimeInterval = 0.2

    /// Gatekeeper / crash-on-launch often completes with `error == nil` before the process dies.
    /// Poll until the app appears (slow cold starts) then confirm it stays up briefly.
    private static func confirmAppStillRunning(
        bundleURL: URL,
        launched: NSRunningApplication?,
        itemName: String,
        hideOnSuccess: Bool,
        store: AppStore
    ) {
        let started = Date()
        func isRunning() -> Bool {
            if let launched, !launched.isTerminated { return true }
            // Exact bundle path — not bundle ID — so another already-running copy does not
            // mask a quarantined launch that died.
            return isApplicationRunning(at: bundleURL)
        }

        func finishSuccess() {
            Task { @MainActor in
                store.endExternalLaunch()
                if hideOnSuccess { store.hideMainWindow() }
            }
        }

        func finishFailure() {
            reportAppLaunchFailure(
                bundleURL: bundleURL,
                itemName: itemName,
                fallbackMessage: "The application quit immediately after launching.",
                store: store
            )
        }

        func scheduleStabilityCheck() {
            DispatchQueue.main.asyncAfter(deadline: .now() + appLaunchStabilityDelay) {
                if isRunning() {
                    finishSuccess()
                } else {
                    finishFailure()
                }
            }
        }

        func pollForAppearance() {
            DispatchQueue.main.asyncAfter(deadline: .now() + appLaunchPollInterval) {
                if isRunning() {
                    scheduleStabilityCheck()
                } else if Date().timeIntervalSince(started) >= appLaunchAppearBudget {
                    finishFailure()
                } else {
                    pollForAppearance()
                }
            }
        }

        if isRunning() {
            scheduleStabilityCheck()
        } else {
            pollForAppearance()
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
            store.endExternalLaunch()
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
        return NSWorkspace.shared.runningApplications.contains { app in
            guard let running = app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL else {
                return false
            }
            return running == target
        }
    }

    /// `TZ` for a new app instance. Empty when the preference is system / unset / unknown.
    /// `__XPC_TZ` is intentionally omitted: Core Foundation reads `TZ` (then `TZFILE`), and this
    /// OS has no `__XPC_TZ` consumer in the dyld shared cache.
    private static func launchEnvironment(timeZoneIdentifier: String?) -> [String: String] {
        guard let timeZoneIdentifier, TimeZone(identifier: timeZoneIdentifier) != nil else { return [:] }
        return ["TZ": timeZoneIdentifier]
    }

    private static func missingOpenWithMessage(applicationURL: URL?) -> String {
        // One-shot path may be missing on disk but the path still yields a label.
        if let applicationURL {
            return "“\(FileDisplayName.of(applicationURL))” could not be found."
        }
        return "The Open With application could not be found."
    }

    private static func openConfiguration(item: LauncherItem, settings: AppState.Settings) -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Allow Gatekeeper / consent UI when needed (Finder shows these; silent openApplication often will not).
        configuration.promptsUserIfNeeded = true
        guard item.applyTimeZone else { return configuration }
        let tz = launchEnvironment(timeZoneIdentifier: settings.timeZoneIdentifier)
        guard !tz.isEmpty else { return configuration }
        // `OpenConfiguration.environment` replaces inheritance when non-nil — merge onto the
        // current process environment so PATH/HOME/etc. survive, then overlay TZ.
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in tz {
            environment[key] = value
        }
        configuration.environment = environment
        return configuration
    }

    /// Shows the item in Finder. No-op for URL items (nothing on disk to reveal).
    /// Hides the launcher after a successful reveal when `keepWindowOpen` is false — same as Open.
    static func reveal(_ item: LauncherItem, keepWindowOpen: Bool, store: AppStore) {
        guard item.kind != .url else { return }
        guard let target = ItemURLResolver.resolveDetailed(item) else {
            Task { @MainActor in
                store.reportOpenFailure(
                    itemName: item.displayName,
                    message: "The item’s location could not be resolved."
                )
            }
            return
        }
        let url = target.url
        if !FileManager.default.fileExists(atPath: url.path) {
            Task { @MainActor in
                store.reportOpenFailure(
                    itemName: item.displayName,
                    message: item.kind.missingTargetMessage
                )
            }
            return
        }
        Task { @MainActor in
            store.refreshStaleBookmarks(for: item.id, itemBookmark: target.refreshedBookmarkData, openWithBookmark: nil)
            // Nest the launch gate so Finder activation does not re-raise the launcher mid-handoff.
            store.beginExternalLaunch()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            if !keepWindowOpen {
                store.hideMainWindow()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                store.endExternalLaunch()
            }
        }
    }
}
