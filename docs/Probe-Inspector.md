# Probe Inspector

The Probe is a movable world-space point. It does two jobs: it marks where the
scene is captured from when **baking an environment HDR**, and it's the tool you
use to set and recall **position marks**.

> **Position marks** (saved world positions) are distinct from the timeline's
> **In / Out marks** (a playback/export range) — see
> [Timeline Editor](Timeline-Editor.md#in--out-marks). The app menus name them
> **Position Marks** and **Timeline** respectively.

**Open:** Window ▸ Probe Inspector…

## Controls

| Control | Description |
|---------|-------------|
| **Show gizmo in viewport** | Toggles the probe's RGB axis-cross gizmo. The probe gizmo itself is never exported. |
| **Position X / Y / Z** | Sliders (−100…100). Left/Right arrow keys nudge by the last displayed digit. Copy / Paste / Zero icons use the shared coordinate clipboard (you can paste a position copied from any other panel). |
| **Mark Position** | Prompts for a **name** and a **colour**, then saves the probe's current position as a mark. The colour defaults to the last one you chose, so a run of related marks can share a colour. |
| **Show marks** | Toggles all position marks — in the viewport **and** in exports (also Position Marks ▸ **Show Position Marks**). |

## Probe mode (move the probe in the viewport)

Press **T** to enter **Probe mode** and position the probe directly in the viewport
instead of via the sliders (it reveals the gizmo automatically):

| Input | Effect |
|-------|--------|
| **Left drag** | Axis-locked move in the screen plane (one axis per stroke). |
| **Arrow keys** | Move in the screen plane; **Shift + ↑/↓** pushes along depth. |
| **Scroll wheel** / **+ −** | Move along depth (into / out of the view). |

Movement is relative to the current view: the scene camera in normal view, or the
**Director POV** in [Scene mode](Viewport-Navigation.md#scene-mode--the-director). In a
standard Director view (keys **1–6**) each gesture moves along a single world axis, so
you can place the probe precisely. Position is clamped to ±100 (same as the sliders).

## Marks

Marks are saved, named world positions drawn as small, single-colour axis-cross +
sphere gizmos. Use them as positional references while animating cameras, lights,
or objects — e.g. drop several marks tracking where an object should be over time,
all in one colour, then key your animation against them.

| Key | Action |
|-----|--------|
| **K** | Show / hide all marks (also Position Marks ▸ Show Position Marks) |
| **N** | Cycle to the next mark — **moves the probe to it** (so you can copy/paste its coordinates), highlights it, and shows its name in the HUD |
| **Shift+N** | Cycle to the previous mark |
| **Delete** / **Backspace** | Delete the selected mark (only acts when marks are visible and one is selected) |

## Persistence & export

- Marks (names, positions, colours) and the Show-marks state are saved with the project.
- When **Show marks** is on, marks render into exported video too — handy for
  final-take adjustments. Turn it off for a clean delivery.

## Baking an environment HDR

Position the probe where you want the capture origin, then File ▸ **Export Scene to
HDR File…**. See [HDR & Image-Based Lighting](HDR.md) for resolution/background
options and using a baked HDR as lighting/background.

See also: [Keyboard reference](../KEYBOARD_REFERENCE.md).
