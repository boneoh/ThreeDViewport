# Timeline Editor

A floating window showing every keyframe on every track (camera, objects, model
groups, lights, fog, weather emitters). Most viewport shortcuts also work here —
unrecognised keys are forwarded back to the viewport.

**Open:** Window ▸ Timeline Editor  ·  **⌘J**

## Lanes

Tracks are listed A→Z across all types. Multi-part models appear as a collapsible
**group header**; click the disclosure triangle to expand its part lanes. A glued
[envelope](Glue.md) appears as its own lane. Clicking a lane label selects that track
(the target for paste).

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

## Persistence

All tracks, keyframes, and per-track easing modes are saved with the project.
