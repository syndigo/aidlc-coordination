# Persona: Compliance Reviewer

> **Status:** **FOLLOW-UP — scaffold only.** This persona is not active on Day 1.
> The substantive implementation is deferred to a follow-up epic
> (provisional: GDI-Compliance-001) once the Day-1 registry has been in production for
> at least two ship cycles.

## Identity (intended)

The **Compliance Reviewer** is an automated gate that fires on every PR that touches a
**single-writer file** (`ModelRegistry.kt`, `Prompts.kt`, `decisions.md`) or claims a
new **anchor surface**. It verifies that the PR:

1. References an active reservation in the allocation registry (i.e. the section's
   `held_by` is set on the file or the surface is in `model_registry.pending` for that
   section's epic).
2. Has a corresponding Jira ticket in the expected status (In Progress or Ready for
   Code Review).
3. Has an updated `decisions.md` ADR entry if the change touches an anchor surface or
   introduces a new model registry surface.
4. Has not exceeded the reservation TTL.

If any check fails, the Reviewer posts a blocking PR comment with the structured reason
and a remediation hint.

## Scope (intended)

**Touches:**

- PR comments on the product repo
- Read-only access to this registry
- Read access to Jira (for ticket status)

**Does NOT touch:**

- The registry YAML
- Any code in the product repo

## How it will work (Phase 2 design sketch)

GitHub webhook on `pull_request.opened` and `pull_request.synchronize` →
`compliance-reviewer` Lambda (or GitHub Action) →
- Diff the PR; identify files touched
- For each file in `single_writer_files`, look up `held_by` in `aidlc-coordination`
- Resolve the section + epic from the PR's branch name (`feature/GDI-XXX-...`)
- If mismatch: post `❌ Compliance: this PR touches ModelRegistry.kt but no active
  reservation exists in aidlc-coordination for GDI-XXX. Run `reserve.sh` first.`

## Why deferred

On Day 1 we have **one team** running sections, and the script-based registry is itself
new. Forcing a compliance gate immediately would frustrate engineers before they trust
the gate. The plan is:

1. Day 1: Section Owners run reservations voluntarily; Release Coordinator audits at
   tag-cut time.
2. After 2 ship cycles: review false-positive rate of an *advisory* (non-blocking) gate.
3. After advisory gate is reliable: promote to blocking, with override doc.

## Triggers for activating this persona

- ≥ 1 incident where an unreserved edit to `ModelRegistry.kt` collided with a different
  section's in-flight work
- The number of sections grows past 5 (today: 1 active section running)
- A Section Owner specifically requests the gate to defend their reservation

## Anti-patterns (when this persona is activated)

- **Blocking PRs without a clear remediation hint.** The comment must say exactly which
  script to run.
- **Failing closed when the registry is unreachable.** Better to log and pass than to
  block on infrastructure flakiness.
- **Re-running on every commit push.** Once a PR is approved, skip re-checking unless
  a `single_writer_file` was touched in the new push.
