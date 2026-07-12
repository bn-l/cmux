import Foundation
import Observation

struct CmuxFeatureFlagDefinition: Identifiable, Equatable {
    var id: String { key }

    let key: String
    let title: String
    let flagDescription: String
    let defaultWhenUnavailable: Bool
}

/// Runtime feature flags for the macOS app. This fork removed the remote
/// (analytics-backed) flag provider, so every flag resolves from a local
/// override or its compiled-in default; there is no network flag source.
///
/// Fallback semantics (flags must never break the app):
/// - With no local override and no remote value, every flag keeps its safe
///   default (release builds hide gated UI; DEBUG defaults keep it visible for
///   dogfood).
/// - A local override, when set, always wins.
///
/// Registry contract (enforced by scripts/lint-feature-flags.py in CI): each
/// flag declares key / owner / reviewBy / defaultWhenUnavailable in the FLAG
/// comment above its property, and its key literal appears nowhere else.
@MainActor
@Observable
final class CmuxFeatureFlags {
    static let shared = CmuxFeatureFlags()

    private static let agentChatUIDefault = false
    private static let sidebarWorkspaceAgentSpinnerDefault = false

    private static let overrideKeyPrefix = "cmux.flags.override."

    // Order is load-bearing for the typed accessors below. A keyed lookup would
    // repeat flag-key literals and violate the feature-flag lint's single
    // evaluation-site rule.
    static let allFlags: [CmuxFeatureFlagDefinition] = {
        [
            // FLAG(key: agent-chat-ui-enabled-release, owner: lawrencecchen,
            //      reviewBy: 2026-10-01, defaultWhenUnavailable: false)
            // Shows the Agent Chat entrypoints: the new-workspace dropdown item,
            // command-palette command, surface-tab-bar button, and shared action
            // executor. Hidden by default until the sidecar UX is ready to ship.
            CmuxFeatureFlagDefinition(
                key: "agent-chat-ui-enabled-release",
                title: String(localized: "featureFlags.agentChat.title", defaultValue: "Agent Chat UI"),
                flagDescription: String(
                    localized: "featureFlags.agentChat.description",
                    defaultValue: "Shows Agent Chat entrypoints in the new-workspace dropdown, command palette, and surface tab bar."
                ),
                defaultWhenUnavailable: CmuxFeatureFlags.agentChatUIDefault
            ),

            // FLAG(key: sidebar-workspace-agent-spinner-experiment, owner: lawrencecchen,
            //      reviewBy: 2026-10-01, defaultWhenUnavailable: false)
            // Shows the coding-agent activity spinner in workspace rows. Hidden
            // by default while multi-agent lifecycle edge cases are investigated.
            CmuxFeatureFlagDefinition(
                key: "sidebar-workspace-agent-spinner-experiment",
                title: String(
                    localized: "featureFlags.sidebarWorkspaceAgentSpinner.title",
                    defaultValue: "Workspace agent spinner"
                ),
                flagDescription: String(
                    localized: "featureFlags.sidebarWorkspaceAgentSpinner.description",
                    defaultValue: "Shows a spinner in workspace rows while coding agents are running."
                ),
                defaultWhenUnavailable: CmuxFeatureFlags.sidebarWorkspaceAgentSpinnerDefault
            ),
        ]
    }()

    var isAgentChatUIEnabled: Bool {
        effectiveValue(for: Self.allFlags[0])
    }

    var isSidebarWorkspaceAgentSpinnerEnabled: Bool {
        effectiveValue(for: Self.allFlags[1])
    }

    @ObservationIgnored
    private let defaults: UserDefaults
    @ObservationIgnored
    private let remoteFlagValueProvider: (String) -> Any?

    private var localOverridesByKey: [String: Bool] = [:]
    private var remoteValuesByKey: [String: Bool] = [:]
    private var effectiveValuesByKey: [String: Bool] = [:]

    init(
        defaults: UserDefaults = .standard,
        remoteFlagValueProvider: @escaping (String) -> Any? = { _ in nil }
    ) {
        self.defaults = defaults
        self.remoteFlagValueProvider = remoteFlagValueProvider
        localOverridesByKey = Self.allFlags.reduce(into: [:]) { values, definition in
            if let value = Self.storedOverrideValue(for: definition.key, defaults: defaults) {
                values[definition.key] = value
            }
        }
        recomputeEffectiveValues()
    }

    /// Previously subscribed to remote (analytics-backed) feature-flag payloads.
    /// This fork removed that provider, so flags always resolve from local
    /// overrides and compiled-in defaults; kept as a no-op for call-site parity.
    func start() {}

    func effectiveValue(for definition: CmuxFeatureFlagDefinition) -> Bool {
        effectiveValuesByKey[definition.key] ?? definition.defaultWhenUnavailable
    }

    func overrideValue(for definition: CmuxFeatureFlagDefinition) -> Bool? {
        localOverridesByKey[definition.key]
    }

    func remoteValue(for definition: CmuxFeatureFlagDefinition) -> Bool? {
        remoteValuesByKey[definition.key]
    }

    func setOverride(_ value: Bool?, for definition: CmuxFeatureFlagDefinition) {
        let previousEffectiveValues = effectiveValuesByKey
        if let value {
            localOverridesByKey[definition.key] = value
            defaults.set(value, forKey: Self.overrideDefaultsKey(for: definition.key))
        } else {
            localOverridesByKey.removeValue(forKey: definition.key)
            defaults.removeObject(forKey: Self.overrideDefaultsKey(for: definition.key))
        }
        recomputeEffectiveValues()
        postChangeIfNeeded(previousEffectiveValues: previousEffectiveValues)
    }

    func clearAllOverrides() {
        let previousEffectiveValues = effectiveValuesByKey
        var clearedAnyOverride = false
        for definition in Self.allFlags {
            if localOverridesByKey.removeValue(forKey: definition.key) != nil {
                clearedAnyOverride = true
            }
            defaults.removeObject(forKey: Self.overrideDefaultsKey(for: definition.key))
        }
        guard clearedAnyOverride else { return }
        recomputeEffectiveValues()
        postChangeIfNeeded(previousEffectiveValues: previousEffectiveValues)
    }

    func applyLoadedFlags() {
        let previousEffectiveValues = effectiveValuesByKey
        remoteValuesByKey = Self.allFlags.reduce(into: [:]) { values, definition in
            if let value = Self.coerceBoolFlagValue(remoteFlagValueProvider(definition.key)) {
                values[definition.key] = value
            }
        }
        recomputeEffectiveValues()
        postChangeIfNeeded(previousEffectiveValues: previousEffectiveValues)
    }

    private func recomputeEffectiveValues() {
        effectiveValuesByKey = Self.allFlags.reduce(into: [:]) { values, definition in
            values[definition.key] = localOverridesByKey[definition.key]
                ?? remoteValuesByKey[definition.key]
                ?? definition.defaultWhenUnavailable
        }
    }

    private func postChangeIfNeeded(previousEffectiveValues: [String: Bool]) {
        if Self.allFlags.contains(where: { definition in
            previousEffectiveValues[definition.key] != effectiveValuesByKey[definition.key]
        }) {
            NotificationCenter.default.post(name: .cmuxFeatureFlagsDidChange, object: self)
        }
    }

    private static func overrideDefaultsKey(for key: String) -> String {
        overrideKeyPrefix + key
    }

    private static func storedOverrideValue(for key: String, defaults: UserDefaults) -> Bool? {
        guard let value = defaults.object(forKey: overrideDefaultsKey(for: key)) else {
            return nil
        }
        if let boolValue = value as? Bool {
            return boolValue
        }
        if let numberValue = value as? NSNumber {
            return numberValue.boolValue
        }
        return nil
    }

    nonisolated static func coerceBoolFlagValue(_ value: Any?, default fallback: Bool) -> Bool {
        coerceBoolFlagValue(value) ?? fallback
    }

    nonisolated static func coerceBoolFlagValue(_ value: Any?) -> Bool? {
        guard let value else { return nil }

        if let boolValue = value as? Bool {
            return boolValue
        }

        if let numberValue = value as? NSNumber {
            return numberValue.boolValue
        }

        if let stringValue = value as? String {
            switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true":
                return true
            case "false":
                return false
            default:
                return nil
            }
        }

        return nil
    }
}

extension Notification.Name {
    static let cmuxFeatureFlagsDidChange = Notification.Name("cmuxFeatureFlagsDidChange")
}
