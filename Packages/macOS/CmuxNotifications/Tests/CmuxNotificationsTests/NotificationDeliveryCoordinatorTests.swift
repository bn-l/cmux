import Foundation
import Testing
import UserNotifications
@testable import CmuxNotifications

@MainActor
private final class FakeNotificationCenter: UserNotificationCenterConfiguring {
    private(set) var categories: Set<UNNotificationCategory> = []
    private(set) var delegate: (any UNUserNotificationCenterDelegate)?

    /// When true, category installation suspends until
    /// ``releaseCategoryInstall()``, modeling the framework's unbounded wait
    /// on a wedged daemon.
    var stallCategoryInstall = false
    private var stallWaiters: [CheckedContinuation<Void, Never>] = []
    private var categoryInstallWaiters: [CheckedContinuation<Void, Never>] = []

    func setNotificationCategories(
        _ categories: Set<UNNotificationCategory>
    ) async -> Result<Void, UserNotificationCenterFailure> {
        if stallCategoryInstall {
            await withCheckedContinuation { stallWaiters.append($0) }
        }
        self.categories = categories
        let waiters = categoryInstallWaiters
        categoryInstallWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        return .success(())
    }

    func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {
        self.delegate = delegate
    }

    /// Suspends until the fire-and-forget category install has landed.
    func waitForCategoryInstall() async {
        guard categories.isEmpty else { return }
        await withCheckedContinuation { categoryInstallWaiters.append($0) }
    }

    /// Lets a stalled category installation proceed.
    func releaseCategoryInstall() {
        stallCategoryInstall = false
        let waiters = stallWaiters
        stallWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

@MainActor
private final class FakeTerminalNavigation: NotificationDeliveryTerminalNavigating {
    struct OpenCall: Equatable {
        let tabId: UUID
        let surfaceId: UUID?
        let notificationId: UUID?
    }

    var openSucceeds = true
    var performSucceeds = true
    private(set) var opens: [OpenCall] = []
    private(set) var storedOpens: [(id: UUID, fallbackTabId: UUID, fallbackSurfaceId: UUID?)] = []
    private(set) var performedClickActions: [NotificationNavClickAction] = []
    private(set) var markedReadIds: [UUID] = []

    func open(tabId: UUID, surfaceId: UUID?, notificationId: UUID?) -> Bool {
        opens.append(OpenCall(tabId: tabId, surfaceId: surfaceId, notificationId: notificationId))
        return openSucceeds
    }

    func openNotification(id: UUID, fallbackTabId: UUID, fallbackSurfaceId: UUID?) -> Bool {
        storedOpens.append((id: id, fallbackTabId: fallbackTabId, fallbackSurfaceId: fallbackSurfaceId))
        return openSucceeds
    }

    func performClickAction(_ action: NotificationNavClickAction) -> Bool {
        performedClickActions.append(action)
        return performSucceeds
    }

    func markNotificationRead(id: UUID) {
        markedReadIds.append(id)
    }
}

private final class DummyNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {}

@Suite(.serialized)
@MainActor
struct NotificationDeliveryCoordinatorTests {
    @Test("configure installs only the terminal category and the delegate")
    func configureInstallsCategoriesAndDelegate() async throws {
        let center = FakeNotificationCenter()
        let delegate = DummyNotificationDelegate()
        let coordinator = makeCoordinator(center: center)

        coordinator.configureUserNotifications(delegate: delegate)
        #expect((center.delegate as AnyObject?) === delegate)
        await center.waitForCategoryInstall()

        let categories = categoriesByIdentifier(center.categories)
        let terminalCategory = try #require(categories["terminal.category"])
        #expect(terminalCategory.actions.map(\.identifier) == ["terminal.show"])
        #expect(terminalCategory.actions.map(\.title) == ["Show"])
        #expect(terminalCategory.options.contains(.customDismissAction))

        // Only the terminal category exists: cmux never offers notification
        // buttons that answer an agent's permission, plan or question prompt.
        #expect(Set(categories.keys) == ["terminal.category"])
    }

    @Test("configuration never blocks its caller on notification-center entry")
    func configureDoesNotBlockCallingExecutor() async {
        let center = FakeNotificationCenter()
        // Category installation cannot finish until the test releases it, so
        // the assertion below is causal: it can only pass when configure hands
        // control back without waiting on the (wedged) center entry.
        center.stallCategoryInstall = true
        let coordinator = makeCoordinator(center: center)

        coordinator.configureUserNotifications(delegate: DummyNotificationDelegate())

        #expect(
            center.categories.isEmpty,
            "configure must return before category installation completes"
        )
        center.releaseCategoryInstall()
        await center.waitForCategoryInstall()
        #expect(!center.categories.isEmpty)
    }

    @Test("presentation options include sound only when the notification has sound")
    func presentationOptions() {
        let coordinator = makeCoordinator()

        let quiet = coordinator.presentationOptions(notificationHasSound: false)
        #expect(quiet.contains(.banner))
        #expect(quiet.contains(.list))
        #expect(!quiet.contains(.sound))

        let audible = coordinator.presentationOptions(notificationHasSound: true)
        #expect(audible.contains(.banner))
        #expect(audible.contains(.list))
        #expect(audible.contains(.sound))
    }

    @Test(
        "Allow/Deny/plan taps on a Feed notification left over from an older build do nothing",
        arguments: [
            ("CMUXFeedPermissionOnceAlways", "feed.permission.always"),
            ("CMUXFeedPermissionDeny", "feed.permission.deny"),
            ("CMUXFeedExitPlan", "feed.exit_plan.autoAccept"),
            ("CMUXFeedQuestion", "feed.question.open"),
        ]
    )
    func leftoverFeedActionIsIgnored(categoryIdentifier: String, actionIdentifier: String) {
        let terminal = FakeTerminalNavigation()
        let coordinator = makeCoordinator(terminalNavigation: terminal)

        coordinator.handle(NotificationDeliveryResponse(
            categoryIdentifier: categoryIdentifier,
            actionIdentifier: actionIdentifier,
            requestIdentifier: "feed.req-1",
            userInfo: ["requestId": "req-1", "tabId": UUID().uuidString]
        ))

        #expect(terminal.opens.isEmpty)
        #expect(terminal.storedOpens.isEmpty)
        #expect(terminal.performedClickActions.isEmpty)
        #expect(terminal.markedReadIds.isEmpty)
    }

    @Test("terminal default response with click action performs and marks read")
    func terminalDefaultClickActionPerformsAndMarksRead() {
        let terminal = FakeTerminalNavigation()
        let notificationId = UUID()
        let tabId = UUID()
        let coordinator = makeCoordinator(terminalNavigation: terminal)

        coordinator.handle(NotificationDeliveryResponse(
            categoryIdentifier: "terminal.category",
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            requestIdentifier: notificationId.uuidString,
            userInfo: [
                "tabId": tabId.uuidString,
                "cmuxClickAction": "revealInFinder",
                "cmuxRevealInFinderPath": "/tmp/report.txt",
            ]
        ))

        #expect(terminal.performedClickActions == [.revealInFinder(path: "/tmp/report.txt")])
        #expect(terminal.markedReadIds == [notificationId])
        #expect(terminal.opens.isEmpty)
    }

    @Test("terminal default response opens stored notification using notificationId fallback")
    func terminalDefaultOpensStoredNotification() {
        let terminal = FakeTerminalNavigation()
        let tabId = UUID()
        let surfaceId = UUID()
        let notificationId = UUID()
        let coordinator = makeCoordinator(terminalNavigation: terminal)

        coordinator.handle(NotificationDeliveryResponse(
            categoryIdentifier: "terminal.category",
            actionIdentifier: "terminal.show",
            requestIdentifier: "not-a-uuid",
            userInfo: [
                "tabId": tabId.uuidString,
                "surfaceId": surfaceId.uuidString,
                "notificationId": notificationId.uuidString,
            ]
        ))

        #expect(terminal.storedOpens.count == 1)
        #expect(terminal.storedOpens.first?.id == notificationId)
        #expect(terminal.storedOpens.first?.fallbackTabId == tabId)
        #expect(terminal.storedOpens.first?.fallbackSurfaceId == surfaceId)
        #expect(terminal.opens.isEmpty)
        #expect(terminal.markedReadIds.isEmpty)
    }

    @Test("terminal default response without notification id opens raw tab and surface")
    func terminalDefaultWithoutNotificationIdOpensTarget() {
        let terminal = FakeTerminalNavigation()
        let tabId = UUID()
        let surfaceId = UUID()
        let coordinator = makeCoordinator(terminalNavigation: terminal)

        coordinator.handle(NotificationDeliveryResponse(
            categoryIdentifier: "terminal.category",
            actionIdentifier: "terminal.show",
            requestIdentifier: "not-a-uuid",
            userInfo: [
                "tabId": tabId.uuidString,
                "surfaceId": surfaceId.uuidString,
            ]
        ))

        #expect(terminal.opens == [.init(tabId: tabId, surfaceId: surfaceId, notificationId: nil)])
        #expect(terminal.storedOpens.isEmpty)
        #expect(terminal.markedReadIds.isEmpty)
    }

    @Test("terminal dismiss marks notification read using request identifier")
    func terminalDismissMarksRead() {
        let terminal = FakeTerminalNavigation()
        let tabId = UUID()
        let notificationId = UUID()
        let coordinator = makeCoordinator(terminalNavigation: terminal)

        coordinator.handle(NotificationDeliveryResponse(
            categoryIdentifier: "terminal.category",
            actionIdentifier: UNNotificationDismissActionIdentifier,
            requestIdentifier: notificationId.uuidString,
            userInfo: ["tabId": tabId.uuidString]
        ))

        #expect(terminal.markedReadIds == [notificationId])
        #expect(terminal.opens.isEmpty)
    }

    @Test("terminal dismiss marks notification read without requiring tab id")
    func terminalDismissMarksReadWithoutTabId() {
        let terminal = FakeTerminalNavigation()
        let notificationId = UUID()
        let coordinator = makeCoordinator(terminalNavigation: terminal)

        coordinator.handle(NotificationDeliveryResponse(
            categoryIdentifier: "terminal.category",
            actionIdentifier: UNNotificationDismissActionIdentifier,
            requestIdentifier: notificationId.uuidString,
            userInfo: [:]
        ))

        #expect(terminal.markedReadIds == [notificationId])
        #expect(terminal.opens.isEmpty)
    }

    private func makeCoordinator(
        center: FakeNotificationCenter = FakeNotificationCenter(),
        terminalNavigation: FakeTerminalNavigation = FakeTerminalNavigation()
    ) -> NotificationDeliveryCoordinator {
        NotificationDeliveryCoordinator(
            center: center,
            terminalNavigation: terminalNavigation,
            terminalIdentifiers: TerminalNotificationDeliveryIdentifiers(
                categoryIdentifier: "terminal.category",
                showActionIdentifier: "terminal.show"
            ),
            actionTitles: NotificationDeliveryActionTitles(show: "Show")
        )
    }

    private func categoriesByIdentifier(
        _ categories: Set<UNNotificationCategory>
    ) -> [String: UNNotificationCategory] {
        Dictionary(uniqueKeysWithValues: categories.map { ($0.identifier, $0) })
    }
}
