# Viewport Navigation

How to fly the camera, select and manipulate scene elements, and use Scene mode.
The full key/mouse tables live in the [keyboard reference](../KEYBOARD_REFERENCE.md);
this is the orientation.

## Control modes

A single mode decides what your mouse and arrow keys drive. Switch with a key; the
HUD (top-left) shows the active mode and selection.

| Key | Mode |
|-----|------|
| **C** | **Camera** — orbit/truck/pedestal the scene camera. |
| **O** | **Object** — move/rotate the selected object. Press again to cycle objects. |
| **L** | **Light** — move/aim the selected light. Press again to cycle lights. |
| **M** | **Model** — move/rotate a whole multi-part model group as one unit. |

You can also select by **clicking the object in the viewport** or clicking a lane in
the [Timeline Editor](Timeline-Editor.md) — both drive the same selection (HUD,
inspector dropdowns, and Timeline highlight all follow).

## Mouse

| Input | Effect (mode-dependent) |
|-------|-------------------------|
| **Left click** | Select the object under the cursor (a multi-part model selects as a unit → Model mode; a single object → Object mode). Clicking empty space keeps the current selection. |
| **Option + Left click** | Select the individual **part** under the cursor (Object mode), even within a multi-part model — the HUD reads *model ▸ part*. |
| **Left drag** | Axis-locked translate (truck + pedestal for camera). |
| **Right drag** | Free rotate / free-look. |
| **Space + Left drag** | Free orbit. |
| **Scroll wheel** | Dolly / depth move. |
| **Option + Scroll** | Uniform scale (object/model). |

Arrow keys mirror the mouse (Shift = rotate/free-look; `[` `]` roll/orbit; `+`/`−`
depth or focal length). See the [keyboard reference](../KEYBOARD_REFERENCE.md) for
the per-mode tables.

## Scene mode & the Director

Press **S** to toggle **Scene mode** — a free editing viewpoint (the "Director's
POV") that lets you see and frame the scene from anywhere *without* disturbing the
keyframed scene camera. The Director is never keyframed or exported.

- **S** enters Scene mode (auto-fitting the Director the first time) and exits back to
  the scene Camera.
- **D** jumps straight to the Director POV from any mode: it enters Scene mode if
  needed, switches to the Director if you're on the scene Camera, and is ignored if
  you're already in the Director. (Unlike S, D never exits Scene mode.)
- **C** selects the scene **Camera** (in Scene mode, targets it for posing while the
  view stays through the Director); **D** selects the **Director**.

- **1–6** snap the Director to world-aligned Front / Left / Rear / Right / Top /
  Bottom views, centred on the selected object's group. Because the view is aligned
  to the world axes, a drag then moves along a single world axis (and the scroll
  wheel along the third) for precise placement.
- **7 / 8** solo the selected group (hide others / make them holdout) while posing.
- **⌘+ / ⌘−** dolly the Director; **⌘R** re-auto-fits it.

Typical flow: **S** to enter Scene mode → **O** to select/pose a part → **1–6** to
reframe → pose → **S** to return to Camera mode.

## HUD

The top-left HUD shows the control mode + selected item, a **SCENE** badge in Scene
mode, and the name of a [mark](Probe-Inspector.md) when you cycle marks (**N**).
