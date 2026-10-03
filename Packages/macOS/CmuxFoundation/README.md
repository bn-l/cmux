# CmuxFoundation

Shared low-level primitives for cmux with no internal package dependencies. This is the
bottom of the package dependency graph: encoding/text helpers, value types, and other
cross-cutting utilities that several domains need, with nothing in here depending on AppKit,
SwiftUI, or another cmux package.

It exists as the leaf every other package and the app target can depend on without creating
a cycle. Keep it dependency-free.

Foundation helpers are exposed as extensions on existing types rather than free functions,
so call sites read naturally (`value.javaScriptStringLiteral`, not `f(value)`).

## Contents

- `String.javaScriptStringLiteral` — the string encoded as a quoted JavaScript string literal.
- `SSHAgentSocketResolver` — OpenSSH option parsing and SSH agent socket path normalization.
- `MainActorDeferredActionScheduler` — replaceable clock-driven main-actor work
  whose queued actions cannot retain prior scheduled actions.
- `MainActorCoalescingDeadlineTimer` — one persistent timer handle for hot,
  synchronous streams of deadline updates.
- `MainActorRepeatingActionScheduler` — one persistent timer handle for a
  lifecycle-bound repeating main-actor action.
- `MainActorTaskStore` — keyed replaceable task ownership that keeps task
  handles out of captured SwiftUI value snapshots.

## Usage

```swift
import CmuxFoundation

let literal = userText?.javaScriptStringLiteral ?? "null"
webView.evaluateJavaScript("setValue(\(literal))")
```

## Testing

Tests need no app, AppKit lifecycle, or user-owned state:

```swift
import Testing
import CmuxFoundation

@Test func plainStringIsQuoted() {
    #expect("hello".javaScriptStringLiteral == "\"hello\"")
}
```

Deferred-action tests inject a controllable `Clock<Duration>` and advance it
instead of waiting for wall time:

```swift
let scheduler = MainActorDeferredActionScheduler(clock: testClock)
scheduler.schedule(after: .milliseconds(50)) {
    receivedAction = true
}
```

Hot repeating work keeps one timer handle and must be cancelled at its owner’s
lifecycle boundary:

```swift
let ticker = MainActorRepeatingActionScheduler()
ticker.startIfIdle(every: .milliseconds(16)) {
    refreshPointerState()
}
ticker.cancel()
```

Replaceable async work uses a reference-owned task store. The store retains
only weak task-owner references, so an operation that captures its owner cannot
form an owner-to-task retain cycle:

```swift
let tasks = MainActorTaskStore<String>()
tasks.replace("search", priority: .userInitiated) {
    await rebuildSearchIndex()
}
```
