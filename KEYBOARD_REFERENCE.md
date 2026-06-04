# ThreeDViewport Keyboard Reference

## Primary Keyboard Commands

Available in the main viewport (no modifier unless noted).

| Key | Action |
|-----|--------|
| **B** | Nudge selected keyframe 1 frame backward |
| **C** | Camera mode |
| **D** | Director mode — navigate the Director's POV (Scene mode only) |
| **Delete** / **Backspace** | Delete selected keyframe(s) (forwarded to Timeline Editor); also deletes the selected probe **mark** when marks are shown |
| **E** / **End** | Jump playhead to end |
| **F** | Nudge selected keyframe 1 frame forward |
| **G** | Cycle render mode: Greyscale → Color → Black + White |
| **H** / **Home** | Jump playhead to start |
| **I** / **Insert** | Stamp keyframe for active mode |
| **K** | Show / hide all probe marks (see [Probe Inspector](docs/Probe-Inspector.md)) |
| **L** | Light mode (press again to cycle to next light) |
| **M** | Model mode (move/rotate whole group as one unit) |
| **N** | Cycle to next probe mark — moves the probe to it and shows its name in the HUD |
| **Shift+N** | Cycle to previous probe mark |
| **O** | Object mode (press again to cycle to next object) |
| **P** | Play / Pause |
| **R** | Reset current object, light, or camera orientation |
| **⌘R** | Re-auto-fit Director (only in Scene mode) |
| **S** | Toggle Scene mode (Director's POV — see camera, lights, models from above and behind); auto-engages Director mode |
| **V** | Toggle the keyframe motion-path overlay for the selected entity |
| **W** | Wireframe toggle |
| **1**–**6** | Snap Director to a standard view of the selection — Front/Left/Rear/Right/Top/Bottom (Scene mode only) |
| **7** | Solo: hide everything except the selected object's group (Scene mode only) |
| **8** | Solo: make the hidden others still occlude (Scene mode only; pairs with 7) |
| **⌘+** / **⌘−** | Dolly Director in / out (only in Scene mode) |
| **Shift+Tab** | Previous keyframe across visible Timeline rows |
| **Tab** | Next keyframe across visible Timeline rows |

<div style="page-break-after: always;"></div>


## Menu Shortcuts

| Shortcut | Menu | Action |
|----------|------|--------|
| **⌘E** | File | Export ProRes Video… |
| **⌘⇧E** | File | Export All Passes… (multi-pass) |
| **⌘F** | Window | Feedback panel |
| **⌘G** | View | Render Mode (cycles Greyscale → Color → Black + White) |
| **⌘⇧G** | Window | Color Grade panel |
| **⌘⇧A** | Window | Atmosphere panel (Fog + Weather: rain/snow/sleet) |
| **⌘I** | Window | Model Inspector panel |
| **⌘J** | Window | Timeline Editor |
| **⌘K** | Window | Camera panel (follow-target picker + stamp button) |
| **⌘L** | Window | Lights & Background panel |
| **⌘M** | Window | Minimize |
| **⌘N** | File | New Project |
| **⌘O** | File | Open Model… (adds to scene) |
| **⌘Q** | ThreeDViewport | Quit |
| **⌘S** | File | Save Project |
| **⌘⇧S** | File | Save Project As… |

No-shortcut Window items: **Probe Inspector…**, **Show Marks** (toggle; the **K** key
also toggles), and **Path Animator ▸ Rotation… / Linear…**.

<div style="page-break-after: always;"></div>


## Movement and Directional Keys

Hold for smooth repeat. Numpad equivalents: 4/6/8/2/+/−

| Key | Camera | Object / Model | Lights |
|-----|--------|----------------|--------|
| **←** | Truck left | Move left (screen-relative) | Move left (positional) / Pan left (directional) |
| **→** | Truck right | Move right (screen-relative) | Move right (positional) / Pan right (directional) |
| **↑** | Pedestal up | Move up (screen-relative) | Move up (positional) / Tilt up (directional) |
| **↓** | Pedestal down | Move down (screen-relative) | Move down (positional) / Tilt down (directional) |
| **Shift+←** | Free-look yaw left | Rotate around world Y− | Pan left (directional/spot/laser) |
| **Shift+→** | Free-look yaw right | Rotate around world Y+ | Pan right (directional/spot/laser) |
| **Shift+↑** | Free-look tilt up | Rotate around world X+ | Tilt up (directional/spot/laser) |
| **Shift+↓** | Free-look tilt down | Rotate around world X− | Tilt down (directional/spot/laser) |
| **+** / **KP+** | Focal length increase (FOV narrow) | Move forward (camera depth) | Dolly in (positional only) |
| **−** / **KP−** | Focal length decrease (FOV wide) | Move backward (camera depth) | Dolly out (positional only) |
| **Option++** | — | Scale up 5% | — |
| **Option+−** | — | Scale down 5% | — |
| **[** | Orbit yaw left | Roll left (Z−) | Azimuth left |
| **]** | Orbit yaw right | Roll right (Z+) | Azimuth right |
| **R** | Reset to defaults | Reset rotation to loaded orientation | Reset to default direction |

<div style="page-break-after: always;"></div>


## Mouse

| Button | Camera | Object / Model | Lights |
|--------|--------|----------------|--------|
| **Left drag** | Axis-locked Truck + Pedestal | Axis-locked translate (screen-relative) | Axis-locked Move (positional) / Pan + Tilt (directional) |
| **Right drag** | Free Pan + Tilt | Free rotate (both axes) | Free Pan + Tilt (directional/spot/laser only) |
| **Space + Left drag** | Free orbit (orbits Director in Scene mode, scene camera otherwise) | Free orbit | Free orbit |
| **Scroll wheel** | Dolly in / out | Move forward / backward (camera depth) | Dolly in / out (positional only) |
| **Option + Scroll wheel** | — | Uniform scale around object/group centre | — |

<div style="page-break-after: always;"></div>


## Director Mode (Scene Mode Only)

Press **D** in Scene mode — or just press **S**, which auto-engages Director mode — to fly the Director's POV (the free editing viewpoint) without disturbing the keyframed scene camera. This makes it easy to frame individual parts (hands, feet, arms, legs) for posing. Controls mirror Camera mode but drive the Director:

| Input | Director action |
|-------|-----------------|
| **← → ↑ ↓** | Pan |
| **+** / **−** | FOV narrow / wide |
| **⌘+** / **⌘−** | Dolly in / out |
| **Left drag** | Truck + Pedestal (pan) |
| **Right drag** | Free-look (aim) |
| **⌘R** | Re-auto-fit the Director to the scene |
| **Scroll wheel** | Dolly in / out (move toward / away from a part) |
| **Space + Left drag** | Orbit |
| **Shift + arrows** | Free-look (aim) |

The Director is never keyframed or saved. Typical flow: **S** to enter Scene mode, frame the part, **O** to select and pose it, **D** to reframe. Leaving Scene mode (**S**) returns to Camera mode.

> **Note:** **D** means *Director mode* in the viewport, but *delete keyframe* in the Timeline Editor window — two separate views. The viewport always consumes **D**, so it can never delete a keyframe by accident.

### Snap to a standard view (number row 1–6)

In Scene mode, the number keys snap the Director to an axis-aligned view of the **selected object's group**, centered and framed to fit. Views are **object-relative** — they follow the object's own orientation, so "Front" always shows the object's front no matter how it's flown or turned. (The orbit Director can't roll, so a banked object appears tilted in frame but is seen from the correct side.)

| Key | View |
|-----|------|
| **1** | Front |
| **2** | Left |
| **3** | Rear |
| **4** | Right |
| **5** | Top |
| **6** | Bottom |

The snap uses the object's pose at the **current playhead** — if you scrub to a frame where the object has turned, press the key again to re-frame. Works in any control mode while Scene mode is active, so the flow is: **S** → select via **O** (or click a Timeline lane) → press **1–6** → pose the part.

### Solo while posing (7 / 8)

In Scene mode, two keys declutter the view around what you're posing. They are **non-destructive** — your real Visible / Holdout settings are never changed, and leaving Scene mode restores the normal view instantly.

| Key | Action |
|-----|--------|
| **7** | Hide everything except the **selected object's group** (e.g. just the robot stays). Press again to restore. |
| **8** | Make those hidden others still **occlude** (holdout) — so you can judge how the part sits behind / in front of them. Only has effect while **7** is on. |

Solo tracks the selection live (cycle with **O** and the kept group follows). The HUD shows `[Solo]` / `[Solo+Occlude]` while active. Both reset when you leave Scene mode.

<div style="page-break-after: always;"></div>


## Timeline Editor

The Timeline Editor is a floating window (⌘J) that shows every keyframe on every track. Most viewport shortcuts also work when the Timeline Editor has focus — unrecognised keys are forwarded back to the viewport.

### Keyboard

| Command | Operation |
|---------|-----------|
| **A** | Align multi-selected keyframes to the earliest selected (one per lane; aborts if a lane has 2+ selected) |
| **B** | Nudge selected keyframe(s) 1 frame backward (whole multi-selection moves together) |
| **⌘C** | Copy selected keyframe(s) to internal clipboard |
| **Delete** / **Backspace** | Delete selected keyframe(s) |
| **F** | Nudge selected keyframe(s) 1 frame forward (whole multi-selection moves together) |
| **I** / **Insert** | Stamp a keyframe on the selected lane at the playhead (replaces the nearest existing one within 1.5 frames) |
| **⌘V** | Paste clipboard at current playhead on selected lane(s) |
| **End** | Seek playhead to end |
| **Home** | Seek playhead to start |
| **Shift+Tab** | Previous keyframe across all rows currently visible on screen |
| **Tab** | Next keyframe across all rows currently visible on screen |

### Mouse

| Action | Operation |
|--------|-----------|
| **Click diamond** | Select that keyframe and seek to its time |
| **Click lane label** | Select the lane (selects its track for ⌘V paste) |
| **Click group disclosure triangle** | Expand / collapse the group's lanes |
| **Click ruler** | Scrub the playhead |
| **Control + Left drag** | Rubber-band select keyframes in a region |
| **Drag diamond** | Move it in time (multi-selection drags together) |
| **Option-click diamond** | Toggle keyframe in/out of multi-selection |
