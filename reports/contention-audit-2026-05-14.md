# Pillar Contention Audit — 2026-05-14

> Scope: UGC Platform (`allocations/ugc-platform.yml`).
> Audited at HEAD `69c8b3d` (2026-05-14, after Day-2 batch landed).
> Author: portfolio audit pass during troubleshooting.

This is the live answer to "where are pillars tripping over each other?".
Each finding lists the symptom, the registry truth, the gap, and the fix.

---

## Headline numbers

- **7 / 4 pillars in flight** — over the cap declared in the profile
  (`max_concurrent_pillars_in_flight: 4`). The portfolio orchestrator should
  have deferred 3 pillars but cannot, because the orchestrator personas have
  not been instantiated as live sessions yet.
- **Critical path:** FR-F.1.5.1 (AI-elevated product matching, in Pillar F).
  Has 1 deferred consumer (FR-A.1.12). Currently `not_started` per
  `anchor_dependencies` but `in_flight` per `pillars[F].in_flight_frs`.
  **Anchor-dependencies state is stale relative to pillar state.** First gap.
- **Active single-writer holds:** all three on Pillar B's GDI-907.
  - `ai/governance/ModelRegistry.kt`     until 2026-05-16T03:38:43Z
  - `ai/prompt/Prompts.kt`                until 2026-05-16T03:38:45Z
  - `service/ReviewService.kt`            until 2026-05-16T03:38:40Z
- **Pillar shipped_frs are all empty** for B/C/D/E/F/G/H/I/J — even though
  Pillars B and C have shipped multiple releases this week (v0.34.0,
  v0.36.0, v0.37.0, v0.40.0, v0.41.0, v0.42.0 are all in `flyway.shipped`
  with section labels). **shipped_frs are never written.** Second gap and
  the root cause of most "pillars tripping over each other" symptoms.

---

## Finding 1 — `pillars[].shipped_frs` is never updated

**Symptom:** `shipped_frs` stays `[]` for every pillar except A. Yet
`flyway.shipped` shows ~8 sections-B/C/D shipped versions in the last 24
hours. The pillar block is **fiction** — if the pillar-orchestrator persona
reads it to decide what to launch next, every decision is wrong.

**Registry truth:** `release.sh` writes to `flyway.shipped` /
`model_registry.shipped` / `releases.in_flight` but never touches
`pillars[<letter>].shipped_frs` or `in_flight_frs`. The Pillar Orchestrator
persona is supposed to update them by hand. Nobody is doing that.

**Gap:** `release.sh --status=shipped --fr <FR-X.Y.Z>` should atomically
move the FR from `pillars[<letter>].in_flight_frs` to `shipped_frs`. Same
for `--status=abandoned` (remove from `in_flight_frs`, no append).

**Concrete consequence:** the intra-pillar serial chain guard added to
`reserve.sh` (D-016) checks if predecessor is in any pillar's
`shipped_frs`. Every intra-pillar chain that depends on a B/C/D/E/F/G/H/I/J
FR will refuse to fire — false WAITs. Today the only chain we have is
`FR-A.1.9 -> FR-B.1.9` and A.1.9 IS in A's shipped_frs, so we got lucky.
First time we add a same-pillar chain, this breaks.

**Fix:** Day-2 task already on the list.
[Wire release.sh to update pillars block.]

---

## Finding 2 — `anchor_dependencies` state lags pillar state by hand-edits

**Symptom:** `anchor_dependencies[FR-F.1.5.1].status = not_started`. But
`pillars[F].in_flight_frs = [FR-F.1.5.1]` and `releases.in_flight` has
F's GDI-846 with `proposed_tag: v0.39.0`. Two views of the same fact
disagree.

**Registry truth:** Nobody updates `anchor_dependencies[].status` when an
FR moves through its lifecycle. It's set at registry-seed time and stale
forever after.

**Gap:** when `release.sh` ships an FR that appears as an `anchor:` in
`anchor_dependencies`, set `status: shipped` + `shipped_at` + `shipped_release`.
When `reserve.sh` reserves a flyway/model-registry resource for an FR
that is an `anchor:`, transition to `in_flight`.

**Concrete consequence:** `portfolio-status.sh` picks the critical path
from `anchor_dependencies` where `status != shipped`. F.1.5.1 is mislabeled
`not_started` so it shows as critical, when in reality it's already
in-flight — the *next* unshipped anchor (none exist) is what should be
flagged.

**Fix:** add the same hook in `release.sh` that I'm adding for `pillars`.
Bundle this in the same commit.

---

## Finding 3 — Section H reservations re-keyed mid-stream (GDI-728/D-008 redux)

**Symptom:** commits `06a19a8` / `23ab4c3` / `dc173ee` reserved V938, V40,
V940 under the placeholder `section-H-FR-H.4-epic`. Then `94d94a7`
re-keyed all three to `GDI-886`. The fact that this happened means the
operator started work without a Jira key and had to fix it up later.

**Registry truth:** `reserve.sh` doesn't validate that `--epic` looks like
a real Jira key. Placeholders sail through. The `--epic` field then has to
be hand-edited later, which is exactly the kind of churn that creates
phantom "reserved by section-H-FR-H.4-epic, but H.4 is now GDI-886"
ambiguity.

**Concrete consequence:** today nothing breaks because the re-key happened
quickly. But for any future tab that runs `release.sh --all-for-epic
section-H-FR-H.4-epic` after the re-key, it would find nothing and silently
no-op.

**Fix:** add an optional `--enforce-jira-pattern` flag to `reserve.sh`
that refuses an `--epic` that doesn't match `^GDI-[0-9]+$`. Set it via the
profile (`profile.product.epic_pattern`). Day-3, not Day-2 priority.

---

## Finding 4 — Pillar B's GDI-907 grabbed all three load-bearing locks

**Symptom:** ModelRegistry.kt, Prompts.kt, ReviewService.kt all held by
GDI-907 (Section B's FR-B.2.8 = "review-precheck" AI surface). Held until
2026-05-16T03:38Z (~36 hours from now).

**Registry truth:** This is *correct behavior*. B legitimately needs all
three to add a new AI surface. The issue is not that B holds them — it's
that **Pillars C, F, and any future Pillar that wants to touch
ModelRegistry.kt are blocked for 36 hours**, and there is no signal in
their `pillars[<letter>].blocked_on` saying so.

**Concrete consequence:**
- C has FR-C.1.18 in backlog (consumes the A.1.9 anchor) — but C.1.18
  needs to add a `review-summary-locale` consumer to ModelRegistry.kt.
  Blocked, but C's `blocked_on` is `[]`.
- F's GDI-846 just shipped (8b2022d / 212f35b / 1f5c397 released the
  three locks) so F is currently free, but F's next FR will hit the
  same wall.
- Any Pillar Orchestrator running pillar-status.sh today on letter C
  will see "lock contention" but not understand it as a *blocker on
  this pillar's launchable backlog*. It's just a warning, not a stop.

**Gap:** when `reserve.sh` returns WAIT for a load-bearing lock that a
pillar's backlog FR needs, the pillar-orchestrator should write
`blocked_on: ["ModelRegistry.kt held by GDI-907 until <ts>"]` so the
portfolio-orchestrator can see it on the next tick.

**Fix:** add a `--write-blocked-on <pillar-letter>` flag to
`conflict-check.sh`. When the script returns WAIT and that flag is set,
it appends a `blocked_on` entry to the pillar's block. Day-3.

---

## Finding 5 — `releases.in_flight` doesn't get pruned when a release ships

**Symptom:** `releases.in_flight` lists three entries — A `v0.28.0`, E
`v0.38.0`, F `v0.39.0`. But:
- v0.28.0 shipped 2026-05-13 (A.1.9 anchor shipped)
- v0.38.0 shipped 2026-05-14T02:11Z (V32, V932 in flyway.shipped tagged
  it)
- F shipped v0.42.0 not v0.39.0 (commit `880849b`)

**Registry truth:** `release.sh --status=shipped` sets the resource as
shipped but does not remove the corresponding entry from
`releases.in_flight[]`. So in_flight is a permanent journal of "every
proposal ever made" rather than what's actually in flight.

**Concrete consequence:** `portfolio-status.sh` and the `serial_with`
guard in `reserve.sh` both read `releases.in_flight` to detect ship-window
contention. A peer pillar will be flagged as in-flight forever.

**Fix:** `release.sh --status=shipped` should remove the matching entry
from `releases.in_flight[]` (where `epic` matches and `proposed_tag`
matches OR the next adjacent semver). Day-2.

---

## Finding 6 — V21 / V23 reservations hit their TTL (almost)

**Symptom:** flyway V21 and V23 are both reserved by Section A with
`expires_at: 2026-05-15T22:00:00Z` (29 hours from now). V21 is for
FR-A.1.12 (GDI-742). V23 is "section-A-buffer" with note "release if
unused by 2026-05-15". Both will be `expired but still in the registry`
unless something culls them.

**Registry truth:** Nothing reads `expires_at` and acts on it. The
`status.sh` view shows them; nobody acts. The "ttl-expired sweep"
mentioned in the pillar-orchestrator persona docs has no script behind it.

**Gap:** add `release.sh --sweep-expired` that finds reserved entries
where `expires_at < now` and calls itself with `--status=abandoned
--reason=ttl-expired` for each. Either Pillar Orchestrator or a cron-style
loop calls it.

**Fix:** Day-2.

---

## Finding 7 — `flyway.next_free` is wrong (documentary, lazy update)

**Symptom:** `.flyway.next_free = V24`. Actual next free = V43 (V42 just
got reserved by GDI-907; V32–V42 are reserved or shipped; V40, V41 also).

**Registry truth:** `next_free` was deliberately left documentary because
GDI-770 added a lazy-compute path in `status.sh`. The field stays stale.

**Concrete consequence:** any tab that reads `.flyway.next_free` directly
(without going through `status.sh`'s lazy compute) will pick V24 and
collide with the V24 already shipped by GDI-692 in `flyway.shipped`.

**Fix:** delete the `next_free` field from the YAML and the schema, OR
auto-update it on every `reserve.sh` for flyway. Lean delete, since the
lazy compute already exists. Day-3.

---

## Severity-ranked fix list

| Pri | Fix | Impact | Day |
|-----|-----|--------|-----|
| P0  | `release.sh` updates `pillars[].shipped_frs` + removes from `in_flight_frs` | Pillar block becomes truthful; serial chain guard works as designed | 2 |
| P0  | `release.sh` updates `anchor_dependencies[].status` + `shipped_at` + `shipped_release` when an anchor ships | Critical-path computation becomes correct | 2 |
| P0  | `release.sh --status=shipped` removes matching entry from `releases.in_flight[]` | `serial_with` guard stops false-positiving | 2 |
| P1  | `release.sh --sweep-expired` (with `release.sh --status=abandoned --reason=ttl-expired`) | TTL-expired reservations get cleaned automatically | 2 |
| P1  | `git_pull_rebase` never auto-pops a conflicting stash; warns + leaves stash for the operator | This very session almost lost untracked files | 2 |
| P1  | Orchestrator personas refuse to run outside a worktree | Closes the stash-pop loss vector | 2 |
| P2  | `conflict-check.sh --write-blocked-on <letter>` | Pillar block surfaces lock blockers automatically | 3 |
| P2  | `--enforce-jira-pattern` on reserve.sh, set via profile | Stops placeholder epic keys leaking into the registry | 3 |
| P3  | Delete `flyway.next_free` (use lazy compute) | Removes a stale documentary field | 3 |

---

## Recommended Day-2 commit order

1. **`release.sh` pillar-block + anchor-state + in_flight pruning** (one commit, three hooks). This is THE big fix.
2. **`release.sh --sweep-expired`** (small, isolated).
3. **`git_pull_rebase` hardening** (defensive — one section in `_lib.sh`).
4. **Orchestrator persona worktree refusal** (doc edits).
5. **`bootstrap-from-profile.sh`** (independent — for next product).

After 1–4 land, re-run `portfolio-status.sh` and the dashboard should
reflect ground truth. Then we can decide which pillars to defer / prioritize.

---

## Phase 4 (cross-check vs UGC repo + GitHub releases) — landed 2026-05-14

After Phase 3 reconciled the registry against itself, a follow-up audit
compared the registry against the actual UGC repo and GitHub releases.
**10 drift findings** caught (5 untracked tags, 4 migrations on disk
not in registry, 1 stale anchor + collateral pillar fixes).

Reconciliation landed in commit `1293f0e` (the diff slipped into the
"chore(stats): refresh portfolio stats" commit because portfolio-status.sh
auto-pushed during the same edit window — the data is correct, the
commit message is misleading; documented here for the audit trail).

Subsequent invocation of the new `audit-registry-drift.sh` script
caught **5 MORE untracked tags** (v0.17.0, v0.18.0, v0.18.1, v0.20.0,
v0.20.1) that the original audit's `--limit 20` cut off. All 10 untracked
tags are now noted in the `releases:` comment block. Pillar D, E, G
in_flight_frs were moved to shipped_frs (their merged-to-dev work is
genuinely shipped, just not tagged).

**Final dashboard after Phase 4:** zero drift findings, 2 pillars
in_flight (B/H), 8 not_started. Cap of 8 is fine.

## Phase 5 (recurring drift detection) — landed 2026-05-14

`scripts/audit-registry-drift.sh` (D-024) makes the cross-check
repeatable. Five drift checks: disk-vs-registry migrations, stale
reservations, GitHub-releases-not-in-registry, anchor staleness, and
pillar-speculation. Read-only; exits 1 on findings; JSON mode for
machine consumption.

Wired into the portfolio-orchestrator persona doc as step 2 of every
tick (after `--sweep-expired`, before `--update-stats`). Future Phase
5+ work could add CI integration so any push to `allocations/` that
introduces drift fails the PR.
