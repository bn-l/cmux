# Reading and writing to terminal sessions over the cmux socket

## Overview

cmux exposes a Unix domain socket that allows external processes to read terminal screen content and inject input into active terminal sessions. This enables CLI automation, scripting, and remote control of running terminals.

## Socket location

The socket server is started in `Sources/TerminalController.swift` (the `start()` method at line ~873). It creates an `AF_UNIX, SOCK_STREAM` socket.

Default paths (configured in `Sources/SocketControlSettings.swift`):
- Production: `~/.config/cmux/cmux.sock` (or legacy `/tmp/cmux.sock`)
- Debug: `/tmp/cmux-debug.sock`
- Tagged debug: `/tmp/cmux-debug-<tag>.sock`
- Nightly: `/tmp/cmux-nightly.sock`
- Staging: `/tmp/cmux-staging.sock`

Overridable via `CMUX_SOCKET_PATH` env var or `--socket` CLI flag.

## Protocol

Two protocols are supported, parsed in `Sources/TerminalController.swift` at `handleClient()` (line ~1505):

- **V1:** Plain text, newline-delimited. `command arg1 arg2\n` -> plain text response.
- **V2 (JSON-RPC 2.0):** `{"id":"abc","method":"surface.read_text","params":{"scrollback":true}}\n`

Responses (V2):
```json
{"id":"abc","ok":true,"result":{"text":"...","base64":"...","workspace_id":"...","surface_id":"..."}}
```

## Reading terminal content

### V2 method: `surface.read_text`

Implemented in `Sources/TerminalController.swift` at `v2SurfaceReadText()` (line ~5416).

**Parameters:**
| Param | Type | Default | Description |
|---|---|---|---|
| `workspace_id` | string (UUID) | current workspace | Target workspace |
| `surface_id` | string (UUID) | focused surface | Target terminal surface |
| `scrollback` | bool | `false` | Include scrollback buffer (not just visible viewport) |
| `lines` | int | all | Limit to last N lines (implies scrollback) |

**Response fields:** `text` (decoded string), `base64` (base64-encoded), `workspace_id`, `surface_id`, `window_id`.

### How it works internally

`readTerminalTextBase64()` (line ~5487) calls Ghostty's C API `ghostty_surface_read_text()` (declared in `ghostty.h` line ~1120). It reads text by constructing selection regions using different point tags:

- `GHOSTTY_POINT_VIEWPORT` -- visible viewport only (default when `scrollback=false`)
- `GHOSTTY_POINT_SCREEN` -- full screen buffer
- `GHOSTTY_POINT_SURFACE` -- history/scrollback
- `GHOSTTY_POINT_ACTIVE` -- active screen region

When scrollback is requested, it reads all three regions (screen, surface, active), merges them, and picks the candidate with the most lines/bytes. This handles edge cases around resize/reflow boundaries.

### CLI commands

Defined in `CLI/cmux.swift`:

```bash
# Read visible viewport
cmux read-screen

# Read with scrollback
cmux read-screen --scrollback

# Read last 200 lines from a specific surface
cmux read-screen --surface surface:2 --scrollback --lines 200

# tmux-compatible alias
cmux capture-pane --scrollback --lines 200

# Pipe terminal content to a shell command
cmux pipe-pane --command "grep ERROR"
```

`read-screen` help text is at `CLI/cmux.swift` line ~6470. `capture-pane` (tmux compat) is at line ~6283.

## Writing to terminal sessions

### V2 method: `surface.send_text`

Implemented in `Sources/TerminalController.swift` at `v2SurfaceSendText()` (line ~5260).

**Parameters:**
| Param | Type | Default | Description |
|---|---|---|---|
| `workspace_id` | string (UUID) | current workspace | Target workspace |
| `surface_id` | string (UUID) | focused surface | Target terminal surface |
| `text` | string | (required) | Text to inject |

The text is chunked by `sendSocketText()` (line ~13331) into text segments and control characters, then injected via `sendTextEvent()` (line ~13077) which calls Ghostty's `ghostty_surface_key()` C API. After injection, `forceRefresh()` is called so the terminal renders the new content immediately.

Escape sequences: `\n` and `\r` send Enter, `\t` sends Tab.

### V2 method: `surface.send_key`

Implemented at `v2SurfaceSendKey()` (line ~5320).

**Parameters:**
| Param | Type | Default | Description |
|---|---|---|---|
| `workspace_id` | string (UUID) | current workspace | Target workspace |
| `surface_id` | string (UUID) | focused surface | Target terminal surface |
| `key` | string | (required) | Named key to send |

Dispatched by `sendNamedKey()` (line ~13189). Supported named keys:

| Key name | Aliases | Description |
|---|---|---|
| `enter` | `return` | Enter/Return |
| `tab` | | Tab |
| `escape` | `esc` | Escape |
| `backspace` | | Backspace |
| `up` | `arrow_up`, `arrowup` | Up arrow |
| `down` | `arrow_down`, `arrowdown` | Down arrow |
| `left` | `arrow_left`, `arrowleft` | Left arrow |
| `right` | `arrow_right`, `arrowright` | Right arrow |
| `ctrl+c` | `ctrl-c`, `sigint` | Ctrl+C (interrupt) |
| `ctrl+d` | `ctrl-d`, `eof` | Ctrl+D (EOF) |
| `ctrl+z` | `ctrl-z`, `sigtstp` | Ctrl+Z (suspend) |
| `ctrl+\` | `ctrl-\`, `sigquit` | Ctrl+\ (quit) |
| `shift+tab` | `shift-tab`, `backtab` | Shift+Tab |
| `home` | | Home |
| `end` | | End |
| `delete` | `del`, `forward_delete` | Forward delete |
| `pageup` | `page_up` | Page Up |
| `pagedown` | `page_down` | Page Down |

Arbitrary modifier+key combos are also supported (e.g. `ctrl+shift+a`, `alt+enter`).

### CLI commands

```bash
# Send text (injected as keystrokes)
cmux send "echo hello"
cmux send "ls -la\n"

# Send to a specific surface
cmux send --surface surface:2 "pwd\n"

# Send a named key
cmux send-key enter
cmux send-key ctrl+c
cmux send-key --surface surface:2 escape
```

Help text at `CLI/cmux.swift` lines ~6486 (`send`) and ~6500 (`send-key`).

## Other surface commands

All dispatched from `processV2Command()` in `Sources/TerminalController.swift` (line ~1921):

| Method | Description |
|---|---|
| `surface.list` | List all surfaces in a workspace (line ~4399) |
| `surface.current` | Get the currently focused surface (line ~4462) |
| `surface.focus` | Focus a specific surface |
| `surface.split` | Split a surface into panes |
| `surface.create` | Create a new surface |
| `surface.close` | Close a surface |
| `surface.move` | Move a surface |
| `surface.reorder` | Reorder surfaces |
| `surface.refresh` | Force redraw all surfaces in workspace (line ~4938) |
| `surface.health` | Check surface attachment status (line ~4961) |
| `surface.clear_history` | Clear scrollback buffer (line ~5366) |
| `surface.trigger_flash` | Trigger visual flash on a surface |

## Access control

Configured in `Sources/SocketControlSettings.swift` (`SocketControlMode` enum, line ~7):

| Mode | Description |
|---|---|
| `off` | Socket disabled |
| `cmuxOnly` | Only processes descended from cmux can connect (ancestry check via PID) |
| `automation` | Any local process from the same user |
| `password` | HMAC-SHA256 password authentication |
| `allowAll` | No restrictions (env-var only, unsafe) |

Default is `cmuxOnly`. Override with `CMUX_SOCKET_MODE` env var.

## Go CLI client

The Go-based remote CLI client lives at `daemon/remote/cmd/cmuxd-remote/cli.go`:

- `dialSocket()` (line ~523) -- connects via Unix socket or TCP (for remote relay)
- `socketRoundTrip()` (line ~623) -- V1 text protocol request/response
- `socketRoundTripV2()` (line ~673) -- V2 JSON-RPC request/response

## Example: read-then-write loop

```bash
# Read what's on screen
TEXT=$(cmux read-screen --scrollback --lines 50)

# Conditionally send input based on content
if echo "$TEXT" | grep -q "password:"; then
    cmux send "hunter2\n"
fi

# Or use pipe-pane to process output
cmux pipe-pane --command "grep -c ERROR"
```

## Key source files

| Path | Description |
|---|---|
| `Sources/TerminalController.swift` | Socket server, all V1/V2 command handlers, text read/write impl |
| `Sources/SocketControlSettings.swift` | Socket path resolution, access modes, password auth |
| `CLI/cmux.swift` | CLI command dispatch, `read-screen`/`send`/`send-key`/`capture-pane` |
| `daemon/remote/cmd/cmuxd-remote/cli.go` | Go CLI client, socket connection, V1/V2 round-trip |
| `ghostty.h` | Ghostty C API declarations (`ghostty_surface_read_text`, `ghostty_surface_key`, etc.) |
