# ThreeDViewport Keyboard Reference

## Mode Switching (global)

| Key | Action |
|-----|--------|
| **B** | Nudge selected keyframe 1 frame backward |
| **C** | Camera mode |
| **F** | Nudge selected keyframe 1 frame forward |
| **G** | Greyscale Toggle |
| **I** or **Insert** | Stamp keyframe for active mode |
| **L** | Light mode (press again to cycle to next light) |
| **M** | Model mode (move/rotate whole group as one unit) |
| **O** | Object mode (press again to cycle to next object) |
| **P** | Play / Pause |
| **W** | Wireframe toggle |
| **Delete** | Delete selected keypoint(s) |
| **End** | Jump playhead to end |
| **Home** | Jump playhead to start |
| **Return** | Commit keyframe edit |
| **Shift+Tab** | Previous keyframe on active track |
| **Tab** | Next keyframe on active track |

<div style="page-break-after: always;"></div>


## Directional Keys

Hold for smooth repeat. Numpad equivalents: 4/6/8/2/+/−

| Key | Camera | Object / Model | Lights |
|-----|--------|----------------|--------|
| **←** | Pan left | Move left (X−) | Move left (positional) / Steer left (directional) |
| **→** | Pan right | Move right (X+) | Move right (positional) / Steer right (directional) |
| **↑** | Pan up | Move up (Y+) | Move up (positional) / Steer up (directional) |
| **↓** | Pan down | Move down (Y−) | Move down (positional) / Steer down (directional) |
| **Shift+←** | Look left (free-look yaw) | Rotate left (Y−, yaw) | Rotate azimuth left |
| **Shift+→** | Look right (free-look yaw) | Rotate right (Y+, yaw) | Rotate azimuth right |
| **Shift+↑** | Look up (free-look pitch) | Rotate up (X+, pitch) | Rotate elevation up |
| **Shift+↓** | Look down (free-look pitch) | Rotate down (X−, pitch) | Rotate elevation down |
| **+** / **KP+** | Dolly in (move camera forward) | Move forward (Z+) | Move light forward (depth) |
| **−** / **KP−** | Dolly out (move camera backward) | Move backward (Z−) | Move light back (depth) |
| **Option++** | — | Scale up 5% | — |
| **Option+−** | — | Scale down 5% | — |
| **[** | Orbit yaw left | Roll left (Z−) | Rotate azimuth left |
| **]** | Orbit yaw right | Roll right (Z+) | Rotate azimuth right |
| **R** | Reset to defaults | Reset rotation to loaded orientation | Reset to default direction |

<div style="page-break-after: always;"></div>


## Mouse

| Button | Camera | Object / Model | Lights |
|--------|--------|----------------|--------|
| **Left drag** | Axis-locked pan | Axis-locked translate | Axis-locked lateral move |
| **Right drag** | Free-look (both axes) | Free rotate (both axes) | Free rotate (azimuth + elevation) |
| **Space + Left drag** | Free orbit (all modes) | Free orbit (all modes) | Free orbit (all modes) |
| **Scroll wheel** | Lens zoom in/out (FOV) | Move forward / backward | Move light forward / backward (depth) |

## Timeline Editor

| Command | Operation |
|---------| --------- |
| **Control+Left drag** | Select multiple keyframes |
| **Control+C** | Copy keyframe(s) |
| **Control+V** | Paste keyframe(s) at scrub position |