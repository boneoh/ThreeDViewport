# ThreeDViewport Keyboard Reference

## Primary Keyboard Commands

| Key | Action |
|-----|--------|
| **B** | Nudge selected keyframe 1 frame backward |
| **C** | Camera mode |
| **D** / **Delete** / **Backspace** | Delete selected keyframe(s) |
| **E** / **End** | Jump playhead to end |
| **F** | Nudge selected keyframe 1 frame forward |
| **G** | Greyscale Toggle |
| **H** / **Home** | Jump playhead to start |
| **I** / **Insert** | Stamp keyframe for active mode |
| **L** | Light mode (press again to cycle to next light) |
| **M** | Model mode (move/rotate whole group as one unit) |
| **O** | Object mode (press again to cycle to next object) |
| **P** | Play / Pause |
| **R** | Reset current object, light, or camera orientation |
| **⌘R** | Re-auto-fit Director (only in Scene mode) |
| **S** | Toggle Scene mode (Director's POV — see camera, lights, models from above and behind) |
| **W** | Wireframe toggle |
| **⌘+** / **⌘−** | Dolly Director in / out (only in Scene mode) |
| **Return** | Commit keyframe edit |
| **Shift+Tab** | Previous keyframe on active track |
| **Tab** | Next keyframe on active track |

<div style="page-break-after: always;"></div>


## Movement and Directional Keys

Hold for smooth repeat. Numpad equivalents: 4/6/8/2/+/−

| Key | Camera | Object / Model | Lights |
|-----|--------|----------------|--------|
| **←** | Truck left | Move left (screen-relative) | Truck left (positional) / Pan left (directional) |
| **→** | Truck right | Move right (screen-relative) | Truck right (positional) / Pan right (directional) |
| **↑** | Pedestal up | Move up (screen-relative) | Pedestal up (positional) / Tilt up (directional) |
| **↓** | Pedestal down | Move down (screen-relative) | Pedestal down (positional) / Tilt down (directional) |
| **Shift+←** | Pan left | Rotate left (Y−, yaw) | Pan left (directional/spot/laser) |
| **Shift+→** | Pan right | Rotate right (Y+, yaw) | Pan right (directional/spot/laser) |
| **Shift+↑** | Tilt up | Rotate up (X+, pitch) | Tilt up (directional/spot/laser) |
| **Shift+↓** | Tilt down | Rotate down (X−, pitch) | Tilt down (directional/spot/laser) |
| **+** / **KP+** | Focal Length increase | Move away (increase distance) | Dolly in (positional only) |
| **−** / **KP−** | Focal Length decrease | Move toward (decrease distance) | Dolly out (positional only) |
| **Option++** | — | Scale up 5% | — |
| **Option+−** | — | Scale down 5% | — |
| **[** | Orbit yaw left | Roll left (Z−) | Pan left |
| **]** | Orbit yaw right | Roll right (Z+) | Pan right |
| **R** | Reset to defaults | Reset rotation to loaded orientation | Reset to default direction |

<div style="page-break-after: always;"></div>


## Mouse

| Button | Camera | Object / Model | Lights |
|--------|--------|----------------|--------|
| **Left drag** | Axis-locked Truck + Pedestal | Axis-locked translate (screen-relative) | Axis-locked Truck + Pedestal (positional) / Pan + Tilt (directional) |
| **Right drag** | Free Pan + Tilt | Free rotate (both axes) | Free Pan + Tilt (directional/spot/laser only) |
| **Space + Left drag** | Free orbit (orbits Director in Scene mode, scene camera otherwise) | Free orbit | Free orbit |
| **Scroll wheel** | Dolly in/out | Move away / toward (screen depth) | Dolly in / out (positional only) |

## Timeline Editor

| Command | Operation |
|---------| --------- |
| **Mouse Left Click** | Select object row or single keyframe |
| **Control+Left drag** | Select multiple keyframes |
| **Control+C** | Copy keyframe(s) |
| **Control+V** | Paste keyframe(s) at scrub position |