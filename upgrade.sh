#!/usr/bin/env bash
# Called by the installed launcher while it holds tools.lock.
set -euo pipefail
agent_uid=$1
agent_gid=$2
upgrade_dir=$3
image="agent-sandbox:dev-$agent_uid"
base="agent-sandbox:base-$agent_uid"
tools="agent-sandbox-tools-$agent_uid"
stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
target="agent-sandbox:upgrade-base-$agent_uid-$stamp"
candidate="agent-sandbox:upgrade-dev-$agent_uid-$stamp"
snapshot="agent-sandbox:upgrade-source-$agent_uid-$stamp"
backup="agent-sandbox:dev-$agent_uid-backup-$stamp"
die() { printf 'agent-sandbox: %s\n' "$*" >&2; exit 2; }
docker image inspect "$image" >/dev/null
has_tools=0
if docker container inspect "$tools" >/dev/null 2>&1; then
  [[ $(docker container inspect --format '{{index .Config.Labels "agent-sandbox.kind"}}' "$tools") == tools-v3 ]] || die "Container name already in use: $tools"
  [[ $(docker container inspect --format '{{.State.Running}}' "$tools") == false ]] || die 'Stop the active tools session before upgrading.'
  has_tools=1
fi
# Preserve the published image and all pending tool changes before building.
docker image tag "$image" "$backup"
if (( has_tools )); then
  docker commit --change 'USER node' --change 'WORKDIR /workspace' \
    --change 'ENTRYPOINT ["/usr/local/bin/agent-entrypoint"]' \
    --change 'CMD ["shell"]' "$tools" "$snapshot" >/dev/null
else
  docker image tag "$image" "$snapshot"
fi
printf 'Building full upgrade. Previous shared image: %s\n' "$backup"
docker build --pull --no-cache --build-arg "SANDBOX_UID=$agent_uid" \
  -t "$target" "$upgrade_dir"
docker build --no-cache -f "$upgrade_dir/Upgrade.Dockerfile" \
  --build-arg "TARGET_IMAGE=$target" --build-arg "CURRENT_IMAGE=$snapshot" \
  -t "$candidate" "$upgrade_dir"
docker run --rm --network none --read-only --user "$agent_uid:$agent_gid" \
  --cap-drop ALL --security-opt no-new-privileges:true \
  --tmpfs "/home/node:rw,nosuid,nodev,uid=$agent_uid,gid=$agent_gid" \
  --tmpfs /tmp:rw,exec,nosuid,nodev,size=1g,mode=1777 \
  --entrypoint /bin/bash "$candidate" -euc '
    node --version; npm --version; go version; python3 --version
    codex --version; claude --version; git --version; gcc --version
    python3 -m venv /tmp/check-venv
    /tmp/check-venv/bin/python -c "import ssl"
  '
has_base=0
if docker image inspect "$base" >/dev/null 2>&1; then
  docker image tag "$base" "agent-sandbox:base-$agent_uid-backup-$stamp"
  has_base=1
fi
publishing=1
renamed_tools=0
rollback_publication() {
  status=$?
  if (( publishing )); then
    docker image tag "$backup" "$image" || true
    if (( has_base )); then docker image tag "agent-sandbox:base-$agent_uid-backup-$stamp" "$base" || true; fi
    if (( renamed_tools )); then docker container rename "$tools-backup-$stamp" "$tools" || true; fi
  fi
  exit "$status"
}
trap rollback_publication EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Keep the old tools container for recovery; the next tools session creates one
# from the new image. Existing agent sessions and state volumes are untouched.
if (( has_tools )); then
  docker container rename "$tools" "$tools-backup-$stamp"
  renamed_tools=1
fi
docker image tag "$candidate" "$image"
docker image tag "$target" "$base"
publishing=0
printf 'Full upgrade saved. Restart agents to use it. Backup: %s\n' "$backup"
