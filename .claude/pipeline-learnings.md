# AIDLC Coordination — Pipeline Learnings

> Append-only record of lessons learned from `/sdlc` runs against this repo.
> Each entry includes root cause, fix, and a generalizable rule for future runs.

---

## GDI-669 (Bootstrap — registry + scripts + personas) — 2026-05-13

### 1. yq v4 does NOT support `--arg` (jq's variable-binding flag) — Stage 7 catch

**Symptom:** Stage 7 smoke test of `./scripts/conflict-check.sh --json` produced yq help text on stderr and malformed/empty JSON on stdout. Cause: `_lib.sh:emit_json()` was calling `yq -n --arg key value '...'` — a jq pattern. yq v4 silently rejects `--arg` and prints its own help. Day-1 smoke (without `--json`) worked perfectly; only the forward-looking JSON interface was broken.

**Root cause:** Cross-tool cognitive contamination. yq and jq look similar; their CLI surface diverges in ways that don't error loudly. `--arg` in jq binds a variable for use in the filter expression; yq has no equivalent — string substitution in yq is done via filter-level interpolation (`yq -n '{"k": "'"$VAL"'"}'`) or shell quoting tricks.

**Fix:** Stage 7 remediation commit `e9c9f32` replaced `emit_json()` with pure-bash `printf` + a `json_escape()` helper handling RFC 8259 escapes (backslashes, quotes, tabs, newlines, carriage returns). Pure bash means zero deps and trivial portability. The agent also caught a second related bug in `status.sh --json` (yq v4 requires quoted object keys: `{"file": .file}`, not `{file: .file}`) and fixed both in the same commit.

**Generalize — pipeline-learning GDI-669 #1:**

> When emitting JSON from a shell script, prefer pure-bash `printf` + an RFC-8259 escape helper over invoking yq or jq. Reasons:
> 1. Zero external dependencies (bash + printf are everywhere).
> 2. No cognitive cross-contamination between yq and jq syntaxes.
> 3. Easy to inline-test (`./script.sh --json | python3 -m json.tool`).
>
> Use yq/jq for *transforming* existing JSON/YAML; build new JSON in bash.

**Codify — script convention:** All scripts in `scripts/` that emit `--json` MUST use the `emit_json()` helper in `scripts/_lib.sh` (or a similar pure-bash pattern). The helper takes a key→value map and produces parseable JSON. If you need to call yq inside `--json` paths, use object literal interpolation, not `--arg`.

**Codify — CI gate:** Add a `--json` round-trip test to `.github/workflows/ci.yml`'s `yq-smoke` job:
```yaml
- name: --json round-trip smoke
  run: |
    for s in conflict-check status; do
      ./scripts/$s.sh --section A --files-to-touch ModelRegistry.kt --json | python3 -m json.tool > /dev/null
    done
```
This would have caught the Stage 7 defect at PR time, not at Stage 7 verification.

### 2. D-019 bootstrap-log discipline produces a usable artifact — confirmed

**Observation:** The Stage 4 agent captured 20 D-019 Step blocks in `bootstrap-log.md` covering every gh, git, file, and curl command from repo creation through first green PR. Each entry has the prescribed structure: What / Why / Tool / Surprises / Automation potential / Human judgment.

**Generalize — pipeline-learning GDI-669 #2:**

> The D-019 format is genuinely useful for greenfield bootstrap runs, not just an aspirational ritual. After this run, a future "Stage 0 Greenfield Bootstrap" subagent could be templated from this `bootstrap-log.md` with high fidelity:
> - 11 of 20 steps have "Automation potential: high" — fully scriptable.
> - 6 of 20 steps need "Human judgment: yes" — those become orchestrator prompts.
> - 3 of 20 are pure setup (clone, cd) — boilerplate.
>
> Future greenfield bootstraps in other repos should reuse the D-019 format.

**Codify — bootstrap convention:** Any future SDLC run that creates a new repo MUST include a `bootstrap-log.md` at the repo root, structured per D-019. Stage 4's prompt should reference this convention.

### 3. Per-phase commits in Stage 4 enabled surgical Stage 7 remediation

**Observation:** The Stage 4 agent committed once per story (Phase A through G, 7 commits total). When Stage 7 caught the `--json` defect, the remediation only had to touch `scripts/_lib.sh` and `scripts/status.sh` — both isolated in their original story's commit (Story 4 / GDI-673 / commit `7efebdc`). The fix landed as a clean single follow-up commit `e9c9f32` with no rebase risk.

**Compare to GDI-591 (UGC Platform):** That run nearly lost 30+ min of work to a Stage 4 agent timeout because it had only committed Phase A. After GDI-591, the per-phase pattern was codified as "required for L+ runs" in `ugc-platform.yml`. GDI-638 + GDI-669 confirm the pattern is valuable for M and S runs too.

**Generalize — pipeline-learning GDI-669 #3:**

> Per-phase commits in Stage 4 are valuable beyond timeout protection — they're a *code-review accelerator* AND a *remediation enabler*. For any Stage 4 run with ≥4 files OR ≥2 distinct workstreams, commit per logical phase.

**Codify:** When the `aidlc-coordination` platform profile is authored, `known_issues` should include this rule at stage:4 — strengthen from the UGC Platform version: "recommended for M+, required for L+" → "recommended for ANY Stage 4 with multiple distinct workstreams."

### 4. Stage 7 should test forward-looking interfaces, not just default behavior

**Symptom:** The Stage 4 agent built the `--json` flag (it appears in `--help`) but never tested it. Stage 7 caught the defect because the orchestrator independently exercised `--json` mode as part of the smoke-test protocol.

**Root cause:** Stage 4 prioritized AC coverage (the AC text says "JSON-on-stdout when --json is passed" but doesn't make it a hard test target). The `--json` interface is forward-looking — it's the Coordinator skill's contract, not Day 1's.

**Generalize — pipeline-learning GDI-669 #4:**

> If a feature has forward-looking interfaces (flags / endpoints / contracts described as "for future use"), Stage 7 MUST exercise them anyway. The cost of catching a forward-looking-interface defect now is ~15 min of remediation. The cost of catching it during the next epic (when the consumer is being built) is the entire next epic's wall-clock.

**Codify — Stage 7 spot-check addition:** When the changeset includes a flag, endpoint, or API surface marked as "forward-looking" or "for future use," Stage 7 spot-checks MUST include a successful round-trip of that interface, not just the default path.

### 5. Direct orchestrator verification is appropriate for small surfaces

**Observation:** Stage 7 didn't dispatch a full subagent — the orchestrator ran the smoke tests directly via Bash. The surface was small (4 commands, 4 expected outputs), and dispatching an agent would have added 30s+ of overhead without value.

**Generalize — pipeline-learning GDI-669 #5:**

> For S-sized runs with simple verifiable surfaces (≤ 5 commands, no codebase exploration needed, no complex reasoning), the orchestrator should run Stage 7 directly rather than dispatching a subagent. Stage 7 dispatch is mandatory for M+ runs where the agent needs to inspect file contents, run test suites with coverage, do security analysis, etc.

**Codify — Stage 7 dispatch rule:** S-sized runs MAY run Stage 7 in-orchestrator if the test surface is ≤5 commands AND no static analysis is required. M+ runs MUST dispatch.

---

(future entries above this line)
