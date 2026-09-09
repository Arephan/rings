#!/usr/bin/env bash
# A fake agent: it "finds" one prospect and hands it on. A real ring would put
# `claude -p` or any other agent here and let the runbook do this.
set -uo pipefail
mkdir -p out/emit
STAMP=$(date -u +%H%M%S)
printf '{"company": "Northwind %s", "need": "a booking system", "budget": 40000}\n' "$STAMP" > out/emit/prospect.json
printf 'emit prospect.qualified@1 key=northwind-%s ref=https://crm.example.test/northwind-%s file=out/emit/prospect.json\n' "$STAMP" "$STAMP" > out/handoffs
echo "Qualified one prospect (Northwind $STAMP, booking system, budget forty thousand) and handed it to whoever writes proposals." > out/last.md
