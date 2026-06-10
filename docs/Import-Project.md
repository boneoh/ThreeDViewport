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
- Current version imports the **whole** source project (shifted to the insert time); a
  From/To window to import just a slice is planned.
