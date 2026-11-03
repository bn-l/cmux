import Foundation

enum MenuBarProfilingProfilePreview {
    static func text(outputURL: URL, summary: String) -> String {
        [
            outputURL.path,
            "",
            fileListText(for: outputURL),
            "",
            String(localized: "statusMenu.profiling.previewSummaryHeader", defaultValue: "summary.md preview:"),
            summary,
        ].joined(separator: "\n")
    }

    static func summaryText(for outputURL: URL) -> String {
        let summaryURL = outputURL.appendingPathComponent("summary.md")
        guard let summary = try? String(contentsOf: summaryURL, encoding: .utf8), !summary.isEmpty else {
            return String(localized: "statusMenu.profiling.summaryMissing", defaultValue: "summary.md is not available yet.")
        }
        return summary
    }

    private static func fileListText(for outputURL: URL) -> String {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: outputURL,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return String(localized: "statusMenu.profiling.filesUnavailable", defaultValue: "Files: unavailable")
        }

        let lines = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
            "- \(url.lastPathComponent) (\(displaySize(for: url)))"
        }
        if lines.isEmpty {
            return String(localized: "statusMenu.profiling.filesEmpty", defaultValue: "Files: none yet")
        }
        return String(localized: "statusMenu.profiling.filesHeader", defaultValue: "Files:") + "\n" + lines.joined(separator: "\n")
    }

    private static func displaySize(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true {
            return String(localized: "statusMenu.profiling.folderSize", defaultValue: "folder")
        }
        return ByteCountFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file)
    }
}
