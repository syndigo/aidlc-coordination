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

## Integrated mode (post-GDI-677 — default)

As of GDI-677 (May 2026), `/sdlc --profile ugc-platform` invokes the coordination
scripts automatically. Section Owners no longer call `conflict-check.sh` / `reserve.sh`
/ `release.sh` by hand for the standard flow — the orchestrator does it at Phase 0.6
(before Stage 1) and Stage 10 (after Close). The Section Owner only needs to:

1. Make sure the epic carries a `section-A`..`section-J` label (the orchestrator reads
   the section letter from there). If the label is missing or ambiguous, the
   orchestrator will ask once and lock in the answer.
2. Run `/sdlc --profile ugc-platform` against the ticket as usual.
3. Watch the orchestrator's user-visible status line for `🔒 Coordination check…`,
   `✅ GO — N resources reserved`, and at Stage 10 `📤 Releasing coordination
   reservations…` / `✅ Released N resources`.

### Example terminal session (integrated mode)

```text
$ /sdlc GDI-720
🚀 SDLC orchestrator starting…
   Loading profile: ugc-platform
   Run size: M (3 size signals: schema_change, new_api, files_estimated=8)

🔒 Coordination check (--coordinate) starting…
   Repo:    ~/.aidlc-coordination/  (clean checkout)
   Section: A          (from epic label section-A)
   FR:      FR-A.1.9   (from epic problem statement)
   Files-to-touch (computed from touch_patterns):
     - services/ugc-api/src/main/kotlin/com/syndigo/ugc/ai/ModelRegistry.kt
     - services/ugc-api/src/main/kotlin/com/syndigo/ugc/ai/Prompts.kt
     - services/ugc-api/src/main/resources/db/migration/V19__*.sql
   conflict-check.sh → GO
   reserve.sh × 3    → held until 2026-05-14T22:00Z
✅ GO — 3 resources reserved

… Phase 0.7 intent validation …
… Stages 1–9 …

▶ Stage 10: Close
📤 Releasing coordination reservations…
   release.sh × 3 → status=shipped, release_tag=v0.28.0
✅ Released 3 resources

#### FINAL REPORT
…
#### Coordination (Phase 0.6 ran)
| Resource        | ID                              | Reserved at         | Released at         | Status   |
|-----------------|---------------------------------|---------------------|---------------------|----------|
| flyway          | V19                             | 2026-05-13T18:02Z   | 2026-05-13T21:48Z   | shipped  |
| model-registry  | catalog-locale-translation      | 2026-05-13T18:02Z   | 2026-05-13T21:48Z   | shipped  |
| file-lock       | ModelRegistry.kt                | 2026-05-13T18:02Z   | 2026-05-13T21:48Z   | shipped  |
```

If `conflict-check.sh` returns `WAIT`, the orchestrator BLOCKS before Stage 1 with a
structured message naming the section/epic holding the lock and the expiry timestamp.
The Section Owner can wait, swap tickets, or coordinate with the holding section.

### When to fall back to manual mode

- Profile does not have `coordination.enabled: true` (i.e. product hasn't opted in yet).
- Running outside `/sdlc` entirely (ad-hoc registry inspection, retro queries, manual
  reservation extension on a long-running ticket).
- Debugging an orchestrator-level issue with the coordination check (use the scripts
  directly to confirm registry state matches expectations).

Use `/sdlc --coordinate` to force-on the integrated coordination check for a profile
that hasn't opted in. Use `--files-to-touch f1,f2,...` to override the regex-computed
file list when it misses or over-matches.

---

## Manual mode (fallback)

The manual-mode lifecycle below is preserved for the cases listed above. The flow is
identical to what `/sdlc --profile ugc-platform` now performs at Phase 0.6 and
Stage 10 — these are the same scripts.

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

### ⚠ Append-list-conflict-class files (GDI-692 retro, 2026-05-13)

Some single-writer files LOOK append-safe (every change adds a new entry at the end of
a list or enum) but are NOT actually append-safe under parallel editing. When two
sections both add a new entry, git's auto-merge fails because the additions land on
adjacent lines or in the same `when {}` / `enum class { ... }` / `containsExactlyInAnyOrder(...)`
block.

Files in this class for `ugc-platform` are marked `append_list_conflict_class: true` in
the registry:

- `services/ugc-api/src/main/kotlin/com/syndigo/ugc/ai/governance/ModelRegistry.kt`
- `services/ugc-api/src/main/kotlin/com/syndigo/ugc/ai/prompt/Prompts.kt`
- `services/ugc-api/src/test/kotlin/com/syndigo/ugc/ai/governance/ModelRegistryTest.kt`

**Rules for these files:**

1. **Always reserve the lock via `reserve.sh --resource file-lock`** before touching them.
   Do NOT skip "because it's just an enum entry."
2. **Reserve them as a TRIPLE** — if you reserve `ModelRegistry.kt`, also reserve
   `Prompts.kt` AND `ModelRegistryTest.kt`. They co-vary: every AI surface adds entries
   to all three.
3. **DO NOT release these locks as a "false-positive mitigation."** The WAIT they trigger
   when another section is editing is the correct behavior. GDI-692 made this mistake
   and paid for it with a 3-file merge-conflict cleanup at Stage 8.
4. The lock is for the WHOLE FILE for the WHOLE epic duration. There's no finer-grained
   "lock the enum entry section" mechanism — and shouldn't be, because git operates at
   the line level.

When in doubt: the cost of a 24h WAIT for another section to finish is much less than
the cost of a 3-file merge-conflict resolution mid-Stage-8.

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
