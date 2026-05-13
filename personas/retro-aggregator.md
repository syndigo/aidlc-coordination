# Persona: Retro Aggregator

> **Status:** **FOLLOW-UP — scaffold only.** This persona is not active on Day 1.
> The substantive implementation is deferred to a follow-up epic
> (provisional: GDI-Retro-001).

## Identity (intended)

The **Retro Aggregator** is a scheduled job that periodically reads the per-section
retro blocks from each product repo's `.claude/pipeline-learnings.md`, dedupes them,
clusters them by theme (e.g. "JDK version drift", "Flyway version contention", "anchor
slip"), and produces a weekly summary in the AIDLC Coordination repo at
`reports/retros-YYYY-MM-DD.md`.

It also surfaces *cross-section* learnings — patterns where Section A and Section C
hit the same issue but described it differently in their retros.

## Scope (intended)

**Touches:**

- This repo: `reports/` (new directory created when Retro Aggregator goes live)
- Read-only access to product repos' `.claude/pipeline-learnings.md`

**Does NOT touch:**

- The allocation registry YAML
- Product code

## How it will work (Phase 2 design sketch)

Scheduled job (cron / GitHub Actions schedule) every Monday at 09:00 UTC →

1. For each product in `allocations/`, clone the product repo.
2. Read `.claude/pipeline-learnings.md`.
3. Diff against last week's snapshot to find new blocks.
4. Send the new blocks to Claude with a clustering prompt.
5. Write the dedup'd/clustered output to `reports/retros-{date}.md` in this repo.
6. Commit + push.

## Why deferred

The `.claude/pipeline-learnings.md` file in the product repos is itself new (Section A
in UGC Platform started using it in May 2026). We need 4-6 weeks of accumulated retro
blocks before clustering produces useful patterns.

## Triggers for activating this persona

- ≥ 50 retro blocks across all sections (today: ~10)
- A Section Owner asks "have other sections seen this before?" and the answer requires
  manual grep across files (today: feasible; in 6 months: not)
- The Release Coordinator wants weekly trend data for the executive update

## Anti-patterns (when this persona is activated)

- **Editing `pipeline-learnings.md` in-place.** The Aggregator must be read-only on
  product repos — it writes only to this coordination repo.
- **Aggregating across products without attribution.** Each insight must trace back to
  the originating retro block (product + commit SHA).
- **Compressing too aggressively.** A retro is worth more verbatim than as a summary
  bullet; the Aggregator should cluster + index, not paraphrase.
