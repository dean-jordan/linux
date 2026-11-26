# SPDX-License-Identifier: GPL-2.0

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name('run-clang-tools.py')

CLANG_TIDY = '''#!/usr/bin/env python3
from pathlib import Path
import sys

source = Path(sys.argv[-1]).name
sys.stdout.write(f'diagnostic for {source}\\n')
sys.stderr.write(f'checks for {source}: {sys.argv[3]}\\n')
sys.exit(7 if source == 'bad.c' else 0)
'''


class RunClangToolsTest(unittest.TestCase):
    def setUp(self):
        tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(tempdir.cleanup)
        self.root = Path(tempdir.name)
        self.build = self.root / 'build'
        self.build.mkdir()

        clang_tidy = self.root / 'clang-tidy'
        clang_tidy.write_text(CLANG_TIDY, encoding='utf-8')
        clang_tidy.chmod(0o755)
        self.env = dict(os.environ,
                        PATH=str(self.root) + os.pathsep + os.environ['PATH'])

    def run_tools(self, *files, analysis='clang-tidy'):
        commands = self.root / 'compile_commands.json'
        entries = []
        for filename in files:
            source = self.build / filename
            source.touch()
            entries.append({
                'directory': str(self.build),
                'file': str(source),
                'arguments': ['clang', '-c', str(source)],
            })
        commands.write_text(json.dumps(entries), encoding='utf-8')
        return subprocess.run([sys.executable, str(SCRIPT), analysis,
                               str(commands)], cwd=self.root, env=self.env,
                              capture_output=True, text=True, timeout=30)

    def test_reports_success_when_all_jobs_pass(self):
        result = self.run_tools('first.c', 'last.cpp', 'ignored.S')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '')
        self.assertIn('Skipping non-C file:', result.stderr)
        self.assertNotIn('diagnostic for ignored.S', result.stderr)
        for source in ('first.c', 'last.cpp'):
            with self.subTest(source=source):
                self.assertIn(f'diagnostic for {source}\n', result.stderr)

    def test_reports_failure_and_finishes_other_jobs(self):
        result = self.run_tools('first.c', 'bad.c', 'last.cpp',
                                analysis='clang-analyzer')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(result.stdout, '')
        for source in ('first.c', 'bad.c', 'last.cpp'):
            with self.subTest(source=source):
                self.assertIn(f'diagnostic for {source}\n', result.stderr)
                self.assertIn(f'checks for {source}: -checks=-*,clang-analyzer-*',
                              result.stderr)


if __name__ == '__main__':
    unittest.main()
