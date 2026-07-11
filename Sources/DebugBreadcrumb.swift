import Foundation

// Local debug-trace shims that replaced the removed Sentry helpers. No data
// leaves the process; these only write to the DEBUG log.
func debugBreadcrumb(_ message: String, category: String = "ui", data: [String: Any]? = nil) {
#if DEBUG
    if let data { cmuxDebugLog("[\(category)] \(message) \(data)") } else { cmuxDebugLog("[\(category)] \(message)") }
#endif
}

func debugCaptureError(_ message: String, category: String = "ui", data: [String: Any]? = nil, contextKey: String? = nil) {
#if DEBUG
    cmuxDebugLog("[error][\(category)] \(message)" + (data.map { " \($0)" } ?? ""))
#endif
}
