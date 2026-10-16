# Agent Sandbox

Run coding agents in sandboxed Docker environments. Agent Sandbox provides
`claude` and `codex` commands that start a separate container for each session,
with access to your current project directory and persistent agent settings.
Both agents share a development image, so tools installed once are available
to both.

## Installation

Requires Linux, Bash, `flock` (util-linux), Git, and a local Docker Engine
running and accessible to your regular user without `sudo`.

```bash
git clone https://github.com/jorsanpe/agent-sandbox.git
cd agent-sandbox
./install.sh
export PATH="$HOME/.local/bin:$PATH"
hash -r
```

Add the `export PATH` line to your `~/.bashrc` or `~/.zshrc`. The installer
creates `claude`, `codex`, and `agent-sandbox` wrappers in `~/.local/bin`.
Move any unrelated files already using those names aside before installing,
and remove shell aliases or functions that override the wrappers.

## Usage

Run an agent from the project directory you want it to work on:

```bash
cd ~/projects/my-project
codex
# Or:
claude
```

Arguments and piped input work as usual:

```bash
claude --resume
git diff | claude -p 'Review these changes'
```

### Codex login

From any directory in your host terminal, run:

```bash
codex login
```

Open the printed URL in your host browser. For this explicit browser login,
the Linux container uses host networking so the browser callback reaches
Codex. Login and logout do not mount your project or forward SSH.
Normal agent sessions use bridge networking. Credentials are saved in
the persistent state volume; upgrades do not require another login.

For a remote machine or an account that supports device authentication, use
`codex login --device-auth` instead. `codex login status` checks the saved login.
See the [official authentication guide](https://developers.openai.com/codex/auth).

The wrapper ignores your host's `OPENAI_API_KEY`, so you can leave it set for
other tools without changing your saved ChatGPT login. To explicitly select
API billing, pass the key through stdin:

```bash
printenv OPENAI_API_KEY | codex login --with-api-key
```

Credentials persist in Codex's Docker volume across sessions. Your host's
existing Codex login is not imported. Run `codex logout` to sign out.
If the old wrapper switched you to API billing, run `codex login` once after
installing the updated wrappers to restore your ChatGPT login.

### Finding previous Codex sessions

Run `codex resume --all` to include sessions recorded in other project paths.
The launcher pins `HOME=/home/node` and `CODEX_HOME=/home/node/.codex` to the
persistent `agent-sandbox-codex-<your UID>` volume, including after image upgrades.
The installer reuses that volume and never clears it.

Sessions and credentials from a host installation in `~/.codex` are separate
from sandbox state. If history disappears, keep both locations and the Docker
volumes intact while investigating; reinstalling does not import host history.
For first installation or shell command caching, run the PATH export and
`hash -r` above in your existing terminal. Neither requires a new terminal.

### Claude login

Claude prompts for login on its first launch. You can also export
`ANTHROPIC_API_KEY` on the host. Each agent's login, settings, and history
persist across sessions in its own Docker volume.

### Git commit identity

The launcher forwards your host Git `user.name` and `user.email` as author and
committer environment variables. Repository config and conditional includes
are resolved in the project before launching the container. Explicit host
`GIT_AUTHOR_*` and `GIT_COMMITTER_*` identity variables take precedence.
Only these identity values are forwarded; your host Git configuration stays
on the host. Each new session picks up changes automatically.

Configure your default identity on the host once if needed:

```bash
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
```

### Git over SSH

Git over SSH uses your host SSH agent when `SSH_AUTH_SOCK` is set. Load your
key with `ssh-add` and ensure the Git server is trusted in your host's
`~/.ssh/known_hosts` before starting a session. Private-key files stay on the
host; SSH config and aliases are not imported. Disable forwarding with:

```bash
AGENT_SANDBOX_SSH=0 codex
```

## Install new tools

Open the shared tools container from your host terminal:

```bash
agent-sandbox
```

Install packages as root inside that container, then exit successfully to save
them to the shared local image:

```bash
apt-get update
apt-get install -y jq
npm install -g pnpm
exit
```

You can also install a tool with a single command:

```bash
agent-sandbox npm install -g pnpm
```

New Claude and Codex sessions use the updated image; restart existing sessions
to pick up the tools. No Dockerfile changes or manual rebuilds are needed.
Use `/usr/local` or `/opt` for shared installations; npm's global prefix and
Go's `GOBIN` are already configured for shared executables.

If an installation fails, its changes remain in the tools container but are
not saved to the shared image. Run `agent-sandbox` again, fix the problem, and
exit successfully. Avoid entering credentials there: its filesystem becomes
part of the shared image. Project files and agent login volumes are not mounted
in this container.

## Upgrades

From any host directory, as your regular user:

```bash
agent-sandbox upgrade
```

Exit any open tools shell first. The command fast-forwards the Git checkout
registered at installation, refreshes the application and host wrappers, then
upgrades the tools image. Keep that checkout available and clean; local edits,
diverged history, or a failed pull stop the upgrade.

The full upgrade migrates Bookworm images to Trixie and updates Node, Go,
Debian packages, global npm tools, and both agents. Custom tools are carried
forward. The previous tools image and tools container are backed up; agent
login/settings volumes are preserved. Exit and relaunch running agents after
success. Your terminal window can stay open.

For smaller updates that leave the application and base runtimes unchanged:

```bash
agent-sandbox upgrade agents  # Latest Codex and Claude Code
agent-sandbox upgrade system  # Packages within the current Debian release
agent-sandbox upgrade npm     # Global npm packages within their version ranges
```

### One-time setup for older installations

If your installed launcher predates application self-updates, run this once
from your existing repository clone on the host:

```bash
git pull --ff-only
./install.sh
agent-sandbox upgrade
```

If you already installed the self-update version, use only
`agent-sandbox upgrade`. The PATH export and `hash -r` in the installation
instructions are needed when setting up command resolution, not on every upgrade.
If you move the source checkout, rerun `./install.sh` there to register its path.

See the [complete upgrade guide](UPGRADING.md) for verification, failure
recovery, image rollback, and custom definitions.

## Default tools

The default image is based on Debian 13 (Trixie) and includes:

| Tools | Purpose |
| --- | --- |
| OpenAI Codex and Claude Code | Coding agents, installed at their latest versions when the image is built |
| Node.js 24 LTS and npm | Run JavaScript and install Node.js packages |
| Go 1.27.2 | Build, test, and install Go programs |
| Python 3.13 and `venv` | Run Python and create isolated package environments |
| GCC 14, G++ 14, and Make (`build-essential`) | Compile C/C++ code and native dependencies |
| Git and OpenSSH client | Version control and SSH authentication |
| Bash | Shell scripts and interactive commands |
| ripgrep (`rg`) | Search project files quickly |
| curl and CA certificates | Download files and make HTTPS requests |
| procps (`ps`, `top`, etc.) | Inspect running processes |

Additional tools can be installed with `agent-sandbox` as described above.

## Sandbox scope

Agent containers run as your non-root UID/GID with a read-only root filesystem,
dropped Linux capabilities, and limits of 2 CPUs, 4 GiB RAM, and 512 processes.
Docker provides the sandbox boundary; the Codex wrapper disables its nested
sandbox and keeps approvals on request.

Agents can modify or delete files in the mounted project. Network access is
enabled, agent state is shared across that agent's projects, and a forwarded
SSH agent exposes its loaded identities. Your host home and Docker socket are
not mounted. Use standalone project clones; linked Git worktrees are unsupported.

## Development checks

To verify credential persistence with real Docker and Codex, using only dummy
credentials in temporary state (no account or network access):

```bash
AGENT_SANDBOX_TEST_IMAGE=agent-sandbox:dev-$(id -u) python3 -m unittest discover -s tests -v
```

The Docker test checks explicit login, a second container reading the saved
credentials, and logout. Browser OAuth still requires a manual check with your
account; the automated tests verify its network routing and argument handling.
