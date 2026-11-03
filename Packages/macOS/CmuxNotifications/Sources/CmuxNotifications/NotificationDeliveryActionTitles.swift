/// Localized action titles used when installing OS notification categories.
/// The app target creates this value so localization continues to resolve from
/// the app bundle while the package owns category composition.
public struct NotificationDeliveryActionTitles: Sendable, Equatable {
    /// Title for opening a terminal notification.
    public let show: String

    /// Creates the localized titles used by delivery-category actions.
    public init(show: String) {
        self.show = show
    }
}
