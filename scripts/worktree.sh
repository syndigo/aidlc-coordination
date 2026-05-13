#!/usr/bin/env bash
# shellcheck shell=bash
#
# worktree.sh — create or remove an isolated git worktree for an SDLC session.
#
# Solves the "shared-clone working-tree contamination" class (GDI-728): when
# two SDLC sessions run on the same user's machine targeting the same product
# repo, branch switches in one session destabilize the other's state. The
# resource-level claims tracked by reserve.sh / conflict-check.sh (Flyway
# V-numbers, model registry surfaces, single-writer files, release tags) do
# NOT protect against this — the conflict is on the OS-level working tree,
# not on a YAML-registered resource. This helper creates a per-epic worktree
# at a deterministic path so each concurrent session operates in isolation.
#
# Usage:
#   worktree.sh add    --repo-path <PATH> --epic <GDI-XXX> --branch <name> \
#                      [--base-branch origin/dev] [--product <name>] \
#                      [--json] [--dry-run]
#   worktree.sh remove --repo-path <PATH> --epic <GDI-XXX> \
#                      [--product <name>] [--json]
#   worktree.sh path   --epic <GDI-XXX> [--product <name>]
#   worktree.sh list   [--json]
#   worktree.sh --help
#   worktree.sh --version
#
# Deterministic path:
#   /tmp/aidlc-worktrees/<product-slug>-<epic-key>
# product-slug defaults to --product, falling back to the basename of the
# repo's origin remote URL (without .git suffix).
#
# Exit codes:
#   0  ok (idempotent — re-running `add` for the same epic returns existing path)
#   1  generic error (e.g. dirty worktree on `remove`)
#   2  invalid argument / missing required field
#   3  state conflict (path exists but is not a worktree, on `add`;
#       worktree doesn't exist, on `remove`)
#   127 missing dependency (git)

# shellcheck source=_lib.sh
. "$(dirname "$0")/_lib.sh"

# ----- constants ------------------------------------------------------------

WORKTREE_ROOT="/tmp/aidlc-worktrees"

# ----- argv -----------------------------------------------------------------

SUBCOMMAND=""
REPO_PATH=""
EPIC=""
BRANCH=""
BASE_BRANCH="origin/dev"
PRODUCT=""
EMIT_JSON=0
DRY_RUN=0

print_help() {
  cat <<'USAGE'
worktree.sh — create or remove an isolated git worktree for an SDLC session.

Subcommands:
  add     --repo-path <PATH> --epic <GDI-XXX> --branch <name>
          [--base-branch origin/dev] [--product <name>] [--json] [--dry-run]
          Create (or find) an isolated worktree at the deterministic path.
          Idempotent: re-running with the same --epic returns the existing path.

  remove  --repo-path <PATH> --epic <GDI-XXX> [--product <name>] [--json]
          Remove the per-epic worktree. NEVER --force: if the tree is dirty,
          the script surfaces state and exits 1 with a hint to commit/push.

  path    --epic <GDI-XXX> [--product <name>]
          Print the deterministic worktree path. Does not touch git.

  list    [--json]
          Show all worktrees currently under /tmp/aidlc-worktrees/.

Deterministic path:
  /tmp/aidlc-worktrees/<product-slug>-<epic-key>
  product-slug defaults to --product, otherwise inferred from the
  origin remote URL basename.

Solves GDI-728: shared-clone working-tree contamination during concurrent
SDLC runs on the same user's machine.
USAGE
}

# Subcommand is positional and required (except for --help/--version).
if [ $# -eq 0 ]; then
  print_help
  exit 2
fi

case "$1" in
  --help|-h)  print_help; exit 0 ;;
  --version)  print_version; exit 0 ;;
  add|remove|path|list) SUBCOMMAND="$1"; shift ;;
  *) log_err "Unknown subcommand: $1 (expected add|remove|path|list)"; print_help; exit 2 ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-path)   REPO_PATH="$2"; shift 2 ;;
    --epic)        EPIC="$2"; shift 2 ;;
    --branch)      BRANCH="$2"; shift 2 ;;
    --base-branch) BASE_BRANCH="$2"; shift 2 ;;
    --product)     PRODUCT="$2"; shift 2 ;;
    --json)        EMIT_JSON=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --help|-h)     print_help; exit 0 ;;
    --version)     print_version; exit 0 ;;
    *) log_err "Unknown argument: $1"; print_help; exit 2 ;;
  esac
done

# ----- dependency check -----------------------------------------------------
#
# require_tools insists on yq+git. yq is not actually needed here, but
# loading the same dep set keeps behavior consistent with sibling scripts
# (operators won't be surprised by a partial-install workstation passing
# worktree.sh and failing reserve.sh). git is the real dependency.
if ! command -v git >/dev/null 2>&1; then
  log_err "git not found on PATH"
  exit 127
fi

# ----- helpers --------------------------------------------------------------

# Derive a product slug.
# Priority: --product flag > origin remote basename > "unknown".
derive_product_slug() {
  if [ -n "$PRODUCT" ]; then
    printf '%s' "$PRODUCT"
    return 0
  fi
  if [ -n "$REPO_PATH" ] && [ -d "$REPO_PATH/.git" ] || \
     ( [ -n "$REPO_PATH" ] && git -C "$REPO_PATH" rev-parse --git-dir >/dev/null 2>&1 ); then
    url="$(git -C "$REPO_PATH" remote get-url origin 2>/dev/null || true)"
    if [ -n "$url" ]; then
      # Strip trailing .git, then take the basename.
      slug="$(printf '%s' "$url" | sed -e 's/\.git$//' -e 's#.*[/:]##')"
      if [ -n "$slug" ]; then
        printf '%s' "$slug"
        return 0
      fi
    fi
  fi
  printf 'unknown'
}

# Compute the deterministic worktree path. Requires $EPIC and a slug source.
compute_worktree_path() {
  slug="$(derive_product_slug)"
  printf '%s/%s-%s' "$WORKTREE_ROOT" "$slug" "$EPIC"
}

# Resolve a path to its canonical/real form (follows symlinks).
# On macOS /tmp is a symlink to /private/tmp; `git worktree list` always
# records the canonical form, so we must canonicalize before comparing.
# Falls back to the input path if neither realpath nor python3 is available.
resolve_real_path() {
  p="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$p" 2>/dev/null || printf '%s' "$p"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$p" 2>/dev/null || printf '%s' "$p"
  else
    printf '%s' "$p"
  fi
}

# Does $1 look like a registered git worktree (per `git worktree list`)?
is_registered_worktree() {
  path_to_check="$1"
  if [ ! -d "$REPO_PATH" ]; then
    return 1
  fi
  real_path="$(resolve_real_path "$path_to_check")"
  # `git worktree list --porcelain` prints "worktree <abs-path>" lines using
  # the canonical (realpath) form. Match either the literal input or the
  # canonicalized form for portability.
  git -C "$REPO_PATH" worktree list --porcelain 2>/dev/null \
    | grep -E "^worktree ($path_to_check|$real_path)\$" >/dev/null 2>&1
}

# Check whether a working tree is dirty (uncommitted changes OR unpushed commits).
# Returns 0 if dirty, 1 if clean.
worktree_is_dirty() {
  wt_path="$1"
  if [ ! -d "$wt_path" ]; then
    return 1
  fi
  # Uncommitted changes (staged or unstaged or untracked).
  if [ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null)" ]; then
    return 0
  fi
  # Unpushed commits on the current branch (only if it has an upstream).
  upstream="$(git -C "$wt_path" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  if [ -n "$upstream" ]; then
    ahead="$(git -C "$wt_path" rev-list --count "$upstream..HEAD" 2>/dev/null || echo 0)"
    if [ "$ahead" != "0" ]; then
      return 0
    fi
  fi
  return 1
}

# ----- subcommand: path -----------------------------------------------------

if [ "$SUBCOMMAND" = "path" ]; then
  if [ -z "$EPIC" ]; then
    log_err "Missing required arg: --epic"
    exit 2
  fi
  # No repo-path required; if --product is unset and no repo-path, slug=unknown.
  WT_PATH="$(compute_worktree_path)"
  printf '%s\n' "$WT_PATH"
  exit 0
fi

# ----- subcommand: list -----------------------------------------------------

if [ "$SUBCOMMAND" = "list" ]; then
  if [ ! -d "$WORKTREE_ROOT" ]; then
    log_info "No worktrees: $WORKTREE_ROOT does not exist"
    if [ "$EMIT_JSON" = "1" ]; then
      printf '{"worktrees":[]}\n'
    fi
    exit 0
  fi
  log_info "Worktrees under $WORKTREE_ROOT:"
  found=0
  if [ "$EMIT_JSON" = "1" ]; then
    printf '{"worktrees":['
    first=1
  fi
  for wt in "$WORKTREE_ROOT"/*; do
    [ -d "$wt" ] || continue
    found=1
    name="$(basename "$wt")"
    branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
    dirty="clean"
    if worktree_is_dirty "$wt"; then
      dirty="dirty"
    fi
    if [ "$EMIT_JSON" = "1" ]; then
      if [ "$first" = "0" ]; then
        printf ','
      fi
      first=0
      esc_name="$(json_escape "$name")"
      esc_path="$(json_escape "$wt")"
      esc_branch="$(json_escape "$branch")"
      esc_dirty="$(json_escape "$dirty")"
      printf '{"name":"%s","path":"%s","branch":"%s","state":"%s"}' \
        "$esc_name" "$esc_path" "$esc_branch" "$esc_dirty"
    else
      printf '  %-50s  branch=%-30s  %s\n' "$name" "$branch" "$dirty"
    fi
  done
  if [ "$EMIT_JSON" = "1" ]; then
    printf ']}\n'
  fi
  if [ "$found" = "0" ]; then
    log_info "(none)"
  fi
  exit 0
fi

# ----- subcommand: add ------------------------------------------------------

if [ "$SUBCOMMAND" = "add" ]; then
  for var_name in REPO_PATH EPIC BRANCH; do
    eval "v=\$$var_name"
    # shellcheck disable=SC2154
    if [ -z "$v" ]; then
      log_err "Missing required arg: --$(echo "$var_name" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
      exit 2
    fi
  done

  if [ ! -d "$REPO_PATH" ]; then
    log_err "Repo path does not exist: $REPO_PATH"
    exit 2
  fi
  if ! git -C "$REPO_PATH" rev-parse --git-dir >/dev/null 2>&1; then
    log_err "Repo path is not a git repository: $REPO_PATH"
    exit 2
  fi

  WT_PATH="$(compute_worktree_path)"

  # Idempotency: if path already exists AND is a registered worktree, return it.
  if [ -d "$WT_PATH" ]; then
    if is_registered_worktree "$WT_PATH"; then
      log_info "Worktree already exists: $WT_PATH (idempotent no-op)"
      printf '%s\n' "$WT_PATH"
      if [ "$EMIT_JSON" = "1" ]; then
        emit_json "ok" "idempotent — existing worktree at $WT_PATH"
      fi
      exit 0
    fi
    log_err "Path $WT_PATH exists but is not a registered git worktree"
    log_err "Refusing to clobber; remove manually if intentional"
    exit 3
  fi

  if [ "$DRY_RUN" = "1" ]; then
    log_info "[dry-run] would create worktree at $WT_PATH"
    log_info "[dry-run]   from base=$BASE_BRANCH branch=$BRANCH repo=$REPO_PATH"
    exit 0
  fi

  # Ensure root dir exists.
  mkdir -p "$WORKTREE_ROOT" || {
    log_err "Could not create $WORKTREE_ROOT"
    exit 1
  }

  # Refresh remotes so BASE_BRANCH is current.
  log_info "Fetching origin in $REPO_PATH..."
  if ! git -C "$REPO_PATH" fetch origin --quiet; then
    log_warn "git fetch origin failed; proceeding with local refs"
  fi

  # Does the branch already exist (locally or on remote)?
  branch_exists_locally=0
  if git -C "$REPO_PATH" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    branch_exists_locally=1
  fi
  branch_exists_remote=0
  if git -C "$REPO_PATH" show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
    branch_exists_remote=1
  fi

  if [ "$branch_exists_locally" = "1" ] || [ "$branch_exists_remote" = "1" ]; then
    log_info "Adding worktree for existing branch '$BRANCH' at $WT_PATH"
    if ! git -C "$REPO_PATH" worktree add "$WT_PATH" "$BRANCH" 2>&1; then
      log_err "git worktree add failed"
      exit 1
    fi
  else
    log_info "Creating new branch '$BRANCH' from $BASE_BRANCH in worktree $WT_PATH"
    if ! git -C "$REPO_PATH" worktree add -b "$BRANCH" "$WT_PATH" "$BASE_BRANCH" 2>&1; then
      log_err "git worktree add -b failed"
      exit 1
    fi
  fi

  log_info "Worktree ready: $WT_PATH (branch=$BRANCH, base=$BASE_BRANCH)"
  printf '%s\n' "$WT_PATH"
  if [ "$EMIT_JSON" = "1" ]; then
    emit_json "ok" "worktree created at $WT_PATH (branch=$BRANCH)"
  fi
  exit 0
fi

# ----- subcommand: remove ---------------------------------------------------

if [ "$SUBCOMMAND" = "remove" ]; then
  for var_name in REPO_PATH EPIC; do
    eval "v=\$$var_name"
    # shellcheck disable=SC2154
    if [ -z "$v" ]; then
      log_err "Missing required arg: --$(echo "$var_name" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
      exit 2
    fi
  done

  if [ ! -d "$REPO_PATH" ]; then
    log_err "Repo path does not exist: $REPO_PATH"
    exit 2
  fi

  WT_PATH="$(compute_worktree_path)"

  if [ ! -d "$WT_PATH" ]; then
    log_warn "No worktree to remove at $WT_PATH (idempotent no-op)"
    if [ "$EMIT_JSON" = "1" ]; then
      emit_json "ok" "no worktree at $WT_PATH"
    fi
    exit 0
  fi

  if worktree_is_dirty "$WT_PATH"; then
    log_err "Refusing to remove dirty worktree at $WT_PATH"
    log_err "Uncommitted changes or unpushed commits detected."
    log_err "Commit/push first, then re-run remove. (worktree.sh NEVER uses --force.)"
    if [ "$EMIT_JSON" = "1" ]; then
      emit_json "error" "dirty worktree at $WT_PATH — commit/push first"
    fi
    exit 1
  fi

  log_info "Removing worktree $WT_PATH..."
  if ! git -C "$REPO_PATH" worktree remove "$WT_PATH" 2>&1; then
    log_err "git worktree remove failed"
    exit 1
  fi

  log_info "Worktree removed: $WT_PATH"
  if [ "$EMIT_JSON" = "1" ]; then
    emit_json "ok" "worktree removed from $WT_PATH"
  fi
  exit 0
fi

log_err "Unhandled subcommand: $SUBCOMMAND"
exit 2
