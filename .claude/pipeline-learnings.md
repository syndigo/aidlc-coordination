# AIDLC Coordination — Pipeline Learnings

> Append-only record of lessons learned from `/sdlc` runs against this repo.
> Each entry includes root cause, fix, and a generalizable rule for future runs.

---

## GDI-677 (/sdlc Coordination integration — Phase 0.6 + Stage 10 hooks) — 2026-05-13

### 1. Branch protection vs solo-operator pipelines — Stage 8 friction

**Symptom:** `gh pr merge 77` against `syndigo/aidlc` failed with "the base branch policy prohibits the merge". Branch protection requires 1 approving review and we ran with a single operator. Used `--admin` override to merge. All required CI checks (`lint`, `test`, `sca`, `secrets`) had PASSED cleanly.

**Root cause:** The aidlc repo's branch protection was authored for multi-operator workflows. Solo-operator `/sdlc` runs have no second human reviewer. The current policy forces every solo run to either (a) override with `--admin`, (b) ask a teammate to LGTM, or (c) wait for an automated reviewer that doesn't exist yet.

**Generalize — pipeline-learning GDI-677 #1:**

> The `/sdlc` orchestrator currently assumes the operator can merge their own PRs. Repos with `required_approving_review_count >= 1` on `main` will trip Stage 8 unless the operator has admin rights. Three options for solo-operator-friendly policy:
> 1. Reduce `required_approving_review_count` to 0 on tooling/internal repos (matches the aidlc-coordination repo).
> 2. Configure a bot reviewer (e.g., a dedicated GitHub App that auto-approves on green CI + DoD evidence).
> 3. Document `--admin` as the official solo-operator path with audit logging.

**Codify — orchestrator update (future epic):** `/sdlc` Stage 8 should detect `required_pull_request_reviews.required_approving_review_count > 0` upfront and explicitly tell the operator: "This repo requires N approvals. Continuing will use --admin override. Authorize?" — before any merge attempt. Prevents the surprise mid-pipeline.

**Codify — repo configuration follow-up:** For each repo in scope of `/sdlc`, decide explicitly which policy applies. Document in the platform profile under a new `branch_protection_policy:` field. Filed as follow-up.

### 2. CodeQL summary check stays "pending" indefinitely — Stage 5 noise

**Symptom:** PR #77's `gh pr checks` output showed `CodeQL pending 0` indefinitely. All sub-jobs (`Analyze (actions)`, `Analyze (javascript-typescript)`, `Analyze (python)`) had PASSED individually. CodeQL is NOT in `required_status_checks.contexts` so it didn't block merge.

**Root cause:** GitHub Apps quirk — the `CodeQL` summary check is reported separately from its sub-jobs and never finalizes when run via the recommended `github/codeql-action` workflow pattern. The sub-jobs (which actually do the analysis) finish cleanly but the "summary" line in the gh CLI output stays "pending".

**Generalize — pipeline-learning GDI-677 #2:**

> When Stage 5 sees a CI check in "pending" state, verify whether it's in `required_status_checks.contexts` before treating as a blocker. Use:
> ```bash
> gh api repos/<owner>/<repo>/branches/main/protection --jq '.required_status_checks.contexts'
> ```
> Pending non-required checks are noise, not blockers.

**Codify — Stage 5 dispatch prompt update:** Before BLOCKing on a pending check, the agent should query branch protection to confirm whether the pending check is required. If not required, mark as INFORMATIONAL and proceed.

### 3. ADR-specified decision number was already taken — Stage 4 auto-renumber

**Symptom:** ADD-GDI-677 specified that `decisions.md` should get a new "D-004" entry. Stage 4 agent found that D-001 through D-005 already existed in the file (seeded during GDI-669 bootstrap). The agent correctly renumbered to D-006 to preserve the append-only ordering rule.

**Root cause:** ADD authoring happens before Stage 4 reads the actual decisions.md file. The numbering collision was knowable from Stage 3 if the agent had read decisions.md, but the ADD just specified "D-004" by default.

**Generalize — pipeline-learning GDI-677 #3:**

> When an ADD specifies a new entry in an append-only numbered log (decisions.md, ADR registry, RFC index), Stage 3 OR Stage 4 MUST read the current file head to determine the actual next free number. Don't trust the ADD's number — it was written before the file was inspected.

**Codify — Stage 3 design rule:** When the ADD specifies a numbered append-only log entry, the ADD MUST cite the current head number (e.g., "D-005 is current head; this run adds D-006") rather than guess. Stage 3 agent should read the file as part of design.

**Codify — Stage 4 development rule:** If the ADD specifies a numbered append-only entry and Stage 4 finds the number is taken, renumber to the next free + call it out in the PR body. This run's Stage 4 agent did exactly this correctly.

### 4. M-sized ADD with exact line numbers eliminated Stage 4 discovery time

**Symptom (positive):** Stage 3 ADD identified exact SKILL.md line numbers for Phase 0.6 insertion (~451), Stage 10 sub-step (~1204), state tracker block (~136), and FINAL REPORT section (~1292). Stage 4 went straight to editing — zero exploration time.

**Generalize — pipeline-learning GDI-677 #4:**

> For multi-file orchestrator-prompt or large-config edits, Stage 3 should include line numbers (or robust section anchors) for every insertion point. Cost: ~30 sec of grep during Stage 3. Benefit: Stage 4 avoids 5-15 min of file-discovery time per edit target.

**Codify — Stage 3 design rule:** When ADD specifies edits to a file >500 lines OR with multiple distinct insertion points, the ADD MUST include line numbers for each target. Use `grep -n` output verbatim. Stage 4 verifies the numbers haven't drifted (re-greps before editing).

### 5. ~/.aidlc-coordination/ auto-clone works exactly as designed — first live test

**Symptom (positive):** Stage 8 smoke test scenario started with `~/.aidlc-coordination/` not present on the workstation. The Phase 0.6 protocol's auto-clone step was exercised live for the first time. Cloned cleanly, all scripts ran, all three scenarios (GO, WAIT file-lock, WAIT anchor-dep) produced correct exit codes and parseable JSON.

**Generalize — pipeline-learning GDI-677 #5:**

> The Day-1 design choice in GDI-669 (file-based state machine + git as audit trail) holds up under integration with `/sdlc`. The auto-clone path is now load-bearing — a future regression in script behavior would be caught at Phase 0.6 against any product's registry. No tighter binding needed.

**Codify:** No action — this is informational confirmation that the GDI-669 design works. Reaffirm the file-based approach in any future "should we move to a hosted service?" discussion.

### 6. Profile validation doesn't yet cover the new `coordination:` field

**Symptom:** aidlc's `validate-profiles` CI job passed on PR #77, but the job's underlying schema does NOT yet validate the shape of the `coordination:` block. A malformed `coordination:` field (wrong type for `enabled`, missing `repo_path`, bad regex in `touch_patterns`) would slip through.

**Generalize — pipeline-learning GDI-677 #6:**

> When a `/sdlc` epic adds a new top-level field to the platform profile YAML, the same epic SHOULD update the profile validation schema to cover the new field. Catches malformed profile edits at PR time instead of at Phase 0.6 runtime.

**Codify — Stage 4 development rule:** When `shared/profiles/<product>.yml` gains a new top-level key, Stage 4 MUST also update `scripts/validate-profiles.py` (or wherever the validation lives) to assert the shape of the new key. Filed as a follow-up ticket since it was out of scope for this run.

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
