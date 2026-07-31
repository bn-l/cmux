#!/usr/bin/env python3
"""One-off cleanup for cross-project agent session bindings.

Before the session-identity fix, a Claude/Codex hook could be routed to the wrong
pane (a recycled `ttysNNN` device name, re-seeded from the previous run's snapshot,
matched a different project's tab). The hook then recorded that session under the
wrong pane, published the wrong resume binding, and the mis-binding was saved into
the quit snapshot and replayed on the next launch — growing every restart.

The fixed app stops writing new mis-bindings and refuses to act on cross-project
ones, but the bindings already on disk stay until they are removed. This script
removes them:

  * `~/.cmuxterm/*-hook-sessions.json` — drops records whose `cwd` is not in the
    same project tree as the panel their `surfaceId` names in the snapshot.
  * `~/Library/Application Support/cmux/session-com.cmuxterm.app.json` — strips
    `resumeBinding` / `agent` from panels whose claimed cwd is not in the panel's
    own project tree, then leaves at most one panel per `(kind, sessionId)`.

Run it with cmux QUIT (the app rewrites both files on quit and would undo this).
Reports only unless `--apply` is passed; `--apply` writes a `.bak` copy of every
file it changes first.

    ./scripts/prune-cross-project-agent-sessions.py
    ./scripts/prune-cross-project-agent-sessions.py --apply
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path
from typing import Any

DEFAULT_SESSION_FILE = (
    Path.home() / "Library/Application Support/cmux/session-com.cmuxterm.app.json"
)
DEFAULT_HOOK_STORE_DIR = Path.home() / ".cmuxterm"


def standardized(path: str | None) -> str | None:
    """Normalize a directory for comparison; `None` for anything unusable."""
    if not path or not path.strip():
        return None
    resolved = os.path.normpath(os.path.expanduser(path.strip()))
    return resolved.rstrip("/") or "/"


def is_affine(lhs: str | None, rhs: str | None) -> bool:
    """Same project tree: equal, or one is a path prefix of the other.

    Fails closed on a missing directory — the cost of a false negative is a lost
    auto-resume, the cost of a false positive is one project's agent adopting
    another project's pane.
    """
    left, right = standardized(lhs), standardized(rhs)
    if left is None or right is None:
        return False
    return left == right or left.startswith(right + "/") or right.startswith(left + "/")


def claim_of(terminal: dict[str, Any]) -> tuple[str | None, str | None, str | None]:
    """(kind, sessionId, claimed cwd) for a terminal panel snapshot."""
    binding = terminal.get("resumeBinding") or {}
    agent = terminal.get("agent") or {}
    kind = binding.get("kind") or agent.get("kind")
    session_id = binding.get("checkpointId") or agent.get("sessionId")
    cwd = binding.get("cwd") or agent.get("workingDirectory")
    return kind, session_id, cwd


def iter_panels(session: dict[str, Any]):
    """Yield (workspace, panel) for every panel in every window."""
    for window in session.get("windows") or []:
        tab_manager = window.get("tabManager") or {}
        for workspace in tab_manager.get("workspaces") or []:
            for panel in workspace.get("panels") or []:
                yield workspace, panel


def panel_directory(workspace: dict[str, Any], panel: dict[str, Any]) -> str | None:
    terminal = panel.get("terminal") or {}
    return (
        panel.get("directory")
        or terminal.get("workingDirectory")
        or workspace.get("currentDirectory")
    )


def strip_claim(panel: dict[str, Any]) -> None:
    terminal = panel.get("terminal")
    if not terminal:
        return
    terminal.pop("resumeBinding", None)
    terminal.pop("agent", None)
    terminal["wasAgentRunning"] = False


def prune_session_file(session: dict[str, Any]) -> list[str]:
    """Strip cross-project and duplicated claims. Returns a report."""
    report: list[str] = []
    claimants: dict[tuple[str, str], list[tuple[dict[str, Any], str | None, str | None]]] = {}

    for workspace, panel in iter_panels(session):
        terminal = panel.get("terminal")
        if not terminal:
            continue
        kind, session_id, claim_cwd = claim_of(terminal)
        if not session_id:
            continue
        directory = panel_directory(workspace, panel)
        if not is_affine(claim_cwd, directory):
            report.append(
                f"  strip cross-project claim: panel={panel.get('id')} "
                f"dir={directory} claim_cwd={claim_cwd} "
                f"kind={kind} session={session_id}"
            )
            strip_claim(panel)
            continue
        key = ((kind or "unknown").lower(), session_id)
        claimants.setdefault(key, []).append((panel, directory, claim_cwd))

    for (kind, session_id), panels in claimants.items():
        if len(panels) < 2:
            continue
        # Exact directory match wins; then the lowest panel id, so repeated runs
        # of this script keep the same panel.
        def rank(item: tuple[dict[str, Any], str | None, str | None]) -> tuple[int, str]:
            panel, directory, claim_cwd = item
            exact = standardized(claim_cwd) == standardized(directory)
            return (0 if exact else 1, str(panel.get("id")))

        winner, *losers = sorted(panels, key=rank)
        report.append(
            f"  duplicate session kind={kind} session={session_id}: "
            f"keeping panel={winner[0].get('id')} ({winner[1]}), "
            f"dropping {len(losers)}"
        )
        for panel, directory, _ in losers:
            report.append(f"    drop duplicate: panel={panel.get('id')} dir={directory}")
            strip_claim(panel)

    return report


def prune_hook_store(store: dict[str, Any], panel_dirs: dict[str, str]) -> list[str]:
    """Drop hook records bound to a panel in a different project tree."""
    report: list[str] = []
    sessions = store.get("sessions") or {}
    dropped_session_ids: set[str] = set()

    for session_id, record in list(sessions.items()):
        surface_id = record.get("surfaceId")
        directory = panel_dirs.get(surface_id or "")
        if directory is None:
            # The pane no longer exists in the snapshot, so there is nothing to
            # check the record against. Left alone: it cannot drive auto-resume
            # (that reads snapshot bindings) and the app now verifies routing.
            continue
        if is_affine(record.get("cwd"), directory):
            continue
        report.append(
            f"  drop record session={session_id} surface={surface_id} "
            f"record_cwd={record.get('cwd')} panel_dir={directory}"
        )
        del sessions[session_id]
        dropped_session_ids.add(session_id)

    for slot in ("activeSessionsByWorkspace", "activeSessionsBySurface"):
        active = store.get(slot) or {}
        for key, entry in list(active.items()):
            if entry.get("sessionId") in dropped_session_ids:
                report.append(f"  clear {slot}[{key}] -> {entry.get('sessionId')}")
                del active[key]

    return report


def write_with_backup(path: Path, payload: dict[str, Any], apply: bool) -> None:
    if not apply:
        return
    backup = path.with_suffix(path.suffix + ".bak")
    shutil.copy2(path, backup)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    print(f"  wrote {path} (backup: {backup})")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--apply",
        action="store_true",
        help="write the pruned files (default: report only)",
    )
    parser.add_argument(
        "--session-file",
        type=Path,
        default=DEFAULT_SESSION_FILE,
        help=f"cmux session snapshot (default: {DEFAULT_SESSION_FILE})",
    )
    parser.add_argument(
        "--hook-store-dir",
        type=Path,
        default=DEFAULT_HOOK_STORE_DIR,
        help=f"directory holding *-hook-sessions.json (default: {DEFAULT_HOOK_STORE_DIR})",
    )
    args = parser.parse_args()

    if not args.session_file.exists():
        print(f"error: session snapshot not found: {args.session_file}", file=sys.stderr)
        return 1

    session = json.loads(args.session_file.read_text())

    # Panel directories are read BEFORE pruning so hook records are judged against
    # where the pane actually is, not against a claim this script is removing.
    panel_dirs: dict[str, str] = {}
    for workspace, panel in iter_panels(session):
        panel_id = panel.get("id")
        directory = panel_directory(workspace, panel)
        if panel_id and directory:
            panel_dirs[str(panel_id)] = directory

    print(f"session snapshot: {args.session_file}")
    session_report = prune_session_file(session)
    print("\n".join(session_report) if session_report else "  nothing to prune")
    if session_report:
        write_with_backup(args.session_file, session, args.apply)

    for store_path in sorted(args.hook_store_dir.glob("*-hook-sessions.json")):
        store = json.loads(store_path.read_text())
        print(f"\nhook store: {store_path}")
        store_report = prune_hook_store(store, panel_dirs)
        print("\n".join(store_report) if store_report else "  nothing to prune")
        if store_report:
            write_with_backup(store_path, store, args.apply)

    if not args.apply:
        print("\nDry run. Re-run with --apply (with cmux quit) to write the changes.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
