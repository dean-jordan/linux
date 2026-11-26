#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0

"""Regression tests for the documentation file reference checker."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


CHECKER = Path(__file__).resolve().parents[1] / "docs/documentation-file-ref-check"


@unittest.skipUnless(shutil.which("git") and shutil.which("perl"),
                     "the reference checker requires git and Perl")
class DocumentationFileRefCheckTest(unittest.TestCase):
    def test_reports_each_broken_doc_role_on_a_line(self):
        with tempfile.TemporaryDirectory() as directory:
            docs = Path(directory) / "Documentation"
            docs.mkdir()
            (docs / "index.rst").write_text(
                "See :doc:`missing-first` and :doc:`existing`.\n"
                "See :doc:`Titled <missing-titled>` and :doc:`/missing-root`.\n"
                "See :doc:`Titled <existing>` and :doc:`/existing`.\n",
                encoding="utf-8",
            )
            (docs / "existing.rst").touch()
            subprocess.run(["git", "init", "-q"], cwd=directory, check=True)
            subprocess.run(["git", "add", "Documentation"], cwd=directory, check=True)

            result = subprocess.run(["perl", str(CHECKER)], cwd=directory,
                                    capture_output=True, text=True, check=True)

        self.assertEqual(result.stderr.splitlines(), [
            "Documentation/index.rst: :doc:`missing-first`",
            "Documentation/index.rst: :doc:`Titled <missing-titled>`",
            "Documentation/index.rst: :doc:`/missing-root`",
        ])


if __name__ == "__main__":
    unittest.main()
