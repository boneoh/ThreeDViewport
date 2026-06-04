# Linear Path Animator

Generates keyframes that move the selected camera, light, or object along a
**straight line** between two points — dollies, trucks, fly-throughs.

**Open:** Window ▸ Path Animator ▸ Linear…

## Workflow

1. **Line (Probe):** position the [Probe](Probe-Inspector.md) at the line start →
   **Capture Start Point**; move it to the end → **Capture End Point**. (Copy /
   paste / zero icons share the Probe Inspector's clipboard.)
2. **Track & time:** select a camera / light / object lane in the
   [Timeline Editor](Timeline-Editor.md), scrub to the start → **Capture Start**;
   scrub to the end → **Capture End**.
3. **Parameters:** Keyframes (≥ 2 evenly-spaced points along the line).
4. **Create Keyframes.**

## Behaviour

- Constant velocity along the line — shape acceleration/deceleration with the
  track's [easing](Timeline-Editor.md).
- **Aim (per type):**
  - **Camera & lights** keep their **current orientation** (parallel dolly) — eye
    and target translate together, so the view direction is preserved.
  - **Objects** face the **direction of travel** (−Z aimed down the line).
- **Create Keyframes** replaces the track's keyframes within the captured time
  window. Object keyframes preserve the object's current scale.

> Camera/lights snap to the **start point** at the start time, so frame the camera
> the way you want *before* clicking Create (it captures the current orientation).

See also: [Rotation Path Animator](Rotation-Path-Animator.md).
