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
