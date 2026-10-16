"""Exercise real Git fast-forwards and installed application publication offline."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ('Dockerfile', 'entrypoint.sh', '.dockerignore', 'Upgrade.Dockerfile',
             'upgrade-image.sh', 'upgrade.sh', 'refresh-app.sh')


class RefreshAppTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = dict(os.environ, HOME=str(self.root / 'home'),
                        GIT_AUTHOR_NAME='Test User', GIT_COMMITTER_NAME='Test User',
                        GIT_AUTHOR_EMAIL='test@example.com', GIT_COMMITTER_EMAIL='test@example.com')
        self.remote = self.root / 'remote.git'
        self.run_git('init', '--bare', '-q', str(self.remote))
        self.writer = self.root / 'writer'
        self.run_git('clone', '-q', str(self.remote), str(self.writer))
        for resource in (*RESOURCES, 'launcher.sh'):
            shutil.copyfile(ROOT / resource, self.writer / resource)
        self.run_git('-C', str(self.writer), 'add', '.')
        self.run_git('-C', str(self.writer), 'commit', '-qm', 'Initial app')
        self.run_git('-C', str(self.writer), 'push', '-q', 'origin', 'HEAD')
        self.source = self.root / 'source checkout'
        self.run_git('clone', '-q', str(self.remote), str(self.source))
        self.installed = Path(self.env['HOME']) / '.local/share/agent-sandbox'
        self.installed.mkdir(parents=True)
        self.bin = Path(self.env['HOME']) / '.local/bin'
        self.bin.mkdir(parents=True)
        for resource in RESOURCES:
            shutil.copyfile(self.source / resource, self.installed / resource)
        for agent in ('codex', 'claude', 'agent-sandbox'):
            shutil.copyfile(self.source / 'launcher.sh', self.bin / agent)
        (self.installed / 'source-dir').write_text(str(self.source) + '\n')
        with (self.writer / 'entrypoint.sh').open('a') as f:
            f.write('\n# Updated upstream entrypoint\n')
        self.run_git('-C', str(self.writer), 'commit', '-qam', 'Update entrypoint')
        self.run_git('-C', str(self.writer), 'push', '-q')

    def run_git(self, *args):
        return subprocess.run(['git', *args], env=self.env, check=True,
                              capture_output=True, text=True)

    def refresh(self):
        return subprocess.run(['bash', str(self.installed / 'refresh-app.sh'), str(self.installed)],
                              env=self.env, capture_output=True, text=True)

    def test_pulls_and_refreshes_without_installer_or_docker(self):
        result = self.refresh()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Updated upstream entrypoint', (self.installed / 'entrypoint.sh').read_text())
        for agent in ('codex', 'claude', 'agent-sandbox'):
            self.assertEqual((self.bin / agent).read_bytes(), (self.source / 'launcher.sh').read_bytes())
            self.assertTrue(os.access(self.bin / agent, os.X_OK))
        self.assertEqual(list(self.installed.glob('.refresh-*')), [])

    def test_dirty_checkout_is_preserved(self):
        (self.source / 'entrypoint.sh').write_text('local edits\n')
        before = (self.installed / 'entrypoint.sh').read_bytes()
        result = self.refresh()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('local changes', result.stderr)
        self.assertEqual((self.source / 'entrypoint.sh').read_text(), 'local edits\n')
        self.assertEqual((self.installed / 'entrypoint.sh').read_bytes(), before)

    def test_diverged_checkout_does_not_publish(self):
        (self.source / 'local-file').write_text('local commit\n')
        self.run_git('-C', str(self.source), 'add', '.')
        self.run_git('-C', str(self.source), 'commit', '-qm', 'Local divergence')
        before = (self.installed / 'entrypoint.sh').read_bytes()
        self.assertNotEqual(self.refresh().returncode, 0)
        self.assertEqual((self.installed / 'entrypoint.sh').read_bytes(), before)

    def test_invalid_upstream_script_does_not_publish(self):
        (self.writer / 'entrypoint.sh').write_text('if then\n')
        self.run_git('-C', str(self.writer), 'commit', '-qam', 'Broken script')
        self.run_git('-C', str(self.writer), 'push', '-q')
        before = (self.installed / 'entrypoint.sh').read_bytes()
        self.assertNotEqual(self.refresh().returncode, 0)
        self.assertEqual((self.installed / 'entrypoint.sh').read_bytes(), before)

    def test_publication_failure_restores_installed_files(self):
        before = {name: (self.installed / name).read_bytes() for name in RESOURCES}
        fake_bin = self.root / 'fake-bin'
        fake_bin.mkdir()
        mv = fake_bin / 'mv'
        real_mv = shutil.which('mv')
        mv.write_text('#!/usr/bin/env python3\nimport os, sys\n'
                      'if sys.argv[-1].endswith("/entrypoint.sh"): sys.exit(31)\n'
                      f'os.execv({real_mv!r}, [{real_mv!r}, *sys.argv[1:]])\n')
        mv.chmod(0o755)
        self.env['PATH'] = str(fake_bin) + ':' + os.environ['PATH']
        result = self.refresh()
        self.assertEqual(result.returncode, 31, result.stderr)
        for name, content in before.items():
            self.assertEqual((self.installed / name).read_bytes(), content)
        self.assertEqual(list(self.installed.glob('.refresh-*')), [])
        self.assertEqual(list(self.bin.glob('.*.new')), [])

    def test_unmanaged_wrapper_is_preserved(self):
        (self.bin / 'codex').write_text('unrelated wrapper\n')
        result = self.refresh()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('unmanaged', result.stderr)
        self.assertEqual((self.bin / 'codex').read_text(), 'unrelated wrapper\n')
