import Foundation

enum MenuBarProfilingLauncher {
    static let defaultDurationSeconds = 15
    static let defaultUsefulTemplateCount = 4

    static func bundledScriptURL(bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "start-cmux-profiling", withExtension: nil, subdirectory: "bin")
    }

    static func estimatedCaptureSeconds(
        durationSeconds: Int = defaultDurationSeconds,
        templateCount: Int = defaultUsefulTemplateCount
    ) -> Int {
        max(durationSeconds, 0) * max(templateCount, 0)
    }

    static func arguments(
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        durationSeconds: Int = defaultDurationSeconds,
        openOutput: Bool = false
    ) -> [String] {
        var args = ["--pid", String(pid), "--duration", String(durationSeconds)]
        if openOutput {
            args.append("--open-output")
        }
        return args
    }
}
