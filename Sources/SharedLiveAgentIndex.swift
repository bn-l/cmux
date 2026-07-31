import Darwin
import Foundation

/// Process-wide cache of `RestorableAgentSessionIndex` results for agent fork and restore paths.
@MainActor
final class SharedLiveAgentIndex {
    static let shared = SharedLiveAgentIndex()

    private(set) var index: RestorableAgentSessionIndex?
    private var loadedAt: Date?
    private var liveAgentProcessFingerprint: Set<String> = []
    private var refreshTask: Task<Void, Never>?
    private var forkAvailabilityRefreshTask: Task<Void, Never>?
    private var validatedForkPanelProbeCompletedAt: [RestorableAgentSessionIndex.PanelKey: Date] = [:]
    private var validatedForkPanels = Set<RestorableAgentSessionIndex.PanelKey>()
    private var validatedMissingForkPanels: [RestorableAgentSessionIndex.PanelKey: Date] = [:]
    private var pendingForkValidationPanels = Set<RestorableAgentSessionIndex.PanelKey>()
    private var processScopeFingerprint: Set<String> = []
    private var changePending = false
    private var deferredReloadTimer: DispatchSourceTimer?

    private static let cacheTTL: TimeInterval = 60.0
    private static let forkAvailabilityProbeTTL: TimeInterval = 15.0
    // Floor between event-driven reloads so chatty hook stores cannot keep the
    // measured ~350ms-1.8s loader running at near-continuous duty cycle.
    private static let minEventReloadInterval: TimeInterval = 5.0

    private var directoryWatchSource: DispatchSourceFileSystemObject?
    // DispatchSource file watching requires a delivery queue; state hops back to MainActor.
    private let watchQueue = DispatchQueue(label: "com.cmuxterm.app.sharedLiveAgentIndexWatch")

    private let indexLoader: @Sendable () -> SharedLiveAgentIndexLoader.LoadResult
    private let hookStoreDirectoryProvider: @MainActor () -> String
    private let dateProvider: @MainActor () -> Date

    init(
        indexLoader: @escaping @Sendable () -> SharedLiveAgentIndexLoader.LoadResult = {
            SharedLiveAgentIndexLoader().loadResultSynchronously()
        },
        hookStoreDirectoryProvider: @escaping @MainActor () -> String = {
            RestorableAgentKind.claude.hookStoreFileURL().deletingLastPathComponent().path
        },
        dateProvider: @escaping @MainActor () -> Date = {
            Date()
        }
    ) {
        self.indexLoader = indexLoader
        self.hookStoreDirectoryProvider = hookStoreDirectoryProvider
        self.dateProvider = dateProvider
    }

    deinit {
        refreshTask?.cancel()
        forkAvailabilityRefreshTask?.cancel()
        deferredReloadTimer?.cancel()
        directoryWatchSource?.cancel()
    }

    /// Read the cached snapshot for stale-tolerant callers. Never blocks.
    ///
    /// `directory` is the panel's directory, used to reject a same-panel-id record that
    /// belongs to a different project (see `AgentSessionDirectoryAffinity`); it is only
    /// consulted when no record exists for this exact `(workspaceId, panelId)`.
    func snapshot(workspaceId: UUID, panelId: UUID, directory: String?) -> SessionRestorableAgentSnapshot? {
        scheduleRefreshIfStale()
        return index?.snapshot(workspaceId: workspaceId, panelId: panelId, directory: directory)
    }

    /// Read the cached snapshot for the Fork Conversation context menu. Never blocks.
    func snapshotForForkConversationCandidate(
        workspaceId: UUID,
        panelId: UUID,
        directory: String?
    ) -> SessionRestorableAgentSnapshot? {
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        guard let index,
              validatedForkPanelKey(for: panelKey, directory: directory) != nil else {
            return nil
        }
        return index.snapshot(workspaceId: workspaceId, panelId: panelId, directory: directory)
    }

    /// Read the cached snapshot for an enabled Fork Conversation action. Never blocks.
    func snapshotForForkAvailability(
        workspaceId: UUID,
        panelId: UUID,
        directory: String?
    ) -> SessionRestorableAgentSnapshot? {
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        guard let validationKey = validatedForkPanelKey(for: panelKey, directory: directory),
              hasFreshForkAvailabilityProbe(for: validationKey),
              let index else {
            return nil
        }
        return index.snapshot(workspaceId: workspaceId, panelId: panelId, directory: directory)
    }

    func prepareForkAvailabilityProbe(workspaceId: UUID, panelId: UUID, directory: String?) -> Bool {
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        scheduleRefreshIfStale(validating: panelKey)
        guard let index else {
            requestForkAvailabilityRefresh(validating: panelKey)
            return false
        }
        guard index.snapshot(workspaceId: workspaceId, panelId: panelId, directory: directory) != nil else {
            if let validatedAt = validatedMissingForkPanels[panelKey],
               dateProvider().timeIntervalSince(validatedAt) < Self.minEventReloadInterval {
                return true
            }
            requestForkAvailabilityRefresh(validating: panelKey)
            return false
        }
        guard let validationKey = validatedForkPanelKey(for: panelKey, directory: directory) else {
            requestForkAvailabilityRefresh(validating: panelKey)
            return false
        }
        guard hasFreshForkAvailabilityProbe(for: validationKey) else {
            requestForkAvailabilityRefresh(validating: panelKey)
            return false
        }
        return true
    }

    /// Current cached index. Never blocks.
    func currentIndexSchedulingRefresh() -> RestorableAgentSessionIndex? {
        scheduleRefreshIfStale()
        return index
    }

    func scheduleRefreshIfStale(validating panelKey: RestorableAgentSessionIndex.PanelKey? = nil) {
        ensureWatchingHookStoreDirectory()
        guard refreshTask == nil, forkAvailabilityRefreshTask == nil else {
            if let panelKey {
                pendingForkValidationPanels.insert(panelKey)
            }
            return
        }
        if let loadedAt, dateProvider().timeIntervalSince(loadedAt) < Self.cacheTTL {
            return
        }
        if let panelKey {
            pendingForkValidationPanels.insert(panelKey)
        }
        startReload()
    }

    func refreshForkAvailabilityNow(workspaceId: UUID? = nil, panelId: UUID? = nil) async {
        if let workspaceId, let panelId {
            pendingForkValidationPanels.insert(
                RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
            )
        }
        _ = await reloadIfLiveAgentProcessFingerprintChanged()
    }

    private func requestForkAvailabilityRefresh(validating panelKey: RestorableAgentSessionIndex.PanelKey) {
        pendingForkValidationPanels.insert(panelKey)
        guard refreshTask == nil,
              forkAvailabilityRefreshTask == nil else {
            return
        }
        forkAvailabilityRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.reloadIfLiveAgentProcessFingerprintChanged()
            self.forkAvailabilityRefreshTask = nil
            NotificationCenter.default.post(name: .sharedLiveAgentIndexDidChange, object: self)
            if self.changePending {
                self.changePending = false
                self.handleHookStoreChange()
            }
        }
    }

    private func startReload() {
        deferredReloadTimer?.cancel()
        deferredReloadTimer = nil
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reload(forcePublish: true)
            self.refreshTask = nil
            NotificationCenter.default.post(name: .sharedLiveAgentIndexDidChange, object: self)
            if self.changePending {
                self.changePending = false
                self.handleHookStoreChange()
            }
        }
    }

    private func reloadIfLiveAgentProcessFingerprintChanged() async -> Bool {
        // An in-flight background reload sampled the world BEFORE this caller asked, so
        // adopting its result would answer a question about the past. Callers of this
        // path awaited it precisely because they need a reading taken now — drain the
        // background pass first, then take our own. Returning early here left the
        // caller reading pre-refresh state until the ~5s deferred reload fired.
        if let inFlight = refreshTask {
            await inFlight.value
        }
        guard refreshTask == nil else {
            changePending = true
            return false
        }
        await reload(forcePublish: index == nil)
        return true
    }

    private func reload(forcePublish: Bool) async {
        let indexLoader = self.indexLoader
        let result = await Task.detached(priority: .utility) {
            indexLoader()
        }.value
        guard !Task.isCancelled else { return }
        let loadedAt = dateProvider()
        let hasPendingForkValidations = !pendingForkValidationPanels.isEmpty
        if forcePublish
            || hasPendingForkValidations
            || result.liveAgentProcessFingerprint != liveAgentProcessFingerprint
            || result.processScopeFingerprint != processScopeFingerprint {
            applyReloadedIndex(
                result.index,
                loadedAt: loadedAt,
                liveAgentProcessFingerprint: result.liveAgentProcessFingerprint,
                processScopeFingerprint: result.processScopeFingerprint,
                forkValidatedPanels: result.forkValidatedPanels
            )
        } else {
            self.loadedAt = loadedAt
            self.processScopeFingerprint = result.processScopeFingerprint
            self.validatedForkPanels = result.forkValidatedPanels
            self.validatedForkPanelProbeCompletedAt = forkPanelProbeTimestamps(
                for: result.forkValidatedPanels,
                completedAt: loadedAt
            )
        }
        applyPendingForkValidations()
    }

    private func applyReloadedIndex(
        _ newIndex: RestorableAgentSessionIndex,
        loadedAt: Date,
        liveAgentProcessFingerprint: Set<String>,
        processScopeFingerprint: Set<String>,
        forkValidatedPanels: Set<RestorableAgentSessionIndex.PanelKey>
    ) {
        index = newIndex
        self.loadedAt = loadedAt
        validatedForkPanels = forkValidatedPanels
        validatedForkPanelProbeCompletedAt = forkPanelProbeTimestamps(
            for: forkValidatedPanels,
            completedAt: loadedAt
        )
        validatedMissingForkPanels.removeAll()
        self.liveAgentProcessFingerprint = liveAgentProcessFingerprint
        self.processScopeFingerprint = processScopeFingerprint
    }

    private func applyPendingForkValidations() {
        guard let index else {
            pendingForkValidationPanels.removeAll()
            return
        }
        let now = dateProvider()
        for panelKey in pendingForkValidationPanels {
            // Exact keys straight from the pending set — no cross-workspace fallback is
            // wanted here, so no directory is threaded.
            if index.snapshot(workspaceId: panelKey.workspaceId, panelId: panelKey.panelId, directory: nil) == nil {
                validatedMissingForkPanels[panelKey] = now
            } else if let validationKey = validatedForkPanelKey(for: panelKey, directory: nil) {
                validatedForkPanelProbeCompletedAt[validationKey] = now
            }
        }
        pendingForkValidationPanels.removeAll()
    }

    private func forkPanelProbeTimestamps(
        for panelKeys: Set<RestorableAgentSessionIndex.PanelKey>,
        completedAt: Date
    ) -> [RestorableAgentSessionIndex.PanelKey: Date] {
        Dictionary(uniqueKeysWithValues: panelKeys.map { ($0, completedAt) })
    }

    private func hasFreshForkAvailabilityProbe(for panelKey: RestorableAgentSessionIndex.PanelKey) -> Bool {
        guard let completedAt = validatedForkPanelProbeCompletedAt[panelKey] else { return false }
        return dateProvider().timeIntervalSince(completedAt) < Self.forkAvailabilityProbeTTL
    }

    /// The validated fork key for this panel. The cross-workspace fallback exists because
    /// workspace ids are re-minted on every launch, so after a restart a pane's own
    /// validated key is only findable by panel id — but ungated it also matches other
    /// projects' keys for that panel id, and `Set.first` picks between them by hash
    /// order. Require the same proof the restore fallback requires (a live process that
    /// names this panel, or directory affinity), then pick deterministically.
    private func validatedForkPanelKey(
        for panelKey: RestorableAgentSessionIndex.PanelKey,
        directory: String?
    ) -> RestorableAgentSessionIndex.PanelKey? {
        if validatedForkPanels.contains(panelKey) {
            return panelKey
        }
        guard let index else { return nil }
        return validatedForkPanels
            .filter { candidate in
                guard candidate.panelId == panelKey.panelId,
                      let entry = index.entry(
                          workspaceId: candidate.workspaceId,
                          panelId: candidate.panelId,
                          directory: nil
                      ) else {
                    return false
                }
                return RestorableAgentSessionIndex.panelIdFallbackAccepts(entry, directory: directory)
            }
            .min { $0.workspaceId.uuidString < $1.workspaceId.uuidString }
    }

    private var isForkAvailabilityRefreshInFlight: Bool {
        refreshTask != nil || forkAvailabilityRefreshTask != nil
    }

    private func handleHookStoreChange() {
        if refreshTask != nil || forkAvailabilityRefreshTask != nil {
            changePending = true
            return
        }
        let elapsed = loadedAt.map { dateProvider().timeIntervalSince($0) } ?? .infinity
        if elapsed >= Self.minEventReloadInterval {
            startReload()
        } else if deferredReloadTimer == nil {
            // DispatchSourceTimer coalesces hook-store event bursts without Task.sleep in runtime code.
            let timer = DispatchSource.makeTimerSource(queue: watchQueue)
            timer.schedule(deadline: .now() + (Self.minEventReloadInterval - elapsed))
            timer.setEventHandler { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.deferredReloadTimer?.cancel()
                    self.deferredReloadTimer = nil
                    self.handleHookStoreChange()
                }
            }
            deferredReloadTimer = timer
            timer.resume()
        }
    }

    private func ensureWatchingHookStoreDirectory() {
        guard directoryWatchSource == nil else { return }
        let dir = hookStoreDirectoryProvider()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else {
            return
        }
        // DispatchSource is the platform file-watch bridge; events re-enter MainActor.
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .link, .rename],
            queue: watchQueue
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.handleHookStoreChange() }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        directoryWatchSource = source
        if refreshTask == nil {
            startReload()
        } else {
            changePending = true
        }
    }
}

extension Notification.Name {
    static let sharedLiveAgentIndexDidChange = Notification.Name("cmux.sharedLiveAgentIndexDidChange")
}
