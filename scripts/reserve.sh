#!/usr/bin/env bash
# shellcheck shell=bash
#
# reserve.sh — claim a shared resource in the AIDLC allocation registry.
#
# Atomic via local-clone + commit + git-push-with-rebase-retry. The audit
# trail is the linear commit history on main (ADR-D-004).
#
# Usage:
#   reserve.sh --resource <flyway|model-registry|file-lock|release-tag|release-band> \
#              --section <A..J> --epic <GDI-XXX> --id <V19|surface-id|filename|vX.Y.Z|vX.Y.x> \
#              [--product <name>] [--fr <FR-X.Y.Z>] [--ttl-hours N] [--json] [--dry-run]
#   reserve.sh --help
#   reserve.sh --version
#
# GDI-778 (2026-05-14): release-band added. Prefer over release-tag for new
# epics — bands record intent; concrete tags computed at Stage 9 via
# next-tag.sh from `gh release list`. Avoids the advisory-reservation race
# that bit GDI-731 / GDI-779 / GDI-830 / GDI-893 (4 consecutive Section C
# runs paid a 2-3 min Stage 9 re-allocation tax).
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
PRODUCT_REPO_PATH=""
BYPASS_PILLAR_CHECKS=0

print_help() {
  cat <<'USAGE'
reserve.sh — claim a shared resource in the AIDLC allocation registry.

Required:
  --resource <flyway|model-registry|file-lock|release-tag|release-band>
  --section <A..J>
  --epic <GDI-XXX>            Jira key OR a section-local epic identifier
  --id <id>                   Flyway version, surface name, file path, semver
                              tag (release-tag), or band shape vN.M.x (release-band)

Optional:
  --product <name>            Default: ugc-platform
  --fr <FR-X.Y.Z>             Functional requirement reference
  --ttl-hours N               Hours until expiry (default: 24)
  --product-repo-path <path>  GDI-770 retro: when reserving a flyway version,
                              if a path to the product repo is supplied, scan
                              for an existing V<id>__*.sql file. If found
                              under a DIFFERENT owner than --epic, emit a
                              loud warning but proceed (you may legitimately
                              be reserving a version a sibling tab has
                              already abandoned). Pass --product-repo-path
                              to enable.
  --bypass-pillar-checks      D-016: skip the pillar-tier guards (intra-pillar
                              serial chains, single-writer max_concurrent_holders,
                              ship-window serial_with peers). Use only when
                              recovering from a stuck state -- the orchestrator
                              personas should never set this. Logs a WARN.
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
    --product-repo-path) PRODUCT_REPO_PATH="$2"; shift 2 ;;
    --bypass-pillar-checks) BYPASS_PILLAR_CHECKS=1; shift ;;
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
  flyway|model-registry|file-lock|release-tag|release-band) ;;
  *) log_err "Invalid --resource: $RESOURCE"; exit 2 ;;
esac

validate_section "$SECTION"

case "$RESOURCE" in
  flyway)        validate_flyway_version "$ID" ;;
  release-tag)   validate_semver_tag "$ID" ;;
  release-band)  validate_semver_tag "$ID" ;;  # GDI-778: band shape is vN.M.x — semver validator accepts it
esac

YML="$(resolve_yml_path "$PRODUCT")"

# ----- GDI-770 retro: on-disk drift warning (flyway only) -------------------
# When reserving a Flyway version, optionally scan the product repo for an
# existing V<id>__*.sql file. If found and owned by a different epic,
# WARN the operator. Do NOT block — the operator may legitimately be claiming
# a version that was abandoned by a prior tab, or may intend to renumber.
if [ "$RESOURCE" = "flyway" ] && [ -n "$PRODUCT_REPO_PATH" ]; then
  if [ -d "$PRODUCT_REPO_PATH" ]; then
    drift_file=""
    # Find any V<id>__*.sql across common migration paths. ugc-platform uses
    # services/ugc-api/src/main/resources/db/migration; other repos may
    # differ but `find` is path-agnostic. Exclude common build-output dirs
    # (bin/, build/, target/, out/, .gradle/, node_modules/) so we don't
    # false-positive on compiled-resource copies.
    drift_file="$(
      find "$PRODUCT_REPO_PATH" -type f -name "${ID}__*.sql" \
        -not -path '*/bin/*' \
        -not -path '*/build/*' \
        -not -path '*/target/*' \
        -not -path '*/out/*' \
        -not -path '*/.gradle/*' \
        -not -path '*/node_modules/*' \
        2>/dev/null | head -1
    )"
    if [ -n "$drift_file" ]; then
      log_warn "On-disk drift detected: $drift_file already exists for $ID"
      log_warn "  If a sibling tab owns this file, your reservation is stale."
      log_warn "  Recommend: run scripts/audit-flyway.sh --product-repo-path \"$PRODUCT_REPO_PATH\" to confirm."
      log_warn "  Proceeding with reservation; rename your migration if needed."
    fi
  else
    log_warn "--product-repo-path does not exist: $PRODUCT_REPO_PATH (skipping disk-drift check)"
  fi
fi

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
    release-band)
      # GDI-778: a band intent is identified by (section, band, epic). Same
      # epic + same band = already recorded (idempotent).
      held_epic="$(yq -r ".releases.in_flight[]? | select(.proposed_tag == \"$ID\" and .section == \"$SECTION\") | .epic // \"\"" "$YML")"
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
    release-band)
      # GDI-778: bands are SECTION-EXCLUSIVE but NOT epic-exclusive. Many
      # epics in the same section can share a band; an epic in another
      # section reserving the same band IS a conflict (sections own bands).
      held_epic="$(yq -r ".releases.in_flight[]? | select(.proposed_tag == \"$ID\" and .section != \"$SECTION\") | .epic // \"\"" "$YML" | head -1)"
      ;;
  esac
  if [ -z "$held_epic" ] || [ "$held_epic" = "none" ] || [ "$held_epic" = "null" ]; then
    return 1
  fi
  printf '%s' "$held_epic"
  return 0
}

# ----- D-016 pillar-tier guards --------------------------------------------
# These are advisory until the pillar tier is populated. If the YAML has no
# .pillars[] block, every check returns 0 (allow). If the pillar tier IS
# populated, three rules apply:
#   1. Intra-pillar serial chains: an FR may not be reserved while one of
#      its predecessors (in the same pillar's serial_chains[].chain) is
#      not yet shipped (not in shipped_frs and not in flyway.shipped /
#      model_registry.shipped depending on resource type).
#   2. file-lock max_concurrent_holders: if the file declares a holder cap
#      > 1, the active-holder count (held_by + holders[] not expired) must
#      be < cap. For the default cap=1, the existing held_by_other_epic
#      check already covers this -- so the new logic only fires when cap > 1.
#   3. release-tag serial_with: when reserving a release-tag for pillar X,
#      refuse if a peer pillar in X.serial_with has a releases.in_flight
#      entry within the last 1 hour (configurable later).
#
# All three short-circuit-allow when --bypass-pillar-checks is set.

# Returns 0 (allow) or 1 (refuse) and sets PILLAR_CHECK_REASON on refuse.
PILLAR_CHECK_REASON=""
pillar_constraints_check() {
  if [ "$BYPASS_PILLAR_CHECKS" = "1" ]; then
    log_warn "Bypassing pillar-tier checks (--bypass-pillar-checks)"
    return 0
  fi

  pillars_present="$(yq -r '(.pillars // []) | length' "$YML")"
  if [ "$pillars_present" = "0" ]; then
    return 0
  fi

  # --- Rule 1: intra-pillar serial chain --------------------------------
  # Only meaningful with --fr set. Look up serial_chains in this section's
  # pillar; for each chain, find the index of $FR. If index > 0, the
  # predecessor at chain[index-1] must be shipped.
  if [ -n "$FR" ]; then
    # All chains as "predecessor|successor" pairs where successor == $FR.
    # We grep for any chain that contains $FR at position > 0.
    # Build the predecessor list via per-chain split in shell because yq v4
    # lacks index-of-element on arrays.
    predecessors="$(yq -r "
      .pillars[]
      | select(.letter == \"$SECTION\")
      | (.serial_chains // [])
      | .[]
      | .chain
      | join(\" \")
    " "$YML" 2>/dev/null)"
    # predecessors is one chain per line, space-separated. For each line,
    # walk and find $FR; if it appears at index > 0, predecessor = previous.
    if [ -n "$predecessors" ]; then
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        prev=""
        found_at=0
        idx=0
        for token in $line; do
          if [ "$token" = "$FR" ] && [ "$idx" -gt 0 ]; then
            found_at=1
            break
          fi
          prev="$token"
          idx=$((idx + 1))
        done
        if [ "$found_at" = "1" ]; then
          # Check if $prev is shipped: look in this pillar's shipped_frs
          # AND in cross-pillar shipped_frs (the predecessor may live in
          # another pillar -- e.g., FR-A.1.9 -> FR-B.1.9).
          shipped="$(yq -r "
            [.pillars[].shipped_frs[]?]
            | .[]
            | select(. == \"$prev\")
          " "$YML" 2>/dev/null)"
          if [ -z "$shipped" ]; then
            PILLAR_CHECK_REASON="intra-pillar serial chain: predecessor $prev (chain=$line) not yet shipped"
            return 1
          fi
        fi
      done <<EOF
$predecessors
EOF
    fi
  fi

  # --- Rule 2: file-lock max_concurrent_holders -------------------------
  if [ "$RESOURCE" = "file-lock" ]; then
    cap="$(yq -r ".single_writer_files[] | select(.file == \"$ID\") | .max_concurrent_holders // 1" "$YML")"
    if [ "$cap" -gt 1 ]; then
      # Count active holders: held_by != none/null/empty + each holders[]
      # entry whose .until is in the future. Compare ISO timestamps as
      # strings (sortable).
      now="$(iso_now)"
      active=0
      held_by="$(yq -r ".single_writer_files[] | select(.file == \"$ID\") | .held_by // \"\"" "$YML")"
      held_until="$(yq -r ".single_writer_files[] | select(.file == \"$ID\") | .until // \"\"" "$YML")"
      if [ -n "$held_by" ] && [ "$held_by" != "none" ] && [ "$held_by" != "null" ]; then
        # held_by counts only if its TTL is in the future (or absent, which we treat as active).
        if [ -z "$held_until" ] || [ "$held_until" \> "$now" ]; then
          active=$((active + 1))
        fi
      fi
      # holders[] entries.
      holder_lines="$(yq -r ".single_writer_files[] | select(.file == \"$ID\") | (.holders // [])[]?.until" "$YML" 2>/dev/null)"
      if [ -n "$holder_lines" ]; then
        while IFS= read -r u; do
          [ -z "$u" ] && continue
          if [ "$u" \> "$now" ]; then
            active=$((active + 1))
          fi
        done <<EOF
$holder_lines
EOF
      fi
      if [ "$active" -ge "$cap" ]; then
        PILLAR_CHECK_REASON="file-lock cap reached: $active active holders >= $cap (max_concurrent_holders)"
        return 1
      fi
    fi
  fi

  # --- Rule 3: release-tag serial_with ----------------------------------
  if [ "$RESOURCE" = "release-tag" ]; then
    peers="$(yq -r ".pillars[] | select(.letter == \"$SECTION\") | (.serial_with // [])[]" "$YML" 2>/dev/null)"
    if [ -n "$peers" ]; then
      # Any in_flight entry whose section is in $peers and whose epic was
      # added to the registry in the last hour blocks us. We don't track
      # an "added_at" timestamp on releases.in_flight today, so be
      # conservative: any peer with any in_flight entry blocks.
      while IFS= read -r peer; do
        [ -z "$peer" ] && continue
        peer_in_flight="$(yq -r ".releases.in_flight[]? | select(.section == \"$peer\") | .epic" "$YML" 2>/dev/null | head -1)"
        if [ -n "$peer_in_flight" ]; then
          PILLAR_CHECK_REASON="ship-window serial_with: pillar $SECTION must serialize with pillar $peer, which has in-flight epic $peer_in_flight"
          return 1
        fi
      done <<EOF
$peers
EOF
    fi
  fi

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

# D-016 pillar-tier guards (intra-pillar serial chain, file-lock holder cap,
# release-tag serial_with). Returns 1 with PILLAR_CHECK_REASON set on refuse.
if ! pillar_constraints_check; then
  log_err "Pillar-tier guard refused: $PILLAR_CHECK_REASON"
  log_err "  Override with --bypass-pillar-checks (orchestrator personas should not)."
  if [ "$EMIT_JSON" = "1" ]; then
    emit_json "wait" "$PILLAR_CHECK_REASON"
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
  release-band)
    # GDI-778: record band-intent in releases.in_flight with proposed_tag set
    # to the band shape (vN.M.x). Stage 9 will call next-tag.sh at create-time
    # to compute the actual concrete tag from gh release list — the registry
    # is no longer the source of truth for the specific tag (which was the
    # whole point of the GDI-778 contract change).
    #
    # The band intent is still useful for: (1) audit trail of which sections
    # have epics in flight; (2) cross-section ownership check (two sections
    # cannot both claim the same band — see held_by_other_epic).
    yq "
      .releases.in_flight = (.releases.in_flight // []) + [{
        \"section\": \"$SECTION\",
        \"epic\": \"$EPIC\",
        \"proposed_tag\": \"$ID\",
        \"anchor_sha\": \"pending\",
        \"note\": \"band-intent (GDI-778); concrete tag computed at Stage 9 by next-tag.sh\"
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
  git_commit_and_push "chore(reserve): $EPIC reserves $RESOURCE/$ID (section $SECTION)" "$YML" || {
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
