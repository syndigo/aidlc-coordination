#!/usr/bin/env bash
# shellcheck shell=bash
#
# next-tag.sh — compute the next available concrete semver tag for a section,
# by reading actual existing tags from GitHub (gh release list) at Stage-9
# create-time. This is the load-bearing piece of GDI-778: do NOT pre-reserve
# a specific tag at intake — let Stage 9 compute it from live state.
#
# Why this exists (GDI-778):
#   Pre-reserving a specific release tag at Phase 0.6 is racy across parallel
#   /sdlc sessions: `gh release create` doesn't consult the coordination
#   registry, so the reservation is advisory and frequently gets stolen by a
#   parallel section that reaches Stage 9 first. The reservation pattern paid
#   a ~2-3 minute re-allocation tax on every parallel Section C run for 4
#   consecutive runs (GDI-731, GDI-779, GDI-830, GDI-893).
#
#   The fix is to NOT pre-reserve a specific tag. Instead, call this script
#   at Stage 9 (release-create time):
#     next-tag.sh --section C --bump minor [--repo syndigo/ugc-platform]
#   It reads `gh release list`, finds the highest existing tag matching the
#   bump strategy, and emits the next free concrete tag on stdout.
#
# Bump strategies:
#   --bump minor   (default)  next free minor:    v0.42.0 → v0.43.0
#   --bump patch              next free patch:    v0.42.0 → v0.42.1
#   --bump major              next free major:    v0.42.0 → v1.0.0
#   --bump band               next free tag within section's band from
#                             allocations/<product>.yml releases.next_per_section
#                             (legacy mode; falls back to --bump minor if band
#                             not set or not matched)
#
# Usage:
#   next-tag.sh --section <A..J> [--bump minor|patch|major|band]
#               [--product <name>] [--repo <owner/name>] [--json]
#   next-tag.sh --help
#   next-tag.sh --version
#
# Output (plain):
#   v0.43.0
#
# Output (--json):
#   {"section":"C","bump":"minor","next_tag":"v0.43.0","current_max":"v0.42.0","at":"..."}
#
# Exit codes:
#   0   next tag computed and emitted
#   1   generic error
#   2   invalid argument
#   127 missing dependency (yq, gh)

# shellcheck source=_lib.sh
. "$(dirname "$0")/_lib.sh"

# ----- argv -----------------------------------------------------------------

SECTION=""
BUMP="minor"
PRODUCT="$DEFAULT_PRODUCT"
REPO=""
EMIT_JSON=0

print_help() {
  cat <<'USAGE'
next-tag.sh — compute next available concrete semver tag at Stage-9 create time.

Required:
  --section <A..J>           Section letter (audit/log purposes; does NOT
                             constrain the computed tag unless --bump=band)

Optional:
  --bump <minor|patch|major|band>
                             Bump strategy (default: minor)
                             minor: next free vX.Y+1.0  (most common for features)
                             patch: next free vX.Y.Z+1  (hotfixes)
                             major: next free vX+1.0.0  (breaking)
                             band:  next free tag within section's band per
                                    allocations/<product>.yml releases.next_per_section
  --product <name>           Default: ugc-platform
  --repo <owner/name>        Default: syndigo/<product>
  --json                     Emit structured JSON
  --help, --version

Examples:
  next-tag.sh --section C
    -> v0.43.0  (next minor after current_max)

  next-tag.sh --section C --bump patch
    -> v0.42.1

  next-tag.sh --section C --bump band  (legacy)
    -> next tag in Section C's pre-configured band

GDI-778 contract: Stage 9 of /sdlc dispatches this BEFORE `gh release create`,
takes the output as the concrete tag, and creates the release atomically. No
pre-reservation, no race.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --section)  SECTION="$2"; shift 2 ;;
    --bump)     BUMP="$2"; shift 2 ;;
    --product)  PRODUCT="$2"; shift 2 ;;
    --repo)     REPO="$2"; shift 2 ;;
    --json)     EMIT_JSON=1; shift ;;
    --help|-h)  print_help; exit 0 ;;
    --version)  print_version; exit 0 ;;
    *) log_err "Unknown argument: $1"; print_help; exit 2 ;;
  esac
done

if [ -z "$SECTION" ]; then
  log_err "Missing required arg: --section"
  exit 2
fi
validate_section "$SECTION"

case "$BUMP" in
  minor|patch|major|band) ;;
  *) log_err "Invalid --bump: $BUMP (expected minor|patch|major|band)"; exit 2 ;;
esac

require_tools
if ! command -v gh >/dev/null 2>&1; then
  log_err "gh CLI not found on PATH. Install GitHub CLI."
  exit 127
fi

YML="$(resolve_yml_path "$PRODUCT")"

if [ -z "$REPO" ]; then
  REPO="syndigo/${PRODUCT}"
fi

# ----- fetch existing tags from GitHub --------------------------------------

EXISTING_RAW="$(gh release list --repo "$REPO" --limit 100 --json tagName 2>/dev/null)" || {
  log_err "gh release list failed for $REPO. Is gh authenticated? Run: gh auth status"
  exit 1
}

# Extract bare tag names, one per line. yq is the cleanest JSON-to-line tool
# we already have on the path.
ALL_TAGS="$(printf '%s' "$EXISTING_RAW" | yq -p=json -o=json '.[] | .tagName' 2>/dev/null | tr -d '"')"

# Filter to canonical vX.Y.Z tags (drop pre-aidlc and any non-semver oddities).
SEMVER_TAGS="$(printf '%s\n' "$ALL_TAGS" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true)"

if [ -z "$SEMVER_TAGS" ]; then
  log_err "No vX.Y.Z tags found in $REPO. Cannot compute next tag."
  exit 1
fi

# Find the maximum tag by version-sort.
# sort -V handles vX.Y.Z naturally.
CURRENT_MAX="$(printf '%s\n' "$SEMVER_TAGS" | sort -V | tail -1)"

# Parse major.minor.patch from CURRENT_MAX (strip leading "v").
MAX_NUMS="${CURRENT_MAX#v}"
MAJOR="${MAX_NUMS%%.*}"
REST="${MAX_NUMS#*.}"
MINOR="${REST%%.*}"
PATCH="${REST#*.}"

# ----- compute NEXT_TAG -----------------------------------------------------

case "$BUMP" in
  minor)
    NEXT_MINOR=$((MINOR + 1))
    NEXT_TAG="v${MAJOR}.${NEXT_MINOR}.0"
    # Verify the candidate is actually free (defense against a tag created
    # AFTER CURRENT_MAX but with a lower-than-expected version, e.g. a
    # back-fill). Walk forward if collision.
    while printf '%s\n' "$SEMVER_TAGS" | grep -qxF "$NEXT_TAG"; do
      NEXT_MINOR=$((NEXT_MINOR + 1))
      NEXT_TAG="v${MAJOR}.${NEXT_MINOR}.0"
    done
    ;;
  patch)
    NEXT_PATCH=$((PATCH + 1))
    NEXT_TAG="v${MAJOR}.${MINOR}.${NEXT_PATCH}"
    while printf '%s\n' "$SEMVER_TAGS" | grep -qxF "$NEXT_TAG"; do
      NEXT_PATCH=$((NEXT_PATCH + 1))
      NEXT_TAG="v${MAJOR}.${MINOR}.${NEXT_PATCH}"
    done
    ;;
  major)
    NEXT_MAJOR=$((MAJOR + 1))
    NEXT_TAG="v${NEXT_MAJOR}.0.0"
    while printf '%s\n' "$SEMVER_TAGS" | grep -qxF "$NEXT_TAG"; do
      NEXT_MAJOR=$((NEXT_MAJOR + 1))
      NEXT_TAG="v${NEXT_MAJOR}.0.0"
    done
    ;;
  band)
    # Legacy: read the section's band from allocations YAML and find next
    # free patch within it. The current band shape vN.M.x means "any vN.M.Z".
    BAND="$(yq -r ".releases.next_per_section.\"${SECTION}\" // \"\"" "$YML")"
    if [ -z "$BAND" ] || [ "$BAND" = "null" ]; then
      log_err "No band configured for section $SECTION (falling back to --bump=minor recommended)"
      exit 2
    fi
    case "$BAND" in
      v[0-9]*.[0-9]*.x) ;;
      *) log_err "Band for section $SECTION is not vN.M.x form: $BAND"; exit 2 ;;
    esac
    BAND_PREFIX="${BAND%x}"  # "v0.30."
    IN_BAND="$(printf '%s\n' "$SEMVER_TAGS" | grep -E "^${BAND_PREFIX//./\\.}[0-9]+$" | sort -V | tail -1 || true)"
    if [ -z "$IN_BAND" ]; then
      NEXT_TAG="${BAND_PREFIX}0"
    else
      BAND_PATCH="${IN_BAND##*.}"
      NEXT_BAND_PATCH=$((BAND_PATCH + 1))
      NEXT_TAG="${BAND_PREFIX}${NEXT_BAND_PATCH}"
    fi
    ;;
esac

# Validate output is a real semver.
validate_semver_tag "$NEXT_TAG"

# ----- emit -----------------------------------------------------------------

if [ "$EMIT_JSON" = "1" ]; then
  esc_section="$(json_escape "$SECTION")"
  esc_bump="$(json_escape "$BUMP")"
  esc_tag="$(json_escape "$NEXT_TAG")"
  esc_max="$(json_escape "$CURRENT_MAX")"
  esc_repo="$(json_escape "$REPO")"
  printf '{"section":"%s","bump":"%s","next_tag":"%s","current_max":"%s","repo":"%s","at":"%s"}\n' \
    "$esc_section" "$esc_bump" "$esc_tag" "$esc_max" "$esc_repo" "$(iso_now)"
else
  printf '%s\n' "$NEXT_TAG"
fi
