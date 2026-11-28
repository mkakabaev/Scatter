import Foundation

/// Tracks in-flight favicon / page-title fetches for URL launcher items.
@MainActor
final class WebLinkEnricher {
    /// Caps parallel HTML/favicon work so bulk URL paste does not flood the network.
    private static let maxConcurrent = 4

    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Per-item run token so a cancelled Task’s `defer` does not clear a restarted enrichment.
    private var runTokens: [UUID: UUID] = [:]
    private var pending: [UUID: PendingEnrichment] = [:]
    private var pendingOrder: [UUID] = []
    private var runningCount = 0

    private struct PendingEnrichment {
        var item: LauncherItem
        var pageURL: URL
        var itemExists: (UUID) -> Bool
        var setIcon: (UUID, Data) -> Void
        var setDisplayName: (_ itemID: UUID, _ name: String, _ onlyIfCurrentEquals: String) -> Void
    }

    /// Start (or restart) enrichment for a URL item.
    /// Title upgrade only when the tile still shows the host fallback — not after a pasteboard title or Rename.
    func enrich(
        item: LauncherItem,
        pageURL: URL,
        itemExists: @escaping (UUID) -> Bool,
        setIcon: @escaping (UUID, Data) -> Void,
        setDisplayName: @escaping (_ itemID: UUID, _ name: String, _ onlyIfCurrentEquals: String) -> Void
    ) {
        let itemID = item.id
        cancel(itemID: itemID)
        let pendingItem = PendingEnrichment(
            item: item,
            pageURL: pageURL,
            itemExists: itemExists,
            setIcon: setIcon,
            setDisplayName: setDisplayName
        )
        if runningCount < Self.maxConcurrent {
            start(pendingItem)
        } else {
            pending[itemID] = pendingItem
            pendingOrder.append(itemID)
        }
    }

    func cancel(itemID: UUID) {
        // Request cancel only — leave the task slot / `runningCount` for the Task `defer`.
        tasks[itemID]?.cancel()
        if pending.removeValue(forKey: itemID) != nil {
            pendingOrder.removeAll { $0 == itemID }
        }
    }

    func cancel(itemIDs: Set<UUID>) {
        for id in itemIDs {
            cancel(itemID: id)
        }
    }

    func cancelAll() {
        for task in tasks.values {
            task.cancel()
        }
        // Do not clear `tasks` / `runTokens` or zero `runningCount` — each Task's defer
        // still owns its slot. Zeroing here would under-count after hide → show → paste.
        pending.removeAll()
        pendingOrder.removeAll()
    }

    private func start(_ work: PendingEnrichment) {
        let itemID = work.item.id
        let hostFallback = WebDisplayName.of(title: nil, url: work.pageURL)
        let initialName = work.item.displayName
        let shouldUpgradeTitle = initialName == hostFallback
        let token = UUID()
        runTokens[itemID] = token
        runningCount += 1
        tasks[itemID] = Task { @MainActor in
            defer {
                if runTokens[itemID] == token {
                    runTokens[itemID] = nil
                    tasks[itemID] = nil
                }
                runningCount = max(0, runningCount - 1)
                startNextPending()
            }
            let assets = await WebLinkFetcher.fetch(for: work.pageURL)
            guard !Task.isCancelled, work.itemExists(itemID) else { return }
            if let png = assets.png {
                work.setIcon(itemID, png)
            }
            if shouldUpgradeTitle, let title = assets.title {
                let upgraded = WebDisplayName.of(title: title, url: work.pageURL)
                guard upgraded != hostFallback else { return }
                work.setDisplayName(itemID, upgraded, initialName)
            }
        }
    }

    private func startNextPending() {
        while runningCount < Self.maxConcurrent, !pendingOrder.isEmpty {
            let nextID = pendingOrder.removeFirst()
            guard let work = pending.removeValue(forKey: nextID) else { continue }
            start(work)
        }
    }
}
