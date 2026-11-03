public import Foundation
import Observation
public import UserNotifications

/// Coordinates OS notification category installation, foreground presentation
/// choices, and response delivery for terminal notifications.
///
/// The coordinator owns the notification delivery/response domain. System
/// access is inverted through ``UserNotificationCenterConfiguring``. Terminal
/// responses route into ``NotificationNavigationCoordinator`` through
/// ``NotificationDeliveryTerminalNavigating``. Notifications never carry
/// actions that answer an agent: there are no Allow/Deny/plan buttons.
@MainActor
@Observable
public final class NotificationDeliveryCoordinator {
    private let center: any UserNotificationCenterConfiguring
    private let terminalNavigation: any NotificationDeliveryTerminalNavigating
    private let terminalIdentifiers: TerminalNotificationDeliveryIdentifiers
    private let actionTitles: NotificationDeliveryActionTitles

    /// The in-flight category installation, retained so reconfiguration can
    /// cancel and replace a previous install instead of racing it.
    @ObservationIgnored private var categoryInstallationTask: Task<Void, Never>?

    /// Creates a notification delivery coordinator with all OS and terminal
    /// side effects supplied through injected seams.
    public init(
        center: any UserNotificationCenterConfiguring,
        terminalNavigation: any NotificationDeliveryTerminalNavigating,
        terminalIdentifiers: TerminalNotificationDeliveryIdentifiers,
        actionTitles: NotificationDeliveryActionTitles
    ) {
        self.center = center
        self.terminalNavigation = terminalNavigation
        self.terminalIdentifiers = terminalIdentifiers
        self.actionTitles = actionTitles
    }

    /// Assigns the `UNUserNotificationCenter` delegate, then installs the
    /// terminal notification category.
    ///
    /// The delegate is installed synchronously so launch-time notification
    /// responses are never dropped. Category installation is fire-and-forget
    /// through the bounded ``UserNotificationCenterConfiguring`` boundary: it
    /// can touch the notification daemon over XPC, so a wedged daemon must
    /// degrade to missing categories rather than a blocked main actor.
    public func configureUserNotifications(delegate: any UNUserNotificationCenterDelegate) {
        center.setDelegate(delegate)
        let categories = notificationCategories()
        categoryInstallationTask?.cancel()
        categoryInstallationTask = Task { [center] in
            _ = await center.setNotificationCategories(categories)
        }
    }

    /// Presentation options for a notification delivered while the app is in
    /// the foreground.
    public func presentationOptions(for notification: UNNotification) -> UNNotificationPresentationOptions {
        presentationOptions(notificationHasSound: notification.request.content.sound != nil)
    }

    /// Handles a notification response from `UNUserNotificationCenterDelegate`.
    public func handleNotificationResponse(_ response: UNNotificationResponse) {
        handle(NotificationDeliveryResponse(response))
    }

    func presentationOptions(notificationHasSound: Bool) -> UNNotificationPresentationOptions {
        var options: UNNotificationPresentationOptions = [.banner, .list]
        if notificationHasSound {
            options.insert(.sound)
        }
        return options
    }

    func handle(_ response: NotificationDeliveryResponse) {
        handleTerminalNotificationResponse(response)
    }

    func notificationCategories() -> Set<UNNotificationCategory> {
        let terminalShowAction = UNNotificationAction(
            identifier: terminalIdentifiers.showActionIdentifier,
            title: actionTitles.show
        )

        let terminalCategory = UNNotificationCategory(
            identifier: terminalIdentifiers.categoryIdentifier,
            actions: [terminalShowAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        return [terminalCategory]
    }

    private func handleTerminalNotificationResponse(_ response: NotificationDeliveryResponse) {
        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier, terminalIdentifiers.showActionIdentifier:
            guard let tabIdString = response.userInfo["tabId"] as? String,
                  let tabId = UUID(uuidString: tabIdString) else {
                return
            }
            let surfaceId: UUID? = {
                guard let surfaceIdString = response.userInfo["surfaceId"] as? String else {
                    return nil
                }
                return UUID(uuidString: surfaceIdString)
            }()
            let notificationId = notificationId(response)
            if let clickAction = NotificationNavClickAction(userInfo: response.userInfo) {
                let didPerform = terminalNavigation.performClickAction(clickAction)
                if didPerform, let notificationId {
                    terminalNavigation.markNotificationRead(id: notificationId)
                }
                return
            }
            if let notificationId {
                _ = terminalNavigation.openNotification(
                    id: notificationId,
                    fallbackTabId: tabId,
                    fallbackSurfaceId: surfaceId
                )
            } else {
                _ = terminalNavigation.open(tabId: tabId, surfaceId: surfaceId, notificationId: nil)
            }
        case UNNotificationDismissActionIdentifier:
            if let notificationId = notificationId(response) {
                terminalNavigation.markNotificationRead(id: notificationId)
            }
        default:
            break
        }
    }

    private func notificationId(_ response: NotificationDeliveryResponse) -> UUID? {
        if let id = UUID(uuidString: response.requestIdentifier) {
            return id
        }
        if let idString = response.userInfo["notificationId"] as? String,
           let id = UUID(uuidString: idString) {
            return id
        }
        return nil
    }
}
