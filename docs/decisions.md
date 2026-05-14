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
