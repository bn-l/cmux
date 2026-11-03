import AppKit
import Foundation

@MainActor
final class MenuBarProfilingProgressWindowController: NSWindowController {
    static let shared = MenuBarProfilingProgressWindowController()

    let titleLabel = NSTextField(labelWithString: "")
    let countdownLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    let permissionLabel = NSTextField(wrappingLabelWithString: "")
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    let progressIndicator = NSProgressIndicator()
    let previewTextView = NSTextView()
    let openFolderButton = NSButton()
    let closeButton = NSButton()

    private var process: Process?
    var outputLogURL: URL?
    var errorLogURL: URL?
    var outputLogHandle: FileHandle?
    var errorLogHandle: FileHandle?
    private var countdownTimer: Timer?
    private var startedAt: Date?
    private var scriptOutput = ""
    var outputURL: URL?
    var captureComplete = false

    private var estimatedSeconds: Int {
        MenuBarProfilingLauncher.estimatedCaptureSeconds()
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "statusMenu.profiling.title", defaultValue: "Profiling cmux")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func startProfiling(
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        scriptURL: URL? = MenuBarProfilingLauncher.bundledScriptURL()
    ) {
        if process != nil || (captureComplete && outputURL != nil) {
            showWindow()
            return
        }

        resetInterface()
        showWindow()

        guard let scriptURL else {
            finishWithLaunchFailure(
                String(
                    localized: "statusMenu.profiling.scriptMissing",
                    defaultValue: "The bundled profiling script is missing."
                )
            )
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path] + MenuBarProfilingLauncher.arguments(pid: pid)
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor [weak self] in
                self?.finish(terminationStatus: status)
            }
        }

        do {
            let outputLog = try makeTemporaryLogFile(prefix: "cmux-profile-output")
            let errorLog = try makeTemporaryLogFile(prefix: "cmux-profile-error")
            outputLogURL = outputLog.0
            outputLogHandle = outputLog.1
            errorLogURL = errorLog.0
            errorLogHandle = errorLog.1
            process.standardOutput = outputLog.1
            process.standardError = errorLog.1
            self.process = process
            startedAt = Date()
            startCountdownTimer()
            try process.run()
            statusLabel.stringValue = String(
                localized: "statusMenu.profiling.running",
                defaultValue: "Recording CPU, SwiftUI, memory, and system traces in the background."
            )
        } catch {
            finishWithLaunchFailure(
                String(
                    localized: "statusMenu.profiling.launchFailed",
                    defaultValue: "Unable to start profiling."
                ) + " " + error.localizedDescription
            )
        }
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }

        titleLabel.stringValue = String(localized: "statusMenu.profiling.title", defaultValue: "Profiling cmux")
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
        countdownLabel.alignment = .left

        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabelColor

        permissionLabel.stringValue = String(
            localized: "statusMenu.profiling.permissionExplanation",
            defaultValue: "macOS may ask for administrator permission because Instruments samples the running cmux process."
        )
        permissionLabel.font = .systemFont(ofSize: 12)
        permissionLabel.textColor = .secondaryLabelColor

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabelColor

        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = Double(estimatedSeconds)
        progressIndicator.controlSize = .regular

        configureTextView(previewTextView, editable: false)

        openFolderButton.title = String(localized: "statusMenu.profiling.openFolder", defaultValue: "Open Folder")
        openFolderButton.target = self
        openFolderButton.action = #selector(openCaptureFolder)

        closeButton.title = String(localized: "statusMenu.profiling.close", defaultValue: "Close")
        closeButton.target = self
        closeButton.action = #selector(closeWindow)

        let reviewStack = NSStackView(views: [
            labeledView(
                label: String(localized: "statusMenu.profiling.captureContentsLabel", defaultValue: "Capture folder"),
                view: scrollView(for: previewTextView, height: 220)
            ),
        ])
        reviewStack.orientation = .vertical
        reviewStack.alignment = .width
        reviewStack.spacing = 8

        let buttonStack = NSStackView(views: [openFolderButton, closeButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.alignment = .centerY

        let stack = NSStackView(views: [
            titleLabel,
            countdownLabel,
            detailLabel,
            permissionLabel,
            progressIndicator,
            statusLabel,
            reviewStack,
            buttonStack,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progressIndicator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            reviewStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func resetInterface() {
        clearScriptLogs()
        scriptOutput = ""
        outputURL = nil
        captureComplete = false
        progressIndicator.maxValue = Double(estimatedSeconds)
        progressIndicator.doubleValue = 0
        openFolderButton.isEnabled = false
        closeButton.isEnabled = true
        countdownLabel.stringValue = remainingText(estimatedSeconds)
        detailLabel.stringValue = String(
            format: String(
                localized: "statusMenu.profiling.bodyFormat",
                defaultValue: "Recording CPU, SwiftUI, memory, and system traces for %d seconds each. Finalizing may take longer."
            ),
            MenuBarProfilingLauncher.defaultDurationSeconds
        )
        statusLabel.stringValue = String(
            localized: "statusMenu.profiling.starting",
            defaultValue: "Starting Instruments..."
        )
        updatePreview()
        updateOpenFolderState()
    }

    private func showWindow() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }

    private func startCountdownTimer() {
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateCountdown()
            }
        }
        updateCountdown()
    }

    private func updateCountdown() {
        guard let startedAt else { return }
        let elapsed = max(0, Int(Date().timeIntervalSince(startedAt)))
        let remaining = max(estimatedSeconds - elapsed, 0)
        progressIndicator.doubleValue = Double(min(elapsed, estimatedSeconds))
        countdownLabel.stringValue = remaining > 0
            ? remainingText(remaining)
            : String(localized: "statusMenu.profiling.finalizing", defaultValue: "Finalizing traces...")
    }

    private func remainingText(_ seconds: Int) -> String {
        String(
            format: String(
                localized: "statusMenu.profiling.remainingFormat",
                defaultValue: "About %d seconds remaining"
            ),
            seconds
        )
    }

    private func appendScriptOutput(_ text: String) {
        scriptOutput += text
        parseOutputURL(from: text)
    }

    private func parseOutputURL(from text: String) {
        for line in text.components(separatedBy: .newlines) {
            if let range = line.range(of: "cmux profiling capture written to ") {
                let path = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                outputURL = URL(fileURLWithPath: path)
            } else if let range = line.range(of: "Output: ") {
                let path = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                outputURL = URL(fileURLWithPath: path)
            }
        }
        updateOpenFolderState()
        updatePreview()
    }

    private func finish(terminationStatus: Int32) {
        countdownTimer?.invalidate()
        countdownTimer = nil
        drainScriptLogs()
        clearScriptLogs()
        process = nil
        progressIndicator.doubleValue = Double(estimatedSeconds)

        if terminationStatus == 0 {
            captureComplete = true
            countdownLabel.stringValue = String(localized: "statusMenu.profiling.completeTitle", defaultValue: "Capture complete")
            statusLabel.stringValue = String(
                localized: "statusMenu.profiling.savedLocally",
                defaultValue: "The capture is saved on this Mac. Nothing was sent anywhere."
            )
        } else {
            countdownLabel.stringValue = String(localized: "statusMenu.profiling.failedTitle", defaultValue: "Profiling failed")
            statusLabel.stringValue = failureMessage()
            NSSound.beep()
        }
        updateOpenFolderState()
        updatePreview()
    }

    private func finishWithLaunchFailure(_ message: String) {
        countdownTimer?.invalidate()
        countdownTimer = nil
        clearScriptLogs()
        process = nil
        progressIndicator.doubleValue = 0
        countdownLabel.stringValue = String(localized: "statusMenu.profiling.failedTitle", defaultValue: "Profiling failed")
        statusLabel.stringValue = message
        updateOpenFolderState()
        updatePreview()
        NSSound.beep()
    }

    private func drainScriptLogs() {
        outputLogHandle?.closeFile()
        errorLogHandle?.closeFile()
        outputLogHandle = nil
        errorLogHandle = nil
        scriptOutput = readLogText(from: outputLogURL) + readLogText(from: errorLogURL)
        parseOutputURL(from: scriptOutput)
    }

    private func clearScriptLogs() {
        outputLogHandle?.closeFile()
        errorLogHandle?.closeFile()
        outputLogHandle = nil
        errorLogHandle = nil
        removeLogFile(outputLogURL)
        removeLogFile(errorLogURL)
        outputLogURL = nil
        errorLogURL = nil
    }

    private func failureMessage() -> String {
        let base = String(
            localized: "statusMenu.profiling.failedBody",
            defaultValue: "The capture did not finish. If a folder was created, it may contain partial logs."
        )
        let tail = scriptOutput
            .split(separator: "\n")
            .suffix(2)
            .joined(separator: "\n")
        return tail.isEmpty ? base : base + "\n" + tail
    }

    func updatePreview() {
        guard let outputURL else {
            previewTextView.string = String(
                localized: "statusMenu.profiling.previewWaiting",
                defaultValue: "The capture folder will appear here after the profiler writes it."
            )
            return
        }

        previewTextView.string = MenuBarProfilingProfilePreview.text(
            outputURL: outputURL,
            summary: summaryText(for: outputURL)
        )
    }

    func updateOpenFolderState() {
        openFolderButton.isEnabled = outputURL != nil && process == nil
    }

    @objc private func openCaptureFolder() {
        guard let outputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
    }

    private func summaryText(for outputURL: URL) -> String {
        MenuBarProfilingProfilePreview.summaryText(for: outputURL)
    }

    @objc private func closeWindow() {
        window?.close()
    }

    func clearCompletedCaptureState() {
        guard process == nil, captureComplete else { return }
        scriptOutput = ""
        outputURL = nil
        captureComplete = false
        clearScriptLogs()
    }
}

extension MenuBarProfilingProgressWindowController: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            MenuBarProfilingProgressWindowController.shared.clearCompletedCaptureState()
        }
    }
}
