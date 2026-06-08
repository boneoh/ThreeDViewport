# Glue (Envelopes)

**Glue** binds two or more objects into a single unit that moves and animates
together. It creates an **envelope** — a geometryless "null" node that the members
parent to. Move or keyframe the envelope and the whole unit follows; select a
single member and it still moves on its own *within* the unit.

It's the general-purpose version of camera-follow: instead of one camera tracking
one object, any group of objects rides a shared parent.

**Open:** Edit ▸ Glue Objects…

## Create a glue

1. Load the objects you want to bind.
2. **Edit ▸ Glue Objects…** opens a dialog listing every top-level object.
3. **Check** the objects to bind (two or more).
4. Pick the **Anchor** — the envelope's origin/pivot is placed at this object's
   position, so rotations of the unit pivot around it.
5. Give the envelope a **Name** and click **Glue**.

Nothing moves when you glue — each member's current position is frozen relative to
the envelope, so the unit looks identical until you animate it.

## Move and animate the unit

- The envelope is a selectable **root object**: cycle to it with **O**, or click
  its lane in the [Timeline Editor](Timeline-Editor.md).
- With the envelope selected, drag / arrow-key / use the
  [Model Inspector](Model-Inspector.md) — the whole unit moves and rotates around
  the anchor.
- **Keyframe the envelope** (stamp with **I**, or use the
  [Orbit Path Animator](Orbit-Path-Animator.md)) to animate the unit as one.
- The envelope appears as a target everywhere a root object can — the
  [Camera](Camera-Panel.md) **Follow Target**, and the
  [Spin](Spin-Path-Animator.md) / [Orbit](Orbit-Path-Animator.md) Path Animator
  **Target** dropdowns — so the whole unit can be followed, spun, or orbited.

## Animate a single member

After gluing, a member is no longer a viewport-cycleable root — **select it from
its lane in the [Timeline Editor](Timeline-Editor.md)**. From there you can move it,
keyframe it, or give it its own [Spin](Spin-Path-Animator.md). A member's own
animation **composes on top of** the envelope's, so e.g. B can orbit A (envelope
keyframes) while spinning on its own axis (B's own keyframes).

## Unglue

Select the envelope and choose **Edit ▸ Unglue** (or remove it via Edit ▸ Remove).
Members become independent again, keeping their current positions — nothing jumps.

## Export the glued unit as a model

Select the envelope and choose **File ▸ Export Glued Model…** to write the whole unit
(every member's geometry, flattened by its glued transform, with PBR materials and
textures) as a single reusable **.glb**. Re-import it as one object to assemble bigger
scenes from sub-assemblies. The command is enabled only when an envelope is selected.

## Example: B orbits A *and* spins

1. Glue B to A with **A as the anchor**.
2. Select the **envelope** and use the [Orbit Path Animator](Orbit-Path-Animator.md)
   → the pair orbits, so B circles A.
3. Select **B's lane** in the Timeline Editor and use the
   [Spin Path Animator](Spin-Path-Animator.md) → B spins on its own axis.
4. Play — B orbits A while spinning, both smooth.

## Notes & current limits

- **Saved with the project** — envelopes, membership, the envelope's transform, and
  its keyframes all persist.
- **One-time bind:** to change membership, unglue and re-glue (no add/remove yet).
- **Models only** for now — lights and effects can't be glued.
- **Glue first, then keyframe a member.** A track that already exists on an object
  *before* gluing is reinterpreted relative to the envelope; add member animation
  after gluing for predictable results.
- Nested envelopes (gluing a unit into a larger unit) are supported by the
  transform system but not yet exposed in the Glue dialog.

See also: [Orbit Path Animator](Orbit-Path-Animator.md) · [Spin Path Animator](Spin-Path-Animator.md) · [Timeline Editor](Timeline-Editor.md).
