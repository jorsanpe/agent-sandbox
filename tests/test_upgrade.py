"""Exercise upgrade routing and image publication without a Docker daemon."""
import json
import os
import shutil
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
        resources = self.path / '.local' / 'share' / 'agent-sandbox'
        resources.mkdir(parents=True)
        for name in ('Dockerfile', 'entrypoint.sh', '.dockerignore',
                     'Upgrade.Dockerfile', 'upgrade-image.sh', 'upgrade.sh', 'refresh-app.sh'):
            shutil.copyfile(ROOT / name, resources / name)
        # Routing tests isolate image upgrade behavior from Git/network updates.
        (resources / 'refresh-app.sh').write_text('#!/bin/bash\nexit 0\n')
        self.log = self.path / 'docker.jsonl'
        docker = self.path / 'docker'
        docker.write_text('''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ['DOCKER_LOG'], 'a') as log:
    log.write(json.dumps(args) + '\\n')
if args[:2] == ['container', 'inspect'] and os.environ.get('NO_TOOLS'):
    sys.exit(1)
if args[:3] == ['container', 'inspect', '--format']:
    print(os.environ.get('TOOLS_RUNNING', 'false') if args[3] == '{{.State.Running}}' else 'tools-v3')
if args[:2] == ['image', 'tag'] and 'upgrade-dev-' in args[2] and os.environ.get('FAIL_PUBLISH'):
    sys.exit(19)
if args[0] == os.environ.get('FAIL_COMMAND'):
    sys.exit(19)
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
        for target in ('agents', 'system', 'npm'):
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
        builds = [c for c in calls if c[0] == 'build']
        self.assertEqual(len(builds), 2)
        self.assertIn('--pull', builds[0])
        self.assertTrue(all('--no-cache' in c for c in builds))
        self.assertTrue(any('CURRENT_IMAGE=agent-sandbox:upgrade-source-' in arg
                            for arg in builds[1]))
        smoke = next(i for i, c in enumerate(calls) if c[0] == 'run')
        publish = next(i for i, c in enumerate(calls)
                       if c[:2] == ['image', 'tag'] and c[-1].startswith('agent-sandbox:dev-')
                       and '-backup-' not in c[-1])
        self.assertLess(smoke, publish)
        self.assertTrue(any(c[:2] == ['container', 'rename'] for c in calls))
        self.assertFalse(any('volume' in c or '--mount' in c for c in calls))

    def test_full_upgrade_failure_keeps_active_image_and_tools(self):
        for failure in ('build', 'run'):
            with self.subTest(failure=failure):
                self.log.unlink(missing_ok=True)
                self.env['FAIL_COMMAND'] = failure
                result, calls = self.run_tools('upgrade', 'all')
                self.assertEqual(result.returncode, 19, result.stderr)
                self.assertFalse(any(c[:2] == ['container', 'rename'] for c in calls))
                self.assertFalse(any(c[:2] == ['image', 'tag'] and c[-1] == 'agent-sandbox:dev-' + str(os.getuid())
                                     for c in calls))

    def test_full_upgrade_rejects_active_tools(self):
        self.env['TOOLS_RUNNING'] = 'true'
        result, calls = self.run_tools('upgrade')
        self.assertEqual(result.returncode, 2)
        self.assertFalse(any(c[0] in ('build', 'commit') for c in calls))

    def test_publication_failure_restores_tools_and_image(self):
        self.env['FAIL_PUBLISH'] = '1'
        result, calls = self.run_tools('upgrade')
        self.assertEqual(result.returncode, 19, result.stderr)
        renames = [c for c in calls if c[:2] == ['container', 'rename']]
        self.assertEqual(len(renames), 2)
        self.assertEqual(renames[0][2:], list(reversed(renames[1][2:])))
        self.assertTrue(any(c[:2] == ['image', 'tag'] and '-backup-' in c[2]
                            and c[-1] == 'agent-sandbox:dev-' + str(os.getuid())
                            for c in calls))

    def test_full_upgrade_without_tools_uses_shared_image(self):
        self.env['NO_TOOLS'] = '1'
        result, calls = self.run_tools('upgrade')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(c[0] == 'commit' for c in calls))
        self.assertFalse(any(c[:2] == ['container', 'rename'] for c in calls))

    def test_application_refresh_failure_prevents_image_upgrade(self):
        refresh = self.path / '.local/share/agent-sandbox/refresh-app.sh'
        refresh.write_text('#!/bin/bash\nexit 23\n')
        result, calls = self.run_tools('upgrade')
        self.assertEqual(result.returncode, 23)
        self.assertEqual(calls, [])

    def test_full_upgrade_missing_definitions_explains_bootstrap(self):
        (self.path / '.local/share/agent-sandbox/upgrade.sh').unlink()
        result, calls = self.run_tools('upgrade')
        self.assertEqual(result.returncode, 2)
        self.assertIn('updated install.sh once', result.stderr)
        self.assertEqual(calls, [])

    def test_failed_upgrade_does_not_publish(self):
        result, calls = self.run_tools('upgrade', 'agents', status=17)
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
        self.assertEqual((self.path / '.local/share/agent-sandbox/upgrade.sh').read_text(),
                         (ROOT / 'upgrade.sh').read_text())

    def test_installer_can_refresh_v7_and_be_rerun(self):
        bin_dir = self.path / '.local' / 'bin'
        bin_dir.mkdir(parents=True)
        for name in ('codex', 'claude', 'agent-sandbox'):
            (bin_dir / name).write_text('#!/bin/bash\n# agent-sandbox-managed-wrapper-v7\n')
        for _ in range(2):
            result = subprocess.run(['bash', str(ROOT / 'install.sh')],
                                    env=self.env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertFalse(any(c[:2] == ['volume', 'rm'] for c in calls))
        states = [c[2] for c in calls if c[:2] == ['volume', 'create']]
        uid = os.getuid()
        self.assertEqual(states, [f'agent-sandbox-{a}-{uid}'
                                 for _ in range(2) for a in ('claude', 'codex')])

    def test_codex_state_and_login_network(self):
        codex = self.path / 'codex'
        codex.symlink_to(ROOT / 'launcher.sh')
        project = self.path / 'project'
        project.mkdir()
        for args, network in [((), 'bridge'), (('resume', '--all'), 'bridge'),
                              (('login',), 'host'),
                              (('login', '--device-auth'), 'bridge'),
                              (('login', 'status'), 'bridge')]:
            with self.subTest(args=args):
                self.log.unlink(missing_ok=True)
                result = subprocess.run([str(codex), *args], cwd=project,
                                        env=dict(self.env, AGENT_SANDBOX_SSH='0'),
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = [json.loads(line) for line in self.log.read_text().splitlines()]
                run = next(c for c in calls if c[0] == 'run')
                self.assertEqual(run[run.index('--network') + 1], network)
                self.assertEqual(run.count('--network'), 1)
                self.assertIn('HOME=/home/node', run)
                self.assertIn('CODEX_HOME=/home/node/.codex', run)
                self.assertIn(f'type=volume,src=agent-sandbox-codex-{os.getuid()},dst=/home/node,volume-nocopy', run)
                self.assertEqual(run[run.index('--workdir') + 1],
                                 '/tmp' if args and args[0] == 'login' else str(project))

    def test_auth_from_home_ignores_project_and_stale_ssh(self):
        (self.path / 'codex').symlink_to(ROOT / 'launcher.sh')
        cases = [(('login', '-c', 'foo=true'), 'host'),
                 (('-c', 'foo=true', 'login'), 'host'),
                 (('--config=foo=true', 'login'), 'host'),
                 (('login', '--device-auth'), 'bridge'),
                 (('-c', 'foo=true', 'login', 'status'), 'bridge'),
                 (('logout',), 'bridge')]
        for args, network in cases:
            with self.subTest(args=args):
                self.log.unlink(missing_ok=True)
                result = subprocess.run([str(self.path / 'codex'), *args],
                                        cwd=self.path,
                                        env=dict(self.env, SSH_AUTH_SOCK='/missing/socket'),
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = [json.loads(line) for line in self.log.read_text().splitlines()]
                run = next(c for c in calls if c[0] == 'run')
                self.assertEqual(run[run.index('--network') + 1], network)
                self.assertEqual(run[run.index('--workdir') + 1], '/tmp')
                self.assertNotIn('SSH_AUTH_SOCK=/run/agent-sandbox/ssh-agent', run)
                self.assertNotIn('sandbox_mode="danger-full-access"', run)
                self.assertFalse(any('dst=' + str(self.path) in a for a in run))
                self.assertIn(f'type=bind,src={self.path}/.local/share/agent-sandbox/entrypoint.sh,dst=/run/agent-sandbox-entrypoint.sh,readonly', run)
                self.assertEqual(run[run.index('--entrypoint') + 1], '/bin/bash')
                self.assertEqual(run[-len(args):], list(args))

    def test_host_git_identity_is_forwarded_for_both_agents(self):
        project = self.path / 'identity-project'
        project.mkdir()
        subprocess.run(['git', 'init', '-q', str(project)], check=True)
        for key, value in [('user.name', 'Project User'), ('user.email', 'project@example.com')]:
            subprocess.run(['git', '-C', str(project), 'config', key, value], check=True)
        for agent in ('codex', 'claude'):
            wrapper = self.path / agent
            wrapper.symlink_to(ROOT / 'launcher.sh')
            self.log.unlink(missing_ok=True)
            env = dict(self.env, AGENT_SANDBOX_SSH='0', GIT_AUTHOR_NAME='Explicit Author')
            for key in ('GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL'):
                env.pop(key, None)
            result = subprocess.run([str(wrapper)], cwd=project, env=env,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = [json.loads(line) for line in self.log.read_text().splitlines()]
            run = next(c for c in calls if c[0] == 'run')
            for value in ('GIT_AUTHOR_NAME=Explicit Author',
                          'GIT_COMMITTER_NAME=Project User',
                          'GIT_AUTHOR_EMAIL=project@example.com',
                          'GIT_COMMITTER_EMAIL=project@example.com'):
                self.assertIn(value, run)
            self.assertFalse(any('.gitconfig' in value for value in run))

    def test_codex_host_api_key_is_not_forwarded(self):
        (self.path / 'codex').symlink_to(ROOT / 'launcher.sh')
        project = self.path / 'project'
        project.mkdir()
        for args in ((), ('login',), ('login', '--with-api-key'), ('logout',)):
            with self.subTest(args=args):
                self.log.unlink(missing_ok=True)
                result = subprocess.run(
                    [str(self.path / 'codex'), *args], cwd=project,
                    env=dict(self.env, AGENT_SANDBOX_SSH='0',
                             OPENAI_API_KEY='test-key-must-stay-on-host'),
                    capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = [json.loads(line) for line in self.log.read_text().splitlines()]
                run = next(c for c in calls if c[0] == 'run')
                self.assertFalse(any('OPENAI_API_KEY' in arg or
                                     'test-key-must-stay-on-host' in arg for arg in run))

    def test_entrypoint_uses_saved_auth_and_preserves_explicit_key_stdin(self):
        # Stand in for the real CLI and record every invocation, including stdin.
        cli = self.path / 'codex'
        cli.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['DOCKER_LOG'], 'a') as log:
    log.write(json.dumps({'args': sys.argv[1:],
                         'key_present': 'OPENAI_API_KEY' in os.environ,
                         'stdin': sys.stdin.read()}) + '\\n')
''')
        cli.chmod(0o755)
        for args, stdin in [((), ''), (('login',), ''),
                            (('login', '--with-api-key'), 'explicit-test-key\n'),
                            (('logout',), '')]:
            with self.subTest(args=args):
                self.log.unlink(missing_ok=True)
                result = subprocess.run(
                    ['bash', str(ROOT / 'entrypoint.sh'), 'codex', *args],
                    env=dict(self.env, OPENAI_API_KEY='inherited-test-key'),
                    input=stdin, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = [json.loads(line) for line in self.log.read_text().splitlines()]
                self.assertEqual(calls, [{'args': list(args), 'key_present': False,
                                         'stdin': stdin}])

    def test_installer_preserves_unrelated_legacy_file(self):
        bin_dir = self.path / '.local' / 'bin'
        bin_dir.mkdir(parents=True)
        legacy = bin_dir / 'sandbox-tools'
        legacy.write_text('#!/bin/bash\necho unrelated\n')
        result = subprocess.run(['bash', str(ROOT / 'install.sh')],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(legacy.read_text(), '#!/bin/bash\necho unrelated\n')

    def test_installer_refreshes_existing_wrappers_without_replacing_tools_image(self):
        bin_dir = self.path / '.local' / 'bin'
        bin_dir.mkdir(parents=True)
        for name in ('codex', 'claude', 'agent-sandbox'):
            (bin_dir / name).write_text('#!/bin/bash\n# agent-sandbox-managed-wrapper-v6\n')
        result = subprocess.run(['bash', str(ROOT / 'install.sh')],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ('codex', 'claude', 'agent-sandbox'):
            self.assertEqual((bin_dir / name).read_text(), (ROOT / 'launcher.sh').read_text())
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertFalse(any(c[:2] == ['image', 'tag'] for c in calls))


if __name__ == '__main__':
    unittest.main()
