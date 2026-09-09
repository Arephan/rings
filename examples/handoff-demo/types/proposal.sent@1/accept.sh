#!/usr/bin/env bash
# The gate for proposal.sent@1. A proposal that names no channel it went out on
# is a proposal that was written, not sent. Exit non-zero to refuse; the last
# line on stderr becomes the reason in the receipt.
set -uo pipefail
grep -q '"sent_via"' "$RING_PAYLOAD" || { echo "payload has no sent_via" >&2; exit 1; }
[ -n "$RING_CAUSE" ] || { echo "a proposal must name the prospect it answers (cause=)" >&2; exit 1; }
exit 0
