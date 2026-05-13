# AIDLC Coordination Service

The **AIDLC Coordination Service** is the allocation registry + serialization mailbox that
allows multiple Claude SDLC sessions (parallel agents working on the same product) to safely
edit shared resources without stomping on each other.

It is **Day-1 file-based**: a single YAML registry per product, edited via three POSIX-bash
scripts, with git serving as the audit trail. A future Coordinator skill will graduate this
to an HTTP service backed by the same YAML.

This repo is the **substrate** — it stores allocation registries (one YAML per product),
the schema that validates them, and the scripts that mutate them atomically.

---

## What this solves

Before AIDLC Coordination, two parallel SDLC sessions targeting the same product (e.g. UGC
Platform Sections A and C) could both claim Flyway version `V19`, both edit `ModelRegistry.kt`
on different branches, both try to deploy through TFC at the same time. Conflicts surfaced
at PR-merge time — costly, after both sessions had invested hours.

AIDLC Coordination moves conflict detection **before the work starts**. A session calls
`conflict-check.sh` at the top of its run; if a shared resource it needs is already held,
the script returns `WAIT` with a reason and an expiry. The session can defer, swap to a
different ticket, or escalate.

---

## Day-1 scope (this repo)

- **`allocations/`** — one YAML per product. The UGC Platform registry (`ugc-platform.yml`)
  is seeded with the current real state as of 2026-05-12.
- **`schemas/`** — the JSON Schema that validates allocation YAMLs. CI enforces it.
- **`scripts/`** — three POSIX-bash scripts that read/write the YAML atomically:
  - `reserve.sh` — claim a shared resource (Flyway version, model registry surface, file lock, release tag)
  - `release.sh` — mark a claim shipped or freed
  - `conflict-check.sh` — read-only check; the right answer for "before I start working"
  - `status.sh` — human-readable dashboard of current holds
- **`personas/`** — four markdown specs describing the roles that interact with the registry
- **`docs/`** — playbook for running parallel sessions, architecture diagram, ADR log

---

## What's deferred (intentionally NOT in this repo on Day 1)

- The `/coordinate` Claude skill — sessions call the scripts directly via Bash for now.
- The Compliance Reviewer GitHub webhook.
- The Retro Aggregator scheduled job.
- The TFC deploy mailbox (the YAML has a stub, but Day 1 sessions still merge directly
  to dev as today).
- A platform profile YAML for this repo — will be authored separately via `/profile-builder`.

See [`docs/decisions.md`](docs/decisions.md) for the rationale on each deferral.

---

## Quick start

```sh
# 1. Clone alongside the product repo you're working in
git clone https://github.com/syndigo/aidlc-coordination ~/Projects/aidlc-coordination

# 2. Before starting a new section's work, check for conflicts
cd ~/Projects/aidlc-coordination
./scripts/conflict-check.sh --section C --fr C.1.18 --files-to-touch ModelRegistry.kt

# 3. If GO, reserve the resources you need
./scripts/reserve.sh --resource flyway --section C --epic GDI-700 --id V24 --ttl-hours 24

# 4. Do the work in the product repo, then mark it shipped
./scripts/release.sh --resource flyway --section C --epic GDI-700 --id V24 \
  --status shipped --release-tag v0.30.0
```

See [`docs/parallel-session-playbook.md`](docs/parallel-session-playbook.md) for a worked
two-session example.

---

## Repository layout

```
.
├── allocations/
│   └── ugc-platform.yml          # the real Day-1 registry
├── schemas/
│   └── allocation.yml.schema.json
├── scripts/
│   ├── reserve.sh
│   ├── release.sh
│   ├── conflict-check.sh
│   └── status.sh
├── personas/
│   ├── section-owner.md
│   ├── release-coordinator.md
│   ├── compliance-reviewer.md     # FOLLOW-UP (scaffold only)
│   └── retro-aggregator.md        # FOLLOW-UP (scaffold only)
├── docs/
│   ├── parallel-session-playbook.md
│   ├── how-it-works.md
│   └── decisions.md
├── .github/workflows/ci.yml
├── .claude/CLAUDE.md
├── bootstrap-log.md
└── README.md
```

---

## Dependencies

- [`yq` v4](https://github.com/mikefarah/yq) — YAML processor used by every script
- `bash` 3.2+ (the macOS default; scripts are POSIX-portable)
- `git` 2.x — used as the audit trail
- `gh` CLI — used by some helper paths
- Python 3 (CI fallback for JSON Schema validation if `ajv-cli` is unavailable)

---

## Status

**Day 1 — bootstrap.** This repo was greenfield-created on 2026-05-12 under epic
[GDI-669](https://syndigo.atlassian.net/browse/GDI-669) and its 6 child stories.
See [`bootstrap-log.md`](bootstrap-log.md) for the full creation trail (D-019 format).

**Integration shipped (GDI-677):** `/sdlc --profile ugc-platform` now auto-invokes
Phase 0.6 coordination check + Stage 10 release. See
[docs/parallel-session-playbook.md](docs/parallel-session-playbook.md) integrated
mode for the default workflow. Manual mode remains documented as fallback.
