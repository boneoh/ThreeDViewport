# Spin Path Animator

Generates a constant, **wobble-free self-spin** for the selected object — evenly
spaced rotation keyframes about the object's **own local X / Y / Z axis**. The
object spins **in place** (its position and scale are untouched), so the spin
composes cleanly on top of any motion the object already has — including riding a
[glued](Glue.md) envelope's orbit.

This is the in-place counterpart to the [Orbit Path Animator](Orbit-Path-Animator.md),
which moves an object *around* an external axis.

**Open:** Window ▸ Path Animator ▸ Spin…

## Workflow

1. **Track & time:** select an **object** lane in the
   [Timeline Editor](Timeline-Editor.md), scrub to the start → **Capture Start**;
   scrub to the end → **Capture End**.
2. **Spin:** pick the **Local axis** (X / Y / Z — Y is a top-like spin), set
   **Revolutions** (negative reverses direction), and **Keyframes / rev**.
3. **Create Keyframes.**

## Why it doesn't wobble

- Every keyframe is a **pure-rotation delta** (no translation, no scale) about a
  single, exact axis — so there is no hand-set cross-axis drift that makes an
  object nod or precess.
- The track is set to **linear** easing, so interpolation is `slerp` between
  equal-angle steps — mathematically exact, constant-velocity rotation with no
  spline overshoot.
- With **Keyframes / rev ≥ 3** (steps under 180°), `slerp` always takes the
  correct short arc. **4** is already exact for a clean spin; raise it only if you
  later switch the track to a spline easing.

## Notes

- **Create Keyframes** deletes the object track's existing keyframes within the
  captured time window and inserts the spin, and sets that track to **linear**
  easing.
- The spin starts at angle 0 — the object's current orientation — so there is no
  pop at the start, and whole-number revolutions return to the start orientation.
- **Object tracks only** (self-spin isn't meaningful for cameras or lights).
- The spin is about the object's **local origin (pivot)**. If a model's pivot is
  off-centre the spin will look like a small orbit around that pivot.

## Example: B orbits A *and* spins on its own axis

1. [Glue](Glue.md) B to A (anchor A) to create an envelope (Edit ▸ Glue Objects…).
2. Select the **envelope** and use the [Orbit Path Animator](Orbit-Path-Animator.md)
   to make the pair orbit — B circles A.
3. Select **B's lane** in the Timeline Editor and use the **Spin Path Animator**
   to add B's self-spin.
4. Play — B orbits A while spinning on its own axis, both smooth.

See also: [Orbit Path Animator](Orbit-Path-Animator.md) · [Linear Path Animator](Linear-Path-Animator.md).
