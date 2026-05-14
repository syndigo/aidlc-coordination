#!/usr/bin/env bash
# shellcheck shell=bash
#
# spawn-pillar.sh — render the bootstrap prompt and open a new terminal tab.
#
# Approach (a) per D-025 follow-up:
#   1. Render the bootstrap prompt via bootstrap-pillar-prompt.sh
#   2. Copy the rendered prompt to the clipboard (pbcopy on macOS)
#   3. Open a new terminal tab in iTerm2 or Apple Terminal (auto-detected
#      via TERM_PROGRAM, or forced via --terminal)
#   4. The new tab is left at the operator's shell prompt; ⌘V to paste
#      the bootstrap prompt into Claude.
#
# Why approach (a): doesn't fight Anthropic's CLI, doesn't depend on
# accessibility permissions for synthetic keystrokes, doesn't break when
# the Claude CLI UX changes. Operator does the final ⌘V — one keystroke
# of friction in exchange for not having to babysit a brittle automation.
#
# Usage:
#   spawn-pillar.sh --letter <X> [--product <name>] [--with-drift-check]
#                   [--terminal <iterm2|terminal>] [--no-open] [--no-clipboard]
#   spawn-pillar.sh --help
#   spawn-pillar.sh --version
#
# Exit codes:
#   0  spawned successfully (or dry-run printed)
#   1  generic error
#   2  invalid argument / missing tools / unsupported terminal
#   127 missing dependency (osascript, pbcopy)

# shellcheck source=_lib.sh
. "$(dirname "$0")/_lib.sh"

PRODUCT="$DEFAULT_PRODUCT"
LETTER=""
WITH_DRIFT_CHECK=0
TERMINAL=""
LOCAL_REPO_PATH=""
NO_OPEN=0
NO_CLIPBOARD=0

print_help() {
  cat <<'USAGE'
spawn-pillar.sh — render bootstrap prompt + copy to clipboard + open new terminal tab.

Required:
  --letter <X>                  Pillar letter (also section letter)

Optional:
  --product <name>              Default: ugc-platform
  --with-drift-check            Pass --with-drift-check to the renderer
                                (recommended; runs audit-registry-drift.sh
                                and embeds the result so the new tab knows
                                whether the registry is currently honest).
                                Adds ~5s.
  --local-repo-path <path>      Forwarded to bootstrap-pillar-prompt.sh.
  --terminal <iterm2|terminal>  Where the new pillar tab opens. Default:
                                iterm2 — the designated home for pillar-
                                orchestrator sessions (D-026). It does NOT
                                matter where you INVOKE this script from
                                (VS Code integrated terminal, an SSH
                                session, iTerm2 itself) — the new tab
                                always lands in iTerm2 unless you pass
                                --terminal terminal. The one exception:
                                if you invoke from Apple Terminal, it
                                honors that (TERM_PROGRAM=Apple_Terminal).
  --no-open                     Render + copy to clipboard but do NOT open
                                a new terminal tab. Use this when invoking
                                from VS Code if you'd rather open the new
                                tab yourself, or to recover a clobbered
                                clipboard without spawning another tab.
  --no-clipboard                Render + open terminal but do NOT copy to
                                clipboard. The rendered prompt is printed
                                to stdout — operator can pipe it elsewhere.
  --help, --version

What this does:
  1. Calls bootstrap-pillar-prompt.sh with the same args (renders the
     handoff prompt against current registry state).
  2. Copies the rendered prompt to the system clipboard via pbcopy.
  3. Opens a new iTerm2 tab (or Apple Terminal tab with --terminal terminal)
     and selects it so it has focus.
  4. Prints next-step instructions.

Then in the new tab, YOU do three things (the script does not automate
these — by design; see D-025 approach (a)):
  1. Launch Claude.
  2. ⌘V to paste the bootstrap prompt as the first message. (It is on
     your clipboard from step 2 above. If you copied something else in
     between, re-run with --no-open to re-copy without opening another
     tab.)
  3. Hit Enter.

The strategic FR pick stays human — the rendered prompt has an
ORCHESTRATOR NOTE comment marking where to insert your one-paragraph
rationale before the new tab dispatches /sdlc.

Pillar sessions live in iTerm2; code editing lives in VS Code. Keeping
them in separate apps keeps both uncluttered — one iTerm2 window shows
all your pillar tabs at a glance.

macOS only (depends on osascript + pbcopy). On Linux / WSL, run
bootstrap-pillar-prompt.sh by hand and paste into your target tab.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --letter)             LETTER="$2"; shift 2 ;;
    --product)            PRODUCT="$2"; shift 2 ;;
    --with-drift-check)   WITH_DRIFT_CHECK=1; shift ;;
    --local-repo-path)    LOCAL_REPO_PATH="$2"; shift 2 ;;
    --terminal)           TERMINAL="$2"; shift 2 ;;
    --no-open)            NO_OPEN=1; shift ;;
    --no-clipboard)       NO_CLIPBOARD=1; shift ;;
    --help|-h)            print_help; exit 0 ;;
    --version)            print_version; exit 0 ;;
    *) log_err "Unknown argument: $1"; print_help; exit 2 ;;
  esac
done

if [ -z "$LETTER" ]; then
  log_err "Missing required arg: --letter"
  exit 2
fi
validate_section "$LETTER"

# Tool checks. require_tools handles yq/git; we add pbcopy + osascript here.
require_tools
if [ "$NO_CLIPBOARD" != "1" ] && ! command -v pbcopy >/dev/null 2>&1; then
  log_err "pbcopy not found on PATH (this script is macOS-only)"
  log_err "  Pass --no-clipboard to print the rendered prompt to stdout instead."
  exit 127
fi
if [ "$NO_OPEN" != "1" ] && ! command -v osascript >/dev/null 2>&1; then
  log_err "osascript not found on PATH (this script is macOS-only)"
  log_err "  Pass --no-open to skip opening a new terminal tab."
  exit 127
fi

# ----- terminal detection ---------------------------------------------------

if [ -z "$TERMINAL" ]; then
  # iTerm2 is the designated home for pillar-orchestrator tabs (D-026).
  # The operator may *invoke* this script from anywhere — VS Code's
  # integrated terminal, Apple Terminal, an SSH session — but the new
  # pillar tab always lands in iTerm2 unless --terminal terminal is
  # explicitly passed. This is deliberate: pillar sessions live in
  # iTerm2 (one window, all pillars visible, split panes); code editing
  # lives in VS Code. Separating them keeps both uncluttered.
  case "${TERM_PROGRAM:-}" in
    Apple_Terminal)
      # The operator is in Apple Terminal — honor it; they probably want
      # the new tab in the same app.
      TERMINAL="terminal"
      ;;
    *)
      # iTerm.app, vscode, ssh, unset — all route to iTerm2. No warning:
      # this is the intended behavior, not a fallback.
      TERMINAL="iterm2"
      ;;
  esac
fi

# Sanity check: if --terminal iterm2 but iTerm.app isn't installed, hand back
# a clear error before osascript fails opaquely.
if [ "$TERMINAL" = "iterm2" ] && [ ! -d "/Applications/iTerm.app" ]; then
  log_err "--terminal iterm2 selected but /Applications/iTerm.app not found"
  log_err "  Install via: brew install --cask iterm2"
  log_err "  Or pass --terminal terminal to use Apple Terminal."
  exit 2
fi

case "$TERMINAL" in
  iterm2|terminal) ;;
  *)
    log_err "Unsupported --terminal: $TERMINAL (expected iterm2 or terminal)"
    exit 2
    ;;
esac

# ----- render the bootstrap prompt -----------------------------------------

RENDERER="$(dirname "$0")/bootstrap-pillar-prompt.sh"
if [ ! -x "$RENDERER" ]; then
  log_err "bootstrap-pillar-prompt.sh not found or not executable: $RENDERER"
  exit 1
fi

# Build the renderer arg list. POSIX-portable conditional argument
# construction (no arrays).
render_cmd="$RENDERER --letter $LETTER --product $PRODUCT"
[ "$WITH_DRIFT_CHECK" = "1" ] && render_cmd="$render_cmd --with-drift-check"
[ -n "$LOCAL_REPO_PATH" ] && render_cmd="$render_cmd --local-repo-path \"$LOCAL_REPO_PATH\""

log_info "Rendering bootstrap prompt for Pillar $LETTER ($PRODUCT)..."
RENDERED="$(eval "$render_cmd")"
if [ -z "$RENDERED" ]; then
  log_err "Renderer returned empty output. Run the renderer directly to see the error:"
  log_err "  $render_cmd"
  exit 1
fi

# ----- clipboard -----------------------------------------------------------

if [ "$NO_CLIPBOARD" != "1" ]; then
  printf '%s' "$RENDERED" | pbcopy
  log_info "Copied $(printf '%s' "$RENDERED" | wc -l | tr -d ' ') lines to clipboard"
fi

# Always print to stdout so the operator can verify, pipe, or recover if
# pbcopy silently fails. Suppressed only when explicitly opening a new tab
# without --no-clipboard (the default flow) to keep the terminal output
# focused on next-step instructions.
if [ "$NO_OPEN" = "1" ] || [ "$NO_CLIPBOARD" = "1" ]; then
  printf '%s\n' "$RENDERED"
fi

# ----- open new terminal tab -----------------------------------------------

if [ "$NO_OPEN" = "1" ]; then
  log_info "--no-open set; not opening a new terminal tab"
  log_info "Next steps:"
  log_info "  1. Switch to your target terminal tab (or open one manually)"
  log_info "  2. Launch Claude (claude / claude-code / your chosen entry point)"
  log_info "  3. Paste the bootstrap prompt with ⌘V as the first message"
  exit 0
fi

# AppleScript per terminal. Both scripts open a new tab in the frontmost
# window of the target app and bring the app to the front. Neither types
# anything into the new tab — that's the operator's job (⌘V into Claude).
case "$TERMINAL" in
  iterm2)
    # iTerm2 scripting reference: https://iterm2.com/documentation-scripting.html
    # Cold-start safe: if iTerm2 was just launched and has no windows, the
    # "current window" reference would fail; create a window instead.
    # `select` on the new tab guarantees it grabs focus so the operator's
    # very next keystroke (or ⌘V) lands in the right place.
    osascript <<'APPLESCRIPT' 2>&1
tell application "iTerm"
  activate
  if (count of windows) is 0 then
    create window with default profile
  else
    tell current window
      set newTab to (create tab with default profile)
      select newTab
    end tell
  end if
end tell
APPLESCRIPT
    rc=$?
    ;;
  terminal)
    # Apple Terminal: System Events sends ⌘T to open a new tab in the
    # frontmost Terminal window.
    osascript <<'APPLESCRIPT' 2>&1
tell application "Terminal"
  activate
end tell
tell application "System Events"
  keystroke "t" using {command down}
end tell
APPLESCRIPT
    rc=$?
    ;;
esac

if [ "$rc" != "0" ]; then
  log_err "osascript failed (rc=$rc) while opening a new tab in $TERMINAL"
  log_err "  The rendered prompt is on your clipboard; switch to a tab manually and paste."
  exit 1
fi

log_info "Opened a new $TERMINAL tab"
log_info "Next steps in the new tab:"
log_info "  1. Launch Claude (claude / your chosen entry point)"
log_info "  2. Paste the bootstrap prompt with ⌘V as the first message"
log_info "  3. Wait for the new tab's Pillar Orchestrator to propose its first FR"
log_info "  4. Approve the FR pick before it dispatches /sdlc"
