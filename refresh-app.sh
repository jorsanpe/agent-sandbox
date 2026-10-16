#!/usr/bin/env bash
# Called by the installed launcher while it holds tools.lock.
set -euo pipefail
upgrade_dir=$1
bin_dir="$HOME/.local/bin"
die() { printf 'agent-sandbox: %s\n' "$*" >&2; exit 2; }
[[ -r $upgrade_dir/source-dir ]] || die 'Run install.sh once to register the source checkout for application upgrades.'
IFS= read -r source_dir < "$upgrade_dir/source-dir"
command -v git >/dev/null || die 'Git is required to update Agent Sandbox.'
[[ -d $source_dir ]] || die 'The source checkout has moved. Run install.sh from its new location.'
[[ $(git -C "$source_dir" rev-parse --show-toplevel) == "$source_dir" ]] || die 'The registered source is not a Git checkout root.'
[[ -z $(git -C "$source_dir" status --porcelain) ]] || die 'Source checkout has local changes. Commit or preserve them before upgrading.'
for agent in claude codex agent-sandbox; do
  target="$bin_dir/$agent"
  [[ -f $target && ! -L $target ]] || die "Expected a managed wrapper at $target. Run install.sh."
  grep -Eq '^# agent-sandbox-managed-wrapper-v[0-9]+$' "$target" || die "Refusing to replace an unmanaged wrapper: $target"
done
git -C "$source_dir" pull --ff-only
resources=(Dockerfile entrypoint.sh .dockerignore Upgrade.Dockerfile upgrade-image.sh upgrade.sh refresh-app.sh)
# Validate and stage everything before changing installed files. Retain backups
# until publication finishes so a failed copy/rename can restore the old app.
stage=$(mktemp -d "$upgrade_dir/.refresh-XXXXXX")
publishing=0
installed=()
cleanup() {
  status=$?
  if (( publishing )); then
    for target in "${installed[@]}"; do
      cp -p -- "$stage/backup/${target##*/}" "$target" || true
    done
  fi
  for agent in claude codex agent-sandbox; do
    rm -f -- "$bin_dir/.$agent.new"
  done
  rm -rf -- "$stage"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$stage/backup"
for resource in "${resources[@]}" launcher.sh; do
  [[ -f $source_dir/$resource ]] || die "Missing application file: $resource"
  if [[ $resource == *.sh ]]; then bash -n "$source_dir/$resource"; fi
  install -m 0644 "$source_dir/$resource" "$stage/$resource"
done
for resource in "${resources[@]}"; do
  cp -p -- "$upgrade_dir/$resource" "$stage/backup/$resource"
done
for agent in claude codex agent-sandbox; do
  cp -p -- "$bin_dir/$agent" "$stage/backup/$agent"
  install -m 0755 "$stage/launcher.sh" "$bin_dir/.$agent.new"
done
publishing=1
for resource in "${resources[@]}"; do
  installed+=("$upgrade_dir/$resource")
  mv -- "$stage/$resource" "$upgrade_dir/$resource"
done
for agent in claude codex agent-sandbox; do
  installed+=("$bin_dir/$agent")
  mv -- "$bin_dir/.$agent.new" "$bin_dir/$agent"
done
publishing=0
printf 'Agent Sandbox application refreshed from %s\n' "$source_dir"
