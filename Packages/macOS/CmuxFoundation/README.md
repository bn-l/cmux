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
