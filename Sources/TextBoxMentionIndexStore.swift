import Foundation
import OSLog

/// Completion candidates for the text box's `@file` and `/skill` / `$skill`
/// mentions.
///
/// File mentions list only the folder the typed path names, like shell
/// completion: `@` lists the pane's folder, `@src/` lists `src/`, and the text
/// after the last `/` filters that one listing. Nothing is indexed ahead of
/// time and no subfolder is walked. Upstream (#5021) prebuilt a recursive
/// index with `rg --files` whenever a text box got its folder, which walked
/// the whole home folder (and tripped the Desktop/Documents/Photos privacy
/// prompts) for every pane opened in `~`.
actor TextBoxMentionIndexStore {
    static let shared = TextBoxMentionIndexStore()

    private static let logger = Logger(subsystem: "com.cmuxterm.app", category: "textbox-mentions")
    private static let maxIndexedSkills = 800
    private static let suggestionLimit = 500
    private static let skippedDirectoryNames: Set<String> = [
        ".build",
        ".git",
        ".next",
        ".swiftpm",
        ".vercel",
        "DerivedData",
        "Library",
        "node_modules",
        "Pods",
        "vendor"
    ]
    private static let skippedPackageDirectorySuffixes = [
        ".app",
        ".appex",
        ".bundle",
        ".dSYM",
        ".framework",
        ".kext",
        ".mdimporter",
        ".plugin",
        ".prefPane",
        ".qlgenerator",
        ".rtfd",
        ".xcframework",
        ".xcodeproj",
        ".xcworkspace",
        ".playground"
    ]

    private var skillIndexesByRootKey: [String: TextBoxMentionCandidateIndex] = [:]

    func suggestions(
        for query: TextBoxMentionQuery,
        rootDirectory: String?
    ) async -> [TextBoxMentionSuggestion] {
        switch query.kind {
        case .file:
            guard let rootDirectory = Self.normalizedDirectory(rootDirectory) else { return [] }
            return Self.fileSuggestions(for: query, rootDirectory: rootDirectory)
        case .skill:
            let index = skillIndex(rootDirectory: Self.normalizedDirectory(rootDirectory))
            return index.rankedCandidates(
                matching: query.query,
                limit: Self.suggestionLimit,
                shouldCancel: { Task.isCancelled }
            )
                .map { $0.suggestion(trigger: query.trigger) }
        }
    }

    /// Lists the one folder named by the typed path and ranks its entries
    /// against the text after the last `/`.
    private static func fileSuggestions(
        for query: TextBoxMentionQuery,
        rootDirectory: String
    ) -> [TextBoxMentionSuggestion] {
        let typed = query.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastSlash = typed.lastIndex(of: "/")
        let folder = lastSlash.map { String(typed[..<$0]) } ?? ""
        let name = lastSlash.map { String(typed[typed.index(after: $0)...]) } ?? typed
        let rootURL = URL(fileURLWithPath: rootDirectory, isDirectory: true)
        let folderURL = folder.isEmpty ? rootURL : rootURL.appendingPathComponent(folder, isDirectory: true)

        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: name.hasPrefix(".") ? [] : [.skipsHiddenFiles]
            )
        } catch {
            logger.debug("mention listing failed folder=\(folderURL.path, privacy: .private) error=\(error.localizedDescription, privacy: .public)")
            return []
        }

        let prefix = folder.isEmpty ? "" : "\(folder)/"
        let candidates = entries.map { url in
            let entryName = url.lastPathComponent
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            return isFolder
                ? directoryCandidate(relativePath: prefix + entryName, directoryURL: url)
                : fileCandidate(relativePath: prefix + entryName, fileURL: url, fileName: entryName)
        }
        return TextBoxMentionCandidateIndex(candidates: candidates)
            .rankedCandidates(matching: name, limit: suggestionLimit, shouldCancel: { Task.isCancelled })
            .map { $0.suggestion(trigger: query.trigger) }
    }

    private func skillIndex(rootDirectory: String?) -> TextBoxMentionCandidateIndex {
        let roots = Self.skillSearchRoots(rootDirectory: rootDirectory)
        let cacheKey = roots.map(\.path).joined(separator: "\n")
        if let cached = skillIndexesByRootKey[cacheKey] {
            return cached
        }

        var seenPaths = Set<String>()
        var candidates: [TextBoxMentionCandidate] = []
        for (rootIndex, root) in roots.enumerated() {
            for skillURL in Self.scanSkillFiles(rootURL: root) {
                let path = skillURL.standardizedFileURL.path
                guard seenPaths.insert(path).inserted else { continue }
                let skillName = Self.skillName(from: skillURL)
                candidates.append(TextBoxMentionCandidate(
                    title: "/\(skillName)",
                    subtitle: Self.displayPath(path),
                    targetPath: path,
                    systemImageName: "sparkle.magnifyingglass",
                    searchKey: Self.skillSearchKey(skillName: skillName, skillURL: skillURL, rootURL: root),
                    priority: rootIndex
                ))
                if candidates.count >= Self.maxIndexedSkills {
                    break
                }
            }
            if candidates.count >= Self.maxIndexedSkills {
                break
            }
        }

        let index = TextBoxMentionCandidateIndex(candidates: candidates)
        skillIndexesByRootKey[cacheKey] = index
        return index
    }

    private static func directoryCandidate(relativePath: String, directoryURL: URL) -> TextBoxMentionCandidate {
        let normalizedPath = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let displayTitle = "@\(normalizedPath)/"
        let directoryName = directoryURL.lastPathComponent
        return TextBoxMentionCandidate(
            title: displayTitle,
            subtitle: displayPath(directoryURL.path),
            targetPath: directoryURL.path,
            systemImageName: "folder",
            searchKey: "\(normalizedPath) \(directoryName) folder directory".lowercased(),
            priority: 0
        )
    }

    private static func fileCandidate(
        relativePath: String,
        fileURL: URL,
        fileName: String
    ) -> TextBoxMentionCandidate {
        TextBoxMentionCandidate(
            title: "@\(relativePath)",
            subtitle: displayPath(fileURL.path),
            targetPath: fileURL.path,
            systemImageName: "doc",
            searchKey: "\(relativePath) \(fileName)".lowercased(),
            priority: 1
        )
    }

    private static func scanSkillFiles(rootURL: URL) -> [URL] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }

        var result: [URL] = []
        if fileManager.fileExists(atPath: rootURL.appendingPathComponent("SKILL.md").path) {
            result.append(rootURL.appendingPathComponent("SKILL.md"))
            return result
        }

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return result }

        while let item = enumerator.nextObject() as? URL {
            let standardizedURL = item.standardizedFileURL
            let name = standardizedURL.lastPathComponent
            let values = try? standardizedURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if shouldSkipIndexedDirectoryName(name) {
                    enumerator.skipDescendants()
                    continue
                }

                let skillFile = standardizedURL.appendingPathComponent("SKILL.md", isDirectory: false)
                if fileManager.fileExists(atPath: skillFile.path) {
                    result.append(skillFile.standardizedFileURL)
                    enumerator.skipDescendants()
                }
            } else if values?.isRegularFile == true, name == "SKILL.md" {
                result.append(standardizedURL)
            }

            if result.count >= maxIndexedSkills {
                break
            }
        }

        return result
    }

    private static func skillSearchRoots(rootDirectory: String?) -> [URL] {
        let fileManager = FileManager.default
        var roots: [URL] = []

        if let rootDirectory {
            var current = URL(fileURLWithPath: rootDirectory, isDirectory: true).standardizedFileURL
            while current.path != "/" {
                let skillsURL = current.appendingPathComponent("skills", isDirectory: true)
                if fileManager.fileExists(atPath: skillsURL.path) {
                    roots.append(skillsURL)
                }
                current.deleteLastPathComponent()
            }
        }

        let home = fileManager.homeDirectoryForCurrentUser
        roots.append(home.appendingPathComponent(".codex/skills", isDirectory: true))
        roots.append(home.appendingPathComponent(".codex/skills/.system", isDirectory: true))
        roots.append(home.appendingPathComponent(".agents/skills", isDirectory: true))
        roots.append(contentsOf: pluginSkillRoots(
            pluginCacheURL: home.appendingPathComponent(".codex/plugins/cache", isDirectory: true),
            fileManager: fileManager
        ))

        var seen = Set<String>()
        return roots
            .map(\.standardizedFileURL)
            .filter { fileManager.fileExists(atPath: $0.path) }
            .filter { seen.insert($0.path).inserted }
    }

    private static func pluginSkillRoots(pluginCacheURL: URL, fileManager: FileManager) -> [URL] {
        guard let vendors = try? fileManager.contentsOfDirectory(
            at: pluginCacheURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var roots: [URL] = []
        for vendor in vendors where isDirectory(vendor, fileManager: fileManager) {
            guard let pluginNames = try? fileManager.contentsOfDirectory(
                at: vendor,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for pluginName in pluginNames where isDirectory(pluginName, fileManager: fileManager) {
                guard let versions = try? fileManager.contentsOfDirectory(
                    at: pluginName,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for version in versions where isDirectory(version, fileManager: fileManager) {
                    let skillsURL = version.appendingPathComponent("skills", isDirectory: true)
                    if isDirectory(skillsURL, fileManager: fileManager) {
                        roots.append(skillsURL)
                    }
                }
            }
        }
        return roots
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func shouldSkipIndexedDirectoryName(_ name: String) -> Bool {
        if skippedDirectoryNames.contains(name) {
            return true
        }
        let normalizedName = name.lowercased()
        return skippedPackageDirectorySuffixes.contains { suffix in
            normalizedName.hasSuffix(suffix.lowercased())
        }
    }

    private static func skillName(from skillURL: URL) -> String {
        guard let content = try? String(contentsOf: skillURL, encoding: .utf8) else {
            return skillURL.deletingLastPathComponent().lastPathComponent
        }

        for line in content.split(separator: "\n", maxSplits: 32, omittingEmptySubsequences: false) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("name:") else { continue }
            let name = String(trimmed.dropFirst("name:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return skillURL.deletingLastPathComponent().lastPathComponent
    }

    private static func skillSearchKey(skillName: String, skillURL: URL, rootURL: URL) -> String {
        let skillDirectory = skillURL.deletingLastPathComponent().standardizedFileURL
        let relativeSkillPath = relativePath(
            for: skillDirectory.path,
            rootPath: rootURL.standardizedFileURL.path
        )
        return "\(skillName) \(relativeSkillPath)".lowercased()
    }

    private static func normalizedDirectory(_ path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }

        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return url.path
    }

    private static func relativePath(for path: String, rootPath: String) -> String {
        guard path.hasPrefix(rootPath) else { return path }
        let start = path.index(path.startIndex, offsetBy: rootPath.count)
        let relative = String(path[start...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : relative
    }

    private static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) else { return path }
        return "~" + String(path.dropFirst(home.count))
    }
}
