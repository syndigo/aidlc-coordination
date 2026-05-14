# Orchestration Tiers

> Status: Day-1 (introduced under D-016 / D-017).
> Companion to: [parallel-session-playbook.md](./parallel-session-playbook.md), [how-it-works.md](./how-it-works.md).

This document is the canonical description of the 3-tier orchestration model that
sits on top of the AIDLC allocation registry.

---

## Why three tiers

The Day-1 substrate (allocation YAML + reserve/release/conflict-check scripts +
section-owner persona) handles **resource arbitration** between parallel Section Owners.
What it does NOT handle:

- **Intra-pillar sequencing** — when a pillar contains 13 FRs and three of them have a
  serial-chain dependency, somebody has to decide launch order.
- **Cross-pillar critical path** — when 10 pillars are in flight, somebody has to
  decide which pillar's anchor unblocks the most downstream work.
- **Resource budgeting at portfolio scale** — `ModelRegistry.kt` is a global lock; if
  3 pillars all want it next, somebody decides who waits.

These are all human decisions today (Nate as VP DevOps). The 3-tier model formalizes
them so a Claude session can take over each one.

---

## The tiers

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Tier 3: Portfolio Orchestrator (one per product)                       │
│                                                                         │
│  Owns: critical path, cross-pillar scheduling, ship-window arbitration, │
│        portfolio-wide parallelism cap                                   │
│  Reads: pillars[*], anchor_dependencies, single_writer_files, stats     │
│  Writes: pillars[*].status, pillars[*].blocked_on (cross-pillar),       │
│          pillars[*].serial_with, anchor_dependencies, stats             │
│  Spawns: Pillar Orchestrators                                           │
│  Persona: personas/portfolio-orchestrator.md                            │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │ (one per active pillar)
                                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  Tier 2: Pillar Orchestrator (one per pillar)                           │
│                                                                         │
│  Owns: pillar's FR backlog, intra-pillar sequencing, lock pre-flight,   │
│        per-pillar parallelism cap                                       │
│  Reads: pillars[<my_letter>], single_writer_files, anchor_dependencies  │
│  Writes: pillars[<my_letter>] subtree only                              │
│  Spawns: Section Owners (via /sdlc <ticket>)                            │
│  Persona: personas/pillar-orchestrator.md                               │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │ (up to max_in_flight_frs in parallel)
                                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  Tier 1: Section Owner (one per FR in flight)                           │
│                                                                         │
│  Owns: implementing the FR end-to-end                                   │
│  Reads/writes: section-scoped code, registry entries via reserve/release│
│  Persona: personas/section-owner.md (existing Day-1)                    │
└─────────────────────────────────────────────────────────────────────────┘
```

Adjacent to all three tiers, orthogonal:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Release Coordinator (existing Day-1, peer to Portfolio)                │
│                                                                         │
│  Owns: tag cutting, releases.current_main, in_flight registration       │
│  Persona: personas/release-coordinator.md                               │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## How a tick flows (top down)

1. **Portfolio Orchestrator wakes.** Runs `portfolio-status.sh --update-stats`,
   reads the dashboard, identifies the critical path and any over-cap conditions.
2. **Portfolio decides cross-pillar moves.** Resolves shipped anchors, defers pillars
   over the parallelism cap, surfaces successor_epic chains.
3. **Portfolio nudges Pillar Orchestrator(s).** For each pillar that should make
   progress this tick, hands off to the Pillar Orchestrator with context.
4. **Pillar Orchestrator wakes.** Runs `pillar-status.sh <letter>`, picks the next
   launchable FR per the decision loop in its persona doc.
5. **Pillar pre-flights.** Calls `conflict-check.sh` for the FR's expected files. If
   WAIT, defers and tries the next backlog item.
6. **Pillar launches Section Owner.** Hands the FR + epic to a `/sdlc` invocation.
7. **Section Owner runs the standard flow.** `reserve.sh` is called automatically by
   `/sdlc --profile <product>` at Phase 0.6. The new D-016 pillar guards in `reserve.sh`
   provide a second line of defense if the orchestrator missed something.
8. **Section Owner ships.** `release.sh` at Stage 10 marks the resource shipped, surfaces
   any `successor_epic` to the Portfolio, and the cycle repeats.

---

## Hand-off contracts at a glance

| From → To | Required payload | Update path |
|---|---|---|
| Portfolio → Pillar | pillar letter, reason, in-force constraints | message + `pillars[<letter>].status` write |
| Pillar → Section | FR id, epic, expected files, predecessor symbols | `/sdlc <ticket>` invocation |
| Section → Pillar | FR shipped (via release.sh) | `pillars[<letter>].shipped_frs` append |
| Pillar → Portfolio | pillar status change, blocked_on, exhausted backlog | `pillars[<letter>].status` / `.blocked_on` write |

---

## When NOT to use the higher tiers

The pillar tier and portfolio tier are **opt-in**. A product with one pillar (or one
Section Owner) doesn't need them. The substrate works the same way it did Day-1.

Adopt the pillar tier when:

- A single pillar has more than 3 FRs in flight at once
- Intra-pillar serial chains (anchor → consumer) start tripping people
- A `single_writer_file` lock is being requested by 2+ FRs in the same pillar

Adopt the portfolio tier when:

- ≥3 pillars are in flight simultaneously
- Cross-pillar anchors (e.g. UGC's FR-A.1.9) gate downstream pillars
- The operator (human) is spending more than ~15 minutes/day reading `status.sh`

---

## Per-product reuse: the profile layer

The substrate is product-agnostic. Each product carries:

- One **allocation YAML** at `allocations/<product>.yml` (live state)
- One **profile YAML** at `profiles/<product>.yml` (immutable shape — paths, language,
  pillar definitions, section letter range)

The allocation YAML carries a `profile_ref` field pointing at its profile.

`portfolio-status.sh` reads the profile to find:

- `orchestration.max_concurrent_pillars_in_flight` — the parallelism cap
- `pillars[].fr_prefix` — to validate FR ids
- `pillars[].default_*` — defaults the allocation YAML can override

When bringing on a new product:

1. Author `profiles/<new-product>.yml` — fill in paths, language, pillars
2. Generate a starter `allocations/<new-product>.yml` from the profile (Day-1: by hand;
   future: a `bootstrap-from-profile.sh` script)
3. Same scripts, same personas — no new substrate needed

See [decisions.md](./decisions.md) D-016 (pillar tier rationale) and D-017 (profile
split rationale) for the full design discussion.

---

## What's still deferred

- **`bootstrap-from-profile.sh`** — generates a Day-1 allocation YAML from a profile.
  Today the allocation has to be hand-authored when bringing on a new product.
- **Skill-style invocation** — there is no `/portfolio` or `/pillar` slash command yet.
  The orchestrator personas describe how Claude should behave in a fresh session, not a
  callable skill.
- **Auto-launch of successor epics** — the Portfolio reads `successor_epic` and notifies
  the Pillar; it does not yet auto-spawn a Section Owner.
- **TFC deploy queue integration** — still Day-1 stub (ADR-D-005).

These are intentional Day-2 items. Build the personas and scripts first; promote to
skills once the manual flow proves stable.
