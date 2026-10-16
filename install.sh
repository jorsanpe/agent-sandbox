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

for agent in claude codex agent-sandbox; do
  target="$bin_dir/$agent"
  if [[ -e $target || -L $target ]]; then
    [[ ! -L $target && -f $target ]] || die "$target already exists; move it aside yourself first."
    grep -Eq '^# agent-sandbox-managed-wrapper-v[234567]$' "$target" || die "$target already exists; move it aside yourself first."
  fi
done

docker build --pull -t "$base_image" --build-arg "SANDBOX_UID=$agent_uid" "$@" "$source_dir"
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
upgrade_dir="$HOME/.local/share/agent-sandbox"
mkdir -p -- "$upgrade_dir"
for resource in Dockerfile entrypoint.sh .dockerignore Upgrade.Dockerfile upgrade-image.sh upgrade.sh; do
  install -m 0644 "$source_dir/$resource" "$upgrade_dir/$resource"
done
for agent in claude codex agent-sandbox; do
  install -m 0755 "$source_dir/launcher.sh" "$bin_dir/$agent"
done
# Remove only our old wrapper; leave unrelated files and symlinks untouched.
legacy_wrapper="$bin_dir/sandbox-tools"
if [[ -f $legacy_wrapper && ! -L $legacy_wrapper ]] &&
   grep -Eq '^# agent-sandbox-managed-wrapper-v[2345]$' "$legacy_wrapper"; then
  rm -- "$legacy_wrapper"
fi
# Existing shared images are preserved, so migrate required CLI dependencies
# through the persistent tools environment instead of replacing user installs.
dependency_status=0
docker run --rm --read-only --network none --cap-drop ALL \
  --security-opt no-new-privileges:true --user "$agent_uid:$agent_gid" \
  --entrypoint /bin/sh "$image" -c \
  'command -v ssh >/dev/null && command -v ps >/dev/null && getent passwd "$1" >/dev/null || exit 42' sh "$agent_uid" || dependency_status=$?
case "$dependency_status" in
  0) ;;
  42)
    flock -u 9
    exec 9>&-
    "$bin_dir/agent-sandbox" sh -c 'apt-get update && apt-get install -y --no-install-recommends openssh-client procps && if ! getent passwd "$1" >/dev/null; then usermod -u "$1" node; fi' sh "$agent_uid"
    ;;
  *) die "Could not check image dependencies (Docker exit $dependency_status)." ;;
esac
cat <<'EOF'
Installed ~/.local/bin/claude, codex, and agent-sandbox.

Run in your current terminal, and add the export line to ~/.bashrc (or ~/.zshrc):
  export PATH="$HOME/.local/bin:$PATH"
  hash -r

Then cd into a project and run claude or codex normally.
Go and Node/npm are included. Run agent-sandbox to install more tools;
exit that shell to save them for future sessions of both agents.
Run agent-sandbox upgrade to upgrade the base OS, Node, Go, packages, and agents.
For first-time Codex subscription login: codex login --device-auth
Claude prompts for login on its first interactive launch.
Your existing SSH agent is forwarded automatically when SSH_AUTH_SOCK is set.
Private keys stay on the host. Set AGENT_SANDBOX_SSH=0 to disable forwarding.
Remove aliases/functions named claude or codex so PATH wins.
EOF
