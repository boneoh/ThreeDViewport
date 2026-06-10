# Import Project

Brings another `.3dvp` project's content **into the current scene** — appending, not
replacing — so you can reuse smaller scenes or parts inside a larger animation. The
import is **baked in** at a chosen time and placement: afterwards its objects behave
like any other object in the host scene.

**Open:** File ▸ Import Project…

## Workflow

1. **File ▸ Import Project…**, pick a `.3dvp`.
2. In the dialog set:
   - **Insert at (s)** — the host time the imported animation begins at (defaults to
     the playhead).
   - **Position / Rotation / Scale** — where the import lands. **Position** defaults to
     the [Probe](Probe-Inspector.md); the **Probe** button re-reads it. Rotation is in
     degrees; Scale is uniform.
   - **Include lights** — also append the import's lights (off by default).
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
| Group-level animation, glued envelopes | Fog, particles/weather |
| Lights (opt-in) | Color grade, background/HDRI, feedback |

The host scene keeps its own camera and scene-wide effects.

Imported lanes are grouped under a collapsible **bundle header** in the
[Timeline Editor](Timeline-Editor.md#import-bundles) (named after the source file), so
a large import can be folded away to a single row.

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

## Notes

- **Names just work.** If the import shares a model with the host (e.g. both use
  `buckyball-…`), the copies are disambiguated everywhere as `name 1` / `name 2`, and
  the merged scene saves/reloads correctly.
- **Times are in seconds**, so importing a 30 fps project into a 24 fps one (or vice
  versa) keeps the timing.
- The import is **baked** — you can edit any imported object afterwards, but you can't
  re-slide the whole import as a unit (re-import to reposition in time).
- Imported spin/orbit play exactly as authored, but aren't re-editable as rate markers
  on the imported objects.
- Imports the **whole** source project by default, or just the source's In/Out slice
  when **Use source In/Out range** is on (see above).
