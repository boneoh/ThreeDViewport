# ThreeDViewport Keyboard Reference

## Primary Keyboard Commands

Available in the main viewport (no modifier unless noted).

| Key | Action |
|-----|--------|
| **B** | Nudge selected keyframe 1 frame backward |
| **C** | Camera mode |
| **D** | Director mode — navigate the Director's POV (Scene mode only) |
| **Delete** / **Backspace** | Delete selected keyframe(s) (forwarded to Timeline Editor) |
| **E** / **End** | Jump playhead to end |
| **F** | Nudge selected keyframe 1 frame forward |
| **G** | Greyscale toggle |
| **H** / **Home** | Jump playhead to start |
| **I** / **Insert** | Stamp keyframe for active mode |
| **L** | Light mode (press again to cycle to next light) |
| **M** | Model mode (move/rotate whole group as one unit) |
| **O** | Object mode (press again to cycle to next object) |
| **P** | Play / Pause |
| **R** | Reset current object, light, or camera orientation |
| **⌘R** | Re-auto-fit Director (only in Scene mode) |
| **S** | Toggle Scene mode (Director's POV — see camera, lights, models from above and behind); auto-engages Director mode |
| **1**–**6** | Snap Director to a standard view of the selection — Front/Left/Rear/Right/Top/Bottom (Scene mode only) |
| **W** | Wireframe toggle |
| **⌘+** / **⌘−** | Dolly Director in / out (only in Scene mode) |
| **Return** | Commit keyframe edit |
| **Escape** | Cancel keyframe edit |
| **Tab** | Next keyframe on active track |
| **Shift+Tab** | Previous keyframe on active track |

<div style="page-break-after: always;"></div>


## Menu Shortcuts

| Shortcut | Menu | Action |
|----------|------|--------|
| **⌘Q** | ThreeDViewport | Quit |
| **⌘O** | File | Open Model… (adds to scene) |
| **⌘N** | File | New Project |
| **⌘S** | File | Save Project |
| **⌘⇧S** | File | Save Project As… |
| **⌘E** | File | Export ProRes Video… |
| **⌘G** | View | Greyscale Mode |
| **⌘M** | Window | Minimize |
| **⌘L** | Window | Lights & Background panel |
| **⌘F** | Window | Feedback panel |
| **⌘K** | Window | Camera panel (follow-target picker + stamp button) |
| **⌘J** | Window | Timeline Editor |
| **⌘⇧G** | Window | Color Grade panel |

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
| **Scroll wheel** | Dolly in / out (move toward / away from a part) |
| **Left drag** | Truck + Pedestal (pan) |
| **Right drag** | Free-look (aim) |
| **Space + Left drag** | Orbit |
| **← → ↑ ↓** | Pan |
| **Shift + arrows** | Free-look (aim) |
| **+** / **−** | FOV narrow / wide |
| **⌘+** / **⌘−** | Dolly in / out |
| **⌘R** | Re-auto-fit the Director to the scene |

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

<div style="page-break-after: always;"></div>


## Timeline Editor

The Timeline Editor is a floating window (⌘J) that shows every keyframe on every track. Most viewport shortcuts also work when the Timeline Editor has focus — unrecognised keys are forwarded back to the viewport.

### Keyboard

| Command | Operation |
|---------|-----------|
| **⌘C** | Copy selected keyframe(s) to internal clipboard |
| **⌘V** | Paste clipboard at current playhead on selected lane(s) |
| **D** / **Delete** / **Backspace** | Delete selected keyframe(s) |
| **I** / **Insert** | Stamp a keyframe on the selected lane at the playhead |
| **Return** | Enter edit mode on the selected diamond (or commit while editing) |
| **Escape** | Cancel keyframe edit |
| **Home** | Seek playhead to start |
| **End** | Seek playhead to end |
| **Tab** | Next keyframe in the selected lane |
| **Shift+Tab** | Previous keyframe in the selected lane |
| **F** | Nudge selected keyframe(s) 1 frame forward |
| **B** | Nudge selected keyframe(s) 1 frame backward |

### Mouse

| Action | Operation |
|--------|-----------|
| **Click ruler** | Scrub the playhead |
| **Click diamond** | Select that keyframe and seek to its time |
| **Double-click diamond** | Enter edit mode (live-adjust pose, then Return to commit) |
| **Option-click diamond** | Toggle keyframe in/out of multi-selection |
| **Drag diamond** | Move it in time (multi-selection drags together) |
| **Control + Left drag** | Rubber-band select keyframes in a region |
| **Click lane label** | Select the lane (selects its track for ⌘V paste) |
| **Click group disclosure triangle** | Expand / collapse the group's lanes |
