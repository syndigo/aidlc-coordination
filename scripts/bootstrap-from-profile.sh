#!/usr/bin/env bash
# shellcheck shell=bash
#
# bootstrap-from-profile.sh — generate allocations/<product>.yml from a profile.
#
# Reads profiles/<product>.yml (the per-product shape: paths, language,
# section letters, pillar definitions) and generates a Day-1 allocation
# YAML seeded with empty registry blocks + the pillar shape. The generated
# allocation will validate against schemas/allocation.yml.schema.json
# immediately.
#
# Idempotent: refuses to overwrite an existing allocation unless --force.
#
# Usage:
#   bootstrap-from-profile.sh --product <name> [--force] [--dry-run]
#   bootstrap-from-profile.sh --help
#   bootstrap-from-profile.sh --version
#
# Exit codes:
#   0  generated successfully (or dry-run printed)
#   1  generic error
#   2  invalid argument / profile not found / allocation exists (no --force)
#   127 missing dependency

# shellcheck source=_lib.sh
. "$(dirname "$0")/_lib.sh"

PRODUCT=""
FORCE=0
DRY_RUN=0

print_help() {
  cat <<'USAGE'
bootstrap-from-profile.sh — generate allocations/<product>.yml from a profile.

Required:
  --product <name>     Product slug. Reads profiles/<name>.yml; writes
                       allocations/<name>.yml.

Optional:
  --force              Overwrite an existing allocation YAML.
                       Use with care — destroys live coordination state.
  --dry-run            Print the generated allocation to stdout; do not
                       write to disk or commit.
  --help, --version

Workflow:
  1. Author profiles/<new-product>.yml (validates against
     schemas/profile.yml.schema.json).
  2. Run bootstrap-from-profile.sh --product <new-product> --dry-run
     to preview the seeded allocation.
  3. Re-run without --dry-run to write allocations/<new-product>.yml.
  4. The generated allocation is committed as a single chore commit.
  5. Sessions can immediately reserve resources against the new product.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --product) PRODUCT="$2"; shift 2 ;;
    --force)   FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) print_help; exit 0 ;;
    --version) print_version; exit 0 ;;
    *) log_err "Unknown argument: $1"; print_help; exit 2 ;;
  esac
done

if [ -z "$PRODUCT" ]; then
  log_err "Missing required arg: --product"
  exit 2
fi

require_tools

PROFILE_PATH="$REPO_ROOT/profiles/${PRODUCT}.yml"
ALLOCATION_PATH="$REPO_ROOT/allocations/${PRODUCT}.yml"

if [ ! -f "$PROFILE_PATH" ]; then
  log_err "Profile not found: $PROFILE_PATH"
  log_err "  Author the profile first. See profiles/ugc-platform.yml as a template,"
  log_err "  and schemas/profile.yml.schema.json for the contract."
  exit 2
fi

if [ -f "$ALLOCATION_PATH" ] && [ "$FORCE" != "1" ]; then
  log_err "Allocation already exists: $ALLOCATION_PATH"
  log_err "  Refusing to overwrite without --force."
  log_err "  --force destroys live coordination state. Use only when bootstrapping"
  log_err "  a fresh product or recovering from a corrupt registry."
  exit 2
fi

# Pull the bits we need from the profile. yq v4 doesn't support advanced
# transforms, so we extract individual fields and shell-construct the
# allocation YAML below.
PROFILE_PRODUCT_NAME="$(yq -r '.product.name' "$PROFILE_PATH")"
PROFILE_PRODUCT_REPO="$(yq -r '.product.repo // "unknown/unknown"' "$PROFILE_PATH")"

# Sanity check: --product must match the profile's product.name
if [ "$PROFILE_PRODUCT_NAME" != "$PRODUCT" ]; then
  log_err "Profile's product.name ($PROFILE_PRODUCT_NAME) does not match --product ($PRODUCT)"
  log_err "  Either rename the profile or pass --product $PROFILE_PRODUCT_NAME"
  exit 2
fi

# Section letters as a flow-style array string (e.g., "[A, B, C]").
SECTION_LETTERS_FLOW="$(yq -o=json '.section_range.letters' "$PROFILE_PATH" \
  | tr -d '\n' | sed 's/,/, /g')"

# Default per-section release tags (Day-1: all v0.1.x).
# Build the next_per_section map by iterating section letters.
section_letters="$(yq -r '.section_range.letters[]' "$PROFILE_PATH")"

# Build the pillars[] block from the profile's pillars[] list. Each profile
# pillar becomes an allocation pillar with status=not_started and empty
# in_flight_frs/shipped_frs.
TMP="$(mktemp)"
trap 'rm -f "$TMP" "$TMP.next_per_section" "$TMP.pillars"' EXIT

# next_per_section block (one line per section letter).
{
  echo "  next_per_section:"
  for L in $section_letters; do
    echo "    $L: v0.1.x"
  done
} > "$TMP.next_per_section"

# pillars[] block from profile.pillars[].
{
  has_profile_pillars="$(yq -r '(.pillars // []) | length' "$PROFILE_PATH")"
  if [ "$has_profile_pillars" = "0" ]; then
    # No pillars in the profile — emit empty array marker.
    echo "pillars: []"
  else
    echo "pillars:"
    pillar_count="$has_profile_pillars"
    i=0
    while [ "$i" -lt "$pillar_count" ]; do
      letter="$(yq -r ".pillars[$i].letter" "$PROFILE_PATH")"
      name="$(yq -r ".pillars[$i].name" "$PROFILE_PATH")"
      max_in_flight="$(yq -r ".pillars[$i].default_max_in_flight_frs // 2" "$PROFILE_PATH")"
      ship_freq="$(yq -r ".pillars[$i].default_ship_frequency // \"unlimited\"" "$PROFILE_PATH")"
      cat <<PILLAR
  - letter: $letter
    name: $name
    status: not_started
    owner_persona: personas/pillar-orchestrator.md
    fr_backlog: []
    in_flight_frs: []
    shipped_frs: []
    blocked_on: []
    ship_frequency: $ship_freq
    max_in_flight_frs: $max_in_flight
PILLAR
      i=$((i + 1))
    done
  fi
} > "$TMP.pillars"

# Single-writer files seeded from profile.ai_surface_files[].
single_writer_block=""
ai_surface_count="$(yq -r '(.ai_surface_files // []) | length' "$PROFILE_PATH")"
if [ "$ai_surface_count" = "0" ]; then
  # Schema requires single_writer_files to have at least one entry.
  # Seed with the project's append-safe ADR file so the array isn't empty.
  single_writer_block="- file: docs/decisions.md
  held_by: none
  note: Append-safe at the section level. Seeded by bootstrap-from-profile.sh."
else
  i=0
  while [ "$i" -lt "$ai_surface_count" ]; do
    path="$(yq -r ".ai_surface_files[$i].path" "$PROFILE_PATH")"
    role="$(yq -r ".ai_surface_files[$i].role" "$PROFILE_PATH")"
    append_conflict="$(yq -r ".ai_surface_files[$i].append_list_conflict_class // false" "$PROFILE_PATH")"
    max_holders="$(yq -r ".ai_surface_files[$i].max_concurrent_holders // 1" "$PROFILE_PATH")"
    single_writer_block="${single_writer_block}- file: $path
  held_by: none
  note: \"AI surface ($role) seeded from profile.ai_surface_files[].\"
  append_list_conflict_class: $append_conflict
  max_concurrent_holders: $max_holders
"
    i=$((i + 1))
  done
fi

# Now construct the full allocation YAML.
{
  cat <<HEADER
# =====================================================================
# $PRODUCT — Allocation Registry
# =====================================================================
# Generated by scripts/bootstrap-from-profile.sh from
# profiles/${PRODUCT}.yml on $(iso_now).
#
# This file holds live coordination state. The immutable product shape
# (paths, language, pillar definitions) lives in the profile referenced
# by .profile_ref below.

product:
  name: $PRODUCT
  repo: $PROFILE_PRODUCT_REPO
  sections: $SECTION_LETTERS_FLOW

flyway:
  shipped: []
  reserved: []
  next_free: V1
  test_fixture_range:
    shipped: []
    reserved: []
    next_free: V900

model_registry:
  shipped: []
  pending: []

single_writer_files:
$(printf '  %s' "$single_writer_block" | sed 's/^/  /' | sed '1s/^  //')

releases:
  current_main: pre-aidlc
HEADER
  cat "$TMP.next_per_section"
  cat <<MIDDLE
  in_flight: []

anchor_dependencies: []

tfc_deploy_queue:
  current_deployed_sha: pre-aidlc
  current_desired_sha: pre-aidlc
  pending_pushes: []
  next_batch_window: null
  note: |
    Day-1 stub for new product. Sessions merge directly to dev as today.

profile_ref: profiles/${PRODUCT}.yml

MIDDLE
  cat "$TMP.pillars"
} > "$TMP"

# Validate the generated YAML against the schema before writing.
yq -o=json '.' "$TMP" > "${TMP}.json" 2>/dev/null
# We can't ajv from the script (might not be installed locally); use yq
# to at least confirm the YAML parses.
if ! yq '.' "$TMP" >/dev/null 2>&1; then
  log_err "Generated YAML failed to parse. This is a bug in bootstrap-from-profile.sh."
  log_err "  Generated content saved at: $TMP"
  trap - EXIT
  exit 1
fi

if [ "$DRY_RUN" = "1" ]; then
  log_info "[dry-run] would write to: $ALLOCATION_PATH"
  log_info "----- generated content -----"
  cat "$TMP"
  log_info "----- end generated content -----"
  exit 0
fi

cp "$TMP" "$ALLOCATION_PATH"
log_info "Wrote $ALLOCATION_PATH ($(wc -l < "$ALLOCATION_PATH" | tr -d ' ') lines)"

if ( cd "$REPO_ROOT" && git rev-parse --git-dir >/dev/null 2>&1 ); then
  git_pull_rebase || log_warn "rebase skipped"
  commit_msg="chore(bootstrap): generate allocations/${PRODUCT}.yml from profile

Generated by scripts/bootstrap-from-profile.sh from
profiles/${PRODUCT}.yml. Empty registry blocks; pillar shape and
single-writer seeds taken from the profile."
  git_commit_and_push "$commit_msg" "$ALLOCATION_PATH" || {
    log_err "push failed"
    exit 1
  }
fi
