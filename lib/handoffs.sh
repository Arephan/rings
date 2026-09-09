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
  local spool id tmp sha bytes sub dup gate why drec
  spool=$(ho_spool)

  ho_type_declared "$type" || { echo "refused $type is not declared in any CHAIN_ line of rings.conf"; return 0; }
  ho_ring_emits "$ring" "$type" || { echo "refused $ring does not list $type in EMITS"; return 0; }
  [ -n "$key" ] || { echo "refused key= is required"; return 0; }
  [ -s "$payload" ] || { echo "refused payload $payload is missing or empty"; return 0; }
  if ho_type_is_outcome "$type" && [ -z "$ref" ]; then
    echo "refused $type is an outcome and needs ref= into the system where it happened"; return 0
  fi
  if [ -n "$cause" ]; then
    [ -f "$spool/items/$cause/manifest" ] || { echo "refused cause $cause is not a published item"; return 0; }
    drec="$spool/deliveries/$ring/$cause"
    if [ "$(ho_kv_get "$drec" leased_by 2>/dev/null)" != "$run" ] && [ "$(ho_kv_get "$drec" decided_by 2>/dev/null)" != "$run" ]; then
      echo "refused cause $cause was not leased to run $run of $ring"; return 0
    fi
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
