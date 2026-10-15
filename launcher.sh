#!/usr/bin/env bash
# agent-sandbox-managed-wrapper-v3
set -euo pipefail

die() { printf 'agent-sandbox: %s\n' "$*" >&2; exit 2; }
agent=${0##*/}
case "$agent" in claude|codex|sandbox-tools) ;; *) die 'Run install.sh to install the wrappers.' ;; esac
command -v docker >/dev/null || die 'Docker is required.'
agent_uid=$(id -u)
agent_gid=$(id -g)
[[ $agent_uid != 0 ]] || die 'Run as your regular, non-root user.'
image="agent-sandbox:dev-$agent_uid"

if [[ $agent == sandbox-tools ]]; then
  command -v flock >/dev/null || die 'flock (util-linux) is required.'
  lock_dir="$HOME/.local/state/agent-sandbox"
  mkdir -p -- "$lock_dir"
  chmod 700 "$lock_dir"
  exec 9>"$lock_dir/tools.lock"
  flock -n 9 || die 'Another tool-installation or setup session is running.'
  tools_container="agent-sandbox-tools-$agent_uid"
  docker image inspect "$image" >/dev/null 2>&1 || die 'Run install.sh first.'
  if docker container inspect "$tools_container" >/dev/null 2>&1; then
    owner=$(docker container inspect --format '{{index .Config.Labels "agent-sandbox.kind"}}' "$tools_container")
    [[ $owner == tools-v3 ]] || die "Container name already in use: $tools_container"
  else
    # This trusted installer container has no project, home, socket, or state mounts.
    docker create --name "$tools_container" --label agent-sandbox.kind=tools-v3 \
      --init --user 0:0 --workdir /root --network bridge \
      --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
      --cap-add FSETID --cap-add SETUID --cap-add SETGID --cap-add SETFCAP \
      --security-opt no-new-privileges:true \
      --pids-limit 512 --memory 4g --memory-swap 4g --cpus 2 \
      --log-driver none --entrypoint /bin/sleep "$image" infinity >/dev/null
  fi
  cleanup_tools() { docker stop --time 5 "$tools_container" >/dev/null 2>&1 || true; }
  trap cleanup_tools EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  docker start "$tools_container" >/dev/null
  tool_args=(exec --interactive --user 0:0 --workdir /root
    --env HOME=/root --env GOBIN=/usr/local/bin --env NPM_CONFIG_PREFIX=/usr/local
    --env "TERM=${TERM:-xterm-256color}")
  if [[ -t 0 && -t 1 ]]; then tool_args+=(--tty); fi
  if (( $# == 0 )); then set -- bash; fi
  result=0
  docker "${tool_args[@]}" "$tools_container" "$@" || result=$?
  # Stop first so the snapshot excludes active processes and partial in-memory state.
  docker stop --time 5 "$tools_container" >/dev/null
  if (( result != 0 )); then
    printf 'Tool command failed (%s). Changes remain in the tools container but were not published.\n' "$result" >&2
    exit "$result"
  fi
  docker commit \
    --change 'USER node' \
    --change 'WORKDIR /workspace' \
    --change 'ENTRYPOINT ["/usr/local/bin/agent-entrypoint"]' \
    --change 'CMD ["shell"]' \
    "$tools_container" "$image" >/dev/null
  printf 'Tools saved. New claude and codex sessions will use them.\n' >&2
  exit 0
fi

# Original absolute paths keep per-project session histories distinct.
project=$(pwd -P)
host_home=$(cd -- "$HOME" && pwd -P)
case "$project" in
  /|/home|/Users|/root|/etc|/usr|/var|/run|/proc|/sys|/dev|/tmp|/opt|/mnt|/media)
    die 'Choose a project directory, not a broad system directory.' ;;
esac
[[ $project != "$host_home" ]] || die 'Refusing to mount your entire home directory. cd into a project first.'
case "$project" in
  *','*|*'"'*|*$'\n'*|*$'\r'*) die 'Project paths cannot contain commas, quotes, or newlines.' ;;
esac
[[ ! -f .git ]] || die 'Linked Git worktrees need external Git metadata. Use a standalone clone.'
state="agent-sandbox-$agent-$agent_uid"
docker volume inspect "$state" >/dev/null 2>&1 || die 'Persistent state volume is missing. Run install.sh first.'

args=(run --rm --init --interactive
  --read-only --user "$agent_uid:$agent_gid"
  --cap-drop ALL --security-opt no-new-privileges:true
  --pids-limit 512 --memory 4g --memory-swap 4g --cpus 2
  --ulimit nofile=4096:4096 --shm-size 128m
  --network bridge --log-driver none
  --workdir "$project"
  --mount "type=bind,src=$project,dst=$project,bind-recursive=disabled"
  --mount "type=volume,src=$state,dst=/home/node,volume-nocopy"
  --tmpfs /tmp:rw,exec,nosuid,nodev,size=1g,mode=1777
  --env "TERM=${TERM:-xterm-256color}"
)
if [[ -t 0 && -t 1 ]]; then args+=(--tty); fi
# Forward only the selected provider's key, by name rather than value.
case "$agent" in
  codex)
    if [[ -n ${OPENAI_API_KEY:-} ]]; then args+=(--env OPENAI_API_KEY); fi ;;
  claude)
    if [[ -n ${ANTHROPIC_API_KEY:-} ]]; then args+=(--env ANTHROPIC_API_KEY); fi ;;
esac
# Docker is the isolation boundary. Its hardened namespace/seccomp settings can
# prevent Codex's nested bubblewrap sandbox from starting even benign commands.
# Config overrides retain on-request approvals and can be explicitly overridden
# by later user CLI options. Do not apply them to auth/help/version operations.
cli_args=("$agent")
if [[ $agent == codex ]]; then
  case "${1:-}" in
    login|logout|help|--help|-h|--version|-V|completion) ;;
    *) cli_args+=(-c 'sandbox_mode="danger-full-access"' -c 'approval_policy="on-request"') ;;
  esac
fi
exec docker "${args[@]}" "$image" "${cli_args[@]}" "$@"
