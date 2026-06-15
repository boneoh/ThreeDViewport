# Import Project

Brings another `.3dvp` project's content **into the current scene** — appending, not
replacing — so you can reuse smaller scenes or parts inside a larger animation. The
import is **baked in** at a chosen time and placement: afterwards its objects behave
like any other object in the host scene.

**Open:** File ▸ Import Project…

> **Reusing a glued gizmo with its animation:** Import Project the gizmo's **`.3dvp`** —
> it brings the keyframes, group animation, glued [envelopes](Glue.md), and spin/orbit
> motion. (Open Model of the exported `.glb` gives a *static* copy only.) To make the
> imported spin/orbit **editable** afterward, see *Extending an import's spin / orbit* below.

## Workflow

1. **File ▸ Import Project…**, pick a `.3dvp`.
2. In the dialog set:
   - **Insert at (s)** — the host time the imported animation begins at (defaults to
     the playhead).
   - **Position / Rotation / Scale** — where the import lands. **Position** defaults to
     the [Probe](Probe-Inspector.md); the **Probe** button re-reads it. Rotation is in
     degrees; Scale is uniform.
   - **Include lights** — also append the import's lights (off by default).
   - **Include fog & particles** — also bring in the import's effects (off by default):
     its particle emitters are **appended**, and its fog is **adopted only if the host
     has none** (see below).
   - **Make spin/orbit editable (extends to end)** — off by default. When on, the
     import's spin/orbit rate-markers are re-applied to the imported objects so they're
     **editable** and run to the host timeline's end (same as *Extend Spin/Orbit to End*
     below, done automatically). Leave it off to keep the motion exactly as authored.
   - **Use source In/Out range** — appears only when the source has **both** an In and
     an Out [timeline mark](Timeline-Editor.md#in--out-marks); imports just that slice
     (see below). Defaults on when available.
3. **Import.** The models, their keyframes, materials (incl.
   [Brightness](Model-Inspector.md#brightness-self-emission)), and any glued
   [envelopes](Glue.md) are appended, every keyframe time shifted by the insert time
   and every object placed by the Position/Rotation/Scale.

## What's imported

| Imported | Not imported |
|----------|--------------|
| Models + their animation + materials | Camera + camera moves |
| Group-level animation, glued envelopes | Color grade, background/HDRI, feedback |
| Lights (opt-in) | |
| Fog + particles/weather (opt-in) | |

The host scene keeps its own camera, colour grade, and background.

### Effects (fog & particles)

With **Include fog & particles** on:

- **Particle emitters are appended** — each enabled source emitter becomes a new
  emitter in the host (placed by Position/Rotation/Scale, times shifted by the insert
  time), up to the 8-emitter limit; any beyond that are skipped. Imported emitters
  join the import's **bundle**, so they move with the bundle's span-bar drag and tile
  under **Repeat to Fill Timeline** along with its models.
- **Fog is adopted only when the host has none.** Fog is a single global volume, so it
  can't be merged — if the host already has fog enabled, the imported fog is skipped
  (the host's is kept). Clear the host fog first if you want the import's.

The emitter box / fog volume is placed by the import's Position and scaled by its
Scale; box rotation is not applied (spawn regions are axis-aligned).

Imported lanes are grouped under a collapsible **bundle header** in the
[Timeline Editor](Timeline-Editor.md#import-bundles) (named after the source file), so
a large import can be folded away to a single row.

## Repeating an import (looping)

A short import can be **looped to fill the host timeline** instead of hand-duplicating
it: right-click the bundle header ▸ **Repeat to Fill Timeline**. The cycle length is
the source's full timeline duration, and the repeats regenerate from the editable first
cycle, so editing it (or sliding the bundle in time, or lengthening the host timeline)
updates every repeat. This pairs naturally with building **small, self-contained clip
projects** designed to loop — see
[Timeline Editor ▸ Repeat to Fill Timeline](Timeline-Editor.md#import-bundles) and the
[Advanced ▸ Reuse](Advanced.md#part-4--reuse-exported-models-and-looping-clips)
workflow.

## Importing a slice (source In/Out)

Mark an **In** and **Out** range on the source project's timeline (the Timeline Editor
footer or **Timeline** menu — see [Timeline Editor](Timeline-Editor.md#in--out-marks))
and save it. When you import that project, **Use source In/Out range** lets you bring
in only that slice:

- Keyframes **outside** `[In, Out]` are dropped; the slice's boundaries are
  **resampled**, so each track starts and ends on the exact pose it had at In / Out —
  no jump at the cut.
- The slice is **remapped** so the source **In lands at the Insert time**. A 2–5 s
  source slice inserted at 10 s plays over 10–13 s in the host.
- Slicing only affects **animation timing**. Every object still appears — one whose
  keyframes all fall outside the range imports as a static hold of its pose at In.

A source must have **both** marks set (or none) for this to be offered. If only **one**
mark is set (or the pair is inverted), the dialog shows a warning that the stray mark
is ignored and the **whole** project is imported — so an ambiguous file can't produce
a surprise slice, but you can still proceed (or cancel and fix the marks).
Position/Rotation/Scale and Include lights work exactly as for a full import.

## Extending an import's spin / orbit

Imported spin/orbit come in as **baked keyframes that stop at the source's duration** —
the editable rate markers aren't imported, so a spinning gizmo dropped into a longer
scene stops partway. To carry it through:

Tick **Make spin/orbit editable** in the Import dialog to do this automatically as part
of the import, or do it later on demand:

**Right-click the bundle header ▸ Extend Spin/Orbit to End.** ThreeDViewport re-opens the
source `.3dvp`, reads its spin/orbit **rate markers**, and re-applies them to the
imported objects (placed and time-shifted to match the import). The motion then runs to
the **end of the host timeline** — and it's now **editable**: open the
[Spin](Spin-Path-Animator.md) / [Orbit](Orbit-Path-Animator.md) animator to change the
rate, reverse it, or drop a **rate-0** marker to stop it wherever you like.

- The menu item appears only when the bundle remembers its source file. If the source
  has been **moved or deleted**, you'll get a message — restore it or re-import.
- On a **ranged** (In/Out) import, extending re-bakes the full host length, so the slice
  boundary is dropped for those objects (you're explicitly opting into host-length
  motion).

## Notes

- **Names just work.** If the import shares a model with the host (e.g. both use
  `buckyball-…`), the copies are disambiguated everywhere as `name 1` / `name 2`, and
  the merged scene saves/reloads correctly.
- **Times are in seconds**, so importing a 30 fps project into a 24 fps one (or vice
  versa) keeps the timing.
- The import is **baked** — you can edit any imported object afterwards, and you can
  re-slide the whole import in time by dragging its bundle's span bar in the
  [Timeline Editor](Timeline-Editor.md#import-bundles).
- Imported spin/orbit play exactly as authored, but aren't re-editable as rate markers
  on the imported objects.
- Imports the **whole** source project by default, or just the source's In/Out slice
  when **Use source In/Out range** is on (see above).
- **The source's timeline duration is respected.** Keyframes left *past* the source's
  last frame — e.g. stale baked spin/orbit keyframes after you shortened that project's
  timeline — are **not** imported. They stay in the source file; the import just stops
  at the last frame (boundary-sampled, so the end pose is exact).
- **All referenced model files must be present.** If the source project points at a
  model file that isn't on disk, the import is refused with a message naming it (rather
  than mis-placing the remaining objects). Restore the file or fix its path, then retry.
