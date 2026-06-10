# Timeline Editor

A floating window showing every keyframe on every track (camera, objects, model
groups, lights, fog, weather emitters). Most viewport shortcuts also work here —
unrecognised keys are forwarded back to the viewport.

**Open:** Window ▸ Timeline Editor  ·  **⌘J**

## Lanes

Tracks are listed A→Z across all types. Multi-part models appear as a collapsible
**group header**; click the disclosure triangle to expand its part lanes. A glued
[envelope](Glue.md) renders the same way — a collapsible header with its members
nested — except each member keeps its **own** track (and easing), since glued members
animate independently. Clicking a lane label selects that track (the target for
paste).

The first column's name is the canonical name used throughout the app (the HUD, the
[Model Inspector](Model-Inspector.md), and the Camera / Path-Animator target
dropdowns all match it). When the same model is loaded more than once, the copies are
disambiguated with a numeric suffix — *hand 1*, *hand 2*, etc.

## Keyboard

| Command | Operation |
|---------|-----------|
| **I** / **Insert** | Stamp a keyframe on the selected lane at the playhead (replaces the nearest one within ~1.5 frames) |
| **F** / **B** | Nudge selected keyframe(s) one frame forward / backward (whole multi-selection moves) |
| **A** | Align multi-selected keyframes to the earliest selected (one per lane) |
| **Delete** / **Backspace** | Delete selected keyframe(s) |
| **⌘C** / **⌘V** | Copy / paste keyframe(s) to the selected lane(s) at the playhead |
| **Tab** / **Shift+Tab** | Next / previous keyframe across visible rows |
| **Home** / **End** | Seek playhead to start / end |

## Mouse

| Action | Operation |
|--------|-----------|
| **Click diamond** | Select it and seek to its time |
| **Drag diamond** | Move it in time (multi-selection drags together) |
| **Control + drag** | Rubber-band select keyframes in a region |
| **Option-click diamond** | Toggle it in/out of the multi-selection |
| **Click ruler** | Scrub the playhead |

## Easing

Each track has an **easing popup** (linear or spline tiers). Spline modes
interpolate with a tensioned Catmull-Rom through neighbouring keyframes for smooth
motion; linear is the default. Camera, light, object, fog, and particle tracks all
support per-track easing.

> Live keyframe **edit mode** (formerly Return / double-click) has been removed —
> the I / Insert stamp workflow replaces it.

## In / Out marks

Like an NLE, the timeline carries an optional **In** and **Out** point that define a
working range. Set them from the **footer** (or the **Timeline** menu):

| Footer button | Action |
|---------------|--------|
| **Set In** | Place the In point at the playhead. |
| **Set Out** | Place the Out point at the playhead. |
| **Clear** | Remove both marks. |
| **Loop In/Out** | When on, playback is confined to the In…Out range; off plays the full timeline. |

The active range is tinted across the lanes with a faint band, and each mark draws a
bracket line with a small tab pointing into the range (bright yellow where the mark is
set, grey on the implicit edge). Setting In past Out (or vice-versa) clears the other
mark so the range can't invert.

The marks also drive **playback** (via the Loop In/Out toggle) and **export** (the
single-clip Export panel offers a *Full Timeline* / *In → Out* choice — see
[Export](Export.md)). They are saved with the project, so a slice marked in one
project can be reused later.

> These are distinct from the [Probe Inspector](Probe-Inspector.md)'s **Position
> Marks** (saved world positions). The menu names keep them apart.

## Persistence

All tracks, keyframes, and per-track easing modes are saved with the project, along
with the In / Out points. (The Loop In/Out toggle is a transient playback mode and is
not saved.)
