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

### Import bundles

Everything brought in by one [Import Project](Import-Project.md) is grouped under a
collapsible **bundle header** named after the source file, so a large import folds
away to a single row instead of scattering lanes through the timeline. The bundle is
display-only — it groups the lanes (objects, model groups, glued envelopes, and any
imported lights) but has no animation of its own. Group and envelope headers stay
collapsible *inside* the bundle (two levels of disclosure). A freshly imported bundle
starts expanded; click its triangle to collapse it. Bundles persist with the project.

**Rename** the bundle header by right-clicking it ▸ *Rename Import Bundle…*. Member
rows (objects and glued units) rename through the [Model Inspector](Model-Inspector.md)
as usual and stay nested under the bundle. The same right-click menu also offers
*Repeat to Fill Timeline*, *Extend Spin/Orbit to End* (see
[Import Project](Import-Project.md#extending-an-imports-spin--orbit)), and *Delete Import*.
Imported **particle emitters** join the bundle too — they move and tile with it.

**Move the whole import in time** by dragging the teal **span bar** on the bundle
header — it spans the import's first→last keyframe. Every member track shifts by the
same (frame-snapped) amount, so the import keeps its internal timing. It won't move
earlier than t=0; dragging past the end grows the timeline duration to fit. (A bundle
with no keyframes has no bar — there's nothing to move in time.)

**Repeat to Fill Timeline** — right-click the bundle header ▸ *Repeat to Fill
Timeline* loops the import to the end of the host timeline. The cycle length is the
**imported project's full timeline duration** (frame zero → last frame), so any quiet
lead-in or lead-out you built into the source repeats too — not just the keyframed
span. Each repeat is a **hard restart** at the import's frame zero; design the source
so its last frame lands back on its first (e.g. a full 360° [Spin](Spin-Path-Animator.md)
/ [Orbit](Orbit-Path-Animator.md), or a value that returns to its start) — the editor
does not blend the seam.

The generated repeats render **dark green and are locked** — they can't be clicked,
dragged, or rubber-banded. They regenerate automatically from the editable **first
cycle**, so:

- Edit the first cycle (drag or stamp a keyframe) and every repeat follows.
- Drag the bundle's span bar to slide the loop in time — the repeats re-tile.
- Change the timeline duration and the loop refills (longer) or trims (shorter) — no
  re-import needed.

The loop state persists with the project. Toggle the menu item again to turn it off,
which removes the repeats and leaves the bare first cycle. See
[Advanced ▸ Reuse](Advanced.md#part-4--reuse-exported-models-and-looping-clips) for the
build-a-short-loop-and-fill workflow.

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
| **Right-click a row** | Context menu — **Delete** (see below); plus paste-channel on a light/fog/particle diamond, and rename / repeat on a bundle header |

### Copy / paste across objects

`⌘C` / `⌘V` retarget depending on what you copied:

- **One lane** (one or many diamonds from a single row) → pastes onto whatever lane is
  **selected**, at the playhead.
- **A whole multi-part model's lanes** (diamonds spanning the child rows of one model)
  → select the **other model** (its header or any of its parts) and paste: each child's
  keyframes land on the matching part of the destination model, by position. This copies
  a full animation/spin rig from one model onto a **duplicate** of it — even when parts
  share names. (Without a destination model selected, a multi-lane paste returns each
  lane to its own row.)
- A multi-lane copy that **isn't** a single model's parts (e.g. a light + an object)
  always pastes back to its own lanes.

## Delete a row

Right-click any lane and choose **Delete** (a confirmation follows). The label and what
it removes depend on the row:

- **Model** — a standalone object, or a whole multi-part model (deleting any one part
  removes the model — the parts of one `.glb` aren't independent).
- **Glued Model** — the [envelope](Glue.md) **and** all its members (use *Unglue* to
  keep the members).
- **Member** — one member of a glued unit (it leaves the unit; the rest stay).
- **Light** / **Emitter** — that light or weather emitter (not offered for the last one).
- **Import** — on a [bundle header](#import-bundles), the whole import and everything it
  brought in (its objects and any imported lights).

Deletes are clean: parent links, group tracks, and Spin/Orbit schedules are all
repaired so nothing is left mis-targeted. (Fog and the camera have no Delete — disable
fog from the [Atmosphere](Atmosphere.md) panel.)

## Easing

Each track has an **easing popup** (linear or spline tiers). Spline modes
interpolate with a tensioned Catmull-Rom through neighbouring keyframes for smooth
motion; linear is the default. Camera, light, object, fog, and particle tracks all
support per-track easing.

> Live keyframe **edit mode** (formerly Return / double-click) has been removed —
> the I / Insert stamp workflow replaces it.

## Lock a track

Each top-level row has a **lock toggle** (padlock) just right of the easing popup.
When a track is locked it's **frozen against edits**: you can't move / rotate / scale
it in the viewport, and you can't stamp, drag, delete, or paste its keyframes. Playback
and export are unaffected — lock only guards editing. Attempting a blocked edit plays
a gentle **beep** as a reminder.

- A **model** is locked from its header row (it locks the whole model; to adjust a
  child, unlock the model, edit, then re-lock). Model **part** rows have no toggle.
- The footer has **Lock All** / **Unlock All** to freeze or release every track at once.
- Lock state is saved with the project.

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

All tracks, keyframes, per-track easing modes, and **per-track lock state** are saved
with the project, along with the In / Out points. (The Loop In/Out toggle is a
transient playback mode and is not saved.)
