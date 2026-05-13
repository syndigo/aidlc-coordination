#!/usr/bin/env bash
# shellcheck shell=bash
#
# reserve.sh — claim a shared resource in the AIDLC allocation registry.
#
# Atomic via local-clone + commit + git-push-with-rebase-retry. The audit
# trail is the linear commit history on main (ADR-D-004).
#
# Usage:
#   reserve.sh --resource <flyway|model-registry|file-lock|release-tag> \
#              --section <A..J> --epic <GDI-XXX> --id <V19|surface-id|filename|vX.Y.Z> \
#              [--product <name>] [--fr <FR-X.Y.Z>] [--ttl-hours N] [--json] [--dry-run]
#   reserve.sh --help
#   reserve.sh --version
#
# Exit codes:
#   0  reserved successfully (or idempotent no-op — already held by same epic)
#   1  generic error
#   2  invalid argument / not found
#   3  conflict (someone else holds the resource)
#   127 missing dependency (yq, git)

# shellcheck source=_lib.sh
. "$(dirname "$0")/_lib.sh"

# ----- argv -----------------------------------------------------------------

RESOURCE=""
SECTION=""
EPIC=""
ID=""
PRODUCT="$DEFAULT_PRODUCT"
FR=""
TTL_HOURS=24
EMIT_JSON=0
DRY_RUN=0

print_help() {
  cat <<'USAGE'
reserve.sh — claim a shared resource in the AIDLC allocation registry.

Required:
  --resource <flyway|model-registry|file-lock|release-tag>
  --section <A..J>
  --epic <GDI-XXX>            Jira key OR a section-local epic identifier
  --id <id>                   Flyway version, surface name, file path, or semver tag

Optional:
  --product <name>            Default: ugc-platform
  --fr <FR-X.Y.Z>             Functional requirement reference
  --ttl-hours N               Hours until expiry (default: 24)
  --json                      Emit structured JSON on stdout
  --dry-run                   Plan only; do not edit/commit/push
  --help, --version
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --resource) RESOURCE="$2"; shift 2 ;;
    --section)  SECTION="$2"; shift 2 ;;
    --epic)     EPIC="$2"; shift 2 ;;
    --id)       ID="$2"; shift 2 ;;
    --product)  PRODUCT="$2"; shift 2 ;;
    --fr)       FR="$2"; shift 2 ;;
    --ttl-hours) TTL_HOURS="$2"; shift 2 ;;
    --json)     EMIT_JSON=1; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --help|-h)  print_help; exit 0 ;;
    --version)  print_version; exit 0 ;;
    *) log_err "Unknown argument: $1"; print_help; exit 2 ;;
  esac
done

require_tools

# ----- validate inputs ------------------------------------------------------

for var_name in RESOURCE SECTION EPIC ID; do
  eval "v=\$$var_name"
  # shellcheck disable=SC2154
  if [ -z "$v" ]; then
    log_err "Missing required arg: --${var_name}" | tr '[:upper:]' '[:lower:]'
    exit 2
  fi
done

case "$RESOURCE" in
  flyway|model-registry|file-lock|release-tag) ;;
  *) log_err "Invalid --resource: $RESOURCE"; exit 2 ;;
esac

validate_section "$SECTION"

case "$RESOURCE" in
  flyway)        validate_flyway_version "$ID" ;;
  release-tag)   validate_semver_tag "$ID" ;;
esac

YML="$(resolve_yml_path "$PRODUCT")"

# ----- compute expiry -------------------------------------------------------

NOW="$(iso_now)"
# Portable expiry calc: BSD date on macOS uses -v; GNU date uses -d.
if date -u -v+1H +"%Y-%m-%dT%H:%M:%SZ" >/dev/null 2>&1; then
  EXPIRES_AT="$(date -u -v+"${TTL_HOURS}"H +"%Y-%m-%dT%H:%M:%SZ")"
else
  EXPIRES_AT="$(date -u -d "+${TTL_HOURS} hours" +"%Y-%m-%dT%H:%M:%SZ")"
fi

# ----- idempotency check ----------------------------------------------------
# If the same epic already holds this resource, exit 0 immediately.

already_held_same_epic() {
  case "$RESOURCE" in
    flyway)
      held_epic="$(yq -r ".flyway.reserved[] | select(.version == \"$ID\") | .epic // \"\"" "$YML")"
      ;;
    model-registry)
      held_epic="$(yq -r ".model_registry.pending[] | select(.surface == \"$ID\") | .epic // \"\"" "$YML")"
      ;;
    file-lock)
      held_epic="$(yq -r ".single_writer_files[] | select(.file == \"$ID\") | .held_by // \"\"" "$YML")"
      ;;
    release-tag)
      held_epic="$(yq -r ".releases.in_flight[]? | select(.proposed_tag == \"$ID\") | .epic // \"\"" "$YML")"
      ;;
  esac
  if [ "$held_epic" = "$EPIC" ]; then
    return 0
  fi
  return 1
}

# ----- conflict check -------------------------------------------------------

held_by_other_epic() {
  case "$RESOURCE" in
    flyway)
      held_epic="$(yq -r ".flyway.reserved[] | select(.version == \"$ID\") | .epic // \"\"" "$YML")"
      ;;
    model-registry)
      held_epic="$(yq -r ".model_registry.pending[] | select(.surface == \"$ID\") | .epic // \"\"" "$YML")"
      ;;
    file-lock)
      held_epic="$(yq -r ".single_writer_files[] | select(.file == \"$ID\") | .held_by // \"\"" "$YML")"
      ;;
    release-tag)
      held_epic="$(yq -r ".releases.in_flight[]? | select(.proposed_tag == \"$ID\") | .epic // \"\"" "$YML")"
      ;;
  esac
  if [ -z "$held_epic" ] || [ "$held_epic" = "none" ] || [ "$held_epic" = "null" ]; then
    return 1
  fi
  printf '%s' "$held_epic"
  return 0
}

# ----- main -----------------------------------------------------------------

if already_held_same_epic; then
  log_info "Already reserved by $EPIC ($RESOURCE/$ID) — idempotent no-op"
  if [ "$EMIT_JSON" = "1" ]; then
    emit_json "reserved" "idempotent — already held by $EPIC"
  fi
  exit 0
fi

other_holder="$(held_by_other_epic || true)"
if [ -n "$other_holder" ] && [ "$other_holder" != "$EPIC" ]; then
  log_err "Conflict: $RESOURCE/$ID is held by $other_holder (not $EPIC)"
  if [ "$EMIT_JSON" = "1" ]; then
    emit_json "wait" "held_by=$other_holder"
  fi
  exit 3
fi

# Apply the edit.
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

case "$RESOURCE" in
  flyway)
    fr_field="$FR"
    yq "
      .flyway.reserved += [{
        \"version\": \"$ID\",
        \"section\": \"$SECTION\",
        \"epic\": \"$EPIC\",
        \"fr\": \"$fr_field\",
        \"status\": \"reserved\",
        \"reserved_at\": \"$NOW\",
        \"expires_at\": \"$EXPIRES_AT\"
      }]
    " "$YML" > "$TMP"
    ;;
  model-registry)
    yq "
      .model_registry.pending += [{
        \"surface\": \"$ID\",
        \"section\": \"$SECTION\",
        \"epic\": \"$EPIC\",
        \"fr\": \"$FR\",
        \"status\": \"reserved\",
        \"reserved_at\": \"$NOW\",
        \"expires_at\": \"$EXPIRES_AT\"
      }]
    " "$YML" > "$TMP"
    ;;
  file-lock)
    # If the file already exists in single_writer_files, update held_by;
    # otherwise append a new entry.
    exists="$(yq -r ".single_writer_files[] | select(.file == \"$ID\") | .file" "$YML")"
    if [ -n "$exists" ]; then
      yq "
        (.single_writer_files[] | select(.file == \"$ID\")) |= (
          .held_by = \"$EPIC\" | .until = \"$EXPIRES_AT\" | .reason = \"reserved via reserve.sh\"
        )
      " "$YML" > "$TMP"
    else
      yq "
        .single_writer_files += [{
          \"file\": \"$ID\",
          \"held_by\": \"$EPIC\",
          \"until\": \"$EXPIRES_AT\",
          \"reason\": \"reserved via reserve.sh\"
        }]
      " "$YML" > "$TMP"
    fi
    ;;
  release-tag)
    yq "
      .releases.in_flight = (.releases.in_flight // []) + [{
        \"section\": \"$SECTION\",
        \"epic\": \"$EPIC\",
        \"proposed_tag\": \"$ID\",
        \"anchor_sha\": \"pending\"
      }]
    " "$YML" > "$TMP"
    ;;
esac

if [ "$DRY_RUN" = "1" ]; then
  log_info "[dry-run] would write:"
  diff -u "$YML" "$TMP" || true
  exit 0
fi

cp "$TMP" "$YML"
log_info "Reserved $RESOURCE/$ID for $EPIC (section $SECTION) until $EXPIRES_AT"

# Commit + push (best-effort; if not in a git repo or no remote, just write).
if ( cd "$REPO_ROOT" && git rev-parse --git-dir >/dev/null 2>&1 ); then
  git_pull_rebase || log_warn "rebase skipped"
  git_commit_and_push "chore(reserve): $EPIC reserves $RESOURCE/$ID (section $SECTION)" || {
    log_err "push failed"
    if [ "$EMIT_JSON" = "1" ]; then
      emit_json "error" "git push failed"
    fi
    exit 1
  }
fi

if [ "$EMIT_JSON" = "1" ]; then
  emit_json "reserved" "$RESOURCE/$ID reserved by $EPIC until $EXPIRES_AT"
fi
