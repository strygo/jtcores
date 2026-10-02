#!/usr/bin/env python3
"""Verify the entire exported tree, replaying its patches against its base.

Self-contained in the core export; no Capcom checkout or scratch dependency.
Unknown tracked changes, dirty submodules and untracked source are rejected.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

BUNDLE = "modules/cpsplus/evolution-capacity"


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args]).decode().strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(root):
    manifest = json.loads((root / BUNDLE / "export_manifest.json").read_text())
    expected_files = set(manifest["rtl_files"]) | set(manifest["bundle_files"]) | {f"{BUNDLE}/export_manifest.json"}
    changed = set(git(root, "diff", "--name-only", manifest["base_revision"], "HEAD").splitlines())
    if changed != expected_files:
        raise ValueError(f"full-tree delta mismatch: {sorted(changed ^ expected_files)}")
    if git(root, "status", "--porcelain", "--untracked-files=all"):
        raise ValueError("export must be clean, including untracked files")
    for name, expected in (manifest["rtl_files"] | manifest["bundle_files"]).items():
        if digest(root / name) != expected:
            raise ValueError(f"exported content drift: {name}")
    for name, expected in manifest["submodules"].items():
        if git(root / name, "rev-parse", "HEAD") != expected or git(root / name, "status", "--porcelain"):
            raise ValueError(f"submodule identity/drift: {name}")
    patches = root / BUNDLE / "patches"
    if {p.name for p in patches.iterdir()} != set(manifest["patches"]):
        raise ValueError("unexpected patch set")
    with tempfile.TemporaryDirectory(prefix="capacity-replay-", dir=root.parent) as tmp:
        replay = Path(tmp) / "tree"
        git(root, "worktree", "add", "--detach", "-q", str(replay), manifest["base_revision"])
        try:
            for name, expected in manifest["patches"].items():
                patch = patches / name
                if digest(patch) != expected:
                    raise ValueError(f"patch drift: {name}")
                git(replay, "apply", str(patch))
            for name, expected in manifest["rtl_files"].items():
                if digest(replay / name) != expected:
                    raise ValueError(f"patch replay differs: {name}")
        finally:
            git(root, "worktree", "remove", "--force", str(replay))
    # Whole-tree comparison above includes every changed file, not just known
    # RTL files. It excludes no audio or build-script subtree.
    print(f"PASS full-tree export: {len(manifest['patches'])} replayed patches, "
          f"{len(manifest['rtl_files'])} source files; only declared bundle/workflow additions")
    return manifest


def self_test(root):
    verify(root)
    # A committed edit outside all declared RTL files must fail the whole-tree
    # check, even though every known patched file still has its expected hash.
    with tempfile.TemporaryDirectory(prefix="capacity-mutation-", dir=root.parent) as tmp:
        mutant = Path(tmp) / "tree"
        git(root, "worktree", "add", "--detach", "-q", str(mutant), "HEAD")
        try:
            target = mutant / "modules/cpsplus/README.md"
            target.write_text(target.read_text() + "\nUnexpected containment test edit.\n")
            git(mutant, "add", "--", "modules/cpsplus/README.md")
            git(mutant, "-c", "user.name=Containment Test", "-c", "user.email=containment@example.invalid",
                "commit", "-q", "-m", "temporary containment mutation")
            try: verify(mutant)
            except ValueError as error:
                if "full-tree delta mismatch" not in str(error): raise
            else: raise AssertionError("unexpected committed CPS+ subtree edit passed")
        finally:
            git(root, "worktree", "remove", "--force", str(mutant))
    print("PASS containment negative control: unexpected committed CPS+ subtree edit rejected")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test: self_test(args.root.resolve())
    else: verify(args.root.resolve())
