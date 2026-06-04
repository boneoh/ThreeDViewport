# Rotation Path Animator

Generates keyframes that move the selected camera, light, or object along a
**helix / arc / corkscrew** around an axis. Great for orbits, spin-in-place, and
graceful curved moves that are tedious to hand-key.

**Open:** Window ▸ Path Animator ▸ Rotation…

## Workflow

1. **Axis (Probe):** position the [Probe](Probe-Inspector.md) at the axis start →
   **Capture Axis Start**; move it to the axis end → **Capture Axis End**. (Copy /
   paste / zero icons mirror the Probe Inspector, sharing the same clipboard.)
2. **Track & time:** select a camera / light / object lane in the
   [Timeline Editor](Timeline-Editor.md), scrub to the start → **Capture Start**;
   scrub to the end → **Capture End**.
3. **Parameters:** Radius · Start angle (°) · End angle (°) · Revolutions
   (fractional ok) · Keyframes / rev.
4. **Create Keyframes.**

## Geometry

- Angle swept: `Δθ = (end − start) + revolutions·360°`.
- Position: `P(s) = A + s·(B−A) + radius·(cos θ·u + sin θ·v)` for s from 0→1 over
  the time window. `A == B` with a fractional revolution gives a flat **arc**; a
  real axis with whole revolutions gives a **corkscrew**.
- **Aim:** camera and lights aim at a **fixed point** (the axis midpoint); objects
  aim at the **same-height** axis point (so they turn to follow the column as they
  rise). Object −Z is treated as "forward."
- A small radius (e.g. **0.001**) makes an object **spin in place** with no visible
  orbital wobble.

## Notes

- **Create Keyframes** deletes the track's existing keyframes within the captured
  time window and inserts the generated ones.
- Object keyframes **preserve the object's current scale**.
- Camera/light aim points are per-keyframe, so you can nudge them afterwards.

See also: [Linear Path Animator](Linear-Path-Animator.md).
