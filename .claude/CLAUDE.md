# Claude instructions for `aidlc-coordination`

This repo is the substrate for the AIDLC Coordination Service. It is **not** a normal
product repo — it has no compiled code, no application server, no database. It holds:

- YAML registries (one per product)
- JSON Schemas
- POSIX-bash scripts
- Markdown documentation

## Editing rules

1. **Allocation YAMLs are append-only-by-section.** When working on Section A, never
   edit Section C's entries. The schema enforces structure, but it does not enforce
   ownership — that's a human/agent contract.

2. **Never `git push --force` to `main`.** The git history of `allocations/` is the
   audit trail.

3. **Every script edit must include a corresponding update to:**
   - The script's `--help` output
   - The matching example in `docs/parallel-session-playbook.md`
   - The corresponding ADR in `docs/decisions.md` if the change is non-trivial

4. **Scripts must stay POSIX-portable** (bash 3.2 compatible). The team runs them on
   macOS and Linux. No `[[`, no `${var,,}`, no `mapfile`, no associative arrays.
   `shellcheck --severity=warning` must pass in CI.

5. **`yq` is mikefarah/yq v4.** Do not introduce alternative YAML processors.

6. **The seeded registry data is real, not example data.** When the UGC Platform ships
   a new release that consumes a reserved Flyway version, update the YAML in this repo
   in the same PR cycle.

## Where things live

- `allocations/<product>.yml` — per-product registry
- `schemas/allocation.yml.schema.json` — schema; one shape for all products
- `scripts/*.sh` — atomic edit + read paths
- `personas/*.md` — role specs (read these before running a section)
- `docs/parallel-session-playbook.md` — the day-to-day walkthrough
- `docs/decisions.md` — append-only ADR log
- `bootstrap-log.md` — D-019 capture of the original repo creation

## When in doubt

- Read `docs/how-it-works.md` first
- Then `personas/section-owner.md` if you're acting as a section
- Then `personas/release-coordinator.md` if you're cutting a release
