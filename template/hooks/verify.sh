#!/usr/bin/env bash
# Optional. Delete this file and the DELIVERABLE check in ring.conf is the verifier.
#
# Exit 0 = this run really did the work. Non-zero = mark it unverified, notify,
# and record it in the ledger. RING_DIR and RING_NAME are set.
set -uo pipefail

OUT="$RING_DIR/out/last.md"

[ -s "$OUT" ] || { echo "verify: no deliverable"; exit 1; }

# A deliverable that is only a header is the classic false pass.
if [ "$(wc -w < "$OUT")" -lt 20 ]; then
  echo "verify: deliverable is under 20 words"
  exit 1
fi

exit 0
