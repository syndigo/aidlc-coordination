#!/usr/bin/env bash
# shellcheck shell=bash
#
# audit-registry-drift.sh — compare the coordination registry against external truth.
#
# The Phase 3 reconciliation (2026-05-14) only compared the registry against
# itself. The Phase 4 audit (same day) caught 10 drift items by comparing the
# registry against (a) GitHub releases and (b) migrations on disk in the
# product repo. This script makes that comparison repeatable so orchestrator
# personas can run it on every tick instead of waiting for the next manual
# audit.
#
# Read-only. Reports drift on stdout; never mutates the registry. The
# orchestrator persona is responsible for translating findings into reserve.sh
# / release.sh calls.
#
# Usage:
#   audit-registry-drift.sh --product <name> --product-repo-path <path>
#                           [--gh-repo <owner/repo>] [--json]
#                           [--limit-releases <N>]
#   audit-registry-drift.sh --help
#   audit-registry-drift.sh --version
#
# Exit codes:
#   0  no drift found
#   1  drift found (still printed)
#   2  invalid argument / missing tools / repo not accessible
#   127 missing dependency

# shellcheck source=_lib.sh
. "$(dirname "$0")/_lib.sh"

PRODUCT="$DEFAULT_PRODUCT"
REPO_PATH=""
GH_REPO=""
EMIT_JSON=0
LIMIT_RELEASES=30

print_help() {
  cat <<'USAGE'
audit-registry-drift.sh — compare registry against external truth.

Required:
  --product-repo-path <path>  Local clone of the product repo (where the
                              migrations live).

Optional:
  --product <name>            Default: ugc-platform
  --gh-repo <owner/repo>      GitHub repo to query for releases. If
                              omitted, derived from profiles/<product>.yml
                              .product.repo. If that's also empty, the
                              GitHub-releases drift check is skipped.
  --limit-releases <N>        Number of recent GitHub releases to check
                              against the registry. Default: 30.
  --json                      Emit findings as JSON (one finding per
                              object). Exit code still reflects drift.
  --help, --version

Drift checks performed:
  1. flyway-on-disk vs flyway.shipped/reserved
     - Lists every V*__*.sql under the product repo's migration dir,
       compares against (registry shipped + reserved versions), and
       flags any disk migration the registry doesn't know about.
  2. registry-vs-disk reservations
     - For each flyway.reserved entry, check whether the corresponding
       V*__*.sql file already exists on disk (which means it shipped
       and the reservation should be moved to .shipped).
  3. github-releases vs flyway.shipped tags
     - Lists recent GitHub releases (tag + title), flags any tag that
       isn't in flyway.shipped[].release_tag.
  4. anchor staleness vs github releases
     - For each anchor_dependencies[] not yet shipped, scan recent
       release titles for the anchor's FR id. If found, flag the
       anchor as stale.
  5. pillars[].in_flight_frs vs flyway.reserved.fr
     - Same internal check as the Phase 3 reconciliation. Flags
       speculative in_flight_frs entries that have no flyway.reserved
       backing.

Recommended cadence:
  Orchestrator personas (pillar / portfolio) should call this at the
  top of every tick alongside release.sh --sweep-expired. CI can also
  run it on every push to allocations/<product>.yml as a sanity check.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --product)            PRODUCT="$2"; shift 2 ;;
    --product-repo-path)  REPO_PATH="$2"; shift 2 ;;
    --gh-repo)            GH_REPO="$2"; shift 2 ;;
    --limit-releases)     LIMIT_RELEASES="$2"; shift 2 ;;
    --json)               EMIT_JSON=1; shift ;;
    --help|-h)            print_help; exit 0 ;;
    --version)            print_version; exit 0 ;;
    *) log_err "Unknown argument: $1"; print_help; exit 2 ;;
  esac
done

if [ -z "$REPO_PATH" ]; then
  log_err "Missing required arg: --product-repo-path"
  exit 2
fi
if [ ! -d "$REPO_PATH" ]; then
  log_err "Product repo path is not a directory: $REPO_PATH"
  exit 2
fi

require_tools

YML="$(resolve_yml_path "$PRODUCT")"

# Profile lookup -- need migration.dir_pattern and (optionally) product.repo
# for the GitHub releases check. The profile is the single source of truth
# for product shape (D-017).
PROFILE_REF="$(yq -r '.profile_ref // ""' "$YML")"
MIGRATION_DIR=""
if [ -n "$PROFILE_REF" ] && [ -f "$REPO_ROOT/$PROFILE_REF" ]; then
  MIGRATION_DIR="$(yq -r '.migration.dir_pattern // ""' "$REPO_ROOT/$PROFILE_REF")"
  if [ -z "$GH_REPO" ]; then
    GH_REPO="$(yq -r '.product.repo // ""' "$REPO_ROOT/$PROFILE_REF")"
  fi
fi
if [ -z "$MIGRATION_DIR" ]; then
  # Fallback to ugc-platform default. Other products MUST set profile.
  MIGRATION_DIR="services/ugc-api/src/main/resources/db/migration"
  log_warn "No profile_ref or migration.dir_pattern; falling back to UGC default: $MIGRATION_DIR"
fi

# ----- finding accumulator --------------------------------------------------
# Print findings as we discover them; track count for exit code. JSON mode
# accumulates into an array.
FINDING_COUNT=0
JSON_FINDINGS=""

emit_finding() {
  category="$1"
  severity="$2"   # error | warn | info
  message="$3"
  fix_hint="$4"
  FINDING_COUNT=$((FINDING_COUNT + 1))
  if [ "$EMIT_JSON" = "1" ]; then
    esc_msg="$(json_escape "$message")"
    esc_fix="$(json_escape "$fix_hint")"
    sep=""
    [ -n "$JSON_FINDINGS" ] && sep=","
    JSON_FINDINGS="${JSON_FINDINGS}${sep}{\"category\":\"$category\",\"severity\":\"$severity\",\"message\":\"$esc_msg\",\"fix\":\"$esc_fix\"}"
  else
    case "$severity" in
      error) tag="❌" ;;
      warn)  tag="⚠️ " ;;
      info)  tag="ℹ️ " ;;
      *)     tag="• " ;;
    esac
    printf '%s [%s] %s\n' "$tag" "$category" "$message"
    if [ -n "$fix_hint" ]; then
      printf '       fix: %s\n' "$fix_hint"
    fi
  fi
}

# ----- check 1: migrations on disk vs registry ------------------------------

if [ "$EMIT_JSON" != "1" ]; then
  printf '\n=== Drift check 1: migrations on disk vs flyway.shipped + flyway.reserved ===\n'
fi

DISK_DIR="$REPO_PATH/$MIGRATION_DIR"
if [ ! -d "$DISK_DIR" ]; then
  emit_finding "disk-migrations" "warn" \
    "Migration directory not found at $DISK_DIR" \
    "Verify migration.dir_pattern in profiles/${PRODUCT}.yml; or pass --product-repo-path pointing at the right clone."
else
  # Build the registry-known set: shipped + reserved versions.
  REGISTRY_VERSIONS="$(yq -r '
    [(.flyway.shipped // [])[].version, (.flyway.reserved // [])[].version]
    | unique
    | .[]
  ' "$YML" 2>/dev/null | sort -u)"

  # Walk the disk; for each V*__*.sql, check membership.
  while IFS= read -r migration_file; do
    [ -z "$migration_file" ] && continue
    base="$(basename "$migration_file")"
    version="$(printf '%s' "$base" | sed -n 's/^\(V[0-9][0-9]*\)__.*\.sql$/\1/p')"
    [ -z "$version" ] && continue
    if ! printf '%s\n' "$REGISTRY_VERSIONS" | grep -qFx "$version"; then
      emit_finding "disk-migrations" "error" \
        "$version on disk ($base) is not in flyway.shipped or flyway.reserved" \
        "git log --no-merges -3 -- '$migration_file' to find the owning epic; then add via release.sh --resource flyway --status=shipped"
    fi
  done <<EOF
$(find "$DISK_DIR" -name 'V*__*.sql' -type f 2>/dev/null | sort -V)
EOF
fi

# ----- check 2: registry reservations that already shipped (on disk) --------

if [ "$EMIT_JSON" != "1" ]; then
  printf '\n=== Drift check 2: flyway.reserved entries whose migration is already on disk ===\n'
fi

if [ -d "$DISK_DIR" ]; then
  # For each reserved version, check if a V<n>__*.sql file exists.
  reserved_versions="$(yq -r '(.flyway.reserved // [])[] | .version + " " + .epic + " " + (.fr // "no-fr")' "$YML" 2>/dev/null)"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    version="$(printf '%s' "$line" | awk '{print $1}')"
    epic="$(printf '%s' "$line" | awk '{print $2}')"
    # Skip test-fixture range (V900+) -- those have separate semantics.
    case "$version" in
      V[0-9][0-9][0-9])
        n="$(printf '%s' "$version" | sed 's/^V//')"
        if [ "$n" -ge 900 ]; then
          continue
        fi
        ;;
    esac
    if find "$DISK_DIR" -name "${version}__*.sql" -type f 2>/dev/null | grep -q .; then
      file="$(find "$DISK_DIR" -name "${version}__*.sql" -type f 2>/dev/null | head -1)"
      emit_finding "stale-reservation" "warn" \
        "$version ($epic) is in flyway.reserved but $(basename "$file") already exists on disk" \
        "release.sh --resource flyway --section <X> --epic $epic --id $version --status shipped --release-tag <vX.Y.Z> --fr <FR-X.Y.Z> --update-pillars-block"
    fi
  done <<EOF
$reserved_versions
EOF
fi

# ----- check 3: github releases vs registry tags ----------------------------

if [ "$EMIT_JSON" != "1" ]; then
  printf '\n=== Drift check 3: GitHub releases not in flyway.shipped[].release_tag ===\n'
fi

if [ -z "$GH_REPO" ]; then
  emit_finding "github-releases" "info" \
    "No --gh-repo and no profile.product.repo; skipping GitHub-releases drift check" \
    "Set product.repo in profiles/${PRODUCT}.yml or pass --gh-repo owner/repo"
elif ! command -v gh >/dev/null 2>&1; then
  emit_finding "github-releases" "info" \
    "gh CLI not on PATH; skipping GitHub-releases drift check" \
    "Install gh from https://cli.github.com/ to enable this check"
else
  # Fetch recent releases. gh release list is rate-limited; --limit caps it.
  GH_TAGS="$(gh release list --repo "$GH_REPO" --limit "$LIMIT_RELEASES" 2>/dev/null \
    | awk '{print $(NF-1)}' | sort -u)"
  if [ -z "$GH_TAGS" ]; then
    emit_finding "github-releases" "info" \
      "gh release list returned no tags for $GH_REPO" \
      "Check authentication: gh auth status; and confirm the repo is accessible."
  else
    REGISTRY_TAGS="$(yq -r '(.flyway.shipped // [])[].release_tag // empty' "$YML" 2>/dev/null | sort -u)"
    # Also accept tags noted in the inline release-comment block (the 5
    # untracked tags from the 2026-05-14 audit) -- match by tag name in the
    # full YAML body. This is a soft check so the audit doesn't re-flag
    # already-documented exceptions.
    REGISTRY_NOTED_TAGS="$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' "$YML" 2>/dev/null | sort -u)"
    KNOWN_TAGS="$(printf '%s\n%s\n' "$REGISTRY_TAGS" "$REGISTRY_NOTED_TAGS" | sort -u)"
    while IFS= read -r tag; do
      [ -z "$tag" ] && continue
      if ! printf '%s\n' "$KNOWN_TAGS" | grep -qFx "$tag"; then
        emit_finding "github-releases" "error" \
          "GitHub release $tag exists but is not in flyway.shipped or noted in releases comment block" \
          "gh release view $tag --repo $GH_REPO --json tagName,name,createdAt to identify owning epic; then add to flyway.shipped (with version) or document as a tag-only release in the releases: comment block"
      fi
    done <<EOF
$GH_TAGS
EOF
  fi
fi

# ----- check 4: anchor staleness vs github releases -------------------------

if [ "$EMIT_JSON" != "1" ]; then
  printf '\n=== Drift check 4: anchor_dependencies stale vs github releases ===\n'
fi

if [ -n "$GH_REPO" ] && command -v gh >/dev/null 2>&1; then
  # Fetch tag + title for recent releases; format: "tag|title".
  GH_TITLES="$(gh release list --repo "$GH_REPO" --limit "$LIMIT_RELEASES" --json tagName,name 2>/dev/null \
    | jq -r '.[] | .tagName + "|" + .name' 2>/dev/null)"
  if [ -n "$GH_TITLES" ]; then
    # Iterate unshipped anchors.
    unshipped_anchors="$(yq -r '
      (.anchor_dependencies // [])[]
      | select(.status != "shipped")
      | .anchor
    ' "$YML" 2>/dev/null)"
    while IFS= read -r anchor_fr; do
      [ -z "$anchor_fr" ] && continue
      # Look for the FR id in any release title. Anchor is e.g. "FR-A.1.9";
      # release titles use the same form. Handle both with and without the
      # "FR-" prefix, since some titles abbreviate.
      anchor_short="$(printf '%s' "$anchor_fr" | sed 's/^FR-//')"
      hit="$(printf '%s\n' "$GH_TITLES" | grep -E "($anchor_fr|$anchor_short)" | head -1)"
      if [ -n "$hit" ]; then
        ship_tag="$(printf '%s' "$hit" | cut -d'|' -f1)"
        emit_finding "anchor-stale" "error" \
          "Anchor $anchor_fr is unshipped in registry but appears in GitHub release $ship_tag: $hit" \
          "release.sh --resource <flyway|model-registry> --status=shipped --fr $anchor_fr --release-tag $ship_tag --update-pillars-block (Hook 2 will flip the anchor to shipped)"
      fi
    done <<EOF
$unshipped_anchors
EOF
  fi
fi

# ----- check 5: pillar in_flight_frs vs flyway.reserved.fr ------------------

if [ "$EMIT_JSON" != "1" ]; then
  printf '\n=== Drift check 5: pillars[].in_flight_frs without backing flyway.reserved entry ===\n'
fi

# Build the set of (section, fr) that are currently reserved.
RESERVED_TUPLES="$(yq -r '
  (.flyway.reserved // [])[]
  | select(.fr != null and .fr != "")
  | .section + " " + .fr
' "$YML" 2>/dev/null | sort -u)"

# For each pillar's in_flight_frs entry, check if a matching reserved tuple
# exists. If not, the pillar's claim is speculative.
pillar_letters="$(yq -r '(.pillars // [])[].letter' "$YML" 2>/dev/null)"
while IFS= read -r letter; do
  [ -z "$letter" ] && continue
  in_flight="$(yq -r "(.pillars[] | select(.letter == \"$letter\") | .in_flight_frs // [])[]" "$YML" 2>/dev/null)"
  while IFS= read -r fr; do
    [ -z "$fr" ] && continue
    expected_tuple="$letter $fr"
    if ! printf '%s\n' "$RESERVED_TUPLES" | grep -qFx "$expected_tuple"; then
      # Not in flyway.reserved. Check whether it might be in
      # model_registry.pending instead (which is also a valid in-flight signal).
      pending_match="$(yq -r "(.model_registry.pending // [])[] | select(.section == \"$letter\" and .fr == \"$fr\") | .surface" "$YML" 2>/dev/null | head -1)"
      if [ -z "$pending_match" ]; then
        emit_finding "pillar-speculation" "warn" \
          "Pillar $letter claims $fr in_flight but no matching flyway.reserved or model_registry.pending entry exists" \
          "If the FR is genuinely in flight: reserve a flyway version with reserve.sh. If not: drop from pillars[$letter].in_flight_frs."
      fi
    fi
  done <<EOF
$in_flight
EOF
done <<EOF
$pillar_letters
EOF

# ----- summary --------------------------------------------------------------

if [ "$EMIT_JSON" = "1" ]; then
  printf '{"product":"%s","finding_count":%d,"findings":[%s]}\n' \
    "$PRODUCT" "$FINDING_COUNT" "$JSON_FINDINGS"
else
  printf '\n=== Summary ===\n'
  if [ "$FINDING_COUNT" -eq 0 ]; then
    log_info "No drift detected against $GH_REPO + $REPO_PATH"
  else
    log_warn "$FINDING_COUNT drift finding(s) reported above"
  fi
fi

if [ "$FINDING_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
