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

In the [Timeline Editor](Timeline-Editor.md) the envelope renders as a **collapsible
group**: a header row with a **disclosure triangle**, and its members nested
underneath. Expand it and **select a member's lane** to move it, keyframe it, or give
it its own [Spin](Spin-Path-Animator.md). Each member keeps its **own** track (and its
own easing) — unlike a loaded multi-part model, whose parts share one group track.

A member's own animation **composes on top of** the envelope's, so e.g. B can orbit A
(envelope keyframes) while spinning on its own axis (B's own keyframes). You can even
spin each member on a different axis — A in X, B in Y, the envelope C in Z — for
layered, compound motion.

## Edit members (add / remove)

To change what's in an existing unit without rebuilding it, select the envelope and
choose **Edit ▸ Edit Glue Members…**. The dialog lists the current members (checked)
plus any other top-level objects you can add. Check to add, uncheck to remove, then
**Apply**:

- **Added** objects are re-based into the envelope's frame, exactly as if they'd been
  glued originally.
- **Removed** objects re-root in place, keeping their current pose — nothing jumps.
- The envelope keeps its **current pivot** (the anchor is set when you first glue and
  isn't re-chosen here), and you can rename the unit from the same dialog.
- A unit needs **at least two members**; to drop below that, use **Unglue** instead.

## Unglue

Select the envelope and choose **Edit ▸ Unglue** (or remove it via Edit ▸ Remove).
Members become independent again, keeping their current positions — nothing jumps.

## Export the glued unit as a model

Select the envelope and choose **File ▸ Export Model…** to write the whole unit
(every member's geometry, flattened by its glued transform, with material overrides,
[Brightness](Model-Inspector.md#brightness-self-emission), and textures) as a single
reusable **.glb**. Re-import it as one object to assemble bigger scenes from
sub-assemblies.

**Export Model** isn't envelope-only — it exports whatever is selected: a **single
object**, a whole **multi-part model**, or an envelope's subtree. So you can tint a
single shape in the [Model Inspector](Model-Inspector.md) and export it directly,
without gluing first. Each export bakes relative to the selection's own frame and
re-imports auto-normalised at the origin.

> **The export is baked — and the glue cannot be undone.** The glue itself (which
> members belong to the envelope, the anchor, each member's base transform) is a
> ThreeDViewport concept stored **only in the `.3dvp` project file** — the `.glb` format
> has no notion of it, so none of it is exported. A re-imported glued model comes in as an
> ordinary multi-part model — one unit driven as a whole (Model mode, a single group
> track). Its former members are now **parts**, frozen in their glued positions, and there
> is **no Unglue** for them. You can still [Spin](Spin-Path-Animator.md) an individual part
> (it appears in the Spin Target list as `model ▸ part`) and keyframe it from its lane, but
> a part can **no longer be orbited** as an independent object (Orbit writes a world pose
> that only applies to roots/envelopes), nor re-anchored, swapped, or re-glued.
>
> **So always keep the source project.** The `.3dvp` you built the envelope in is the only
> live, editable copy of the glue — archive it alongside the `.glb` and treat the `.glb`
> as a one-way delivery asset. See
> [Advanced ▸ Bake a sub-assembly into a reusable model](Advanced.md#bake-a-sub-assembly-into-a-reusable-model).

Because `.glb` is a standard format, the exported model isn't a dead end — you can open it
in a third-party tool such as **Blender**, edit the geometry, materials, or layout, and
export it again as `.glb` for use back in ThreeDViewport. The original glue relationship
still doesn't come along (it never left ThreeDViewport), but the *model* is fully yours to
refine in whatever pipeline you prefer.

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
- **Membership is editable** via *Edit ▸ Edit Glue Members…* (add/remove without
  ungluing); the **anchor/pivot** is still fixed at glue time — re-glue to change it.
- **Models only** for now — lights and effects can't be glued.
- **Glue first, then keyframe a member.** A track that already exists on an object
  *before* gluing is reinterpreted relative to the envelope; add member animation
  after gluing for predictable results.
- Nested envelopes (gluing a unit into a larger unit) are supported by the
  transform system but not yet exposed in the Glue dialog.

See also: [Orbit Path Animator](Orbit-Path-Animator.md) · [Spin Path Animator](Spin-Path-Animator.md) · [Timeline Editor](Timeline-Editor.md).
