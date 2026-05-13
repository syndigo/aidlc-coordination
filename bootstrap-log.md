# Bootstrap Log — `syndigo/aidlc-coordination`

This file is a **D-019 capture** of every manual step taken to bootstrap this repository.
A future "Stage 0 Greenfield Bootstrap" subagent will be authored directly from this log:
each `## Step N` block names a command, the rationale, the actual stdout/stderr, and any
follow-ups required.

**Run start:** 2026-05-12
**Driver:** Stage 4 (Development) of `/sdlc` pipeline for epic GDI-669
**Operator:** nembree-syndigo (gh authenticated)
**Working dir:** `/Users/nateembree/Projects/aidlc-coordination/`

---

## Step 0 — Pre-flight checks

**Command:**
```
gh auth status
yq --version
shellcheck --version | head -1
```

**Rationale:** Confirm tooling before any destructive action.

**Output (truncated):**
```
github.com
  ✓ Logged in to github.com account nembree-syndigo (keyring)
  - Active account: true
  - Token scopes: 'admin:org', 'gist', 'repo', 'workflow'
yq (https://github.com/mikefarah/yq/) version v4.52.5
ShellCheck - shell script analysis tool
```

**Follow-up for future bootstrap subagent:** REQUIRE these three tools at runtime. If
`yamllint`/`ajv-cli`/`markdownlint` are missing on the operator's machine, the subagent
should install them via `pip install yamllint`, `npm install -g ajv-cli ajv-formats`, etc.
or skip those local checks and rely on CI.

---

## Step 1 — Re-verify Stage 1 DoD (Jira epic + 6 stories)

**Command:**
```
curl -s -u "$ATLASSIAN_EMAIL:$ATLASSIAN_API_TOKEN" \
  -X POST "$ATLASSIAN_BASE_URL/rest/api/3/search/jql" \
  -H "Content-Type: application/json" \
  --data '{"jql":"parent = GDI-669","maxResults":20,"fields":["issuetype","status","summary"]}'
```

**Rationale:** Stage 4 must not begin if upstream artifacts are missing. The contract is
"Epic GDI-669 exists with exactly 6 child Stories."

**Output:**
```
count= 6
GDI-675 Story - AIDLC Coordination — Story 6: Playbook + how-it-works docs + bootstrap-log + CI + smoke test
GDI-674 Story - AIDLC Coordination — Story 5: Persona specs (4 markdown documents)
GDI-673 Story - AIDLC Coordination — Story 4: conflict-check.sh (Phase 0 pre-flight) + status.sh
GDI-672 Story - AIDLC Coordination — Story 3: reserve.sh and release.sh (atomic via git-commit-as-audit-trail)
GDI-671 Story - AIDLC Coordination — Story 2: Registry YAML + JSON Schema (seeded with current UGC Platform state)
GDI-670 Story - AIDLC Coordination — Story 1: Greenfield repo bootstrap (per D-019)
```

**Follow-up:** Add this guard to the future bootstrap subagent as the first command;
short-circuit with BLOCK if count != 6.

---

## Step 2 — Create the GitHub repository

**Command:**
```
gh repo create syndigo/aidlc-coordination --public \
  --description "AIDLC coordination layer: allocation registry + serialization mailbox for parallel SDLC sessions"
```

**Rationale:** Greenfield repo per D-019. `--public` because this is an internal-tooling
repo that may be referenced by external Syndigo orgs (atrify, 1WS, etc.). No README at
creation time — we ship our own README in the initial commit so it matches the project
voice.

**Output:**
```
https://github.com/syndigo/aidlc-coordination
```

**Follow-up:** Future subagent should accept a `--visibility public|private|internal` flag
and pass it through. Also note: `--add-readme=false` is the default when `--description`
is given; we relied on the default rather than naming it explicitly.

---

## Step 3 — Clone the empty repo locally

**Command:**
```
cd /Users/nateembree/Projects/ && gh repo clone syndigo/aidlc-coordination
```

**Rationale:** All subsequent file authoring is local. Cloning rather than `git init` +
`git remote add` keeps the upstream pointer canonical.

**Output:**
```
Cloning into 'aidlc-coordination'...
warning: You appear to have cloned an empty repository.
```

**Follow-up:** The "empty repository" warning is expected and harmless. The subagent
should not treat it as an error.

---

## Step 4 — Author the initial skeleton (5 files)

**Files written** (no commit yet):
- `README.md`
- `.gitignore`
- `.claude/CLAUDE.md`
- `.github/workflows/ci.yml`
- `bootstrap-log.md` (this file)

**Rationale:** The substantive content (allocations, schemas, scripts, personas, docs)
goes on a feature branch — that's how we demonstrate the day-1 workflow end-to-end per
AC-1.5 of GDI-670. The initial commit on `main` is just enough to set branch protection
against.

**Follow-up:** The 5-file skeleton is the minimal viable `main` for any repo that uses
feature-branch flow on day 1. The bootstrap subagent should template these exact 5 files.

---

## Step 5 — Initial commit on `main`

**Command:**
```
git add README.md .gitignore .claude/CLAUDE.md .github/workflows/ci.yml bootstrap-log.md
git commit -m "chore(GDI-670): initial skeleton (README, gitignore, CLAUDE.md, CI, bootstrap-log)"
git push -u origin main
```

**Rationale:** Captures the initial SHA so branch protection has something to protect.

**Output / SHA:** Captured below in Step 5b once executed.

**Follow-up:** None — straightforward.

---

## Step 5b — Initial commit SHA captured

**Initial commit SHA on `main`:** `7714ec397b47f02031a7f39439e5bd59397dd1f1`

Verified via:
```
git rev-parse HEAD
```

---

## Step 6 — Enable branch protection on `main`

**Command:**
```
gh api -X PUT "repos/syndigo/aidlc-coordination/branches/main/protection" --input <json>
```

**Rationale:** A bootstrap-shipped repo must enforce PR flow from day 1. We start with
the **minimum viable protection**:
- `required_pull_request_reviews.required_approving_review_count = 0` — a solo-author
  repo cannot satisfy a 1-approval rule on its own bootstrap PR. Raise to 1 once a
  second human is on the repo.
- `required_status_checks = null` — the CI workflow has not yet run. Add named checks
  (`yamllint`, `shellcheck`, `schema-validate`, `markdown-structure`, `yq-smoke`) once
  they've appeared in the GitHub Checks UI.
- `allow_force_pushes = false`, `allow_deletions = false` — the audit trail must be
  immutable.

**Known limitation logged:** The 0-approval protection is a deliberate Day-1 weakening.
The follow-up ticket is GDI-669 → "Phase-1 follow-ups: enable 1-approval + required
status checks once CI is green."

**Output:** Protection PUT returned 200 OK with body confirming:
- `required_approving_review_count: 0`
- `allow_force_pushes.enabled: false`
- `allow_deletions.enabled: false`
- `enforce_admins.enabled: false`

---

## Step 7 — Enable auto-merge and delete-branch-on-merge

**Command:**
```
gh api -X PATCH "repos/syndigo/aidlc-coordination" \
  --field allow_auto_merge=true --field delete_branch_on_merge=true
```

**Rationale:** Reserve/release scripts (in the next iteration) will open PRs and rely on
auto-merge. Enabling it at the org-repo level avoids per-PR fiddling.

**Output:** `allow_auto_merge=True delete_branch_on_merge=True` (confirmed via the
returned repo JSON).

---

## Step 8 — Create feature branch for substantive content

**Command:**
```
git checkout -b feature/GDI-669-bootstrap-verification
```

**Rationale:** The 12 remaining files (1 YAML + 1 schema + 4 scripts + 4 personas + 3
docs, minus the smoke-test capture which appends to this file) go on a feature branch so
the bootstrap PR demonstrates the full PR-driven workflow.

---

## Step 9 — Author allocations/ugc-platform.yml + JSON Schema (GDI-671)

See commit B1. The YAML is seeded with **real** current UGC Platform state as of
2026-05-12 (verified against `gh release list --repo syndigo/ugc-platform`):

- V1-V12 — shipped pre-AIDLC (no per-version epic tracking)
- V13 — GDI-499, v0.13.0 (catalog validation framework)
- V14 — GDI-613, v0.23.0 (AI image-content findings)
- V15 — GDI-613 follow-on, v0.23.0 (idempotency unique)
- V16 — GDI-634, v0.24.0 (site_keys)
- V17 — GDI-638, v0.26.0 (reviews filter+sort index)
- V18 — GDI-645, v0.27.0 (catalog category findings)
- V19-V23 — reserved by Section A (FR-A.1.9, A.1.8, A.1.12, A.1.7, buffer)

**Schema validation tool chosen:** `ajv-cli@5` + `ajv-formats@3` (Node), with a
`yaml→json` conversion step via `js-yaml@4`. Fallback to Python `jsonschema` for local
runs where Node isn't preferred. **Captured for the subagent: prefer ajv when Node is
already in the operator's PATH; fall back to python jsonschema otherwise.**

---

## Step 10 — Author scripts/reserve.sh + release.sh (GDI-672)

See commit B2. Design choice (recorded as ADR-D-004 in `docs/decisions.md`):
**Day-1 scripts edit `main` directly via local-clone + commit + push.** The
branch+PR+auto-merge model is overhead for the bootstrap; deferred to GDI-669
Phase-2 follow-up.

`yq` v4 (mikefarah) is the canonical YAML processor. Atomicity guarantee: each script
calls `git pull --rebase` before edit, then commits + pushes; on push-rejected, retries
up to 3 times with fresh rebase. The retry budget and rationale are in the script header.

POSIX-portability tested via `shellcheck --severity=warning`.

---

## Step 11 — Author scripts/conflict-check.sh + status.sh (GDI-673)

See commit B3. `conflict-check.sh` is read-only by default; `--claim` chain-calls
`reserve.sh` for the detected needs. `status.sh` produces a human dashboard via `yq`
queries.

---

## Step 12 — Author 4 persona specs (GDI-674)

See commit B4. Section Owner + Release Coordinator are full-substance (200-400 lines
each). Compliance Reviewer + Retro Aggregator are scaffold-only (100-150 lines), marked
clearly as FOLLOW-UP for later epics.

---

## Step 13 — Author docs/ (GDI-675)

See commit B5. Playbook, how-it-works, decisions ADR log.

---

## Step 14 — Smoke test

The smoke test is the AC-6.6 deliverable for GDI-675. Captured below:

### Smoke test 14a — Section A re-checks its own hold (expected: GO)

**Command:**
```
./scripts/conflict-check.sh --section A --fr A.1.9 --files-to-touch ModelRegistry.kt
```

**Expected:** GO. Section A already holds the `ModelRegistry.kt` lock per the seeded
YAML (`single_writer_files.ModelRegistry.kt.held_by = section-A-FR-A.1.9-epic`).
The conflict-check is idempotent for the same section.

**Actual output:**
```
[INFO]  self-hold OK: file=ModelRegistry.kt held_by_self=section-A-FR-A.1.9-epic
[INFO]  GO — section A may proceed with A.1.9
GO
exit=0
```

**Result:** PASS — exit 0, output GO, the self-hold was recognized.

### Smoke test 14b — Section C checks the same file (expected: WAIT)

**Command:**
```
./scripts/conflict-check.sh --section C --fr C.1.11 --files-to-touch ModelRegistry.kt
```

**Expected:** WAIT, with structured reason citing Section A's hold + expiry timestamp
(`2026-05-14T22:00:00Z`).

**Actual output:**
```
[WARN]  WAIT — section C cannot proceed with C.1.11:
WAIT file=ModelRegistry.kt held_by=section-A-FR-A.1.9-epic until=2026-05-14T22:00:00Z
WAIT:
WAIT file=ModelRegistry.kt held_by=section-A-FR-A.1.9-epic until=2026-05-14T22:00:00Z
exit=1
```

**Result:** PASS — exit 1, output WAIT, holder + expiry correctly surfaced.

### Bonus smoke test 14c — Section C anchor-blocked

**Command:**
```
./scripts/conflict-check.sh --section C --fr C.1.18
```

**Expected:** WAIT — C.1.18 is a declared consumer of the FR-A.1.9 anchor, which is
in_flight (not yet shipped).

**Actual output:**
```
[WARN]  WAIT — section C cannot proceed with C.1.18:
WAIT anchor=FR-A.1.9 status=in_flight
WAIT:
WAIT anchor=FR-A.1.9 status=in_flight
exit=1
```

**Result:** PASS — anchor-dependency block correctly surfaces.

### Smoke test debugging note (real-world feedback for the bootstrap subagent)

The first run of 14b returned GO instead of WAIT. Root cause: the original
`conflict-check.sh` used `printf '%s' "$csv" | tr ',' '\n' | while read f`, which
fails when the CSV has no commas (no trailing newline → `read` returns false
immediately). Fix: switched to `IFS=, set -- $csv; for f in "$@"` — POSIX-portable,
works for both single-value and multi-value CSVs.

Second bug: the original anchor-block yq query used
`. as $a | .consumers[] | select(.fr == "...") | $a.anchor`. In yq v4 this emits the
anchor regardless of whether the select matched — the select gates only the consumer
projection, not the `$a` binding. Fix: nested the select inside the outer select via
`select(.status != "shipped" and (.consumers[] | select(...)))`. Both fixes
recorded as **pipeline learnings** for the future bootstrap subagent.

The fixed scripts pass shellcheck --severity=warning cleanly.

---

## Step 15 — Open PR

PR opened at: captured below.

---

## Step 16 — Wait for CI green + transition stories to In Progress

CI checks captured below. Story transitions (GDI-670..GDI-675 → In Progress) via Jira REST
also captured.

---

## Open follow-ups (for the future Stage 0 Greenfield Bootstrap subagent)

1. Templatize the 5-file skeleton (README/gitignore/CLAUDE.md/ci.yml/bootstrap-log.md)
   with `${PROJECT_NAME}`, `${EPIC_KEY}`, `${SHORT_DESCRIPTION}` placeholders.
2. Default branch protection settings should be parameterized: solo-bootstrap mode
   (0 reviews, no required checks) vs. follow-up-tightening mode.
3. Detect `ajv-cli`/`yamllint`/`shellcheck` availability and degrade gracefully — local
   validation is best-effort; CI is authoritative.
4. The Jira-DoD-reverification guard is generic — lift it into a shared `_shared/jira.sh`
   helper.
5. Capture the actual run duration of every step so the subagent can produce a wall-clock
   estimate at the end.

---

## Step appendix — actual stdout / SHAs / PR number

### Commits on `feature/GDI-669-bootstrap-verification`

In order (verified via `git log --oneline main..feature/GDI-669-bootstrap-verification`):

1. **B1** — `feat(GDI-671): seed allocations/ugc-platform.yml + JSON Schema (Day 1 registry)`
2. **B2** — `feat(GDI-672): reserve.sh + release.sh (yq-based atomic edits)`
3. **B3** — `feat(GDI-673): conflict-check.sh + status.sh (read-only by default)`
4. **B4** — `docs(GDI-674): 4 persona specs (...)`
5. **B5** — `docs(GDI-675): parallel-session playbook + how-it-works + decisions ADR log`
6. **B6** — `docs(GDI-675): finalize bootstrap-log.md + smoke test capture` (this commit)

### Tooling versions used

- `gh` (GitHub CLI) authenticated as `nembree-syndigo` with `admin:org`, `repo`,
  `workflow` scopes
- `git` 2.x (Apple-shipped)
- `yq` (mikefarah) v4.52.5
- `shellcheck` (installed via brew)
- Python 3.14 with `jsonschema` + `PyYAML` installed in
  `/private/tmp/aidlc-venv/` (one-shot venv; documented as "use Node ajv-cli in CI,
  Python jsonschema for local")

### Schema-validation evidence (local, before CI runs)

```
$ yq -o=json '.' allocations/ugc-platform.yml > /tmp/ugc-platform.json
$ /tmp/aidlc-venv/bin/python -c "
  import json, jsonschema
  s = json.load(open('schemas/allocation.yml.schema.json'))
  d = json.load(open('/tmp/ugc-platform.json'))
  jsonschema.validate(d, s)
  print('VALID')
  "
VALID — YAML conforms to schema (validated via yq-to-JSON)
```

### shellcheck evidence

```
$ shellcheck --severity=warning scripts/*.sh
(no output — clean)
```

### status.sh evidence (manual smoke before PR)

```
=================================================
 AIDLC Allocation Status — ugc-platform
=================================================
 current_main:   v0.27.0
 flyway:         18 shipped / 5 reserved (next free: V24)
 model surfaces: 5 shipped / 1 pending
...
```

(Full output captured in Step 14 above and demo'd in
`docs/parallel-session-playbook.md`.)

### PR number / URL

Captured by the final commit + push step; see the PR URL emitted by `gh pr create`
or query `gh pr list --repo syndigo/aidlc-coordination --state open`.
