# ThreeDViewport

A macOS Metal-based 3D animation viewer and exporter. Load `.glb` models, position and animate them with keyframes, configure lighting and backgrounds, apply a video feedback delay-line effect, and export to ProRes `.mov`.

---

## Requirements

- macOS 13 or later
- Apple Silicon or Intel Mac with Metal support
- Swift 5.9 / Xcode 15 or later

---

## Window Layout

```
┌─────────────────────────────────────────┐
│  Scene HUD (top-left overlay)           │
│                                         │
│           Metal Viewport                │
│           (1920 × 1080)                 │
│                                         │
├─────────────────────────────────────────┤
│           Timeline Panel                │
└─────────────────────────────────────────┘
```

- **Metal Viewport** — the 3D render area. Receives all mouse and keyboard input.
- **Scene HUD** — floating overlay in the top-left corner showing the current control mode, object list with visibility toggles, and the selected object name.
- **Timeline Panel** — transport controls, playhead scrubber, keyframe buttons, and export button across the bottom of the window.

Floating inspector panels (Lights & Background, Feedback) open as separate utility windows that stay on top without stealing keyboard focus from the viewport.

---

## Menus

### Application Menu
| Item | Shortcut | Description |
|------|----------|-------------|
| Quit ThreeDViewport | ⌘Q | Quit the application |

### File Menu
| Item | Shortcut | Description |
|------|----------|-------------|
| New Project | ⌘N | Clear the scene and reset to defaults. Prompts for confirmation if models are loaded. |
| Open Model… | ⌘O | Load a `.glb` file, replacing the entire current scene. The camera fits to the loaded model. |
| Add Model to Scene… | ⌘⇧O | Append a `.glb` to the existing scene without clearing it. |
| Open Project… | — | Open a `.3dvp` project file, restoring all models, keyframes, camera, lighting, and feedback settings. |
| Save Project | ⌘S | Save to the current project file. Falls back to Save As… on first save. |
| Save Project As… | ⌘⇧S | Save to a new `.3dvp` file (prompts for location). |
| Export ProRes Video… | ⌘E | Export the animation to a `.mov` file at 1920 × 1080. |

### View Menu
| Item | Shortcut | Description |
|------|----------|-------------|
| Lights & Background… | ⌘L | Toggle the Lights & Background inspector panel. |
| Feedback… | ⌘F | Toggle the Feedback delay-line panel. |
| Color Rendering | ⌘T | Toggle between colour and greyscale rendering (checkmark shows current state). Also toggled by the **T** key in the viewport. |

---

## Mouse Controls

| Gesture | Action |
|---------|--------|
| **Drag** (camera mode) | Orbit the camera around the target point |
| **Drag** (object mode, playback paused) | Rotate the selected object in world space |
| **Scroll wheel** | Zoom the camera in / out |
| **Space + Drag** | Pan the camera (works in any control mode) |

---

## Keyboard Controls

### Mode Switching
These keys switch which scene element receives arrow-key input. They fire once and do not repeat.

| Key | Mode |
|-----|------|
| **C** | Camera mode — arrow keys pan the camera |
| **L** | Light mode — arrow keys rotate the selected light. Press **L** again while already in light mode to cycle to the next light. |
| **O** | Object mode — arrow keys translate the selected object. Press **O** again while already in object mode to cycle to the next object. |

The current mode is shown in the Scene HUD overlay.

### Camera Mode (default)
| Key | Action |
|-----|--------|
| ← → ↑ ↓ | Pan camera left / right / up / down |
| **+** / **=** | Zoom in |
| **−** | Zoom out |

### Light Mode
| Key | Action |
|-----|--------|
| ← → | Rotate selected light azimuth (horizontal) |
| ↑ ↓ | Rotate selected light elevation (vertical) |
| **+** / **=** | Move positional/spot light forward (into the scene) |
| **−** | Move positional/spot light backward |

### Object Mode
| Key | Action |
|-----|--------|
| ← → | Move selected object along the X axis |
| ↑ ↓ | Move selected object along the Y axis |
| **+** / **=** | Move selected object along the Z axis (towards camera) |
| **−** | Move selected object along the Z axis (away from camera) |

### Viewport Toggles
| Key | Action |
|-----|--------|
| **T** | Toggle colour / greyscale rendering |
| **G** | Toggle wireframe display |
| **Space** (hold) | Switch to camera pan while held; any drag pans instead of orbiting |

---

## Scene HUD Overlay

The semi-transparent overlay in the top-left of the viewport shows:

- **Control Mode** badge — Camera / Light / Object
- **Object list** — one row per loaded model, showing the model name and a visibility eye icon. Click the eye to toggle that object's visibility.
- The **selected object** is highlighted in the list.

---

## Timeline Panel

The panel across the bottom of the window contains:

| Control | Description |
|---------|-------------|
| ⏹ Stop | Rewind to t = 0:00:00 and stop |
| ▶ / ⏸ Play / Pause | Start or pause playback |
| Time display | Current playhead position in MM:SS:FF format |
| Scrubber | Drag to scrub through the animation |
| Duration label | Current timeline length in MM:SS:FF. **Click** to open a popover where you can type a new duration in seconds or pick a preset (5 s, 10 s, 15 s, 30 s, 60 s, 120 s). |
| **Add Key** | Add an object keyframe at the current playhead position for the selected object |
| **Add Cam Key** | Add a camera keyframe at the current playhead position |
| **Export .mov** | Open the export sheet (same as File › Export ProRes Video…) |

While exporting, a progress indicator and percentage replace the Export button. All transport and keyframe controls are disabled during export.

---

## Animation Workflow

ThreeDViewport uses a **keyframe + delta** system:

1. **Load a model** — it is auto-normalised to fit a 1-unit bounding sphere and its rest pose is recorded as the *base transform*.
2. **Switch to Object mode** (press **O**) and **pause playback**.
3. **Pose the object** using arrow keys or by dragging in the viewport.
4. **Scrub** the timeline to the desired time.
5. **Click Add Key** (or use the timeline button) to record the current pose as a keyframe.
6. Repeat for as many poses and time points as needed.
7. **Play** the timeline to preview the animation.

### How Deltas Work

Each keyframe stores the *delta* between the object's base transform and its current transform (`invBase × transform`). During playback the renderer applies `baseTransform × interpolatedDelta` each frame. This means:

- Manual repositioning before adding any keyframes does not break the animation — the saved base transform is restored on project reload.
- Objects without keyframes have their current transform saved directly so manual positioning persists across save/load.

### Camera Keyframes

Camera keyframes record absolute yaw, pitch, distance, and target. Add them with **Add Cam Key** at any playhead position. The camera interpolates between them during playback.

---

## Lights & Background Inspector

Open with **View › Lights & Background…** (⌘L). The panel floats above the viewport.

### Lights

Up to four lights are supported. Each light has:

| Control | Description |
|---------|-------------|
| Type selector | Directional, Point, Spot, or Laser |
| Enable toggle | Turn the light on or off |
| Colour well | Pick the light colour |
| Intensity slider | 0 – 10 |
| Azimuth / Elevation | Directional and positional angle controls |
| Inner / Outer angle | Spot and laser cone angles |
| Position | World-space XYZ for point, spot, and laser lights |

Lights can also be adjusted with arrow keys after pressing **L** to enter light mode. Press **L** again to cycle to the next light.

### Background

| Control | Description |
|---------|-------------|
| Mode | Solid colour or gradient |
| Top colour / Bottom colour | Gradient endpoint colours |
| Solid colour | Colour when in solid mode |

---

## Feedback Delay-Line

Open with **View › Feedback…** (⌘F). The panel floats above the viewport.

The feedback system blends the current frame with a delayed copy from a ring buffer, creating a video echo / trails effect.

| Control | Range | Description |
|---------|-------|-------------|
| Enable toggle | on / off | Activates the feedback loop |
| Interval | 1 – 60 frames | How many rendered frames between feedback ticks |
| Decay | 0.0 – 1.0 | Blend weight between current scene (0.0) and feedback tap (1.0). ~0.5 gives an equal mix. |
| Length | 1 – 60 frames | Number of delayed frames stored in the ring buffer. Larger values mean a longer echo. |
| **Clear Queue** | — | Flush the ring buffer and re-prime from scratch |

**Status indicator:**
- 🟠 *Priming…* — the ring buffer is filling up (Length × Interval frames needed before feedback becomes active)
- 🟢 *Active* — the ring buffer is full and feedback is running

**Behaviour notes:**
- Feedback only runs during **playback**. While paused or at the end of the animation, the last blended frame is held on screen.
- The queue is automatically cleared when playback starts so each play-through begins fresh.
- Feedback settings are saved in the project file.

---

## Video Export

**File › Export ProRes Video…** (⌘E) renders the full timeline to a 1920 × 1080 `.mov` file.

| Option | Description |
|--------|-------------|
| ProRes 4444 | Full quality with alpha channel — largest file, highest fidelity |
| ProRes 422 HQ | High quality without alpha — smaller file |

The export renders every frame offline at the timeline's frame rate. Feedback (if enabled) is applied during export using an independent processor initialised from the saved feedback settings. The viewport stays live during export and playback is suspended until it completes.

---

## Project Files

Projects are saved as `.3dvp` files (JSON). They store:

- Timeline duration
- Camera position and keyframe track
- All loaded model paths (absolute) and per-object keyframes / base transforms
- Lighting configuration
- Background configuration
- Colour / greyscale mode
- Feedback settings

Model files (`.glb`) are referenced by absolute path and must remain accessible at their original location for the project to reload them.

---

## Supported Model Format

- **glTF 2.0 Binary (`.glb`)** — including PBR materials (base colour, normal, metallic/roughness, emissive textures), embedded meshes, and node transforms.

Models are auto-normalised on load: scaled so their bounding sphere fits within a 1-unit radius and centred at the world origin.
