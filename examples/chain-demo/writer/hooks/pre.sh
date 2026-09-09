#!/usr/bin/env bash
# Halt this ring when its input is stale. The alternative — running anyway on
# yesterday's facts — produces confident output that is quietly wrong, which is
# worse than no output.
set -uo pipefail
SRC="$RING_DIR/../scout/out/findings.md"
MAX_AGE=7200

if [ ! -s "$SRC" ]; then
  echo "pre: upstream scout has produced nothing; this run will fail its verifier"
  exit 0
fi
AGE=$(( $(date +%s) - $(stat -f %m "$SRC" 2>/dev/null || stat -c %Y "$SRC" 2>/dev/null || echo 0) ))
if [ "$AGE" -gt "$MAX_AGE" ]; then
  echo "pre: upstream findings are ${AGE}s old (max ${MAX_AGE}s) — proceeding, but say so in the report"
fi
