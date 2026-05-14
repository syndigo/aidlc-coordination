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
- **`scripts/`** — POSIX-bash scripts that read/write the YAML atomically:
  - `reserve.sh` — claim a shared resource (Flyway version, model registry surface, file lock, release tag)
  - `release.sh` — mark a claim shipped or freed
  - `conflict-check.sh` — read-only check; the right answer for "before I start working"
  - `status.sh` — human-readable dashboard of current holds
  - `worktree.sh` — create/remove an isolated git worktree for the current session
    (GDI-728: prevents shared-clone working-tree contamination during concurrent runs)
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

# 3. If GO, isolate the session in a worktree (concurrent-run safety, GDI-728)
./scripts/worktree.sh add --repo-path ~/Projects/ugc-platform --epic GDI-700 \
  --branch feature/GDI-700-add-locale-translation

# 4. Reserve the resources you need
./scripts/reserve.sh --resource flyway --section C --epic GDI-700 --id V24 --ttl-hours 24

# 4b. (Recommended) Reserve a release-band, NOT a specific tag (GDI-778)
./scripts/reserve.sh --resource release-band --section C --epic GDI-700 --id "v0.3x" --ttl-hours 24

# 5. Do the work in the worktree, then at Stage 9 compute the next free tag
NEXT_TAG="$(./scripts/next-tag.sh --section C)"  # → e.g. v0.43.0
gh release create "$NEXT_TAG" --target <merge-sha> --title "..."

# 6. Mark resources shipped
./scripts/release.sh --resource flyway --section C --epic GDI-700 --id V24 \
  --status shipped --release-tag "$NEXT_TAG"
./scripts/release.sh --resource release-band --section C --epic GDI-700 --id "v0.3x" \
  --status released --release-tag "$NEXT_TAG"

# 7. Clean up the worktree
./scripts/worktree.sh remove --repo-path ~/Projects/ugc-platform --epic GDI-700
```

> **Why release-band (GDI-778)?** Pre-reserving a specific release tag at Phase 0.6
> is racy across parallel /sdlc sessions — `gh release create` doesn't consult the
> registry, and the reservation gets stolen by whichever section reaches Stage 9
> first. Four consecutive Section C runs (GDI-731 / GDI-779 / GDI-830 / GDI-893)
> paid a ~2-3 min Stage 9 re-allocation tax. The fix is to record band-intent at
> intake (sections own bands, not specific tags) and compute the concrete tag at
> create-time via `next-tag.sh` reading `gh release list`.

> **Why the worktree step?** Resource locks (V-numbers, surface names, file paths)
> are tracked at the YAML-registry level. They do NOT protect against same-user,
> same-clone working-tree mutations — branches disappear locally when another
> session runs `git checkout`. GDI-728 codifies the worktree-per-epic convention
> after Stage 4 of GDI-699 was contaminated by a concurrent run on the same clone.

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
│   ├── reserve.sh              # claim a resource; --resource release-band added GDI-778
│   ├── release.sh              # mark shipped/released; --resource release-band added GDI-778
│   ├── next-tag.sh             # GDI-778: compute next free tag at Stage 9 from gh release list
│   ├── conflict-check.sh
│   ├── status.sh
│   └── worktree.sh             # GDI-728: isolate concurrent sessions
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
