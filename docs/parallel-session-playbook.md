# Parallel Session Playbook

This playbook walks through running two Claude SDLC sessions in parallel against the UGC
Platform — Section A on FR-A.1.9 and Section C on a hypothetical FR-C.1.18 — using the
AIDLC Coordination Service scripts.

The goal is to show the **end-to-end flow** for one concrete day, with actual commands
and expected outputs. Use it as a template when you spin up your own parallel sessions.

---

## Integrated mode (default, GDI-677+)

For products whose SDLC platform profile sets `coordination.enabled: true`
(UGC Platform is the first such opt-in, shipped 2026-05-13 via GDI-677),
parallel sessions run automatically against this registry — there is nothing
manual to do per ticket. The orchestrator's Phase 0.6 (Coordination Pre-flight)
calls `conflict-check.sh` + `reserve.sh`, Stage 4 (Development) calls
`worktree.sh add` to isolate the session, and Stage 10 (Close) calls
`release.sh` + `worktree.sh remove`. The Section Owner just runs `/sdlc` as usual.

**Worktree-per-session (GDI-728).** Resource-level claims (V-numbers, model
surfaces, file paths) do not protect against same-user, same-clone working-tree
contamination — branches disappear locally when another session runs
`git checkout`. Stage 4 of every concurrent session is dispatched into a
deterministic isolated worktree at `/tmp/aidlc-worktrees/<product>-<epic>`.
Idempotent: a re-run with the same epic returns the existing path.

### End-to-end flow

```sh
# One-time setup per workstation
cd ~
git clone https://github.com/syndigo/aidlc-coordination ~/.aidlc-coordination

# One-time setup per aidlc checkout (propagates updated SKILL.md to ~/.claude)
cd ~/Projects/aidlc
./install.sh

# Per ticket — one command, both Tabs identical
cd ~/Projects/ugc-platform
/sdlc GDI-720         # Tab 1: Section A continuing FR-A.1.9
# Phase 0.6 runs Phase 0.6 conflict-check + reserve automatically.
# Stage 10 runs release.sh automatically.

cd ~/Projects/ugc-platform
/sdlc GDI-721         # Tab 2: Section C starting FR-C.1.18
# Phase 0.6 detects the FR-A.1.9 anchor surface held by Section A.
# On WAIT, Tab 2 BLOCKS with a structured message before Stage 1.
```

### How Phase 0.6 decides what to reserve

The orchestrator reads `profile.coordination.touch_patterns` and matches the
ticket's primary FR against each pattern's `when_fr_matches` regex:

| FR matches | Reserves |
|---|---|
| `FR-A.1.(7-12)`, plus other AI surfaces | `ModelRegistry.kt` file-lock |
| Any `FR-*.*.*` AI surface | `Prompts.kt` file-lock |
| Intake mentions `schema`/`migration`/`new table` | Flyway version |

If the regex misses or over-matches, override at the CLI:
```sh
/sdlc GDI-720 --files-to-touch services/ugc-api/.../Foo.kt,services/ugc-api/.../Bar.kt
```

If a product hasn't opted in via its profile, force-on the integrated check ad-hoc:
```sh
/sdlc GDI-XYZ --coordinate
```

### When to fall back to manual mode

The manual flow below is the right tool for:
- Inspecting current registry state without running a full /sdlc
- Extending the TTL on an in-flight reservation that's about to expire
- Debugging an orchestrator-level coordination issue
- Sections of products that have not yet added `coordination:` to their profile

---

## Portfolio mode (D-016, multi-pillar coordination)

When you have ≥3 pillars in flight against the same product, the integrated
mode above is necessary but not sufficient — it stops two Section Owners
from stepping on each other, but it doesn't decide *which pillar to run
next* or *which FR is on the critical path*. That's the job of the
Portfolio Orchestrator (Tier 3) and Pillar Orchestrator (Tier 2) personas.

A typical multi-pillar tick looks like this:

```sh
# 1. Portfolio dashboard — read first thing each tick
./scripts/portfolio-status.sh
# Shows: in-flight pillar count vs cap, critical path, lock contention,
#        cross-pillar anchors, blocked_on entries per pillar.

# 2. Refresh the computed stats block (so other tabs see fresh numbers)
./scripts/portfolio-status.sh --update-stats

# 3. For each pillar that should make progress this tick, hand off to
#    its Pillar Orchestrator (one /sdlc per pillar, NOT per FR).
#    The Pillar Orchestrator picks the next launchable FR and spawns a
#    Section Owner for it via /sdlc <ticket>.

# 4. When a Section Owner ships, release.sh (called automatically by
#    /sdlc Stage 10) moves the FR to shipped_frs and surfaces any
#    successor_epic to the Portfolio. The Portfolio reads it on the
#    next tick and unblocks the chain.
```

For a single pillar's view (what the Pillar Orchestrator reads on its tick):

```sh
./scripts/pillar-status.sh --letter B
# Shows: in_flight_frs vs max cap, fr_backlog, serial_chains with
#        ship status per link, blocked_on entries, lock contention
#        forecast for files this pillar's backlog touches.
```

### Spawning a pillar tab (D-025 / D-026)

To start a new pillar tab, render its bootstrap prompt and open a tab in
one command:

```sh
./scripts/spawn-pillar.sh --letter C --with-drift-check
```

This (1) renders the Pillar C handoff prompt against current registry
state, (2) copies it to the clipboard, (3) opens a new **iTerm2** tab and
selects it. Pillar-orchestrator sessions live in iTerm2 regardless of
where you invoke the script from — VS Code's integrated terminal, an SSH
session, iTerm2 itself. The one exception: invoke from Apple Terminal and
it honors that. Pass `--terminal terminal` to force Apple Terminal.

Then **in the new tab**, you do three things by hand (the script does NOT
automate these — D-025 approach (a), deliberately, so it doesn't fight
the Claude CLI's input handling):

1. Launch Claude.
2. ⌘V to paste the bootstrap prompt as the first message.
3. Hit Enter.

The clipboard rule: run `spawn-pillar.sh` → switch to the new tab → ⌘V
**immediately**. If you copy anything else in between (a path, a summary),
the prompt is gone — recover with `./scripts/spawn-pillar.sh --letter C
--no-open`, which re-renders and re-copies without opening another tab.

`--no-open` is also the right flag when invoking from VS Code if you'd
rather open the new pane yourself: the script just renders + copies, you
⌃⇧\` and ⌘V.

See [orchestration-tiers.md](./orchestration-tiers.md) for the full 3-tier
model, hand-off contracts, and authority limits per persona.

---

## Manual mode (fallback)

The remainder of this document walks through the Day-1 manual flow that
`/sdlc` now performs at Phase 0.6 + Stage 10. The commands are identical;
the only difference is who runs them (operator vs orchestrator).

## Setup (one-time)

Each operator clones the coordination repo once, alongside the product repo:

```sh
cd ~/Projects
gh repo clone syndigo/aidlc-coordination
gh repo clone syndigo/ugc-platform   # the product repo, if you don't already have it
```

The scripts assume `aidlc-coordination/` is checked out and on the latest `main`. Pull
before starting each session:

```sh
cd ~/Projects/aidlc-coordination && git pull --rebase
```

---

## Scenario

- **Session 1 (Tab 1):** Section A continuing work on FR-A.1.9 (catalog-locale-translation).
  This is the live in-flight item per the seeded registry. Section A already holds the
  `ModelRegistry.kt` + `Prompts.kt` locks and a `V19` Flyway reservation.

- **Session 2 (Tab 2):** A fresh Section C ticket — FR-C.1.18 — that needs to add
  reviews translation. It depends on the FR-A.1.9 anchor surface.

---

## Session 1 — Section A (resuming)

### Step 1.1 — Pre-flight check

```sh
$ cd ~/Projects/aidlc-coordination
$ ./scripts/conflict-check.sh \
    --section A \
    --fr FR-A.1.9 \
    --files-to-touch ModelRegistry.kt,Prompts.kt
```

**Expected output:**

```
[INFO]  GO — section A may proceed with FR-A.1.9
GO
```

Section A is already the holder; the check is idempotent.

### Step 1.2 — Isolate the session in a worktree (GDI-728)

Before switching to the product repo, create a per-epic worktree so a parallel
session (Section C in another Tab) cannot stomp on this checkout:

```sh
$ ./scripts/worktree.sh add \
    --repo-path ~/Projects/ugc-platform \
    --epic GDI-720 \
    --branch feature/GDI-720-catalog-locale-translation
[INFO]  Fetching origin in ~/Projects/ugc-platform...
[INFO]  Creating new branch 'feature/GDI-720-catalog-locale-translation' from origin/dev in worktree /tmp/aidlc-worktrees/ugc-platform-GDI-720
/tmp/aidlc-worktrees/ugc-platform-GDI-720

$ cd /tmp/aidlc-worktrees/ugc-platform-GDI-720
$ git status
On branch feature/GDI-720-catalog-locale-translation
Your branch is up to date with 'origin/dev'.
nothing to commit, working tree clean
```

The worktree command is idempotent — re-running it for the same epic
returns the existing path without recreating anything.

### Step 1.3 — Do the work in the product repo

Section A's session now operates in the worktree at
`/tmp/aidlc-worktrees/ugc-platform-GDI-720` and runs `/sdlc` against
GDI-720 (the Jira ticket for FR-A.1.9). The coordination repo is no longer touched
until ship time.

### Step 1.4 — Stage 9 release-tag pre-flight (GDI-770 retro)

Before invoking `gh release create`, claim the release tag in the registry
so a sibling tab that reaches Stage 9 concurrently can't win the same
`vX.Y.Z` by race. The pattern mirrors the Flyway / model-registry holds:

```sh
$ cd ~/Projects/aidlc-coordination
$ ./scripts/conflict-check.sh --section A --fr FR-A.1.9 \
    --release-tags v0.28.0 --json
# GO ⇒ proceed; WAIT ⇒ another tab claimed it; pick the next minor and retry.

$ ./scripts/reserve.sh --resource release-tag --section A \
    --epic section-A-FR-A.1.9-epic --id v0.28.0 --ttl-hours 4
```

The reservation lives in `.releases.in_flight[]`. Stage 10's
`release.sh --resource release-tag --status=released` advances
`.releases.current_main` to the new tag and removes the in-flight row.

This step closes the GDI-708 / GDI-770 collision class where two tabs cut
the same `v0.31.0` first-come-first-served because the registry only
arbitrated Flyway versions and file locks, not tags.

### Step 1.5 — Ship + release

When the PR merges and `v0.28.0` is tagged:

```sh
$ cd ~/Projects/aidlc-coordination
# As of 2026-05-19, pillar-block updates are default-on. Pass --fr so the
# pillar block picks up the shipped FR automatically (skipping --fr triggers
# a warning and skips the pillar-block hooks for that call).
$ ./scripts/release.sh --resource flyway --section A \
    --epic section-A-FR-A.1.9-epic --id V19 --fr FR-A.1.9 \
    --status shipped --release-tag v0.28.0

$ ./scripts/release.sh --resource model-registry --section A \
    --epic section-A-FR-A.1.9-epic --id catalog-locale-translation --fr FR-A.1.9 \
    --status shipped --release-tag v0.28.0

$ ./scripts/release.sh --resource file-lock --section A \
    --epic section-A-FR-A.1.9-epic \
    --id services/ugc-api/src/main/kotlin/com/syndigo/ugc/ai/ModelRegistry.kt \
    --status released --no-update-pillars-block   # file-locks don't carry an FR

# Clean up the per-epic worktree (GDI-728).
# Refuses if the worktree is dirty — commit/push first if so.
$ ./scripts/worktree.sh remove \
    --repo-path ~/Projects/ugc-platform \
    --epic GDI-720
[INFO]  Removing worktree /tmp/aidlc-worktrees/ugc-platform-GDI-720...
[INFO]  Worktree removed: /tmp/aidlc-worktrees/ugc-platform-GDI-720
```

After these run, the FR-A.1.9 anchor is `shipped` and the three blocked consumers
(C.1.18, B.1.9, J.5.4) move to `free`. The Release Coordinator then pings the
unblocked sections.

> **Caution — flyway and model-registry must use `--status=shipped` with a real
> `--release-tag`.** `release.sh` rejects `--status=released` for those resources
> because it would append a row with an empty `release_tag`, which fails schema
> validation (`semverTag` rejects `""`). `--status=released` remains valid for
> `file-lock` (clears `held_by`) and `release-tag` (sets `current_main`). See D-013.
>
> **GDI-770 retro — clean exit for stale reservations.** If a sibling tab won
> the race for the version/surface you reserved (the GDI-770 V29/V30
> pattern), use `--status=abandoned --reason "<text>"` to remove the
> reservation cleanly without a shipped append. This is valid for `flyway`
> and `model-registry` only. The `--reason` is required and is carried in
> the git commit message for audit.
>
> Example:
>
> ```sh
> ./scripts/release.sh --resource flyway --section D \
>   --epic GDI-770 --id V29 --status abandoned \
>   --reason "Sibling tab GDI-742 won V29 race; renamed to V31 via fix-forward"
> ```
>
> **GDI-798 — orphan sweep after Stage 10.** `release.sh` only releases the
> single resource its `--id` names. After an epic ships its canonical
> migration (e.g. GDI-800 shipped V32 + V932 + the file-locks), older-version
> reservations under the same epic remain orphaned in the registry until
> manually swept. Use `--all-for-epic` for a one-shot sweep that drops every
> remaining reservation across `flyway.reserved`, `flyway.test_fixture_range`,
> `model_registry.pending`, `single_writer_files` (`held_by==KEY`), and
> `releases.in_flight`. The sweep lands in a single commit and is idempotent
> (re-running with zero matches exits 0). See D-015.
>
> Example — sweep GDI-800's leftover V22/V923 after the V32/V932 ship:
>
> ```sh
> # Preview the sweep first:
> ./scripts/release.sh --all-for-epic GDI-800 --dry-run
>
> # Then execute:
> ./scripts/release.sh --all-for-epic GDI-800 \
>   --reason "Stage 10 of GDI-800 shipped V32/V932; sweeping older V22/V923 orphans"
> ```

---

## Session 2 — Section C (attempted parallel start)

### Step 2.1 — Pre-flight check (while Section A is still in_flight)

```sh
$ cd ~/Projects/aidlc-coordination && git pull --rebase
$ ./scripts/conflict-check.sh \
    --section C \
    --fr FR-C.1.18 \
    --files-to-touch ModelRegistry.kt
```

**Expected output:**

```
[WARN]  WAIT — section C cannot proceed with FR-C.1.18:
WAIT file=ModelRegistry.kt held_by=section-A-FR-A.1.9-epic until=2026-05-14T22:00:00Z
WAIT:
WAIT file=ModelRegistry.kt held_by=section-A-FR-A.1.9-epic until=2026-05-14T22:00:00Z
```

Exit code: `1`. The session does NOT proceed.

### Step 2.2 — Verify anchor dependency

`conflict-check.sh` also surfaces the anchor block:

```sh
$ ./scripts/conflict-check.sh --section C --fr FR-C.1.18
[WARN]  WAIT — section C cannot proceed with FR-C.1.18:
WAIT anchor=FR-A.1.9 status=in_flight
```

The session can read `status.sh` to see when Section A is expected to ship:

```sh
$ ./scripts/status.sh
=================================================
 AIDLC Allocation Status — ugc-platform
=================================================
 current_main:   v0.27.0
 ...
--- Active reserved Flyway versions ---
  V19  section=A  epic=section-A-FR-A.1.9-epic  fr=FR-A.1.9  expires=2026-05-14T22:00:00Z
 ...
--- Anchor dependencies (in-flight) ---
  FR-A.1.9 (section A): Translation single-anchor surface
    consumers: C.1.18 (blocked_until_anchor_shipped), ...
```

### Step 2.3 — Section C's options

1. **Wait until 2026-05-14T22:00:00Z** for Section A to ship, then re-run Phase 0.
2. **Swap to a different Section C ticket** that doesn't depend on FR-A.1.9 (e.g.
   FR-C.1.5 which has no anchor dependency).
3. **Escalate to the Release Coordinator** if FR-A.1.9 is slipping and FR-C.1.18 is
   on the critical path.

Section C chooses option 2 and pivots to a different ticket. No code was written yet —
the cost of the conflict was a 30-second `conflict-check.sh` call, not a 4-hour PR
rebase battle.

---

## After Section A ships

Once `v0.28.0` is released and the Release Coordinator runs the post-ship registry
updates, Section C's pre-flight returns GO:

```sh
$ ./scripts/conflict-check.sh --section C --fr FR-C.1.18 \
    --files-to-touch ModelRegistry.kt
[INFO]  GO — section C may proceed with FR-C.1.18
GO
```

Section C reserves and proceeds:

```sh
$ ./scripts/reserve.sh --resource file-lock --section C \
    --epic GDI-740 --id services/ugc-api/src/main/kotlin/com/syndigo/ugc/ai/ModelRegistry.kt \
    --fr FR-C.1.18 --ttl-hours 24

$ ./scripts/reserve.sh --resource flyway --section C \
    --epic GDI-740 --id V24 --fr FR-C.1.18 --ttl-hours 24
```

> **Flyway version-collision gate (D-029).** `reserve.sh --resource flyway`
> REFUSES (`exit 3`) any version already in `flyway.shipped` or
> `flyway.reserved` — held by any epic. This is the hard stop that prevents
> the duplicate-migration pileups that caused the 2026-05-20 dev outage
> (two epics both grabbed V112, Flyway hard-failed on boot). To pick a free
> version, read the tail of `flyway.shipped` + `flyway.reserved` in
> `allocations/<product>.yml`, or run `audit-registry-drift.sh`. The only
> override is `--force-flyway-version`, for recovering a slot abandoned by a
> dead tab — it logs a loud WARN and makes you responsible for renumbering.

---

## Tips

- **Always `git pull --rebase` before running any script.** Other sections may have
  pushed updates since you last ran `status.sh`.

- **Use `--json` for any script when piping into another tool.** The human format is
  optimized for terminal reading; the JSON format is stable across releases.

- **Use `--dry-run` on `reserve.sh` when learning.** It shows the diff without
  pushing — useful for the first few times.

- **If you hit a `WAIT` you don't understand,** run `./scripts/status.sh` and read the
  full active state. The conflict-check output is intentionally terse.

- **Reservations expire on TTL.** If your work runs past the TTL, re-run `reserve.sh`
  with the same args to extend.
