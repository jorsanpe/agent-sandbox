#!/usr/bin/env bash
set -euo pipefail
umask 077

agent=${1:-shell}
if (( $# )); then shift; fi
case "$agent" in
  codex)
    # Use saved credentials. API-key login is an explicit stdin operation;
    # inherited environment variables must not change the selected account.
    unset OPENAI_API_KEY
    exec codex "$@"
    ;;
  claude) exec claude "$@" ;;
  shell) exec bash "$@" ;;
  *) printf 'Unknown agent: %s\n' "$agent" >&2; exit 2 ;;
esac
