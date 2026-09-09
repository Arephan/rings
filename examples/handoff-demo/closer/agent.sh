#!/usr/bin/env bash
# A fake agent: pretends every proposal in the inbox was signed. A real closer
# would check the contract system and reject proposals still open.
set -uo pipefail
mkdir -p out/emit
: > out/handoffs
n=0
for f in in/*.json; do
  [ -f "$f" ] || continue
  id=$(basename "$f" .json)
  n=$((n + 1))
  printf '{"proposal": "%s", "signed": true}\n' "$id" > "out/emit/deal-$n.json"
  printf 'accept %s countersigned copy on file\n' "$id" >> out/handoffs
  printf 'emit deal.signed@1 key=deal-%s cause=%s ref=https://contracts.example.test/%s file=out/emit/deal-%s.json\n' "$id" "$id" "$id" "$n" >> out/handoffs
done
echo "Checked $n proposal(s) against the contract system and recorded each signed deal with its reference." > out/last.md
