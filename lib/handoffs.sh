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
