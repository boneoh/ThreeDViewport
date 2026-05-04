# ThreeDViewport

A macOS Metal-based 3D animation viewer and exporter. Load `.glb` models, position and animate them with keyframes, configure lighting and backgrounds, apply a video feedback delay-line effect, and export to ProRes `.mov`.

---

## Requirements

- macOS 14 or later
- Apple Silicon or Intel Mac with Metal support
- Swift 5.9 / Xcode 15 or later

---

## Building the .app

> **Important:** `swift build` alone does **not** produce a working `.app`. It copies Metal shader source files into the resources bundle but never compiles them. `makeDefaultLibrary(bundle:)` requires a pre-compiled `default.metallib`, so the app will launch with a white viewport if you skip this step.

Use the included script instead:

```bash
# Release build (default) — produces ThreeDViewport.app in the project root
./make_app.sh

# Debug build
./make_app.sh debug

# Launch
open ThreeDViewport.app
```

The script does everything in one step:

1. `swift build -c release` (or `debug`)
2. Compiles all `.metal` shaders in `Sources/ThreeDViewport/Renderer/` to `default.metallib` using `xcrun metal` / `xcrun metallib`
3. Assembles the `.app` bundle structure (`Contents/MacOS`, `Contents/Frameworks`, etc.)
4. Copies the executable, shader bundle, and `GLTFKit2.framework`
5. Adds the `@executable_path/../Frameworks` rpath so the dynamic framework is found at runtime
6. Writes `Info.plist`
7. Ad-hoc code-signs the result (`codesign --sign -`)

If you add new `.metal` files, also add them to the `resources` list in `Package.swift` — the script picks them up automatically via the `Renderer/*.metal` glob.

For distribution with a Developer ID or App Store submission, replace the `-` identity in the `codesign` lines of `make_app.sh` with your certificate name.

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

- **Metal Viewport** — the 3D render area. Receives all mouse and keyboard input when it has focus.
- **Scene HUD** — floating overlay in the top-left corner showing the current control mode, object list with visibility toggles, and the selected object name.
- **Timeline Panel** — transport controls, playhead scrubber, keyframe buttons, and export button across the bottom of the window.

Separate floating panels open via the View and Window menus:

| Panel | Menu | Description |
|-------|------|-------------|
| Lights & Background | View ⌘L | Adjust lights, colours, and scene background |
| Feedback | View ⌘F | Configure the video delay-line feedback effect |
| Timeline Editor | Window | Per-track keyframe editor with retiming and insert/delete |

The Lights & Background and Feedback panels are utility windows that do not steal keyboard focus from the viewport. The Timeline Editor becomes key when clicked so its keyboard shortcuts work.

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

### Window Menu
| Item | Shortcut | Description |
|------|----------|-------------|
| Timeline Editor | — | Toggle the Timeline Editor panel. Shows one lane per object and camera with draggable keyframe diamonds. |

---

## Mouse Controls

Mouse behaviour depends on the active control mode and whether playback is running.

### Left Drag

| Context | Action |
|---------|--------|
| Camera or Light mode | Pan the camera (slides the target point) |
| Object mode, playback paused | Translate the selected object in the camera's view plane |
| Any mode, **Space held** | **Orbit** the camera around its target point |

### Right Drag

| Context | Action |
|---------|--------|
| Camera or Light mode | **Free-look** — camera position stays fixed; aim direction rotates |
| Object mode, playback paused | Rotate the selected object (yaw + pitch around world axes) |

### Scroll Wheel

| Context | Action |
|---------|--------|
| Camera or Light mode | Zoom in / out (adjusts orbit distance) |
| Object mode, playback paused | Translate the selected object along the camera's forward axis (depth) |

---

## Keyboard Controls

### Mode Switching
These keys switch which scene element receives arrow-key input. They fire once and do not repeat.

| Key | Mode |
|-----|------|
| **C** | Camera mode — arrows pan the camera |
| **L** | Light mode — arrows rotate the selected light. Press **L** again while in light mode to cycle to the next light. |
| **O** | Object mode — arrows translate the selected object. Press **O** again while in object mode to cycle to the next object. |

The current mode is shown in the Scene HUD overlay.

### Camera Mode (default)
| Key | Action |
|-----|--------|
| ← → ↑ ↓ | Pan camera left / right / up / down |
| Shift + ← → | Free-look — rotate aim direction left / right (yaw) |
| Shift + ↑ ↓ | Free-look — rotate aim direction up / down (pitch) |
| **+** / **=** | Zoom in |
| **−** / **_** | Zoom out |

### Light Mode
| Key | Action |
|-----|--------|
| ← → | Rotate selected light azimuth (horizontal) |
| ↑ ↓ | Rotate selected light elevation (vertical) |
| **+** / **=** | Move positional / spot light forward (into the scene) |
| **−** / **_** | Move positional / spot light backward |

### Object Mode
Arrow keys only affect the selected object when playback is **paused**.

| Key | Action |
|-----|--------|
| ← → | Translate selected object along the X axis |
| ↑ ↓ | Translate selected object along the Y axis |
| Shift + ← → | Rotate selected object around the Y axis (yaw) |
| Shift + ↑ ↓ | Rotate selected object around the X axis (pitch) |
| **[** | Roll object left (around Z axis) |
| **]** | Roll object right (around Z axis) |
| **+** / **=** | Translate along the Z axis (towards camera) |
| **−** / **_** | Translate along the Z axis (away from camera) |

### Viewport Toggles
| Key | Action |
|-----|--------|
| **T** | Toggle colour / greyscale rendering |
| **G** | Toggle wireframe display |
| **Space** (hold) | While held, left-drag **orbits** the camera around its target |

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
3. **Pose the object** using arrow keys, mouse drag, or scroll wheel.
4. **Scrub** the timeline to the desired time.
5. **Click Add Key** in the Timeline Panel (or press **Insert** in the Timeline Editor with the object's lane selected) to record the current pose as a keyframe.
6. Repeat for as many poses and time points as needed.
7. **Play** the timeline to preview the animation.

### How Deltas Work

Each keyframe stores the *delta* between the object's base transform and its current transform (`invBase × transform`). During playback the renderer applies `baseTransform × interpolatedDelta` each frame. This means:

- Manual repositioning before adding any keyframes does not break the animation — the saved base transform is restored on project reload.
- Objects without keyframes have their current transform saved directly so manual positioning persists across save/load.

### Camera Keyframes

Camera keyframes record absolute yaw, pitch, distance, and target. Add them with **Add Cam Key** in the Timeline Panel, or press **Insert** in the Timeline Editor with the Camera lane selected. The camera interpolates between them during playback.

---

## Timeline Editor

Open with **Window › Timeline Editor**. The panel shows one horizontal lane per animated track and can be open at any time independently of playback.

```
┌────────────────────────────────────────────────────┐
│ Camera    │  0s    1s    2s    3s    4s    5s  …   │
│───────────│──────────────────────────────────────  │
│ Camera    │  ◆              ◆                       │
│ Cube      │       ◆    ◆        ◆                   │
│ Sphere    │                 ◆                       │
└────────────────────────────────────────────────────┘
```

- The **ruler** shows timecode in seconds. Click anywhere on the ruler to scrub the playhead.
- Each **lane** shows the object or camera name on the left and keyframe diamonds on the right.
- The **red playhead** line moves in real time during playback.
- The timeline scale is dynamic — it always fits the full duration in the available width. Resize the panel to zoom in.

### Timeline Editor Controls

| Action | Result |
|--------|--------|
| Click a **diamond** | Select it and scrub the playhead to that keyframe's time |
| Click an **empty lane area** or label | Select that lane (deselects any diamond) |
| Click **outside all lanes** | Deselect everything |
| **Drag** a selected diamond | Retime the keyframe in real time; playhead follows |
| ← → arrow keys | Nudge the selected diamond ±1 frame (1/30 s) |
| **Delete** | Remove the selected keyframe |
| **Insert** | Stamp a new keyframe at the current playhead time for the selected lane, using the object's or camera's current live state |
| **Return** (on a selected diamond) | Enter **in-place edit mode** for that keyframe (see below) |
| **Return** (while editing) | Commit the new pose — overwrites the keyframe |
| **Escape** (while editing) | Cancel — restores the original pose |

### In-Place Keyframe Edit Mode

Select a diamond and press **Return** to enter edit mode. The selected diamond turns **amber** and a yellow `● EDITING` badge appears in the ruler area.

While in edit mode:
- The timeline **pauses** at the keyframe's time.
- The viewport switches to **Object mode** (or **Camera mode** for the camera lane) automatically.
- Use all normal viewport mouse and keyboard controls to adjust the pose.
- Mouse interactions in the Timeline Editor are blocked while editing.

Press **Return** again to commit — the keyframe is updated with the current pose.  
Press **Escape** to cancel — the original pose is restored exactly.

### Insert Workflow

The Insert key captures *whatever state the object or camera is in right now*:

1. Scrub the playhead to the desired time
2. Move the object or camera to the desired pose (using viewport controls)
3. Click the lane in the Timeline Editor to select it
4. Press **Insert** — the keyframe is recorded and the new diamond is selected

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
