#!/usr/bin/env bash
# The gate for the outcome. The runner already insists on ref=; this checks it
# points somewhere outside the fleet. A real gate would fetch it.
set -uo pipefail
case "$RING_REF" in
  https://*) exit 0 ;;
  *) echo "ref must be a URL into the contract system, got: $RING_REF" >&2; exit 1 ;;
esac
