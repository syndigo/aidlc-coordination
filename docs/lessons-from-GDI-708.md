# Lessons Learned — GDI-708 (Section B FR-B.1.9) Pipeline Run

**Date:** 2026-05-13
**Pipeline:** `/sdlc --profile ugc-platform GDI-708`
**Run context:** Three parallel SDLC tabs against the same product (Section A, Section B = this run, Section D). Section A and Section D were active in their own terminal tabs simultaneously.
**Outcome at time of writing:** Pipeline blocked at Stage 7 by a real test regression that was caused, in part, by gaps in this coordination system.

This document captures the gaps that the file-based coordination registry **did not catch** and proposes concrete enhancements. It is input for D-007+ ADRs and persona spec refinements.

---

## What worked

- **Pre-flight `conflict-check.sh` returned GO correctly.** No file-level collision on `ModelRegistry.kt` / `Prompts.kt` between the three tabs at the time GDI-708 started.
- **Reservation calls were idempotent and survived rebase failures.** The "[ERROR] git pull --rebase failed" warning on every script call (caused by a leftover branch tracking config) did not corrupt registry state.
- **24-hour TTLs gave a safety net** when V24 was wrongly reserved (see Gap 1).

## Gaps that bit this run

### Gap 1 — The registry trusts agent-reported state, not branch reality

**What happened:**
- Stage 3 (Design) agent claimed `V24__review_summaries.sql` already existed on the `dev` branch and reassigned this run's migration from V24 to V25.
- The orchestrator, trusting that claim, called `release.sh --resource flyway --id V24` and `reserve.sh --resource flyway --id V25`.
- Later inspection showed **`V24__review_summaries.sql` does not exist anywhere** — not on `dev`, not on the feature branch, not on any sibling Tab. The agent hallucinated it.
- Result: V24 is now "next_free" in the registry while no human or pipeline expects it to be. The next pipeline run that reserves V24 will collide with no one — harmless this time, but it represents permanent skew between registry and code-base reality.

**Why the registry didn't catch this:** `conflict-check.sh` operates on the YAML registry alone. It does not verify against the actual contents of `git ls-tree origin/dev`. The registry can drift from reality the moment an agent fabricates a precondition.

**Proposed enhancement:**
- **`conflict-check.sh --verify-against <ref>`** — optional `git ls-tree <ref>` cross-check for the Flyway resource family. Before granting GO on flyway V_N, run `git ls-tree origin/dev services/<service>/src/main/resources/db/migration/ | grep -c "V${N}__"`. If non-zero, return WAIT with reason `registry-skew: V_N exists on <ref> but registry says reserved/free`.
- **Periodic reconciler.** A new `scripts/reconcile.sh` (called by a CI cron or `/sdlc` Phase 0.6 once per day) that diffs registry vs reality and prints discrepancies. Optionally auto-corrects (with a `--apply` flag).

### Gap 2 — Worktree-level stomping is invisible to the registry

**What happened:**
- The Stage 4 (Development) agent reported: "A parallel agent in the main worktree at `/Users/nateembree/Projects/ugc-platform` repeatedly reset the GDI-708 branch to a sibling branch's tip during my session, forcing me to recover commits via reflog and switch all subsequent work to an isolated worktree at `/tmp/ugc-platform-GDI-708`."
- The "parallel agent" was the user's Section D / GDI-709 tab, running in the same terminal session, using the same local clone.
- The Stage 7 (Test) agent ran into the same problem: `git stash` reported the working tree was on `feature/GDI-709-section-d-qa-question-submission`, not on the branch under test. Its initial regression diagnosis was based on a wrong file because of this.

**Why the registry didn't catch this:** Coordination is at the registry-row level (Flyway version, file-lock entry, model surface). It assumes each session has its own isolated working tree. In practice, multiple `/sdlc` tabs running on the same workstation share `~/Projects/ugc-platform` and trample each other's `git checkout`.

**Proposed enhancement:**
- **Worktree-aware reservation.** Add an optional `worktree:` field to the reservation YAML — the absolute path the session is running in. When two sessions reserve resources for the same product on the same workstation but with different `worktree:` paths, surface a warning (`WARN: cross-worktree session detected — confirm isolation`).
- **`scripts/check-worktree.sh`** — a helper that the `/sdlc` orchestrator calls at Phase 0 to verify the current `pwd` matches the worktree this session reserved. If not, BLOCK with: "Working directory has been mutated by a sibling session. Run `git worktree add /tmp/<product>-<ticket> <branch>` and re-run /sdlc from there."
- **Document the multi-tab pattern.** Update `docs/parallel-session-playbook.md` with a "Same-workstation, multiple-tabs" subsection that prescribes per-tab git worktrees (e.g., `/tmp/ugc-platform-section-B`, `/tmp/ugc-platform-section-D`) instead of sharing `~/Projects/ugc-platform`.

### Gap 3 — CI green ≠ local green; the registry has no signal for build-cache divergence

**What happened:**
- PR #110 reported `Build & test` PASS (8m35s) on GitHub Actions.
- Locally, the same SHA (`b3cc93b`) reproducibly failed 3 tests in `ModelRegistryTest` with `NoWhenBranchMatchedException`.
- The Stage 7 agent flagged this divergence as "either CI Gradle remote cache is masking a failing test, or there's a kotest-vs-junit5 selector difference."
- This is a real build-system bug — not a coordination concern per se — but it means the **registry's release-tag entry** (which trusts CI to gate quality) would have allowed `release.sh --status shipped` while the build was still actually broken.

**Why the registry didn't catch this:** Coordination is upstream of build quality. It has no DoD signal of its own.

**Proposed enhancement:**
- **Add a `quality_gate:` field to releases.** When `release.sh --status shipped` is called, optionally include `--quality-gate-evidence=<URL>` pointing to the run that gave the green. The registry stores it. A future audit script can spot-check: "did the run actually pass, or was the cache stale?"
- **In the playbook**, prescribe a quick local re-run before calling `release.sh --status shipped`: `./gradlew :services:<svc>:test --rerun-tasks --no-build-cache --no-daemon` for the touched module. Cheap insurance.

### Gap 4 — No locking on the product's migration directory as a whole

**What happened:**
- Section A holds Flyway V20, V21, V22, V23 (per the seeded registry on 2026-05-13).
- Section B (this run) was first told to use V24, then re-routed to V25.
- The current `next_free` is V24 (re-released by the V24→V25 swap).
- If any of Section A's pending work doesn't end up shipping V21..V23, **the migration sequence will have permanent gaps**: V20, then nothing until V25. Flyway treats this as a hard error in `repair` mode and a soft warning in `migrate` mode.

**Why the registry didn't catch this:** Each Flyway version is a separate row. There's no concept of "the migration sequence MUST be contiguous" — that's a Flyway-tool-level invariant the registry doesn't model.

**Proposed enhancement:**
- **Add a `flyway_sequence_check` to `status.sh`.** Print warnings when the registry has gaps between shipped + reserved versions. Example output: `WARN: flyway gaps detected — shipped: V1..V19; reserved: V20,V21,V22,V23,V25; gap: V24`.
- **Optional: a `compact_reservations` script** that re-numbers reservations to remove gaps when the affected sections agree. This is dangerous (it rewrites history-in-progress) and should be gated by a `--unsafe-renumber` flag.

### Gap 5 — Cross-section ADD deviations need a coordination signal, not just a Phase 13 retro note

**What happened:**
- Stage 4 implementation of GDI-714 deviated from the ADD: instead of routing through the FR-A.1.9 `PLATFORM_LOCALE_TRANSLATION_V1` anchor (a cross-section integration that was the whole point of picking B.1.9), the implementation passes the locale to Bedrock directly.
- The orchestrator caught this and logged it for Phase 13 retro.
- But this is also a **broken anchor-consumer contract** at the coordination level: the registry's `anchor_dependencies` entry for FR-A.1.9 names `B.1.9` as a consumer with `status: not_started`. After GDI-708 ships, the registry will say the consumer "shipped" — but it doesn't actually consume the anchor.

**Why the registry didn't catch this:** Anchor-dependency status is updated by `release.sh`. The script trusts the caller. There's no contract-level verification.

**Proposed enhancement:**
- **`release.sh --resource anchor-consumer` should require evidence.** Add `--consumer-verified=<file:line-or-symbol>` — e.g., `--consumer-verified=services/ugc-api/.../EmailTemplateGenerator.kt:invokeLocaleTranslationValidator`. The script greps the cited symbol from the cited file at the release-tag SHA. If absent, refuse to mark the consumer as `shipped` and downgrade to `partial`.
- **Reflect "partial" anchor-consumption in `status.sh`.** Surfaces sections that *claim* to consume an anchor but don't actually invoke it.

### Gap 6 — A "WARN" from `conflict-check.sh` cannot represent a self-hold

**What happened (minor, observed during V24→V25 swap):**
- After releasing V24 and reserving V25, a sanity `conflict-check.sh` returned WAIT with reason `held_by=GDI-708` — i.e., this run was warned about its own hold.
- This is technically correct but cosmetically confusing for an orchestrator that's checking idempotency.

**Proposed enhancement:**
- **Add `--ignore-self <epic>`** flag to `conflict-check.sh` so an orchestrator can ask "would I conflict with anyone OTHER than myself?" — useful when re-running Phase 0.6 mid-pipeline.

---

## Recommended enhancement priority

| # | Gap | Severity | Effort | Recommended ADR |
|---|---|---|---|---|
| 1 | Registry trusts agent state, not git reality | HIGH — caused real registry skew | M (1 day) | D-007 — Reality-cross-check for Flyway resource family |
| 2 | Worktree-level stomping invisible | HIGH — corrupted 2 stages of this run | S (½ day) | D-008 — Worktree-aware reservation + per-tab git-worktree playbook |
| 3 | CI green ≠ local green | MEDIUM — narrowly missed shipping broken | S (½ day) | D-009 — Optional `--quality-gate-evidence` on release |
| 4 | Flyway sequence gaps | MEDIUM — future-pain | XS (2 hours) | D-010 — Sequence-gap warnings in `status.sh` |
| 5 | Anchor-consumer contract not enforced | MEDIUM — semantic drift on cross-section integrations | M (1 day) | D-011 — `--consumer-verified` on anchor releases |
| 6 | Self-hold cosmetics | LOW | XS (1 hour) | D-012 — `--ignore-self` flag |

## Recommended persona-spec updates

- **`personas/section-owner.md`** — add a "Multi-Tab Discipline" section that prescribes per-tab `git worktree add` instead of sharing the repo clone. Without this, registry-level coordination is undermined by filesystem-level stomping.
- **`personas/release-coordinator.md`** — add a "Quality Evidence Capture" subsection that prescribes a local `--rerun-tasks --no-build-cache` test pass before calling `release.sh --status shipped`. CI-only verification can be silently cached.
- **`personas/retro-aggregator.md`** — add an explicit responsibility: "Forward registry-vs-reality discrepancies (Flyway gaps, anchor-consumer contract violations) to the next-week ADR cycle, not just to retro markdown."

## Recommended changes to `docs/parallel-session-playbook.md`

- New subsection: **"Same workstation, multiple tabs"** — show the `git worktree add /tmp/<product>-<section> <branch>` pattern.
- New subsection: **"What the registry does NOT prevent"** — list the gaps above so operators know they need worktree isolation and local-test re-runs as well as the registry.
- New troubleshooting entry: **"My branch keeps getting reset by a sibling session"** — diagnose worktree contention; remedy is `git worktree`.

---

## What this run did with its retro

This run's Phase 13 (auto-retro) will:
1. Open a Jira story to fix the V24-reservation registry skew (call `reserve.sh --resource flyway --section B --epic registry-cleanup --id V24` then `release.sh --status released`).
2. File six follow-up Jira tickets — one per gap above — assigned to whoever owns the `aidlc-coordination` repo.
3. File one follow-up ticket on the `ugc-platform` repo for the `EmailTemplateGenerator` → `LocaleTranslationValidator` anchor consumer re-wiring (Gap 5 example).
4. Add this file to the `aidlc-coordination` repo as `docs/lessons-from-GDI-708.md` and link it from `docs/decisions.md` as the input for D-007 through D-012.
