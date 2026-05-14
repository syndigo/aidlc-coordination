I want you to start Pillar {{PILLAR_LETTER}} work for the {{PRODUCT}} project on this tab.
There are {{PARALLEL_PILLARS}} parallel /sdlc tabs already active against the same product,
so coordination matters from the first command.

## Read these first, in order

1. /Users/nateembree/Projects/.claude/CLAUDE.md — global conventions (testing, docs, TS,
   accessibility, code quality, DB/RLS, API design, git workflow).

2. /Users/nateembree/Projects/powerreviews/CLAUDE.md — UGC Platform project conventions
   (repo, secrets, stack, multi-tenancy, AIDLC discipline, SDLC pipeline discipline).
   Note: the planning home lives in /Users/nateembree/Projects/powerreviews/, but the actual
   product repo is at {{LOCAL_REPO_PATH}} — most sibling tabs are running there.

3. /Users/nateembree/Projects/powerreviews/gameplan.md — read §1 (Goals), §2 (Workstream Map),
   §8 through §8.8 (recent status snapshots — they document what just shipped today across
   parallel tabs, what coordination gaps surfaced, and how each was fixed), and §10's
   Section {{PILLAR_LETTER}} FR table.

4. /Users/nateembree/Projects/powerreviews/decisions.md — at minimum D-022 (UI in every section)
   and D-024 (spec alignment + AI as cross-cutting). The §2.5 AI cross-cutting framing matters
   for any AI FR in your pillar.

## The AIDLC coordination substrate

This project runs a file-based coordination registry at /Users/nateembree/Projects/aidlc-coordination
to prevent parallel-tab collisions on shared resources (Flyway versions, single-writer files like
ModelRegistry.kt and Prompts.kt, release tags). Before you start any work, run:

    cd /Users/nateembree/Projects/aidlc-coordination && git pull --rebase
    ./scripts/status.sh
    ./scripts/pillar-status.sh --letter {{PILLAR_LETTER}}
    ./scripts/portfolio-status.sh

That tells you what every other tab is currently holding, what your pillar's backlog looks like,
and where the cross-pillar critical path sits. Then for each resource you intend to touch, call
./scripts/conflict-check.sh and ./scripts/reserve.sh. For your worktree, use
./scripts/worktree.sh add — it creates an isolated git worktree at /tmp/aidlc-worktrees/
{{PRODUCT}}-<EPIC> so sibling tabs can't trample your branch (GDI-728 lesson — read
docs/lessons-from-GDI-708.md in that repo for the full backstory). When you're done, call
./scripts/release.sh --update-pillars-block --fr <FR-X.Y.Z> at Stage 10 (D-016 hooks update
the pillar block, anchor status, and prune in_flight automatically) and ./scripts/worktree.sh
remove.

For deep context on the coordination gaps that produced this discipline, read:
/Users/nateembree/Projects/aidlc-coordination/docs/lessons-from-GDI-708.md
/Users/nateembree/Projects/aidlc-coordination/reports/contention-audit-2026-05-14.md
/Users/nateembree/Projects/aidlc-coordination/docs/orchestration-tiers.md

## The /sdlc skill

Dispatch via:

    /sdlc --profile {{PRODUCT}} GDI-XXXX

The skill drives the full 14-stage pipeline (Initiation → Planning → Design → Development →
Build → CI Pipeline → Test → Deploy → Release → Close → Session Doc → Loom Ingest →
Retrospective → Post-Deploy Ops). The profile at ~/Projects/aidlc/shared/profiles/{{PRODUCT}}.yml
sets the deploy method (GitHub Actions → repository_dispatch → global-devops-infra → TFC Stack
→ EKS), coordination opt-in (enabled), and all the conventions. The dev URL is
https://ugc-api.dev.syndigo-devops.com.

Important known issues live in the profile under known_issues — Flyway sibling-tab races
(GDI-786 fix is live: spring.flyway.out-of-order=true on dev), worktree-per-session discipline
(GDI-728), the release-tag race that has fired 5+ times today (file Stage 9 manually with the
next free tag — see scripts/next-tag.sh from GDI-778), and the TFC opaque-error pattern (TFC
web UI has real errors when the API returns null).

## What Pillar {{PILLAR_LETTER}} is

Pillar {{PILLAR_LETTER}} — {{PILLAR_NAME}}. {{PILLAR_SCOPE}}

Current state per the coordination registry:

- **Backlog** ({{FR_BACKLOG_COUNT}} FRs): {{FR_BACKLOG_LIST}}
- **In flight right now**: {{IN_FLIGHT_FRS}}
- **Already shipped from this pillar**: {{SHIPPED_FRS_COUNT}}

{{ANCHOR_RELEVANCE_BLOCK}}

See the spec at `ugc-platform-functional-spec-final (1).md` (in the project planning home) and
§10's {{PILLAR_LETTER}} subsection in gameplan.md for the full FR table.

## What other pillars are doing right now

{{ACTIVE_LOCKS_BLOCK}}

{{RECENT_SHIPS_BLOCK}}

This matters for two reasons. First, if a sibling tab is holding a single-writer file
(ModelRegistry.kt, Prompts.kt, ModelRegistryTest.kt) and your FR needs to touch it, you'll
queue — pick an FR that doesn't need that lock, or wait. Second, the recent-ships list tells
you which patterns just landed and are safe to copy in your own work.

## How to start

1. Confirm your understanding of Pillar {{PILLAR_LETTER}} scope by reading §10
   Section {{PILLAR_LETTER}} in gameplan.md and the spec.
2. Coordinator check-in: `./scripts/status.sh` + `./scripts/pillar-status.sh --letter {{PILLAR_LETTER}}`.
3. Propose your first FR pick to me with a one-paragraph rationale (why this one, why now,
   what it unblocks).

   <!-- ORCHESTRATOR NOTE: The renderer can list backlog but cannot pick the right opener.
        Read the spec; consider what gates the AI tier; pick the smallest genuinely-independent
        foundational FR. Mirror prior-pillar opening patterns where applicable (e.g., FR-D.1
        opened Section D as GDI-709 / v0.32.0 — non-AI, gives the substrate the AI tier needs). -->

4. Wait for my approval, then create the Jira epic and dispatch /sdlc.

Don't dispatch /sdlc until I've approved the FR pick. The choice of opening FR sets the pattern
for the whole pillar.
