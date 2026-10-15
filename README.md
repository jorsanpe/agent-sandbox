# Shared tools, isolated project sessions

`claude` and `codex` use one shared development image. Each invocation starts a
separate container mounting only the current host directory. Install tools once
with `sandbox-tools`; both agents use them in future sessions. Go, Node/npm,
Python/venv, Git, ripgrep, curl, and C/C++ build tools are included.

## Install once (Linux)

Requires Bash, `flock` (util-linux), and a current local Docker Engine accessible
to your regular user without sudo. Do not use a remote Docker context.

```bash
./install.sh
export PATH="$HOME/.local/bin:$PATH"
hash -r
```

Add the export line to `~/.bashrc` (or `~/.zshrc`). Remove any `claude`/`codex`
aliases or functions that override PATH. `type -a claude codex sandbox-tools`
should show the wrappers in `~/.local/bin` first. The installer refuses to
overwrite unrelated files there; move an existing native CLI aside first.
It upgrades the earlier wrappers from this bundle and retains their login volumes.

Then use your normal commands:

```bash
cd ~/projects/my-project
claude
claude --resume
git diff | claude -p 'Review these changes'
codex
```

Claude prompts for login on first interactive use. For Codex subscription login,
run `codex login --device-auth` once from a project directory; finish in your
host browser. Device auth must be enabled for your account. Alternatively,
export `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` on the host for API billing.
Only the matching agent's key is forwarded. Codex saves its key through CLI
login in its persistent home. Host logins/settings are not imported automatically.

## Git over SSH

When your host shell has `SSH_AUTH_SOCK` set, the wrappers automatically forward
that agent socket to Claude/Codex sessions. Git uses the keys already loaded in
the agent. Private-key files and your host `~/.ssh/config` are never mounted.
If no SSH agent is running, coding sessions still work, but SSH authentication
is not provided. Load your usual key on the host with `ssh-add` if needed.

Your existing `~/.ssh/known_hosts` file is mounted read-only when present. Git is
configured to require a matching trusted host key: unknown or changed hosts
fail rather than prompting or being accepted automatically. First verify/trust
the Git server on your host, then launch a new agent session. For GitHub, compare
the host fingerprint with [GitHub's published fingerprints](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints).
No `ssh-keyscan` output is automatically trusted. No known_hosts file is also
allowed at launch, but SSH Git operations fail until trust has been configured.

Disable forwarding for one session with `AGENT_SANDBOX_SSH=0 codex` (or `claude`),
or export that setting in your shell to disable it by default. When enabled,
Git's `GIT_SSH_COMMAND` selects the forwarded agent and mounted known_hosts;
host SSH aliases, ProxyJump rules, and IdentityFile settings are not imported.
These settings apply to Git's SSH transport; arbitrary direct `ssh` invocations
need their own host-key options. Use `git ls-remote origin` inside an agent
session to check authentication without pushing changes.

Forwarding gives the session access to every identity loaded in that agent.
Code can request authentication/signatures and interact with the agent protocol
while connected; a read-only socket mount does not restrict those operations.
This is not a repository permission boundary. A dedicated agent with only the
intended Git key is optional if you want a narrower scope. Avoid running
untrusted code with a forwarded agent. Tools-installation sessions never get
this socket or the known_hosts mount, even when forwarding is enabled.

For an existing installation, rerun `./install.sh` from the updated bundle.
It preserves installed tools and CLI state, adds `openssh-client`/`procps` if
missing, and ensures the runtime UID has a passwd entry needed by OpenSSH.
You do not need to copy keys, recreate volumes, or reauthenticate the CLIs.

## Install tools without rebuilding

Open the shared installation environment:

```bash
sandbox-tools
```

You are root **inside the tools container**. For example:

```bash
apt-get update
apt-get install -y jq
npm install -g pnpm
exit
```

On successful exit, the wrapper stops the installation container and saves its
filesystem as the shared local image. Newly launched `claude` and `codex`
containers get those tools. Existing sessions continue using their earlier
image until you restart them. No Dockerfile editing or image build is needed.

You can also run a single command, for example `sandbox-tools npm install -g pnpm`.
The wrapper sets `GOBIN=/usr/local/bin` and `NPM_CONFIG_PREFIX=/usr/local` in the
installation shell, so `go install package@version` and `npm install -g` produce
shared executables. Other installers should use `/usr/local` or `/opt` with an
appropriate global PATH setting, rather than root's private home.

The persistent installation container retains changes even if a command fails.
A failing command is not published to the shared image. Fix it in a subsequent
`sandbox-tools` session and exit successfully to publish the resulting state.
Finish package installation before exiting; do not leave installers running
in the background. The wrapper permits only one installation/setup session at
a time. Snapshots may take a little time and consume disk space.

Do not log into the coding agents or enter private tokens in `sandbox-tools`:
its filesystem, including root's history/configuration, becomes the shared image.
Normal agent credentials and project files are never mounted there or forwarded
to it. Images remain local; nothing is pushed to a registry.

Project dependencies still install normally inside agent sessions. Tools installed
in an agent's persistent home stay specific to that agent; use `sandbox-tools`
for tools you want to share. System-wide installs in ordinary agent sessions are
blocked, so an agent cannot silently change the shared development image.

## How storage is divided

| Data | Location and lifetime |
| --- | --- |
| Shared tools | Local `agent-sandbox:dev-<uid>` image and persistent `agent-sandbox-tools-<uid>` installation container |
| Fresh starting image | `agent-sandbox:base-<uid>` |
| Claude login/settings/history | Docker volume `agent-sandbox-claude-<uid>` |
| Codex login/settings/history | Docker volume `agent-sandbox-codex-<uid>` |
| Project | Only the current directory, bind-mounted at the same absolute path |
| Temporary session files | Disposable container and `/tmp` |

Separate CLI state volumes do not duplicate the installed development toolchain.
Docker reuses image layers across sessions. The root installation filesystem and
one shared snapshot are retained; snapshots are not zero-storage operations.
Neither state volumes, project directories, nor image snapshots have disk quotas.

Arguments and piped stdin are forwarded literally; interactive sessions get a
TTY. `exec docker run` preserves Docker signal handling and the CLI exit status
when startup succeeds. Project paths are canonicalized so histories remain tied
to stable absolute paths. Simultaneous sessions have separate containers; they
still share their agent's state and any explicitly shared project directory.

## Isolation boundaries

Agent sessions run with your non-root UID/GID, a read-only root filesystem,
all Linux capabilities dropped, no privilege escalation, and default Docker
seccomp. Limits are 2 CPUs, 4 GiB RAM without swap, and 512 processes. No host
home, Docker socket, host namespaces, or published ports are provided. SSH-agent
access is the explicit file/socket exception described above and can be disabled.
Codex uses `sandbox_mode="danger-full-access"` with
`approval_policy="on-request"`: Docker supplies the isolation boundary, so Codex
does not attempt to start an incompatible nested bubblewrap sandbox. This removes
Codex's additional filesystem/network sandbox inside the container, including
restrictions on access to its credentials and state. It does not grant host
access or change Docker's restrictions. Claude's permission defaults are unchanged.

The root installation container is a different trust level. It has a writable
filesystem and selected capabilities for package management, but no host/project
bind mounts, credential volumes, Docker socket, or forwarded API keys. Only you
launch it from the host. A separate offline initialization helper sets ownership
on state volumes during setup. Agent sessions get neither helper's capabilities.

Only the current host directory is mounted as a directory. SSH forwarding also
mounts the exact agent socket and known_hosts file; no entire SSH directory is
exposed. Parent/sibling projects remain inaccessible by path; nested mounts are
excluded. Broad system
directories and the entire host home are rejected. Linked Git worktrees are
rejected because their external Git metadata would require an additional mount.
Use standalone clones without secrets, host sockets, or hard links to sensitive
files. Agents can modify/delete everything in their mounted project.

Persistent CLI state intentionally includes prior histories, caches, credentials,
and settings. It is shared across projects for that CLI, so project filesystem
isolation is not complete information isolation: a malicious project could read
stored history or credentials and poison settings for later sessions.

Network egress is unrestricted, including reachable host/LAN services and other
containers. This setup does not prevent exfiltration. Enforce network policy
externally if required. Containers share the Docker host's kernel; use a dedicated
VM for hostile code. Rootless Docker or user namespaces may need adjusted UID
mapping; the defaults assume ordinary local Docker bind-mount semantics.

Host executables, external `--add-dir` targets, external local MCPs, browser
launching, enterprise/proxy environment variables, and development-server ports
are not made available automatically. Add only the specific access you need.
The Codex wrapper supplies its container-compatible policy as command-line config
defaults. Explicit user CLI options can override these defaults. If you re-enable
Codex's nested sandbox, namespace restrictions may prevent it from starting.

For an older wrapper that reports `bwrap: No permissions to create a new namespace`,
restart with `codex --sandbox danger-full-access --ask-for-approval on-request`.
To install this wrapper-only fix without rebuilding, run from this bundle:
`install -m 0755 launcher.sh "$HOME/.local/bin/codex"`.

## Updates

Rerunning `install.sh` updates host wrappers and builds the starting image,
preserving an existing tools environment and upgrading missing SSH/process
dependencies and UID lookup support through `sandbox-tools`. Rebuilding
the starting image alone does not replace your installed environment. Update
tools through `sandbox-tools`, e.g. `npm install -g @openai/codex
@anthropic-ai/claude-code`, or use Debian's package manager in that shell.

The initial Dockerfile supports `BASE_IMAGE`, `GO_IMAGE`, `CODEX_VERSION`, and
`CLAUDE_VERSION` build arguments. Defaults resolve some packages at build time;
this is not a fully reproducible locked build. `/opt/agent-versions.txt` records
initial CLI versions only; use CLI version commands for subsequent installs.
Do not delete the installation container or shared image unless you intend to
reset the development environment. Do not run Docker pruning with unneeded
volumes/containers selected if you want this state preserved.

## Validation

Shell syntax and mocked Docker tests cover setup, preservation of existing state,
argument/stdin forwarding, exit codes, directory isolation, credential separation,
the tools-container lifecycle, snapshot configuration, lock contention, and
failure handling. Docker is unavailable in the authoring environment: image
builds, actual package installation, login, terminal signals, and kernel isolation
have not been verified on a running Docker engine.

SSH-specific checks use simulated socket-type checks and mocked Docker calls to
verify forwarding/opt-out branches, exact read-only mounts, strict Git host-key
settings, no forwarding to the tools container, and upgrade handling. Real SSH
options are checked with `ssh -G` without connecting. This environment prohibits
creating Unix sockets, so live socket forwarding remains untested. No real SSH
agent, private keys, or remote Git service is used in these checks.

## Official references

- [Codex CLI/login](https://developers.openai.com/codex/cli/reference)
- [Claude development containers](https://code.claude.com/docs/en/devcontainer)
- [Docker image snapshots](https://docs.docker.com/reference/cli/docker/container/commit/)
- [Docker Engine security](https://docs.docker.com/engine/security/)
