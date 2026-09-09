#!/usr/bin/env bash
# A fake agent: accepts every prospect in its inbox and emits one proposal per
# prospect, naming the prospect as cause so the trace holds together.
set -uo pipefail
mkdir -p out/emit
: > out/handoffs
n=0
for f in in/*.json; do
  [ -f "$f" ] || continue
  id=$(basename "$f" .json)
  n=$((n + 1))
  printf '{"for": "%s", "sent_via": "email", "amount": 38000}\n' "$id" > "out/emit/proposal-$n.json"
  printf 'accept %s proposal drafted and sent by email\n' "$id" >> out/handoffs
  printf 'emit proposal.sent@1 key=proposal-%s cause=%s ref=mail:%s file=out/emit/proposal-%s.json\n' "$id" "$id" "$id" "$n" >> out/handoffs
done
echo "Took $n prospect(s) from the inbox, sent a proposal for each by email, and handed every proposal on to the closer." > out/last.md
