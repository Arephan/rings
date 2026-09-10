#!/usr/bin/env bash
# rings — core runner.
#
# One function, ring_run, executes a single ring end to end and is responsible
# for every guarantee this project makes: a ring never runs twice at once, never
# runs past its timeout, never runs while halted, never exceeds its daily budget,
# and never reports success without producing its declared deliverable.
#
# Written for bash 3.2 so it behaves identically under launchd's /bin/bash on
# macOS and under modern bash on Linux. No associative arrays, no ${var^^},
# no mapfile.

# shellcheck source=./handoffs.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/handoffs.sh"

ring_run() {
  local dir="$1"
  [ -d "$dir" ] || { echo "rings: no such ring: $dir" >&2; return 2; }
  dir=$(cd "$dir" && pwd)

  [ -f "$dir/ring.conf" ] || { echo "rings: $dir has no ring.conf" >&2; return 2; }
  # shellcheck source=/dev/null
  . "$dir/ring.conf"

  local name agent timeout_s lock_stale deliverable notify max_runs prompt_mode
  name="${NAME:-$(basename "$dir")}"
  agent="${AGENT:-}"
  timeout_s="${TIMEOUT:-900}"
  lock_stale="${LOCK_STALE:-$((timeout_s + 300))}"
  deliverable="${DELIVERABLE:-}"
  notify="${NOTIFY:-stdout}"
  max_runs="${MAX_RUNS_PER_DAY:-0}"
  prompt_mode="${PROMPT_MODE:-arg}"

  local ring_id run_id inbox_max ho_on inbox ho_block ho_counts
  ring_id=$(basename "$dir")
  run_id=$(ho_run_id)
  inbox_max="${INBOX_MAX:-10}"
  ho_on=0
  inbox=""; ho_block=""; ho_counts=""
  ho_active "$dir" && ho_on=1

  local log ledger lock started rc dpath
  log="$dir/ring.log"
  ledger="$dir/ledger.jsonl"
  lock="$dir/.lock"
  started=$(date -u +%FT%TZ)
  dpath=""
  [ -n "$deliverable" ] && dpath="$dir/$deliverable"

  # --- stop rule 1: the halt file. A human, or another ring, can stop this ring
  # without editing a schedule or killing a daemon.
  if [ -f "$dir/.halt" ]; then
    ring_log "$log" "SKIP halted ($(head -c 200 "$dir/.halt" 2>/dev/null))"
    return 0
  fi

  # --- stop rule 2: daily budget. A loop that wakes every 30 minutes and is
  # allowed to burn an agent call each time is the most common way these systems
  # waste money. 0 means unlimited, and you should have to type it.
  if [ "$max_runs" -gt 0 ] && [ -f "$ledger" ]; then
    local today count
    today=$(date -u +%F)
    count=$(grep -c "\"started\": \"$today" "$ledger" 2>/dev/null | tr -d ' ')
    [ -z "$count" ] && count=0
    if [ "$count" -ge "$max_runs" ]; then
      ring_log "$log" "SKIP budget reached ($count/$max_runs runs today)"
      return 0
    fi
  fi

  # --- stop rule 3: the lock. mkdir is atomic on every filesystem that matters,
  # unlike a pid file. A lock older than LOCK_STALE belonged to a run that was
  # killed before its trap fired, and is reclaimed.
  if mkdir "$lock" 2>/dev/null; then
    echo "$$" > "$lock/pid"
  else
    local age
    age=$(( $(date +%s) - $(ring_mtime "$lock") ))
    if [ "$age" -lt "$lock_stale" ]; then
      ring_log "$log" "SKIP previous run still active (${age}s)"
      return 0
    fi
    ring_log "$log" "RECLAIM stale lock (${age}s)"
    rm -rf "$lock"
    mkdir "$lock"
    echo "$$" > "$lock/pid"
  fi
  # The trap is the crash net, not the release: it is process-wide, so a caller
  # that runs three rings in one process would overwrite it twice and leave the
  # first two locks behind. Every return path below releases the lock by hand.
  # shellcheck disable=SC2064
  trap "rm -rf '$lock'" EXIT

  # Everything from here runs with the ring as the working directory, so a
  # runbook and an agent command can both use paths relative to the ring.
  cd "$dir" || { ring_unlock "$lock"; return 2; }
  export RING_DIR="$dir" RING_NAME="$name"

  # --- guard: a syntax error in a hook used to be a silent outage, because the
  # loop still "ran" and still exited 0. Parse-check before spending an agent call.
  local h
  for h in "$dir"/hooks/*.sh; do
    [ -f "$h" ] || continue
    if ! bash -n "$h" 2>"$dir/.guard.err"; then
      ring_log "$log" "GUARD $h will not parse: $(head -1 "$dir/.guard.err")"
      ring_notify "$notify" "$name" "[down] $name: $(basename "$h") will not parse — $(head -1 "$dir/.guard.err")"
      ring_unlock "$lock"
      return 3
    fi
    # macOS launchd runs /bin/bash 3.2 while most authors test under bash 5.
    if [ -x /bin/bash ] && ! /bin/bash -n "$h" 2>"$dir/.guard.err"; then
      ring_log "$log" "GUARD $h parses under your bash but not /bin/bash: $(head -1 "$dir/.guard.err")"
      ring_notify "$notify" "$name" "[down] $name: $(basename "$h") fails the /bin/bash parse — $(head -1 "$dir/.guard.err")"
      ring_unlock "$lock"
      return 3
    fi
  done

  # --- memory: the previous deliverable is fed back in, so a ring can see what it
  # already said and refuse to repeat itself. This is the difference between a
  # loop that makes progress and one that oscillates.
  local prev="(no previous run)"
  if [ -n "$dpath" ] && [ -s "$dpath" ]; then
    prev=$(cat "$dpath")
    mkdir -p "$dir/.prev"
    cp -f "$dpath" "$dir/.prev/last" 2>/dev/null
  fi
  if [ -n "$dpath" ] && [ -f "$dpath" ]; then
    rm -f -- "$dpath"
  fi

  # --- handoffs: clear last run's candidates and inbox, reconcile the spool, and
  # lease what is waiting. The agent sees the result as a block in the prompt.
  if [ "$ho_on" -eq 1 ]; then
    rm -rf "$dir/in" "$dir/out/emit" "$dir/out/handoffs"
    mkdir -p "$dir/in" "$dir/out/emit" "$dir/runs"
    ho_reconcile "$ring_id" "$(date +%s)"
    inbox=$(ho_lease "$ring_id" "$run_id" "$inbox_max" "$timeout_s" "$dir/in")
    ho_block=$(ho_prompt_block "$dir" "$inbox")
  fi

  ring_log "$log" "RUN START"
  if [ -x "$dir/hooks/pre.sh" ]; then
    RING_DIR="$dir" RING_NAME="$name" "$dir/hooks/pre.sh" >> "$log" 2>&1
  fi

  # --- goal: RUNBOOK.md is the durable contract; the block below is this run's
  # context. Keeping them apart is deliberate — you edit the runbook, you never
  # edit the loop.
  local runbook context prompt
  runbook=""
  [ -f "$dir/RUNBOOK.md" ] && runbook=$(cat "$dir/RUNBOOK.md")
  context="

===============================================================================
THIS RUN
===============================================================================
Ring: ${name}
Started: $(date '+%A %B %-d, %Y at %-I:%M %p %Z')
Working directory: ${dir}

Your previous deliverable was:
---
${prev}
---
Do not repeat it. Report what changed, or find something new."
  if [ -n "$deliverable" ]; then
    context="${context}

Writing ${deliverable} is the deliverable. If you finish without writing it,
this run produced nothing and will be recorded as a failure."
  fi
  prompt="${runbook}${context}${ho_block}"
  [ "$ho_on" -eq 1 ] && printf '%s' "$prompt" > "$dir/.prompt"

  # --- act, under a hard wall clock. An agent that hangs must not hold the lock
  # until the next reboot.
  local to
  to=$(ring_timeout_bin)
  if [ -z "$agent" ]; then
    ring_log "$log" "no AGENT set in ring.conf; nothing to run"
    rc=2
  elif [ -z "$to" ]; then
    ring_log "$log" "WARN no timeout binary found; running unbounded"
    if [ "$prompt_mode" = "stdin" ]; then
      printf '%s' "$prompt" | bash -c "$agent" >> "$log" 2>&1
      rc=$?
    else
      bash -c "$agent \"\$1\"" _ "$prompt" < /dev/null >> "$log" 2>&1
      rc=$?
    fi
  else
    if [ "$prompt_mode" = "stdin" ]; then
      printf '%s' "$prompt" | "$to" "$timeout_s" bash -c "$agent" >> "$log" 2>&1
      rc=$?
    else
      "$to" "$timeout_s" bash -c "$agent \"\$1\"" _ "$prompt" < /dev/null >> "$log" 2>&1
      rc=$?
    fi
  fi
  ring_log "$log" "RUN END rc=$rc"

  # --- verify: the whole point. An exit code of 0 is not evidence of work.
  # A ring passes when its verifier says so, and the default verifier is
  # "the deliverable exists and is not empty".
  local verdict detail
  verdict="pass"
  detail=""
  if [ "$rc" -eq 124 ]; then
    verdict="timeout"
    detail="killed at ${timeout_s}s"
  elif [ "$rc" -ne 0 ]; then
    verdict="error"
    detail="agent exited $rc"
  elif [ -x "$dir/hooks/verify.sh" ]; then
    if RING_DIR="$dir" RING_NAME="$name" "$dir/hooks/verify.sh" >> "$log" 2>&1; then
      verdict="pass"
    else
      verdict="unverified"
      detail="hooks/verify.sh rejected the run"
    fi
  elif [ -n "$dpath" ] && [ ! -s "$dpath" ]; then
    verdict="unverified"
    detail="ran clean but wrote no ${deliverable}"
  fi

  if [ -x "$dir/hooks/post.sh" ]; then
    RING_DIR="$dir" RING_NAME="$name" RING_VERDICT="$verdict" "$dir/hooks/post.sh" >> "$log" 2>&1
  fi

  # --- handoffs: publish what came back, apply decisions, release the rest, and
  # write the receipt. Before the ledger line so the counts land in it.
  if [ "$ho_on" -eq 1 ]; then
    ho_counts=$(ho_settle "$dir" "$ring_id" "$run_id" "$started" "$rc" "$verdict" "$inbox")
  fi
  ring_ledger_append "$ledger" "$name" "$started" "$rc" "$verdict" "$detail" "$run_id" "$ho_counts"

  # --- notify: a ring reports its output, or reports that it failed. It never
  # reports that it ran. "I woke up" is not news.
  if [ "$verdict" = "pass" ]; then
    if [ -n "$dpath" ] && [ -s "$dpath" ]; then
      ring_notify "$notify" "$name" "$(cat "$dpath")"
    fi
  else
    ring_notify "$notify" "$name" "[$verdict] ${name}: ${detail:-see $log}"
  fi

  ring_log "$log" "DONE $verdict"
  ring_unlock "$lock"
  [ "$verdict" = "pass" ] && return 0
  return 1
}

# --- helpers -----------------------------------------------------------------

ring_unlock() {
  # Release a lock ring_run took. Safe to call on a lock that is already gone.
  rm -rf -- "$1"
}

# Shared by bin/rings and every lib. RINGS_HOME must be set by the caller.
each_ring() {
  local d
  [ -d "$RINGS_HOME" ] || return 0
  for d in "$RINGS_HOME"/*; do
    [ -f "$d/ring.conf" ] && echo "$d"
  done
}

conf_get() {
  # conf_get <dir> <KEY> [default] — read one value without sourcing into our shell
  local v
  v=$(bash -c ". '$1/ring.conf' 2>/dev/null; printf '%s' \"\${$2:-}\"")
  [ -z "$v" ] && v="${3:-}"
  printf '%s' "$v"
}

last_ledger_field() {
  # last_ledger_field <ledger> <field>
  [ -s "$1" ] || return 1
  tail -1 "$1" | sed -n "s/.*\"$2\": *\"\{0,1\}\([^\",}]*\).*/\1/p"
}

fleet_get() {
  # fleet_get <KEY> [default] — read one value from $RINGS_HOME/rings.conf
  local v
  [ -f "$RINGS_HOME/rings.conf" ] || { printf '%s' "${2:-}"; return; }
  v=$(bash -c ". '$RINGS_HOME/rings.conf' 2>/dev/null; printf '%s' \"\${$1:-}\"")
  [ -z "$v" ] && v="${2:-}"
  printf '%s' "$v"
}

ring_log() {
  local log="$1"
  shift
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$log"
}

ring_mtime() {
  # GNU stat first, BSD second. The order matters and so does the digit check:
  # GNU `stat -f %m` does not fail on a file, it prints "?" and exits 0, and a
  # "?" reaching an arithmetic expansion aborts the caller rather than the sum.
  local m
  m=$(stat -c %Y "$1" 2>/dev/null) || m=$(stat -f %m "$1" 2>/dev/null) || m=""
  case "$m" in
    '' | *[!0-9]*) echo 0 ;;
    *) echo "$m" ;;
  esac
}

ring_timeout_bin() {
  local c
  for c in timeout gtimeout /opt/homebrew/bin/timeout /usr/local/bin/timeout; do
    if command -v "$c" >/dev/null 2>&1; then
      command -v "$c"
      return 0
    fi
  done
  echo ""
}

ring_json_escape() {
  # Portable enough for the fields we write. Order matters: backslash first.
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n\t\r' '   '
}

ring_ledger_append() {
  # ring_ledger_append <ledger> <name> <started> <rc> <verdict> <detail> [run] [extra json fragment]
  local ledger name started rc verdict detail ended run extra
  ledger="$1"; name="$2"; started="$3"; rc="$4"; verdict="$5"; detail="$6"; run="${7:-}"; extra="${8:-}"
  ended=$(date -u +%FT%TZ)
  {
    printf '{"ring": "%s", "started": "%s", "ended": "%s", "rc": %s, "verdict": "%s", "detail": "%s"' \
      "$(ring_json_escape "$name")" "$started" "$ended" "$rc" "$verdict" "$(ring_json_escape "$detail")"
    [ -n "$run" ] && printf ', "run": "%s"' "$run"
    [ -n "$extra" ] && printf ', %s' "$extra"
    printf '}\n'
  } >> "$ledger"
}

ring_notify() {
  local channel name msg payload
  channel="$1"; name="$2"; msg="$3"
  [ -z "$msg" ] && return 0
  case "$channel" in
    none)
      :
      ;;
    stdout)
      printf -- '-- %s --\n%s\n' "$name" "$msg"
      ;;
    slack)
      local token
      token="${RINGS_SLACK_TOKEN:-}"
      if [ -z "$token" ] && [ -f "$HOME/.rings_slack_token" ]; then
        token=$(cat "$HOME/.rings_slack_token")
      fi
      if [ -z "$token" ] || [ -z "${RINGS_SLACK_CHANNEL:-}" ]; then
        echo "rings: slack notifier needs RINGS_SLACK_TOKEN and RINGS_SLACK_CHANNEL" >&2
        return 1
      fi
      payload=$(ring_slack_payload "$RINGS_SLACK_CHANNEL" "$msg")
      printf '%s' "$payload" | curl -s -X POST https://slack.com/api/chat.postMessage \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json; charset=utf-8" \
        --data-binary @- > /dev/null
      ;;
    webhook)
      if [ -z "${RINGS_WEBHOOK_URL:-}" ]; then
        echo "rings: webhook notifier needs RINGS_WEBHOOK_URL" >&2
        return 1
      fi
      payload=$(ring_slack_payload "$name" "$msg")
      printf '%s' "$payload" | curl -s -X POST "$RINGS_WEBHOOK_URL" \
        -H "Content-Type: application/json" --data-binary @- > /dev/null
      ;;
    *)
      # Anything else is treated as a command the message is piped into.
      printf '%s' "$msg" | bash -c "$channel"
      ;;
  esac
}

ring_slack_payload() {
  printf '{"channel": "%s", "text": "%s", "mrkdwn": true}' \
    "$(ring_json_escape "$1")" "$(ring_json_escape "$2")"
}
