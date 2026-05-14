#!/usr/bin/env bash
# shellcheck shell=bash
#
# audit-flyway.sh — scan a product repo's Flyway migration directory and
# reconcile it against the coordination registry's flyway holds.
#
# GDI-770 retro: when multiple parallel SDLC tabs reserve Flyway versions
# concurrently (Section A grabbing V29, Section C grabbing V30, Section D
# already holding V30 on disk), the file-based reservations alone don't
# detect on-disk-vs-registry drift. This script provides a fast read-only
# audit the operator (or Stage 4 / Stage 0.6) can run to spot the drift
# before it produces a broken PR.
#
# Usage:
#   audit-flyway.sh --product-repo-path <path-to-product-repo>
#                   [--product <name>] [--migrations-glob <glob>]
#                   [--json]
#   audit-flyway.sh --help
#   audit-flyway.sh --version
#
# Default --migrations-glob: services/ugc-api/src/main/resources/db/migration/V*__*.sql
#                            (matches the ugc-platform convention)
#
# Output:
#   For each Vxx version detected on disk OR in the registry, emit one row:
#     V<num>  on_disk=<filename|->  shipped=<epic|->  reserved_by=<epic|->  status=<DRIFT|OK|...>
#
#   "DRIFT" rows are the ones that matter — they indicate the on-disk file
#   doesn't match what the registry says. These are the patterns:
#     - on_disk=Y, shipped=Y     OK (normal post-release)
#     - on_disk=Y, reserved=Y    OK (in-flight, expected)
#     - on_disk=Y, neither       DRIFT-disk-only (file shipped without a registry entry; orphan from a manual edit)
#     - on_disk=N, reserved=Y    OK (anticipated; nothing shipped yet)
#     - on_disk=N, shipped=Y     DRIFT-registry-only (registry says shipped but file is missing; bad state)
#     - on_disk=Y, reserved-by-X, but X != owner-of-on-disk-file  DRIFT-owner-mismatch (the GDI-770 case)
#
# Exit codes:
#   0  No drift detected
#   1  At least one DRIFT row emitted
#   2  invalid argument
#   127 missing dependency

# shellcheck source=_lib.sh
. "$(dirname "$0")/_lib.sh"

PRODUCT_REPO_PATH=""
PRODUCT="$DEFAULT_PRODUCT"
MIGRATIONS_GLOB="services/ugc-api/src/main/resources/db/migration/V*__*.sql"
EMIT_JSON=0

print_help() {
  cat <<'USAGE'
audit-flyway.sh — reconcile on-disk Flyway migrations against registry holds.

Required:
  --product-repo-path <path>   Filesystem path to the product repo's local clone

Optional:
  --product <name>             Default: ugc-platform
  --migrations-glob <glob>     Relative path glob inside the product repo.
                               Default: services/ugc-api/src/main/resources/db/migration/V*__*.sql
  --json                       Emit structured JSON on stdout
  --help, --version

Output (human-readable):
  One row per Vxx version detected on disk OR in the registry:
    V<num>  on_disk=<file|->  shipped=<epic|->  reserved=<epic|->  status=<OK|DRIFT...>

  Drift statuses:
    DRIFT-disk-only         file present on disk but registry has no entry
    DRIFT-registry-only     registry says shipped but file is missing
    DRIFT-owner-mismatch    file on disk + reservation by a DIFFERENT epic
                            (the GDI-770 V29/V30 race pattern)

Exit code 1 if any DRIFT row emitted.

Example:
  ./scripts/audit-flyway.sh --product-repo-path ~/Projects/ugc-platform
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --product-repo-path) PRODUCT_REPO_PATH="$2"; shift 2 ;;
    --product)           PRODUCT="$2"; shift 2 ;;
    --migrations-glob)   MIGRATIONS_GLOB="$2"; shift 2 ;;
    --json)              EMIT_JSON=1; shift ;;
    --help|-h)           print_help; exit 0 ;;
    --version)           print_version; exit 0 ;;
    *) log_err "Unknown argument: $1"; print_help; exit 2 ;;
  esac
done

require_tools

if [ -z "$PRODUCT_REPO_PATH" ]; then
  log_err "Missing required arg: --product-repo-path"
  exit 2
fi

if [ ! -d "$PRODUCT_REPO_PATH" ]; then
  log_err "Product repo path does not exist: $PRODUCT_REPO_PATH"
  exit 2
fi

YML="$(resolve_yml_path "$PRODUCT")"

# ----- scan on-disk migrations ----------------------------------------------
#
# Build a "version -> filename" map from on-disk Vxx__*.sql files. Production
# range only (V1-V899); the V900-V999 test_fixture_range is intentional and
# tracked separately in the YAML.

ON_DISK_TMP="$(mktemp)"
trap 'rm -f "$ON_DISK_TMP"' EXIT

# Expand glob inside the product repo. Use a subshell so we don't pollute cwd.
(
  cd "$PRODUCT_REPO_PATH" || exit 1
  # shellcheck disable=SC2086
  for f in $MIGRATIONS_GLOB; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    version="$(printf '%s' "$base" | sed -E 's/^(V[0-9]+)__.*\.sql$/\1/')"
    if [ -z "$version" ] || [ "$version" = "$base" ]; then
      continue
    fi
    # Extract numeric part and skip test-fixture range (>=900).
    numeric="$(printf '%s' "$version" | sed -E 's/^V//')"
    case "$numeric" in
      ''|*[!0-9]*) continue ;;
    esac
    if [ "$numeric" -ge 900 ]; then
      continue
    fi
    printf '%s\t%s\n' "$version" "$base" >> "$ON_DISK_TMP"
  done
) || {
  log_err "Failed to scan migrations glob in $PRODUCT_REPO_PATH"
  exit 1
}

# ----- pull registry holds --------------------------------------------------

REGISTRY_TMP="$(mktemp)"
trap 'rm -f "$ON_DISK_TMP" "$REGISTRY_TMP"' EXIT

# Emit lines: "Vxx\tshipped|reserved\tepic"
# Filter to production range only — V900+ rows that accidentally landed in
# top-level .flyway.shipped/.reserved are dropped post-emit via awk so the
# yq idiom stays simple (yq's sub() can't be used in select() predicates).
yq -r '
  (.flyway.shipped[]?  | [.version, "shipped",  (.epic // "?")] | @tsv),
  (.flyway.reserved[]? | [.version, "reserved", (.epic // "?")] | @tsv)
' "$YML" | awk -F'\t' '
  {
    n = substr($1, 2) + 0
    if (n > 0 && n < 900) { print }
  }
' > "$REGISTRY_TMP"

# ----- merge + classify -----------------------------------------------------
#
# For every distinct V<num> across both sources, emit one row.

ALL_TMP="$(mktemp)"
trap 'rm -f "$ON_DISK_TMP" "$REGISTRY_TMP" "$ALL_TMP"' EXIT

awk -F'\t' '
  FNR==NR { disk[$1] = $2; next }
  {
    if ($2 == "shipped") shipped[$1] = $3
    else if ($2 == "reserved") reserved[$1] = $3
  }
  END {
    for (v in disk)     versions[v] = 1
    for (v in shipped)  versions[v] = 1
    for (v in reserved) versions[v] = 1
    n = 0
    for (v in versions) { keys[n++] = v }
    # numeric-by-V sort
    for (i = 0; i < n; i++) {
      for (j = i + 1; j < n; j++) {
        ai = substr(keys[i], 2) + 0
        aj = substr(keys[j], 2) + 0
        if (aj < ai) { t = keys[i]; keys[i] = keys[j]; keys[j] = t }
      }
    }
    for (i = 0; i < n; i++) {
      v = keys[i]
      df = disk[v];     if (df == "")     df = "-"
      sh = shipped[v];  if (sh == "")     sh = "-"
      rs = reserved[v]; if (rs == "")     rs = "-"
      # Classify
      status = "OK"
      if (df != "-" && sh == "-" && rs == "-") {
        status = "DRIFT-disk-only"
      } else if (df == "-" && sh != "-") {
        status = "DRIFT-registry-only"
      } else if (df != "-" && rs != "-" && sh == "-") {
        # File on disk + reservation. If the reservation epic matches the
        # filename owner (we cannot easily infer this without filename
        # convention) we accept; otherwise flag potential owner-mismatch.
        # For now, flag every reserved-and-on-disk as needing review:
        # the reserved row should have been advanced to shipped when the
        # file was written, OR another epic owns the file.
        status = "DRIFT-owner-mismatch?"
      }
      printf "%s\t%s\t%s\t%s\t%s\n", v, df, sh, rs, status
    }
  }
' "$ON_DISK_TMP" "$REGISTRY_TMP" > "$ALL_TMP"

# ----- emit -----------------------------------------------------------------

DRIFT_COUNT=0
if [ "$EMIT_JSON" = "1" ]; then
  printf '{"rows":['
  first=1
  while IFS="$(printf '\t')" read -r v df sh rs status; do
    [ -z "$v" ] && continue
    if [ "$first" = "1" ]; then first=0; else printf ','; fi
    printf '{"version":"%s","on_disk":"%s","shipped_by":"%s","reserved_by":"%s","status":"%s"}' \
      "$v" "$df" "$sh" "$rs" "$status"
    case "$status" in DRIFT*) DRIFT_COUNT=$((DRIFT_COUNT + 1)) ;; esac
  done < "$ALL_TMP"
  printf '],"drift_count":%d}\n' "$DRIFT_COUNT"
else
  printf '%-6s %-50s %-30s %-30s %s\n' "V" "on_disk" "shipped_by" "reserved_by" "status"
  printf '%s\n' "----------------------------------------------------------------------------------------------------------------------"
  while IFS="$(printf '\t')" read -r v df sh rs status; do
    [ -z "$v" ] && continue
    printf '%-6s %-50s %-30s %-30s %s\n' "$v" "$df" "$sh" "$rs" "$status"
    case "$status" in DRIFT*) DRIFT_COUNT=$((DRIFT_COUNT + 1)) ;; esac
  done < "$ALL_TMP"
  printf '\nTotal drift rows: %d\n' "$DRIFT_COUNT"
fi

if [ "$DRIFT_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
