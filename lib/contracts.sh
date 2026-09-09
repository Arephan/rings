# contracts.sh — what one ring hands the next, and whether that handoff is real.
#
# `NEEDS` (see docs/chains.md) is a drawing: it says a ring reads another one.
# A contract is the same claim made checkable — a named file, a shelf life, and
# the rings that consume it. `rings contracts` then goes and looks. A consumer
# only counts as wired if the consuming ring's own files mention the carrier by
# name; a declaration nobody reads is the failure this exists to catch.

# --- parsing -----------------------------------------------------------------

# contract_field <spec> <n> — the nth colon-separated field, empty if absent.
contract_field() { printf '%s' "$1" | cut -d: -f"$2"; }

# contract_emits <ring dir> — one TSV line per emit: name, relpath, format, ttl_hours
contract_emits() {
  local dir="$1" spec name rel fmt ttl
  for spec in $(conf_get "$dir" EMITS ""); do
    name=$(contract_field "$spec" 1)
    rel=$(contract_field "$spec" 2)
    fmt=$(contract_field "$spec" 3)
    ttl=$(contract_field "$spec" 4)
    [ -n "$name" ] && [ -n "$rel" ] || continue
    if [ -z "$fmt" ]; then
      case "$rel" in
        *.jsonl) fmt="jsonl" ;;
        *.json)  fmt="json" ;;
        *.md)    fmt="markdown" ;;
        *)       fmt="text" ;;
      esac
    fi
    printf '%s\t%s\t%s\t%s\n' "$name" "$rel" "$fmt" "${ttl:-0}"
  done
}

# contract_consumes <ring dir> — one TSV line per consume: producer, emit name, filter
# CONSUMES entries look like  producer.emit  or  producer.emit:key=value
contract_consumes() {
  local dir="$1" spec ref filter
  for spec in $(conf_get "$dir" CONSUMES ""); do
    ref=${spec%%:*}
    filter=""
    case "$spec" in *:*) filter=${spec#*:} ;; esac
    case "$ref" in *.*) : ;; *) continue ;; esac
    printf '%s\t%s\t%s\n' "${ref%%.*}" "${ref#*.}" "$filter"
  done
}

# --- verification ------------------------------------------------------------

# contract_text <ring dir> — every file in a ring that could name a carrier.
contract_text() {
  local dir="$1" f
  # ring.conf is included except for its own CONSUMES lines: the declaration is
  # the claim, and a claim cannot be its own evidence. Everything else counts —
  # the runbook is what the agent is told, the scripts are what it runs.
  [ -f "$dir/ring.conf" ] && grep -v '^[[:space:]]*CONSUMES=' "$dir/ring.conf"
  for f in "$dir"/RUNBOOK.md "$dir"/*.md "$dir"/*.sh "$dir"/hooks/*.sh; do
    [ -f "$f" ] && cat -- "$f"
  done 2>/dev/null
  return 0
}

# contract_wired <consumer dir> <carrier basename> — does that ring actually
# mention the file? A CONSUMES line is a promise; this is the evidence.
contract_wired() {
  # No pipeline here on purpose: this runs under `set -o pipefail`, where a
  # short-circuiting `grep -q` can SIGPIPE its producer and fail a true match.
  local text
  text=$(contract_text "$1")
  case "$text" in
    *"$2"*) return 0 ;;
  esac
  return 1
}

# contract_row_claimed <json row> <filter> — filter is key=value, or empty for all.
contract_row_claimed() {
  local row="$1" f="$2" k v
  [ -z "$f" ] && return 0
  k=${f%%=*}
  v=${f#*=}
  grep -qE "\"$k\"[[:space:]]*:[[:space:]]*\"?$v\"?([,}[:space:]]|\$)" <<ROW
$row
ROW
}

# contract_stranded <carrier> <filter>... — rows no wired consumer's filter claims.
# Prints "<stranded> <total>". This is the check that finds work a fleet is
# producing and silently dropping on the floor.
contract_stranded() {
  local file="$1" line f claimed n total
  shift
  n=0; total=0
  [ -s "$file" ] || { echo "0 0"; return 0; }
  while IFS= read -r line; do
    case "$line" in '') continue ;; esac
    total=$((total + 1))
    claimed=0
    for f in "$@"; do
      if contract_row_claimed "$line" "$f"; then claimed=1; break; fi
    done
    [ "$claimed" -eq 0 ] && n=$((n + 1))
  done < "$file"
  echo "$n $total"
}

# --- the scan ----------------------------------------------------------------

# contract_consumers_of <producer> <emit> — TSV: consuming ring, filter
contract_consumers_of() {
  local cd cn
  for cd in $(each_ring); do
    cn=$(basename "$cd")
    contract_consumes "$cd" | awk -F'\t' -v p="$1" -v e="$2" -v c="$cn" \
      '$1 == p && $2 == e { print c "\t" $3 }'
  done
}

# contracts_scan — one TSV record per declared emit, across every ring:
# producer, emit, carrier, relpath, format, ttl_hours, present, age_sec, rows,
# declared, wired, consumers, stranded, status, why
contracts_scan() {
  local d
  for d in $(each_ring); do
    contracts_scan_ring "$d"
  done
}

contracts_scan_ring() {
  local d n emits ename erel efmt ettl
  d="$1"
  n=$(basename "$d")
  emits=$(contract_emits "$d")
  [ -n "$emits" ] || return 0
  while IFS="$(printf '\t')" read -r ename erel efmt ettl; do
    [ -n "$ename" ] || continue
    contracts_scan_emit "$d" "$n" "$ename" "$erel" "$efmt" "$ettl"
  done <<EMITS
$emits
EMITS
}

contracts_scan_emit() {
  local d n ename erel efmt ettl
  d="$1"; n="$2"; ename="$3"; erel="$4"; efmt="$5"; ettl="$6"
  local carrier base present age rows cons cn cfilter
  local declared wired consumers filters stranded total status why

  carrier="$d/$erel"
  base=$(basename "$erel")
  present=0; age=0; rows="-"
  if [ -f "$carrier" ]; then
    present=1
    age=$(( $(date +%s) - $(ring_mtime "$carrier") ))
    [ "$efmt" = "jsonl" ] && rows=$(grep -c . "$carrier" 2>/dev/null | tr -d ' ')
  fi

  declared=0; wired=0; consumers=""; filters=""
  cons=$(contract_consumers_of "$n" "$ename")
  while IFS="$(printf '\t')" read -r cn cfilter; do
    [ -n "$cn" ] || continue
    declared=$((declared + 1))
    if contract_wired "$RINGS_HOME/$cn" "$base"; then
      wired=$((wired + 1))
      consumers="$consumers${consumers:+,}$cn${cfilter:+[$cfilter]}"
      filters="$filters $cfilter"
    else
      consumers="$consumers${consumers:+,}$cn(unwired)"
    fi
  done <<CONS
$cons
CONS

  stranded=0; total=0
  if [ "$present" -eq 1 ] && [ "$efmt" = "jsonl" ] && [ "$wired" -gt 0 ]; then
    # shellcheck disable=SC2086
    read -r stranded total <<STRAND
$(contract_stranded "$carrier" $filters)
STRAND
  fi

  status="flowing"; why=""
  if [ "$present" -eq 0 ]; then
    status="missing"; why="$n declares it emits $erel; the file is not there"
  elif [ "$declared" -eq 0 ]; then
    status="orphan"; why="written every run, and no ring consumes it"
  elif [ "$wired" -eq 0 ]; then
    status="orphan"; why="$declared ring(s) declare they consume it, none mentions $base"
  elif [ "$stranded" -gt 0 ]; then
    status="leaking"; why="$stranded of $total rows match no consumer filter"
  elif [ "$ettl" != "0" ] && [ "$age" -gt $((ettl * 3600)) ]; then
    status="stale"; why="$((age / 3600))h old, shelf life is ${ettl}h"
  elif [ "$wired" -lt "$declared" ]; then
    status="partial"; why="$((declared - wired)) declared consumer(s) never mention $base"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$n" "$ename" "$carrier" "$erel" "$efmt" "$ettl" "$present" "$age" "$rows" \
    "$declared" "$wired" "${consumers:--}" "$stranded" "$status" "$why"
}

# contracts_dangling — a CONSUMES that names an emit nobody declares.
contracts_dangling() {
  local d n cons cprod cname cfilter found pd names
  for d in $(each_ring); do
    n=$(basename "$d")
    cons=$(contract_consumes "$d")
    while IFS="$(printf '\t')" read -r cprod cname cfilter; do
      [ -n "$cprod" ] || continue
      found=0
      for pd in $(each_ring); do
        [ "$(basename "$pd")" = "$cprod" ] || continue
        names=$(contract_emits "$pd" | cut -f1)
        case "
$names
" in
          *"
$cname
"*) found=1 ;;
        esac
      done
      [ "$found" -eq 0 ] && printf '%s\t%s.%s\n' "$n" "$cprod" "$cname"
    done <<CONS
$cons
CONS
  done
}
