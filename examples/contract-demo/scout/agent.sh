#!/usr/bin/env bash
set -uo pipefail
mkdir -p out
{
  printf '{"kind": "lead", "id": "%s-a", "title": "small job"}\n' "$(date -u +%H%M)"
  printf '{"kind": "lead", "id": "%s-b", "title": "another small job"}\n' "$(date -u +%H%M)"
  printf '{"kind": "tender", "id": "%s-c", "title": "the big one", "value": 400000}\n' "$(date -u +%H%M)"
} > out/leads.jsonl
