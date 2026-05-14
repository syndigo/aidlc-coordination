#!/usr/bin/env bash
# shellcheck shell=bash
#
# pillar-status.sh — single-pillar dashboard for the Pillar Orchestrator.
#
# Reads allocations/<product>.yml#pillars[<letter>] plus the relevant slices
# of single_writer_files / anchor_dependencies / flyway and renders a focused
# view: in-flight count vs cap, serial-chain status, lock contention forecast,
# blocked_on entries.
#
# Read-only. Does NOT mutate the registry.
#
# Usage:
#   pillar-status.sh --letter <A..Z> [--product <name>] [--json]
#   pillar-status.sh --help
#   pillar-status.sh --version

# shellcheck source=_lib.sh
. "$(dirname "$0")/_lib.sh"

PRODUCT="$DEFAULT_PRODUCT"
LETTER=""
EMIT_JSON=0

print_help() {
  cat <<'USAGE'
pillar-status.sh — pillar-scoped dashboard.

Required:
  --letter <A..Z>      Pillar letter (also the section letter)

Optional:
  --product <name>     Default: ugc-platform
  --json               Emit JSON instead of human format
  --help, --version
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --letter)  LETTER="$2"; shift 2 ;;
    --product) PRODUCT="$2"; shift 2 ;;
    --json)    EMIT_JSON=1; shift ;;
    --help|-h) print_help; exit 0 ;;
    --version) print_version; exit 0 ;;
    *) log_err "Unknown argument: $1"; print_help; exit 2 ;;
  esac
done

if [ -z "$LETTER" ]; then
  log_err "Missing required arg: --letter"
  exit 2
fi
validate_section "$LETTER"

require_tools

YML="$(resolve_yml_path "$PRODUCT")"

# Confirm the pillar exists in the YAML. If not, the product hasn't adopted
# the pillar tier yet — print a clear message instead of an empty dashboard.
pillar_exists="$(yq -r ".pillars[]? | select(.letter == \"$LETTER\") | .letter" "$YML")"
if [ -z "$pillar_exists" ]; then
  log_err "Pillar $LETTER not found in $YML (.pillars[])"
  log_err "  This product may not yet have a pillar tier defined."
  log_err "  Add a pillars[] block to the allocation YAML, or check the letter."
  exit 2
fi

# ----- gather data ----------------------------------------------------------

PILLAR_NAME="$(yq -r ".pillars[] | select(.letter == \"$LETTER\") | .name" "$YML")"
PILLAR_STATUS="$(yq -r ".pillars[] | select(.letter == \"$LETTER\") | .status" "$YML")"
PILLAR_MAX="$(yq -r ".pillars[] | select(.letter == \"$LETTER\") | .max_in_flight_frs // 2" "$YML")"
PILLAR_FREQ="$(yq -r ".pillars[] | select(.letter == \"$LETTER\") | .ship_frequency // \"unlimited\"" "$YML")"

IN_FLIGHT_COUNT="$(yq -r "(.pillars[] | select(.letter == \"$LETTER\") | .in_flight_frs // []) | length" "$YML")"
SHIPPED_COUNT="$(yq -r  "(.pillars[] | select(.letter == \"$LETTER\") | .shipped_frs   // []) | length" "$YML")"
BACKLOG_COUNT="$(yq -r  "(.pillars[] | select(.letter == \"$LETTER\") | .fr_backlog    // []) | length" "$YML")"

# ----- JSON output ----------------------------------------------------------

if [ "$EMIT_JSON" = "1" ]; then
  export LETTER
  yq -o=json "
    .pillars[] | select(.letter == env(LETTER)) | {
      \"letter\": .letter,
      \"name\": .name,
      \"status\": .status,
      \"in_flight_frs\": (.in_flight_frs // []),
      \"in_flight_count\": ((.in_flight_frs // []) | length),
      \"max_in_flight_frs\": (.max_in_flight_frs // 2),
      \"shipped_frs\": (.shipped_frs // []),
      \"fr_backlog\": (.fr_backlog // []),
      \"serial_chains\": (.serial_chains // []),
      \"blocked_on\": (.blocked_on // []),
      \"ship_frequency\": (.ship_frequency // \"unlimited\"),
      \"serial_with\": (.serial_with // [])
    }
  " "$YML"
  exit 0
fi

# ----- human output ---------------------------------------------------------

cat <<EOF
=================================================
 Pillar $LETTER — $PILLAR_NAME
=================================================
 status:           $PILLAR_STATUS
 in_flight_frs:    $IN_FLIGHT_COUNT / $PILLAR_MAX (cap)
 backlog:          $BACKLOG_COUNT
 shipped:          $SHIPPED_COUNT
 ship_frequency:   $PILLAR_FREQ

--- In-flight FRs ---
EOF
yq -r "(.pillars[] | select(.letter == \"$LETTER\") | .in_flight_frs // []) | .[] | \"  \" + ." "$YML" \
  | grep -v '^$' || echo "  (none)"

cat <<EOF

--- Backlog (next launchable first) ---
EOF
yq -r "(.pillars[] | select(.letter == \"$LETTER\") | .fr_backlog // []) | .[] | \"  \" + ." "$YML" \
  | grep -v '^$' || echo "  (none)"

cat <<EOF

--- Serial chains (intra-pillar) ---
EOF
SERIAL_COUNT="$(yq -r "(.pillars[] | select(.letter == \"$LETTER\") | .serial_chains // []) | length" "$YML")"
if [ "$SERIAL_COUNT" -eq 0 ]; then
  echo "  (none)"
else
  # For each chain, render predecessor -> successor with a (SHIPPED|PENDING) marker.
  # Ship-status is read from this pillar's shipped_frs OR any other pillar's shipped_frs
  # (since serial chains can cross pillars even though the chain block lives here).
  yq -r "
    (.pillars[] | select(.letter == \"$LETTER\") | .serial_chains // [])
    | .[]
    | (.chain | join(\" -> \")) + \"   \" + (.reason // \"\")
  " "$YML" | sed 's/^/  /'
  echo
  echo "  (run portfolio-status.sh to see ship status of each chain link)"
fi

cat <<EOF

--- blocked_on ---
EOF
yq -r "(.pillars[] | select(.letter == \"$LETTER\") | .blocked_on // []) | .[] | \"  \" + ." "$YML" \
  | grep -v '^$' || echo "  (none)"

cat <<EOF

--- Lock contention (single-writer files held by anyone) ---
EOF
HELD_COUNT="$(yq -r '[.single_writer_files[] | select(.held_by != "none" and .held_by != null)] | length' "$YML")"
if [ "$HELD_COUNT" -eq 0 ]; then
  echo "  (no active single-writer locks)"
else
  yq -r '
    .single_writer_files[]
    | select(.held_by != "none" and .held_by != null)
    | "  " + .file + "\n    held_by: " + .held_by + "  until: " + (.until // "n/a")
  ' "$YML"
fi

cat <<EOF

--- Cross-pillar anchor dependencies relevant to this pillar ---
EOF
# Show anchors WHERE this pillar is either the producer (.section == LETTER)
# or a consumer (.consumers[].section == LETTER).
PRODUCED="$(yq -r ".anchor_dependencies[] | select(.section == \"$LETTER\") | \"  PRODUCES \" + .anchor + \" (\" + .status + \"): \" + (.description // \"\")" "$YML")"
CONSUMED="$(yq -r ".anchor_dependencies[] | select(.consumers[]?.section == \"$LETTER\") | \"  CONSUMES \" + .anchor + \" (\" + .status + \"): \" + (.description // \"\")" "$YML")"
if [ -z "$PRODUCED" ] && [ -z "$CONSUMED" ]; then
  echo "  (none)"
else
  [ -n "$PRODUCED" ] && printf '%s\n' "$PRODUCED"
  [ -n "$CONSUMED" ] && printf '%s\n' "$CONSUMED"
fi

echo "================================================="
