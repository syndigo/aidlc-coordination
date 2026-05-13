# How It Works

This document describes the architecture of the AIDLC Coordination Service.

---

## One-paragraph summary

A YAML file per product holds the **allocation registry** — what's shipped, what's
reserved, who holds what. Three POSIX-bash scripts read and write the YAML atomically
via local-clone + git-commit-as-audit-trail + push-with-rebase-retry. Sessions running
the SDLC pipeline call the scripts at the top of their work (to check) and at the end
(to release). Git is the audit trail; `yq` v4 is the YAML processor.

---

## System diagram

```mermaid
flowchart LR
    subgraph SDLC1["Claude SDLC Session — Section A"]
        A1[Phase 0: conflict-check.sh]
        A2[Phase 1: reserve.sh]
        A3[Phase 2: do work in product repo]
        A4[Phase 3: release.sh]
    end

    subgraph SDLC2["Claude SDLC Session — Section C"]
        C1[Phase 0: conflict-check.sh]
        C2[WAIT — exit 1]
        C3[swap ticket]
    end

    subgraph Repo["syndigo/aidlc-coordination"]
        Y[allocations/ugc-platform.yml]
        S[schemas/allocation.yml.schema.json]
        SC[scripts/*.sh]
    end

    subgraph Coord["Release Coordinator"]
        R1[verify anchor consumers]
        R2[cut tag in product repo]
        R3[update registry]
    end

    A1 -->|read| Y
    A2 -->|write via yq + git push| Y
    A3 -->|merge to dev| Coord
    A4 -->|write via yq + git push| Y
    C1 -->|read| Y
    C1 -->|GO/WAIT| C2
    C2 --> C3
    R3 -->|write via yq + git push| Y
    Y -. validated by .-> S
    SC -. operate on .-> Y
```

---

## Sequence: a happy-path reserve

```mermaid
sequenceDiagram
    participant SO as Section Owner (Claude)
    participant Sh as reserve.sh
    participant Yq as yq v4
    participant FS as allocations/ugc-platform.yml
    participant Git as git (this repo)
    participant GH as github.com

    SO->>Sh: ./reserve.sh --resource flyway --section A --epic GDI-720 --id V19
    Sh->>Sh: validate args (section A..J, V<digits>)
    Sh->>Yq: yq -r ".flyway.reserved[].epic" (idempotency check)
    Yq->>FS: read
    FS-->>Yq: existing entries
    Yq-->>Sh: no match for GDI-720 + V19
    Sh->>Yq: yq ".flyway.reserved += {...}"
    Yq->>FS: write
    Sh->>Git: git pull --rebase
    Git->>GH: pull
    Sh->>Git: git add + commit + push
    Git->>GH: push to main
    GH-->>Git: ok (no conflict)
    Git-->>Sh: success
    Sh-->>SO: [INFO] Reserved flyway/V19 for GDI-720 (section A) until ...
```

If the push is rejected (someone else updated `main`), `reserve.sh` re-runs
`git pull --rebase` and retries — up to 3 times.

---

## Sequence: a conflict

```mermaid
sequenceDiagram
    participant SO as Section C
    participant Sh as conflict-check.sh
    participant Yq as yq v4
    participant FS as ugc-platform.yml

    SO->>Sh: ./conflict-check.sh --section C --fr FR-C.1.18 --files-to-touch ModelRegistry.kt
    Sh->>Yq: query single_writer_files where file matches ModelRegistry.kt
    Yq->>FS: read
    FS-->>Yq: {held_by: section-A-FR-A.1.9-epic, until: 2026-05-14T22:00:00Z}
    Yq-->>Sh: result
    Sh->>Sh: held_by != "none" AND not prefixed section-C-
    Sh-->>SO: WAIT file=ModelRegistry.kt held_by=section-A-... until=...
    Note over SO: exit 1 — section pivots or waits
```

---

## Why a file-based registry?

We considered three alternatives:

| Option | Pros | Cons | Decision |
|---|---|---|---|
| **File-based (chosen)** | No infra; git is the audit trail; trivial to validate; trivially recoverable | Sequential commits; ~5-second write latency | Day-1 winner |
| HTTP service (e.g. SQLite-backed Flask) | Faster reads; could enforce ACLs | Requires a deployable; bootstrap cost; another thing to monitor | Phase-2 if needed |
| Postgres + Hasura | Best query power; full RLS | Hugely overscoped for Day 1; we have 1 product | Rejected |

The file-based approach also lets us **see the entire state of the system by reading
one file** — invaluable during incidents.

---

## Atomicity guarantees

Each script's effective transaction is:

```
1. git pull --rebase           (fail → retry)
2. yq edit + write              (always succeeds locally)
3. git add + commit             (always succeeds locally)
4. git push                     (fail → goto 1, max 3 attempts)
```

This gives us **last-writer-wins** under contention. Lost-update is possible only if
two writers somehow bypass the rebase loop — which the scripts don't do. If you bypass
the scripts and write YAML by hand without rebasing, you can break it; the safeguard is
"only edit via scripts."

The `git pull --rebase` step is critical: it ensures we never lose another session's
write that landed between our last sync and our edit.

---

## Failure modes

| Failure | Detection | Recovery |
|---|---|---|
| `yq` not installed | `require_tools` fails fast | Install yq v4 |
| Push rejected (someone else updated) | Retry loop, max 3 attempts | Automatic |
| Schema violation (e.g. malformed timestamp) | CI catches; local scripts don't | Revert the offending commit |
| Stale reservation past TTL | Manual today; auto-sweep in Phase 2 | Re-reserve, or Coordinator clears |
| Operator edits YAML by hand without rebasing | Future writers' rebase usually fixes; rare lost-update possible | Restore from git history |

---

## Concurrency model

The registry is **single-master** (the `main` branch is the only place state lives).
Concurrent writers serialize via git's push contention; no other coordination is
needed. This is fine for the expected write rate (~5 reserve/release calls per section
per ticket × ~10 sections × ~10 tickets/week = ~500 writes/week; even bursts are
sub-second).

If write volume grows past ~10/second, move to the Phase-2 HTTP service backed by the
same YAML; sessions then read via HTTP, write via HTTP, and the service serializes
internally.

---

## What the YAML schema enforces

`schemas/allocation.yml.schema.json` (JSON Schema draft-07) enforces:

- All 6 top-level sections are present
- Enum values for `status` (no typos like `in-flight` vs `in_flight`)
- ISO-8601 timestamp pattern on `reserved_at`/`expires_at`/`shipped_at`
- Semver pattern on release tags (`vX.Y.Z`, `vX.Y.x`, or `pre-aidlc`)
- Flyway version pattern (`^V\d+$`)
- Section letter pattern (`^[A-J]$`)

What the schema does **NOT** enforce:

- **Cross-references**: the schema can't verify that
  `single_writer_files[].held_by` matches an existing
  `model_registry.pending[].epic` or `flyway.reserved[].epic`. That's a contract,
  enforced by humans + the scripts on the write path.
- **Logical consistency**: nothing stops someone from declaring `V19` both shipped and
  reserved in the same file. The scripts avoid this by construction.

The CI workflow runs the schema on every PR.

---

## Future architecture (Phase 2)

```mermaid
flowchart LR
    subgraph S2["Sessions (read/write via HTTP)"]
        A[Section A]
        B[Section B]
        C[Section C]
    end

    subgraph SVC["Coordinator Service"]
        API[HTTP API]
        Q[Mailbox queue]
    end

    subgraph Store["File store"]
        Y[ugc-platform.yml]
    end

    subgraph TFC["TFC"]
        W[Workspace dev]
    end

    A & B & C -->|GET/POST| API
    API -->|read/write| Y
    Q -->|sequenced applies| W
    API -->|enqueue| Q
```

In Phase 2, the HTTP API becomes the authority for writes; the YAML in this repo is
the durable store; a mailbox queue serializes TFC applies so two sections' deploys
don't race.
