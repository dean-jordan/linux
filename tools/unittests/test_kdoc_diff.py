#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0

"""Exercise the kernel-doc regression check through its command line."""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


KDOC_DIFF = Path(__file__).resolve().parents[1] / "docs/kdoc_diff"


@unittest.skipUnless(shutil.which("git"), "kdoc_diff requires git")
class KdocDiffTest(unittest.TestCase):
    def test_regression_command_reports_test_status(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            docs = root / "tools/docs"
            docs.mkdir(parents=True)
            tests = root / "tools/unittests"
            tests.mkdir()
            shutil.copyfile(KDOC_DIFF, docs / "kdoc_diff")

            # Minimal child commands isolate status propagation from parsing.
            kernel_doc = docs / "kernel-doc"
            kernel_doc.write_text('#!/bin/sh\nprintf "tests: []\\n" > "$4"\n',
                                  encoding="utf-8")
            kernel_doc.chmod(0o755)
            parser_test = tests / "test_kdoc_parser.py"
            parser_test.write_text('#!/bin/sh\nset -e\ntest -s "$3"\n'
                                   'exit "$(cat status)"\n', encoding="utf-8")
            parser_test.chmod(0o755)
            (root / "example.c").touch()

            def git(*args):
                return subprocess.run([
                    "git", "-c", "user.name=Test Fixture",
                    "-c", "user.email=fixture@example.invalid",
                    "-c", "commit.gpgsign=false", *args,
                ], cwd=root, capture_output=True, text=True, check=True).stdout.strip()

            git("init", "-q", "--template=")
            for status in (0, 1):
                (root / "status").write_text(str(status), encoding="utf-8")
                git("add", ".")
                git("commit", "-qm", f"Parser status {status}")

            original_head = git("rev-parse", "HEAD")
            for revision, status in (("HEAD~..HEAD~", 0), ("HEAD~..HEAD", 1)):
                with self.subTest(revision=revision):
                    output = subprocess.run([
                        sys.executable, str(docs / "kdoc_diff"), revision,
                        "example.c", "--regression",
                    ], cwd=root, capture_output=True, text=True)
                    self.assertEqual(output.returncode, status,
                                     output.stdout + output.stderr)
                    self.assertNotIn("Failed to generate documentation", output.stderr)
                    self.assertEqual(git("rev-parse", "HEAD"), original_head)


if __name__ == "__main__":
    unittest.main()
