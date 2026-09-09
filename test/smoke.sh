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
