import CmuxSettings
import Foundation

/// Settings-file section parser for file editor options, extracted from `KeyboardShortcutSettingsFileStore.swift`, which sits at its file-length budget.
extension CmuxSettingsFileStore {
    func parseFileEditorSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if let value = jsonBool(section["wordWrap"]) {
            snapshot.managedUserDefaults[FilePreviewWordWrapSettings.key] = .bool(value)
        } else if section.keys.contains("wordWrap") {
            logInvalid("fileEditor.wordWrap", sourcePath: sourcePath)
        }
    }
}
