"""Exercise upgrade routing and image publication without a Docker daemon."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class UpgradeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        (self.path / 'agent-sandbox').symlink_to(ROOT / 'launcher.sh')
        self.log = self.path / 'docker.jsonl'
        docker = self.path / 'docker'
        docker.write_text('''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ['DOCKER_LOG'], 'a') as log:
    log.write(json.dumps(args) + '\\n')
if args[:3] == ['container', 'inspect', '--format']:
    print('tools-v3')
if args[0] == 'exec':
    sys.exit(int(os.environ.get('EXEC_STATUS', '0')))
''')
        docker.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.path),
                        PATH=f'{self.path}:{os.environ["PATH"]}',
                        DOCKER_LOG=str(self.log))

    def run_tools(self, *args, status=0):
        result = subprocess.run([str(self.path / 'agent-sandbox'), *args],
                                env=dict(self.env, EXEC_STATUS=str(status)),
                                capture_output=True, text=True)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return result, calls

    def test_upgrade_targets_are_forwarded_and_saved(self):
        for target in ('all', 'agents', 'system', 'npm'):
            with self.subTest(target=target):
                self.log.unlink(missing_ok=True)
                result, calls = self.run_tools('upgrade', target)
                self.assertEqual(result.returncode, 0, result.stderr)
                command = next(call for call in calls if call[0] == 'exec')
                self.assertEqual(command[-2:], ['sandbox-upgrade', target])
                self.assertIn('bash', command)
                self.assertTrue(any(call[0] == 'commit' for call in calls))
                self.assertLess(next(i for i, c in enumerate(calls) if c[0] == 'stop'),
                                next(i for i, c in enumerate(calls) if c[0] == 'commit'))
                self.assertNotIn('--mount', command)

    def test_default_target(self):
        result, calls = self.run_tools('upgrade')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(next(c for c in calls if c[0] == 'exec')[-1], 'all')

    def test_failed_upgrade_does_not_publish(self):
        result, calls = self.run_tools('upgrade', status=17)
        self.assertEqual(result.returncode, 17)
        self.assertFalse(any(c[0] == 'commit' for c in calls))
        self.assertTrue(any(c[0] == 'stop' for c in calls))

    def test_invalid_arguments_do_not_start_container(self):
        for args in [('upgrade', 'unknown'), ('upgrade', 'agents', 'extra')]:
            result, calls = self.run_tools(*args)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(calls, [])

    def test_help_does_not_start_container(self):
        result, calls = self.run_tools('--help')
        self.assertEqual(result.returncode, 0)
        self.assertIn('Node.js and Go', result.stdout)
        self.assertEqual(calls, [])

    def test_custom_commands_still_work(self):
        result, calls = self.run_tools('npm', 'install', '-g', 'pnpm')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(next(c for c in calls if c[0] == 'exec')[-4:],
                         ['npm', 'install', '-g', 'pnpm'])

    def test_installer_migrates_managed_legacy_wrapper(self):
        bin_dir = self.path / '.local' / 'bin'
        bin_dir.mkdir(parents=True)
        legacy = bin_dir / 'sandbox-tools'
        legacy.write_text('#!/bin/bash\n# agent-sandbox-managed-wrapper-v5\n')
        result = subprocess.run(['bash', str(ROOT / 'install.sh')],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(legacy.exists())
        self.assertEqual((bin_dir / 'agent-sandbox').read_text(),
                         (ROOT / 'launcher.sh').read_text())

    def test_installer_preserves_unrelated_legacy_file(self):
        bin_dir = self.path / '.local' / 'bin'
        bin_dir.mkdir(parents=True)
        legacy = bin_dir / 'sandbox-tools'
        legacy.write_text('#!/bin/bash\necho unrelated\n')
        result = subprocess.run(['bash', str(ROOT / 'install.sh')],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(legacy.read_text(), '#!/bin/bash\necho unrelated\n')


if __name__ == '__main__':
    unittest.main()
