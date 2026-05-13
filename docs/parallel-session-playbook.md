# Parallel Session Playbook

This playbook walks through running two Claude SDLC sessions in parallel against the UGC
Platform — Section A on FR-A.1.9 and Section C on a hypothetical FR-C.1.18 — using the
AIDLC Coordination Service scripts.

The goal is to show the **end-to-end flow** for one concrete day, with actual commands
and expected outputs. Use it as a template when you spin up your own parallel sessions.

---

## Setup (one-time)

Each operator clones the coordination repo once, alongside the product repo:

```sh
cd ~/Projects
gh repo clone syndigo/aidlc-coordination
gh repo clone syndigo/ugc-platform   # the product repo, if you don't already have it
```

The scripts assume `aidlc-coordination/` is checked out and on the latest `main`. Pull
before starting each session:

```sh
cd ~/Projects/aidlc-coordination && git pull --rebase
```

---

## Scenario

- **Session 1 (Tab 1):** Section A continuing work on FR-A.1.9 (catalog-locale-translation).
  This is the live in-flight item per the seeded registry. Section A already holds the
  `ModelRegistry.kt` + `Prompts.kt` locks and a `V19` Flyway reservation.

- **Session 2 (Tab 2):** A fresh Section C ticket — FR-C.1.18 — that needs to add
  reviews translation. It depends on the FR-A.1.9 anchor surface.

---

## Session 1 — Section A (resuming)

### Step 1.1 — Pre-flight check

```sh
$ cd ~/Projects/aidlc-coordination
$ ./scripts/conflict-check.sh \
    --section A \
    --fr FR-A.1.9 \
    --files-to-touch ModelRegistry.kt,Prompts.kt
```

**Expected output:**

```
[INFO]  GO — section A may proceed with FR-A.1.9
GO
```

Section A is already the holder; the check is idempotent.

### Step 1.2 — Do the work in the product repo

Section A's session now switches to the UGC Platform repo and runs `/sdlc` against
GDI-720 (the Jira ticket for FR-A.1.9). The coordination repo is no longer touched
until ship time.

### Step 1.3 — Ship + release

When the PR merges and `v0.28.0` is tagged:

```sh
$ cd ~/Projects/aidlc-coordination
$ ./scripts/release.sh --resource flyway --section A \
    --epic section-A-FR-A.1.9-epic --id V19 \
    --status shipped --release-tag v0.28.0

$ ./scripts/release.sh --resource model-registry --section A \
    --epic section-A-FR-A.1.9-epic --id catalog-locale-translation \
    --status shipped --release-tag v0.28.0

$ ./scripts/release.sh --resource file-lock --section A \
    --epic section-A-FR-A.1.9-epic \
    --id services/ugc-api/src/main/kotlin/com/syndigo/ugc/ai/ModelRegistry.kt \
    --status released
```

After these run, the FR-A.1.9 anchor is `shipped` and the three blocked consumers
(C.1.18, B.1.9, J.5.4) move to `free`. The Release Coordinator then pings the
unblocked sections.

---

## Session 2 — Section C (attempted parallel start)

### Step 2.1 — Pre-flight check (while Section A is still in_flight)

```sh
$ cd ~/Projects/aidlc-coordination && git pull --rebase
$ ./scripts/conflict-check.sh \
    --section C \
    --fr FR-C.1.18 \
    --files-to-touch ModelRegistry.kt
```

**Expected output:**

```
[WARN]  WAIT — section C cannot proceed with FR-C.1.18:
WAIT file=ModelRegistry.kt held_by=section-A-FR-A.1.9-epic until=2026-05-14T22:00:00Z
WAIT:
WAIT file=ModelRegistry.kt held_by=section-A-FR-A.1.9-epic until=2026-05-14T22:00:00Z
```

Exit code: `1`. The session does NOT proceed.

### Step 2.2 — Verify anchor dependency

`conflict-check.sh` also surfaces the anchor block:

```sh
$ ./scripts/conflict-check.sh --section C --fr FR-C.1.18
[WARN]  WAIT — section C cannot proceed with FR-C.1.18:
WAIT anchor=FR-A.1.9 status=in_flight
```

The session can read `status.sh` to see when Section A is expected to ship:

```sh
$ ./scripts/status.sh
=================================================
 AIDLC Allocation Status — ugc-platform
=================================================
 current_main:   v0.27.0
 ...
--- Active reserved Flyway versions ---
  V19  section=A  epic=section-A-FR-A.1.9-epic  fr=FR-A.1.9  expires=2026-05-14T22:00:00Z
 ...
--- Anchor dependencies (in-flight) ---
  FR-A.1.9 (section A): Translation single-anchor surface
    consumers: C.1.18 (blocked_until_anchor_shipped), ...
```

### Step 2.3 — Section C's options

1. **Wait until 2026-05-14T22:00:00Z** for Section A to ship, then re-run Phase 0.
2. **Swap to a different Section C ticket** that doesn't depend on FR-A.1.9 (e.g.
   FR-C.1.5 which has no anchor dependency).
3. **Escalate to the Release Coordinator** if FR-A.1.9 is slipping and FR-C.1.18 is
   on the critical path.

Section C chooses option 2 and pivots to a different ticket. No code was written yet —
the cost of the conflict was a 30-second `conflict-check.sh` call, not a 4-hour PR
rebase battle.

---

## After Section A ships

Once `v0.28.0` is released and the Release Coordinator runs the post-ship registry
updates, Section C's pre-flight returns GO:

```sh
$ ./scripts/conflict-check.sh --section C --fr FR-C.1.18 \
    --files-to-touch ModelRegistry.kt
[INFO]  GO — section C may proceed with FR-C.1.18
GO
```

Section C reserves and proceeds:

```sh
$ ./scripts/reserve.sh --resource file-lock --section C \
    --epic GDI-740 --id services/ugc-api/src/main/kotlin/com/syndigo/ugc/ai/ModelRegistry.kt \
    --fr FR-C.1.18 --ttl-hours 24

$ ./scripts/reserve.sh --resource flyway --section C \
    --epic GDI-740 --id V24 --fr FR-C.1.18 --ttl-hours 24
```

---

## Tips

- **Always `git pull --rebase` before running any script.** Other sections may have
  pushed updates since you last ran `status.sh`.

- **Use `--json` for any script when piping into another tool.** The human format is
  optimized for terminal reading; the JSON format is stable across releases.

- **Use `--dry-run` on `reserve.sh` when learning.** It shows the diff without
  pushing — useful for the first few times.

- **If you hit a `WAIT` you don't understand,** run `./scripts/status.sh` and read the
  full active state. The conflict-check output is intentionally terse.

- **Reservations expire on TTL.** If your work runs past the TTL, re-run `reserve.sh`
  with the same args to extend.
