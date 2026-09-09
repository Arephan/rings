#!/usr/bin/env bash
# Stands in for `claude -p`. Receives the composed prompt as $1 and must write
# the deliverable, exactly like a real agent would.
set -uo pipefail
mkdir -p out
{
  echo "# hello-ring"
  echo
  echo "Ran at $(date -u +%FT%TZ). The prompt I was handed was $(printf '%s' "$1" | wc -w | tr -d ' ') words long."
  echo
  echo "A real agent would have read something, done something, and written the"
  echo "result here. This deliverable exists only to prove the verifier fires."
} > out/last.md
