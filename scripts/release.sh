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
#   release.sh --all-for-epic <GDI-XXX> [--reason "<text>"] \
#              [--product <name>] [--json] [--dry-run]
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
# --all-for-epic mode (GDI-798):
#   Sweeps EVERY remaining reservation in the registry whose epic
#   matches <KEY> and releases each one in a single commit:
#     - flyway.reserved entries           -> dropped (status=abandoned semantics)
#     - flyway.test_fixture_range.reserved -> dropped
#     - model_registry.pending entries    -> dropped
#     - single_writer_files held_by==KEY  -> cleared to held_by=none
#     - releases.in_flight entries        -> dropped
#   Use after Stage 10 of an epic to clean up older-version reservations
#   that were superseded by the canonical ship (e.g. GDI-800 shipped V32
#   but left V22, V923 reserved under the same epic). Idempotent: re-run
#   safely returns 0 with zero sweep count.
#
#   --reason is optional (default: "swept via --all-for-epic after Stage 10")
#   and is recorded in the git commit message for audit. See D-015.
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
REASON=""
PRODUCT="$DEFAULT_PRODUCT"
EMIT_JSON=0
# GDI-798: --all-for-epic <KEY> sweeps every remaining reservation in the
# registry whose epic matches <KEY>. Mutually exclusive with --resource mode.
ALL_FOR_EPIC=""
DRY_RUN=0
# D-020 (P1.3): --sweep-expired finds every reservation whose expires_at
# is in the past and abandons each (drops from reserved arrays; no shipped
# append). Mutually exclusive with --resource and --all-for-epic modes.
# Audit finding 6 in reports/contention-audit-2026-05-14.md.
SWEEP_EXPIRED=0
# D-016 Day-2: --update-pillars-block opt-in flag fires three hooks that
# bring pillars[]/anchor_dependencies/releases.in_flight in sync with the
# per-resource edit this call is making. Opt-in for one release cycle to
# de-risk the rollout (audit findings 1, 2, 5 in
# reports/contention-audit-2026-05-14.md). --fr is required when the flag
# is set so the pillar-block hook knows which FR id to move.
UPDATE_PILLARS=0
FR=""

print_help() {
  cat <<'USAGE'
release.sh — mark a reserved resource as shipped or released.

Per-resource mode (required args):
  --resource <flyway|model-registry|file-lock|release-tag|release-band>
  --section <A..J>
  --epic <GDI-XXX>
  --id <id>
  --status <shipped|released|abandoned>

Sweep mode (GDI-798):
  --all-for-epic <GDI-XXX>    Mutually exclusive with --resource. Releases
                              every remaining reservation in the registry
                              whose epic matches the given key:
                                * flyway.reserved        -> dropped
                                * flyway.test_fixture... -> dropped
                                * model_registry.pending -> dropped
                                * single_writer_files    -> held_by=none
                                * releases.in_flight     -> dropped
                              Use after Stage 10 to sweep stale older-version
                              reservations left behind by the canonical ship.
                              Idempotent — zero matches exits 0.

Sweep mode (D-020 / P1.3):
  --sweep-expired             Mutually exclusive with --resource and
                              --all-for-epic. Drops every reservation whose
                              expires_at is in the past:
                                * flyway.reserved        -> dropped
                                * flyway.test_fixture... -> dropped
                                * model_registry.pending -> dropped
                              Does NOT touch single_writer_files (those have
                              their own .until field, cleared by the file's
                              next reservation, not on a wall-clock sweep).
                              Does NOT touch releases.in_flight (those are
                              pruned by P0 hooks at ship time).
                              Use --dry-run to preview the sweep first.
                              Idempotent — zero expired entries exits 0.

Optional:
  --release-tag <vX.Y.Z>      Required for status=shipped; ignored otherwise
  --reason "<text>"           Required for status=abandoned (audit trail).
                              Optional for --all-for-epic (defaults to
                              "swept via --all-for-epic after Stage 10").
  --product <name>            Default: ugc-platform
  --fr <FR-X.Y.Z>             Functional requirement id. Required when
                              --update-pillars-block is set; otherwise
                              recorded in the commit message only.
  --update-pillars-block      D-016 Day-2 opt-in: also reconcile pillars[],
                              anchor_dependencies[], and releases.in_flight[]
                              to reflect this release. Three hooks fire
                              after the per-resource edit:
                                1. move --fr from
                                   pillars[<section>].in_flight_frs to
                                   pillars[<section>].shipped_frs (on shipped)
                                   or just remove from in_flight_frs (on
                                   released/abandoned). Idempotent.
                                2. if --fr matches an anchor in
                                   anchor_dependencies, set status=shipped
                                   + shipped_at + shipped_release (on shipped).
                                3. for flyway/model-registry shipped
                                   resources, drop matching releases.in_flight
                                   entry (where epic+release-tag match).
                              See reports/contention-audit-2026-05-14.md.
  --dry-run                   Print the diff that WOULD apply (or, in
                              --all-for-epic mode, the planned sweep), then
                              exit 0 without editing or committing. Use to
                              test --update-pillars-block hooks against a
                              sandbox YAML before flipping the default.
  --json
  --help, --version

Notes:
  --status=released is valid for file-lock and release-tag only.
  Using it with flyway or model-registry is rejected (use
  --status=shipped --release-tag vX.Y.Z instead). See D-013.

  --status=abandoned (GDI-770 retro) is the clean exit for a stale
  reservation that will NEVER ship — e.g. when a sibling tab raced
  for the same Flyway version and won, or when the operator chose
  a different version mid-flight. Removes the reserved row entirely
  (no shipped append). Requires --reason so the git commit message
  carries the audit trail. Valid for flyway and model-registry.
  Use this instead of letting reservations TTL-expire silently.

  --all-for-epic (GDI-798) is the orphan-sweep for after Stage 10.
  Stage 10 only releases the canonical resource the ticket named on
  the way in; older-version reservations under the same epic remain
  stale until manually swept. This flag does the sweep in one commit.
  See D-015.
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
    --reason)   REASON="$2"; shift 2 ;;
    --product)  PRODUCT="$2"; shift 2 ;;
    --all-for-epic) ALL_FOR_EPIC="$2"; shift 2 ;;
    --sweep-expired) SWEEP_EXPIRED=1; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --update-pillars-block) UPDATE_PILLARS=1; shift ;;
    --fr)       FR="$2"; shift 2 ;;
    --json)     EMIT_JSON=1; shift ;;
    --help|-h)  print_help; exit 0 ;;
    --version)  print_version; exit 0 ;;
    *) log_err "Unknown argument: $1"; print_help; exit 2 ;;
  esac
done

require_tools

# GDI-798: --all-for-epic mode is mutually exclusive with per-resource args.
# We branch early so the per-resource required-arg checks are skipped.
if [ -n "$ALL_FOR_EPIC" ]; then
  if [ -n "$RESOURCE" ] || [ -n "$ID" ] || [ -n "$STATUS" ] || [ "$SWEEP_EXPIRED" = "1" ]; then
    log_err "--all-for-epic is mutually exclusive with --resource/--id/--status and --sweep-expired"
    exit 2
  fi
  # Default reason for audit trail; operator may override via --reason.
  if [ -z "$REASON" ]; then
    REASON="swept via --all-for-epic after Stage 10"
  fi

  YML="$(resolve_yml_path "$PRODUCT")"
  NOW="$(iso_now)"

  # Enumerate everything that matches the epic, BEFORE editing. The lists
  # are emitted as line-delimited values (POSIX-portable; no associative
  # arrays). Empty stdout = zero matches in that category.
  flyway_matches="$(yq -r ".flyway.reserved // [] | map(select(.epic == \"$ALL_FOR_EPIC\")) | .[].version" "$YML")"
  fixture_matches="$(yq -r ".flyway.test_fixture_range.reserved // [] | map(select(.epic == \"$ALL_FOR_EPIC\")) | .[].version" "$YML")"
  model_matches="$(yq -r ".model_registry.pending // [] | map(select(.epic == \"$ALL_FOR_EPIC\")) | .[].surface" "$YML")"
  file_matches="$(yq -r ".single_writer_files // [] | map(select(.held_by == \"$ALL_FOR_EPIC\")) | .[].file" "$YML")"
  tag_matches="$(yq -r ".releases.in_flight // [] | map(select(.epic == \"$ALL_FOR_EPIC\")) | .[].proposed_tag" "$YML")"

  # Count matches across all categories. Use a simple newline-count guard
  # against empty strings (which `wc -l` would still count as 1 on some
  # platforms).
  count_lines() {
    if [ -z "$1" ]; then
      printf '0'
    else
      printf '%s\n' "$1" | grep -c .
    fi
  }
  n_flyway="$(count_lines "$flyway_matches")"
  n_fixture="$(count_lines "$fixture_matches")"
  n_model="$(count_lines "$model_matches")"
  n_file="$(count_lines "$file_matches")"
  n_tag="$(count_lines "$tag_matches")"
  total=$((n_flyway + n_fixture + n_model + n_file + n_tag))

  log_info "Sweep plan for epic=$ALL_FOR_EPIC in $PRODUCT:"
  log_info "  flyway.reserved              : $n_flyway"
  log_info "  flyway.test_fixture_range    : $n_fixture"
  log_info "  model_registry.pending       : $n_model"
  log_info "  single_writer_files held_by  : $n_file"
  log_info "  releases.in_flight           : $n_tag"
  log_info "  total                        : $total"

  if [ "$total" -eq 0 ]; then
    log_info "Idempotent no-op: no reservations matched epic=$ALL_FOR_EPIC"
    if [ "$EMIT_JSON" = "1" ]; then
      emit_json "released" "no-op: zero matches for epic=$ALL_FOR_EPIC"
    fi
    exit 0
  fi

  if [ "$DRY_RUN" = "1" ]; then
    log_info "--dry-run: no edits performed"
    if [ "$EMIT_JSON" = "1" ]; then
      emit_json "released" "dry-run: $total matches for epic=$ALL_FOR_EPIC"
    fi
    exit 0
  fi

  TMP="$(mktemp)"
  trap 'rm -f "$TMP"' EXIT

  # Single yq pass that drops every matching reservation across all four
  # registry sections and clears file-lock held_by where held_by==KEY.
  # Why one pass: a single commit keeps the audit trail clean and avoids
  # partial-state if any intermediate write fails.
  yq "
    .flyway.reserved |= ((. // []) | map(select(.epic != \"$ALL_FOR_EPIC\"))) |
    .flyway.test_fixture_range.reserved |= ((. // []) | map(select(.epic != \"$ALL_FOR_EPIC\"))) |
    .model_registry.pending |= ((. // []) | map(select(.epic != \"$ALL_FOR_EPIC\"))) |
    (.single_writer_files[] | select(.held_by == \"$ALL_FOR_EPIC\")) |= (
      .held_by = \"none\" | .until = \"$NOW\" | .reason = \"released via release.sh --all-for-epic\"
    ) |
    .releases.in_flight |= ((. // []) | map(select(.epic != \"$ALL_FOR_EPIC\")))
  " "$YML" > "$TMP"
  cp "$TMP" "$YML"

  # Build a compact summary line per category for the commit body.
  summary=""
  if [ "$n_flyway" -gt 0 ]; then
    flat="$(printf '%s' "$flyway_matches" | tr '\n' ',' | sed 's/,$//')"
    summary="${summary}flyway: $flat
"
  fi
  if [ "$n_fixture" -gt 0 ]; then
    flat="$(printf '%s' "$fixture_matches" | tr '\n' ',' | sed 's/,$//')"
    summary="${summary}fixture: $flat
"
  fi
  if [ "$n_model" -gt 0 ]; then
    flat="$(printf '%s' "$model_matches" | tr '\n' ',' | sed 's/,$//')"
    summary="${summary}model-registry: $flat
"
  fi
  if [ "$n_file" -gt 0 ]; then
    flat="$(printf '%s' "$file_matches" | tr '\n' ',' | sed 's/,$//')"
    summary="${summary}file-lock: $flat
"
  fi
  if [ "$n_tag" -gt 0 ]; then
    flat="$(printf '%s' "$tag_matches" | tr '\n' ',' | sed 's/,$//')"
    summary="${summary}release-tag: $flat
"
  fi

  log_info "Swept $total reservation(s) for epic=$ALL_FOR_EPIC"

  if ( cd "$REPO_ROOT" && git rev-parse --git-dir >/dev/null 2>&1 ); then
    git_pull_rebase || log_warn "rebase skipped"
    commit_msg="chore(release): sweep $total orphan reservation(s) for $ALL_FOR_EPIC

Reason: $REASON

$summary"
    git_commit_and_push "$commit_msg" "$YML" || {
      log_err "push failed"
      if [ "$EMIT_JSON" = "1" ]; then
        emit_json "error" "git push failed"
      fi
      exit 1
    }
  fi

  if [ "$EMIT_JSON" = "1" ]; then
    emit_json "released" "swept $total reservation(s) for epic=$ALL_FOR_EPIC"
  fi
  exit 0
fi

# D-020 (P1.3): --sweep-expired branch. Mutually exclusive with --resource
# and --all-for-epic; validated above when --all-for-epic was set, here
# when --sweep-expired is set.
if [ "$SWEEP_EXPIRED" = "1" ]; then
  if [ -n "$RESOURCE" ] || [ -n "$ID" ] || [ -n "$STATUS" ] || [ -n "$ALL_FOR_EPIC" ]; then
    log_err "--sweep-expired is mutually exclusive with --resource, --id, --status, and --all-for-epic"
    exit 2
  fi

  YML="$(resolve_yml_path "$PRODUCT")"
  NOW="$(iso_now)"

  # ISO-8601 timestamps are sortable as strings, so `expires_at < NOW`
  # works without parsing into epoch. Enumerate matches by category for
  # the audit summary, then drop them in a single yq pass.
  export H_NOW="$NOW"
  flyway_expired="$(yq -r "
    .flyway.reserved // [] | map(select(.expires_at != null and .expires_at < strenv(H_NOW))) | .[].version
  " "$YML")"
  fixture_expired="$(yq -r "
    .flyway.test_fixture_range.reserved // [] | map(select(.expires_at != null and .expires_at < strenv(H_NOW))) | .[].version
  " "$YML")"
  model_expired="$(yq -r "
    .model_registry.pending // [] | map(select(.expires_at != null and .expires_at < strenv(H_NOW))) | .[].surface
  " "$YML")"

  count_lines() {
    if [ -z "$1" ]; then
      printf '0'
    else
      printf '%s\n' "$1" | grep -c .
    fi
  }
  n_flyway="$(count_lines "$flyway_expired")"
  n_fixture="$(count_lines "$fixture_expired")"
  n_model="$(count_lines "$model_expired")"
  total=$((n_flyway + n_fixture + n_model))

  log_info "Sweep-expired plan for $PRODUCT (cutoff=$NOW):"
  log_info "  flyway.reserved              : $n_flyway"
  log_info "  flyway.test_fixture_range    : $n_fixture"
  log_info "  model_registry.pending       : $n_model"
  log_info "  total                        : $total"

  if [ "$total" -eq 0 ]; then
    log_info "Idempotent no-op: no expired reservations"
    if [ "$EMIT_JSON" = "1" ]; then
      emit_json "released" "no-op: zero expired reservations"
    fi
    exit 0
  fi

  if [ "$DRY_RUN" = "1" ]; then
    log_info "--dry-run: no edits performed. Expired entries that would drop:"
    [ -n "$flyway_expired" ] && printf '  flyway: %s\n' "$flyway_expired" | tr '\n' ' '
    [ -n "$fixture_expired" ] && printf '  fixture: %s\n' "$fixture_expired" | tr '\n' ' '
    [ -n "$model_expired" ] && printf '  model: %s\n' "$model_expired" | tr '\n' ' '
    printf '\n'
    if [ "$EMIT_JSON" = "1" ]; then
      emit_json "released" "dry-run: $total expired reservations"
    fi
    exit 0
  fi

  TMP="$(mktemp)"
  trap 'rm -f "$TMP"' EXIT

  yq "
    .flyway.reserved |= ((. // []) | map(select(.expires_at == null or .expires_at >= strenv(H_NOW)))) |
    .flyway.test_fixture_range.reserved |= ((. // []) | map(select(.expires_at == null or .expires_at >= strenv(H_NOW)))) |
    .model_registry.pending |= ((. // []) | map(select(.expires_at == null or .expires_at >= strenv(H_NOW))))
  " "$YML" > "$TMP"
  cp "$TMP" "$YML"

  log_info "Swept $total expired reservation(s)"

  if ( cd "$REPO_ROOT" && git rev-parse --git-dir >/dev/null 2>&1 ); then
    git_pull_rebase || log_warn "rebase skipped"
    summary=""
    [ "$n_flyway" -gt 0 ] && summary="${summary}flyway: $(printf '%s' "$flyway_expired" | tr '\n' ',' | sed 's/,$//')\n"
    [ "$n_fixture" -gt 0 ] && summary="${summary}fixture: $(printf '%s' "$fixture_expired" | tr '\n' ',' | sed 's/,$//')\n"
    [ "$n_model" -gt 0 ] && summary="${summary}model-registry: $(printf '%s' "$model_expired" | tr '\n' ',' | sed 's/,$//')\n"
    commit_msg="chore(release): sweep $total expired reservation(s)

Cutoff: $NOW

$(printf '%b' "$summary")"
    git_commit_and_push "$commit_msg" "$YML" || {
      log_err "push failed"
      if [ "$EMIT_JSON" = "1" ]; then
        emit_json "error" "git push failed"
      fi
      exit 1
    }
  fi

  if [ "$EMIT_JSON" = "1" ]; then
    emit_json "released" "swept $total expired reservation(s)"
  fi
  exit 0
fi

for var_name in RESOURCE SECTION EPIC ID STATUS; do
  eval "v=\$$var_name"
  # shellcheck disable=SC2154
  if [ -z "$v" ]; then
    log_err "Missing required arg: --$(echo "$var_name" | tr '[:upper:]' '[:lower:]')"
    exit 2
  fi
done

# D-016 Day-2: --update-pillars-block requires --fr so the pillar-block
# hook knows which FR id to move between in_flight_frs and shipped_frs.
# Without --fr we'd have to guess which FR this resource backed, and
# guessing was the original bug (pillar block stayed empty for months).
if [ "$UPDATE_PILLARS" = "1" ] && [ -z "$FR" ]; then
  log_err "--update-pillars-block requires --fr <FR-X.Y.Z>"
  log_err "  The pillar-block hook needs the FR id to move it from"
  log_err "  pillars[<section>].in_flight_frs to .shipped_frs."
  exit 2
fi

case "$STATUS" in
  shipped|released|abandoned) ;;
  *) log_err "Invalid --status: $STATUS (expected shipped|released|abandoned)"; exit 2 ;;
esac

if [ "$STATUS" = "shipped" ] && [ -z "$RELEASE_TAG" ]; then
  log_err "--release-tag is required when --status=shipped"
  exit 2
fi

if [ "$STATUS" = "abandoned" ] && [ -z "$REASON" ]; then
  log_err "--reason is required when --status=abandoned (audit trail in git commit message)"
  exit 2
fi

case "$RESOURCE" in
  flyway|model-registry|file-lock|release-tag|release-band) ;;
  *) log_err "Invalid --resource: $RESOURCE"; exit 2 ;;
esac

# For flyway and model-registry, the only meaningful terminal status is
# "shipped" (with a real release_tag). "released" on those resources
# would append a row with an empty release_tag, which fails schema
# validation (semverTag rejects empty string). file-lock, release-tag, and
# release-band legitimately use --status=released. See docs/decisions.md (D-013).
if [ "$STATUS" = "released" ]; then
  case "$RESOURCE" in
    file-lock|release-tag|release-band) ;;
    flyway|model-registry)
      log_err "--status=released is not valid for --resource=$RESOURCE (use --status=shipped with --release-tag, or --status=abandoned --reason ... to drop a stale reservation)"
      exit 2
      ;;
  esac
fi

# --status=abandoned is for flyway/model-registry only (drops the reservation
# without a shipped row). file-lock/release-tag/release-band use --status=released.
if [ "$STATUS" = "abandoned" ]; then
  case "$RESOURCE" in
    flyway|model-registry) ;;
    file-lock|release-tag|release-band)
      log_err "--status=abandoned is not valid for --resource=$RESOURCE (use --status=released for file-lock/release-tag/release-band)"
      exit 2
      ;;
  esac
fi

validate_section "$SECTION"

YML="$(resolve_yml_path "$PRODUCT")"
NOW="$(iso_now)"

# D-016 Day-2 hooks. These run AFTER the per-resource yq edit applies to
# the temp file but BEFORE we cp the temp back over $YML. Composing into
# the same temp file keeps the whole change in one commit; if any hook
# fails (e.g., pillar letter doesn't exist in pillars[]), the whole
# release.sh call exits without mutating the registry.
#
# Args: $1 = path to the in-progress YAML temp file
# All hooks short-circuit when UPDATE_PILLARS=0.
update_pillar_block_hooks() {
  hook_target="$1"
  if [ "$UPDATE_PILLARS" != "1" ]; then
    return 0
  fi

  # Confirm pillars[] block exists; if not, the product hasn't adopted the
  # tier yet -- skip silently so the flag is safe to set unconditionally
  # in /sdlc Stage 10 wiring.
  has_pillars="$(yq -r '(.pillars // []) | length' "$hook_target")"
  if [ "$has_pillars" = "0" ]; then
    log_warn "--update-pillars-block: no pillars[] block in $YML; skipping hooks"
    return 0
  fi

  # --- Hook 1: pillars[<section>].{in_flight_frs, shipped_frs} ----------
  # On shipped: ensure FR appears in shipped_frs (idempotent), drop from
  #   in_flight_frs.
  # On released/abandoned: drop from in_flight_frs only (no shipped append).
  pillar_exists="$(yq -r ".pillars[]? | select(.letter == \"$SECTION\") | .letter" "$hook_target")"
  if [ -z "$pillar_exists" ]; then
    log_warn "--update-pillars-block: pillar $SECTION not in pillars[]; skipping pillar-block hook (anchor + in_flight hooks still run)"
  else
    case "$STATUS" in
      shipped)
        # Build the new YAML: remove FR from in_flight_frs, append to
        # shipped_frs only if not already there. yq v4 array .[] update
        # uses |= for in-place mutation; (… | unique) collapses dupes.
        export H_SECTION="$SECTION"
        export H_FR="$FR"
        yq "
          (.pillars[] | select(.letter == strenv(H_SECTION))) |= (
            .in_flight_frs = ((.in_flight_frs // []) | map(select(. != strenv(H_FR)))) |
            .shipped_frs   = (((.shipped_frs   // []) + [strenv(H_FR)]) | unique)
          )
        " "$hook_target" > "${hook_target}.h1" && mv "${hook_target}.h1" "$hook_target"
        ;;
      released|abandoned)
        export H_SECTION="$SECTION"
        export H_FR="$FR"
        yq "
          (.pillars[] | select(.letter == strenv(H_SECTION))) |= (
            .in_flight_frs = ((.in_flight_frs // []) | map(select(. != strenv(H_FR))))
          )
        " "$hook_target" > "${hook_target}.h1" && mv "${hook_target}.h1" "$hook_target"
        ;;
    esac
  fi

  # --- Hook 2: anchor_dependencies[].status -----------------------------
  # If --fr matches an anchor_dependencies[].anchor and we shipped, set
  # status=shipped + shipped_at + shipped_release. Idempotent: re-running
  # against an already-shipped anchor just refreshes shipped_at to NOW
  # (acceptable -- audit trail is in git anyway).
  if [ "$STATUS" = "shipped" ] && [ -n "$RELEASE_TAG" ]; then
    is_anchor="$(yq -r ".anchor_dependencies[]? | select(.anchor == \"$FR\") | .anchor" "$hook_target")"
    if [ -n "$is_anchor" ]; then
      export H_FR="$FR"
      export H_NOW="$NOW"
      export H_TAG="$RELEASE_TAG"
      yq "
        (.anchor_dependencies[] | select(.anchor == strenv(H_FR))) |= (
          .status = \"shipped\" |
          .shipped_at = strenv(H_NOW) |
          .shipped_release = strenv(H_TAG)
        )
      " "$hook_target" > "${hook_target}.h2" && mv "${hook_target}.h2" "$hook_target"
      log_info "  hook2: anchor $FR marked shipped at $RELEASE_TAG"
    fi
  fi

  # --- Hook 3: prune releases.in_flight ---------------------------------
  # On shipped of flyway/model-registry, drop the matching in_flight entry
  # (epic match AND release-tag match -- be conservative; only prune
  # entries that are clearly fulfilled by THIS release). The release-tag
  # and release-band per-resource branches below already prune in_flight,
  # so we skip them here to avoid double-touch.
  if [ "$STATUS" = "shipped" ] && [ -n "$RELEASE_TAG" ]; then
    case "$RESOURCE" in
      flyway|model-registry)
        export H_EPIC="$EPIC"
        export H_TAG="$RELEASE_TAG"
        yq "
          .releases.in_flight = ((.releases.in_flight // []) | map(select(
            .epic != strenv(H_EPIC) or .proposed_tag != strenv(H_TAG)
          )))
        " "$hook_target" > "${hook_target}.h3" && mv "${hook_target}.h3" "$hook_target"
        ;;
    esac
  fi

  return 0
}

TMP="$(mktemp)"
trap 'rm -f "$TMP" "${TMP}.h1" "${TMP}.h2" "${TMP}.h3"' EXIT

case "$RESOURCE" in
  flyway)
    if [ "$STATUS" = "abandoned" ]; then
      # GDI-770 retro: remove the stale reservation entirely; do NOT append
      # to .shipped (no real release tag). The git commit message carries
      # the audit trail via --reason.
      yq "
        .flyway.reserved |= map(select(.version != \"$ID\"))
      " "$YML" > "$TMP"
    else
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
    fi
    ;;
  model-registry)
    if [ "$STATUS" = "abandoned" ]; then
      yq "
        .model_registry.pending |= map(select(.surface != \"$ID\"))
      " "$YML" > "$TMP"
    else
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
    fi
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
  release-band)
    # GDI-778: release-band releases drop the band-intent entry from
    # in_flight but DO NOT update current_main (the band is vN.M.x — not a
    # concrete tag). When --status=shipped and --release-tag <vN.M.Z> is
    # supplied, current_main is set to the concrete tag. Otherwise just the
    # band intent is cleared.
    yq "
      .releases.in_flight |= ((. // []) | map(select(.proposed_tag != \"$ID\" or .section != \"$SECTION\" or .epic != \"$EPIC\")))
      $( [ -n "$RELEASE_TAG" ] && printf '| .releases.current_main = \"%s\"' "$RELEASE_TAG" )
    " "$YML" > "$TMP"
    ;;
esac

update_pillar_block_hooks "$TMP" || {
  log_err "--update-pillars-block hook failed; ABORTING release (no YAML mutation)"
  exit 1
}

# D-016 Day-2: --dry-run for per-resource mode (sibling to the pre-existing
# --all-for-epic dry-run path). Print the diff that WOULD apply; do not
# write or commit. Critical for testing the new pillar-block hooks against
# a sandbox YAML without pushing to main.
if [ "$DRY_RUN" = "1" ]; then
  log_info "[dry-run] would write the following diff to $YML:"
  diff -u "$YML" "$TMP" || true
  if [ "$EMIT_JSON" = "1" ]; then
    emit_json "released" "dry-run: $RESOURCE/$ID would be released as $STATUS"
  fi
  exit 0
fi

cp "$TMP" "$YML"
log_info "Released $RESOURCE/$ID (status=$STATUS, epic=$EPIC, section=$SECTION)"
if [ "$UPDATE_PILLARS" = "1" ]; then
  log_info "  pillar-block hooks fired (--fr=$FR)"
fi

# GDI-728: if this session was isolated via worktree.sh, remind the operator
# to clean it up. We can't know for sure here, but the hint is cheap and
# easy to ignore when not applicable.
if [ "$STATUS" = "shipped" ]; then
  log_info "If this session used a worktree, remove it:"
  log_info "  ./scripts/worktree.sh remove --repo-path <PRODUCT_REPO_PATH> --epic $EPIC"
fi

if ( cd "$REPO_ROOT" && git rev-parse --git-dir >/dev/null 2>&1 ); then
  git_pull_rebase || log_warn "rebase skipped"
  commit_msg="chore(release): $EPIC releases $RESOURCE/$ID as $STATUS"
  if [ "$STATUS" = "abandoned" ] && [ -n "$REASON" ]; then
    commit_msg="$commit_msg

Reason: $REASON"
  fi
  git_commit_and_push "$commit_msg" "$YML" || {
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
