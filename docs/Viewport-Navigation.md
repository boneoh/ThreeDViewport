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

You can also select by clicking in the viewport or clicking a lane in the
[Timeline Editor](Timeline-Editor.md).

## Mouse

| Input | Effect (mode-dependent) |
|-------|-------------------------|
| **Left drag** | Axis-locked translate (truck + pedestal for camera). |
| **Right drag** | Free rotate / free-look. |
| **Space + Left drag** | Free orbit. |
| **Scroll wheel** | Dolly / depth move. |
| **Option + Scroll** | Uniform scale (object/model). |

Arrow keys mirror the mouse (Shift = rotate/free-look; `[` `]` roll/orbit; `+`/`−`
depth or focal length). See the [keyboard reference](../KEYBOARD_REFERENCE.md) for
the per-mode tables.

## Scene mode & the Director

Press **S** to enter **Scene mode** — a free editing viewpoint (the "Director's
POV") that lets you see and frame the scene from anywhere *without* disturbing the
keyframed scene camera. **D** flies the Director; it is never keyframed or exported.

- **1–6** snap the Director to Front / Left / Rear / Right / Top / Bottom of the
  selected object's group (object-relative).
- **7 / 8** solo the selected group (hide others / make them holdout) while posing.
- **⌘+ / ⌘−** dolly the Director; **⌘R** re-auto-fits it.

Typical flow: **S** to enter Scene mode → **O** to select/pose a part → **1–6** to
reframe → pose → **S** to return to Camera mode.

## HUD

The top-left HUD shows the control mode + selected item, a **SCENE** badge in Scene
mode, and the name of a [mark](Probe-Inspector.md) when you cycle marks (**N**).
