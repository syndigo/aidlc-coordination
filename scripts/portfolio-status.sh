#!/usr/bin/env bash
# shellcheck shell=bash
#
# portfolio-status.sh — cross-pillar dashboard for the Portfolio Orchestrator.
#
# Reads allocations/<product>.yml#pillars[] + single_writer_files +
# anchor_dependencies and renders: parallelism vs cap, critical path,
# blocked pillars, lock contention map.
#
# With --update-stats, also writes the .stats: block back into the YAML
# (computed_at, in_flight_pillar_count, longest_ttl_expiry, critical_path_anchor,
# blocked_pillars). This is the only mutation this script makes.
#
# Usage:
#   portfolio-status.sh [--product <name>] [--json] [--update-stats]
#   portfolio-status.sh --help
#   portfolio-status.sh --version

# shellcheck source=_lib.sh
. "$(dirname "$0")/_lib.sh"

PRODUCT="$DEFAULT_PRODUCT"
EMIT_JSON=0
UPDATE_STATS=0

print_help() {
  cat <<'USAGE'
portfolio-status.sh — cross-pillar dashboard.

Optional:
  --product <name>     Default: ugc-platform
  --json               Emit JSON instead of human format
  --update-stats       Compute and write the .stats: block to the allocation YAML
  --help, --version
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --product)      PRODUCT="$2"; shift 2 ;;
    --json)         EMIT_JSON=1; shift ;;
    --update-stats) UPDATE_STATS=1; shift ;;
    --help|-h)      print_help; exit 0 ;;
    --version)      print_version; exit 0 ;;
    *) log_err "Unknown argument: $1"; print_help; exit 2 ;;
  esac
done

require_tools

YML="$(resolve_yml_path "$PRODUCT")"

# Profile lookup (D-017). The portfolio cap lives in the profile.
PROFILE_REF="$(yq -r '.profile_ref // ""' "$YML")"
MAX_CONCURRENT_PILLARS=""
if [ -n "$PROFILE_REF" ] && [ -f "$REPO_ROOT/$PROFILE_REF" ]; then
  MAX_CONCURRENT_PILLARS="$(yq -r '.orchestration.max_concurrent_pillars_in_flight // ""' "$REPO_ROOT/$PROFILE_REF")"
fi
if [ -z "$MAX_CONCURRENT_PILLARS" ] || [ "$MAX_CONCURRENT_PILLARS" = "null" ]; then
  MAX_CONCURRENT_PILLARS="unset"
fi

# Confirm there's a pillars block at all.
PILLAR_COUNT="$(yq -r '(.pillars // []) | length' "$YML")"
if [ "$PILLAR_COUNT" -eq 0 ]; then
  log_err "No pillars[] block in $YML"
  log_err "  This product has not adopted the pillar tier yet."
  log_err "  Add a pillars[] block to use the Portfolio Orchestrator."
  exit 2
fi

# ----- compute summary ------------------------------------------------------

IN_FLIGHT_PILLARS="$(yq -r '[.pillars[] | select(.status == "in_flight")] | length' "$YML")"
BLOCKED_PILLARS="$(yq -r '[.pillars[] | select(.status == "blocked")] | length' "$YML")"
SHIPPED_PILLARS="$(yq -r '[.pillars[] | select(.status == "shipped")] | length' "$YML")"
NOT_STARTED_PILLARS="$(yq -r '[.pillars[] | select(.status == "not_started")] | length' "$YML")"

# Sum of in_flight FR counts across all pillars.
TOTAL_IN_FLIGHT_FRS="$(yq -r '[.pillars[].in_flight_frs[]?] | length' "$YML")"

# Longest TTL expiry across all reservations + locks.
# yq v4 doesn't accept jq's // fallback or `last`; emit the sorted list and
# pick the final non-empty line in shell.
LONGEST_TTL="$(yq -r '
  [
    (.flyway.reserved[]?.expires_at),
    (.model_registry.pending[]?.expires_at),
    (.single_writer_files[]?.until)
  ]
  | map(select(. != null and . != ""))
  | sort
  | .[]
' "$YML" 2>/dev/null | tail -1)"

# Critical-path anchor: the not_started or in_flight anchor with the most
# downstream consumers. Tie-broken by alphabetical. Compute via two passes
# in shell because yq v4 lacks jq's `first`, sort_by-with-multiple-keys, and
# // fallback semantics.
CRITICAL_PATH_ANCHOR=""
CRIT_LINE="$(yq -r '
  .anchor_dependencies[]
  | select(.status == "not_started" or .status == "in_flight")
  | ((.consumers // []) | length | tostring) + " " + .anchor
' "$YML" 2>/dev/null | sort -k1,1nr -k2,2 | head -1)"
if [ -n "$CRIT_LINE" ]; then
  CRITICAL_PATH_ANCHOR="${CRIT_LINE#* }"
fi

# Pillars that are blocked (status==blocked OR have non-empty blocked_on).
BLOCKED_PILLAR_LETTERS="$(yq -r '
  [.pillars[]
    | select(.status == "blocked" or ((.blocked_on // []) | length > 0))
    | .letter
  ] | join(",")
' "$YML")"

# ----- update stats block ---------------------------------------------------

if [ "$UPDATE_STATS" = "1" ]; then
  TMP="$(mktemp)"
  trap 'rm -f "$TMP"' EXIT
  NOW="$(iso_now)"
  # Build the blocked_pillars array from the comma-joined list.
  if [ -z "$BLOCKED_PILLAR_LETTERS" ]; then
    BLOCKED_JSON="[]"
  else
    # Convert "A,B,C" -> ["A","B","C"]
    BLOCKED_JSON="["
    sep=""
    OLD_IFS="$IFS"
    IFS=","
    for letter in $BLOCKED_PILLAR_LETTERS; do
      BLOCKED_JSON="${BLOCKED_JSON}${sep}\"${letter}\""
      sep=","
    done
    IFS="$OLD_IFS"
    BLOCKED_JSON="${BLOCKED_JSON}]"
  fi

  # Pass values through env() (yq v4 does not support jq's --arg).
  export STATS_NOW="$NOW"
  export STATS_IN_FLIGHT_PILLARS="$IN_FLIGHT_PILLARS"
  export STATS_TOTAL_FRS="$TOTAL_IN_FLIGHT_FRS"
  export STATS_LONGEST_TTL="$LONGEST_TTL"
  export STATS_CRITICAL="$CRITICAL_PATH_ANCHOR"
  export STATS_BLOCKED="$BLOCKED_JSON"
  # env() in yq v4 parses the value as YAML, so a JSON-array string in
  # STATS_BLOCKED is already an array (no from_json needed). Numbers come
  # in as strings, so coerce via the explicit Int parsing yq supports.
  yq "
    .stats = {
      \"computed_at\": strenv(STATS_NOW),
      \"in_flight_pillar_count\": (strenv(STATS_IN_FLIGHT_PILLARS) | to_number),
      \"in_flight_section_count\": (strenv(STATS_TOTAL_FRS) | to_number),
      \"longest_ttl_expiry\": strenv(STATS_LONGEST_TTL),
      \"critical_path_anchor\": strenv(STATS_CRITICAL),
      \"blocked_pillars\": env(STATS_BLOCKED)
    }
  " "$YML" > "$TMP"

  # Drop empty longest_ttl_expiry -- schema rejects "" against the timestamp
  # pattern. The field is optional so omit it entirely when nothing is reserved.
  if [ -z "$LONGEST_TTL" ]; then
    yq -i 'del(.stats.longest_ttl_expiry)' "$TMP"
  fi
  if [ -z "$CRITICAL_PATH_ANCHOR" ]; then
    yq -i 'del(.stats.critical_path_anchor)' "$TMP"
  fi

  cp "$TMP" "$YML"
  log_info "Updated .stats block in $YML"

  # Commit + push if we're in a git repo (best-effort).
  if ( cd "$REPO_ROOT" && git rev-parse --git-dir >/dev/null 2>&1 ); then
    git_pull_rebase || log_warn "rebase skipped"
    git_commit_and_push "chore(stats): refresh portfolio stats for $PRODUCT" "$YML" || \
      log_warn "stats commit/push failed (continuing)"
  fi
fi

# ----- JSON output ----------------------------------------------------------

if [ "$EMIT_JSON" = "1" ]; then
  export PROD="$PRODUCT"
  export MAX_PIL="$MAX_CONCURRENT_PILLARS"
  yq -o=json "
    {
      \"product\": env(PROD),
      \"max_concurrent_pillars_in_flight\": env(MAX_PIL),
      \"pillars\": [
        .pillars[] | {
          \"letter\": .letter,
          \"name\": .name,
          \"status\": .status,
          \"in_flight_count\": ((.in_flight_frs // []) | length),
          \"shipped_count\": ((.shipped_frs // []) | length),
          \"backlog_count\": ((.fr_backlog // []) | length),
          \"blocked_on\": (.blocked_on // [])
        }
      ],
      \"locks_held\": [
        .single_writer_files[] | select(.held_by != \"none\" and .held_by != null) | {
          \"file\": .file, \"held_by\": .held_by, \"until\": .until
        }
      ],
      \"anchors_unshipped\": [
        .anchor_dependencies[] | select(.status != \"shipped\") | {
          \"anchor\": .anchor,
          \"section\": .section,
          \"consumer_count\": ((.consumers // []) | length)
        }
      ],
      \"stats\": .stats
    }
  " "$YML"
  exit 0
fi

# ----- human output ---------------------------------------------------------

over_cap_marker=""
if [ "$MAX_CONCURRENT_PILLARS" != "unset" ] && [ "$IN_FLIGHT_PILLARS" -gt "$MAX_CONCURRENT_PILLARS" ]; then
  over_cap_marker="  ⚠ OVER CAP"
fi

cat <<EOF
=================================================
 Portfolio — $PRODUCT
=================================================
 in_flight pillars:    $IN_FLIGHT_PILLARS / $MAX_CONCURRENT_PILLARS$over_cap_marker
 blocked pillars:      $BLOCKED_PILLARS
 shipped pillars:      $SHIPPED_PILLARS
 not-started pillars:  $NOT_STARTED_PILLARS
 total in-flight FRs:  $TOTAL_IN_FLIGHT_FRS
 critical_path:        ${CRITICAL_PATH_ANCHOR:-<none>}
 longest TTL:          ${LONGEST_TTL:-<none>}

--- Pillar status ---
EOF
yq -r '
  .pillars[]
  | "  " + .letter + "  " + .status
    + "  in_flight=" + (((.in_flight_frs // []) | length) | tostring)
    + "  shipped="   + (((.shipped_frs   // []) | length) | tostring)
    + "  backlog="   + (((.fr_backlog    // []) | length) | tostring)
    + "  blocked_on=" + (((.blocked_on   // []) | length) | tostring)
' "$YML"

cat <<EOF

--- Lock contention (active single-writer holds) ---
EOF
HELD_COUNT="$(yq -r '[.single_writer_files[] | select(.held_by != "none" and .held_by != null)] | length' "$YML")"
if [ "$HELD_COUNT" -eq 0 ]; then
  echo "  (none)"
else
  yq -r '
    .single_writer_files[]
    | select(.held_by != "none" and .held_by != null)
    | "  " + .file + "\n    held_by: " + .held_by + "  until: " + (.until // "n/a")
  ' "$YML"
fi

cat <<EOF

--- Cross-pillar anchors (unshipped) ---
EOF
ANCHOR_COUNT="$(yq -r '[.anchor_dependencies[] | select(.status != "shipped")] | length' "$YML")"
if [ "$ANCHOR_COUNT" -eq 0 ]; then
  echo "  (none — all anchors shipped)"
else
  yq -r '
    .anchor_dependencies[]
    | select(.status != "shipped")
    | "  " + .anchor + " (section " + .section + ", " + .status + ")"
      + "  consumers=" + (((.consumers // []) | length) | tostring)
      + "  -- " + (.description // "")
  ' "$YML"
fi

cat <<EOF

--- Pillars with blocked_on entries ---
EOF
yq -r '
  .pillars[]
  | select((.blocked_on // []) | length > 0)
  | "  Pillar " + .letter + ":\n" + ((.blocked_on // []) | map("    - " + .) | join("\n"))
' "$YML" | grep -v '^$' || echo "  (none)"

if [ "$UPDATE_STATS" = "1" ]; then
  cat <<EOF

--- Stats block (just written) ---
EOF
  yq -r '.stats // "(no stats block)"' "$YML"
fi

echo "================================================="
