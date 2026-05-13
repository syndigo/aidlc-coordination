#!/usr/bin/env bash
# shellcheck shell=bash
#
# conflict-check.sh — pre-flight check for parallel SDLC sessions.
#
# Read-only by default. Returns GO if the section can proceed, WAIT (exit 1)
# if any required resource is held by a different epic. Use --claim to
# chain-call reserve.sh for the detected needs once you've decided to proceed.
#
# Usage:
#   conflict-check.sh --section <A..J> --fr <FR-X.Y.Z> \
#                     [--files-to-touch file1,file2,...] \
#                     [--flyway-versions V19,V20,...] \
#                     [--model-surfaces surface-a,surface-b,...] \
#                     [--product <name>] [--json] [--claim --epic <GDI-XXX>]
#   conflict-check.sh --help
#   conflict-check.sh --version
#
# Exit codes:
#   0  GO — no conflicts detected, or all resources already held by this section's epic
#   1  WAIT — at least one resource is held by a different epic
#   2  invalid argument
#   127 missing dependency

# shellcheck source=_lib.sh
. "$(dirname "$0")/_lib.sh"

SECTION=""
FR=""
FILES=""
FLYWAY_VERSIONS=""
MODEL_SURFACES=""
PRODUCT="$DEFAULT_PRODUCT"
EMIT_JSON=0
CLAIM=0
EPIC=""

print_help() {
  cat <<'USAGE'
conflict-check.sh — pre-flight check for parallel SDLC sessions.

Required:
  --section <A..J>
  --fr <FR-X.Y.Z>             Functional requirement reference

Optional:
  --files-to-touch <csv>      Comma-separated list of files about to be edited
  --flyway-versions <csv>     Comma-separated Flyway versions the work would claim
  --model-surfaces <csv>      Comma-separated model surfaces the work would claim
  --product <name>            Default: ugc-platform
  --json                      Emit structured JSON on stdout
  --claim                     If GO, chain-call reserve.sh for the detected needs
                              (requires --epic <GDI-XXX>)
  --epic <GDI-XXX>            Used with --claim
  --help, --version

Output:
  Human-readable summary on stderr. On stdout: "GO" or "WAIT: <reason>" by
  default; structured JSON if --json.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --section)  SECTION="$2"; shift 2 ;;
    --fr)       FR="$2"; shift 2 ;;
    --files-to-touch) FILES="$2"; shift 2 ;;
    --flyway-versions) FLYWAY_VERSIONS="$2"; shift 2 ;;
    --model-surfaces) MODEL_SURFACES="$2"; shift 2 ;;
    --product)  PRODUCT="$2"; shift 2 ;;
    --json)     EMIT_JSON=1; shift ;;
    --claim)    CLAIM=1; shift ;;
    --epic)     EPIC="$2"; shift 2 ;;
    --help|-h)  print_help; exit 0 ;;
    --version)  print_version; exit 0 ;;
    *) log_err "Unknown argument: $1"; print_help; exit 2 ;;
  esac
done

require_tools

if [ -z "$SECTION" ] || [ -z "$FR" ]; then
  log_err "Missing required args: --section and --fr"
  exit 2
fi
validate_section "$SECTION"

if [ "$CLAIM" = "1" ] && [ -z "$EPIC" ]; then
  log_err "--claim requires --epic"
  exit 2
fi

YML="$(resolve_yml_path "$PRODUCT")"

# ----- collect conflicts ----------------------------------------------------
#
# We accumulate conflict reasons into a single text block. If non-empty at
# the end, exit WAIT.

conflicts=""

add_conflict() {
  if [ -z "$conflicts" ]; then
    conflicts="$1"
  else
    conflicts="$conflicts
$1"
  fi
}

# Helper: iterate a CSV via positional params (works for both bash and POSIX sh).
# Sets the global $@ in the caller's scope when used via `set -- $(csv_split "$x")`.
csv_split() {
  printf '%s' "$1" | tr ',' ' '
}

# --- check files-to-touch against single_writer_files
if [ -n "$FILES" ]; then
  oldIFS="$IFS"
  IFS=','
  # shellcheck disable=SC2086
  set -- $FILES
  IFS="$oldIFS"
  for f in "$@"; do
    [ -z "$f" ] && continue
    # Match either full path or just the basename (basename is the common form).
    held="$(yq -r ".single_writer_files[] | select(.file == \"$f\" or (.file | test(\"/$f\$\"))) | .held_by // \"\"" "$YML")"
    if [ -n "$held" ] && [ "$held" != "none" ] && [ "$held" != "null" ]; then
      # Check whether this section already owns it (via the epic prefix).
      if printf '%s' "$held" | grep -q "section-${SECTION}-"; then
        log_info "self-hold OK: file=$f held_by_self=$held"
      else
        until_ts="$(yq -r ".single_writer_files[] | select(.file == \"$f\" or (.file | test(\"/$f\$\"))) | .until // \"\"" "$YML")"
        add_conflict "WAIT file=$f held_by=$held until=$until_ts"
      fi
    fi
  done
fi

# --- check Flyway versions
if [ -n "$FLYWAY_VERSIONS" ]; then
  oldIFS="$IFS"
  IFS=','
  # shellcheck disable=SC2086
  set -- $FLYWAY_VERSIONS
  IFS="$oldIFS"
  for v in "$@"; do
    [ -z "$v" ] && continue
    held="$(yq -r ".flyway.reserved[] | select(.version == \"$v\") | .epic // \"\"" "$YML")"
    if [ -n "$held" ] && [ "$held" != "null" ]; then
      held_section="$(yq -r ".flyway.reserved[] | select(.version == \"$v\") | .section // \"\"" "$YML")"
      if [ "$held_section" != "$SECTION" ]; then
        add_conflict "WAIT flyway=$v held_by=$held section=$held_section"
      fi
    fi
  done
fi

# --- check model surfaces (against pending)
if [ -n "$MODEL_SURFACES" ]; then
  oldIFS="$IFS"
  IFS=','
  # shellcheck disable=SC2086
  set -- $MODEL_SURFACES
  IFS="$oldIFS"
  for s in "$@"; do
    [ -z "$s" ] && continue
    held="$(yq -r ".model_registry.pending[] | select(.surface == \"$s\") | .epic // \"\"" "$YML")"
    if [ -n "$held" ] && [ "$held" != "null" ]; then
      held_section="$(yq -r ".model_registry.pending[] | select(.surface == \"$s\") | .section // \"\"" "$YML")"
      if [ "$held_section" != "$SECTION" ]; then
        add_conflict "WAIT model-surface=$s held_by=$held section=$held_section"
      fi
    fi
  done
fi

# --- check anchor dependencies (is THIS fr blocked by a not-yet-shipped anchor?)
anchor_block="$(yq -r ".anchor_dependencies[] | select(.status != \"shipped\" and (.consumers[] | select(.fr == \"$FR\" and .status == \"blocked_until_anchor_shipped\"))) | \"WAIT anchor=\" + .anchor + \" status=\" + .status" "$YML" 2>/dev/null || true)"
if [ -n "$anchor_block" ] && [ "$anchor_block" != "null" ]; then
  add_conflict "$anchor_block"
fi

# ----- emit result ----------------------------------------------------------

if [ -z "$conflicts" ]; then
  log_info "GO — section $SECTION may proceed with $FR"
  # GDI-728: resource locks don't protect against shared-clone working-tree
  # contamination. Recommend the worktree helper for concurrent-run safety.
  log_info "Recommended: isolate this session in a worktree to avoid shared-clone contamination:"
  log_info "  ./scripts/worktree.sh add --repo-path <PRODUCT_REPO_PATH> --epic <GDI-XXX> \\"
  log_info "    --branch feature/<GDI-XXX>-<slug> [--base-branch origin/dev]"
  if [ "$EMIT_JSON" = "1" ]; then
    emit_json "go" "section=$SECTION fr=$FR no conflicts"
  else
    printf 'GO\n'
  fi
  if [ "$CLAIM" = "1" ]; then
    log_info "[--claim] chaining to reserve.sh for detected needs..."
    if [ -n "$FILES" ]; then
      oldIFS="$IFS"; IFS=','
      # shellcheck disable=SC2086
      set -- $FILES
      IFS="$oldIFS"
      for f in "$@"; do
        [ -z "$f" ] && continue
        "$(dirname "$0")/reserve.sh" --resource file-lock --section "$SECTION" \
          --epic "$EPIC" --id "$f" --fr "$FR" --product "$PRODUCT" || true
      done
    fi
    if [ -n "$FLYWAY_VERSIONS" ]; then
      oldIFS="$IFS"; IFS=','
      # shellcheck disable=SC2086
      set -- $FLYWAY_VERSIONS
      IFS="$oldIFS"
      for v in "$@"; do
        [ -z "$v" ] && continue
        "$(dirname "$0")/reserve.sh" --resource flyway --section "$SECTION" \
          --epic "$EPIC" --id "$v" --fr "$FR" --product "$PRODUCT" || true
      done
    fi
    if [ -n "$MODEL_SURFACES" ]; then
      oldIFS="$IFS"; IFS=','
      # shellcheck disable=SC2086
      set -- $MODEL_SURFACES
      IFS="$oldIFS"
      for s in "$@"; do
        [ -z "$s" ] && continue
        "$(dirname "$0")/reserve.sh" --resource model-registry --section "$SECTION" \
          --epic "$EPIC" --id "$s" --fr "$FR" --product "$PRODUCT" || true
      done
    fi
  fi
  exit 0
fi

log_warn "WAIT — section $SECTION cannot proceed with $FR:"
printf '%s\n' "$conflicts" >&2
if [ "$EMIT_JSON" = "1" ]; then
  emit_json "wait" "$conflicts"
else
  printf 'WAIT:\n%s\n' "$conflicts"
fi
exit 1
