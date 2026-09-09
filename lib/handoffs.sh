# handoffs.sh — the delivered form of a contract. See docs/handoffs.md.
#
# A contract says ring B reads a file ring A writes. A handoff has the runner
# carry each typed work item from A to B, keep a receipt for every step, and
# refuse to publish what fails the type's gate. This file owns the spool.
#
# bash 3.2. Manifests and delivery records are key=value lines so this file
# never needs a JSON parser; payloads are opaque and only a type's accept.sh
# ever opens one.

# --- paths, time, ids --------------------------------------------------------

ho_spool() { printf '%s\n' "$RINGS_HOME/spool"; }

ho_now() { date -u +%FT%TZ; }

ho_run_id() { date -u +%Y-%m-%dT%H-%M-%SZ; }

ho_new_id() {
  # UTC to the second with colons replaced (it is a directory name), plus six hex.
  local hex
  hex=$(od -An -N3 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  [ -n "$hex" ] || hex=$(printf '%06x' "$(( (RANDOM * 32768 + RANDOM) % 16777216 ))")
  printf '%s-%s\n' "$(ho_run_id)" "$hex"
}

ho_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -c1-64
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -c1-64
  else echo unavailable; fi
}

ho_epoch_to_iso() {
  # GNU first, BSD second. Both print RFC3339 UTC.
  date -u -d "@$1" +%FT%TZ 2>/dev/null || date -u -r "$1" +%FT%TZ 2>/dev/null || echo ""
}

# --- key=value files ---------------------------------------------------------

# ho_kv_get <file> <key> — the value, empty if the key is absent; exit 1 if no file.
ho_kv_get() {
  [ -f "$1" ] || return 1
  sed -n "s/^$2=//p" "$1" | head -1
}

# ho_kv_set <file> <key> <value> — replace or append, written via tmp + mv so a
# reader never sees a half-written record. Newlines in the value are dropped.
ho_kv_set() {
  local f="$1" k="$2" v tmp
  v=$(printf '%s' "$3" | tr -d '\n\r')
  tmp="$f.tmp.$$"
  if [ -f "$f" ]; then grep -v "^$k=" "$f" > "$tmp"; else : > "$tmp"; fi
  printf '%s=%s\n' "$k" "$v" >> "$tmp"
  mv -f "$tmp" "$f"
}

# --- declarations ------------------------------------------------------------

# ho_chain_types — TSV: type, sink, is_outcome — for every CHAIN_<sink> in rings.conf.
ho_chain_types() {
  local sinks sink id types t last oldifs
  sinks=$(fleet_get SINKS "")
  oldifs="$IFS"; IFS=","
  for sink in $sinks; do
    IFS="$oldifs"
    sink=$(printf '%s' "$sink" | sed -e 's/^ *//' -e 's/ *$//')
    id=${sink%%:*}
    [ -n "$id" ] || { IFS=","; continue; }
    types=$(fleet_get "CHAIN_$id" "")
    last=""
    for t in $types; do last="$t"; done
    for t in $types; do
      if [ "$t" = "$last" ]; then printf '%s\t%s\t1\n' "$t" "$id"; else printf '%s\t%s\t0\n' "$t" "$id"; fi
    done
    IFS=","
  done
  IFS="$oldifs"
}

ho_type_sink()       { ho_chain_types | awk -F'\t' -v t="$1" '$1 == t { print $2; exit }'; }
ho_type_declared()   { [ -n "$(ho_type_sink "$1")" ]; }
ho_type_is_outcome() { [ "$(ho_chain_types | awk -F'\t' -v t="$1" '$1 == t { print $3; exit }')" = "1" ]; }

# ho_ring_types <ring dir> <EMITS|CONSUMES> — only the entries that are handoff
# types (they contain @). Everything else is a v0.2 file contract.
ho_ring_types() {
  local t
  for t in $(conf_get "$1" "$2" ""); do
    case "$t" in *@*) printf '%s\n' "$t" ;; esac
  done
}

ho_active() {
  [ -n "$(ho_ring_types "$1" EMITS)$(ho_ring_types "$1" CONSUMES)" ]
}

# ho_ring_emits <ring name> <type>
ho_ring_emits() {
  local t
  for t in $(ho_ring_types "$RINGS_HOME/$1" EMITS); do
    [ "$t" = "$2" ] && return 0
  done
  return 1
}

# ho_subscribers_of <type> — ring names whose CONSUMES lists the type.
ho_subscribers_of() {
  local d t
  for d in $(each_ring); do
    for t in $(ho_ring_types "$d" CONSUMES); do
      [ "$t" = "$1" ] && basename "$d"
    done
  done
}

# --- publish -----------------------------------------------------------------

# ho_find_key <type> <key> — id of the published item with that identity, if any.
ho_find_key() {
  local m
  for m in "$(ho_spool)"/items/*/manifest; do
    [ -f "$m" ] || continue
    [ "$(ho_kv_get "$m" type)" = "$1" ] || continue
    [ "$(ho_kv_get "$m" key)" = "$2" ] || continue
    ho_kv_get "$m" id
    return 0
  done
  return 1
}

# ho_deliver <id> <ring> — a ready delivery record, created once, never twice.
ho_deliver() {
  local f
  f="$(ho_spool)/deliveries/$2/$1"
  [ -f "$f" ] && return 0
  mkdir -p "$(dirname "$f")"
  {
    echo "state=ready"
    echo "attempts=0"
    echo "leased_by="
    echo "lease_until="
    echo "lease_until_epoch="
    echo "ended="
    echo "note="
    echo "created=$(ho_now)"
  } > "$f.tmp.$$"
  mv -f "$f.tmp.$$" "$f"
}

# ho_publish <ring> <run> <type> <key> <cause> <ref> <payload file>
# Prints one line: "ok <id>" or "refused <reason>". The refusal reasons are the
# built-in checks from docs/handoffs.md, then the type's accept.sh if there is one.
ho_publish() {
  local ring="$1" run="$2" type="$3" key="$4" cause="$5" ref="$6" payload="$7"
  local spool id tmp sha bytes sub dup gate why drec cstate
  spool=$(ho_spool)

  ho_type_declared "$type" || { echo "refused $type is not declared in any CHAIN_ line of rings.conf"; return 0; }
  ho_ring_emits "$ring" "$type" || { echo "refused $ring does not list $type in EMITS"; return 0; }
  [ -n "$key" ] || { echo "refused key= is required"; return 0; }
  if [ ! -f "$payload" ] || [ ! -s "$payload" ]; then
    echo "refused payload $payload is missing, empty or not a regular file"; return 0
  fi
  if ho_type_is_outcome "$type" && [ -z "$ref" ]; then
    echo "refused $type is an outcome and needs ref= into the system where it happened"; return 0
  fi
  if [ -n "$cause" ]; then
    [ -f "$spool/items/$cause/manifest" ] || { echo "refused cause $cause is not a published item"; return 0; }
    drec="$spool/deliveries/$ring/$cause"
    case "$run" in
      cli-*)
        # A hand-run emit has no lease of its own. The weaker rule it has to
        # satisfy is that the ring has taken the cause at some point: a run of
        # it holds the lease now, or a run of it decided to accept.
        cstate=$(ho_kv_get "$drec" state 2>/dev/null)
        if [ "$cstate" != "leased" ] && [ "$cstate" != "accepted" ]; then
          echo "refused cause $cause has not been taken by $ring (no leased or accepted delivery)"; return 0
        fi
        ;;
      *)
        if [ "$(ho_kv_get "$drec" leased_by 2>/dev/null)" != "$run" ] && [ "$(ho_kv_get "$drec" decided_by 2>/dev/null)" != "$run" ]; then
          echo "refused cause $cause was not leased to run $run of $ring"; return 0
        fi
        ;;
    esac
  fi
  if dup=$(ho_find_key "$type" "$key"); then
    echo "refused duplicate of $dup"; return 0
  fi

  gate="$RINGS_HOME/types/$type/accept.sh"
  if [ -x "$gate" ]; then
    if ! why=$(RING_PAYLOAD="$payload" RING_KEY="$key" RING_REF="$ref" RING_CAUSE="$cause" \
                RING_FROM="$ring" RING_TYPE="$type" "$gate" 2>&1 >/dev/null); then
      echo "refused gate: $(printf '%s\n' "$why" | grep . | tail -1)"; return 0
    fi
  fi

  id=$(ho_new_id)
  tmp="$spool/incoming/$id"
  mkdir -p "$tmp" "$spool/items" || return 2
  cp "$payload" "$tmp/payload" || return 2
  sha=$(ho_sha256 "$tmp/payload")
  bytes=$(wc -c < "$tmp/payload" | tr -d ' ')
  {
    echo "id=$id"
    echo "type=$type"
    echo "from=$ring"
    echo "run=$run"
    echo "ts=$(ho_now)"
    echo "key=$key"
    echo "cause=$cause"
    echo "ref=$ref"
    echo "sha256=$sha"
    echo "bytes=$bytes"
  } > "$tmp/manifest"
  mv "$tmp" "$spool/items/$id" || return 2
  for sub in $(ho_subscribers_of "$type"); do
    ho_deliver "$id" "$sub"
  done
  echo "ok $id"
}

# --- deliveries --------------------------------------------------------------

# ho_reconcile <ring> <now epoch>
# 1. every item of a type this ring consumes, published since the ring started
#    consuming it, has a delivery record;
# 2. every lease that outlived its lease_until goes back to ready (or dead).
ho_reconcile() {
  local ring="$1" now="$2" spool ddir t since m id ts f until max since_ts
  spool=$(ho_spool)
  ddir="$spool/deliveries/$ring"
  mkdir -p "$ddir"
  for t in $(ho_ring_types "$RINGS_HOME/$ring" CONSUMES); do
    since="$ddir/.since.$t"
    if [ ! -f "$since" ]; then
      ho_now > "$since.tmp.$$"
      mv -f "$since.tmp.$$" "$since"
    fi
    for m in "$spool"/items/*/manifest; do
      [ -f "$m" ] || continue
      [ "$(ho_kv_get "$m" type)" = "$t" ] || continue
      ts=$(ho_kv_get "$m" ts)
      # RFC3339 UTC strings sort as time; a string compare is exact here. The
      # marker has one-second resolution, and the boundary second counts as
      # after it: a new subscriber may see one extra item from that second,
      # while an item whose record was lost can always be reconciled.
      since_ts=$(cat "$since")
      [ "$ts" \< "$since_ts" ] && continue
      id=$(ho_kv_get "$m" id)
      ho_deliver "$id" "$ring"
    done
  done
  max=$(conf_get "$RINGS_HOME/$ring" MAX_ATTEMPTS 3)
  for f in "$ddir"/[0-9]*; do
    [ -f "$f" ] || continue
    [ "$(ho_kv_get "$f" state)" = "leased" ] || continue
    until=$(ho_kv_get "$f" lease_until_epoch)
    case "$until" in '' | *[!0-9]*) until=0 ;; esac
    [ "$until" -lt "$now" ] || continue
    ho_release_one "$f" "$max" "lease expired"
  done
}

# ho_lease <ring> <run> <max items> <timeout s> <in dir>
# Oldest ready records first (ids sort by time). Prints TSV: id, type, from,
# attempt (1-based), max. A payload whose checksum disagrees with its manifest
# is skipped, not leased; rings trace reports it.
ho_lease() {
  local ring="$1" run="$2" maxn="$3" timeout_s="$4" indir="$5"
  local spool ddir f n id m max untile attempts
  spool=$(ho_spool)
  ddir="$spool/deliveries/$ring"
  n=0
  max=$(conf_get "$RINGS_HOME/$ring" MAX_ATTEMPTS 3)
  untile=$(( $(date +%s) + timeout_s + 300 ))
  for f in "$ddir"/[0-9]*; do
    [ -f "$f" ] || continue
    [ "$n" -lt "$maxn" ] || break
    [ "$(ho_kv_get "$f" state)" = "ready" ] || continue
    id=$(basename "$f")
    m="$spool/items/$id/manifest"
    [ -f "$m" ] || continue
    [ "$(ho_sha256 "$spool/items/$id/payload")" = "$(ho_kv_get "$m" sha256)" ] || continue
    ho_kv_set "$f" state leased
    ho_kv_set "$f" leased_by "$run"
    ho_kv_set "$f" lease_until_epoch "$untile"
    ho_kv_set "$f" lease_until "$(ho_epoch_to_iso "$untile")"
    cp "$spool/items/$id/payload" "$indir/$id.json"
    attempts=$(ho_kv_get "$f" attempts)
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$(ho_kv_get "$m" type)" "$(ho_kv_get "$m" from)" "$((attempts + 1))" "$max"
    n=$((n + 1))
  done
}

# ho_decide <ring> <run> <accept|reject> <id> <note> — prints "ok" or "invalid <why>".
ho_decide() {
  local ring="$1" run="$2" verb="$3" id="$4" note="$5" f
  f="$(ho_spool)/deliveries/$ring/$id"
  [ -f "$f" ] || { echo "invalid $id is not a delivery for $ring"; return 0; }
  if [ "$(ho_kv_get "$f" state)" != "leased" ] || [ "$(ho_kv_get "$f" leased_by)" != "$run" ]; then
    echo "invalid $id was not leased to this run"; return 0
  fi
  case "$verb" in
    accept) ho_kv_set "$f" state accepted ;;
    reject) ho_kv_set "$f" state rejected ;;
    *) echo "invalid decision $verb"; return 0 ;;
  esac
  ho_kv_set "$f" ended "$(ho_now)"
  ho_kv_set "$f" note "$note"
  ho_kv_set "$f" decided_by "$run"
  echo ok
}

# ho_release_one <record> <max> <why> — a lease that ended without a decision.
ho_release_one() {
  local f="$1" max="$2" a
  a=$(ho_kv_get "$f" attempts)
  case "$a" in '' | *[!0-9]*) a=0 ;; esac
  a=$((a + 1))
  ho_kv_set "$f" attempts "$a"
  ho_kv_set "$f" leased_by ""
  ho_kv_set "$f" lease_until ""
  ho_kv_set "$f" lease_until_epoch ""
  if [ "$a" -ge "$max" ]; then
    ho_kv_set "$f" state dead
    ho_kv_set "$f" ended "$(ho_now)"
    ho_kv_set "$f" note "$3; dead after $a attempts"
  else
    ho_kv_set "$f" state ready
  fi
}

# ho_release_run <ring> <run> — everything still leased to this run.
ho_release_run() {
  local ring="$1" run="$2" f max
  max=$(conf_get "$RINGS_HOME/$ring" MAX_ATTEMPTS 3)
  for f in "$(ho_spool)/deliveries/$ring"/[0-9]*; do
    [ -f "$f" ] || continue
    [ "$(ho_kv_get "$f" state)" = "leased" ] || continue
    [ "$(ho_kv_get "$f" leased_by)" = "$run" ] || continue
    ho_release_one "$f" "$max" "no decision"
  done
}

# ho_retry <id> <ring> — dead → ready, attempts reset; or a fresh record.
# Only a dead delivery is retried. Resetting a leased one would hand the same
# work to two runs at once, and resetting an accepted one would repeat an
# action already taken in the world; both are refused.
ho_retry() {
  local f state
  f="$(ho_spool)/deliveries/$2/$1"
  [ -f "$(ho_spool)/items/$1/manifest" ] || { echo "no item $1"; return 1; }
  if [ -f "$f" ]; then
    state=$(ho_kv_get "$f" state)
    if [ "$state" != "dead" ]; then
      echo "refused $1 is $state at $2, not dead"; return 1
    fi
    ho_kv_set "$f" state ready
    ho_kv_set "$f" attempts 0
    ho_kv_set "$f" leased_by ""
    ho_kv_set "$f" lease_until ""
    ho_kv_set "$f" lease_until_epoch ""
    ho_kv_set "$f" ended ""
    ho_kv_set "$f" note "retried $(ho_now)"
  else
    ho_deliver "$1" "$2"
    ho_kv_set "$f" note "handed to $2 by rings retry $(ho_now)"
  fi
  echo "ready $1 for $2"
}

# --- the run -----------------------------------------------------------------

# ho_prompt_block <ring dir> <inbox tsv> — the HANDOFFS text appended to the prompt.
ho_prompt_block() {
  local dir="$1" inbox="$2" n emits id type from att max
  n=0
  [ -n "$inbox" ] && n=$(printf '%s\n' "$inbox" | grep -c .)
  emits=$(ho_ring_types "$dir" EMITS | tr '\n' ' ' | sed 's/ $//')
  printf '\n\n===============================================================================\n'
  printf 'HANDOFFS\n'
  printf '===============================================================================\n'
  if [ "$n" -eq 0 ]; then
    printf 'Inbox: nothing is waiting for this ring.\n'
  else
    printf 'Inbox: %s item(s) leased to this run. Payloads are in in/.\n' "$n"
    while IFS="$(printf '\t')" read -r id type from att max; do
      [ -n "$id" ] || continue
      printf '  %s  %s  from %s  attempt %s of %s  in/%s.json\n' "$id" "$type" "$from" "$att" "$max" "$id"
    done <<INBOX
$inbox
INBOX
    printf '\nAn item on attempt 2 or more was put in front of a previous run that did not\n'
    printf 'decide it. Before repeating any action in the world for such an item, check\n'
    printf 'whether that action already happened.\n\n'
    printf 'Decide every item. Write one line per decision to out/handoffs:\n'
    printf '  accept <id> <note>         you acted on it, or it needed no action\n'
    printf '  reject <id> <reason>       it does not qualify; the reason goes back to the producer\n'
    printf 'An item you write nothing about returns to the queue and counts as an attempt.\n'
  fi
  if [ -n "$emits" ]; then
    printf '\nTo hand work on, write the payload to a file under out/emit/ and add one line\n'
    printf 'to out/handoffs:\n'
    printf '  emit <type> key=<natural key> [cause=<inbox id>] [ref=<external id or URL>] file=<path>\n'
    printf 'Values of key=, cause=, ref= and file= cannot contain spaces; encode a space as %%20 or -.\n'
    printf 'You may emit: %s\n' "$emits"
  fi
}

# ho_normalise_line <line> — what an agent actually writes to out/handoffs.
# The prompt block shows the verbs indented, models like to bullet a list, and a
# file that took a trip through Windows carries a trailing carriage return. None
# of those change what the line means, so none of them make it invalid.
ho_normalise_line() {
  printf '%s' "$1" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/^[-*] *//'
}

# ho_settle <ring dir> <ring> <run> <started> <rc> <verdict> <inbox tsv>
# After the agent: publish candidates, then apply decisions, then release what
# is still leased. That order is deliberate — see docs/handoffs.md, "What the
# runner does". Writes runs/<run>.receipt and prints the ledger fragment.
ho_settle() {
  local dir="$1" ring="$2" run="$3" started="$4" rc="$5" verdict="$6" inbox="$7"
  local receipt hf line verb id type key cause ref file tok res rest bad
  local nin na nr ne ni att sha
  receipt="$dir/runs/$run.receipt"
  hf="$dir/out/handoffs"
  nin=0; na=0; nr=0; ne=0; ni=0
  mkdir -p "$dir/runs"
  {
    echo "run=$run"
    echo "ring=$ring"
    echo "started=$started"
    echo "ended=$(ho_now)"
    echo "rc=$rc"
    echo "verdict=$verdict"
    [ -f "$dir/.prompt" ] && echo "prompt_sha256=$(ho_sha256 "$dir/.prompt")"
  } > "$receipt"

  while IFS="$(printf '\t')" read -r id type rest att rest; do
    [ -n "$id" ] || continue
    nin=$((nin + 1))
    sha=$(ho_kv_get "$(ho_spool)/items/$id/manifest" sha256)
    echo "in=$id $sha attempt=$att" >> "$receipt"
  done <<INBOX
$inbox
INBOX

  if [ -f "$hf" ]; then
    # 1. publish. `read` returns non-zero on an unterminated last line, so a run
    #    killed mid-write cannot publish half a candidate.
    while IFS= read -r line; do
      line=$(ho_normalise_line "$line")
      [ -n "$line" ] || continue
      case "$line" in emit\ *) ;; *) continue ;; esac
      set -f
      # shellcheck disable=SC2086
      set -- $line
      set +f
      type="${2:-}"
      if [ $# -ge 2 ]; then shift 2; else set --; fi
      key=""; cause=""; ref=""; file=""; bad=""
      for tok in "$@"; do
        case "$tok" in
          key=*)   key=${tok#key=} ;;
          cause=*) cause=${tok#cause=} ;;
          ref=*)   ref=${tok#ref=} ;;
          file=*)  file=${tok#file=} ;;
          *)       bad="unexpected token '$tok' — key=, cause=, ref= and file= values cannot contain spaces" ;;
        esac
      done
      if [ -n "$bad" ]; then
        ni=$((ni + 1)); echo "invalid=$line — $bad" >> "$receipt"; continue
      fi
      case "$file" in '' ) file="$dir/out/emit/.missing" ;; /*) ;; *) file="$dir/$file" ;; esac
      res=$(ho_publish "$ring" "$run" "$type" "$key" "$cause" "$ref" "$file")
      case "$res" in
        ok\ *) ne=$((ne + 1)); echo "emit=$type key=$key -> ${res#ok }" >> "$receipt" ;;
        *)     ni=$((ni + 1)); echo "invalid=$line — ${res#refused }" >> "$receipt" ;;
      esac
    done < "$hf"

    # 2. decisions
    while IFS= read -r line; do
      line=$(ho_normalise_line "$line")
      case "$line" in
        '' | emit\ *) continue ;;
        accept\ * | reject\ *) ;;
        *) ni=$((ni + 1)); echo "invalid=$line — not accept, reject or emit" >> "$receipt"; continue ;;
      esac
      set -f
      # shellcheck disable=SC2086
      set -- $line
      set +f
      verb="$1"; id="${2:-}"
      if [ $# -ge 2 ]; then shift 2; else set --; fi
      rest="$*"
      res=$(ho_decide "$ring" "$run" "$verb" "$id" "$rest")
      if [ "$res" = "ok" ]; then
        if [ "$verb" = "accept" ]; then
          na=$((na + 1)); echo "accepted=$id $rest" >> "$receipt"
        else
          nr=$((nr + 1)); echo "rejected=$id $rest" >> "$receipt"
        fi
      else
        ni=$((ni + 1)); echo "invalid=$line — ${res#invalid }" >> "$receipt"
      fi
    done < "$hf"
  fi

  # 3. release everything this run was handed and did not decide
  ho_release_run "$ring" "$run"

  echo "counts=in:$nin accepted:$na rejected:$nr emitted:$ne invalid:$ni" >> "$receipt"
  printf '"handoffs": {"in": %s, "accepted": %s, "rejected": %s, "emitted": %s, "invalid": %s}' \
    "$nin" "$na" "$nr" "$ne" "$ni"
}

# --- queries -----------------------------------------------------------------

ho_json_str() { printf '"%s"' "$(ring_json_escape "$1")"; }

# TSV fields are read back with IFS=<tab>, which is whitespace IFS: an empty
# field between two tabs collapses and shifts every later column. Producers
# write "-" for an empty field; ho_dash turns it back into "".
ho_dash() { if [ "$1" = "-" ]; then printf ''; else printf '%s' "$1"; fi; }

ho_json_or_null() { if [ -z "$1" ] || [ "$1" = "-" ]; then printf 'null'; else ho_json_str "$1"; fi; }

# ho_scan_items — TSV: id, type, from, run, ts, key, cause, ref, sha256 (sorted by id = by time)
ho_scan_items() {
  local m id type from run ts key cause ref sha
  for m in "$(ho_spool)"/items/*/manifest; do
    [ -f "$m" ] || continue
    id=$(ho_kv_get "$m" id); type=$(ho_kv_get "$m" type); from=$(ho_kv_get "$m" from); run=$(ho_kv_get "$m" run)
    ts=$(ho_kv_get "$m" ts); key=$(ho_kv_get "$m" key); cause=$(ho_kv_get "$m" cause); ref=$(ho_kv_get "$m" ref)
    sha=$(ho_kv_get "$m" sha256)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$id" "$type" "$from" "$run" "$ts" "$key" "${cause:--}" "${ref:--}" "$sha"
  done
}

# ho_scan_deliveries — TSV: ring, id, type, from, state, attempts, created, ended, note
ho_scan_deliveries() {
  local spool ddir f ring id m type from state attempts created ended note
  spool=$(ho_spool)
  for ddir in "$spool"/deliveries/*; do
    [ -d "$ddir" ] || continue
    ring=$(basename "$ddir")
    for f in "$ddir"/[0-9]*; do
      [ -f "$f" ] || continue
      id=$(basename "$f")
      m="$spool/items/$id/manifest"
      type=$(ho_kv_get "$m" type 2>/dev/null); from=$(ho_kv_get "$m" from 2>/dev/null)
      state=$(ho_kv_get "$f" state); attempts=$(ho_kv_get "$f" attempts); created=$(ho_kv_get "$f" created)
      ended=$(ho_kv_get "$f" ended); note=$(ho_kv_get "$f" note)
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$ring" "$id" "${type:--}" "${from:--}" "$state" "$attempts" "$created" "${ended:--}" "${note:--}"
    done
  done
}

# ho_iso_to_epoch <rfc3339 utc> — GNU first, BSD second; 0 when unparseable.
ho_iso_to_epoch() {
  local e
  e=$(date -u -d "$1" +%s 2>/dev/null) || e=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null) || e=""
  case "$e" in '' | *[!0-9]*) echo 0 ;; *) echo "$e" ;; esac
}

# ho_producers_of <type> — ring names whose EMITS lists the type.
ho_producers_of() {
  local d t
  for d in $(each_ring); do
    for t in $(ho_ring_types "$d" EMITS); do
      [ "$t" = "$1" ] && basename "$d"
    done
  done
}

# ho_type_summary <type> <items tsv> <deliveries tsv> — one TSV line:
# type sink outcome items ready leased accepted rejected dead oldest_ready_seconds gated
ho_type_summary() {
  local t="$1" items="$2" dels="$3" sink outcome n ready leased acc rej dead oldest now created gated
  sink=$(ho_type_sink "$t")
  outcome=0; ho_type_is_outcome "$t" && outcome=1
  n=$(printf '%s\n' "$items" | awk -F'\t' -v t="$t" '$2 == t' | grep -c .)
  ready=$(printf '%s\n' "$dels" | awk -F'\t' -v t="$t" '$3 == t && $5 == "ready"' | grep -c .)
  leased=$(printf '%s\n' "$dels" | awk -F'\t' -v t="$t" '$3 == t && $5 == "leased"' | grep -c .)
  acc=$(printf '%s\n' "$dels" | awk -F'\t' -v t="$t" '$3 == t && $5 == "accepted"' | grep -c .)
  rej=$(printf '%s\n' "$dels" | awk -F'\t' -v t="$t" '$3 == t && $5 == "rejected"' | grep -c .)
  dead=$(printf '%s\n' "$dels" | awk -F'\t' -v t="$t" '$3 == t && $5 == "dead"' | grep -c .)
  oldest=""
  created=$(printf '%s\n' "$dels" | awk -F'\t' -v t="$t" '$3 == t && $5 == "ready" { print $7 }' | sort | head -1)
  if [ -n "$created" ]; then
    now=$(date +%s)
    oldest=$(( now - $(ho_iso_to_epoch "$created") ))
  fi
  gated=0; [ -x "$RINGS_HOME/types/$t/accept.sh" ] && gated=1
  # oldest is "-" when nothing is ready: an empty TSV field would shift gated left (see ho_dash).
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$t" "$sink" "$outcome" "$n" "$ready" "$leased" "$acc" "$rej" "$dead" "${oldest:--}" "$gated"
}

# ho_events — TSV: ts, kind, ring, id, type, text — unsorted; callers sort.
ho_events() {
  local items dels id type from run ts key cause ref sha ring state att created ended note d n line csuf nsuf
  items=$(ho_scan_items)
  dels=$(ho_scan_deliveries)
  while IFS="$(printf '\t')" read -r id type from run ts key cause ref sha; do
    [ -n "$id" ] || continue
    csuf=""; [ "$cause" != "-" ] && csuf=" cause=$cause"
    printf '%s\tpublished\t%s\t%s\t%s\t%s published %s %s key=%s%s\n' \
      "$ts" "$from" "$id" "$type" "$from" "$type" "$id" "$key" "$csuf"
  done <<ITEMS
$items
ITEMS
  while IFS="$(printf '\t')" read -r ring id type from state att created ended note; do
    [ -n "$id" ] || continue
    nsuf=""; [ "$note" != "-" ] && nsuf=": $note"
    case "$state" in
      accepted | rejected | dead) printf '%s\t%s\t%s\t%s\t%s\t%s %s %s%s\n' "$ended" "$state" "$ring" "$id" "$type" "$ring" "$state" "$id" "$nsuf" ;;
    esac
  done <<DELS
$dels
DELS
  for d in $(each_ring); do
    n=$(basename "$d")
    [ -s "$d/ledger.jsonl" ] || continue
    while IFS= read -r line; do
      ended=$(printf '%s' "$line" | sed -n 's/.*"ended": *"\([^"]*\)".*/\1/p')
      state=$(printf '%s' "$line" | sed -n 's/.*"verdict": *"\([^"]*\)".*/\1/p')
      run=$(printf '%s' "$line" | sed -n 's/.*"run": *"\([^"]*\)".*/\1/p')
      [ -n "$ended" ] || continue
      printf '%s\trun\t%s\t%s\t-\t%s run %s%s\n' "$ended" "$n" "${run:--}" "$n" "$state" "${run:+ ($run)}"
    done < "$d/ledger.jsonl"
  done
}
