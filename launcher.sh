#!/usr/bin/env bash
# agent-sandbox-managed-wrapper-v8
set -euo pipefail

die() { printf 'agent-sandbox: %s\n' "$*" >&2; exit 2; }
agent=${0##*/}
case "$agent" in claude|codex|agent-sandbox) ;; *) die 'Run install.sh to install the wrappers.' ;; esac
command -v docker >/dev/null || die 'Docker is required.'
agent_uid=$(id -u)
agent_gid=$(id -g)
[[ $agent_uid != 0 ]] || die 'Run as your regular, non-root user.'
image="agent-sandbox:dev-$agent_uid"

if [[ $agent == agent-sandbox ]]; then
  case "${1:-}" in
    --help|-h)
      cat <<'EOF'
Usage: agent-sandbox [COMMAND [ARG...]]
       agent-sandbox upgrade [all|agents|system|npm]

With no command, open a shell to install shared tools.
Upgrade targets (default: all):
  agents  Install the latest Codex and Claude Code releases.
  system  Upgrade installed Debian packages from configured repositories.
  npm     Update global npm packages within their declared version ranges.
  all     Upgrade the base OS, Node.js and Go, system packages, npm tools, and agents.

The full upgrade uses the image definitions installed by install.sh.
Changes are saved to the shared image only after a successful command.
EOF
      exit 0
      ;;
    upgrade)
      (( $# <= 2 )) || die 'Usage: agent-sandbox upgrade [all|agents|system|npm]'
      upgrade_target=${2:-all}
      case "$upgrade_target" in all|agents|system|npm) ;; *) die "Unknown upgrade target: $upgrade_target" ;; esac
      if [[ $upgrade_target != all ]]; then
        set -- bash -euo pipefail -c '
        target=$1
        if [[ $target == all || $target == system ]]; then
          export DEBIAN_FRONTEND=noninteractive
          apt-get update
          apt-get -y upgrade
        fi
        if [[ $target == all || $target == npm ]]; then
          npm update --global
        fi
        if [[ $target == all || $target == agents ]]; then
          npm install --global --allow-scripts=@anthropic-ai/claude-code @openai/codex@latest @anthropic-ai/claude-code@latest
          { codex --version; claude --version; } > /opt/agent-versions.txt
        fi
      ' sandbox-upgrade "$upgrade_target"
      fi
      ;;
  esac
  command -v flock >/dev/null || die 'flock (util-linux) is required.'
  lock_dir="$HOME/.local/state/agent-sandbox"
  mkdir -p -- "$lock_dir"
  chmod 700 "$lock_dir"
  exec 9>"$lock_dir/tools.lock"
  flock -n 9 || die 'Another tool-installation or setup session is running.'
  if [[ ${upgrade_target:-} == all ]]; then
    upgrade_dir="$HOME/.local/share/agent-sandbox"
    [[ -f $upgrade_dir/upgrade.sh ]] || die 'Run the updated install.sh once to install full-upgrade support.'
    bash "$upgrade_dir/upgrade.sh" "$agent_uid" "$agent_gid" "$upgrade_dir"
    exit $?
  fi
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
    --change 'ENV HOME=/home/node' \
    --change 'ENV CODEX_HOME=/home/node/.codex' \
    --change 'USER node' \
    --change 'WORKDIR /workspace' \
    --change 'ENTRYPOINT ["/usr/local/bin/agent-entrypoint"]' \
    --change 'CMD ["shell"]' \
    "$tools_container" "$image" >/dev/null
  printf 'Tools saved. Exit and relaunch running agents to use them; your terminal can stay open.\n' >&2
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

# Browser OAuth listens on loopback inside the container. On Linux, sharing
# the host network for an explicit login makes that callback reachable by the
# host browser. Normal agent sessions keep their isolated bridge network.
network=bridge
if [[ $agent == codex && ${1:-} == login && ( $# == 1 || ${2:-} == -- ) ]]; then
  network=host
fi

args=(run --rm --init --interactive
  --read-only --user "$agent_uid:$agent_gid"
  --cap-drop ALL --security-opt no-new-privileges:true
  --pids-limit 512 --memory 4g --memory-swap 4g --cpus 2
  --ulimit nofile=4096:4096 --shm-size 128m
  --network "$network" --log-driver none
  --workdir "$project"
  --mount "type=bind,src=$project,dst=$project,bind-recursive=disabled"
  --mount "type=volume,src=$state,dst=/home/node,volume-nocopy"
  --tmpfs /tmp:rw,exec,nosuid,nodev,size=1g,mode=1777
  --env HOME=/home/node
  --env CODEX_HOME=/home/node/.codex
  --env "TERM=${TERM:-xterm-256color}"
)
if [[ -t 0 && -t 1 ]]; then args+=(--tty); fi
# Reuse the host's existing SSH agent. Only the socket and known_hosts file are
# exposed, never private-key files or the host's SSH config. A read-only socket
# mount still permits authentication requests and other agent protocol operations.
case "${AGENT_SANDBOX_SSH:-1}" in 0|1) ;; *) die 'AGENT_SANDBOX_SSH must be 0 or 1.' ;; esac
if [[ ${AGENT_SANDBOX_SSH:-1} == 1 && -n ${SSH_AUTH_SOCK:-} ]]; then
  [[ -S $SSH_AUTH_SOCK ]] || die 'SSH_AUTH_SOCK is not a socket. Refresh your SSH agent or set AGENT_SANDBOX_SSH=0.'
  ssh_socket=$(realpath -- "$SSH_AUTH_SOCK")
  case "$ssh_socket" in
    *','*|*'"'*|*$'\n'*|*$'\r'*) die 'SSH socket paths cannot contain commas, quotes, or newlines.' ;;
  esac
  args+=(--mount "type=bind,src=$ssh_socket,dst=/run/agent-sandbox/ssh-agent,readonly"
    --env SSH_AUTH_SOCK=/run/agent-sandbox/ssh-agent)
  known_hosts_in_container=/dev/null
  if [[ -f $HOME/.ssh/known_hosts ]]; then
    [[ -r $HOME/.ssh/known_hosts ]] || die 'Your known_hosts file is not readable.'
    known_hosts=$(realpath -- "$HOME/.ssh/known_hosts")
    case "$known_hosts" in
      *','*|*'"'*|*$'\n'*|*$'\r'*) die 'known_hosts paths cannot contain commas, quotes, or newlines.' ;;
    esac
    known_hosts_in_container=/run/agent-sandbox/known_hosts
    args+=(--mount "type=bind,src=$known_hosts,dst=$known_hosts_in_container,readonly")
  fi
  # Git reads this command directly; its paths/options are fixed container values.
  # Unknown hosts fail closed. Trust hosts on the host machine before launching.
  args+=(--env "GIT_SSH_COMMAND=ssh -F /dev/null -o IdentityAgent=/run/agent-sandbox/ssh-agent -o IdentityFile=none -o UserKnownHostsFile=$known_hosts_in_container -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=yes -o BatchMode=yes -o ForwardAgent=no")
fi
# Resolve identity on the host, including repository and conditional config.
# Forward only identity fields, never the host Git config (which may contain
# credentials, helpers, signing commands, or paths unavailable in the sandbox).
if command -v git >/dev/null; then
  git_name=$(git config --get user.name || true)
  git_email=$(git config --get user.email || true)
  for role in AUTHOR COMMITTER; do
    for field in NAME EMAIL; do
      identity_var="GIT_${role}_${field}"
      if [[ $field == NAME ]]; then identity_value=$git_name; else identity_value=$git_email; fi
      identity_value=${!identity_var:-$identity_value}
      if [[ -n $identity_value ]]; then args+=(--env "$identity_var=$identity_value"); fi
    done
  done
fi
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
