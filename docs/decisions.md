# Architecture Decision Records (ADR Log)

This is the append-only ADR log for the AIDLC Coordination Service.

Each ADR follows the format: **D-NNN — Title** (status, date, decider) followed by
Context, Decision, Consequences. Append new entries at the bottom; never edit
historical entries (correct via a new ADR that supersedes the old one).

---

## D-001 — File-based registry over HTTP service

**Status:** Accepted
**Date:** 2026-05-12
**Decider:** VP DevOps (initial design)

### Context

We need a registry that allows multiple parallel SDLC sessions to coordinate on shared
resources (Flyway versions, single-writer files, model registry surfaces, release
tags) without stomping on each other. Three options:

1. File-based YAML in a dedicated repo, edited via scripts, git as audit trail.
2. HTTP service (small Flask/Express app, SQLite-backed).
3. Postgres + Hasura GraphQL.

### Decision

Go with **option 1 (file-based)** for Day 1.

### Consequences

**Positive:**
- Zero infrastructure to deploy
- The entire state is visible in one file — invaluable during incidents
- Git history IS the audit trail; no separate audit log to maintain
- Trivial to validate via JSON Schema in CI
- Recoverable from any clone

**Negative:**
- Write latency is ~5 seconds (yq edit + commit + push)
- Concurrent writers serialize via git push contention (acceptable up to ~10/sec)
- No ACL beyond GitHub repo permissions
- No fine-grained query API; consumers must read the whole file

**Revisit if:** write volume exceeds 10/sec, multiple products' YAMLs become a
maintenance burden, or we need fine-grained ACLs (e.g. Section A can only edit its own
row enforced server-side).

---

## D-002 — Single registry repo, one YAML per product

**Status:** Accepted
**Date:** 2026-05-12
**Decider:** VP DevOps (initial design)

### Context

Should each product have its own coordination repo, or share one?

### Decision

**One repo (`syndigo/aidlc-coordination`), one YAML per product** under `allocations/`.

### Consequences

**Positive:**
- Shared schema, shared scripts, shared CI
- Cross-product anchor dependencies become possible later (single source of truth)
- Operator clones one repo, gets coordination for everything

**Negative:**
- A burst of writes on Product A's YAML serializes with writes on Product B's YAML
  (same git push contention)
- Mitigation: it's unlikely we'll have parallel sessions on two products at the same
  minute on Day 1; revisit if it becomes a real bottleneck

---

## D-003 — Scripts are POSIX-bash, processed via mikefarah/yq v4

**Status:** Accepted
**Date:** 2026-05-12
**Decider:** VP DevOps (initial design)

### Context

What language for the read/write scripts? Bash, Python, Node?

### Decision

POSIX-bash (bash 3.2 compatible — macOS default) using **mikefarah/yq v4** as the YAML
processor.

### Consequences

**Positive:**
- No runtime to install on operator machines (bash + yq + git is universal)
- Easy to read; easy to fork into one-off operations during incidents
- `shellcheck --severity=warning` keeps quality high
- yq v4 is well-known, well-maintained, and idiomatic for this use case

**Negative:**
- Bash is hard to test (no unit-test ergonomics like pytest)
- POSIX-portability constraints (no `[[`, no `${var,,}`, no associative arrays) are
  occasional sources of friction

**Test strategy:** integration tests via shell scripts that exercise reserve → conflict
→ release flows against a temp YAML. Unit-test-equivalent coverage via `shellcheck`
+ schema validation in CI + the bootstrap-log smoke test.

---

## D-004 — Day-1 scripts edit `main` directly (not via PR)

**Status:** Accepted
**Date:** 2026-05-12
**Decider:** Stage 4 development run

### Context

Should `reserve.sh` / `release.sh` open a PR per edit and rely on auto-merge, or push
directly to `main`?

### Decision

**Push directly to `main`** on Day 1, with `git pull --rebase` retry on push-rejected.

### Consequences

**Positive:**
- Faster (single push, not PR-creation + auto-merge wait)
- Simpler to reason about; the audit trail is the linear commit history
- No dependency on GitHub auto-merge plumbing for the bootstrap
- The `main` branch's branch-protection setting allows admin push by Section Owner
  identities on Day 1

**Negative:**
- Bypasses any future Compliance Reviewer gate that watches PRs (but the gate is
  deferred — see `personas/compliance-reviewer.md`)
- A bad script edit lands on `main` immediately; recovery is `git revert`

**Revisit:** once the Compliance Reviewer goes live (Phase 2), the scripts should
graduate to "branch + PR + auto-merge" so the gate has something to evaluate.

---

## D-005 — Branch protection on `main` starts permissive

**Status:** Accepted
**Date:** 2026-05-12
**Decider:** Stage 4 development run

### Context

What branch protection should we enable on day 1 of a brand-new solo-author repo?

### Decision

- `required_approving_review_count = 0` (raise to 1 once a second human is on the repo)
- `required_status_checks = null` (add named checks once the CI workflow has produced
  them; today the workflow has never run)
- `allow_force_pushes = false`
- `allow_deletions = false`
- `enforce_admins = false`

### Consequences

**Positive:**
- Solo-bootstrap PR can land without artificial friction
- Forbidding force-push and deletion preserves the audit trail

**Negative:**
- A solo author can land changes without review; mitigated by the small number of
  contributors today

**Tightening plan:** after this PR lands and CI is green, add the 5 named checks
(yamllint, shellcheck, schema-validate, markdown-structure, yq-smoke) as required, and
raise approval count to 1 once a second engineer is on the repo.

---

## D-006 (2026-05-13) — Integration model: orchestrator hooks vs wrapper skill

**Status:** Accepted
**Date:** 2026-05-13
**Decider:** GDI-677 (Stage 3 Design)

> Note: The companion ADD originally specified this entry as D-004, but D-001..D-005
> were already taken when D-019 seeded the decisions log. Renumbered to D-006 to
> preserve append-only ordering. Cross-references in the ADR/ADD now resolve here.

### Context

GDI-669 shipped `scripts/reserve.sh`, `scripts/release.sh`, `scripts/conflict-check.sh`
as a Day-1 file-based state machine. The integration question for GDI-677: how should
`/sdlc` consume these scripts so parallel sessions get coordination automatically?

### Options considered

1. **Extend `/sdlc` itself** with Phase 0.6 + Stage 10 hooks (chosen).
2. **Create a `/sdlc-coordinated` wrapper skill** that calls `/sdlc` internally
   (rejected).
3. **Pre-commit git hook in the target repo** (rejected — bypassable with
   `--no-verify`, wrong timing).

### Decision

Extend `/sdlc` directly. The new Phase 0.6 phase + Stage 10 sub-step are the
orchestrator hooks. Opt-in via `profile.coordination.enabled` (default false →
zero behavior change). Ad-hoc force-on via `--coordinate` flag.

### Rationale

- **Single source of truth.** One `SKILL.md`, one canonical orchestration flow.
- **Propagation via existing `./install.sh`.** No new install path; updates to
  the skill ride the same well-trodden mechanism.
- **Profile-driven opt-in scales to new products.** Adding `coordination:` to a
  product's profile is the activation gesture; no changes to the skill required.
- **Preserves all existing /sdlc behavior.** Products without `coordination:` see
  no change.

### Rejected alternatives

- **Wrapper skill.** Two skills to maintain. Propagation drift inevitable. Harder
  to make opt-in because the wrapper would need its own profile-detection logic.
- **Pre-commit hook.** Wrong timing — fires at commit, not at dispatch. Bypassable
  with `--no-verify`. Doesn't catch reservations needed BEFORE writing code.

### Consequences

**Positive:**
- Parallel sessions get coordination for free once their product's profile opts in.
- Stage 10 release.sh closes the loop without any operator action.
- Manual mode (running the scripts by hand) remains the same — fallback path is
  unchanged.

**Negative:**
- `SKILL.md` grows by ~120 lines. Mitigated by the new section being clearly
  scoped to Phase 0.6 and Stage 10 (no scattered changes).
- Per-product opt-in means profiles must individually enable the feature. The
  first product (UGC Platform) opts in via the GDI-677 PR; others follow per
  their own schedule.

### References

- ADR-GDI-677: https://syndigo.atlassian.net/wiki/spaces/ARCH/pages/4581097480
- ADD-GDI-677: https://syndigo.atlassian.net/wiki/spaces/ARCH/pages/4580868116
- Sibling: GDI-669 (Day-1 file-based coordination service)

---

## Pending — D-007 through D-012 (input from GDI-708 run, 2026-05-13)

The parallel-run experience of `/sdlc --profile ugc-platform GDI-708` (Section B FR-B.1.9
shipped against the live registry) surfaced six concrete gaps in the Day-1 design.
Full write-up is in `docs/lessons-from-GDI-708.md`. Summary of proposed ADRs:

- **D-007** — `conflict-check.sh --verify-against <ref>` for the Flyway resource family,
  closing the gap where an agent fabricated a precondition (`V24__review_summaries.sql`
  that didn't exist) and the registry trusted the claim.
- **D-008** — Worktree-aware reservation. Same workstation + multiple `/sdlc` tabs +
  one shared clone = filesystem-level stomping the registry cannot see. Prescribe
  per-tab `git worktree add`; add `worktree:` field to reservations.
- **D-009** — Optional `--quality-gate-evidence` on `release.sh --status shipped`.
  CI green is not the same as local green — observed CI/local divergence on
  GDI-708 PR #110 (Mockk + Kotlin sealed-when behavior diff or stale Gradle cache).
- **D-010** — Flyway-sequence-gap warnings in `status.sh`. GDI-708 swap left V24
  empty between V20 (Section A reserved) and V25 (Section B reserved).
- **D-011** — `release.sh --resource anchor-consumer --consumer-verified=<symbol>`.
  Refuse to mark an anchor consumer as `shipped` if the named code-symbol isn't
  grep-able from the release-tag SHA. Observed: GDI-714 implementation skipped the
  FR-A.1.9 anchor call entirely while the registry would have happily marked it as
  consumed.
- **D-012** — `--ignore-self <epic>` on `conflict-check.sh` so an orchestrator can
  ask "would I conflict with anyone other than myself?"

Each will become its own ADR once an operator has time to draft and commit them.
This pending block exists so future readers find the lessons file from the canonical
ADR log.

### References

- `docs/lessons-from-GDI-708.md` — full diagnostic write-up with severity + effort
- GDI-708 epic: https://syndigo.atlassian.net/browse/GDI-708
- GDI-708 child stories: GDI-710..GDI-716

---

## D-013 (2026-05-13) — `release.sh` rejects `--status=released` for flyway and model-registry

**Status:** Accepted
**Date:** 2026-05-13
**Decider:** Repo maintainer (CI-failure remediation)

### Context

CI on `main` failed repeatedly with `schema-validate` errors of the form:

```
instancePath: '/flyway/shipped/19/release_tag',
message: 'must match pattern "^(v\d+\.\d+\.\d+(-[a-zA-Z0-9-]+)?|v\d+\.\d+\.x|pre-aidlc)$"'
```

Root cause: `scripts/release.sh` required `--release-tag` only when
`--status=shipped`, but unconditionally wrote `release_tag: "$RELEASE_TAG"`
into the appended row regardless of resource. Calls of the form
`release.sh --resource flyway --status released` (and the model-registry
equivalent) therefore produced rows with `release_tag: ""`, which the
`semverTag` definition in `schemas/allocation.yml.schema.json` rejects.

Four such rows landed on `main` before the failure was investigated:
flyway V20/V24/V25 and model_registry `review-summary-locale`.

### Decision

1. `release.sh` rejects `--status=released` when `--resource` is `flyway`
   or `model-registry`. Those resources must use `--status=shipped` with
   a real `--release-tag`.
2. `--status=released` remains valid for `file-lock` (clears `held_by`)
   and `release-tag` (sets `current_main`) — those code paths never
   write a `release_tag` field, so they are unaffected.
3. The four bad rows on `main` were fixed by deleting the
   `release_tag: ""` line (the field is optional on `shippedFlyway`
   and `shippedModelSurface`). Tags can be backfilled later once the
   real release is cut.

### Rationale

- Schema rejection is the load-bearing invariant — preserving it at the
  script boundary is cheaper than fixing every downstream consumer that
  might trust the YAML.
- Tightening the script (rather than loosening the schema) keeps the
  audit trail honest: a `shipped` row without a tag is a meaningful
  signal that the row is provisional.
- `--status=released` is preserved for the two resources where it has
  legitimate semantics, so the playbook's existing file-lock release
  example continues to work.

### Consequences

- Operators who previously ran `release.sh --resource flyway --status released`
  by habit will now get a clear error pointing them at
  `--status=shipped --release-tag vX.Y.Z`.
- The four V20/V24/V25 and review-summary-locale rows currently have no
  `release_tag`. When those migrations are tied to a real release, an
  operator must backfill the field manually (or via a follow-up script).

### References

- Failing CI runs on `main` 2026-05-13 (search "schema-validate")
- `scripts/release.sh` guards added under `--status` validation
- `docs/parallel-session-playbook.md` § "Step 1.3 — Ship + release" caution block

---

## D-014 (2026-05-13) — Coordination race-condition fixes from GDI-770 retrospective

### Context

The GDI-770 SDLC run (Section D / FR-D.2 multi-source answers, parallel
with Sections A/B/C/D) surfaced four classes of coordination gap that the
Day-1 scripts didn't catch:

1. **Release-tag race.** Two tabs reach Stage 9 with the same
   `vX.Y.Z` because `releases.next_per_section` is documentary, not
   enforced. GDI-708 took `v0.31.0` while GDI-709 was assigned `v0.31.x`;
   GDI-709 had to shift to `v0.32.x` mid-flight via a registry edit.
2. **Flyway version race during Stage 4.** Section A's GDI-742 grabbed
   V29 mid-Stage-4 of GDI-770; then Section C's GDI-C-1-6 grabbed V30
   while GDI-770 already held V30 on disk. The reservation registry
   doesn't poll for on-disk drift, so the operator only discovers the
   collision when CI applies the migration.
3. **No clean exit for stale reservations.** When a sibling tab wins
   the race for a version, the loser has no clean way to surrender the
   reservation — `release.sh --status=released` is rejected for flyway
   (per D-013), and the only alternative is to let the 24-hour TTL
   expire silently.
4. **`git pull --rebase` failure on unstaged changes.** Operators with
   any working-tree modifications saw "cannot pull with rebase: You have
   unstaged changes" inside every `reserve.sh`/`release.sh` call. The
   rebase actually would have applied cleanly, but the error was loud
   and confusing.

Also surfaced: `next_free` in the YAML is stale (only updated lazily by
the most recent reserve call), and `reserve.sh` has no signal when a
sibling tab has ALREADY written a V<id> migration to disk.

### Decision

1. **`conflict-check.sh` gains `--release-tags <csv>`.** Iterates the
   list, WAIT-blocks if any tag appears as `.releases.in_flight[].proposed_tag`
   held by a different section OR as a `.flyway.shipped[].release_tag`
   already-shipped by a different epic. Chain-callable via `--claim`.
   The `/sdlc` Stage 9 protocol must call this BEFORE `gh release create`.

2. **`scripts/audit-flyway.sh` (new).** Read-only auditor that scans a
   product repo's Flyway migration directory and reconciles against the
   registry. Emits one row per Vxx in either source with a status of
   `OK`, `DRIFT-disk-only`, `DRIFT-registry-only`, or
   `DRIFT-owner-mismatch?`. Exit 1 if any drift detected. Intended for
   Stage 4 pre-flight and ad-hoc operator use.

3. **`release.sh` gains `--status=abandoned --reason "<text>"`** for
   `flyway` and `model-registry` resources. Removes the reserved row
   without a shipped append. The `--reason` is required and carried
   in the git commit message body for audit. This is the clean exit
   for stale reservations.

4. **`_lib.sh:git_pull_rebase()` auto-stashes** before the rebase and
   `git stash pop`s after. If the stash pop conflicts (rare for the
   small allocation-YAML edits this repo carries), the stash is left in
   place with a recovery message.

5. **`status.sh` lazy-computes `next_free`** from
   `max(shipped|reserved version) + 1`, filtered to the production range
   (V1-V899). The YAML's static `.flyway.next_free` field is still
   shown as `[yaml-declared: VXX — drift]` when it disagrees with the
   computed value.

6. **`reserve.sh` gains `--product-repo-path <path>`** (optional). When
   reserving a Flyway version, scans the product repo for an existing
   `V<id>__*.sql` outside common build-output directories. If found,
   emits a loud WARN but proceeds — the operator may legitimately be
   reserving a version a sibling tab abandoned.

No schema changes — all behavior changes live in the scripts. D-013's
constraint (flyway/model-registry use `--status=shipped` with a real
release_tag) is preserved; abandoned is a new third path for the
explicit "this reservation will never ship" case.

### Consequences

- `/sdlc` Stage 9 dispatch protocol gains an explicit
  `conflict-check.sh --release-tags <vX.Y.Z>` call. Until that's wired,
  operators run the check manually before `gh release create`.
- `scripts/audit-flyway.sh` becomes part of the Stage 4 dispatch
  toolkit. The dispatch agent reads the audit output as a
  precondition signal before writing any migration file.
- The `next_free` value in the YAML becomes documentary only; the
  authoritative answer comes from `status.sh`. A subsequent ADR may
  remove the static field entirely, but that's a schema change and is
  deferred.
- Operators who saw spurious `git pull --rebase failed` warnings
  during normal reserve/release calls will no longer see them.
- `--status=abandoned` is NOT permitted for `file-lock` or
  `release-tag` — those continue to use `--status=released`. The error
  message disambiguates.

### References

- `scripts/audit-flyway.sh` (new)
- `scripts/conflict-check.sh` (`--release-tags` block + chain-call)
- `scripts/release.sh` (`--status=abandoned` path)
- `scripts/reserve.sh` (`--product-repo-path` warning)
- `scripts/_lib.sh:git_pull_rebase` (stash wrap)
- `scripts/status.sh` (lazy next_free)
- `docs/parallel-session-playbook.md` § Step 1.4 (Stage 9 release-tag pre-flight)
- Source incidents: GDI-708 (v0.31.0 first race), GDI-709 (shift to v0.32.x),
  GDI-770 (V29 + V30 + V31 cascade)
- Lessons doc: `docs/lessons-from-GDI-708.md`

---

## D-015 (2026-05-14) — `release.sh --all-for-epic` orphan-reservation sweep

**Status:** Accepted
**Date:** 2026-05-14
**Decider:** GDI-798

### Context

`scripts/release.sh` only releases the single resource identified by
`--resource`/`--id`. When an epic's SDLC run reaches Stage 10, the
orchestrator's release hook releases ONLY the canonical resource the ticket
named at intake. Older-version reservations the epic accumulated mid-flight
— e.g. an early Flyway version reserved before the schema was refactored,
a test-fixture version paired with the production version, or a model-
registry surface that was renamed during development — remain in the
registry under the same epic key. They become orphans: never going to ship,
never going to be released, only TTL-expire silently 24-48h later.

Live confirmation: GDI-800 shipped V32 + V932 + cleared its file-locks
at Stage 10 (2026-05-14T02:11Z), but V22 (`epic: GDI-800`, FR-A.1.7,
onboarding-schema-mapping) and V923 (test-fixture pair) were left
`status: reserved` under GDI-800. Operators had to grep the registry and
craft individual `release.sh --status=abandoned` calls per orphan.

### Decision

Add a sweep mode to `release.sh`:

```sh
release.sh --all-for-epic <KEY> [--reason "<text>"] [--dry-run] [--json]
```

The mode is mutually exclusive with `--resource`/`--id`/`--status`. It
walks the registry and releases every reservation matching the epic:

- `flyway.reserved`            -> dropped (abandoned semantics)
- `flyway.test_fixture_range.reserved` -> dropped
- `model_registry.pending`     -> dropped
- `single_writer_files` where `held_by == KEY` -> `held_by: none`
- `releases.in_flight`         -> dropped

All edits land in a single `yq` pass and a single commit. The commit
message body carries the list of resources swept (for audit). `--reason`
is optional with a sensible default; `--dry-run` previews the sweep
without editing. Idempotent: zero matches exits 0 with a no-op log.

### Rationale

- **One sweep, one commit.** Mirrors the existing per-resource code path
  (single yq edit + commit + push) so the audit trail stays linear.
- **Same allowed scope as existing flags.** No new schema fields; no new
  resource categories. The sweep operates entirely on data the script
  already knows how to release.
- **Abandoned semantics for flyway/model-registry.** Per D-013 and D-014,
  these resources can't be `released` without a real release_tag, so we
  use the `abandoned`-style "drop the reserved row" path. No `shipped`
  appends — orphans by definition will never ship under this epic.
- **Idempotent.** Re-runnable as part of a Stage 10 hook, a manual cleanup,
  or a periodic sweep script without side effects.

### Rejected alternatives

- **Auto-sweep at the end of every `release.sh --status=shipped` call.**
  Too magical — operators expect `release.sh` to touch only what they
  named. The sweep is opt-in via a distinct flag.
- **A separate `sweep.sh` script.** Would duplicate the YAML-edit
  scaffolding (require_tools, resolve_yml_path, git_pull_rebase,
  git_commit_and_push). Keeping the sweep inside `release.sh` reuses
  every helper.
- **Walk by section instead of epic.** A section can hold reservations
  for many concurrent epics; sweeping by section would over-clean. Epic
  is the unit of work that ships, so epic is the unit of sweep.

### Consequences

**Positive:**
- Stage 10 hooks (or operators) can `release.sh --all-for-epic <KEY>`
  immediately after the canonical release and the registry is clean.
- The retroactive cleanup of GDI-800's V22/V923 orphans is one command,
  not three hand-crafted `--status=abandoned` calls.
- The `status.sh` view of "active reservations" stops surfacing
  reservations whose epic has already shipped.

**Negative:**
- Operators must remember to use `--all-for-epic` for the post-ship
  sweep. Surfaced in the playbook under § "Step 1.5 — Ship + release".
- If an operator runs `--all-for-epic` mid-flight (BEFORE the canonical
  resource has shipped), they will drop their own in-flight reservations.
  Mitigated by `--dry-run` showing the plan first.

### Follow-ups

- Wire `--all-for-epic` into the `/sdlc` orchestrator's Stage 10 hook so
  every Stage 10 close sweeps orphans automatically (without operator
  intervention). Until then, operators run the sweep manually.

### References

- `scripts/release.sh` (sweep block: `if [ -n "$ALL_FOR_EPIC" ]; then ... fi`)
- `docs/parallel-session-playbook.md` § "Step 1.5 — Ship + release"
- Source incident: GDI-800 (V32/V932 shipped, V22/V923 orphaned)
- Sibling ADRs: D-013 (flyway --status=released ban),
  D-014 (--status=abandoned for stale reservations)

---

## D-016 (2026-05-13) — Three-tier orchestration: Pillar + Portfolio above Section Owner

### Status

Accepted. Substantive (not deferred).

### Context

The Day-1 substrate has one persona for the work-doing role (Section Owner) and one
for tag-cutting (Release Coordinator). On UGC Platform that worked while ≤2 sections
were in flight. As the gameplan opened up to 10 pillars (A–J) and the FR backlog grew
past 50, the human operator (Nate) became the de-facto pillar and portfolio scheduler.
That work doesn't scale and isn't repeatable across products.

The gap audit identified eleven missing concepts: intra-pillar serial chains,
single-writer file holder caps, ship-window throttling, cross-pillar critical-path
selection, successor-epic chaining, lock contention forecasting, parallelism caps,
quality-gate evidence (GDI-708 retro), per-pillar status tracking, blocked_on
surfacing, and stats computation. None of these belonged at the Section-Owner tier;
all of them benefit from being above the Section Owner but below a single
human-or-Claude that owns the whole product.

### Decision

Introduce two new tiers as personas + scripts on top of the existing substrate:

- **Tier 2: Pillar Orchestrator** — one per pillar. Owns the pillar's FR backlog,
  intra-pillar serialization, and per-pillar parallelism cap. Spawns Section Owners.
- **Tier 3: Portfolio Orchestrator** — one per product. Owns cross-pillar scheduling,
  the critical path, and the portfolio-wide parallelism cap. Spawns Pillar Orchestrators.

The allocation YAML grows by an optional `pillars[]` block (live state) and an optional
`stats:` block (computed). Existing Day-1 fields are unchanged. Products that don't
adopt the tiers omit both blocks and the schema still validates — the substrate stays
backward-compatible.

The `single_writer_files[]` schema gains optional `max_concurrent_holders` and
`holders[]` to support files where parallel append is genuinely conflict-free.
`anchorConsumer` gains optional `intra_pillar` and `verified_in_release` so D-011
(consumer-symbol verification) and intra-vs-cross-pillar distinctions stay encoded.

Two new read-only scripts: `pillar-status.sh <letter>` (single pillar dashboard) and
`portfolio-status.sh` (cross-pillar dashboard, with `--update-stats` to write the
computed `stats:` block). The existing `status.sh` remains the granular dump.

`reserve.sh` gains three new pillar-tier guards (intra-pillar serial chain,
file-lock holder cap, ship-window `serial_with`). All three short-circuit-allow
when no `pillars[]` block exists, so existing flows are unchanged. A new
`--bypass-pillar-checks` flag exists as an emergency override.

### Alternatives considered

- **Flat (one mega-orchestrator).** Rejected — one Claude session can't hold 10
  pillars × N FRs of state in working context. The portfolio decisions get lossy.
- **Per-FR autonomy (no pillar layer).** Rejected — works only because Nate is the
  human pillar layer today. Removing him drops intra-pillar coherence.
- **Add pillar concept inline to existing personas.** Rejected — would muddy the
  Section Owner contract (which the orchestrator integration in `/sdlc` relies on).

### Consequences

- New: `personas/pillar-orchestrator.md`, `personas/portfolio-orchestrator.md`,
  `scripts/pillar-status.sh`, `scripts/portfolio-status.sh`,
  `docs/orchestration-tiers.md`.
- Schema additions are optional → zero breakage for non-pillar products.
- `reserve.sh` enforcement is opt-in (only fires when `pillars[]` is present).
- Day-1 cap on `max_concurrent_pillars_in_flight` for UGC = 4 (encoded in the profile).
  This is an estimate; revisit after a week of operation.
- Coupling: `release.sh` does NOT yet promote to `pillars[<letter>].shipped_frs`.
  Today the Pillar Orchestrator updates the pillar block by hand. Wire that into
  `release.sh` in a follow-up ADR.

### Follow-ups

- Wire `release.sh` to update `pillars[<letter>].shipped_frs` and remove from
  `in_flight_frs` automatically on `--status=shipped`.
- Add `bootstrap-from-profile.sh` so a fresh product can generate a Day-1 allocation
  YAML from its profile.
- Promote the orchestrator personas to slash commands (`/pillar`, `/portfolio`) once
  the manual flow proves stable.
- Add CI validation for `profiles/*.yml` against `schemas/profile.yml.schema.json`.
- Add CI checks for the new persona files in `markdown-structure`.

### References

- `personas/pillar-orchestrator.md`, `personas/portfolio-orchestrator.md`
- `scripts/pillar-status.sh`, `scripts/portfolio-status.sh`
- `scripts/reserve.sh` (new `pillar_constraints_check()`)
- `schemas/allocation.yml.schema.json` (new `pillar`, `pillarSerialChain` defs)
- `docs/orchestration-tiers.md`

---

## D-017 (2026-05-13) — Per-product profile YAML separates product shape from live state

### Status

Accepted. Companion to D-016.

### Context

The Day-1 scripts hardcoded UGC Platform paths in several places: `audit-flyway.sh`
assumes `services/ugc-api/src/main/resources/db/migration`, `single_writer_files[]`
hardcodes `ai/governance/ModelRegistry.kt`, the section-letter loop assumes A–J. To
reuse this substrate for a non-UGC product, those paths must be parameterized.

We could put product-shape fields directly on the allocation YAML, but allocations
churn (every reserve and release writes), and product shape is immutable. Mixing the
two means every shape change goes through a coordination commit, and every coordination
commit risks corrupting the shape.

### Decision

Add a sibling YAML at `profiles/<product>.yml` carrying product shape:

- `migration.dir_pattern`, `filename_pattern`, `version_prefix`, `test_fixture_threshold`
- `ai_surface_files[]` — the load-bearing single-writer file paths
- `section_range.letters[]` — which letters this product uses
- `release_unit.{name, tag_format}` — what the product calls its release granularity
- `pillars[]` — static pillar definitions (letter, name, scope, FR prefix, defaults)
- `orchestration.{default_pillar_persona, default_portfolio_persona, max_concurrent_pillars_in_flight}`

The allocation YAML carries a `profile_ref:` field (relative path from repo root)
pointing at its profile. Scripts that need product shape (`portfolio-status.sh`
already reads `max_concurrent_pillars_in_flight`; future `audit-flyway.sh` will read
`migration.dir_pattern`) follow the ref.

Validated by a separate schema at `schemas/profile.yml.schema.json` so allocation
schema validation is unaffected.

### Alternatives considered

- **Inline shape on allocation YAML.** Rejected — couples shape to live state.
- **One profile shared across all products.** Rejected — defeats the purpose of
  per-product parameterization.
- **Per-product script forks.** Rejected — defeats the substrate-reuse goal.

### Consequences

- New: `schemas/profile.yml.schema.json`, `profiles/ugc-platform.yml`.
- Schema relaxation: `sectionLetter` was `^[A-J]$`, now `^[A-Z]$` (the per-product
  subset is pinned in `product.sections` and in the profile's `section_range.letters`).
  No existing UGC data is invalidated; new products with letters K–Z now validate.
- The `profile_ref` field on allocations is optional. Existing allocations without
  one continue to work — scripts fall back to their current hardcoded behavior.
- CI must validate `profiles/*.yml` against the new schema (follow-up).

### Follow-ups

- Add CI validation for `profiles/*.yml`.
- Update `audit-flyway.sh` to read `migration.dir_pattern` from the profile when
  `profile_ref` is present; fall back to UGC default otherwise.
- Document profile authoring in a new `docs/onboarding-a-new-product.md`.

### References

- `schemas/profile.yml.schema.json`
- `profiles/ugc-platform.yml`
- `scripts/portfolio-status.sh` (first script to read `profile_ref`)
- `docs/orchestration-tiers.md` § "Per-product reuse: the profile layer"

---

## D-018 (2026-05-14) — `git_commit_and_push` stages only the touched file

### Status

Accepted. Day-2 P1.1 fix.

### Context

`git_commit_and_push()` in `_lib.sh` did `git add allocations/`, which staged
every YAML in the directory. During Day-2 P0 development I created
`allocations/ugc-test.yml` as a sandbox copy of the live registry to dry-run
the new `--update-pillars-block` hooks without pushing to main. The script
ran with `--product ugc-test` correctly, but `git_commit_and_push` then
staged BOTH `ugc-test.yml` AND `ugc-platform.yml` and pushed the bundle as
one commit (`b4eff31`). Reverted in `35bb8ac`. The live UGC YAML wasn't
mutated because of `--product` scoping, but the foot-gun is real: any
operator with a sandbox file in `allocations/` would publish it.

### Decision

Add an explicit second arg to `git_commit_and_push()` for the file path to
stage. All four call sites (reserve.sh, release.sh per-resource +
`--all-for-epic`, portfolio-status.sh `--update-stats`) updated to pass
`$YML`. Default of `allocations/` retained for any unforeseen caller, so
the change is backward-compatible.

### Consequences

- Sandbox YAMLs in `allocations/` no longer leak into commits.
- Future scripts that mutate the registry MUST pass the file path
  explicitly; the prefix-match-staging behavior is now opt-in, not default.

### References

- `scripts/_lib.sh#git_commit_and_push`
- Callers: `scripts/reserve.sh`, `scripts/release.sh`, `scripts/portfolio-status.sh`
- Source incident: commit `b4eff31` (reverted in `35bb8ac`).

---

## D-019 (2026-05-14) — `git_pull_rebase` surfaces stash-pop failures with recovery commands

### Status

Accepted. Day-2 P1.2 fix.

### Context

`git_pull_rebase()` swallowed `git stash pop` failures with
`2>/dev/null || log_warn "stash pop conflicted; recover with: git stash list"`.
The warning fired during a sibling reserve.sh invocation in this session
and was missed; only the stash entry on the stack saved the untracked work
(in this session: the orchestrator personas, status scripts, profile
files, and tiers doc — all uncommitted at the time, all on the verge of
being lost).

### Decision

Three changes to `git_pull_rebase()`:

1. Capture the stash SHA via `git rev-parse 'stash@{0}'` immediately
   after `stash push`, so the recovery command names a durable identity
   even if sibling tabs push additional stashes between push and pop.
2. On stash pop failure, `log_err` (not `log_warn`) with the captured
   SHA, the stash count, AND three recovery commands (`stash list`,
   `stash apply <sha>`, `stash show -p <sha>`) plus the cleanup
   `stash drop <sha>` for after recovery.
3. Return non-zero so the calling script can decide to abort the
   operation instead of blindly continuing on a half-merged tree.

### Consequences

- A pop conflict is now loud, named, and recoverable. Sessions that
  discover stash pop failed can choose to abort (re-run later) or
  recover (`stash apply` + manual conflict resolution).
- The subshell wrapper was removed; shell flow is explicit. No
  behavior change for callers, but easier to read.

### References

- `scripts/_lib.sh#git_pull_rebase`
- Source incident: this session's near-loss of untracked Day-1 work
  (Phase 0 of `reports/contention-audit-2026-05-14.md`).

---

## D-020 (2026-05-14) — `release.sh --sweep-expired` drops TTL-expired reservations

### Status

Accepted. Day-2 P1.3.

### Context

Reservations carry `expires_at` fields, but nothing read them or acted on
them. The pillar-orchestrator persona docs referenced a "TTL-expired
sweep" that had no script behind it. Audit finding 6 in
`reports/contention-audit-2026-05-14.md` flagged V21 and V23 (Section A)
as expiring soon with no cleanup path.

### Decision

`release.sh --sweep-expired` finds every reservation in the registry
whose `expires_at` is in the past (string comparison against `iso_now` —
ISO-8601 timestamps sort lexicographically) and drops them in a single
yq pass:

- `flyway.reserved` → dropped
- `flyway.test_fixture_range.reserved` → dropped
- `model_registry.pending` → dropped

Does NOT touch `single_writer_files` (their `.until` field is cleared by
the file's next reservation, not on a wall-clock sweep — changing that
contract would alter behavior for everything that reads `held_by`/`until`).

Does NOT touch `releases.in_flight` (those are now pruned by the D-016
P0 hooks at ship time).

Mutually exclusive with `--resource` and `--all-for-epic`. Idempotent:
zero expired entries exits 0.

### Consequences

- Orchestrator personas can call `--sweep-expired` at the top of every
  tick to cull stale reservations across the whole product.
- The portfolio-orchestrator persona doc was updated to make this the
  first step of every tick.

### References

- `scripts/release.sh#sweep_expired`
- `personas/portfolio-orchestrator.md#decision-loop` step 1.

---

## D-021 (2026-05-14) — Orchestrator scripts warn when not in a worktree

### Status

Accepted. Day-2 P1.4. Codifies the recommendation from GDI-728 / D-008.

### Context

The orchestrator personas spawn many sibling reserve.sh / release.sh
calls. If the orchestrator runs in the shared main clone, every one of
those calls runs `git_pull_rebase` in the same working tree and the
operator's other tabs get stomped. This session itself almost lost
untracked files via that path (D-019 covers the immediate fix; D-021
addresses the systemic behavior).

### Decision

Two new helpers in `_lib.sh`:

- `warn_if_not_worktree <caller>` — soft warn for read-only paths
  (status scripts). Emits a one-line WARN telling the operator about
  the worktree contract; never blocks. Always returns 0.
- `require_worktree_strict <caller>` — hard refuse for write paths.
  Returns 1 if not in a worktree. Bypassable via `ALLOW_NON_WORKTREE=1`
  in the caller's environment.

Detection: a regular clone has `$REPO_ROOT/.git` as a directory; a
worktree has it as a file pointing back at the main clone's `worktrees/`
dir.

Wired today into `pillar-status.sh` and `portfolio-status.sh` (soft
warn). The strict guard is available for any future write-path
orchestrator script. Persona docs updated to make Phase 0 (worktree
setup) explicit at the top of each decision loop.

### Consequences

- Operators get a one-line WARN reminding them of the contract; they
  can ignore it for ad-hoc reads.
- Future orchestrator scripts that mutate the registry can call
  `require_worktree_strict` to refuse hard.
- No behavior change for `reserve.sh` / `release.sh` (Section Owners
  legitimately use those from the main clone).

### References

- `scripts/_lib.sh#warn_if_not_worktree`, `#require_worktree_strict`
- `scripts/pillar-status.sh`, `scripts/portfolio-status.sh`
- `personas/pillar-orchestrator.md#decision-loop` Phase 0
- `personas/portfolio-orchestrator.md#decision-loop` Phase 0
- Sibling: D-008 / GDI-728 (worktree-per-epic convention).

---

## D-022 (2026-05-14) — `bootstrap-from-profile.sh` for new products

### Status

Accepted. Day-2 P1.5 follow-up to D-016/D-017.

### Context

D-017 introduced `profiles/<product>.yml` carrying immutable product
shape. New products still required hand-authoring an
`allocations/<product>.yml` to match. Tedious and error-prone — the
allocation YAML has 8+ required top-level blocks plus per-pillar entries.

### Decision

`scripts/bootstrap-from-profile.sh --product <name>` reads
`profiles/<name>.yml` and generates a Day-1
`allocations/<name>.yml` with:

- `product.{name, repo, sections}` from profile
- empty `flyway` / `model_registry` / `releases.in_flight` blocks
- `releases.next_per_section` seeded as `v0.1.x` for every letter
- `single_writer_files` seeded from `profile.ai_surface_files` (or a
  `docs/decisions.md` placeholder if the profile has no AI surfaces,
  since the schema requires at least one entry)
- `pillars[]` seeded from `profile.pillars[]` with `status:not_started`,
  empty FR lists, and per-pillar caps from profile defaults
- `profile_ref` pointing back at the profile

Refuses to overwrite an existing allocation unless `--force`. `--dry-run`
prints the generated YAML to stdout without writing.

### Consequences

- Onboarding a new product is now: (1) author profile, (2) bootstrap,
  (3) commit. Three steps instead of "copy ugc-platform.yml and edit by
  hand."
- Generated allocations validate against the schema immediately, so
  the operator can run `reserve.sh` against the new product right away.
- `--force` is dangerous — destroys live coordination state. Documented
  in `--help` and the commit message.

### References

- `scripts/bootstrap-from-profile.sh`
- `schemas/profile.yml.schema.json`
- `schemas/allocation.yml.schema.json`

---

## D-023 (2026-05-14) — Pillar parallelism cap raised from 4 to 8 based on observed throughput

### Status

Accepted. Revises a Day-1 estimate based on 24h of real usage.

### Context

`profiles/ugc-platform.yml#orchestration.max_concurrent_pillars_in_flight`
was set to 4 on Day-1 (D-016). The number was a guess: I had no
throughput data and no usage data, and I picked 4 as a conservative
ceiling assuming the load-bearing AI surface locks
(`ModelRegistry.kt` / `Prompts.kt` / `ModelRegistryTest.kt`) would be
the bottleneck.

24 hours of real usage data:

- **16 flyway ships across 5 distinct pillars** (A, B, C, D, F) in the
  last 24 hours. ~one ship per 90 minutes sustained.
- **Only 2 of those 16 ships needed an AI surface** (model_registry
  shipped 2 entries: B's email-template-gen, C's review-summary-locale).
  ~12.5% of work hits the load-bearing locks.
- The substrate handled 5 in_flight pillars concurrently without falling
  over. The contention I documented in
  `reports/contention-audit-2026-05-14.md` was about state staleness
  (`shipped_frs` not updating, `releases.in_flight` not pruning),
  not lock contention.

The Day-1 "4 cap because of AI lock" rationale was wrong: the AI lock
is a *per-file* constraint, not a *per-pillar* constraint. The tighter,
more accurate constraint is
`single_writer_files[].max_concurrent_holders=1` on the AI surfaces,
which is already in the schema and enforced.

### Decision

Raise `max_concurrent_pillars_in_flight` from 4 to 8.

### Alternatives considered

- **Hold at 4 + observe one more day.** Rejected — we have enough data
  to act, and the Phase 3 audit already proved the substrate handles
  5+ pillars cleanly. Holding the lower cap costs throughput.
- **Raise to 10 (one per UGC pillar).** Rejected — `git_pull_rebase`
  contention scales linearly with pillar count, and at ~32 calls per
  FR cycle × 10 pillars = 320 calls, the rebase storm would become the
  bottleneck. 8 is the empirical sweet spot.
- **Remove the cap entirely.** Rejected — without a ceiling, a runaway
  orchestrator could spin up FRs faster than the human portfolio
  layer can review.

### Consequences

- The portfolio orchestrator can now run up to 8 pillars concurrently
  before the cap warning fires.
- AI lock pressure increases: with 8 pillars, the probability that
  2+ want the AI lock concurrently at any given moment is ~50%+, so
  more queuing on `ModelRegistry.kt`. This is acceptable — the lock
  works correctly; queuing is the intended behavior.
- If rebase contention becomes a real bottleneck (likely around 12+
  pillars), revisit by either: (a) batching reserves, (b) moving to
  a longer-lived HTTP service (revisits D-001), or (c) sharding the
  registry per-pillar (revisits D-002).

### Follow-ups

- After another week of usage, retro this number against actual
  observed parallelism. If we never hit 6+ in flight, dial back. If
  we routinely hit 8 and queue on the AI lock, consider a Pillar-A-only
  carve-out or batching reserves.

### References

- `profiles/ugc-platform.yml#orchestration.max_concurrent_pillars_in_flight`
- `reports/contention-audit-2026-05-14.md` Phase 3 dashboard.
- Sibling: D-016 (Day-1 estimate this revises).

---

## D-024 (2026-05-14) — `audit-registry-drift.sh` — recurring registry-vs-reality check

### Status

Accepted. Closes the structural gap that produced the Phase 4 audit.

### Context

The Phase 3 reconciliation (commit `ce5b276`) compared the registry against
itself — pillars vs `flyway.reserved.fr`. That caught the speculative
`in_flight_frs` seeds I'd left over from Day-1, but it was a closed loop:
the registry can be internally consistent and still wildly out of sync
with the actual product repo.

The Phase 4 audit (one-off subagent run) compared the registry against
GitHub releases and migrations on disk and found:

- 5 GitHub releases not in `flyway.shipped[].release_tag` (v0.21.0,
  v0.21.1, v0.22.0, v0.25.0, v0.36.1). A second pass via the new
  drift script found 5 MORE (v0.17.0, v0.18.0, v0.18.1, v0.20.0,
  v0.20.1) — the audit's `gh release list --limit 20` truncated.
- Migrations on disk that the registry didn't know about (V36, V38,
  V39, V41 — all merged to dev but not yet tagged).
- An anchor (FR-F.1.5.1) marked `not_started` in `anchor_dependencies`
  even though it had shipped at v0.42.0 hours earlier.
- A renumbered Flyway version (V21 → V29 by GDI-786) that the registry
  recorded as "still reserved" because nobody updated it after the
  rename.

The drift was a process failure, not a substrate failure: nothing was
catching it because nothing was looking. After Phase 3 wrapped, my
"the registry is honest now" claim was technically true (against the
internal check) and substantively false (against external truth).

### Decision

Add `scripts/audit-registry-drift.sh` — a read-only script that
compares the registry against external truth on every invocation. Five
checks:

1. **Migrations on disk vs registry.** Walk the product repo's
   migration directory; flag any `V*__*.sql` not in `flyway.shipped`
   or `flyway.reserved`.
2. **Reserved entries that already shipped.** For each
   `flyway.reserved` entry, check if a matching migration file exists
   on disk; if so, the entry is stale.
3. **GitHub releases not in registry.** Pull the last N releases via
   `gh release list`; flag any tag not in `flyway.shipped[].release_tag`
   or noted in the `releases:` comment block.
4. **Anchor staleness vs GitHub releases.** For each unshipped anchor,
   scan recent release titles for the FR id; if found, flag as stale.
5. **Pillar `in_flight_frs` without backing reservation.** For each
   pillar's `in_flight_frs` entry, verify a matching `flyway.reserved`
   or `model_registry.pending` entry exists.

Read-only. Exit 0 if no drift; exit 1 if any finding. JSON mode for
machine consumption.

### Alternatives considered

- **Bake the checks into reserve.sh / release.sh.** Rejected — those
  are write paths and should stay focused. The drift check is
  orchestrator-tier read-only work.
- **Add to portfolio-status.sh.** Rejected — that script is the
  cheap "what's the state" view; the drift check is the more
  expensive "is the state honest" view. Different cadence
  (every-tick vs every-few-ticks).
- **Schedule via cron / GitHub Action.** Deferred. The orchestrator
  personas can call it on every tick today; CI integration is a
  Phase 5 follow-up.

### Consequences

- Orchestrator personas have a single command to call to verify
  registry honesty before making decisions.
- The 10 untracked GitHub releases (5 from Phase 4 audit, 5 newly
  discovered) are documented in the `releases:` comment block so
  the drift checker doesn't re-flag them.
- New "merged-to-dev = shipped" semantics emerge from this work:
  Pillars D, E, G's recent FR-D.5 / FR-E.1.1 / FR-G.1.1 work
  produced flyway migrations on dev without semver tags. These are
  now in `flyway.shipped` with `release_tag` omitted, and in
  `pillars[].shipped_frs`. The pillar status flips to `not_started`
  if no further work is in flight.
- The drift script's exit-code-1-on-finding makes it CI-friendly.
  Phase 5 work could add a `.github/workflows/drift-check.yml`
  that runs on every push and fails red if drift exists.

### Follow-ups

- Wire orchestrator persona docs to call `audit-registry-drift.sh`
  at the top of every tick alongside `release.sh --sweep-expired`.
- CI: add a workflow that runs the drift check on every push to
  `allocations/` and fails the PR if drift exists.
- The script currently hardcodes the migration directory fallback
  to `services/ugc-api/...`; remove the fallback and require the
  profile path once all in-flight products have profiles.
- Consider extending the script to check `model_registry.pending`
  vs git history (similar to flyway-on-disk).

### References

- `scripts/audit-registry-drift.sh`
- `reports/contention-audit-2026-05-14.md` Phase 4 cross-check.
- Sibling: D-017 (profile-driven paths the drift checker reads).

---

## D-025 (2026-05-14) — `bootstrap-pillar-prompt.sh` — render the first-message handoff for fresh pillar tabs

### Status

Accepted. Closes the "every new tab needs the same paragraphs of context"
toil that the Phase 4/5 work surfaced.

### Context

The orchestration tier model (D-016) lets a Portfolio Orchestrator spawn
a Pillar Orchestrator, which in turn spawns Section Owners. Each spawn
is a fresh Claude tab with no prior context. The user (acting as
Portfolio in practice) was hand-pasting the same 100+ line prompt for
every new pillar tab — required reading list, coordination substrate
intro, /sdlc dispatch instructions, the pillar's current state, what
sibling tabs are holding. By the time the prompt was pasted, the live
state ("which locks are held right now," "what just shipped") was 30
minutes stale.

The same prompt is renderable from registry data. Boilerplate writes
itself.

### Decision

Add `scripts/bootstrap-pillar-prompt.sh --product <name> --letter <X>`.
Reads:

- `allocations/<product>.yml` for `pillars[<letter>]` live state
  (backlog, in_flight_frs, shipped_frs count) plus `single_writer_files`
  active holds, last 5 `flyway.shipped` entries, and
  `anchor_dependencies` relevant to this pillar
- `profiles/<product>.yml` for `product.repo`, `pillars[].name/scope/fr_prefix`
- `profiles/<product>.bootstrap-template.md` for the prose template

Renders the rendered markdown to stdout. Pipe into a fresh Claude tab as
the first message before `/sdlc` is dispatched.

`--with-drift-check` flag (off by default; recommended when an
orchestrator persona is doing the spawn) runs `audit-registry-drift.sh`
(D-024) and embeds the result so the new tab knows whether the registry
is currently honest. Adds ~5s and 1+ gh API calls.

The strategic FR pick stays human (or stays with the spawning
orchestrator) — the renderer can list backlog but cannot replace
pillar-strategy reasoning. The template carries an
`<!-- ORCHESTRATOR NOTE: -->` comment marking that spot.

### Alternatives considered

- **Hardcode the prompt prose in the script.** Rejected — different
  products need different reading lists and conventions. Template per
  product is the right level.
- **Bake into the /sdlc skill.** Rejected — /sdlc is the FR-level
  pipeline, not the pillar-level entry. The pillar tab needs context
  before /sdlc is even dispatched.
- **Per-pillar static templates.** Rejected — pillar state changes
  hourly; static templates would lie about what's in flight or what
  locks are held.

### Consequences

- New tabs start with the same boilerplate every time, all live data
  fresh as of `iso_now`.
- The strategic FR-pick reasoning stays human, marked clearly in the
  rendered output.
- One product-specific template per product
  (`profiles/<product>.bootstrap-template.md`); the renderer is
  product-agnostic.
- The portfolio-orchestrator persona doc now requires the spawning
  message to be the rendered prompt; the pillar-orchestrator persona
  doc requires the receiving session to confirm it received one.
- `--with-drift-check` adds ~5s; off by default so ad-hoc human
  invocations don't pay the cost.

### Implementation notes

- awk substitution with explicit `&` escaping (otherwise pillar names
  like "Sampling & Creator Programs" or "Questions & Answers" get
  mangled because awk treats `&` in the gsub replacement as the matched
  text).
- `|| true` guards on every yq subshell so a missing optional field
  (e.g., no `anchor_dependencies` for a fresh product) doesn't kill
  the script under `set -e`.
- yq v4 lacks jq's `if/then/else` and `last`; use `// "fallback"` and
  `[-1:]` slice instead.

### Follow-ups

- A `scripts/spawn-pillar.sh <product> <letter>` wrapper that runs the
  renderer + opens a new terminal tab + pastes the prompt would close
  the loop. Skipped for now — terminal-management UX work that varies
  by operator OS / terminal.
- Section Owner spawn doesn't use this template; /sdlc's Phase 0.6
  integrated mode already does its own bootstrapping. Could unify if
  worth it.
- Other products that adopt the substrate need to author their own
  `<product>.bootstrap-template.md`. Document this in the new-product
  onboarding flow (referenced from `bootstrap-from-profile.sh` D-022).

### References

- `scripts/bootstrap-pillar-prompt.sh`
- `profiles/ugc-platform.bootstrap-template.md`
- `personas/portfolio-orchestrator.md` "Hand-off contract: Portfolio -> Pillar"
- `personas/pillar-orchestrator.md` "Session entry"
- Sibling: D-016 (the tier model this script supports), D-024 (drift check the renderer optionally embeds).

---

## D-026 (2026-05-14) — `spawn-pillar.sh` targets iTerm2 for pillar tabs, regardless of invocation context

### Status

Accepted. Refines `spawn-pillar.sh` (the D-025 follow-up script) after
first-contact friction.

### Context

`spawn-pillar.sh` (approach (a): render + clipboard + open tab) shipped
with a `TERM_PROGRAM`-based auto-detect: iTerm.app -> iterm2,
Apple_Terminal -> terminal, anything else -> iterm2 with a WARN.

In practice the operator runs Claude Code inside VS Code's integrated
terminal, so `TERM_PROGRAM=vscode`. The auto-detect logged a warning
("TERM_PROGRAM=vscode; defaulting to --terminal iterm2. Pass --terminal
terminal if you're on Apple Terminal.") that read like an error — it
made the operator think the script was misconfigured when it was
behaving correctly. Worse, it implied a symmetry that doesn't exist: the
script can drive iTerm2 and Apple Terminal via AppleScript, but it
*cannot* open a tab in VS Code's integrated terminal (no AppleScript
surface for that).

The operator was asked to choose: keep pillar tabs in iTerm2, or stay
in VS Code. They chose iTerm2. (iTerm2 already installed via
`brew install --cask iterm2` during the D-025 follow-up work.)

### Decision

iTerm2 is the **designated home** for pillar-orchestrator tabs. The
script's job is to open the new tab there, full stop — it does NOT
matter where the operator *invokes* the script from. Invocation context
(VS Code integrated terminal, SSH session, iTerm2 itself, unset
`TERM_PROGRAM`) all route the new tab to iTerm2.

The single exception: invoking from Apple Terminal
(`TERM_PROGRAM=Apple_Terminal`) honors Apple Terminal — the operator is
clearly already living there and probably wants the new tab in the same
app.

`--terminal {iterm2,terminal}` remains as an explicit override. The
misleading WARN is removed; the `*)` case now routes to iterm2 silently
because that is the intended behavior, not a fallback.

Two smaller changes in the same edit:
- The iTerm2 AppleScript now `select`s the newly created tab so it has
  focus — the operator's ⌘V lands in the right place without an extra
  click.
- `--help` rewritten to state the iTerm2-is-home model explicitly, to
  spell out the three manual steps in the new tab (launch Claude, ⌘V,
  Enter), and to document the clipboard-clobber recovery
  (`--no-open` re-renders + re-copies).

### Why iTerm2 over Apple Terminal as the designated home

- First-class AppleScript: `create tab with default profile` + `select`,
  vs Apple Terminal's System Events ⌘T keystroke hack.
- Split panes — multiple pillar tabs visible in one window.
- Per-pillar profiles possible (color, startup cd) — future nicety.
- Separating "pillar sessions" (iTerm2) from "code editing" (VS Code)
  keeps both uncluttered.

### Alternatives considered

- **Add a `--terminal vscode` mode.** Rejected. VS Code's CLI can open a
  new integrated terminal but cannot launch Claude into it or paste —
  the mode would do strictly less than the iTerm2 path while adding
  code. The operator chose iTerm2 anyway.
- **Keep the auto-detect symmetric, just soften the warning.** Rejected.
  The asymmetry is real (can't drive VS Code's terminal); pretending
  otherwise in the UX is the actual bug.

### Consequences

- Running `spawn-pillar.sh` from VS Code's terminal now silently opens
  the pillar tab in iTerm2 — no confusing warning.
- The operator's mental model is simple: code in VS Code, pillars in
  iTerm2.
- Apple Terminal users are unaffected (still honored when they invoke
  from it).
- Linux / WSL operators still get the documented fallback: run
  `bootstrap-pillar-prompt.sh` by hand, paste into their target tab.

### References

- `scripts/spawn-pillar.sh` (terminal-detection block, iTerm2 AppleScript)
- `docs/parallel-session-playbook.md` "Spawning a pillar tab"
- Sibling: D-025 (the script this refines), D-021 / GDI-728 (the
  worktree-per-session discipline pillar tabs still follow).

---

## D-027 (2026-05-15) — `audit-registry-drift.sh` scans the test-fixture migration dir; `paired_with` records the pairing

### Status

Accepted. Implemented in `scripts/audit-registry-drift.sh`,
`profiles/ugc-platform.yml`, `schemas/profile.yml.schema.json`,
`schemas/allocation.yml.schema.json`, and `allocations/ugc-platform.yml`
(14 pre-AIDLC + 5 AIDLC-era paired test-fixture migrations backfilled).

### Context

D-024 introduced `audit-registry-drift.sh` to compare the registry against
disk + GitHub releases. The script walks one directory: `migration.dir_pattern`
from the per-product profile (for ugc-platform, the prod Flyway dir
`services/ugc-api/src/main/resources/db/migration`).

In practice, every Section A AI surface and every Section H/B/G ship since
2026-05-13 produces **two** Flyway migrations: a prod-range V<n> in the prod
dir, and a paired test-grants V<n+900> in `services/ugc-api/src/test/resources/db/migration`.
The test-fixture migration grants `app_test_*` roles SELECT/INSERT/DELETE on
the new schema so integration-test fixtures can write through RLS. This is a
load-bearing convention — `ModerationModerationsRlsCrossTenantTest`,
`AnswerSubmissionIT`, `ReviewSummaryRepositoryRlsCrossTenantTest`, etc. all
depend on it.

The drift checker was blind to that sibling directory. Two failure modes:

1. **False-flag as missing.** During the 8-tab capacity run on 2026-05-14/15,
   the checker reported V40, V48, V51 as "missing on disk" because it walked
   only the prod dir. The V900-range entries `(V940, V948, V951)` weren't on
   the prod path. The orphans were *paired* with the V40/V48/V51 prod rows
   in the registry but the checker had no concept of "paired"; it just saw
   reservations with no disk match.
2. **Silent absence.** Even when a section owner did populate the V9XX
   entries in the registry, the prod-only disk walk meant the test-fixture
   side of the pair could land on disk without the registry knowing. By
   2026-05-15 there were 14 pre-AIDLC (`V900`, `V910`-`V924`) and 5 AIDLC-era
   (`V929`, `V930`, `V935`, `V936`, `V944`) test-fixture migrations on disk
   that had no row anywhere in the registry. The checker reported zero drift
   the entire time — because it never looked.

The dual-mode failure was caught only when a Pillar B operator ran the
drift check by hand during a `--with-drift-check` bootstrap and the output
mentioned migration files the operator recognized as already-shipped.

### Decision

Three coordinated changes:

1. **Profile schema (`profiles/<product>.yml`) gains an optional
   `migration.test_fixture_dir_pattern` field.** When set, the drift checker
   walks both `migration.dir_pattern` and `migration.test_fixture_dir_pattern`
   in Check 1, and routes V<test_fixture_threshold>+ lookups in Check 2 to
   the test-fixture dir. If absent, behavior is unchanged from D-024 (the
   checker walks only the prod dir).
2. **Allocation schema (`schemas/allocation.yml.schema.json`) gains
   `fr` and `paired_with` on `shippedFlyway`.** `paired_with` records the
   prod V<n> a test-fixture V<n+threshold> ships under. Both fields are
   optional and backward-compatible.
3. **The 19 backlogged paired test-fixture migrations are written into
   the registry in the same PR.** Pre-AIDLC entries use `epic: pre-aidlc`
   (matching the V1-V12 prod-range convention). AIDLC-era entries carry
   their real epic + FR + release_tag + paired_with.

`reserve.sh` is **unchanged**. Section owners continue to call
`reserve.sh --resource flyway --id V<n>` twice per epic — once for prod,
once for the test-fixture slot — exactly as they do today. The pairing is
recorded at ship time in the `paired_with` field, not at reserve time.

### Why this approach (and not the alternatives)

Three approaches were considered:

- **(A) Teach the drift checker about the test-fixture dir.** *(Chosen.)*
  Minimal surface area: one new optional profile field, one new optional
  shipped-row field, additive changes to the checker. No changes to the
  reservation API. Fixes the symptom (drift miss) without changing the
  workflow operators already know.
- **(B) Add `--paired-with V40` flag to `reserve.sh`.** Cleaner data model
  long-term — the pairing is recorded at reserve time, not after the fact.
  But every section-owner caller has to learn a new flag, and the eight
  active pillar tabs would all need to be re-bootstrapped to pick it up.
  Deferred; revisit if the dual-reserve pattern becomes onerous in practice.
- **(C) Both — checker awareness AND `--paired-with` flag.** Most thorough,
  also the most code to change for what is currently a recordkeeping issue.
  Rejected as over-engineering: the symptom is fixed by (A), and (B) is a
  workflow nicety, not a correctness fix.

### Why `test_fixture_threshold` already existed but `test_fixture_dir_pattern` did not

`test_fixture_threshold: 900` was already in the ugc-platform profile (set
during D-017's per-product profile work). It tells the checker that
versions `>= 900` are test fixtures and excludes them from
prod-`next_free` computation. What was missing was *where* those test
fixtures live on disk. D-017 wrote the threshold from convention (the
existing on-disk pattern) without thinking about the dir-pattern half of
the same pair. D-027 closes that gap.

### Consequences

- The drift checker now reports zero findings against `syndigo/ugc-platform`
  with the test-fixture dir populated. Prior to this work, a clean drift
  report was indistinguishable from "checker can't see the test dir".
- Section owners can keep their existing dual-reserve pattern; no workflow
  change.
- Pre-AIDLC test-fixture migrations are now first-class registry rows. If
  a future cleanup task wants to reconcile the V900-V924 range against
  Jira epics, the rows are in place to be enriched (not added).
- A `paired_with` field is now schema-supported. Future automation (e.g.,
  a `release.sh --pair-with V<n>` shorthand, or a CI gate that fails when a
  test-fixture migration ships without a paired prod migration) has the
  data surface to build on.

### Carry-forward notes for future products

When `bootstrap-from-profile.sh` (D-022) is used to onboard a new product,
the operator should:

1. Populate `migration.dir_pattern` (existing requirement).
2. Populate `migration.test_fixture_dir_pattern` *if and only if* the
   product splits prod vs test migrations into sibling dirs. Products that
   keep test fixtures in the same directory as prod migrations (or that
   don't use Flyway test-grants at all) should leave the field unset.
3. Pick a `test_fixture_threshold` that does not overlap the prod-range
   semver allocator. ugc-platform's 900 leaves headroom up to V899 in prod;
   other products may pick differently.

### References

- `scripts/audit-registry-drift.sh` (Check 1 + Check 2: test-dir aware)
- `profiles/ugc-platform.yml` (`migration.test_fixture_dir_pattern`)
- `schemas/profile.yml.schema.json` (`test_fixture_dir_pattern` description)
- `schemas/allocation.yml.schema.json` (`shippedFlyway.paired_with`, `shippedFlyway.fr`)
- `allocations/ugc-platform.yml` (19 backfilled rows; 5 V9XX entries restored from `released_unused` -> `shipped` with `paired_with`)
- Sibling: D-017 (per-product profile separates shape from state), D-022
  (`bootstrap-from-profile.sh` consumers need the new field), D-024
  (drift checker; this expands its scope).

---

## D-028 (2026-05-19) — `release.sh --update-pillars-block` flipped to default-on; missing `--fr` warns instead of fails

### Status

Accepted. Implemented in `scripts/release.sh` (UPDATE_PILLARS default
flipped to 1; new `--no-update-pillars-block` opt-out flag added;
missing-`--fr` check downgraded from `exit 2` to a `log_warn` that
disables the hooks for that one call). Doc updates in `docs/parallel-session-
playbook.md` (example calls now show `--fr` explicitly and
`--no-update-pillars-block` on the file-lock example).

### Context

D-016 Day-2 introduced `--update-pillars-block` as an opt-in flag on
`release.sh` to reconcile `pillars[]`, `anchor_dependencies[]`, and
`releases.in_flight[]` after a shipped/released call. The opt-in posture
was intentional — we wanted one release cycle of evidence before flipping
the default, to avoid bricking callers that hadn't been updated.

Five days of evidence (§8.12 through §8.16 windows; ~50 ships in
~110 hours; up to 8 concurrent pillar tabs) show that **operator-omitted
hook is the single most frequent drift class**. Pattern in every sweep:

- `flyway.shipped` rows land (because `release.sh` always writes them)
- `pillars[<section>].shipped_frs` does NOT update (because the operator
  omitted the opt-in flag)
- `audit-registry-drift.sh` doesn't catch this (no drift check exists
  for pillar-block-vs-flyway-shipped consistency)
- The next gameplan sweep finds the gap manually and flips the FR rows
  by hand

The Pillar A + Pillar B verifications (`reports/pillar-a-validation-
2026-05-17.md`, `reports/pillar-b-validation-2026-05-17.md`) both passed
on the source side but only because the verifier reconstructed the FR-to-
release mapping from the gameplan. The registry's `pillars[].shipped_frs`
would have been incomplete as a source of truth.

### Decision

Two changes in `scripts/release.sh`:

1. **Flip the default.** `UPDATE_PILLARS=1` is now the initial value. Every
   `release.sh` invocation (shipped, released, or abandoned) runs the
   three D-016 Day-2 hooks unless explicitly opted out.

2. **Add `--no-update-pillars-block`.** Opt-out flag for the use cases
   where the hooks should NOT fire: bootstrap migrations, recovery from a
   stuck state, file-lock releases (which don't carry an FR), or any
   ship where the operator deliberately wants `pillars[]` untouched.

3. **Downgrade the missing-`--fr` check from fatal to warn.** Previously,
   `UPDATE_PILLARS=1 && -z FR` was `exit 2`. With default-on, every
   pre-existing caller that omits `--fr` would suddenly fail. The
   warn-and-skip preserves the per-resource edit (the operator's explicit
   intent) and surfaces the gap loudly via `log_warn` so the next call
   can be improved. The hooks are simply disabled for that one call.

### Why now (not five days ago)

The opt-in posture was the right call for one release cycle — it let us
gather evidence on how often operators omitted the flag (most of the
time) and how the drift surfaced (silently, until manual sweeps caught
it). Flipping the default earlier would have introduced a behavior
change without the evidence to justify it. Flipping it now is well-
supported: gameplan §8.17 documents the trigger event (10 releases in
one overnight window producing 13 pillar-block-vs-flyway-shipped drift
items in the manual sweep).

### Alternatives considered

- **Add a drift-check for pillar-block-vs-flyway-shipped consistency.**
  Would catch the gap but doesn't prevent it. The default-on flip
  prevents the gap from existing in the first place. Both could coexist;
  a follow-up ADR could add the drift check as belt-and-suspenders.
- **Make `--fr` always required.** Stricter, but breaks file-lock and
  release-tag callers that legitimately don't have an FR (those resources
  aren't tied to a specific section feature). Rejected — too disruptive.
- **Keep opt-in but make it default-on per-resource (e.g., default-on for
  flyway, default-off for file-lock).** Cleaner but requires per-resource
  semantics in the script's flag-parsing layer. Rejected as
  over-engineering for the size of the population.

### Consequences

- Every future `release.sh --status shipped` will update `pillars[]`
  automatically. The most common drift class is closed.
- Operators who pass `--fr` see no behavior change (they were already
  hitting the hooks via `--update-pillars-block`).
- Operators who omit `--fr` see a new WARN line; the per-resource edit
  still applies; the pillar block doesn't update for that call. Next
  call with `--fr` brings the block back in sync.
- The `--update-pillars-block` flag becomes a no-op for forward callers
  but is retained for backward compatibility — pillar tabs that still
  pass it won't break.
- One residual drift class remains: the gameplan in `~/Projects/
  powerreviews/gameplan.md` lives outside any git repo writable from
  pillar tabs, so there's no script that can update §10 tracker rows on
  a release. Periodic manual sweeps remain the steady state for that.

### References

- `scripts/release.sh` (UPDATE_PILLARS=1 default, --no-update-pillars-block
  handler, warn-and-skip on missing --fr)
- `docs/parallel-session-playbook.md` (example calls updated)
- Trigger evidence: `~/Projects/powerreviews/gameplan.md` §8.17
- Sibling: D-016 (the original Day-2 introduction this supersedes the
  opt-in posture of), D-024 (drift checker — does not yet cover
  pillar-block-vs-flyway-shipped consistency; potential follow-up).

---

## How to add an ADR

```sh
# Append a new section to docs/decisions.md, never edit existing ones.
# Then commit:
git add docs/decisions.md
git commit -m "docs(adr): D-006 — <title>"
git push
```

Single-writer-files entry for `decisions.md` is `held_by: none` because the file is
append-safe at the section boundary. If two sections add ADR-006 simultaneously, the
second push gets rejected and the operator runs `git pull --rebase` + renumbers.
