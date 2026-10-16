# Upgrading an existing installation

Run these commands in a host terminal as the regular user who installed Agent
Sandbox, with Docker accessible without `sudo`. Do not run them from inside an
agent session or the tools shell.

## First upgrade from an older installation

Exit any open `agent-sandbox` tools shell. You may leave Claude and Codex sessions
running, but they keep their existing image until restarted.

In your existing clone of this repository:

```bash
git pull --ff-only
./install.sh
export PATH="$HOME/.local/bin:$PATH"
hash -r
agent-sandbox upgrade
```

If you have local repository edits, commit or otherwise preserve them before
pulling. `install.sh` refreshes the three managed wrappers and copies the image
and upgrade definitions to `~/.local/share/agent-sandbox`. It builds the starting
image but preserves your existing shared tools image and agent volumes. **The
following `agent-sandbox upgrade` command migrates the existing tools environment.**

Older wrappers already had an `upgrade` command, but it did not upgrade Node, Go,
or the Debian release. Rerunning the updated installer once is required to enable
application self-updates and the full upgrade described here. The installer also migrates the old
`sandbox-tools` wrapper name to `agent-sandbox`.

The full upgrade downloads upstream images and packages, builds a candidate,
and runs checks. Allow time and disk space for both the candidate and backups.
No registry push is performed.

## Routine upgrades

From any host directory:

```bash
agent-sandbox upgrade
# Equivalent:
agent-sandbox upgrade all
```

The full upgrade first runs `git pull --ff-only` in the source checkout recorded
by the installer. It validates and refreshes the host wrappers, entrypoint, and
upgrade definitions, then builds the upgraded tools image. No separate pull or
installer run is needed for routine upgrades. Keep the source checkout available.
If you move it, rerun `install.sh` from its new location to register that path.

Local checkout changes and diverged history stop the upgrade without overwriting
your work. A fetch, validation, or application refresh failure prevents the image
upgrade from starting. If the application refresh succeeds but the later image
build fails, the refreshed application remains installed and the previous tools
image remains available. Retry the same command after resolving the build error.

For smaller updates:

| Command | What it updates |
| --- | --- |
| `agent-sandbox upgrade` | Application, host wrappers, base OS, Node, npm, Go, Debian packages, global npm packages, Codex, and Claude Code |
| `agent-sandbox upgrade agents` | Codex and Claude Code to their latest npm releases |
| `agent-sandbox upgrade system` | Debian packages within the current Debian release |
| `agent-sandbox upgrade npm` | Global npm packages within their declared version ranges |

The smaller updates do not refresh the application, replace Node or Go, or change Debian releases. They
use the existing tools container; failed commands leave changes there for repair,
without publishing them to agent sessions.

## Versions and preserved data

The current full upgrade migrates Debian 12 Bookworm to Debian 13 Trixie and
applies Node 24 LTS and Go 1.27.2. Python moves to Debian's 3.13 series, and the
default C/C++ compilers move to GCC 14. Existing Trixie images can also be
upgraded. Other base distributions are not supported by this migration.

The full upgrade starts from your existing tools filesystem, using the stopped
tools container when one exists, including pending changes from failed tool
commands. Otherwise, it uses the shared image. It then:

1. Saves the currently published image under a timestamped backup tag and creates
   a separate snapshot of the migration source.
2. Builds the current base definitions with fresh upstream images and uncached
   package installation layers.
3. Upgrades Debian packages in a disposable build and installs the current default
   packages. For Bookworm, it replaces the standard Debian apt sources with Trixie
   sources and supplies the target image's archive verification keys.
4. Replaces the managed Node executable, npm directory, Go directory, and agent
   entrypoint. It updates global npm packages and agents and rebuilds native npm
   dependencies for the new Node version.
5. Checks that manually installed Debian packages remain installed and verifies
   that the runtimes, agents, and a Python virtual environment work as a non-root
   user with a read-only root filesystem.
6. Publishes the candidate for new sessions and archives the old tools container.
   Future tools sessions start from the upgraded shared image.

Custom Debian and global npm packages and other files in `/usr/local` and `/opt`
are carried forward. The managed paths named above are replaced completely;
avoid installing custom files inside the Go or npm installation directories.
Independently downloaded binaries, `go install` executables, project dependencies,
and project virtual environments may require their own updates. The command does
not update arbitrary tools installed by other package managers.

If a Debian migration removes a manually installed package, or any build/check
fails, the candidate is not published. Third-party apt repositories and pinned
packages may need adjustment for Trixie before the migration can succeed.

Your mounted projects, SSH files, and agent login/settings volumes are not part
of the upgrade build. Existing agent containers continue using their old image.
Restart them after a successful upgrade to use the new tools.

The full upgrade takes the same lock as tool installation and setup, so these
operations cannot run concurrently. It refuses to snapshot a running tools
container.

## Verify the result

After the success message, restart your agent sessions. Check the agent versions
from your host terminal:

```bash
codex --version
claude --version
```

To inspect the shared toolchain without opening a tools session:

```bash
docker run --rm --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --entrypoint /bin/bash "agent-sandbox:dev-$(id -u)" -euc \
  'cat /etc/os-release; node --version; npm --version; go version; python3 --version; git --version; gcc --version'
```

## Recover from a failed upgrade

Read the first package, repository, build, or smoke-check error in the output.
The full upgrade leaves the published shared image and original tools container
available. You can keep using agents on that image.

For a transient network failure, rerun `agent-sandbox upgrade`. If a custom apt
repository or package blocks migration, open `agent-sandbox`, repair its
configuration, and exit successfully to save the repair. Then retry the full
upgrade. Do not disable apt signature verification to work around archive-key
errors.

For a failed `agents`, `system`, or `npm` update, reopen `agent-sandbox` to repair
the pending changes, then exit successfully. The full upgrade also includes those
pending changes in its source snapshot, so repair broken package state first.

If npm reports blocked installation scripts for a custom package, review those
packages and configure the approved names in the tools environment, then retry.
For example, for a trusted package named `sharp`:

```bash
agent-sandbox npm config set allow-scripts=sharp --location=user
agent-sandbox upgrade
```

Use a comma-separated list when approving multiple packages; `npm config set`
replaces the previous list. The full upgrade adds Claude Code's required installer
to the existing approvals for its update/rebuild commands. It fails on other
unapproved scripts rather than silently publishing incomplete native dependencies.

## Roll back a successful full upgrade

The success output prints the previous shared image tag:

```text
agent-sandbox:dev-<UID>-backup-<TIMESTAMP>-<PID>
```

List available backups:

```bash
docker image ls --filter "reference=agent-sandbox:dev-$(id -u)-backup-*"
docker container ls -a --filter "name=agent-sandbox-tools-$(id -u)-backup-"
```

Exit all tools shells before rollback. Set `sandbox_backup_suffix` below to the
part after `-backup-` in the chosen image tag. Run the block in Bash. It takes
the tools lock, preserves the current shared image and tools container under new
names, restores the selected shared image, and restores its tools container if
that backup exists:

```bash
sandbox_backup_suffix='PASTE_TIMESTAMP_AND_PID_HERE'
(
  set -euo pipefail
  sandbox_uid=$(id -u)
  sandbox_image="agent-sandbox:dev-$sandbox_uid"
  sandbox_tools="agent-sandbox-tools-$sandbox_uid"
  sandbox_backup="$sandbox_image-backup-$sandbox_backup_suffix"
  sandbox_archive="rollback-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  exec 9>"$HOME/.local/state/agent-sandbox/tools.lock"
  flock -n 9 || { echo 'Another setup/tools operation is running.' >&2; exit 1; }
  docker image inspect "$sandbox_backup" >/dev/null
  if docker container inspect "$sandbox_tools" >/dev/null 2>&1; then
    test "$(docker container inspect --format '{{.State.Running}}' "$sandbox_tools")" = false
    test "$(docker container inspect --format '{{index .Config.Labels "agent-sandbox.kind"}}' "$sandbox_tools")" = tools-v3
    docker container rename "$sandbox_tools" "$sandbox_tools-$sandbox_archive"
  fi
  docker image tag "$sandbox_image" "$sandbox_image-$sandbox_archive"
  docker image tag "$sandbox_backup" "$sandbox_image"
  if docker container inspect "$sandbox_tools-backup-$sandbox_backup_suffix" >/dev/null 2>&1; then
    docker container rename "$sandbox_tools-backup-$sandbox_backup_suffix" "$sandbox_tools"
  fi
)
```

Restart agent sessions after rollback. This restores the shared environment;
it does not undo changes agents have already made to projects or their settings
volumes. The starting `base` image can remain newer: normal sessions use `dev`,
and a future full upgrade rebuilds the base definitions.

Backup images and containers remain on your PC until you remove them. Keep them
until you have verified the upgraded environment and any custom tools you rely on.

## Custom base definitions

The full upgrade reads `~/.local/share/agent-sandbox/Dockerfile`,
`Upgrade.Dockerfile`, and their support files. The installed defaults match the
repository at the last installation or full upgrade. Build-arg overrides passed to the
installer affect that initial build only; they are not persisted for later full
upgrades. If you customize the installed definitions, keep a separate copy:
installation and full upgrades replace these managed files. Keep customized definitions in your source checkout and manage their Git history explicitly.

Changing to another distribution or Debian release requires a matching migration
in `upgrade-image.sh`; changing only the Dockerfile is insufficient.
