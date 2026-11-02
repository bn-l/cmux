import Testing
import CmuxGit
@testable import CmuxSidebarGit

@MainActor
@Suite struct WatcherSafetyTests {
    private func makeService(
        host: RecordingSidebarGitHost,
        descriptorReader: any GitMetadataWatchDescriptorReading = GitMetadataService(),
        debugLog: @escaping @Sendable (String) -> Void = { _ in }
    ) -> SidebarGitMetadataService {
        let service = SidebarGitMetadataService(
            workspaceGitMetadataReader: GatedMetadataReader(metadata: .repository(branch: "main")),
            gitMetadataService: descriptorReader,
            pullRequestProbing: RecordingPullRequestProbing(),
            probeLimiter: WorkspaceGitMetadataProbeLimiter(limit: 1),
            clock: ManualGitPollClock(),
            debugLog: debugLog
        )
        service.attach(host: host)
        return service
    }

    private func descriptor(
        repositoryRoot: String,
        identity: String,
        degradation: GitWorkspaceMetadataWatchDegradation? = nil
    ) -> GitWorkspaceMetadataWatchDescriptor {
        GitWorkspaceMetadataWatchDescriptor(
            repositoryRoot: repositoryRoot,
            watchedPaths: [repositoryRoot],
            gitMetadataPaths: [repositoryRoot + "/.git/index"],
            trackedEntryPaths: [repositoryRoot + "/Sources/App.swift"],
            acceptsAllWorkTreeEvents: false,
            eventCoalescingInterval: .milliseconds(250),
            eventFilterIdentity: identity,
            degradation: degradation
        )
    }

    /// Crossing the tracked-file threshold is observable: the watcher degrades
    /// to a bounded strategy and emits one clear diagnostic naming that choice.
    @Test(.timeLimit(.minutes(1)))
    func oversizedRepositoryWatcherLogsItsDegradedMode() async throws {
        let fixture = try SidebarGitLargeRepositoryFixture(entryCount: 4_097)
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: fixture.root.path)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let (logEvents, logContinuation) = AsyncStream<String>.makeStream()
        defer { logContinuation.finish() }
        let service = makeService(
            host: host,
            debugLog: { logContinuation.yield($0) }
        )
        service.workspaceGitTrackedDirectoryByKey[key] = fixture.root.path

        service.updateWorkspaceGitMetadataWatcher(for: key, directory: fixture.root.path)

        var logIterator = logEvents.makeAsyncIterator()
        var matchingLog: String?
        while matchingLog == nil, let message = await logIterator.next() {
            if message.contains("workspace.gitWatch.degraded") {
                matchingLog = message
            }
        }
        service.stopWorkspaceGitMetadataWatcher(for: key)

        let degradedLog = try #require(
            matchingLog,
            "The safety valve must explain when and why a repository leaves direct-scan mode."
        )
        #expect(
            !degradedLog.contains(fixture.root.path),
            "Safety-valve diagnostics must not expose repository paths."
        )
    }

    /// A metadata event received while a descriptor read is in flight invalidates
    /// that result and schedules exactly one read of the newer repository state.
    @Test(.timeLimit(.minutes(1)))
    func metadataEventDuringDescriptorReadSchedulesReplacement() async throws {
        let fixture = try SidebarGitLargeRepositoryFixture(entryCount: 1)
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: fixture.root.path)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let descriptorReader = GatedWatchDescriptorReader()
        let (logEvents, logContinuation) = AsyncStream<String>.makeStream()
        defer { logContinuation.finish() }
        let service = makeService(
            host: host,
            descriptorReader: descriptorReader,
            debugLog: { logContinuation.yield($0) }
        )
        service.workspaceGitTrackedDirectoryByKey[key] = fixture.root.path

        service.updateWorkspaceGitMetadataWatcher(for: key, directory: fixture.root.path)
        #expect(await descriptorReader.nextRequestedDirectory() == fixture.root.path)

        for _ in 0..<5 {
            service.updateWorkspaceGitMetadataWatcher(
                for: key,
                directory: fixture.root.path,
                forceDescriptorRefresh: true
            )
        }
        await descriptorReader.resumeNext(with: descriptor(
            repositoryRoot: fixture.root.path,
            identity: "stale"
        ))

        #expect(await descriptorReader.nextRequestedDirectory() == fixture.root.path)
        await descriptorReader.resumeNext(with: descriptor(
            repositoryRoot: fixture.root.path,
            identity: "fresh",
            degradation: .boundedGitStatus(entryCount: 2, directEntryLimit: 1)
        ))

        var logIterator = logEvents.makeAsyncIterator()
        let appliedLog = try #require(await logIterator.next())
        let installedWatcherKey = try #require(
            service.workspaceGitMetadataWatcherWatchedPathsKeyByProbeKey[key]
        )
        #expect(appliedLog.contains("workspace.gitWatch.degraded"))
        #expect(installedWatcherKey.eventFilterIdentity == "fresh")
        #expect(await descriptorReader.requestCount == 2)
        service.stopWorkspaceGitMetadataWatcher(for: key)
    }

    /// Polls `condition` on the main actor, yielding so the descriptor apply task can run.
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// A rescan whose descriptor read fails (git briefly rewriting `.git` during a
    /// checkout or commit) keeps the working watcher for the same directory.
    /// Stopping it left the workspace's sidebar git state stale until its
    /// directory changed (upstream #12834).
    @Test(.timeLimit(.minutes(1)))
    func failedRescanKeepsTheInstalledWatcherForTheSameDirectory() async throws {
        // Arrange: a watcher installed from a successful descriptor read.
        let fixture = try SidebarGitLargeRepositoryFixture(entryCount: 1)
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: fixture.root.path)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let descriptorReader = GatedWatchDescriptorReader()
        let service = makeService(host: host, descriptorReader: descriptorReader)
        service.workspaceGitTrackedDirectoryByKey[key] = fixture.root.path
        service.updateWorkspaceGitMetadataWatcher(for: key, directory: fixture.root.path)
        #expect(await descriptorReader.nextRequestedDirectory() == fixture.root.path)
        await descriptorReader.resumeNext(with: descriptor(repositoryRoot: fixture.root.path, identity: "installed"))
        #expect(await waitUntil { service.workspaceGitMetadataWatcherWatchedPathsKeyByProbeKey[key] != nil })
        let installed = try #require(service.workspaceGitMetadataWatcherWatchedPathsKeyByProbeKey[key])

        // Act: a git metadata event forces a rescan, and the read fails.
        service.updateWorkspaceGitMetadataWatcher(for: key, directory: fixture.root.path, forceDescriptorRefresh: true)
        #expect(await descriptorReader.nextRequestedDirectory() == fixture.root.path)
        await descriptorReader.resumeNext(with: nil)
        #expect(await waitUntil { service.workspaceGitMetadataWatcherDescriptorRequestsByKey[key] == nil })

        // Assert
        #expect(service.workspaceGitMetadataWatcherWatchedPathsKeyByProbeKey[key] == installed)
        #expect(service.workspaceGitMetadataWatchersByWatchedPathsKey[installed] != nil)
        #expect(service.workspaceGitMetadataWatcherSourceDirectoryByKey[key] == fixture.root.path)
        service.stopWorkspaceGitMetadataWatcher(for: key)
    }

    /// The control: a failed read for a directory the pane has moved to still
    /// releases the watcher it held for the old directory.
    @Test(.timeLimit(.minutes(1)))
    func failedReadAfterADirectoryChangeReleasesTheOldWatcher() async throws {
        // Arrange
        let fixture = try SidebarGitLargeRepositoryFixture(entryCount: 1)
        let other = try SidebarGitLargeRepositoryFixture(entryCount: 1)
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: fixture.root.path)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let descriptorReader = GatedWatchDescriptorReader()
        let service = makeService(host: host, descriptorReader: descriptorReader)
        service.workspaceGitTrackedDirectoryByKey[key] = fixture.root.path
        service.updateWorkspaceGitMetadataWatcher(for: key, directory: fixture.root.path)
        #expect(await descriptorReader.nextRequestedDirectory() == fixture.root.path)
        await descriptorReader.resumeNext(with: descriptor(repositoryRoot: fixture.root.path, identity: "installed"))
        #expect(await waitUntil { service.workspaceGitMetadataWatcherWatchedPathsKeyByProbeKey[key] != nil })

        // Act: the pane moves to another directory and that read fails.
        service.workspaceGitTrackedDirectoryByKey[key] = other.root.path
        service.updateWorkspaceGitMetadataWatcher(for: key, directory: other.root.path)
        #expect(await descriptorReader.nextRequestedDirectory() == other.root.path)
        await descriptorReader.resumeNext(with: nil)
        #expect(await waitUntil { service.workspaceGitMetadataWatcherDescriptorRequestsByKey[key] == nil })

        // Assert
        #expect(service.workspaceGitMetadataWatcherWatchedPathsKeyByProbeKey[key] == nil)
        #expect(service.workspaceGitMetadataWatchersByWatchedPathsKey.isEmpty)
    }

    /// Session restoration clears watcher state even after its probe state has
    /// already completed and no longer owns the key.
    @Test func globalResetStopsWatcherOnlyState() {
        let directory = "/tmp/watcher-only"
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: directory)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let watchedPathsKey = WorkspaceGitMetadataWatchedPathsKey(paths: [directory])
        let service = makeService(host: host)
        let (events, eventContinuation) = AsyncStream<Void>.makeStream()
        let refreshTask = Task {
            for await _ in events {}
        }
        defer {
            eventContinuation.finish()
            refreshTask.cancel()
        }

        service.workspaceGitTrackedDirectoryByKey[key] = directory
        service.setWorkspaceGitMetadataWatcherSourceDirectory(directory, for: key)
        service.setWorkspaceGitMetadataWatcherWatchedPathsKey(watchedPathsKey, for: key)
        service.workspaceGitMetadataWatcherRefreshTasksByWatchedPathsKey[watchedPathsKey] = refreshTask
        service.workspaceGitMetadataWatcherDescriptorRequestsByKey[key] =
            WorkspaceGitMetadataWatcherDescriptorRequest(generation: 1, directory: directory)
        service.workspaceGitMetadataWatcherDescriptorInvalidatedKeys.insert(key)

        service.resetAllWorkspaceGitProbeTracking()

        #expect(service.workspaceGitMetadataWatcherSourceDirectoryByKey.isEmpty)
        #expect(service.workspaceGitMetadataWatcherWatchedPathsKeyByProbeKey.isEmpty)
        #expect(service.workspaceGitMetadataWatcherRefreshTasksByWatchedPathsKey.isEmpty)
        #expect(service.workspaceGitMetadataWatcherDescriptorRequestsByKey.isEmpty)
        #expect(service.workspaceGitMetadataWatcherDescriptorInvalidatedKeys.isEmpty)
        #expect(refreshTask.isCancelled)
    }
}
