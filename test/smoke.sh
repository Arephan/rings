#!/usr/bin/env bash
# Exercises every guarantee the runner makes, against a throwaway ring.
# No network, no API key, no agent. Run it before you trust this with a schedule.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
export RINGS_HOME="$TMP/rings"
mkdir -p "$RINGS_HOME"
RINGS="$ROOT/bin/rings"

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
check() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
assert() { local d="$1"; shift; if "$@" > /dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
greps() { local d="$1" pat="$2" f="$3"; if grep -q "$pat" "$f" 2>/dev/null; then ok "$d"; else bad "$d"; fi; }

mkring() {
  # mkring <name> <agent-body>
  local d="$RINGS_HOME/$1"
  mkdir -p "$d/out"
  cat > "$d/agent.sh" <<AGENT
#!/usr/bin/env bash
$2
AGENT
  chmod +x "$d/agent.sh"
  cat > "$d/ring.conf" <<CONF
NAME="$1"
AGENT="bash agent.sh"
PROMPT_MODE="arg"
DELIVERABLE="out/last.md"
TIMEOUT=10
LOCK_STALE=5
MAX_RUNS_PER_DAY=0
NOTIFY="none"
CONF
  echo "# $1" > "$d/RUNBOOK.md"
}

echo "rings smoke test"
echo

# 1. a ring that writes its deliverable passes
mkring good 'mkdir -p out; echo "a deliverable with more than twenty words in it so that any word count based verifier will be satisfied by this line of text" > out/last.md'
"$RINGS" run good > /dev/null 2>&1
check "$?" "0" "a ring that writes its deliverable passes"
assert "deliverable exists" test -s "$RINGS_HOME/good/out/last.md"
greps "ledger records the pass" '"verdict": "pass"' "$RINGS_HOME/good/ledger.jsonl"

# 2. exit 0 without a deliverable is NOT a pass — the core claim of the project
mkring liar 'exit 0'
"$RINGS" run liar > /dev/null 2>&1
check "$?" "1" "exit 0 with no deliverable is not a pass"
greps "ledger records unverified" '"verdict": "unverified"' "$RINGS_HOME/liar/ledger.jsonl"

# 3. last run's deliverable cannot be reused to fake a pass
"$RINGS" run good > /dev/null 2>&1
cat > "$RINGS_HOME/good/agent.sh" <<'AGENT'
#!/usr/bin/env bash
exit 0
AGENT
"$RINGS" run good > /dev/null 2>&1
check "$?" "1" "a stale deliverable cannot fake a pass"

# 4. a non-zero agent is an error, not a pass
mkring broken 'exit 7'
"$RINGS" run broken > /dev/null 2>&1
check "$?" "1" "a failing agent is recorded as an error"
greps "ledger records the exit code" '"rc": 7' "$RINGS_HOME/broken/ledger.jsonl"

# 5. the timeout is a hard wall, not a request
if [ -n "$(bash -c ". $ROOT/lib/ring.sh; ring_timeout_bin")" ]; then
  mkring slow 'sleep 30'
  sed -i.bak 's/^TIMEOUT=10/TIMEOUT=2/' "$RINGS_HOME/slow/ring.conf"
  START=$(date +%s)
  "$RINGS" run slow > /dev/null 2>&1
  ELAPSED=$(( $(date +%s) - START ))
  assert "timeout killed a hung agent in ${ELAPSED}s" test "$ELAPSED" -lt 15
  greps "ledger records the timeout" '"verdict": "timeout"' "$RINGS_HOME/slow/ledger.jsonl"
else
  echo "  skip  timeout tests (no timeout/gtimeout on this machine)"
fi

# 6. the halt file stops the ring without touching its schedule
"$RINGS" halt good "testing" > /dev/null
BEFORE=$(wc -l < "$RINGS_HOME/good/ledger.jsonl")
"$RINGS" run good > /dev/null 2>&1
AFTER=$(wc -l < "$RINGS_HOME/good/ledger.jsonl")
check "$BEFORE" "$AFTER" "a halted ring does not run"
"$RINGS" resume good > /dev/null
assert "resume clears the halt" test ! -f "$RINGS_HOME/good/.halt"

# 7. the lock keeps two runs from overlapping
mkdir -p "$RINGS_HOME/good/.lock"
BEFORE=$(wc -l < "$RINGS_HOME/good/ledger.jsonl")
"$RINGS" run good > /dev/null 2>&1
AFTER=$(wc -l < "$RINGS_HOME/good/ledger.jsonl")
check "$BEFORE" "$AFTER" "a locked ring skips instead of overlapping"
rm -rf "$RINGS_HOME/good/.lock"

# 8. the daily budget is enforced
mkring budgeted 'mkdir -p out; echo "this deliverable is long enough to satisfy any reasonable word count check that a verifier might apply to it today" > out/last.md'
sed -i.bak 's/^MAX_RUNS_PER_DAY=0/MAX_RUNS_PER_DAY=2/' "$RINGS_HOME/budgeted/ring.conf"
"$RINGS" run budgeted > /dev/null 2>&1
"$RINGS" run budgeted > /dev/null 2>&1
"$RINGS" run budgeted > /dev/null 2>&1
check "$(wc -l < "$RINGS_HOME/budgeted/ledger.jsonl" | tr -d ' ')" "2" "the daily budget caps runs"

# 9. a hook that will not parse stops the run before it spends anything
mkring guarded 'mkdir -p out; echo "this deliverable is long enough to satisfy any reasonable word count check that a verifier might apply to it today" > out/last.md'
mkdir -p "$RINGS_HOME/guarded/hooks"
echo 'if [ then' > "$RINGS_HOME/guarded/hooks/pre.sh"
"$RINGS" run guarded > /dev/null 2>&1
check "$?" "3" "a hook that will not parse stops the run"
assert "nothing ran behind the broken hook" test ! -s "$RINGS_HOME/guarded/out/last.md"

# 10. hooks/verify.sh can reject a run the default check would have passed
mkring picky 'mkdir -p out; echo "too short" > out/last.md'
mkdir -p "$RINGS_HOME/picky/hooks"
cat > "$RINGS_HOME/picky/hooks/verify.sh" <<'V'
#!/usr/bin/env bash
[ "$(wc -w < "$RING_DIR/out/last.md")" -ge 20 ]
V
chmod +x "$RINGS_HOME/picky/hooks/verify.sh"
"$RINGS" run picky > /dev/null 2>&1
check "$?" "1" "a custom verifier can reject a thin deliverable"

# 11. doctor finds a scheduled ring that has never recorded a run
mkring ghost 'exit 0'
printf 'SCHEDULE="0 * * * *"\n' >> "$RINGS_HOME/ghost/ring.conf"
"$RINGS" doctor > "$TMP/doctor.out" 2>&1
greps "doctor flags a scheduled ring that never ran" '\[dead\].*ghost' "$TMP/doctor.out"
greps "doctor flags a scheduled ring with no budget" '\[unbudgeted\].*ghost' "$TMP/doctor.out"

# 11b. doctor reports a run that never verifies
mkring never 'exit 0'
for _ in 1 2 3 4 5; do "$RINGS" run never > /dev/null 2>&1; done
"$RINGS" doctor > "$TMP/doctor2.out" 2>&1
greps "doctor flags a ring that never passes" '\[silent\].*never' "$TMP/doctor2.out"

# 11c. a clean set of rings produces no findings
CLEAN="$TMP/clean"; mkdir -p "$CLEAN"
RINGS_HOME="$CLEAN" "$RINGS" doctor > "$TMP/doctor3.out" 2>&1
greps "doctor stays quiet when there is nothing wrong" 'nothing to report' "$TMP/doctor3.out"

# 12. the shipped examples actually work
"$ROOT/bin/rings" run "$ROOT/examples/hello-ring" > /dev/null 2>&1
check "$?" "0" "examples/hello-ring passes"
"$ROOT/bin/rings" run "$ROOT/examples/chain-demo/scout" > /dev/null 2>&1
check "$?" "0" "examples/chain-demo/scout passes"
"$ROOT/bin/rings" run "$ROOT/examples/chain-demo/writer" > /dev/null 2>&1
check "$?" "0" "examples/chain-demo/writer passes"
greps "the chain carried data downstream" 'disk free' "$ROOT/examples/chain-demo/writer/out/report.md"

# 12b. cron schedules translate to launchd intervals without inventing entries
CT=$(bash -c "source /dev/stdin <<< \"\$(sed -n '/^cron_field_expand/,/^}$/p;/^cron_to_launchd/,/^}$/p' '$ROOT/bin/rings')\"; cron_to_launchd '17,47 * * * *'")
check "$(printf '%s\n' "$CT" | grep -c '<dict>')" "2" "17,47 * * * * becomes two launchd entries"
CT=$(bash -c "source /dev/stdin <<< \"\$(sed -n '/^cron_field_expand/,/^}$/p;/^cron_to_launchd/,/^}$/p' '$ROOT/bin/rings')\"; cron_to_launchd '*/20 * * * *'")
check "$(printf '%s\n' "$CT" | grep -c '<dict>')" "3" "*/20 expands to three launchd entries"
CT=$(bash -c "source /dev/stdin <<< \"\$(sed -n '/^cron_field_expand/,/^}$/p;/^cron_to_launchd/,/^}$/p' '$ROOT/bin/rings')\"; cron_to_launchd '0 9,17 * * 1'")
check "$(printf '%s\n' "$CT" | grep -c '<dict>')" "2" "hours and weekday translate together"
printf '%s\n' "$CT" > "$TMP/cron.out"
greps "weekday survives translation" '<key>Weekday</key><integer>1</integer>' "$TMP/cron.out"

# 12c. contracts are verified, not taken on faith
mkring producer 'mkdir -p out; echo "x" > out/last.md'
mkdir -p "$RINGS_HOME/producer/out"
printf '%s\n' '{"kind": "lead", "id": 1}' '{"kind": "tender", "id": 2}' > "$RINGS_HOME/producer/out/rows.jsonl"
echo 'EMITS="rows:out/rows.jsonl:jsonl:72"' >> "$RINGS_HOME/producer/ring.conf"
echo 'SERVES="revenue"' >> "$RINGS_HOME/producer/ring.conf"

"$RINGS" contracts > "$TMP/c1.out" 2>&1
greps "a carrier nobody consumes is an orphan" 'orphan' "$TMP/c1.out"

mkring taker 'exit 0'
echo 'CONSUMES="producer.rows:kind=lead"' >> "$RINGS_HOME/taker/ring.conf"
"$RINGS" contracts > "$TMP/c2.out" 2>&1
greps "a declared consumer that never names the file is unwired" 'taker(unwired)' "$TMP/c2.out"

echo 'Read ../producer/out/rows.jsonl and take the leads.' >> "$RINGS_HOME/taker/RUNBOOK.md"
"$RINGS" contracts > "$TMP/c3.out" 2>&1
greps "naming the carrier wires the consumer" 'taker\[kind=lead\]' "$TMP/c3.out"
greps "rows no filter claims are counted" '1 of 2 rows' "$TMP/c3.out"

echo 'Also read ../producer/out/rows.jsonl for tenders.' >> "$RINGS_HOME/producer/RUNBOOK.md"
echo 'CONSUMES="producer.rows:kind=lead producer.rows:kind=tender"' > "$TMP/consumes"
sed -i.bak 's|^CONSUMES=.*|CONSUMES="producer.rows:kind=lead producer.rows:kind=tender"|' "$RINGS_HOME/taker/ring.conf"
"$RINGS" contracts > "$TMP/c4.out" 2>&1
greps "claiming every row clears the leak" 'all flowing' "$TMP/c4.out"

mkring ghosttaker 'exit 0'
echo 'CONSUMES="nobody.nothing"' >> "$RINGS_HOME/ghosttaker/ring.conf"
"$RINGS" contracts > "$TMP/c5.out" 2>&1
greps "consuming an emit nobody declares is dangling" 'dangling' "$TMP/c5.out"

"$RINGS" doctor > "$TMP/c6.out" 2>&1
greps "doctor reports contract findings too" 'dangling' "$TMP/c6.out"

"$RINGS" contracts --json > "$TMP/c7.json" 2>&1
if command -v python3 > /dev/null 2>&1; then
  assert "contracts --json is valid json" python3 -c "import json,sys; json.load(open('$TMP/c7.json'))"
else
  greps "contracts --json emits a contracts array" '"contracts"' "$TMP/c7.json"
fi

# 12d. a ring under no stated outcome is named as such
cat > "$RINGS_HOME/rings.conf" <<'FLEET'
APEX="one outcome"
SINKS="revenue:Money in, proof:Machine still verified"
FLEET
"$RINGS" goals > "$TMP/g1.out" 2>&1
greps "goals groups a ring under the sink it serves" 'producer' "$TMP/g1.out"
greps "goals names rings serving no outcome" 'serving no stated outcome' "$TMP/g1.out"
greps "a sink label may contain spaces" 'Machine still verified' "$TMP/g1.out"

# 12e. every age check depends on this being a number on both stats
MT=$(bash -c ". '$ROOT/lib/ring.sh'; ring_mtime '$ROOT/README.md'")
case "$MT" in
  '' | *[!0-9]*) bad "ring_mtime returns digits, not whatever stat printed" ;;
  *)             ok  "ring_mtime returns digits, not whatever stat printed" ;;
esac

# 14. handoffs — foundations
HO="$TMP/ho"; mkdir -p "$HO"
cat > "$HO/rings.conf" <<'FLEET'
APEX="one outcome"
SINKS="revenue:Money in, proof:Machine still verified"
CHAIN_revenue="tender.discovered@1 bid.submitted@1 contract.signed@1"
CHAIN_proof="sweep.ran@1"
FLEET
holib() { RINGS_HOME="$HO" bash -c ". '$ROOT/lib/ring.sh'; . '$ROOT/lib/handoffs.sh'; $*"; }
check "$(holib ho_chain_types | wc -l | tr -d ' ')" "4" "ho_chain_types lists every type in every chain"
check "$(holib ho_type_sink contract.signed@1)" "revenue" "a type knows its sink"
check "$(holib 'ho_type_is_outcome contract.signed@1 && echo yes')" "yes" "the last type in a chain is the outcome"
check "$(holib 'ho_type_is_outcome tender.discovered@1; echo $?')" "1" "an earlier type is not"
check "$(holib 'ho_type_declared nope@1; echo $?')" "1" "an undeclared type is refused"
ID=$(holib ho_new_id)
case "$ID" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]-[0-9][0-9]-[0-9][0-9]Z-??????) ok "ids are timestamp-dash-hex" ;;
  *) bad "ids are timestamp-dash-hex (got $ID)" ;;
esac
printf 'hello' > "$TMP/p"
check "$(holib "ho_sha256 '$TMP/p'")" "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" "sha256 of a payload is the real sha256"
holib "ho_kv_set '$TMP/kv' state ready; ho_kv_set '$TMP/kv' attempts 0; ho_kv_set '$TMP/kv' state leased"
check "$(holib "ho_kv_get '$TMP/kv' state")" "leased" "kv_set replaces a key in place"
check "$(grep -c . "$TMP/kv")" "2" "kv_set does not duplicate keys"
mkdir -p "$HO/scout" "$HO/bidder"
printf 'EMITS="tender.discovered@1"\n' > "$HO/scout/ring.conf"
printf 'CONSUMES="tender.discovered@1 producer.rows:kind=lead"\nEMITS="bid.submitted@1"\n' > "$HO/bidder/ring.conf"
check "$(holib "ho_ring_types '$HO/bidder' CONSUMES")" "tender.discovered@1" "ring_types returns only @ entries"
check "$(holib ho_subscribers_of tender.discovered@1)" "bidder" "subscribers are rings whose CONSUMES names the type"
check "$(holib "ho_ring_emits scout tender.discovered@1 && echo yes")" "yes" "a ring may emit what its EMITS lists"
check "$(holib "ho_ring_emits scout bid.submitted@1; echo \$?")" "1" "and nothing else"

# 15. handoffs — publish
mkdir -p "$HO/types/bid.submitted@1" "$HO/closer"
printf 'EMITS="contract.signed@1"\n' > "$HO/closer/ring.conf"
cat > "$HO/types/bid.submitted@1/accept.sh" <<'GATE'
#!/usr/bin/env bash
# refuse a bid whose payload does not name a portal reference
grep -q '"portal"' "$RING_PAYLOAD" || { echo "no portal reference in payload" >&2; exit 1; }
GATE
chmod +x "$HO/types/bid.submitted@1/accept.sh"
printf '{"title": "the big one", "value": 400000}\n' > "$TMP/tender.json"
OUT=$(RINGS_HOME="$HO" "$RINGS" emit scout tender.discovered@1 key=T-1 ref=https://example.test/T-1 --file "$TMP/tender.json")
case "$OUT" in ok\ *) ok "emit publishes a declared type from its declared producer" ;; *) bad "emit publishes a declared type from its declared producer ($OUT)" ;; esac
TID=${OUT#ok }
assert "the item has a manifest" test -f "$HO/spool/items/$TID/manifest"
assert "the item has the payload" cmp -s "$TMP/tender.json" "$HO/spool/items/$TID/payload"
check "$(holib "ho_kv_get '$HO/spool/items/$TID/manifest' type")" "tender.discovered@1" "manifest records the type"
check "$(holib "ho_kv_get '$HO/spool/items/$TID/manifest' from")" "scout" "manifest records the producer"
check "$(holib "ho_kv_get '$HO/spool/items/$TID/manifest' sha256")" "$(holib "ho_sha256 '$TMP/tender.json'")" "manifest checksum matches the payload"
assert "a ready delivery exists for the subscriber" test -f "$HO/spool/deliveries/bidder/$TID"
check "$(holib "ho_kv_get '$HO/spool/deliveries/bidder/$TID' state")" "ready" "the delivery starts ready"
assert "nothing is left in incoming" test -z "$(ls -A "$HO/spool/incoming" 2>/dev/null)"

OUT=$(RINGS_HOME="$HO" "$RINGS" emit scout tender.discovered@1 key=T-1 --file "$TMP/tender.json")
check "$OUT" "refused duplicate of $TID" "a second item with the same type and key is refused as a duplicate"
check "$(find "$HO/spool/items" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "1" "and nothing was published"
OUT=$(RINGS_HOME="$HO" "$RINGS" emit scout nope@1 key=X --file "$TMP/tender.json")
case "$OUT" in refused*not\ declared*) ok "an undeclared type is refused" ;; *) bad "an undeclared type is refused ($OUT)" ;; esac
OUT=$(RINGS_HOME="$HO" "$RINGS" emit scout bid.submitted@1 key=X --file "$TMP/tender.json")
case "$OUT" in refused*EMITS*) ok "a ring cannot emit a type it does not declare" ;; *) bad "a ring cannot emit a type it does not declare ($OUT)" ;; esac
OUT=$(RINGS_HOME="$HO" "$RINGS" emit scout tender.discovered@1 --file "$TMP/tender.json")
case "$OUT" in refused*key*) ok "key is required" ;; *) bad "key is required ($OUT)" ;; esac
: > "$TMP/empty.json"
OUT=$(RINGS_HOME="$HO" "$RINGS" emit scout tender.discovered@1 key=T-2 --file "$TMP/empty.json")
case "$OUT" in refused*payload*) ok "an empty payload is refused" ;; *) bad "an empty payload is refused ($OUT)" ;; esac
OUT=$(RINGS_HOME="$HO" "$RINGS" emit closer contract.signed@1 key=C-1 --file "$TMP/tender.json")
case "$OUT" in refused*outcome*ref*) ok "an outcome without ref is refused" ;; *) bad "an outcome without ref is refused ($OUT)" ;; esac
printf '{"bid": 1}\n' > "$TMP/bid-nogate.json"
OUT=$(RINGS_HOME="$HO" "$RINGS" emit bidder bid.submitted@1 key=B-1 --file "$TMP/bid-nogate.json")
check "$OUT" "refused gate: no portal reference in payload" "the type gate refuses a candidate and its last stderr line is the reason"
printf '{"bid": 1, "portal": "PRT-1"}\n' > "$TMP/bid.json"
OUT=$(RINGS_HOME="$HO" "$RINGS" emit bidder bid.submitted@1 key=B-1 --file "$TMP/bid.json")
case "$OUT" in ok\ *) ok "the gate lets a good candidate through" ;; *) bad "the gate lets a good candidate through ($OUT)" ;; esac
OUT=$(RINGS_HOME="$HO" "$RINGS" emit bidder bid.submitted@1 key=B-2 cause=not-an-item --file "$TMP/bid.json")
case "$OUT" in refused*cause*) ok "a cause that is not a published item is refused" ;; *) bad "a cause that is not a published item is refused ($OUT)" ;; esac

# 16. handoffs — deliveries
printf 'CONSUMES="tender.discovered@1"\nEMITS="bid.submitted@1"\nMAX_ATTEMPTS=2\nTIMEOUT=10\n' > "$HO/bidder/ring.conf"
IN="$TMP/in"; rm -rf "$IN"; mkdir -p "$IN"
LEASED=$(holib "ho_reconcile bidder \$(date +%s); ho_lease bidder run-1 10 10 '$IN'")
check "$(printf '%s\n' "$LEASED" | cut -f1)" "$TID" "lease hands out the ready item"
check "$(printf '%s\n' "$LEASED" | cut -f4)" "1" "first lease is attempt 1"
check "$(printf '%s\n' "$LEASED" | cut -f5)" "2" "and reports MAX_ATTEMPTS"
assert "the payload was copied into in/" cmp -s "$TMP/tender.json" "$IN/$TID.json"
check "$(holib "ho_kv_get '$HO/spool/deliveries/bidder/$TID' state")" "leased" "the record is leased"
check "$(holib "ho_kv_get '$HO/spool/deliveries/bidder/$TID' leased_by")" "run-1" "to this run"
check "$(holib "ho_lease bidder run-1b 10 10 '$IN'" | wc -l | tr -d ' ')" "0" "a leased item is not handed out twice"

check "$(holib "ho_decide bidder run-2 accept $TID 'x'")" "invalid $TID was not leased to this run" "a decision from the wrong run is invalid"
check "$(holib "ho_decide bidder run-1 accept $TID 'submitted, ref PRT-1'")" "ok" "the leasing run may decide"
check "$(holib "ho_kv_get '$HO/spool/deliveries/bidder/$TID' state")" "accepted" "accept is terminal"
check "$(holib "ho_kv_get '$HO/spool/deliveries/bidder/$TID' note")" "submitted, ref PRT-1" "the note is kept"

printf '{"title": "second"}\n' > "$TMP/t2.json"
T2=$(RINGS_HOME="$HO" "$RINGS" emit scout tender.discovered@1 key=T-2 --file "$TMP/t2.json"); T2=${T2#ok }
holib "ho_lease bidder run-3 10 10 '$IN' > /dev/null; ho_release_run bidder run-3"
check "$(holib "ho_kv_get '$HO/spool/deliveries/bidder/$T2' state")" "ready" "silence returns the item to ready"
check "$(holib "ho_kv_get '$HO/spool/deliveries/bidder/$T2' attempts")" "1" "and counts an attempt"
check "$(holib "ho_lease bidder run-4 10 10 '$IN'" | cut -f4)" "2" "the next lease is attempt 2"
holib "ho_release_run bidder run-4"
check "$(holib "ho_kv_get '$HO/spool/deliveries/bidder/$T2' state")" "dead" "MAX_ATTEMPTS silent leases dead-letter the item"
check "$(holib "ho_lease bidder run-5 10 10 '$IN'" | wc -l | tr -d ' ')" "0" "a dead item is not handed out"
RINGS_HOME="$HO" "$RINGS" retry "$T2" bidder > /dev/null
check "$(holib "ho_kv_get '$HO/spool/deliveries/bidder/$T2' state")" "ready" "retry revives a dead item"
check "$(holib "ho_kv_get '$HO/spool/deliveries/bidder/$T2' attempts")" "0" "with attempts reset"

# a lease whose run died is reclaimed once it expires
holib "ho_lease bidder run-6 10 10 '$IN' > /dev/null; ho_kv_set '$HO/spool/deliveries/bidder/$T2' lease_until_epoch 1"
holib "ho_reconcile bidder \$(date +%s)"
check "$(holib "ho_kv_get '$HO/spool/deliveries/bidder/$T2' state")" "ready" "an expired lease is reclaimed"
check "$(holib "ho_kv_get '$HO/spool/deliveries/bidder/$T2' attempts")" "1" "and counted"

# a missing delivery record is created by reconciliation; a new subscriber sees only new items
rm -f "$HO/spool/deliveries/bidder/$T2"
holib "ho_reconcile bidder \$(date +%s)"
assert "reconcile recreates a missing delivery" test -f "$HO/spool/deliveries/bidder/$T2"
mkdir -p "$HO/late"; printf 'CONSUMES="tender.discovered@1"\n' > "$HO/late/ring.conf"
sleep 1   # the marker has one-second resolution; everything above must be older than it
holib "ho_reconcile late \$(date +%s)"
assert "a new subscriber writes its since marker" test -f "$HO/spool/deliveries/late/.since.tender.discovered@1"
check "$(find "$HO/spool/deliveries/late" -mindepth 1 -maxdepth 1 ! -name '.*' | wc -l | tr -d ' ')" "0" "and gets no items older than the marker"
RINGS_HOME="$HO" "$RINGS" retry "$TID" late > /dev/null
check "$(holib "ho_kv_get '$HO/spool/deliveries/late/$TID' state")" "ready" "retry hands an old item to a new subscriber on purpose"

# 17. handoffs — a run end to end
H2="$TMP/h2"; mkdir -p "$H2/scout/out" "$H2/bidder/out"
cat > "$H2/rings.conf" <<'FLEET'
APEX="one outcome"
SINKS="revenue:Money in"
CHAIN_revenue="tender.discovered@1 bid.submitted@1 contract.signed@1"
FLEET
cat > "$H2/scout/ring.conf" <<'CONF'
AGENT="bash agent.sh"
DELIVERABLE="out/last.md"
TIMEOUT=10
NOTIFY="none"
EMITS="tender.discovered@1"
CONF
cat > "$H2/scout/agent.sh" <<'AGENT'
#!/usr/bin/env bash
mkdir -p out/emit
printf '{"title": "the big one", "value": 400000}\n' > out/emit/t.json
printf 'emit tender.discovered@1 key=T-100 ref=https://example.test/T-100 file=out/emit/t.json\n' > out/handoffs
echo "found one tender worth four hundred thousand and handed it on to whoever bids on these things now" > out/last.md
AGENT
cat > "$H2/bidder/ring.conf" <<'CONF'
AGENT="bash agent.sh"
DELIVERABLE="out/last.md"
TIMEOUT=10
NOTIFY="none"
CONSUMES="tender.discovered@1"
EMITS="bid.submitted@1"
CONF
cat > "$H2/bidder/agent.sh" <<'AGENT'
#!/usr/bin/env bash
mkdir -p out/emit
ID=$(ls in | head -1); ID=${ID%.json}
printf '{"bid": "PRT-9", "for": "%s"}\n' "$ID" > out/emit/b.json
{
  printf 'accept %s submitted via portal, ref PRT-9 (glob-safe: * ?)\n' "$ID"
  printf 'emit bid.submitted@1 key=PRT-9 cause=%s ref=PRT-9 file=out/emit/b.json\n' "$ID"
  printf 'frobnicate %s\n' "$ID"
  printf 'accept not-an-id whatever\n'
  printf 'emit bid.submitted@1 key=BAD KEY file=out/emit/b.json\n'
  printf 'emit bid.submitted@1 key=PARTIAL file=out/emit/b.json'
} > out/handoffs
echo "took the one tender in the inbox and submitted a bid for it through the portal under reference PRT-9 today" > out/last.md
AGENT
echo "# scout" > "$H2/scout/RUNBOOK.md"; echo "# bidder" > "$H2/bidder/RUNBOOK.md"
RINGS_HOME="$H2" "$RINGS" run scout > /dev/null 2>&1
check "$?" "0" "a producing ring passes"
check "$(find "$H2/spool/items" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "1" "the run published its emit line"
T100=$(ls "$H2/spool/items")
check "$(holib "ho_kv_get '$H2/spool/deliveries/bidder/$T100' state")" "ready" "and the subscriber has it ready"
greps "the producer ledger line carries the run id" '"run": "' "$H2/scout/ledger.jsonl"
greps "and the handoff counts" '"handoffs": {"in": 0, "accepted": 0, "rejected": 0, "emitted": 1, "invalid": 0}' "$H2/scout/ledger.jsonl"
assert "a receipt was written" test -f "$H2/scout/runs/$(holib "ho_kv_get '$H2/spool/items/$T100/manifest' run").receipt"

RINGS_HOME="$H2" "$RINGS" run bidder > /dev/null 2>&1
check "$?" "0" "a consuming ring passes"
greps "the prompt named the inbox item" "Inbox: 1 item(s)" "$H2/bidder/.prompt"
greps "and the id" "$T100  tender.discovered@1  from scout  attempt 1 of 3" "$H2/bidder/.prompt"
greps "and what it may emit" "You may emit: bid.submitted@1" "$H2/bidder/.prompt"
check "$(holib "ho_kv_get '$H2/spool/deliveries/bidder/$T100' state")" "accepted" "the decision was applied"
check "$(find "$H2/spool/items" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "2" "exactly one new item: the partial last line was ignored"
BID=""
for f in "$H2/spool/items"/*; do
  b=$(basename "$f")
  [ "$b" = "$T100" ] || BID="$b"
done
check "$(holib "ho_kv_get '$H2/spool/items/$BID/manifest' cause")" "$T100" "the bid names its cause"
RCPT=$(basename "$(find "$H2/bidder/runs" -mindepth 1 -maxdepth 1 -type f | head -1)")
greps "receipt records the input and its checksum" "in=$T100 $(holib "ho_kv_get '$H2/spool/items/$T100/manifest' sha256") attempt=1" "$H2/bidder/runs/$RCPT"
greps "receipt records the accept" "accepted=$T100 submitted via portal, ref PRT-9 (glob-safe: \* ?)" "$H2/bidder/runs/$RCPT"
greps "receipt records the emit" "emit=bid.submitted@1 key=PRT-9 -> $BID" "$H2/bidder/runs/$RCPT"
greps "receipt records the unknown verb as invalid" "invalid=frobnicate" "$H2/bidder/runs/$RCPT"
greps "receipt records the decision on a foreign id as invalid" "invalid=accept not-an-id" "$H2/bidder/runs/$RCPT"
greps "an emit with a space in its key is invalid, not truncated" 'invalid=emit bid.submitted@1 key=BAD KEY' "$H2/bidder/runs/$RCPT"
greps "the ledger counts match" '"handoffs": {"in": 1, "accepted": 1, "rejected": 0, "emitted": 1, "invalid": 3}' "$H2/bidder/ledger.jsonl"
assert "in/ still holds this run's payload for inspection" test -f "$H2/bidder/in/$T100.json"

# 18. handoffs — reading the spool
RINGS_HOME="$H2" "$RINGS" inbox bidder > "$TMP/inbox.out" 2>&1
greps "inbox lists the ring's deliveries" "$T100.*accepted" "$TMP/inbox.out"
RINGS_HOME="$H2" "$RINGS" handoffs > "$TMP/ho.out" 2>&1
greps "handoffs prints each chain type" 'tender.discovered@1' "$TMP/ho.out"
greps "with counts per state" 'bid.submitted@1 *revenue *1 ' "$TMP/ho.out"
RINGS_HOME="$H2" "$RINGS" handoffs --json > "$TMP/ho.json" 2>&1
if command -v python3 > /dev/null 2>&1; then
  assert "handoffs --json parses" python3 -c "import json; j=json.load(open('$TMP/ho.json')); assert j['types'][0]['type']=='tender.discovered@1'; assert j['types'][0]['accepted']==1; assert j['types'][0]['gated'] is False; assert j['types'][2]['oldestReadySeconds'] is None"
fi
RINGS_HOME="$H2" "$RINGS" trace "$BID" > "$TMP/trace.out" 2>&1
greps "trace shows the item" "$BID" "$TMP/trace.out"
greps "trace walks back to the cause" "$T100" "$TMP/trace.out"
greps "trace shows the producer receipt" 'receipt:' "$TMP/trace.out"
RINGS_HOME="$H2" "$RINGS" trace "$T100" --json > "$TMP/trace.json" 2>&1
if command -v python3 > /dev/null 2>&1; then
  assert "trace --json parses and lists the bid as an effect" python3 -c "import json; j=json.load(open('$TMP/trace.json')); assert j['effects'][0]['item']['id']=='$BID'; assert j['deliveries'][0]['state']=='accepted'"
fi
RINGS_HOME="$H2" "$RINGS" feed > "$TMP/feed.out" 2>&1
greps "feed shows the publish" "published tender.discovered@1" "$TMP/feed.out"
greps "feed shows the accept with its note" "accepted.*PRT-9" "$TMP/feed.out"
greps "feed shows run verdicts" "run pass" "$TMP/feed.out"
check "$(grep -c 'key=T-100 cause=' "$TMP/feed.out")" "0" "an empty cause column does not swallow the ref"
check "$(RINGS_HOME="$H2" "$RINGS" feed 2 | grep -c .)" "2" "feed honours n"
RINGS_HOME="$H2" "$RINGS" feed --json > "$TMP/feed.json" 2>&1
if command -v python3 > /dev/null 2>&1; then
  assert "feed --json parses, newest first" python3 -c "import json; j=json.load(open('$TMP/feed.json')); e=j['events']; assert e and all(e[i]['ts']>=e[i+1]['ts'] for i in range(len(e)-1))"
fi
check "$(RINGS_HOME="$CLEAN" "$RINGS" feed | grep -c .)" "0" "an empty fleet has an empty feed"
RINGS_HOME="$CLEAN" "$RINGS" handoffs --json > "$TMP/ho-empty.json" 2>&1
greps "an empty fleet still prints a types array" '"types": \[\]' "$TMP/ho-empty.json"

# 19. handoffs — doctor, list --json, goals
RINGS_HOME="$H2" "$RINGS" contracts > "$TMP/c8.out" 2>&1
greps "handoff types are not mistaken for file contracts" 'No ring declares EMITS' "$TMP/c8.out"
mkdir -p "$H2/closer/out" "$H2/sleeper/out" "$H2/lost/out"
printf 'AGENT="bash agent.sh"\nDELIVERABLE="out/last.md"\nTIMEOUT=10\nNOTIFY="none"\nEMITS="contract.signed@1"\nSCHEDULE="0 * * * *"\nMAX_RUNS_PER_DAY=24\n' > "$H2/closer/ring.conf"
echo 'echo "closer ran and had nothing to close this time around which is fine and expected for a demo ring" > out/last.md' > "$H2/closer/agent.sh"
printf 'AGENT="bash agent.sh"\nDELIVERABLE="out/last.md"\nTIMEOUT=10\nNOTIFY="none"\nCONSUMES="tender.discovered@1"\nMAX_ATTEMPTS=1\n' > "$H2/sleeper/ring.conf"
echo 'echo "sleeper woke, looked at nothing, and went back to sleep without deciding anything at all today" > out/last.md' > "$H2/sleeper/agent.sh"
printf 'AGENT="bash agent.sh"\nDELIVERABLE="out/last.md"\nTIMEOUT=10\nNOTIFY="none"\nCONSUMES="nope@1"\n' > "$H2/lost/ring.conf"
echo 'echo "lost consumes a type that no chain declares and this line only exists to satisfy the verifier" > out/last.md' > "$H2/lost/agent.sh"
for r in closer sleeper lost; do echo "# $r" > "$H2/$r/RUNBOOK.md"; done
printf '{"title": "third"}\n' > "$TMP/t3.json"
T3=$(RINGS_HOME="$H2" "$RINGS" emit scout tender.discovered@1 key=T-300 --file "$TMP/t3.json"); T3=${T3#ok }
RINGS_HOME="$H2" "$RINGS" run sleeper > /dev/null 2>&1   # marker written; T3 too old for it
RINGS_HOME="$H2" "$RINGS" retry "$T3" sleeper > /dev/null
RINGS_HOME="$H2" "$RINGS" run sleeper > /dev/null 2>&1   # leases T3, decides nothing, MAX_ATTEMPTS=1 → dead
check "$(holib "ho_kv_get '$H2/spool/deliveries/sleeper/$T3' state")" "dead" "setup: sleeper dead-lettered the item"
holib "ho_kv_set '$H2/spool/deliveries/bidder/$T3' created 2020-01-01T00:00:00Z"
printf 'SCHEDULE="17,47 * * * *"\n' >> "$H2/bidder/ring.conf"
rm -f "$H2/spool/deliveries/sleeper/$T100"
echo "2000-01-01T00:00:00Z" > "$H2/spool/deliveries/sleeper/.since.tender.discovered@1"   # backdate the marker so T100 counts as undelivered
RINGS_HOME="$H2" "$RINGS" doctor > "$TMP/d.out" 2>&1
greps "doctor: a type with no gate" '\[ungated\].*tender.discovered@1' "$TMP/d.out"
greps "doctor: an emitted type nobody consumes" '\[orphan\].*contract.signed@1' "$TMP/d.out"
greps "doctor: a ring naming an undeclared type" '\[dangling\].*lost.*nope@1' "$TMP/d.out"
greps "doctor: dead letters" '\[dead-letter\].*sleeper.*'"$T3" "$TMP/d.out"
greps "doctor: a receipt with refused lines" '\[invalid\].*bidder' "$TMP/d.out"
greps "doctor: a ready item older than three intervals" '\[backlog\].*bidder' "$TMP/d.out"
greps "doctor: an item with no delivery record at a subscriber" '\[undelivered\].*'"$T100"'.*sleeper' "$TMP/d.out"
RINGS_HOME="$H2" "$RINGS" doctor --json > "$TMP/d.json" 2>&1
if command -v python3 > /dev/null 2>&1; then
  assert "doctor --json parses with tagged findings" python3 -c "import json; j=json.load(open('$TMP/d.json')); assert any(f['tag']=='dead-letter' for f in j['findings']); assert j['rings']>=5"
fi
RINGS_HOME="$H2" "$RINGS" list --json > "$TMP/l.json" 2>&1
if command -v python3 > /dev/null 2>&1; then
  assert "list --json parses and counts today's runs" python3 -c "import json; j=json.load(open('$TMP/l.json')); b=[r for r in j['rings'] if r['ring']=='bidder'][0]; assert b['runsToday']>=1; assert b['consumes']==['tender.discovered@1']"
fi
RINGS_HOME="$H2" "$RINGS" goals > "$TMP/g2.out" 2>&1
greps "goals prints the funnel with item counts" 'tender.discovered@1 *2' "$TMP/g2.out"
greps "and names producers" 'bid.submitted@1 *1 *bidder' "$TMP/g2.out"
greps "and marks the outcome" 'contract.signed@1 *0.*outcome' "$TMP/g2.out"
greps "a ring on a chain is not unserved" '^  serving no stated outcome:.*lost' "$TMP/g2.out"
RINGS_HOME="$H2" "$RINGS" goals --json > "$TMP/g.json" 2>&1
if command -v python3 > /dev/null 2>&1; then
  assert "goals --json parses with the chain" python3 -c "import json; j=json.load(open('$TMP/g.json')); c=j['sinks'][0]['chain']; assert c[0]['type']=='tender.discovered@1' and c[0]['items']==2 and c[2]['outcome'] is True; assert 'lost' in j['unserved'] and 'bidder' not in j['unserved']"
fi

mkdir -p "$H2/multi/out"; printf 'AGENT="true"\nTIMEOUT=5\nNOTIFY="none"\n' > "$H2/multi/ring.conf"; echo "# multi" > "$H2/multi/RUNBOOK.md"
RINGS_HOME="$H2" "$RINGS" halt multi "$(printf 'line one\nline two')" > /dev/null
RINGS_HOME="$H2" "$RINGS" doctor > "$TMP/d-multi.out" 2>&1
check "$(grep -c '^\[line two\]' "$TMP/d-multi.out")" "0" "a multi-line halt reason stays one finding"
RINGS_HOME="$H2" "$RINGS" doctor --json > "$TMP/d-multi.json" 2>&1
if command -v python3 > /dev/null 2>&1; then
  assert "and one json entry" python3 -c "import json; j=json.load(open('$TMP/d-multi.json')); h=[f for f in j['findings'] if f['tag']=='halted' and 'multi' in f['text']]; assert len(h)==1 and 'line one line two' in h[0]['text']; assert not [f for f in j['findings'] if f['tag']=='line two']"
fi

# 13. everything parses under bash 3.2, which is what launchd runs
for f in "$ROOT/bin/rings" "$ROOT"/lib/*.sh "$ROOT"/template/hooks/*.sh "$ROOT"/examples/*/agent.sh "$ROOT"/examples/*/*/agent.sh; do
  [ -f "$f" ] || continue
  /bin/bash -n "$f" 2>/dev/null || bad "$(basename "$f") does not parse under /bin/bash"
done
ok "every shipped script parses under /bin/bash"

rm -rf "$TMP"
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
