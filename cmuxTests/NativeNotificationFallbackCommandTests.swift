import CmuxNotifications
import Foundation
import os
import Testing
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct NativeNotificationFallbackCommandTests {
    private struct CommandInvocation: Equatable, Sendable {
        let title: String
        let subtitle: String
        let body: String
    }

    private final class CommandInvocationRecorder: Sendable {
        private let invocationsLock = OSAllocatedUnfairLock(initialState: [CommandInvocation]())

        var invocations: [CommandInvocation] {
            invocationsLock.withLock { $0 }
        }

        func append(title: String, subtitle: String, body: String) {
            invocationsLock.withLock {
                $0.append(CommandInvocation(title: title, subtitle: subtitle, body: body))
            }
        }
    }

    private final class BoolRecorder: Sendable {
        private let valueLock = OSAllocatedUnfairLock(initialState: false)

        var value: Bool {
            valueLock.withLock { $0 }
        }

        func setTrue() {
            valueLock.withLock { $0 = true }
        }
    }

    @Test
    func deniedNativeNotificationAuthorizationDoesNotRunCustomCommandFallback() {
        let store = TerminalNotificationStore.shared
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        resetState(originalAppFocusOverride: false)
        defer { resetState(originalAppFocusOverride: originalAppFocusOverride) }

        let didAttemptSchedule = BoolRecorder()
        let commands = CommandInvocationRecorder()
        store.configureNotificationAuthorizationHandlerForTesting { completion in
            completion(false, .denied)
        }
        store.configureUserNotificationSchedulerForTesting { _, completion in
            didAttemptSchedule.setTrue()
            completion(nil)
        }
        store.configureNotificationCommandRunnerForTesting { title, subtitle, body in
            commands.append(title: title, subtitle: subtitle, body: body)
        }

        store.addNotification(
            tabId: UUID(),
            surfaceId: nil,
            title: "Real title",
            subtitle: "",
            body: "Real message"
        )

        #expect(commands.invocations.isEmpty)
        #expect(!didAttemptSchedule.value)
    }

    @Test
    func failedNativeNotificationSchedulingDoesNotRunCustomCommandFallback() async {
        let store = TerminalNotificationStore.shared
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        resetState(originalAppFocusOverride: false)
        defer { resetState(originalAppFocusOverride: originalAppFocusOverride) }

        let commands = CommandInvocationRecorder()
        store.configureNotificationAuthorizationHandlerForTesting { completion in
            completion(true, .authorized)
        }
        store.configureUserNotificationSchedulerForTesting { _, completion in
            completion(NSError(domain: "cmuxTests.NotificationScheduling", code: 1))
        }
        store.configureNotificationCommandRunnerForTesting { title, subtitle, body in
            commands.append(title: title, subtitle: subtitle, body: body)
        }

        // The failed-scheduling branch plays unavailable feedback instead of
        // the command fallback; resuming from that seam proves the branch ran
        // to completion before the absence assertion below.
        await withCheckedContinuation { continuation in
            store.configureUnavailableFeedbackPlayerForTesting { _ in
                continuation.resume()
            }
            store.addNotification(
                tabId: UUID(),
                surfaceId: nil,
                title: "Real title",
                subtitle: "",
                body: "Real message"
            )
        }

        #expect(commands.invocations.isEmpty)
    }

    @Test
    func sharedNativeUnavailableFeedbackSuppressesCommandRunner() {
        var effects = TerminalNotificationPolicyEffects()
        effects.sound = false
        effects.command = true
        let commands = CommandInvocationRecorder()

        NativeNotificationDeliveryHooks.runLocalFeedback(
            title: "Real title",
            subtitle: "",
            body: "Real message",
            effects: effects,
            runCommand: false
        ) { title, subtitle, body in
            commands.append(title: title, subtitle: subtitle, body: body)
        }

        #expect(commands.invocations.isEmpty)
    }

    @Test
    func sharedDesktopDisabledFeedbackAllowsCommandRunner() {
        var effects = TerminalNotificationPolicyEffects()
        effects.desktop = false
        effects.sound = false
        effects.command = true
        let commands = CommandInvocationRecorder()

        NativeNotificationDeliveryHooks.runLocalFeedback(
            title: "Real title",
            subtitle: "",
            body: "Real message",
            effects: effects
        ) { title, subtitle, body in
            commands.append(title: title, subtitle: subtitle, body: body)
        }

        #expect(commands.invocations == [
            CommandInvocation(title: "Real title", subtitle: "", body: "Real message"),
        ])
    }

    private func resetState(originalAppFocusOverride: Bool?) {
        let store = TerminalNotificationStore.shared
        store.replaceNotificationsForTesting([])
        store.resetNotificationDeliveryHandlerForTesting()
        store.resetNotificationAuthorizationHandlerForTesting()
        store.resetUserNotificationSchedulerForTesting()
        store.resetNotificationCommandRunnerForTesting()
        store.resetUnavailableFeedbackPlayerForTesting()
        store.resetSuppressedNotificationFeedbackHandlerForTesting()
        AppFocusState.overrideIsFocused = originalAppFocusOverride
    }
}

/// Upstream nests this case under its `AgentNotificationRegressionTests` parent,
/// which this fork does not have; it touches no shared store state.
@Suite("Native notification delivery hooks")
@MainActor
struct NativeNotificationDeliveryHooksExecutorTests {
    @Test("An unresponsive notification center never blocks its calling executor")
    func unresponsiveNativeNotificationCenterDoesNotBlockCallingExecutor() {
        var hooks = NativeNotificationDeliveryHooks(
            userNotificationCenter: UserNotificationCenterService(
                center: .current()
            )
        )
        let schedulerEntered = DispatchSemaphore(value: 0)
        let releaseScheduler = DispatchSemaphore(value: 0)
        // Safety: written by the wedged scheduler thread, read by the test
        // after schedule() returns.
        let schedulerFinished = OSAllocatedUnfairLock(initialState: false)
        hooks.scheduler = { _, _ in
            schedulerEntered.signal()
            // Stand-in for the framework blocking before it wires up its
            // completion. The deadline exists only so a regression fails the
            // test instead of wedging a runner thread indefinitely.
            _ = releaseScheduler.wait(timeout: .now() + 5)
            schedulerFinished.withLock { $0 = true }
        }
        let content = UNMutableNotificationContent()
        let request = UNNotificationRequest(
            identifier: "never-completes",
            content: content,
            trigger: nil
        )

        hooks.schedule(request) { _ in }

        // Causal ordering: schedule() must hand back control while the wedged
        // framework call still has not finished (it cannot finish until the
        // release below).
        #expect(
            !schedulerFinished.withLock { $0 },
            "schedule must return before the wedged center call completes"
        )
        #expect(schedulerEntered.wait(timeout: .now() + 5) == .success)
        releaseScheduler.signal()
    }
}
