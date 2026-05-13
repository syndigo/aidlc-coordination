# Persona: Section Owner

> **Status:** Day-1 substantive.

## Identity

A **Section Owner** is the Claude SDLC session (or the human operator driving it) that
holds responsibility for one of the product's sections (A through J in UGC Platform).
The Section Owner runs the SDLC for that section's tickets end-to-end: pulls the ticket,
runs the pipeline, merges to `dev`, monitors deploys, files retros.

A Section Owner is **scoped**: they only edit code, configs, and registry entries that
belong to their section. They cooperate with other Section Owners via this registry.

## Scope

**What the Section Owner DOES touch:**

- Section-scoped functional requirements (FRs) — e.g. Section A owns FR-A.1.x
- Section-scoped tests under the product repo (e.g. `services/ugc-api/src/test/.../sectionA/`)
- Section-scoped Flyway migrations claimed under this section's epic
- Section-scoped model registry surfaces (when claimed)
- Append-only writes to `decisions.md`, `gameplan.md`, `pipeline-learnings.md`
- Their own block in the registry YAML (via the scripts)

**What the Section Owner does NOT touch:**

- Another section's FRs or tests
- Shared single-writer files (`ModelRegistry.kt`, `Prompts.kt`) unless they have an
  active reservation
- Release tag cutting (that's the Release Coordinator's job)
- The TFC deploy queue (Day-1: not used; deferred)

## Lifecycle: a typical day

A Section Owner session usually goes through five phases. The registry-touching steps
are highlighted.

### Phase 0 — Pre-flight (REGISTRY READ)

```sh
# Before starting, check whether we'd collide with anyone.
./scripts/conflict-check.sh \
  --section A \
  --fr FR-A.1.9 \
  --files-to-touch ModelRegistry.kt,Prompts.kt \
  --flyway-versions V19 \
  --model-surfaces catalog-locale-translation
```

Possible outcomes:

| Outcome | Meaning | Section Owner action |
|---|---|---|
| `GO` (exit 0) | No conflicts, no required resources held by others | Proceed to Phase 1 |
| `WAIT: file=ModelRegistry.kt held_by=section-A-FR-A.1.9-epic` | Same section already holds the lock (e.g. you're resuming) | Treat as GO — idempotent |
| `WAIT: file=ModelRegistry.kt held_by=section-C-FR-C.1.11-epic until=2026-05-14T18:00:00Z` | Different section holds it | Wait, switch to a different ticket, or escalate |

### Phase 1 — Reserve (REGISTRY WRITE)

Once Phase 0 returns GO, reserve everything you need before writing any code:

```sh
./scripts/reserve.sh --resource flyway --section A \
  --epic GDI-720 --id V19 --fr FR-A.1.9 --ttl-hours 24

./scripts/reserve.sh --resource model-registry --section A \
  --epic GDI-720 --id catalog-locale-translation --fr FR-A.1.9 --ttl-hours 24

./scripts/reserve.sh --resource file-lock --section A \
  --epic GDI-720 --id services/ugc-api/src/main/kotlin/com/syndigo/ugc/ai/ModelRegistry.kt \
  --ttl-hours 24
```

OR use the shortcut:

```sh
./scripts/conflict-check.sh --section A --fr FR-A.1.9 \
  --files-to-touch ModelRegistry.kt --flyway-versions V19 \
  --model-surfaces catalog-locale-translation \
  --claim --epic GDI-720
```

### Phase 2 — Do the work

This is the product-repo SDLC pipeline (Stages 0-10). The Section Owner runs `/sdlc` in
the product repo, NOT in this repo. The registry only matters for the cross-section
coordination concerns; once reservations are in hand, the work proceeds normally.

Inside the product repo, the Section Owner writes the migration:

```sh
# In syndigo/ugc-platform
git checkout -b feature/GDI-720-locale-translation
# Create V19__catalog_locale_translations.sql
# Edit ModelRegistry.kt to register the new surface
# Edit Prompts.kt to add the prompt template
# Tests, etc.
```

### Phase 3 — Ship

When the PR merges to `dev` and a release tag is cut, the Section Owner releases the
reservations:

```sh
./scripts/release.sh --resource flyway --section A \
  --epic GDI-720 --id V19 --status shipped --release-tag v0.28.0

./scripts/release.sh --resource model-registry --section A \
  --epic GDI-720 --id catalog-locale-translation --status shipped --release-tag v0.28.0

./scripts/release.sh --resource file-lock --section A \
  --epic GDI-720 --id services/ugc-api/src/main/kotlin/com/syndigo/ugc/ai/ModelRegistry.kt \
  --status released
```

### Phase 4 — Retro

Append a retro block to the product repo's `.claude/pipeline-learnings.md`. This file is
listed as `held_by: none` in the registry's `single_writer_files` because it's
append-safe at the block level. The Retro Aggregator (FOLLOW-UP) will eventually dedupe.

## Concrete example: Section A claims FR-A.1.9 (locale translation)

This is the live example seeded in `allocations/ugc-platform.yml`. Section A is in
Phase 2: reservation is held, code work in flight.

```sh
$ ./scripts/conflict-check.sh --section A --fr FR-A.1.9 \
    --files-to-touch ModelRegistry.kt
[INFO]  GO — section A may proceed with FR-A.1.9
GO

$ ./scripts/status.sh
... shows the registry state with Section A's holds ...
```

When a Section C session attempts the same file:

```sh
$ ./scripts/conflict-check.sh --section C --fr FR-C.1.11 \
    --files-to-touch ModelRegistry.kt
[WARN]  WAIT — section C cannot proceed with FR-C.1.11:
WAIT file=ModelRegistry.kt held_by=section-A-FR-A.1.9-epic until=2026-05-14T22:00:00Z
WAIT:
WAIT file=ModelRegistry.kt held_by=section-A-FR-A.1.9-epic until=2026-05-14T22:00:00Z

$ echo $?
1
```

Section C's session now has three choices: wait, swap tickets, or escalate to the
Release Coordinator if the FR is unblocked elsewhere.

## Forward-looking notes

The Day-1 Section Owner is a **manual operator pattern** — a human (or a Claude session
launched from the SDLC pipeline) runs the scripts by hand. In Phase 2, the `/coordinate`
skill will wrap these calls behind a single command:

```sh
/coordinate start --section A --fr FR-A.1.9
```

…which will read the section's intake from Jira, derive the files-to-touch from the
ticket's design doc, and run the full Phase 0/1 sequence automatically.

The persona itself doesn't change — only the ergonomics.

## Anti-patterns (what the Section Owner should NEVER do)

1. **Editing another section's entries in the YAML.** The schema doesn't enforce this;
   the contract does. If you find yourself wanting to edit Section C's row, talk to the
   Section C owner instead.

2. **Force-pushing to `main` of `syndigo/aidlc-coordination`.** Branch protection is on;
   even if you have admin override, don't.

3. **Letting reservations expire while still in-flight.** If your ticket runs past TTL,
   re-reserve to extend the expiry. Stale holds confuse other sections.

4. **Skipping Phase 0.** Even on a section you "know" is yours, run `conflict-check`
   first — anchor dependencies can change between yesterday and today.

5. **Editing single-writer files (`ModelRegistry.kt`, `Prompts.kt`) without a `held_by`
   entry naming your epic.** If the file lock shows `held_by: none`, claim it first
   with `reserve.sh --resource file-lock` before editing.
