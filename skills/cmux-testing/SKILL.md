---
name: cmux-testing
description: "cmux testing rules for Swift Testing, test target compilation, and package/refactor validation. Use when adding or changing tests, touching package/refactor code, or deciding whether reload.sh is enough validation."
---

# cmux Testing

## Regression test commit policy

When adding a regression test for a bug fix, use a two-commit structure so CI proves the test catches the bug:

1. **Commit 1:** Add the failing test only (no fix). CI should go red.
2. **Commit 2:** Add the fix. CI should go green.

This makes it visible in the GitHub PR UI that the test genuinely fails without the fix.

## Test quality policy

- Do not add tests that only verify source code text, method signatures, AST fragments, or grep-style patterns.
- Do not add tests that read checked-in metadata or project files such as `Resources/Info.plist`, `project.pbxproj`, `.xcconfig`, or source files only to assert that a key, string, plist entry, or snippet exists.
- Tests must verify observable runtime behavior through executable paths (unit/integration/e2e/CLI), not implementation shape.
- For metadata changes, prefer verifying the built app bundle or the runtime behavior that depends on that metadata, not the checked-in source file.
- If a behavior cannot be exercised end-to-end yet, add a small runtime seam or harness first, then test through that seam.
- If no meaningful behavioral or artifact-level test is practical, skip the fake regression test and state that explicitly.

## Test framework

Swift Testing is the current Apple-supported primitive for tests on this codebase (shipped with Swift 6 / Xcode 16, supported on the macOS versions we target). Use it for everything that is not a UI test.

- **Default to Swift Testing for all unit and integration tests.** `import Testing`, annotate tests with `@Test`, group with `@Suite`, assert with `#expect(...)` and `try #require(...)`. Do not write new tests with `import XCTest` unless they are UI tests.
- **UI tests stay on XCTest / XCUITest.** Swift Testing does not support UI testing (no `XCUIApplication` integration). Files under `cmuxUITests/` continue to use `XCTestCase` + `XCUIApplication`. Do not migrate them and do not try to bridge Swift Testing into UI tests.
- **New test targets start on Swift Testing.** Every new Swift package's `Tests/<Name>Tests/` directory (e.g. `Packages/macOS/CmuxSettings/Tests/CmuxSettingsTests/`) should ship with Swift Testing from the first commit. Xcode 16 auto-detects the framework based on the `import Testing` statement; no extra `Package.swift` configuration is required.
- **Migration guide when touching an existing XCTest test.** Convert in place: `XCTestCase` subclass becomes a `@Suite struct` (or `final class` if you need a reference type); each `func testFoo()` becomes `@Test func foo()`; `XCTAssertEqual(a, b)` becomes `#expect(a == b)`; `XCTAssertTrue(cond)` becomes `#expect(cond)`; `XCTUnwrap(x)` becomes `try #require(x)`; `XCTFail("msg")` becomes `Issue.record("msg")`. `setUp()` becomes `init()` on the suite; `tearDown()` becomes `deinit`. Async setup is `async init()`. Do not bulk-rewrite untouched tests; migrate incrementally as a side effect of editing the file.
- **Parameterized tests** use `@Test(arguments: [...])`. Prefer this over duplicate test methods.
- **Parallelization and shared state.** Swift Testing runs tests in parallel by default, including across suites. If a suite genuinely needs ordering or guards shared mutable state, annotate it with `.serialized` instead of adding locks or sleeps.
- **Tags** with `@Test(.tags(.something))` (or on a `@Suite`) let CI and local runs filter selectively.

## Test target validation

`reload.sh` does not compile the test target. It builds only the `cmux` scheme, so a green `reload.sh` says nothing about whether `cmuxTests`/`cmuxUITests` still compile. A symbol that is moved or renamed can keep the `cmux` app building while breaking the test target (real case: a `write(to:atomically:)` typo and a removed `TabManager.CommandResult` only surfaced in the `tests` job). Before pushing package/refactor changes, build the `cmux-unit` scheme (with `-derivedDataPath /tmp/cmux-<tag>` and, for `cmuxApp`/`AppDelegate` churn, the GlobalISel workaround flag) or let the `tests` CI job gate it — never treat `reload.sh` alone as proof the tests build.

## Spawning processes from tests

**Never build a spawned process's environment from `ProcessInfo.processInfo.environment`.**

That inherits the environment of whoever launched the test runner. When that is a cmux
terminal — the normal case, since `reload.sh` and Xcode are usually started from one — it
carries `CMUX_CODEX_WRAPPER_SHIM` / `CMUX_CLAUDE_WRAPPER_SHIM`. The resume command cmux
generates (`AgentResumeArgv.swift`) prefers that shim over a `PATH` lookup:

```sh
"$([ -x "${CMUX_CODEX_WRAPPER_SHIM:-}" ] && printf '%s' "$CMUX_CODEX_WRAPPER_SHIM" || printf codex)"
```

So the fake agent stub your test installed is bypassed and the developer's **real,
authenticated agent** runs. The observed case was `codex resume <fake-session> --yolo`
launching a real Codex TUI that was orphaned to launchd and spun CPU for 46 minutes with
Codex closed.

**Prepending a fake bin to `PATH` does not save you.** Tests usually spawn `zsh -lc` /
`zsh -lic`, and a login shell runs `path_helper`, which rebuilds `PATH` from `/etc/paths.d`
(which includes `/opt/homebrew/bin`) *ahead* of your entry. Verify for yourself:

```sh
env -i HOME=<empty-dir> PATH=<fakebin>:/usr/bin:/bin zsh -lc 'command -v codex'
# → /opt/homebrew/bin/codex        (the real binary, not your stub)
```

Use `AgentSpawnIsolation.childEnvironment(home:prependingPath:fakeAgents:)` from
`cmuxTests/AgentSpawnIsolationTestSupport.swift`. Binding `fakeAgents:` points the shim
variable at your stub, which takes `PATH` out of the decision entirely. It also scrubs
`CMUX_SOCKET_PATH` (so a test cannot drive the developer's live cmux), `CODEX_HOME`,
`CLAUDE_CONFIG_DIR`, and the custom-path overrides, and requires an explicit sandbox `HOME`.
Pair it with `AgentSpawnIsolation.runToCompletion(_:timeout:)` so one bad spawn cannot hang
the suite the way a bare `waitUntilExit()` on a TUI does.

Three backstops exist; none is a substitute for the helper:

- `Resources/bin/cmux-{codex,claude}-wrapper` refuse to exec under XCTest (exit 78).
- `scripts/test-unit.sh` brackets every run with `scripts/reap-leaked-agents.sh`. Use
  `just test-unit`; check strays with `just agents-leaked`.
- `scripts/check-test-determinism.py --strict` fails on the `inherited-agent-env` rule.
  Existing offenders are allowlisted in `.github/test-determinism-allowlist.txt`; delete
  your file's line as you migrate it rather than adding new ones.

## Detailed references

- Read [references/swift-testing-migration.md](references/swift-testing-migration.md) when converting XCTest unit tests to Swift Testing or adding new package tests.
- Read [references/regression-and-quality.md](references/regression-and-quality.md) when adding a regression test, deciding whether a test is behavioral enough, or checking Xcode project test wiring.
- Read [references/local-vs-ci-validation.md](references/local-vs-ci-validation.md) when choosing between `reload.sh`, `cmux-unit`, GitHub Actions, E2E/UI tests, and Python socket tests.
- Read [references/remote-tmux-sizing-e2e.md](references/remote-tmux-sizing-e2e.md) when working on remote-tmux mirror sizing, the sizing UI-test suite, its ssh shim, or the `remote.tmux.pane_grids` / `remote.tmux.test_exec` debug verbs.
