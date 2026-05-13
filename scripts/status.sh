#!/usr/bin/env bash
# shellcheck shell=bash
#
# status.sh — human-readable dashboard of the allocation registry.
#
# Usage:
#   status.sh [--product <name>] [--json]
#   status.sh --help
#   status.sh --version

# shellcheck source=_lib.sh
. "$(dirname "$0")/_lib.sh"

PRODUCT="$DEFAULT_PRODUCT"
EMIT_JSON=0

print_help() {
  cat <<'USAGE'
status.sh — human-readable dashboard of the allocation registry.

Optional:
  --product <name>     Default: ugc-platform
  --json               Emit JSON instead of human format
  --help, --version
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --product) PRODUCT="$2"; shift 2 ;;
    --json)    EMIT_JSON=1; shift ;;
    --help|-h) print_help; exit 0 ;;
    --version) print_version; exit 0 ;;
    *) log_err "Unknown argument: $1"; print_help; exit 2 ;;
  esac
done

require_tools

YML="$(resolve_yml_path "$PRODUCT")"

if [ "$EMIT_JSON" = "1" ]; then
  yq -o=json '
    {
      "product": .product.name,
      "current_main": .releases.current_main,
      "flyway": {
        "shipped_count": (.flyway.shipped | length),
        "reserved_count": (.flyway.reserved | length),
        "next_free": .flyway.next_free
      },
      "model_registry": {
        "shipped_count": (.model_registry.shipped | length),
        "pending_count": (.model_registry.pending | length)
      },
      "single_writer_locks": [
        .single_writer_files[] | select(.held_by != "none") | {"file": .file, "held_by": .held_by, "until": .until}
      ],
      "anchors_in_flight": [
        .anchor_dependencies[] | select(.status == "in_flight") | {"anchor": .anchor, "section": .section}
      ]
    }
  ' "$YML"
  exit 0
fi

product_name="$(yq -r '.product.name' "$YML")"
current_main="$(yq -r '.releases.current_main' "$YML")"
flyway_shipped="$(yq -r '.flyway.shipped | length' "$YML")"
flyway_reserved="$(yq -r '.flyway.reserved | length' "$YML")"
flyway_next="$(yq -r '.flyway.next_free' "$YML")"
model_shipped="$(yq -r '.model_registry.shipped | length' "$YML")"
model_pending="$(yq -r '.model_registry.pending | length' "$YML")"

cat <<EOF
=================================================
 AIDLC Allocation Status — $product_name
=================================================
 current_main:   $current_main
 flyway:         $flyway_shipped shipped / $flyway_reserved reserved (next free: $flyway_next)
 model surfaces: $model_shipped shipped / $model_pending pending

--- Active single-writer locks ---
EOF

yq -r '.single_writer_files[] | select(.held_by != "none") | "  " + .file + "\n    held_by: " + .held_by + "\n    until:   " + (.until // "n/a")' "$YML"

cat <<EOF

--- Active reserved Flyway versions ---
EOF
yq -r '.flyway.reserved[] | "  " + .version + "  section=" + .section + "  epic=" + .epic + "  fr=" + (.fr // "-") + "  expires=" + (.expires_at // "-")' "$YML"

cat <<EOF

--- Pending model surfaces ---
EOF
yq -r '.model_registry.pending[] | "  " + .surface + "  section=" + .section + "  epic=" + .epic + "  status=" + .status' "$YML"

cat <<EOF

--- Anchor dependencies (in-flight) ---
EOF
yq -r '.anchor_dependencies[] | select(.status == "in_flight") | "  " + .anchor + " (section " + .section + "): " + .description + "\n    consumers: " + ([.consumers[] | .fr + " (" + .status + ")"] | join(", "))' "$YML"

cat <<EOF

--- Next per-section release ---
EOF
yq -r '.releases.next_per_section | to_entries | .[] | "  Section " + .key + ": " + .value' "$YML"

echo "================================================="
