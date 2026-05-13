#!/usr/bin/env bash
# shellcheck shell=bash
#
# release.sh — mark a reserved resource as shipped or released.
#
# Usage:
#   release.sh --resource <flyway|model-registry|file-lock|release-tag> \
#              --section <A..J> --epic <GDI-XXX> --id <V19|surface|file|tag> \
#              --status <shipped|released> [--release-tag vX.Y.Z] \
#              [--product <name>] [--json]
#   release.sh --help
#   release.sh --version
#
# Status semantics:
#   --status=shipped    Used for flyway and model-registry resources.
#                       --release-tag is REQUIRED so the appended row
#                       carries a valid semver tag.
#   --status=released   Used for file-lock (clears held_by) and
#                       release-tag (sets current_main). Rejected for
#                       flyway and model-registry — those resources
#                       must use --status=shipped with --release-tag,
#                       otherwise the appended row has an empty
#                       release_tag and fails schema validation.
#                       See D-013.
#
# Exit codes:
#   0  released successfully (or idempotent no-op)
#   1  generic error
#   2  invalid argument / not found
#   127 missing dependency

# shellcheck source=_lib.sh
. "$(dirname "$0")/_lib.sh"

RESOURCE=""
SECTION=""
EPIC=""
ID=""
STATUS=""
RELEASE_TAG=""
PRODUCT="$DEFAULT_PRODUCT"
EMIT_JSON=0

print_help() {
  cat <<'USAGE'
release.sh — mark a reserved resource as shipped or released.

Required:
  --resource <flyway|model-registry|file-lock|release-tag>
  --section <A..J>
  --epic <GDI-XXX>
  --id <id>
  --status <shipped|released>

Optional:
  --release-tag <vX.Y.Z>      Required for status=shipped; ignored otherwise
  --product <name>            Default: ugc-platform
  --json
  --help, --version

Notes:
  --status=released is valid for file-lock and release-tag only.
  Using it with flyway or model-registry is rejected (use
  --status=shipped --release-tag vX.Y.Z instead). See D-013.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --resource) RESOURCE="$2"; shift 2 ;;
    --section)  SECTION="$2"; shift 2 ;;
    --epic)     EPIC="$2"; shift 2 ;;
    --id)       ID="$2"; shift 2 ;;
    --status)   STATUS="$2"; shift 2 ;;
    --release-tag) RELEASE_TAG="$2"; shift 2 ;;
    --product)  PRODUCT="$2"; shift 2 ;;
    --json)     EMIT_JSON=1; shift ;;
    --help|-h)  print_help; exit 0 ;;
    --version)  print_version; exit 0 ;;
    *) log_err "Unknown argument: $1"; print_help; exit 2 ;;
  esac
done

require_tools

for var_name in RESOURCE SECTION EPIC ID STATUS; do
  eval "v=\$$var_name"
  # shellcheck disable=SC2154
  if [ -z "$v" ]; then
    log_err "Missing required arg: --$(echo "$var_name" | tr '[:upper:]' '[:lower:]')"
    exit 2
  fi
done

case "$STATUS" in
  shipped|released) ;;
  *) log_err "Invalid --status: $STATUS (expected shipped|released)"; exit 2 ;;
esac

if [ "$STATUS" = "shipped" ] && [ -z "$RELEASE_TAG" ]; then
  log_err "--release-tag is required when --status=shipped"
  exit 2
fi

case "$RESOURCE" in
  flyway|model-registry|file-lock|release-tag) ;;
  *) log_err "Invalid --resource: $RESOURCE"; exit 2 ;;
esac

# For flyway and model-registry, the only meaningful terminal status is
# "shipped" (with a real release_tag). "released" on those resources
# would append a row with an empty release_tag, which fails schema
# validation (semverTag rejects empty string). file-lock and release-tag
# legitimately use --status=released. See docs/decisions.md (D-013).
if [ "$STATUS" = "released" ]; then
  case "$RESOURCE" in
    file-lock|release-tag) ;;
    flyway|model-registry)
      log_err "--status=released is not valid for --resource=$RESOURCE (use --status=shipped with --release-tag)"
      exit 2
      ;;
  esac
fi

validate_section "$SECTION"

YML="$(resolve_yml_path "$PRODUCT")"
NOW="$(iso_now)"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

case "$RESOURCE" in
  flyway)
    # Remove from .flyway.reserved, append to .flyway.shipped.
    yq "
      .flyway.shipped += [{
        \"version\": \"$ID\",
        \"section\": \"$SECTION\",
        \"epic\": \"$EPIC\",
        \"release_tag\": \"$RELEASE_TAG\",
        \"shipped_at\": \"$NOW\"
      }] |
      .flyway.reserved |= map(select(.version != \"$ID\"))
    " "$YML" > "$TMP"
    ;;
  model-registry)
    yq "
      .model_registry.shipped += [{
        \"surface\": \"$ID\",
        \"section\": \"$SECTION\",
        \"epic\": \"$EPIC\",
        \"release_tag\": \"$RELEASE_TAG\",
        \"shipped_at\": \"$NOW\"
      }] |
      .model_registry.pending |= map(select(.surface != \"$ID\"))
    " "$YML" > "$TMP"
    ;;
  file-lock)
    # Clear held_by (set to none).
    yq "
      (.single_writer_files[] | select(.file == \"$ID\")) |= (
        .held_by = \"none\" | .until = \"$NOW\" | .reason = \"released via release.sh\"
      )
    " "$YML" > "$TMP"
    ;;
  release-tag)
    yq "
      .releases.in_flight |= ((. // []) | map(select(.proposed_tag != \"$ID\"))) |
      .releases.current_main = \"$ID\"
    " "$YML" > "$TMP"
    ;;
esac

cp "$TMP" "$YML"
log_info "Released $RESOURCE/$ID (status=$STATUS, epic=$EPIC, section=$SECTION)"

if ( cd "$REPO_ROOT" && git rev-parse --git-dir >/dev/null 2>&1 ); then
  git_pull_rebase || log_warn "rebase skipped"
  git_commit_and_push "chore(release): $EPIC releases $RESOURCE/$ID as $STATUS" || {
    log_err "push failed"
    if [ "$EMIT_JSON" = "1" ]; then
      emit_json "error" "git push failed"
    fi
    exit 1
  }
fi

if [ "$EMIT_JSON" = "1" ]; then
  emit_json "released" "$RESOURCE/$ID released by $EPIC as $STATUS"
fi
