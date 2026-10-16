#!/usr/bin/env bash
set -euo pipefail

die() { printf 'agent-sandbox: %s\n' "$*" >&2; exit 2; }
case "${1:-}" in
  --help|-h)
    cat <<'HELP'
Usage: ./uninstall.sh

Remove Agent Sandbox's managed commands and installed support files.
Docker images, containers, and state volumes are retained, including sessions,
credentials, and custom tools. The source checkout and shell configuration are
also retained. Run install.sh again to reinstall using the saved state.
Close agent sessions and the tools shell before uninstalling.
HELP
    exit 0 ;;
esac
(( $# == 0 )) || die 'Usage: ./uninstall.sh'
[[ $(id -u) != 0 ]] || die 'Run as your regular user, without sudo.'
command -v flock >/dev/null || die 'flock (util-linux) is required.'
lock_dir="$HOME/.local/state/agent-sandbox"
mkdir -p -- "$lock_dir"
chmod 700 "$lock_dir"
exec 9>"$lock_dir/tools.lock"
flock -n 9 || die 'Another tool-installation, upgrade, or setup session is running.'

bin_dir="$HOME/.local/bin"
upgrade_dir="$HOME/.local/share/agent-sandbox"
[[ ! -L $upgrade_dir ]] || die 'Refusing to remove support files through a symlink.'
for agent in claude codex agent-sandbox sandbox-tools codex-sandbox; do
  target="$bin_dir/$agent"
  if [[ -f $target && ! -L $target ]] &&
     grep -Eq '^# agent-sandbox-managed-wrapper-v[0-9]+$' "$target"; then
    rm -- "$target"
  elif [[ -e $target || -L $target ]]; then
    printf 'Keeping unrelated command: %s\n' "$target"
  fi
done
for resource in Dockerfile entrypoint.sh .dockerignore Upgrade.Dockerfile upgrade-image.sh upgrade.sh refresh-app.sh source-dir; do
  target="$upgrade_dir/$resource"
  if [[ -f $target || -L $target ]]; then rm -- "$target"; fi
done
if [[ -d $upgrade_dir ]]; then
  rmdir -- "$upgrade_dir" 2>/dev/null || printf 'Keeping additional files in %s\n' "$upgrade_dir"
fi
# Keep the lock file in place: deleting a locked inode permits a competing
# installer to acquire a different lock at the same path.
printf '%s\n' \
  'Agent Sandbox commands and support files removed.' \
  'Docker resources, sessions, credentials, custom tools, and source checkout retained.' \
  'Run hash -r in your current shell to clear cached command paths.'
