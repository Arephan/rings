#!/usr/bin/env bash
set -uo pipefail
mkdir -p out
SRC="$RING_DIR/../scout/out/findings.md"
{
  echo "# report"
  echo
  if [ -s "$SRC" ]; then
    echo "Read from the scout ring:"
    echo
    sed 's/^/> /' "$SRC"
  else
    echo "The scout ring produced nothing, so there is nothing to report."
  fi
} > out/report.md
