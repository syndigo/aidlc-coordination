#!/usr/bin/env bash
# shellcheck shell=bash
#
# bootstrap-pillar-prompt.sh — render the first-message prompt for a fresh
# pillar-orchestrator (or section-owner) tab.
#
# When you spin up a new Claude tab to own a pillar's work, you want that
# tab to start with the right context: required reading, coordination
# substrate intro, /sdlc dispatch instructions, this pillar's live state,
# and what the parallel tabs are doing right now. Hand-pasting that
# prompt for every new tab means the live state is stale 30 minutes later.
#
# This script renders the prompt from:
#   - profiles/<product>.bootstrap-template.md  (the prose with {{placeholders}})
#   - allocations/<product>.yml                  (live state — pillar block,
#                                                 single-writer locks, recent ships,
#                                                 anchor relevance)
#   - profiles/<product>.yml                     (product shape — repo, paths,
#                                                 pillar names/scopes)
#
# Read-only. Pipe stdout into a fresh Claude tab as the first message. The
# orchestrator/operator inserts the strategic FR pick + rationale by hand —
# the renderer can list backlog but cannot replace human pillar strategy
# (the template carries an ORCHESTRATOR NOTE comment marking that spot).
#
# Usage:
#   bootstrap-pillar-prompt.sh --product <name> --letter <X>
#                              [--local-repo-path <path>]
#                              [--template <path>]
#   bootstrap-pillar-prompt.sh --help
#   bootstrap-pillar-prompt.sh --version
#
# Exit codes:
#   0  rendered to stdout
#   1  generic error
#   2  invalid argument / template missing / pillar not in YAML
#   127 missing dependency

# shellcheck source=_lib.sh
. "$(dirname "$0")/_lib.sh"

PRODUCT="$DEFAULT_PRODUCT"
LETTER=""
LOCAL_REPO_PATH=""
TEMPLATE_PATH=""
# D-025 follow-up: --with-drift-check runs audit-registry-drift.sh and embeds
# the result into the rendered prompt so the new tab knows whether the
# registry is currently honest. Off by default — drift check makes 1+ gh API
# calls and takes ~5s.
WITH_DRIFT_CHECK=0

print_help() {
  cat <<'USAGE'
bootstrap-pillar-prompt.sh — render the first-message prompt for a fresh pillar tab.

Required:
  --letter <X>                  Pillar letter (also section letter)

Optional:
  --product <name>              Default: ugc-platform
  --local-repo-path <path>      Local clone of the product repo. If omitted,
                                a placeholder is left in the rendered prompt
                                for the operator to fill.
  --template <path>             Path to the bootstrap template. Defaults to
                                profiles/<product>.bootstrap-template.md.
  --with-drift-check            Run audit-registry-drift.sh and embed the
                                result into the prompt. Adds ~5s and 1+ gh
                                API calls; the new tab gets immediate
                                visibility into whether the registry is
                                currently honest. Off by default; recommended
                                when an orchestrator persona is doing the
                                spawn (so the new tab doesn't act on stale
                                state).
  --help, --version

Output: the rendered prompt to stdout. Pipe into a fresh Claude tab as the
first message before /sdlc is dispatched.

Substituted placeholders:
  {{PRODUCT}}                   product slug
  {{PILLAR_LETTER}}             A..Z
  {{PILLAR_NAME}}               from profile.pillars[].name
  {{PILLAR_SCOPE}}              from profile.pillars[].scope
  {{FR_PREFIX}}                 from profile.pillars[].fr_prefix
  {{FR_BACKLOG_LIST}}           comma-separated, from allocation.pillars[].fr_backlog
  {{FR_BACKLOG_COUNT}}          length of the same
  {{IN_FLIGHT_FRS}}             from allocation.pillars[].in_flight_frs
  {{SHIPPED_FRS_COUNT}}         length of allocation.pillars[].shipped_frs
  {{PRODUCT_REPO}}              from profile.product.repo (org/name)
  {{LOCAL_REPO_PATH}}           --local-repo-path or default
  {{ACTIVE_LOCKS_BLOCK}}        rendered list of active single-writer holds
  {{RECENT_SHIPS_BLOCK}}        rendered list of last 5 shipped flyway entries
  {{ANCHOR_RELEVANCE_BLOCK}}    cross-pillar anchors this pillar consumes/produces
  {{PARALLEL_PILLARS}}          count of pillars with status==in_flight other than this one
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --letter)           LETTER="$2"; shift 2 ;;
    --product)          PRODUCT="$2"; shift 2 ;;
    --local-repo-path)  LOCAL_REPO_PATH="$2"; shift 2 ;;
    --template)         TEMPLATE_PATH="$2"; shift 2 ;;
    --with-drift-check) WITH_DRIFT_CHECK=1; shift ;;
    --help|-h)          print_help; exit 0 ;;
    --version)          print_version; exit 0 ;;
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

# Profile lookup -- need product.repo, pillars[].name/scope/fr_prefix.
PROFILE_REF="$(yq -r '.profile_ref // ""' "$YML")"
PROFILE_PATH=""
if [ -n "$PROFILE_REF" ] && [ -f "$REPO_ROOT/$PROFILE_REF" ]; then
  PROFILE_PATH="$REPO_ROOT/$PROFILE_REF"
fi

if [ -z "$TEMPLATE_PATH" ]; then
  TEMPLATE_PATH="$REPO_ROOT/profiles/${PRODUCT}.bootstrap-template.md"
fi
if [ ! -f "$TEMPLATE_PATH" ]; then
  log_err "Bootstrap template not found: $TEMPLATE_PATH"
  log_err "  Author one (see profiles/ugc-platform.bootstrap-template.md as a template)"
  log_err "  or pass --template <path>."
  exit 2
fi

if [ -z "$LOCAL_REPO_PATH" ]; then
  LOCAL_REPO_PATH="<set-via---local-repo-path>"
fi

# Confirm pillar exists in the allocation YAML.
pillar_exists="$(yq -r ".pillars[]? | select(.letter == \"$LETTER\") | .letter" "$YML")"
if [ -z "$pillar_exists" ]; then
  log_err "Pillar $LETTER not found in $YML (.pillars[])"
  exit 2
fi

# ----- gather data ----------------------------------------------------------

# From allocation YAML
PILLAR_NAME_FROM_ALLOC="$(yq -r ".pillars[] | select(.letter == \"$LETTER\") | .name" "$YML")"

FR_BACKLOG="$(yq -r "(.pillars[] | select(.letter == \"$LETTER\") | .fr_backlog // [])[]" "$YML")"
FR_BACKLOG_COUNT="$(yq -r "(.pillars[] | select(.letter == \"$LETTER\") | .fr_backlog // []) | length" "$YML")"

IN_FLIGHT_FRS_RAW="$(yq -r "(.pillars[] | select(.letter == \"$LETTER\") | .in_flight_frs // [])[]" "$YML")"
SHIPPED_FRS_COUNT="$(yq -r "(.pillars[] | select(.letter == \"$LETTER\") | .shipped_frs // []) | length" "$YML")"

PARALLEL_PILLARS="$(yq -r "[.pillars[] | select(.status == \"in_flight\" and .letter != \"$LETTER\")] | length" "$YML")"

# From profile (fallbacks if profile missing)
PILLAR_NAME=""
PILLAR_SCOPE=""
FR_PREFIX=""
PRODUCT_REPO=""
if [ -n "$PROFILE_PATH" ]; then
  PILLAR_NAME="$(yq -r "(.pillars // [])[] | select(.letter == \"$LETTER\") | .name // \"\"" "$PROFILE_PATH")"
  PILLAR_SCOPE="$(yq -r "(.pillars // [])[] | select(.letter == \"$LETTER\") | .scope // \"\"" "$PROFILE_PATH")"
  FR_PREFIX="$(yq -r "(.pillars // [])[] | select(.letter == \"$LETTER\") | .fr_prefix // \"\"" "$PROFILE_PATH")"
  PRODUCT_REPO="$(yq -r '.product.repo // ""' "$PROFILE_PATH")"
fi
# Fall back to allocation's pillar name if profile didn't have it.
[ -z "$PILLAR_NAME" ] && PILLAR_NAME="$PILLAR_NAME_FROM_ALLOC"
[ -z "$PILLAR_SCOPE" ] && PILLAR_SCOPE="(scope not defined in profile.pillars[])"
[ -z "$FR_PREFIX" ] && FR_PREFIX="FR-${LETTER}."
[ -z "$PRODUCT_REPO" ] && PRODUCT_REPO="<unknown/repo>"

# Format FR backlog as a comma-separated list inline; if long, fall back to bullets.
FR_BACKLOG_LIST=""
if [ -z "$FR_BACKLOG" ]; then
  FR_BACKLOG_LIST="(empty)"
else
  FR_BACKLOG_LIST="$(printf '%s' "$FR_BACKLOG" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')"
fi

IN_FLIGHT_FRS=""
if [ -z "$IN_FLIGHT_FRS_RAW" ]; then
  IN_FLIGHT_FRS="(none — pillar has no FR currently reserved)"
else
  IN_FLIGHT_FRS="$(printf '%s' "$IN_FLIGHT_FRS_RAW" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')"
fi

# Active locks block: render single_writer_files held by anyone (including this
# pillar's siblings).
ACTIVE_LOCKS_BLOCK=""
held_count="$(yq -r '[.single_writer_files[] | select(.held_by != "none" and .held_by != null)] | length' "$YML")"
if [ "$held_count" = "0" ]; then
  ACTIVE_LOCKS_BLOCK="**Active single-writer locks**: none right now (good — no queueing pressure on shared files)."
else
  ACTIVE_LOCKS_BLOCK="**Active single-writer locks** (sibling tabs holding shared files):"$'\n'
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    ACTIVE_LOCKS_BLOCK="${ACTIVE_LOCKS_BLOCK}$line"$'\n'
  done <<EOF
$(yq -r '.single_writer_files[] | select(.held_by != "none" and .held_by != null) | "- " + .file + " — held by " + .held_by + " until " + (.until // "n/a")' "$YML")
EOF
fi

# Recent ships block: last 5 from flyway.shipped, freshest last. yq v4 lacks
# jq's if/then/else, so use the // (alternative) operator on .release_tag and
# the AIDLC-tracked test (.shipped_at present implies AIDLC era — pre-AIDLC
# rows have shipped_at = 2026-05-01T00:00:00Z all the same so they sort behind
# anything real; the slice picks the freshest 5 regardless).
RECENT_SHIPS_BLOCK="**Recent ships across the product** (last 5 flyway shipped):"$'\n'
recent_ships="$(yq -r '
  .flyway.shipped
  | sort_by(.shipped_at)
  | .[-5:]
  | .[]
  | "- " + .version + " (section " + (.section // "?") + ", " + .epic + ") — " + (.release_tag // "untagged") + " at " + .shipped_at
' "$YML" 2>/dev/null || true)"
if [ -z "$recent_ships" ]; then
  RECENT_SHIPS_BLOCK="${RECENT_SHIPS_BLOCK}- (no recent ships)"
else
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    RECENT_SHIPS_BLOCK="${RECENT_SHIPS_BLOCK}$line"$'\n'
  done <<EOF
$recent_ships
EOF
fi

# Drift check block: if --with-drift-check, run audit-registry-drift.sh and
# embed a summary of findings. The orchestrator persona's tick already calls
# the drift check separately; this is a fast-path so a freshly spawned tab
# doesn't have to ask "is the registry currently honest?" before it starts.
DRIFT_CHECK_BLOCK=""
if [ "$WITH_DRIFT_CHECK" = "1" ]; then
  drift_repo_path="$LOCAL_REPO_PATH"
  if [ "$drift_repo_path" = "<set-via---local-repo-path>" ] || [ ! -d "$drift_repo_path" ]; then
    DRIFT_CHECK_BLOCK="**Registry-vs-reality drift check**: skipped (no valid product repo path; pass --local-repo-path to enable)."
  else
    drift_out="$("$REPO_ROOT/scripts/audit-registry-drift.sh" --product "$PRODUCT" --product-repo-path "$drift_repo_path" 2>&1 || true)"
    drift_count="$(printf '%s' "$drift_out" | grep -c '^❌\|^⚠️\|^ℹ️ ' || true)"
    if [ "$drift_count" = "0" ]; then
      DRIFT_CHECK_BLOCK="**Registry-vs-reality drift check**: ✅ zero findings. The registry matches the UGC repo and GitHub releases right now."
    else
      DRIFT_CHECK_BLOCK="**Registry-vs-reality drift check**: ⚠️ $drift_count finding(s). Review BEFORE making decisions — the registry may be stale. Run \`./scripts/audit-registry-drift.sh --product $PRODUCT --product-repo-path $drift_repo_path\` for details."
    fi
  fi
fi

# Anchor relevance block: anchors where this pillar is producer (.section == LETTER)
# OR consumer (.consumers[].section == LETTER). Skip entirely if none relevant.
# || true so a missing anchor_dependencies block doesn't kill the script under set -e.
ANCHOR_RELEVANCE_BLOCK=""
PRODUCED_LIST="$(yq -r ".anchor_dependencies[] | select(.section == \"$LETTER\") | \"- PRODUCES \" + .anchor + \" (\" + .status + \") — \" + (.description // \"\")" "$YML" 2>/dev/null || true)"
CONSUMED_LIST="$(yq -r ".anchor_dependencies[] | select(.consumers[]?.section == \"$LETTER\") | \"- CONSUMES \" + .anchor + \" (\" + .status + \") — \" + (.description // \"\")" "$YML" 2>/dev/null || true)"
if [ -n "$PRODUCED_LIST" ] || [ -n "$CONSUMED_LIST" ]; then
  ANCHOR_RELEVANCE_BLOCK="**Cross-pillar anchors relevant to Pillar ${LETTER}**:"$'\n'
  [ -n "$PRODUCED_LIST" ] && ANCHOR_RELEVANCE_BLOCK="${ANCHOR_RELEVANCE_BLOCK}${PRODUCED_LIST}"$'\n'
  [ -n "$CONSUMED_LIST" ] && ANCHOR_RELEVANCE_BLOCK="${ANCHOR_RELEVANCE_BLOCK}${CONSUMED_LIST}"$'\n'
fi

# ----- render --------------------------------------------------------------

# Read the template, perform substitutions. Use a temp file because some
# placeholder values (especially the multiline blocks) make sed -e brittle.
# awk handles this cleanly with environment variables.
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

export R_PRODUCT="$PRODUCT"
export R_PILLAR_LETTER="$LETTER"
export R_PILLAR_NAME="$PILLAR_NAME"
export R_PILLAR_SCOPE="$PILLAR_SCOPE"
export R_FR_PREFIX="$FR_PREFIX"
export R_FR_BACKLOG_LIST="$FR_BACKLOG_LIST"
export R_FR_BACKLOG_COUNT="$FR_BACKLOG_COUNT"
export R_IN_FLIGHT_FRS="$IN_FLIGHT_FRS"
export R_SHIPPED_FRS_COUNT="$SHIPPED_FRS_COUNT"
export R_PRODUCT_REPO="$PRODUCT_REPO"
export R_LOCAL_REPO_PATH="$LOCAL_REPO_PATH"
export R_PARALLEL_PILLARS="$PARALLEL_PILLARS"
export R_ACTIVE_LOCKS_BLOCK="$ACTIVE_LOCKS_BLOCK"
export R_RECENT_SHIPS_BLOCK="$RECENT_SHIPS_BLOCK"
export R_ANCHOR_RELEVANCE_BLOCK="$ANCHOR_RELEVANCE_BLOCK"
export R_DRIFT_CHECK_BLOCK="$DRIFT_CHECK_BLOCK"

awk '
  # Escape special chars (& and \) in the replacement string so awk gsub
  # does not interpret them as backreferences. Without this, a pillar name
  # like "Sampling & Creator Programs" gets the matched-text (the
  # placeholder) substituted in place of "&", producing
  # "Sampling {{PILLAR_NAME}} Creator Programs".
  function esc(s) {
    gsub(/\\/, "\\\\", s)
    gsub(/&/, "\\\\&", s)
    return s
  }
  BEGIN {
    e_product               = esc(ENVIRON["R_PRODUCT"])
    e_pillar_letter         = esc(ENVIRON["R_PILLAR_LETTER"])
    e_pillar_name           = esc(ENVIRON["R_PILLAR_NAME"])
    e_pillar_scope          = esc(ENVIRON["R_PILLAR_SCOPE"])
    e_fr_prefix             = esc(ENVIRON["R_FR_PREFIX"])
    e_fr_backlog_list       = esc(ENVIRON["R_FR_BACKLOG_LIST"])
    e_fr_backlog_count      = esc(ENVIRON["R_FR_BACKLOG_COUNT"])
    e_in_flight_frs         = esc(ENVIRON["R_IN_FLIGHT_FRS"])
    e_shipped_frs_count     = esc(ENVIRON["R_SHIPPED_FRS_COUNT"])
    e_product_repo          = esc(ENVIRON["R_PRODUCT_REPO"])
    e_local_repo_path       = esc(ENVIRON["R_LOCAL_REPO_PATH"])
    e_parallel_pillars      = esc(ENVIRON["R_PARALLEL_PILLARS"])
    e_active_locks_block    = esc(ENVIRON["R_ACTIVE_LOCKS_BLOCK"])
    e_recent_ships_block    = esc(ENVIRON["R_RECENT_SHIPS_BLOCK"])
    e_anchor_relevance_block = esc(ENVIRON["R_ANCHOR_RELEVANCE_BLOCK"])
    e_drift_check_block      = esc(ENVIRON["R_DRIFT_CHECK_BLOCK"])
  }
  {
    line = $0
    gsub(/\{\{PRODUCT\}\}/,                e_product,               line)
    gsub(/\{\{PILLAR_LETTER\}\}/,          e_pillar_letter,         line)
    gsub(/\{\{PILLAR_NAME\}\}/,            e_pillar_name,           line)
    gsub(/\{\{PILLAR_SCOPE\}\}/,           e_pillar_scope,          line)
    gsub(/\{\{FR_PREFIX\}\}/,              e_fr_prefix,             line)
    gsub(/\{\{FR_BACKLOG_LIST\}\}/,        e_fr_backlog_list,       line)
    gsub(/\{\{FR_BACKLOG_COUNT\}\}/,       e_fr_backlog_count,      line)
    gsub(/\{\{IN_FLIGHT_FRS\}\}/,          e_in_flight_frs,         line)
    gsub(/\{\{SHIPPED_FRS_COUNT\}\}/,      e_shipped_frs_count,     line)
    gsub(/\{\{PRODUCT_REPO\}\}/,           e_product_repo,          line)
    gsub(/\{\{LOCAL_REPO_PATH\}\}/,        e_local_repo_path,       line)
    gsub(/\{\{PARALLEL_PILLARS\}\}/,       e_parallel_pillars,      line)
    gsub(/\{\{ACTIVE_LOCKS_BLOCK\}\}/,     e_active_locks_block,    line)
    gsub(/\{\{RECENT_SHIPS_BLOCK\}\}/,     e_recent_ships_block,    line)
    gsub(/\{\{ANCHOR_RELEVANCE_BLOCK\}\}/, e_anchor_relevance_block, line)
    gsub(/\{\{DRIFT_CHECK_BLOCK\}\}/,      e_drift_check_block,      line)
    print line
  }
' "$TEMPLATE_PATH"
