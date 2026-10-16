"""Verify uninstall removes only managed host files and preserves saved data."""
import fcntl
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class UninstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.bin = self.home / '.local/bin'
        self.bin.mkdir(parents=True)
        self.support = self.home / '.local/share/agent-sandbox'
        self.support.mkdir(parents=True)
        self.env = dict(os.environ, HOME=str(self.home))

    def run_uninstall(self, *args):
        return subprocess.run(['bash', str(ROOT / 'uninstall.sh'), *args],
                              env=self.env, capture_output=True, text=True)

    def test_removes_managed_files_and_is_repeatable(self):
        for name in ('claude', 'codex', 'agent-sandbox', 'sandbox-tools', 'codex-sandbox'):
            (self.bin / name).write_text('#!/bin/bash\n# agent-sandbox-managed-wrapper-v8\n')
        (self.support / 'entrypoint.sh').write_text('managed support\n')
        (self.support / 'source-dir').write_text('/kept/source\n')
        extra = self.support / 'my-notes'
        extra.write_text('keep me\n')
        shell_config = self.home / '.bashrc'
        shell_config.write_text('export PATH="$HOME/.local/bin:$PATH"\n')
        # Any Docker call would fail the test; uninstall needs no daemon.
        docker = self.bin / 'docker'
        docker.write_text('#!/bin/bash\nexit 99\n')
        docker.chmod(0o755)
        self.env['PATH'] = str(self.bin) + ':' + os.environ['PATH']
        for _ in range(2):
            result = self.run_uninstall()
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(p.name for p in self.bin.iterdir()), ['docker'])
        self.assertEqual(sorted(p.name for p in self.support.iterdir()), ['my-notes'])
        self.assertEqual(extra.read_text(), 'keep me\n')
        self.assertTrue(shell_config.exists())

    def test_preserves_unrelated_commands_and_symlinks(self):
        codex = self.bin / 'codex'
        codex.write_text('unrelated command\n')
        target = self.home / 'other-cli'
        target.write_text('# agent-sandbox-managed-wrapper-v8\n')
        (self.bin / 'claude').symlink_to(target)
        self.assertEqual(self.run_uninstall().returncode, 0)
        self.assertEqual(codex.read_text(), 'unrelated command\n')
        self.assertTrue((self.bin / 'claude').is_symlink())
        self.assertTrue(target.exists())

    def test_busy_lock_prevents_removal(self):
        lock_dir = self.home / '.local/state/agent-sandbox'
        lock_dir.mkdir(parents=True)
        codex = self.bin / 'codex'
        codex.write_text('# agent-sandbox-managed-wrapper-v8\n')
        with (lock_dir / 'tools.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.run_uninstall().returncode, 2)
        self.assertTrue(codex.exists())

    def test_help_and_invalid_args_do_not_modify_files(self):
        for args, expected in [(('--help',), 0), (('--purge',), 2)]:
            result = self.run_uninstall(*args)
            self.assertEqual(result.returncode, expected)
            self.assertTrue(self.support.exists())
            self.assertFalse((self.home / '.local/state').exists())
