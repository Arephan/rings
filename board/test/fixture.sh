#!/usr/bin/env bash
# board/test/fixture.sh <empty|demo|stress> <dir> — build a RINGS_HOME to point the board at.
#
# One-shot: <dir> is deleted and rebuilt from nothing, so a rerun cannot inherit
# yesterday's spool. Point it somewhere disposable.
#
#   empty   nothing at all: every view renders its empty state.
#   demo    the handoff demo, run once end to end: one item through the chain.
#   stress  120 prospects, a backed-up inbox, a halted ring and a ring that
#           subscribes to a type nobody emits: wide tables, long ids, findings.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
kind="${1:-}"; dir="${2:-}"
[ -n "$kind" ] && [ -n "$dir" ] || { echo "usage: fixture.sh <empty|demo|stress> <dir>" >&2; exit 2; }
rm -rf "$dir"
mkdir -p "$dir"
export RINGS_HOME="$dir"

case "$kind" in
  empty) ;;
  demo)
    # The onboarding path itself, so a screenshot shows what a first run shows.
    "$ROOT/bin/rings" demo > /dev/null ;;
  stress)
    cp -R "$ROOT/examples/handoff-demo/." "$dir/"
    for i in $(seq 1 120); do
      printf '{"company": "Stress %s", "need": "a very long description of a need that goes on and on to test wrapping in the feed and the trace sheet %s"}\n' "$i" "$i" > "$dir/p$i.json"
      "$ROOT/bin/rings" emit scout prospect.qualified@1 "key=stress-$i" "ref=https://crm.example.test/stress-$i" --file "$dir/p$i.json" > /dev/null
    done
    # INBOX_MAX=5, so three runs accept 15 and leave the rest ready.
    for _ in 1 2 3; do "$ROOT/bin/rings" run bidder > /dev/null 2>&1; done
    "$ROOT/bin/rings" run closer > /dev/null 2>&1
    "$ROOT/bin/rings" halt closer "paused for the screenshot" > /dev/null
    # A ring that subscribes to a type nobody emits, so doctor has something to say.
    mkdir -p "$dir/lost"
    printf 'CONSUMES="nope@1"\nAGENT="true"\nTIMEOUT=5\nNOTIFY="none"\n' > "$dir/lost/ring.conf"
    ;;
  *) echo "usage: fixture.sh <empty|demo|stress> <dir>" >&2; exit 2 ;;
esac

echo "$dir"
