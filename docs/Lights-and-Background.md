# Lights & Background

Render mode, image-based lighting, the background, and up to **four** scene lights.

**Open:** Window ▸ Lights & Background…  ·  **⌘L**

## Rendering

| Control | Description |
|---------|-------------|
| **Render mode** | Greyscale · Color · B + W (matte). Also cycled in the viewport with **G** / menu **⌘G**. B + W produces a white-on-black matte (used by Export All matte passes). |
| **IBL intensity** | Strength of the image-based environment lighting. |

## Background

| Mode | Controls |
|------|----------|
| **Solid** | A single background colour. |
| **Gradient** | Top and Bottom colours. |
| **Environment** | Uses the IBL environment HDR as the backdrop, with **Intensity** and **Horizon** (shifts the horizon line). |

HDRs are loaded from the File menu: **Open Lighting HDR…** (drives IBL) and **Open
Background HDR…** (backdrop only). You can also **bake** the current scene to an HDR
from the [Probe](Probe-Inspector.md) position via File ▸ Export Scene to HDR File….
For the full story on IBL intensity, lighting vs background HDRs, and baking, see
**[HDR & Image-Based Lighting](HDR.md)**.

## Lights

Add a light from the **+ type** menu (Ambient / Directional / Point / Spot / Laser).
Pick the light to edit from the **dropdown** — entries are named like the Timeline
Editor's lanes (*Light 1 - Directional*), so a scene with many lights (e.g. after an
[Import Project](Import-Project.md)) stays manageable. The **–** button beside it
removes the selected light (the last one can't be removed). Per light:

| Control | Notes |
|---------|-------|
| **Enabled** | Toggles the light. |
| **Type** | Directional, Point, Spot, Laser. |
| **Color**, **Intensity** | — |
| **Position** | Point/Spot/Laser (copy / paste / zero). |
| **Target** | World-space aim point; Directional/Spot/Laser (copy / paste / zero). |
| **Cone (radians)** | Inner / Outer angles (Spot). |
| **Range** | Beam / spot length. |
| **Beam** | Thickness (Laser). |

Lights can be animated — stamp with **I** in Light mode (cycle lights with **L**),
then set easing in the [Timeline Editor](Timeline-Editor.md). Type, cone, and
enabled state are static (not animated). Arrow keys move/aim the selected light in
the viewport — see the [keyboard reference](../KEYBOARD_REFERENCE.md).

## Persistence

Light configs + keyframes, render mode, background mode/colours, IBL intensity,
and HDR paths are saved with the project.
