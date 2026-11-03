#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.14"
# ///
"""Fill a Ghostty checkout's zig-pkg/ with its dependencies before `zig build`.

Zig 0.17.0 stores fetched dependency archives with their top-level directory
still present, so the build re-hashes them as anonymous `N-V-...` packages and
fails with "hash mismatch". This unpacks every dependency declared in the
checkout's build.zig.zon files (and, transitively, in the dependencies' own
manifests), stripped of that directory, into `<checkout>/zig-pkg/<hash>/`,
which is where the build looks first. Existing entries are left alone.

Downloads use curl and git, so they work where Zig's own TLS does not.
Python 3.14 is required because some dependencies are .tar.zst archives.

Usage: scripts/populate-ghostty-zig-pkg.py [ghostty-checkout] [--cache DIR]
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import tarfile
import tempfile
import zipfile
from pathlib import Path

DEPENDENCY = re.compile(r'\.url\s*=\s*"([^"]+)"\s*,\s*\.hash\s*=\s*"([^"]+)"', re.S)


def manifests(root: Path) -> list[Path]:
    return [
        path
        for path in root.rglob("build.zig.zon")
        if not {".git", ".zig-cache", "zig-out"} & set(path.relative_to(root).parts)
    ]


def download(url: str, cache: Path) -> Path:
    target = cache / re.sub(r"[^A-Za-z0-9._-]", "_", url)
    if not target.exists():
        partial = target.with_suffix(target.suffix + ".part")
        subprocess.run(["curl", "-sSfL", "--retry", "3", "-o", str(partial), url], check=True)
        partial.rename(target)
    return target


def checkout(url: str, cache: Path) -> Path:
    repo, _, rev = url.removeprefix("git+").partition("#")
    repo = repo.split("?")[0]
    target = cache / f"git-{repo.rstrip('/').split('/')[-1].removesuffix('.git')}-{rev[:12]}"
    if not (target / ".git").is_dir():
        subprocess.run(["git", "init", "-q", str(target)], check=True)
        subprocess.run(["git", "-C", str(target), "fetch", "-q", "--depth", "1", repo, rev], check=True)
        subprocess.run(["git", "-C", str(target), "checkout", "-q", "FETCH_HEAD"], check=True)
    return target


def extract(url: str, scratch: Path, cache: Path) -> Path:
    if url.startswith("git+"):
        return checkout(url, cache)
    archive = download(url, cache)
    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as zf:
            zf.extractall(scratch)
    else:
        with tarfile.open(archive) as tf:
            tf.extractall(scratch, filter="tar")
    entries = list(scratch.iterdir())
    return entries[0] if len(entries) == 1 and entries[0].is_dir() else scratch


def unpack(url: str, destination: Path, cache: Path) -> None:
    # Build the tree beside its final location and rename it in, so a failed
    # run never leaves a partial entry that the next run would treat as done.
    with (
        tempfile.TemporaryDirectory(dir=cache) as scratch,
        tempfile.TemporaryDirectory(dir=destination.parent) as staging,
    ):
        tree = Path(staging) / "tree"
        shutil.copytree(
            extract(url, Path(scratch), cache),
            tree,
            symlinks=True,
            ignore=shutil.ignore_patterns(".git") if url.startswith("git+") else None,
        )
        tree.rename(destination)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("checkout", nargs="?", default=Path(__file__).resolve().parents[1] / "ghostty", type=Path)
    parser.add_argument("--cache", type=Path, default=Path(tempfile.gettempdir()) / "ghostty-zig-deps")
    args = parser.parse_args()
    checkout_root: Path = args.checkout.resolve()
    pkg_root = checkout_root / "zig-pkg"
    pkg_root.mkdir(exist_ok=True)
    args.cache.mkdir(parents=True, exist_ok=True)

    added = 0
    changed = True
    while changed:
        changed = False
        for manifest in manifests(checkout_root):
            for url, digest in DEPENDENCY.findall(manifest.read_text()):
                destination = pkg_root / digest
                if destination.exists():
                    continue
                unpack(url, destination, args.cache)
                print(f"added {digest}")
                added += 1
                changed = True
    print(f"{added} added, {len(list(pkg_root.iterdir()))} in {pkg_root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
