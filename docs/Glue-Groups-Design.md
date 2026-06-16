# Design: Gluing Multi-Part Models (Group ↔ Envelope)

Status: **proposal, not built.** Supersedes the reverted 2026-06-16 auto-glue attempt
that corrupted projects.

## The problem

Two separate "grouping" mechanisms exist and don't currently coexist:

- **Group** = a multi-part model from one `.glb`. All its parts share one `groupID`.
  The model's placement is `groupTransforms[gid]`; each part renders as
  `groupTransforms[gid] × part…`. **Invariant:** one group = one `groupID` = **one
  `modelPath`**, and on load the group is rebuilt by re-loading that single path and
  matching the saved per-part data. Groups round-trip cleanly.
- **Envelope** = the "Glue" container: a geometry-less object that parents member
  *objects* via `parentIndex`; a member renders as `envelope.transform ×
  member.localTransform`.

**Conflict:** an envelope parents individual objects. A multi-part model's parts can't
individually become envelope members:
- If glue *dissolves* the group (clears `groupID`), each part becomes a loose object
  with its own `modelPath` → on reload each path re-expands the whole multi-part glb →
  **phantom groups + lost keyframes** (the corruption we hit).
- If a part keeps both `groupID` *and* `parentIndex`, the state doesn't round-trip and
  the renderer has no defined precedence.

## Goal

Glue Objects (and Import-then-glue) should let a multi-part **model** be part of a
glued unit while:
1. preserving the model's internal structure **and** per-part keyframes,
2. keeping correct scale/position,
3. round-tripping cleanly through save→load (no phantom groups, no lost keyframes),
4. being reversible (Unglue restores the model standalone).

## Proposed model: an envelope can contain a GROUP as a first-class member

Instead of dissolving groups, let an envelope hold **group members** alongside object
members. A group member keeps everything it has today (groupID, parts, group transform,
single `modelPath`, per-part keyframes) and merely gains a parent link.

**Runtime / render.** Each frame, for a group whose envelope parent is set:
`groupTransforms[gid] = envelope.transform × groupLocalTransform`
(captured at glue time so nothing moves). Parts then render as usual, so moving/
animating the envelope moves the whole model while its internal animation still plays.
Envelope transforms are computed before composing their enveloped groups.

**Data model.** Extend the envelope's membership: besides `memberIndices` (objects),
add **group members** as `{ groupKey, localTransform }`, where `groupKey =
(sourceFileName, occurrence)` — the same key groups already round-trip by. Runtime link
held on `SceneManager` (`groupEnvelopeParent: [gid: (envIndex, localTransform)]`).

**Save / load.** Persist `memberGroups` on each envelope. Groups still save as one
`modelPath` each (invariant preserved — **no flattening, no clearing groupID**). On
load: after objects + groups are reconstructed, resolve each envelope's `memberGroups`
by `groupKey → gid` and set the runtime parent link.

**Glue UI (#1).** A multi-part model shows as **one** candidate (the group). Selecting
it adds the group as a *group member* (not flattening). Ungrouped objects → object
members as today. `makeEnvelope` gains group members; for each it captures
`groupLocalTransform = inverse(envT) × currentGroupWorld`.

**Import auto-glue (#2).** After import, build the envelope over the imported objects +
imported groups via the new path. Round-trip safe.

**Unglue.** For group members, bake the envelope transform back into the group's
standalone transform and clear the parent link; object members as today.

## Phasing

- **A. Foundation** — data model + render + save/load for envelope-contains-group. Prove
  the round-trip with a hand-built test (import Frangle, glue, save, reload → identical).
- **B. Glue UI** — group as a single candidate → group member.
- **C. Import auto-glue** — rebuilt on the foundation, default-on toggle.

## Key risks / tests

- **Round-trip is make-or-break.** Test: New project → Import "Red and Blue Frangle"
  (which contains a nested `2-buckys-cylinder` group) → Glue → Save → Open. Timeline must
  be identical, child keyframes intact, scale correct.
- **Nested envelopes.** The Frangle source may itself contain an envelope; ensure
  envelope-of-group and (if present) envelope-of-envelope both round-trip.

## Alternatives considered (rejected)

- **Flatten group → loose objects on glue.** Breaks the one-group/one-`modelPath`
  invariant (reload re-expands each path) and loses per-part keyframes. *This caused the
  corruption.*
- **Merge heterogeneous models into one group spanning multiple `.glb`s.** Requires
  groups to support multiple `modelPaths` — a larger save/load change than
  envelope-contains-group.
