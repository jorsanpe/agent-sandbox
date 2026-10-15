#!/usr/bin/env bash
set -euo pipefail

die() { printf 'agent-sandbox: %s\n' "$*" >&2; exit 2; }
[[ $(uname -s) == Linux ]] || die 'This installer targets Linux.'
agent_uid=$(id -u)
agent_gid=$(id -g)
[[ $agent_uid != 0 ]] || die 'Run as your regular user, without sudo.'
command -v docker >/dev/null || die 'Install Docker and make it accessible to your user first.'
command -v flock >/dev/null || die 'flock (util-linux) is required.'
docker info >/dev/null || die 'Docker must be running and accessible without sudo.'
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
bin_dir="$HOME/.local/bin"
base_image="agent-sandbox:base-$agent_uid"
image="agent-sandbox:dev-$agent_uid"
lock_dir="$HOME/.local/state/agent-sandbox"
mkdir -p -- "$lock_dir"
chmod 700 "$lock_dir"
exec 9>"$lock_dir/tools.lock"
flock -n 9 || die 'Another tool-installation or setup session is running.'

for agent in claude codex sandbox-tools; do
  target="$bin_dir/$agent"
  if [[ -e $target || -L $target ]]; then
    [[ ! -L $target && -f $target ]] || die "$target already exists; move it aside yourself first."
    grep -Eq '^# agent-sandbox-managed-wrapper-v[23]$' "$target" || die "$target already exists; move it aside yourself first."
  fi
done

docker build --pull -t "$base_image" "$@" "$source_dir"
if docker image inspect "$image" >/dev/null 2>&1; then
  printf 'Keeping your existing shared tools image: %s\n' "$image"
else
  docker image tag "$base_image" "$image"
fi
for agent in claude codex; do
  state="agent-sandbox-$agent-$agent_uid"
  docker volume create "$state" >/dev/null
  # Offline initialization helper: no project/host bind mounts, only state.
  docker run --rm --network none --read-only --user 0:0 \
    --cap-drop ALL --cap-add CHOWN --cap-add FOWNER \
    --security-opt no-new-privileges:true \
    --mount "type=volume,src=$state,dst=/state,volume-nocopy" \
    --entrypoint /bin/sh "$image" -c \
    'chown "$1:$2" /state && chmod 700 /state' sh "$agent_uid" "$agent_gid"
done
mkdir -p -- "$bin_dir"
for agent in claude codex sandbox-tools; do
  install -m 0755 "$source_dir/launcher.sh" "$bin_dir/$agent"
done
cat <<'EOF'
Installed ~/.local/bin/claude, codex, and sandbox-tools.

Run in your current terminal, and add the export line to ~/.bashrc (or ~/.zshrc):
  export PATH="$HOME/.local/bin:$PATH"
  hash -r

Then cd into a project and run claude or codex normally.
Go and Node/npm are included. Run sandbox-tools to install more tools;
exit that shell to save them for future sessions of both agents.
For first-time Codex subscription login: codex login --device-auth
Claude prompts for login on its first interactive launch.
Remove aliases/functions named claude or codex so PATH wins.
EOF
