# ThreeDViewport

A macOS Metal-based 3D animation viewer and exporter. Load `.glb` / `.gltf` models, position and animate them with keyframes, configure lighting and backgrounds, apply a video feedback delay-line effect, post-process with color grading, and export to ProRes `.mov`.

---

## Requirements

- macOS 14 or later
- Apple Silicon or Intel Mac with Metal support
- Swift 5.9 / Xcode 15 or later

---

## Building

> **Important:** `swift build` alone does **not** produce a working `.app`. SPM copies Metal shader source files into the resources bundle but never compiles them. `makeDefaultLibrary(bundle:)` requires a pre-compiled `default.metallib` — the app launches with a white viewport if this step is skipped.

Use the included script instead:

```bash
# Release build (default) — produces ThreeDViewport.app in the project root
./make_app.sh

# Debug build
./make_app.sh debug

# Launch
open ThreeDViewport.app
```

The script performs all steps in one pass:

1. `swift build -c release` (or `debug`)
2. Assembles the `.app` bundle (`Contents/MacOS`, `Contents/Resources`, `Contents/Frameworks`)
3. Copies the executable
4. Copies the SPM-generated resources bundle
5. Compiles all `.metal` files in `Sources/ThreeDViewport/Renderer/` to `default.metallib` via `xcrun metal` / `xcrun metallib`
6. Copies `GLTFKit2.framework` and adds the `@executable_path/../Frameworks` rpath
7. Writes `Info.plist`
8. Ad-hoc code-signs the result (`codesign --sign -`) — required by macOS for Metal and Gatekeeper

If you add new `.metal` files they are picked up automatically. For distribution with a Developer ID, replace the `-` sign identity in `make_app.sh` with your certificate name.

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

- **Metal Viewport** — the 3D render area. Receives all mouse and keyboard input when focused.
- **Scene HUD** — semi-transparent overlay in the top-left corner showing the control mode, object list with visibility toggles, and the selected object name.
- **Timeline Panel** — transport controls, playhead scrubber, keyframe buttons, and export button across the bottom of the window.

Floating panels open independently via the Window menu:

| Panel | Shortcut | Description |
|-------|----------|-------------|
| Lights & Background | ⌘L | Lights, colour, and scene background |
| Feedback | ⌘F | Video delay-line echo effect |
| Color Grade | ⌘G | Brightness, contrast, and gamma post-process |
| Timeline Editor | ⌘J | Per-track keyframe editor with retiming and insert/delete |

Lights & Background, Feedback, and Color Grade are utility panels that do not steal keyboard focus from the viewport. The Timeline Editor becomes key on click so its keyboard shortcuts work. All panels are resizable and minimizable. When the main window is minimized, all open secondary panels hide automatically and reappear when the main window is restored.

---

## Menus

### Application Menu
| Item | Shortcut | Description |
|------|----------|-------------|
| About ThreeDViewport | — | Standard about panel |
| Quit ThreeDViewport | ⌘Q | Quit the application |

### File Menu
| Item | Shortcut | Description |
|------|----------|-------------|
| Open Model… | ⌘O | Load a `.glb` or `.gltf` file and add it to the scene. The camera fits to the first loaded model. Subsequent models are appended without clearing the existing scene. |
| New Project | ⌘N | Clear the scene and reset to defaults. Prompts for confirmation if models are loaded. |
| Open Project… | — | Open a `.3dvp` project file, restoring all models, keyframes, camera, lights, and display settings. |
| Save Project | ⌘S | Save to the current project file. Prompts for a location on first save. |
| Save Project As… | ⌘⇧S | Save to a new `.3dvp` file. |
| Export ProRes Video… | ⌘E | Export the full animation to a 1920 × 1080 `.mov` file. |

### Edit Menu
| Item | Shortcut | Description |
|------|----------|-------------|
| Remove › *Object Name* | — | Dynamically lists every object in the scene. Selecting one shows a confirmation prompt. Shows "No Objects" when the scene is empty. |
| Remove All | — | Confirmation prompt, then removes all objects from the scene. |

### View Menu
| Item | Shortcut | Description |
|------|----------|-------------|
| Greyscale Mode | ⌘T | Toggle between colour (PBR) and greyscale rendering. Checkmark shows current state. Also toggled by the **T** key in the viewport. |
| Wireframe | — | Toggle wireframe display. Also toggled by the **G** key in the viewport. |
| Axes Gizmo | — | Toggle the XYZ orientation gizmo overlay. |
| Loop Playback | — | When checked, playback loops continuously; when unchecked the timeline stops at the end. |

### Window Menu
| Item | Shortcut | Description |
|------|----------|-------------|
| Show Main Window | — | Deminiaturizes and brings the main window to the front, restoring any panels that were hidden by the miniaturize. |
| Minimize | ⌘M | Minimize the main window (cascades to secondary panels). |
| Zoom | — | Zoom the main window. |
| Bring All to Front | — | Standard macOS window management. |
| Lights & Background… | ⌘L | Toggle the Lights & Background inspector panel. |
| Feedback… | ⌘F | Toggle the Feedback delay-line panel. |
| Color Grade… | ⌘G | Toggle the Color Grade panel. |
| Timeline Editor | ⌘J | Toggle the Timeline Editor panel. |

---

## Mouse Controls

Mouse behaviour depends on the active control mode (Camera / Light / Object) and whether Space is held.

### Left Drag

| Context | Action |
|---------|--------|
| **Space held** (any mode) | **Orbit** the camera around its target point |
| Camera or Light mode | **Pan** the camera — slides the orbit target |
| Object mode, playback paused | **Translate** the selected object in the camera's view plane |

### Right Drag

| Context | Action |
|---------|--------|
| Camera or Light mode | **Free-look** — camera position stays fixed, aim direction rotates |
| Object mode, playback paused | **Rotate** the selected object in camera space with axis lock: the drag accumulates until one axis clearly dominates (8 px threshold), then locks for the rest of the gesture. Horizontal drag rotates around the camera's up vector; vertical drag rotates around the camera's right vector. |

### Scroll Wheel

| Context | Action |
|---------|--------|
| Camera or Light mode | **Zoom** — adjusts the orbit distance |
| Object mode, no modifier | **Depth push/pull** — translates the object along the camera's forward axis |
| Object mode, **Option held** | **Uniform scale** around the object's visual centre |

---

## Keyboard Controls

### Mode Switching

These keys switch which scene element receives arrow-key input. Pressing the same key a second time while already in that mode cycles to the next item of that type.

| Key | Mode |
|-----|------|
| **C** | Camera — arrows pan; Shift+arrows free-look |
| **L** | Light — arrows rotate selected light; press again to cycle to the next light |
| **O** | Object — arrows translate selected object; press again to cycle to the next object |

The current mode is shown in the Scene HUD.

### Camera Mode (default)

| Key | Action |
|-----|--------|
| ← → ↑ ↓ | Pan camera left / right / up / down |
| Shift + ← → | Free-look — rotate aim direction left / right |
| Shift + ↑ ↓ | Free-look — rotate aim direction up / down |
| **+** / **=** | Zoom in |
| **−** | Zoom out |

### Light Mode

| Key | Action |
|-----|--------|
| ← → | Rotate selected light azimuth (horizontal) |
| ↑ ↓ | Rotate selected light elevation (vertical) |
| **+** / **=** | Move positional / spot / laser light forward |
| **−** | Move positional / spot / laser light backward |

### Object Mode

Arrow keys only affect the selected object when playback is **paused**.

| Key | Action |
|-----|--------|
| ← → | Translate along the X axis |
| ↑ ↓ | Translate along the Y axis |
| Shift + ← → | Rotate around the Y axis (yaw) |
| Shift + ↑ ↓ | Rotate around the X axis (pitch) |
| **[** | Roll left (around Z axis) |
| **]** | Roll right (around Z axis) |
| **+** / **=** | Translate along the Z axis (toward camera) |
| **−** | Translate along the Z axis (away from camera) |
| Option + **+** / **=** | Scale up uniformly |
| Option + **−** | Scale down uniformly |
| **R** | Reset rotation to base orientation (preserves position and scale) |

### Transport and Viewport Toggles

| Key | Action |
|-----|--------|
| **P** | Play / Pause playback |
| **T** | Toggle colour / greyscale rendering |
| **G** | Toggle wireframe display |
| **I** / Insert | Add a keyframe at the current playhead time for the active mode (Object, Camera, or Light) |
| **D** / Delete | Remove the selected keyframe in the Timeline Editor |
| Return | Commit the active in-place keyframe edit |
| Home | Jump playhead to start (t = 0) |
| End | Jump playhead to end |
| Tab | Advance playhead to the next keyframe on the active track |
| Shift + Tab | Retreat playhead to the previous keyframe on the active track |
| Space (hold) | While held, left-drag **orbits** the camera regardless of control mode |

---

## Scene HUD Overlay

The semi-transparent overlay in the top-left of the viewport shows:

- **Control Mode** badge — Camera / Light / Object
- **Object list** — one row per loaded model with the model name and an eye icon. Click the eye to toggle that object's visibility.
- The **selected object** is highlighted.

---

## Timeline Panel

The strip across the bottom of the window:

| Control | Description |
|---------|-------------|
| ⏹ Stop | Rewind to t = 0 and stop |
| ▶ / ⏸ Play / Pause | Start or pause playback (**P** key) |
| Time display | Current playhead position in MM:SS:FF |
| Scrubber | Drag to scrub through the animation |
| Duration label | Current timeline length. **Click** to open a popover and type a new duration in seconds, or pick a preset (5 s, 10 s, 15 s, 30 s, 60 s, 120 s). |
| Add Key | Add an object keyframe at the current playhead time for the selected object |
| Add Cam Key | Add a camera keyframe at the current playhead time |
| Export .mov | Open the export sheet |

While exporting, a progress bar replaces the Export button. All transport controls are disabled until the export completes.

---

## Animation Workflow

ThreeDViewport uses a **keyframe + delta** system:

1. **Load a model** — it is auto-normalised to fit a 1-unit bounding sphere and its rest pose is saved as the *base transform*.
2. Press **O** to enter Object mode and **pause** playback.
3. **Pose the object** using arrow keys, left-drag, scroll wheel, or right-drag.
4. **Scrub** the timeline to the desired time.
5. Press **I** (or click **Add Key**) to record the current pose as a keyframe.
6. Repeat for additional poses and times.
7. Press **P** to preview the animation.

### How Deltas Work

Each keyframe stores the *delta* between the object's base transform and its animated transform. During playback the renderer computes `baseTransform × interpolatedDelta` each frame. This means:

- Manual repositioning before adding any keyframes is preserved — the base transform is restored on project reload.
- Objects without keyframes keep their current transform across save/load.

### Camera Keyframes

Camera keyframes record absolute yaw, pitch, distance, and target. Add them with **Add Cam Key** in the Timeline Panel, or press **I** in the Timeline Editor with the Camera lane selected.

### Easing Modes

Each object track has an independently selectable easing mode, set via the popup in the Timeline Editor's label column. All modes except Linear affect the **path** the object travels, not just the timing.

| Mode | Description |
|------|-------------|
| **Linear** | Straight-line path, constant speed. Position and rotation interpolate directly between keyframes. |
| **Smooth** | Catmull-Rom spline path at standard tension. The path flows smoothly through each keyframe position without sharp corners. Rotation uses spherical cubic interpolation (squad). |
| **Spline S** | Same spline approach at reduced tension — a subtle arc that barely deviates from a straight line. Useful when a gentle curve is wanted without visible deflection. |
| **Spline M** | Standard Catmull-Rom tension — same path shape as Smooth. Convenient as a named reference point between S and L. |
| **Spline L** | Double tension — the path arcs noticeably outward at corners, giving a wide, sweeping trajectory. |

> **Note:** With only two keyframes there are no neighbours to create a curve, so all spline modes produce a straight path between two keyframes. The arc appears with three or more keyframes where the object would otherwise make a visible corner turn.

---

## Timeline Editor

Open with **Window › Timeline Editor** (⌘J). The panel auto-sizes its height to show all tracks and updates whenever objects or lights are added or removed.

```
┌────────────────────────────────────────────────────┐
│ [ruler]  0s    1s    2s    3s    4s    5s  …        │
│──────────────────────────────────────────────────  │
│ Camera  │  ◆              ◆                         │
│ Cube    │       ◆    ◆        ◆                     │
│ Lamp    │            ◆                              │
└────────────────────────────────────────────────────┘
```

- The **ruler** shows timecode in seconds. Click anywhere to scrub the playhead.
- Each **lane** shows the track name on the left and keyframe diamonds on the right.
- The **easing popup** sits in the label column for each object track. Camera and light tracks always use linear interpolation.
- The **red playhead** line moves in real time during playback.
- The timeline scale always fits the full duration in the available width. Resize the panel to zoom in.

### Timeline Editor Controls

| Action | Result |
|--------|--------|
| Click a **diamond** | Select it; playhead jumps to that keyframe's time |
| Click a **lane label** or empty lane area | Select that lane (deselects any diamond) |
| Click **outside all lanes** | Deselect everything |
| **Drag** a selected diamond | Retime the keyframe; playhead follows |
| ← → arrow keys | Nudge the selected diamond ±1 frame |
| **Delete** / **D** | Remove the selected keyframe |
| **Insert** / **I** | Stamp a new keyframe at the current playhead time for the selected lane |
| **Return** (on a selected diamond) | Enter **in-place edit mode** for that keyframe |
| **Return** (while editing) | Commit the new pose — overwrites the keyframe |
| **Escape** (while editing) | Cancel — restores the original pose |

### In-Place Keyframe Edit Mode

Select a diamond and press **Return** to enter edit mode. The diamond turns **amber** and a `● EDITING` badge appears in the ruler.

While editing:
- The timeline **pauses** at the keyframe's time.
- The viewport switches to the appropriate control mode automatically.
- All normal viewport mouse and keyboard controls work to adjust the pose.

Press **Return** to commit; press **Escape** to cancel and restore the original pose.

---

## Lights & Background Inspector

Open with **Window › Lights & Background…** (⌘L).

### Rendering

- **Color / Greyscale** toggle — switches the renderer between full PBR colour and greyscale output. Equivalent to **⌘T** or the **T** key.

### Background

| Control | Description |
|---------|-------------|
| Mode | Solid colour or gradient |
| Solid colour | Colour for solid mode |
| Top / Bottom colours | Gradient endpoint colours |

### Lights

Up to four simultaneous lights. Use the **+** button to add a light (choose type from the menu); use the **−** button on a row to remove it (at least one light must remain).

**Common controls for all light types:**

| Control | Range | Description |
|---------|-------|-------------|
| Enabled | on / off | Toggle the light on or off |
| Type | Ambient / Directional / Point / Spot / Laser | Change the light type |
| Colour | — | Light colour (no alpha) |
| Intensity | 0 – 10 | Light brightness |

**Positional lights (Point / Spot / Laser):**

| Control | Range | Description |
|---------|-------|-------------|
| Position X / Y / Z | −10 – +10 | World-space position |

**Oriented lights (Directional / Spot / Laser):**

| Control | Range | Description |
|---------|-------|-------------|
| Direction X / Y / Z | −1 – +1 | Direction vector (auto-normalised) |

**Spot and Laser:**

| Control | Range | Description |
|---------|-------|-------------|
| Inner cone angle | 0 – π/2 rad | Inner hot-spot boundary |
| Outer cone angle | 0 – π/2 rad | Soft falloff boundary |
| Range | 0 – 50 | Maximum beam / spot reach |

**Laser only:**

| Control | Range | Description |
|---------|-------|-------------|
| Beam Thickness | 1 – 30 | Rendered beam width. **1** = hairline; **≥ 2** = camera-facing billboard with soft Gaussian glow. |
| Exclude from feedback | on / off | When on, the beam is composited *after* the feedback pass and is never captured into the echo buffer — keeps a clean sharp beam while the lit scene still trails. |

Laser lights have no distance attenuation. The visible beam is depth-occluded by scene geometry and terminates at the first surface it hits.

Lights can also be adjusted with arrow keys after pressing **L** to enter Light mode. Press **L** again to cycle to the next light.

---

## Feedback Delay-Line

Open with **Window › Feedback…** (⌘F).

Blends the current frame with a delayed copy from a ring buffer, creating a video echo / trails effect.

| Control | Range | Description |
|---------|-------|-------------|
| Enable | on / off | Activate the feedback loop |
| Blend Mode | Normal, Multiply, Screen, Additive, Overlay, Soft Light, Difference, and more | How the feedback tap composites over the current frame |
| Feedback on top (Swap) | on / off | Reverses the blend order — composites the current frame on top of the feedback tap instead |
| Decay | 0.0 – 1.0 | Blend weight for the feedback tap per stored frame |
| Interval | 1 – 60 frames | How many rendered frames between feedback captures |
| Length | 1 – 60 frames | Ring buffer depth — number of delayed frames stored |
| **Clear Queue** | — | Flush the ring buffer and start fresh |

**Status indicator:**
- 🟠 *Priming…* — the buffer is filling (Length × Interval frames required before feedback becomes visible)
- 🟢 *Active* — the buffer is full and feedback is running

**Behaviour notes:**
- Feedback only runs during playback. The last blended frame is held on screen while paused.
- The queue is automatically cleared when playback starts so each play-through begins clean.
- Laser beams with **Exclude from feedback** are drawn after the feedback composite and are never captured into the buffer.
- Feedback settings are saved in the project file.

---

## Color Grade

Open with **Window › Color Grade…** (⌘G).

A full-screen post-process pass applied to every rendered frame, including exports. The pass is skipped entirely when all three controls are at their identity values.

| Control | Range | Identity | Description |
|---------|-------|----------|-------------|
| Brightness | −1.0 – +1.0 | 0.0 | Uniform additive shift applied to all channels before contrast |
| Contrast | 0.0 – 3.0 | 1.0 | Scales each channel around the 0.5 midpoint |
| Gamma | 0.2 – 3.0 | 1.0 | Power curve applied after brightness and contrast. Values **above 1.0** lift midtones (brighter); values **below 1.0** darken midtones. |

The **Reset** button appears whenever any control is off identity and returns all three to their identity values.

**Operation order in the shader:** Brightness → Contrast → Gamma. The result is clamped to [0, 1].

---

## Video Export

**File › Export ProRes Video…** (⌘E) renders the full timeline offline to a 1920 × 1080 `.mov` file. The export sheet offers two codec options:

| Codec | Description |
|-------|-------------|
| **ProRes 4444 — Alpha = Luma** | 12-bit RGB + alpha channel. The alpha value is the Rec.709 luma of each pixel (black → transparent, bright → opaque). Ready for direct compositing in DaVinci Resolve or LZX Videomancer without a separate key pass. |
| **ProRes 422 HQ — solid black** | 10-bit 4:2:2, no alpha. Highest-quality 422 variant; standard for CG renders destined for a colour-grading pipeline. |

The export renders every frame at the timeline's frame rate using an independent GPU pipeline. Feedback (if enabled) runs from a freshly-initialised processor to produce a clean, repeatable result. All keyframe animation — objects, camera, and lights — is fully evaluated. Color grade is applied if any parameter is off identity. The viewport is suspended during export and resumes automatically on completion.

---

## Project Files

Projects are saved as `.3dvp` files (human-readable JSON). The current format is **version 13**. All fields use sensible defaults so older project files load cleanly — unknown or missing keys are silently ignored.

Saved state includes:

- Timeline duration
- Camera position and keyframe track
- All loaded model paths (absolute) and per-object data:
  - Keyframe track with full TRS deltas
  - Base transform (rest pose matrix)
  - Easing mode
- Light configuration (type, colour, intensity, position, direction, cone angles, range, beam thickness, feedback-exclusion flag)
- Per-light keyframe tracks (intensity, colour, direction, position, range, beam thickness)
- Background configuration (solid / gradient, colours)
- Colour / greyscale rendering mode
- Wireframe and axes gizmo display state
- Loop playback setting
- Feedback settings (enabled, blend mode, swap, decay, interval, length)
- Color grade settings (brightness, contrast, gamma)
- Window and panel positions (main window, Timeline Editor, Lights & Background, Feedback, Color Grade)

Model files (`.glb` / `.gltf`) are referenced by absolute path and must remain accessible at their original location for the project to reload correctly.

---

## Supported Model Formats

- **glTF 2.0 Binary (`.glb`)** — single self-contained file with embedded geometry and textures.
- **glTF 2.0 JSON (`.gltf` + `.bin`)** — JSON descriptor alongside external binary buffer files. The `.bin` file(s) must remain in the same folder as the `.gltf`.

Both formats support PBR materials (base colour, normal, metallic/roughness, emissive textures), embedded or external meshes, and node transforms. Models are auto-normalised on load: scaled so their bounding sphere fits within a 1-unit radius and centred at the world origin.

If a model fails to load (for example, due to an unsupported extension such as Draco mesh compression), an alert describes the reason.
