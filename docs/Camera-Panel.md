# Camera Panel

Controls the scene camera and stamps camera keyframes. The camera is an **orbit
camera** — its state is yaw / pitch / distance around a target point, plus focal
length (FOV). Camera keyframes are **absolute** (the full state at each time).

**Open:** Window ▸ Camera…  ·  **⌘K**

## Controls

| Control | Description |
|---------|-------------|
| **Follow Target** | Picker. *None — Free Camera* stamps an absolute camera. Choosing an object makes new keyframes **follow** that object — the camera stays glued to it (POV / over-the-shoulder), rebasing on the object's facing each frame. The choice is sticky across stamps. |
| **Add Camera Keyframe** | Stamps a keyframe at the playhead using the current camera (free or follow, per the picker). Same as pressing **I** in Camera mode. |
| **Follow POV** (Distance / Azimuth / Elevation) | When a follow target is set, frames the camera relative to the object; the button stamps a follow keyframe at that relative pose. |
| **Position X / Y / Z** | The camera eye position (copy / paste / zero). |
| **Target X / Y / Z** | The point the camera looks at / orbits (copy / paste / zero). |
| **Focal Length (mm)** | Vertical FOV expressed as a full-frame-equivalent focal length. |

All coordinate fields use the shared clipboard, so you can paste a position from a
[mark](Probe-Inspector.md), another panel, etc.

## Animating

- Stamp with **I** (Camera mode) or the **Add Camera Keyframe** button, then refine
  in the [Timeline Editor](Timeline-Editor.md) (per-track easing applies).
- For smooth orbital / dolly moves, the [Orbit](Orbit-Path-Animator.md) and
  [Linear](Linear-Path-Animator.md) Path Animators can generate camera keyframes.
- Arrow keys move the camera in the viewport (truck/pedestal; Shift = free-look;
  `[` `]` orbit; `+`/`−` focal length). See the [keyboard reference](../KEYBOARD_REFERENCE.md).

## Persistence

Camera position/target/FOV and all camera keyframes (including follow data) are
saved with the project.
