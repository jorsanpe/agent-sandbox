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

From your host terminal, inside a project directory, sign in with your ChatGPT
account using device authentication:

```bash
codex login --device-auth
```

Open the URL printed in the terminal in your host browser, sign in, and enter
the one-time code. Wait for the terminal to confirm success, then run:

```bash
codex login status
codex
```

If device login is disabled, enable it in your ChatGPT security settings or
ask your workspace administrator to enable it. Use device authentication for
this setup: plain `codex login` uses a localhost browser callback, and the
container does not publish that port to the host.

Alternatively, export `OPENAI_API_KEY` in your host shell and launch `codex`;
the wrapper logs in with that key for API billing. Unset it before using
ChatGPT login so the wrapper does not switch back to API-key authentication.
See the [official Codex authentication guide](https://developers.openai.com/codex/auth).

Credentials persist in Codex's Docker volume across sessions. Your host's
existing Codex login is not imported. Run `codex logout` to sign out; if you
exported `OPENAI_API_KEY`, also unset it to prevent automatic login.

### Claude login

Claude prompts for login on its first launch. You can also export
`ANTHROPIC_API_KEY` on the host. Each agent's login, settings, and history
persist across sessions in its own Docker volume.

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

## Upgrade installed tools

Run from your host terminal to upgrade Debian packages, global npm tools, and
both coding agents in the shared image:

```bash
agent-sandbox upgrade
```

You can also upgrade a specific group:

```bash
agent-sandbox upgrade agents  # Latest Codex and Claude Code releases
agent-sandbox upgrade system  # Installed Debian packages
agent-sandbox upgrade npm     # Global npm packages within their version ranges
```

Custom tools are preserved. Successful upgrades are saved for new sessions;
restart running agents to use them. Failed upgrades remain in the tools
container for repair and are not published to the shared image.

System upgrades use the configured Debian repositories; they do not switch
Debian releases. Node.js and Go are copied from upstream images and are not
updated by this command. Upgrade those runtimes manually in `agent-sandbox`
using their installation instructions. For a fresh installation, select their
image versions with `./install.sh --build-arg BASE_IMAGE=node:22-bookworm-slim
--build-arg GO_IMAGE=golang:1.27.2-bookworm`. Rebuilding the starting image does
not replace an existing shared tools image.

Rerun `./install.sh` after updating this repository to refresh the wrappers.
Existing tools and agent state are preserved.
This also replaces the former `sandbox-tools` command with `agent-sandbox`.

## Default tools

The default image is based on Debian Bookworm and includes:

| Tools | Purpose |
| --- | --- |
| OpenAI Codex and Claude Code | Coding agents, installed at their latest versions when the image is built |
| Node.js 22 and npm | Run JavaScript and install Node.js packages |
| Go 1.27.2 | Build, test, and install Go programs |
| Python 3 and `venv` | Run Python and create isolated package environments |
| GCC, G++, and Make (`build-essential`) | Compile C/C++ code and native dependencies |
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
