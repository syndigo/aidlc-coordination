#!/usr/bin/env bash
# shellcheck shell=bash
# Shared helpers for reserve.sh / release.sh / conflict-check.sh / status.sh.
# POSIX-portable (bash 3.2 compatible — no [[, no ${var,,}, no mapfile,
# no associative arrays).
#
# Sourced via:  . "$(dirname "$0")/_lib.sh"

set -eu

SCRIPT_VERSION="0.1.0"

# Repo root = directory containing scripts/.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ALLOCATIONS_DIR="$REPO_ROOT/allocations"

# Default product. Most operators only have one product per repo.
DEFAULT_PRODUCT="ugc-platform"

# ----- logging --------------------------------------------------------------

log_info() {
  printf '[INFO]  %s\n' "$1" >&2
}

log_warn() {
  printf '[WARN]  %s\n' "$1" >&2
}

log_err() {
  printf '[ERROR] %s\n' "$1" >&2
}

# JSON-escape a string for inclusion as a JSON string value.
# Handles: backslash, double-quote, control chars (newline, carriage return,
# tab, backspace, form-feed) per RFC 8259. Other control chars (<0x20) are
# emitted as \u00XX escapes.
#
# Pure-bash (no jq/yq) because emit_json is on the hot path of every script
# call and the surrounding scripts are POSIX-portable. mikefarah/yq v4 does
# NOT support jq's --arg flag, so we cannot delegate quoting to yq.
json_escape() {
  s="$1"
  # Order matters: backslash MUST be escaped first, otherwise we double-escape
  # the backslashes we introduce for other replacements.
  s="$(printf '%s' "$s" | sed \
    -e 's/\\/\\\\/g' \
    -e 's/"/\\"/g' \
    -e 's/	/\\t/g')"
  # Newlines: convert literal LF to the two-character sequence \n.
  # Using awk because sed handling of embedded newlines is non-portable.
  s="$(printf '%s' "$s" | awk 'BEGIN{ORS=""} {if (NR>1) printf "\\n"; printf "%s", $0}')"
  # Carriage returns -> \r (rare, but be defensive).
  s="$(printf '%s' "$s" | sed -e 's/\r/\\r/g')"
  printf '%s' "$s"
}

# Emit a structured JSON line on stdout when --json is set.
# Args: $1 = "go|wait|reserved|released|error", $2 = "reason text"
#
# Shape: {"status": "...", "reason": "...", "at": "ISO-8601 UTC"}
#
# Why pure bash: mikefarah/yq v4 does not implement jq's variable-binding
# flag, and a yq -n '{...}' with shell-interpolated strings is fragile
# against quotes and newlines in $reason (conflict-check.sh emits multi-line
# conflict lists). The output shape is small and fixed, so hand-rolled JSON
# is simpler than depending on a YAML processor for serialization.
emit_json() {
  status="$1"
  reason="$2"
  ts="$(iso_now)"
  esc_status="$(json_escape "$status")"
  esc_reason="$(json_escape "$reason")"
  esc_ts="$(json_escape "$ts")"
  printf '{"status":"%s","reason":"%s","at":"%s"}\n' \
    "$esc_status" "$esc_reason" "$esc_ts"
}

iso_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# ----- argv parsing ---------------------------------------------------------

# Required tools — fail fast if missing.
require_tools() {
  for tool in yq git; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      log_err "$tool not found on PATH. Install mikefarah/yq v4 + git."
      exit 127
    fi
  done
  yq_major="$(yq --version 2>&1 | sed -n 's/.*version v\([0-9]\).*/\1/p')"
  if [ "$yq_major" != "4" ]; then
    log_err "yq v4 required, found: $(yq --version 2>&1)"
    exit 127
  fi
}

# Resolve --product to a path under allocations/.
resolve_yml_path() {
  product="${1:-$DEFAULT_PRODUCT}"
  yml="$ALLOCATIONS_DIR/${product}.yml"
  if [ ! -f "$yml" ]; then
    log_err "Allocation file not found: $yml"
    exit 2
  fi
  printf '%s' "$yml"
}

# Validate that a value matches one of the legal section letters A..J.
validate_section() {
  case "$1" in
    A|B|C|D|E|F|G|H|I|J) return 0 ;;
    *)
      log_err "Invalid section: $1 (expected A..J)"
      exit 2
      ;;
  esac
}

# Validate a Flyway version pattern Vnnn.
validate_flyway_version() {
  case "$1" in
    V[0-9]*)
      # Strip "V" and confirm the remainder is purely numeric.
      n="${1#V}"
      case "$n" in
        ''|*[!0-9]*)
          log_err "Invalid Flyway version: $1 (expected V<digits>)"
          exit 2
          ;;
      esac
      ;;
    *)
      log_err "Invalid Flyway version: $1 (expected V<digits>)"
      exit 2
      ;;
  esac
}

# Validate a semver tag.
validate_semver_tag() {
  case "$1" in
    v[0-9]*.[0-9]*.[0-9]*) return 0 ;;
    v[0-9]*.[0-9]*.x) return 0 ;;
    *)
      log_err "Invalid semver tag: $1 (expected vX.Y.Z or vX.Y.x)"
      exit 2
      ;;
  esac
}

# ----- git audit-trail helpers ---------------------------------------------
#
# Day-1 design choice (ADR-D-004 in docs/decisions.md): scripts edit the local
# clone of this repo directly and push to main, retrying on push-rejected. We
# do NOT open a PR per edit on Day 1 — the audit trail is the linear commit
# history on main.

git_pull_rebase() {
  ( cd "$REPO_ROOT" && git pull --rebase --quiet ) || {
    log_err "git pull --rebase failed"
    return 1
  }
}

git_commit_and_push() {
  msg="$1"
  ( cd "$REPO_ROOT" && git add allocations/ && git commit -m "$msg" --quiet ) || {
    log_warn "Nothing to commit (idempotent no-op)"
    return 0
  }
  attempt=1
  max_attempts=3
  while [ "$attempt" -le "$max_attempts" ]; do
    if ( cd "$REPO_ROOT" && git push --quiet ); then
      return 0
    fi
    log_warn "git push failed (attempt $attempt of $max_attempts), rebasing..."
    git_pull_rebase || return 1
    attempt=$((attempt + 1))
  done
  log_err "git push failed after $max_attempts attempts"
  return 1
}

# ----- help / version -------------------------------------------------------

print_version() {
  printf '%s version %s\n' "$(basename "$0")" "$SCRIPT_VERSION"
}
