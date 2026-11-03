import Foundation

/// Localized validator messages.
///
/// The keys live in the app's `Resources/Localizable.xcstrings` (CmuxFoundation
/// declares no resources), so they resolve from the main bundle in both the app
/// and the bundled CLI, and fall back to the English default elsewhere.
public struct CmuxConfigValidationLocalization {
    public init() {}
    public func string(
        _ key: StaticString,
        defaultValue: String
    ) -> String {
        String(localized: key, defaultValue: String.LocalizationValue(stringLiteral: defaultValue), bundle: .main)
    }

    public func format(
        _ key: StaticString,
        defaultValue: String,
        _ arguments: any CVarArg...
    ) -> String {
        let localized = string(key, defaultValue: defaultValue)
        return String(format: localized, locale: Locale.current, arguments: arguments)
    }
}
