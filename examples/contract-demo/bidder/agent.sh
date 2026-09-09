#!/usr/bin/env bash
set -uo pipefail
mkdir -p out
SRC="$RING_DIR/../scout/out/leads.jsonl"
{
  echo "# bids"
  echo
  if [ -s "$SRC" ]; then
    grep '"kind": "lead"' "$SRC" | sed 's/^/- /'
  else
    echo "scout produced nothing."
  fi
} > out/bids.md
