#!/usr/bin/env python3
"""Lightweight owned-source provenance regressions; no SDK build or network."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


spec = importlib.util.spec_from_file_location("nice_transport", Path(__file__).with_name("build_owned_nice_transport.py"))
backend = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backend)


def git(root, *arguments):
    return subprocess.check_output(["git", "-C", str(root), *arguments], text=True, stderr=subprocess.DEVNULL)


def repository(root):
    root.mkdir(parents=True)
    git(root, "init", "--quiet")
    git(root, "config", "user.name", "Owned provenance fixture")
    git(root, "config", "user.email", "fixture@example.invalid")
    (root / "README").write_text("Owned baseline\n")
    git(root, "add", "README")
    git(root, "commit", "--quiet", "-m", "Owned fixture baseline")
    return git(root, "rev-parse", "HEAD").strip()


class SourceRefusalTests(unittest.TestCase):
    def test_owned_archive_receipt_refuses_mutation_and_foreign_target(self):
        with tempfile.TemporaryDirectory(prefix="stream-owned-archive-refusal-") as directory:
            prefix = Path(directory)
            archive = prefix / "libglib.a"
            archive.write_bytes(b"owned source-build artifact")
            receipt = {"architecture": "arm64", "target": "14.0", "archives": [{"path": str(archive), "sha256": backend.digest(archive)}]}
            (prefix / "owned-dependencies.json").write_text(json.dumps(receipt))
            backend.verify_owned_dependencies(prefix, "arm64", "14.0")
            with self.assertRaisesRegex(RuntimeError, "architecture or runtime floor"):
                backend.verify_owned_dependencies(prefix, "x86_64", "14.0")
            with self.assertRaisesRegex(RuntimeError, "architecture or runtime floor"):
                backend.verify_owned_dependencies(prefix, "arm64", "13.0")
            archive.write_bytes(b"owned modified artifact")
            with self.assertRaisesRegex(RuntimeError, "differs from its source-build receipt"):
                backend.verify_owned_dependencies(prefix, "arm64", "14.0")
            self.assertEqual(archive.read_bytes(), b"owned modified artifact")

    def test_staged_source_is_refused_and_preserved(self):
        with tempfile.TemporaryDirectory(prefix="stream-nice-source-refusal-") as directory:
            root = Path(directory)
            source = root / "libnice-source"
            pin = repository(source)
            changed = source / "README"
            changed.write_text("Owned staged mutation\n")
            git(source, "add", "README")
            index = git(source, "diff", "--cached", "--binary")
            with self.assertRaisesRegex(RuntimeError, "Unrelated source changes"):
                backend.checkout(root, source.name, "unused-owned-fixture", pin)
            self.assertEqual(changed.read_text(), "Owned staged mutation\n")
            self.assertEqual(git(source, "diff", "--cached", "--binary"), index)

    def test_tracked_submodule_changes_are_refused_and_preserved(self):
        for staged in (False, True):
            with self.subTest(staged=staged), tempfile.TemporaryDirectory(prefix="stream-nice-submodule-refusal-") as directory:
                root = Path(directory)
                seed = root / "owned-child"
                repository(seed)
                source = root / "libdatachannel-source"
                repository(source)
                git(source, "-c", "protocol.file.allow=always", "submodule", "add", "--quiet", str(seed), "deps/child")
                git(source, "commit", "--quiet", "-am", "Owned submodule baseline")
                pin = git(source, "rev-parse", "HEAD").strip()
                # Exercise the recursive guard even when Git configuration hides
                # submodule dirtiness from the parent's ordinary diff.
                git(source, "config", "diff.ignoreSubmodules", "all")
                child = source / "deps/child"
                changed = child / "README"
                changed.write_text("Owned dirty child\n")
                if staged:
                    git(child, "add", "README")
                index = git(child, "diff", "--cached", "--binary")
                with self.assertRaisesRegex(RuntimeError, "submodule has staged or unstaged tracked changes"):
                    backend.checkout(root, source.name, "unused-owned-fixture", pin, recursive=True)
                self.assertEqual(changed.read_text(), "Owned dirty child\n")
                self.assertEqual(git(child, "diff", "--cached", "--binary"), index)


if __name__ == "__main__":
    unittest.main()
