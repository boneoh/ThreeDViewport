# ThreeDViewport

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0.en.html)

A native macOS 3D animation tool built on Metal. Load `.glb` / `.gltf` models, animate them with a keyframe timeline (objects, model groups, camera, and lights), arrange the shot from a Director's POV in Scene mode, apply a video-feedback echo and color grade pass, and export to ProRes `.mov` for compositing.

---

## Requirements

- macOS 14 or later
- Apple Silicon or Intel Mac with Metal support
- Swift 5.9 / Xcode 15 or later

---

## Building

> `swift build` alone does **not** produce a working `.app` bundle. SPM copies Metal shader sources into the resources bundle but never compiles them, and `makeDefaultLibrary(bundle:)` requires a pre-built `default.metallib` — without it the viewport launches white.

Use the included script:

```bash
# Release build (default) — produces ThreeDViewport.app in the project root
./make_app.sh

# Debug build
./make_app.sh debug

# Launch
open ThreeDViewport.app
```

The script runs the full pipeline in one pass:

1. `swift build -c release` (or `debug`)
2. Assembles the `.app` bundle (`Contents/MacOS` / `Resources` / `Frameworks`)
3. Copies the executable and the SPM-generated resources bundle
4. Compiles all `.metal` files in `Sources/ThreeDViewport/Renderer/` into `default.metallib` via `xcrun metal` / `xcrun metallib`
5. Copies `GLTFKit2.framework` and adds the `@executable_path/../Frameworks` rpath
6. Writes `Info.plist`
7. Ad-hoc code-signs the bundle (`codesign --sign -`) so macOS will run it

New `.metal` files are picked up automatically. For distribution with a Developer ID, replace the `-` in the script's `codesign` invocation with your certificate name.

---

## Window layout

```
┌─────────────────────────────────────────┐
│  Scene HUD overlay (top-left)           │
│                                         │
│           Metal viewport                │
│           (1920 × 1080)                 │
│                                         │
├─────────────────────────────────────────┤
│           Timeline panel                │
└─────────────────────────────────────────┘
```

- **Metal viewport** — the 3D render area. Receives all mouse and keyboard input when focused.
- **Scene HUD** — semi-transparent overlay showing the active control mode, the object list with visibility toggles, and the selected item.
- **Timeline panel** — transport controls, playhead scrubber, duration popover, "Add Key" button, and Export button along the bottom.

Floating inspector panels open independently and remember their positions per project. They do not steal keyboard focus from the viewport (except the Timeline Editor, which becomes key on click so its shortcuts work). When the main window is minimized, all open panels hide together and reappear when the window is restored.

## Panels & windows

Each panel has its own page under [`docs/`](docs/) with full controls, keystrokes, and tips. Quick index:

| Panel / window | Open | Docs |
|----------------|------|------|
| Transport bar | (docked, bottom) | [Transport-Bar](docs/Transport-Bar.md) |
| Timeline Editor | Window → Timeline Editor · ⌘J | [Timeline-Editor](docs/Timeline-Editor.md) |
| Camera | Window → Camera… · ⌘K | [Camera-Panel](docs/Camera-Panel.md) |
| Model Inspector | Window → Model Inspector… · ⌘I | [Model-Inspector](docs/Model-Inspector.md) |
| Lights & Background | Window → Lights & Background… · ⌘L | [Lights-and-Background](docs/Lights-and-Background.md) |
| HDR & Image-Based Lighting | File → Open / Export … HDR | [HDR](docs/HDR.md) |
| Atmosphere (Fog + Weather) | Window → Atmosphere… · ⌘⇧A | [Atmosphere](docs/Atmosphere.md) |
| Color Grade | Window → Color Grade… · ⌘⇧G | [Color-Grade](docs/Color-Grade.md) |
| Feedback | Window → Feedback… · ⌘F | [Feedback](docs/Feedback.md) |
| Probe Inspector (+ Marks) | Window → Probe Inspector… | [Probe-Inspector](docs/Probe-Inspector.md) |
| Path Animator — Orbit | Window → Path Animator → Orbit… | [Orbit-Path-Animator](docs/Orbit-Path-Animator.md) |
| Path Animator — Linear | Window → Path Animator → Linear… | [Linear-Path-Animator](docs/Linear-Path-Animator.md) |
| Path Animator — Spin | Window → Path Animator → Spin… | [Spin-Path-Animator](docs/Spin-Path-Animator.md) |
| Glue (Envelopes) | Edit → Glue Objects… | [Glue](docs/Glue.md) |
| Settings | ThreeDViewport → Settings… · ⌘, | [Settings](docs/Settings.md) |

New here? The chapters above cover one feature each. For how they combine into real workflows — layered motion, and cutting a scene into clean compositing passes — read the **[Advanced guide](docs/Advanced.md)**.

See also [Viewport-Navigation](docs/Viewport-Navigation.md), [Export](docs/Export.md), [Copy / Paste / Zero](docs/Coordinate-Clipboard.md), and [KEYBOARD_REFERENCE](KEYBOARD_REFERENCE.md).

---

## What you can do

### Load models

Open `.glb` (single binary) or `.gltf` + `.bin` (JSON + sidecar) via **File → Open Model…** (⌘O). Multiple models can be loaded; each is auto-normalised to a 1-unit bounding sphere on first load. The camera fits to the first model; additional models append without resetting the camera. Hierarchical rigs (e.g. a character with named bones) preserve their parent-child structure for FK animation.

### Animate with keyframes

Stamp keyframes with **I** for whichever mode is active — Object (`O`), Model group (`M`), Camera, or Light (`L`) — then refine them in the [Timeline Editor](docs/Timeline-Editor.md), which supports retiming, copy/paste, multi-select, and per-track easing (linear or Catmull-Rom spline tiers). For smooth generated motion, the [Orbit](docs/Orbit-Path-Animator.md), [Linear](docs/Linear-Path-Animator.md), and [Spin](docs/Spin-Path-Animator.md) Path Animators build whole orbit / arc / dolly paths and wobble-free self-spins from a couple of Probe points or a time window.

### Camera follow

The [Camera panel](docs/Camera-Panel.md) (⌘K) can tie the camera to a named object so it holds its relative framing as the object moves, rotates, and rolls — keyframed in the object's local frame, so it survives any rotation without gimbal-lock issues.

### Scene mode (Director's POV)

Press **S** for a free editing viewpoint that looks *at* the scene camera (drawn as a wireframe wedge) instead of through it — for framing parts, previewing follow paths, and posing. See [Viewport-Navigation](docs/Viewport-Navigation.md).

### Lights, background & atmosphere

Up to four lights (Ambient / Directional / Point / Spot / Laser), a solid / gradient / HDRI-environment background, and image-based lighting — all in [Lights & Background](docs/Lights-and-Background.md). Volumetric fog and weather (rain / snow / sleet) live in [Atmosphere](docs/Atmosphere.md).

### Look: feedback & color grade

A video delay-line echo/trails pass ([Feedback](docs/Feedback.md)) and an exposure / brightness / contrast / gamma pass ([Color Grade](docs/Color-Grade.md)) — both apply in the viewport and the export.

### Position marks

Save named, colour-coded world positions from the [Probe](docs/Probe-Inspector.md) as on-screen reference marks (toggle **K**, cycle **N**) — handy for laying out and adjusting animation, and optionally rendered into exports for final-take tweaks.

### Video export

**File → Export ProRes Video…** (⌘E) renders the timeline offline to ProRes 4444 (luma-alpha) or 422 HQ, each prepended with a sync countdown; **Export All Passes…** (⌘⇧E) renders a multi-pass set for compositing. See [Export](docs/Export.md).

---

## Project files

Projects are saved as `.3dvp` files (human-readable JSON). The schema is additive — older files load cleanly because unknown / missing keys are silently ignored and fields with defaults backfill themselves.

Saved state covers everything needed to reproduce a session:

- Timeline duration and loop-playback setting
- Camera pose + keyframe track (including follow-target metadata and local-frame forward vectors)
- All loaded model paths, per-object base transforms, per-object keyframe tracks (with easing mode), and per-group keyframe tracks
- Light configurations + per-light keyframe tracks
- Background (solid / gradient / HDRI), color-grade, feedback, fog + weather emitters, rendering-mode (color / greyscale / B+W), wireframe, and axes-gizmo settings
- Probe position and named position **marks** (names, positions, colours)
- Window and panel positions for the main window, Timeline Editor, and every inspector panel — restored on load

Model files are referenced by absolute path; they need to remain at their original location for the project to reload cleanly. If a referenced model is missing on load, the project prompts you to locate it.

---

## Supported model formats

- **glTF 2.0 Binary (`.glb`)** — single self-contained file with embedded geometry and textures.
- **glTF 2.0 JSON (`.gltf` + `.bin`)** — JSON descriptor with external binary buffers. The `.bin` file(s) must remain alongside the `.gltf`.

Both support PBR materials (base colour, normal, metallic / roughness, emissive), per-vertex colour fallback, embedded or external meshes, and node hierarchies. If a model fails to load (e.g. Draco compression, an unsupported extension), an alert describes the reason.

---

## Keyboard and mouse

See [KEYBOARD_REFERENCE.md](KEYBOARD_REFERENCE.md) for the complete list of viewport, timeline-editor, and menu shortcuts.
