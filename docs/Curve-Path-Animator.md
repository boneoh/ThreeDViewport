# Curve Path Animator

Generates keyframes that sweep the selected camera, light, or object along a
**flat spiral arc** — from a start point to an end point, curving *around* an aim
point (the pivot it also looks at). The radius eases from the start's distance to the
end's distance, so the path spirals **in or out** as it goes, all in the plane of the
three captured points.

Use it for arcing reveals, swooping fly-bys, and circular moves that also travel
across the scene — the in-motion cousin of the [Orbit](Orbit-Path-Animator.md)
(a fixed-radius, in-place turntable) and the [Linear](Linear-Path-Animator.md)
(a straight dolly).

**Open:** Window ▸ Path Animator ▸ Curve…

## Workflow

1. **Points (Probe):** position the [Probe](Probe-Inspector.md) and click
   **Capture Start**, **Capture End**, and **Capture Aim** for the three points.
   (Copy / paste / zero icons share the Probe clipboard.)
2. **Target:** pick a camera / light / object from the **Target** dropdown.
3. **Time:** scrub to the start → **Capture Start**; scrub to the end → **Capture
   End** (defaults to `0…last`).
4. **Parameters:** **Keyframes** (≥ 2 evenly-spaced points along the arc) and the
   **Long way around** toggle.
5. **Create Keyframes.**

## Geometry

- The path sweeps from **Start** to **End** around **Aim**, in the plane defined by
  the three points. The radius interpolates from `|Start − Aim|` to `|End − Aim|`, so
  unequal distances spiral the path inward or outward.
- **Long way around** sweeps the long arc (> 180°) the other direction around the
  aim; off takes the short arc.
- **Aim:** camera and lights point at the fixed **Aim** point throughout; objects
  turn to face it (object −Z is "forward").
- All three points are world-space Probe positions, so the curve is laid out in world
  coordinates.

## Notes

- **Create Keyframes** replaces the track's keyframes within the captured time window
  and inserts the arc. Shape acceleration / deceleration with the track's
  [easing](Timeline-Editor.md).
- Start and End must each differ from the Aim point (otherwise there's no radius or
  angle to sweep).
- Object keyframes **preserve the object's current scale**.
- The generated keyframes write a **world** pose, so this is intended for **root**
  objects (cameras, lights, ungrouped models).

See also: [Orbit Path Animator](Orbit-Path-Animator.md) · [Linear Path Animator](Linear-Path-Animator.md) · [Spin Path Animator](Spin-Path-Animator.md).
