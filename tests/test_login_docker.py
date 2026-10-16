"""Opt-in real Docker/Codex auth persistence test; no account or API calls.

Run with AGENT_SANDBOX_TEST_IMAGE=agent-sandbox:dev-$(id -u).
Uses a dummy API key only in a temporary directory, never your auth volume.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
IMAGE = os.environ.get('AGENT_SANDBOX_TEST_IMAGE')


@unittest.skipUnless(IMAGE and shutil.which('docker'),
                     'Set AGENT_SANDBOX_TEST_IMAGE and provide Docker to run')
class DockerLoginTests(unittest.TestCase):
    def test_login_survives_new_container_and_logout_clears_it(self):
        with tempfile.TemporaryDirectory() as state:
            def run(*args, stdin=None):
                return subprocess.run([
                    'docker', 'run', '--rm', '--interactive', '--network', 'none',
                    '--read-only', '--user', f'{os.getuid()}:{os.getgid()}',
                    '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges:true',
                    '--tmpfs', '/tmp:rw,nosuid,nodev',
                    '--mount', f'type=bind,src={state},dst=/home/node',
                    '--mount', f'type=bind,src={ROOT / "entrypoint.sh"},dst=/run/current-entrypoint.sh,readonly',
                    '--env', 'HOME=/home/node', '--env', 'CODEX_HOME=/home/node/.codex',
                    '--env', 'OPENAI_API_KEY=inherited-key-must-be-ignored',
                    '--entrypoint', '/bin/bash', IMAGE,
                    '/run/current-entrypoint.sh', 'codex',
                    '-c', 'cli_auth_credentials_store="file"', *args,
                ], input=stdin, capture_output=True, text=True, timeout=60)

            result = run('login', '--with-api-key', stdin='sandbox-test-dummy-key\n')
            self.assertEqual(result.returncode, 0, result.stderr)
            saved = Path(state, '.codex', 'auth.json').read_bytes()
            result = run('login', 'status')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(Path(state, '.codex', 'auth.json').read_bytes(), saved)
            result = run('logout')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(Path(state, '.codex', 'auth.json').exists())
            result = run('login', 'status')
            self.assertNotEqual(result.returncode, 0)
