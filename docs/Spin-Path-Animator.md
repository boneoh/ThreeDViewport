# Spin Path Animator

Generates a constant, **wobble-free self-spin** for the selected object or model —
rotation about its **own local X / Y / Z axis**, in place (position and scale
untouched), so the spin composes cleanly on top of any motion it already has —
including riding a [glued](Glue.md) envelope's orbit.

You drive it with **rate markers**: set a spin **rate** (revolutions per second),
drop a keyframe, and the object keeps spinning at that rate until the next marker.
To change speed, drop another marker; to stop, drop a marker with rate **0**. This
makes dialling a spin in (and adjusting it later) much quicker than hand-keying a
window of rotations.

It works on four kinds of track: a single **object** lane; a **model** (group)
lane — a multi-part model that spins as a whole about its own centre; an individual
**model part** (listed as `model ▸ part`), which spins in place on top of any
whole-model spin; or a glued **envelope** lane, which spins the whole [glued](Glue.md)
unit. Cameras and lights aren't offered (self-spin isn't meaningful for them).

This is the in-place counterpart to the [Orbit Path Animator](Orbit-Path-Animator.md),
which moves an object *around* an external axis.

**Open:** Window ▸ Path Animator ▸ Spin…

## Workflow

1. **Target:** pick an **object**, **model**, **model part** (`model ▸ part`), or
   glued **envelope** from the **Target** dropdown. It defaults to the current
   selection when that selection is something spinnable.
2. **Spin Rate:** choose the **Local axis** (X / Y / Z — Y is a top-like spin), set
   the **Rate (rev/s)** (negative reverses direction), and **Keyframes / rev**.
   Optionally open **Advanced — Tumble (second axis)** to add a simultaneous spin
   about a second local axis (see [Tumble](#tumble-two-axes-at-once) below).
3. Click **Create Keyframes** to drop a rate marker **at the playhead** — scrub to
   where the spin should begin first (frame 0 for a whole-timeline spin). The spin
   then holds that rate from the marker to the next one (or the timeline end).
   (Opening the panel never creates keyframes on its own — it only shows the target's
   existing markers — so it can't disturb animation you already have.)
4. For a later rate change, scrub the playhead to where it should take effect and
   click **Create Keyframes** again. Add a marker with **Rate 0** where you want the
   spin to stop and hold.

Each marker is listed under **Rate Keyframes** (time · rate · axis) with an **×** to
delete it, plus **Clear All**. The markers are saved with the project, so you can
reopen it later and tweak a rate.

## How rates become motion

- The segment from one marker runs at that marker's rate until the next marker. The
  **last marker runs to the end of the timeline**.
- A marker with **rate 0** holds the current orientation — that's how you stop the
  spin (or pause it before a later marker speeds it back up).
- Behind the scenes the rate markers regenerate evenly-spaced rotation keyframes, so
  playback and export are unchanged. The orientation is carried **continuously**
  across markers (and across an axis change), so there's no pop where one rate meets
  the next.

## Why it doesn't wobble

- Every generated keyframe keeps the object's **current position and scale** and
  adds an exact incremental rotation about a **single axis** — so the object spins
  in place with no cross-axis drift that would make it nod or precess.
- The track is forced to **linear** easing, so interpolation is `slerp` between
  equal-angle steps — mathematically exact, constant-velocity rotation with no
  spline overshoot.
- **Keyframes / rev ≥ 3** (steps under 180°) guarantees `slerp` takes the correct
  short arc; raise it for denser sampling if you later switch the track to a spline
  easing.

## Notes

- Adding the first marker (or editing the schedule) replaces the track's keyframes
  from the **first marker onward** and sets that track to **linear** easing. Any
  hand-keyed frames *before* the first marker are left alone.
- The spin starts from the object's **current orientation** at the first marker — no
  pop at the start.
- **Object**, **model**, **model-part**, and glued **envelope** tracks only (self-spin
  isn't meaningful for cameras or lights, so they aren't offered). A part spins about
  its **local** origin (relative to its parent), composing on top of any whole-model
  spin — the same way a glued member spins relative to its envelope.
- An **object** spins about its **local origin (pivot)**; if a single mesh's pivot
  is off-centre the spin looks like a small orbit around that pivot. A **model**
  (group) spins about its **bounding centre**, so multi-part models turn in place.

## Tumble (two axes at once)

The **Advanced — Tumble (second axis)** section adds an optional **second
simultaneous spin** so an object turns about two of its local axes at the same time,
like a tumbling die. Pick the **Second axis** (X / Y / Z) and a **Rate 2 (rev/s)**;
leave **Rate 2** at **0** for an ordinary single-axis spin.

- The two spins compose into one orientation per generated keyframe — primary spin
  first, then the secondary — so a single marker drives the whole tumble. The marker
  list still shows the primary time · rate · axis.
- For a tumble that **loops seamlessly** over a repeated cycle, make both rates land
  on whole revolutions per cycle (e.g. Rate 1 and Rate 2 both integer rev/s over a
  1-second loop). Mismatched rates still tumble correctly but won't return to the
  exact start orientation each cycle.
- This is a clean, deterministic, *loopable* composition — not a free-body physics
  tumble (which doesn't loop). It reads as a tumble and stays reproducible on reload
  and export.

## Example: B orbits A *and* spins on its own axis

1. [Glue](Glue.md) B to A (anchor A) to create an envelope (Edit ▸ Glue Objects…).
2. Select the **envelope** as the [Orbit](Orbit-Path-Animator.md) target and add an
   orbit rate — B circles A.
3. Select **B** as the **Spin** target and add a spin rate.
4. Play — B orbits A while spinning on its own axis, both smooth.

See also: [Orbit Path Animator](Orbit-Path-Animator.md) · [Linear Path Animator](Linear-Path-Animator.md) · [Curve Path Animator](Curve-Path-Animator.md).
