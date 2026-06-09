# Orbit Path Animator

Spins the selected camera, light, or object in a **circular orbit** around an axis —
great for turntables, fly-arounds, and graceful circular moves that are tedious to
hand-key.

You drive it with **rate markers**: set an orbit **rate** (revolutions per second),
drop a keyframe, and the target keeps orbiting at that rate until the next marker.
Change the rate by dropping another marker; stop with a marker at rate **0**. The
orbit is **planar** — a constant-height circle (no climb) — so to adjust speed you
just edit a rate instead of re-keying a whole sweep.

> For a corkscrew / spiral that **moves through the scene** (a flat arc that eases
> its radius), use the [Curve Path Animator](Curve-Path-Animator.md). For making an
> object **spin on its own axis** (rotate in place), use the
> [Spin Path Animator](Spin-Path-Animator.md).

**Open:** Window ▸ Path Animator ▸ Orbit…

## Workflow

1. **Axis (Probe):** position the [Probe](Probe-Inspector.md) at the orbit **centre**
   → **Capture Axis Start**; move it along the desired tilt → **Capture Axis End**
   (the same point = a level, world-up orbit). The plane's normal is the
   start → end direction. (Copy / paste / zero icons share the Probe clipboard.)
2. **Target:** pick a camera, light, object, **model part** (`model ▸ part`), or
   glued **envelope** from the **Target** dropdown (defaults to the current selection
   when valid). A part orbits **relative to its model** (see Notes).
3. **Orbit Rate:** set the **Radius**, **Rate (rev/s)** (negative reverses
   direction), and **Keyframes / rev**.
4. Click **Create Keyframes** to drop a rate marker. The **first** marker for a
   target anchors at **frame 0** so the orbit covers the whole timeline by default —
   no need to scrub to the start first.
5. For a later rate change, scrub the playhead to where it should take effect and
   click **Create Keyframes** again; add a **Rate 0** marker to stop.

Each marker is listed under **Rate Keyframes** (time · rate) with an **×** to delete
it, plus **Clear All**. The axis and radius are **shared by the whole track** —
after changing them, click **Apply Radius / Axis** to re-bake the existing markers
with the new geometry. The schedule is saved with the project.

## Geometry

- A constant-height circle: `P(θ) = C + radius·(cos θ·u + sin θ·v)`, where `C` is the
  captured **Axis Start** and `u`, `v` span the plane perpendicular to the
  start → end direction (world-up when the two axis points coincide). There is **no
  climb** along the axis — for that, use the corkscrew in the
  [Curve Path Animator](Curve-Path-Animator.md).
- The swept angle is **continuous across markers**, so segments at different rates
  join without a jump.
- **Aim:** the camera and lights aim at the orbit **centre** (`C`); an object turns
  to face the centre as it circles (object −Z is "forward").
- The axis is **world-relative** — both Capture Axis points are world-space Probe
  positions.

## Notes

- Adding the first marker (or editing the schedule) replaces the track's keyframes
  from the **first marker onward** and sets the track to **linear** easing (exact
  constant speed). Hand-keyed frames *before* the first marker are left alone.
- A marker with **rate 0** holds position — the target parks on the circle until a
  later marker resumes the orbit.
- Object keyframes **preserve the object's current scale**.
- **Root** objects (cameras, lights, ungrouped models) orbit on the captured
  **world** circle directly. A **model part** or **glued member** orbits **relative
  to its model / envelope**: the world circle you capture is baked into the part's
  own frame at that moment, so the part circles within the model and rides along if
  the whole model is later moved or animated. Re-pose the model first, then re-bake,
  if you change its rest pose. (So you can now orbit a child directly — though driving
  the **orbit on the envelope** + a **[Spin](Spin-Path-Animator.md) on the child**
  is still the classic way to get "B circles A while spinning".)

See also: [Spin Path Animator](Spin-Path-Animator.md) · [Linear Path Animator](Linear-Path-Animator.md) · [Curve Path Animator](Curve-Path-Animator.md).
