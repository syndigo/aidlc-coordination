# Persona: Release Coordinator

> **Status:** Day-1 substantive.

## Identity

The **Release Coordinator** is the role that owns the *product-wide* release cadence —
cutting tags, managing the deploy queue, sequencing pushes so that no two sections
arrive at `dev` (or `stage`/`prod`) at the same minute. On Day 1, this is the human VP
of DevOps or their delegate; in Phase 2, much of this becomes a Claude skill plus a
TFC-mailbox automation.

There is **one** Release Coordinator per product at a time. They do not own any single
section, but they have visibility across all of them.

## Scope

**What the Release Coordinator DOES touch:**

- `releases.current_main` after a tag is cut
- `releases.next_per_section` when a section's next-version target changes
- `releases.in_flight` (read-only on Day 1; write in Phase 2)
- `tfc_deploy_queue` (currently a stub; future: the sequencing register)
- Cross-section anchor dependencies (see `anchor_dependencies` block)

**What the Release Coordinator does NOT touch:**

- Any section's code in the product repo
- Reserved Flyway versions or model surfaces (those belong to Section Owners)
- The CI workflow definitions
- Compliance gates (that's the Compliance Reviewer's job)

## Lifecycle: per-release loop

A typical loop is "section X tells me they're ready to ship; I cut the tag, watch the
deploy, update the registry."

### Step 1 — Receive a ship signal

The Section Owner messages the Release Coordinator: "Section A is ready to ship
GDI-720 / FR-A.1.9, all CI green, anchor work complete."

### Step 2 — Verify the anchor consumers

If the FR is an anchor, check whether any consumers want to ship in the same window:

```sh
./scripts/status.sh | grep -A 3 "Anchor dependencies"
```

If the consumers are ready, the Coordinator can sequence them into back-to-back tags
(e.g. v0.28.0 anchor, v0.29.0 consumer A, v0.30.0 consumer B) on the same day. If not,
ship the anchor alone and queue consumers later.

### Step 3 — Cut the tag

In the product repo:

```sh
gh release create v0.28.0 --repo syndigo/ugc-platform \
  --title "Pillar A FR-A.1.9 — Locale auto-translation (GDI-720)" \
  --generate-notes
```

### Step 4 — Update the registry

```sh
cd ~/Projects/aidlc-coordination
./scripts/release.sh --resource release-tag --section A \
  --epic GDI-720 --id v0.28.0 --status released

# Bump next per-section target
yq -i '.releases.next_per_section.A = "v0.29.x"' allocations/ugc-platform.yml
git commit -am "chore(release): bump section A next target to v0.29.x"
git push
```

### Step 5 — Notify Section Owners

Post the new `current_main` to the team channel:

```
🚢 ugc-platform v0.28.0 released — Section A FR-A.1.9 (catalog-locale-translation)
   Anchor unblocked: C.1.18, B.1.9, J.5.4 are now eligible to ship.
   next per-section: A=v0.29.x B=v0.29.x (next) C=v0.30.x ...
```

## Concrete example: shipping the FR-A.1.9 anchor + its consumers

The seeded YAML shows FR-A.1.9 in_flight with three consumers
(C.1.18, B.1.9, J.5.4) blocked. The Coordinator's job when A reports "ready":

```sh
# 1. Check the consumers' readiness in Jira (manual today; a query in Phase 2)
curl -s -u "$ATLASSIAN_EMAIL:$ATLASSIAN_API_TOKEN" \
  "$ATLASSIAN_BASE_URL/rest/api/3/search/jql" -X POST \
  -H "Content-Type: application/json" \
  --data '{"jql":"\"FR\" = \"FR-C.1.18\" AND status = \"Ready for ship\""}'

# 2. If C.1.18 is ready: sequence v0.28.0 (anchor) → v0.30.0 (consumer)
# 3. If not: ship v0.28.0 alone, defer v0.30.0

# 4. Update anchor_dependencies to mark FR-A.1.9 = shipped:
yq -i '(.anchor_dependencies[] | select(.anchor == "FR-A.1.9")) |= .status = "shipped"' \
  allocations/ugc-platform.yml

# 5. Unblock consumers:
yq -i '(.anchor_dependencies[].consumers[] | select(.status == "blocked_until_anchor_shipped")) |= .status = "free"' \
  allocations/ugc-platform.yml
```

## Forward-looking notes

In Phase 2:

1. The TFC deploy mailbox automation will read `tfc_deploy_queue.pending_pushes` and
   apply them in order, with a configurable batch window.
2. The Coordinator's tag-cutting will be driven by a `/release-coordinator` skill that
   subscribes to a GitHub `release` event, runs the registry update, and posts the
   Slack notification automatically.
3. Anchor-consumer unblock chains will fan-out to Section Owner channels automatically.

## Anti-patterns (what the Release Coordinator should NEVER do)

1. **Cutting two sections' tags within the same TFC apply window.** Even if each PR is
   clean, the TFC plans can race. Sequence them — minimum 5 minutes between tags during
   the Day-1 manual era.

2. **Updating a section's `epic` or `fr` field.** Those belong to the Section Owner.
   The Coordinator only touches `releases.*`, `tfc_deploy_queue`, and the `status`
   field on anchors (after the section confirms ship).

3. **Re-using a semver tag.** Always increment. If a release is botched, ship v0.28.1
   as the recovery.

4. **Skipping the Section Owner channel ping.** Other sections can't plan if they don't
   know what shipped.

5. **Force-pushing to `main` of any product repo.** Tags must follow the same
   immutability contract as the registry's audit history.

## Hand-off protocol

When the Coordinator goes off-shift (or the role rotates), the hand-off message MUST
include:

- Current `releases.current_main` value
- List of `releases.in_flight` entries
- Any anchors in_flight whose consumers are queueing
- Any TFC deploys that paused mid-flight (Phase 2; not used Day 1)
- Outstanding registry edits that didn't push cleanly (rare; see git log)

In Phase 2 a single `./scripts/status.sh --json` dump satisfies this; on Day 1 it's a
human-readable summary in the team channel.
