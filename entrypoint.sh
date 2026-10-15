#!/usr/bin/env bash
set -euo pipefail
umask 077

agent=${1:-shell}
if (( $# )); then shift; fi
case "$agent" in
  codex)
    case "${1:-}" in
      login|logout|help|--help|-h|--version|-V|completion) ;;
      *)
        if [[ -n ${OPENAI_API_KEY:-} ]]; then
          printenv OPENAI_API_KEY | codex login --with-api-key >/dev/null
          unset OPENAI_API_KEY
        fi ;;
    esac
    exec codex "$@"
    ;;
  claude) exec claude "$@" ;;
  shell) exec bash "$@" ;;
  *) printf 'Unknown agent: %s\n' "$agent" >&2; exit 2 ;;
esac
