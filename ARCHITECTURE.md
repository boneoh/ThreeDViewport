# ThreeDViewport Architecture

A native macOS 3D animation viewport built on Metal.

---

## Overview

ThreeDViewport loads `.glb`/`.gltf` models, animates them with keyframes, and exports to ProRes video. The architecture prioritizes real-time rendering performance, clean separation between preview and export paths, and persistent project state.

---

## Core Components

### Renderer (`Renderer.swift`)

Metal render loop controller implementing `MTKViewDelegate`. Manages:

- **Scene geometry pipeline**: PBR materials, multiple light sources, depth testing
- **Transparent pipeline**: Alpha-blended pass for materials with `baseColorFactor.w < 1` or `opacity < 1` (drawn after opaque, depth-tested, no depth write)
- **Holdout pipeline**: Depth-only rendering for occlusion
- **Background pipeline**: Solid, gradient, or HDRI-environment (skybox) backgrounds
- **Image-based lighting (IBL)**: Diffuse irradiance + specular prefilter + BRDF LUT from the loaded environment HDR (`IBL.swift`, `IBLShaders.metal`)
- **Laser systems**: Beam billboards and hit-effect particles
- **Weather particles**: Instanced billboard emitters (rain / snow / sleet)
- **Fog volume**: Raymarched volumetric fog using scene depth
- **Widget pass**: World-space line gizmos — probe, position marks, motion-path overlay, scene-mode camera/light widgets
- **Axes gizmo**: Orientation widget in viewport corner
- **Color grade**: Pre-tone-map exposure + post-process brightness/contrast/gamma
- **Scene mode**: Director camera for a free editing view of the animated scene

**Key design**: Single source-of-truth for rendering. The `Renderer` is the *viewport driver* — it owns the MTKView drawable, vsync, live-light decoupling, hit-testing, and the editor-only overlays (widgets, gizmos, probe, marks, motion path). The whole effect stack (background, skybox, fog, weather, lasers, color grade) is delegated to the shared `ScenePipeline` (below), so the live preview and the export path render it identically. The geometry mesh draw is shared via `SceneGeometryEncoder`.

---

### Compositing Core (`ScenePipeline.swift`)

Shared rendering core called by **both** the live `Renderer` and the offline `VideoExporter`. Built once by the `Renderer` and handed to the `VideoExporter`, so a new effect is added in one place and both paths pick it up identically.

- **Owns all effect pipeline states**: background gradient, environment skybox, laser beam / hit / spark, weather particles (+ the shared particle seed buffer), fog volume, color grade. Built once in `init`.
- **Per-pass encoders**: `encodeBackground`, `encodeParticles`, `encodeLaserBeams` / `encodeLaserHits` / `encodeSparks` / `encodeExcludedLaserBeams` (in-encoder passes), and `encodeFogVolume` / `encodeColorGrade` (own-encoder post passes).
- **`SceneRenderContext`**: one per-frame struct the driver fills with resolved camera, timing, scene/effect state, and mode flags — so deterministic-export vs wall-clock-live timing and scene-vs-director camera stay driver concerns.

**Stays in the drivers** (not in `ScenePipeline`): render-target/encoder ownership (drawable vs feedback scene-texture vs offscreen), the `LaserHitSystem` instances (each driver steps its own — live wall-clock vs deterministic export), overlays, and export-only post (countdown, luma-alpha, writer). See [RENDER_PIPELINE_REFACTOR.md](RENDER_PIPELINE_REFACTOR.md) for the design and migration history.

---

### SceneManager (`SceneManager.swift`)

Live scene graph owner. Maintains:

- Object list with selection state
- Group ID system for batch transformations
- Keyframe track management per group
- Entity lifecycle (add/remove/cycle selection)

**Key design**: Position-based object matching during project load preserves keyframes through model substitution.

---

### Timeline (`Timeline.swift`)

Playback state machine. `ObservableObject` for SwiftUI binding:

- Frame-accurate time advancement (configurable FPS: 23.976–60)
- Loop playback support
- Duration and scrub controls
- Loop revolution counter for feedback buffer management

**Key design**: Time never touches scene state directly. Renders query current time and evaluate keyframes.

---

### Camera System

**CameraController**: Free-transform camera (yaw/pitch/distance/FOV/target). Supports follow-mode where the camera tracks a selected object's world position and facing direction.

**Camera follow keyframes**: Capture relative offset + bearing. The followed object's `+Z` axis determines behind direction; camera rotates with object yaw and pitch. Uses visual center (mesh bounding box) rather than pivot for accuracy.

**Director camera**: Independent viewpoint in Scene mode. Renders scene from behind/above. Independent follow logic for previewing camera paths.

---

### Lighting System

Supports up to 4 simultaneous light types:

| Type           | Description                                                  |
|----------------|--------------------------------------------------------------|
| Ambient        | Flat fill, no position                                       |
| Directional    | World-space direction (sun-like)                             |
| Point          | Position-based decay                                         |
| Spot           | Cone angle, range, direction                                 |
| Laser          | Narrow beam, depth occlusion, optional thick billboard       |

Each light has a keyframe track for intensity, colour, position, target (world-space aim point), range, and beam thickness. Type, cone angles, and enabled state are static (not animated) and persisted per-light.

---

### Image-Based Lighting & Environment Baking

**IBL (`IBL.swift`)**: Precomputes a diffuse irradiance map, a specular prefilter
mip chain, and a BRDF integration LUT from the loaded lighting HDR (done once at
startup, so changing the HDR path takes effect on next launch). These feed the PBR
shader for realistic ambient reflection and are shared by preview and export. A
separate background HDR can drive the skybox without changing the lighting.

**Environment baking (`EnvironmentBaker.swift`)**: Renders the scene as a cube/
equirect capture from the [Probe](#probe--position-marks) position and writes an
`.hdr` (RGBE), so a scene can be turned into an environment map for re-lighting.

---

### Probe & Position Marks (`ProbeConfig.swift`)

A movable world-space point used both as the capture origin for environment baking
and as the source for **position marks** — saved, named, colour-coded world
positions drawn as small line gizmos. Marks persist with the project, can be cycled
(which recalls the probe to the mark), and optionally render into exports. The
probe gizmo itself is editor-only and never exported.

---

### Path Animators (`PathGenerator.swift`)

Pure geometry that generates keyframes for the selected camera, light, or object:

- **Orbit** — a constant-height **planar** circle around a Probe-defined axis,
  driven by **rate markers** (rev/s). Camera/lights aim at the orbit centre; objects
  turn to face it.
- **Linear** — a straight line between two Probe points (`linearSamples`).
  Camera/lights keep their current orientation (parallel dolly); objects face the
  direction of travel.
- **Curve** — a flat spiral arc that sweeps from a start to an end point around an
  aim point, easing its radius in/out (`curveSamples`).
- **Spin** — a constant, wobble-free **self-spin** about the object's (or model's)
  own local axis, also driven by **rate markers**; pure-rotation, in place.

Linear and Curve convert each world-space path point into the appropriate track
representation (camera orbit params, light position+target, or an object delta on
`baseTransform` that preserves scale) and replace the track's keyframes within the
captured time window.

Orbit and Spin instead keep an editable **rate schedule** per track
(`Animation/RateSchedule.swift`, stored on `ViewportView` keyed by `TrackRef`): each
marker holds a rate that runs until the next marker (the last to the timeline end;
rate 0 = stop). `ViewportView.setSpinSchedule` / `setOrbitSchedule` regenerate the
dense keyframes from the markers (continuous angle across segments, forced linear
easing), so playback and export are unchanged. The schedules persist in the project
file (v35). Euler/transform math lives in `TransformMath.swift`.

---

### Feedback System

Video delay-line echo/tails pass. Ring buffer composites current frame with delayed copy:

- Configurable decay weight
- Capture interval
- Ring buffer length
- Multiple blend modes (Normal, Multiply, Screen, Additive, Overlay, etc.)

**Key design**: Feedback runs only during playback and export. Frozen when paused.

---

### Export Pipeline (`VideoExporter.swift`)

Offline rendering to ProRes `.mov` at the resolution set in Settings (default 1920×1080; camera aspect is matched to it):

1. **Offscreen Metal textures**: Private render target, pipelined two-deep (one slot when feedback is active)
2. **Frame loop**: Evaluate animation → render → blit to CPU staging → read back
3. **AVAssetWriter**: Append CVPixelBuffers at rational timestamps
4. **Codec options**:
   - **ProRes 4444** — colour passes write full RGB with **alpha = Rec.709 luma** via a GPU pass, tagged **premultiplied** so RGB displays at full brightness with the luma usable as a key; matte passes keep a geometry-coverage alpha.
   - **ProRes 422 HQ** — 10-bit 4:2:2, no alpha, black background.
5. **Sync countdown**: every export is prepended with a 3-2-1 countdown + white flash frame (generated via CoreGraphics through the same writer) for frame-accurate alignment.
6. **Export All**: a multi-pass driver renders Scene / Solo / Matte / Background / FX passes (driven by per-object class) to numbered files for compositing.

**Key pipeline reuse**: The export is the *export driver* — it owns the offscreen target, deterministic per-frame clock, codec/alpha handling, and the export-only post (luma-alpha rewrite, countdown). The effect stack (background, skybox, fog, weather, lasers, color grade) is rendered through the **shared `ScenePipeline`** (see Renderer §), and geometry through `SceneGeometryEncoder`, so the output matches the live preview by construction.

**Timing**: Uses rational CMTime (e.g. 30000/1001 for 29.97fps) for exact NTSC rates.

---

## Project File Format

Human-readable JSON schema (`.3dvp`). The schema is **additive** — older files load
with backfilled defaults, and unknown/missing keys are ignored. A version field is
stored, but compatibility relies on per-key defaulting rather than a hard version gate.

**Persisted state**:

| Category          | Fields                                                                         |
|-------------------|--------------------------------------------------------------------------------|
| Timeline          | Duration, loop toggle, frame rate                                              |
| Camera            | Pose (yaw/pitch/dist/target/FOV) + keyframe track with follow metadata + easing |
| Objects           | Paths, base transforms, keyframes (+ easing), material factors, base colour, normal mode, object class, visibility/holdout |
| Light configs     | Type, intensity, colour, position, target, cone angles, range, beam thickness  |
| Light keyframes   | Per-light intensity/colour/position/target/range/beam tracks (+ easing)        |
| Group keyframes   | Filename-keyed group transforms                                                |
| Background        | Mode (solid/gradient/environment) + colours; environment intensity/horizon     |
| HDR paths         | Lighting HDR + background HDR paths                                            |
| IBL               | IBL intensity                                                                  |
| Feedback          | Interval, decay, length, blend mode, swap                                      |
| Color grade       | Exposure, brightness, contrast, gamma                                          |
| Fog volume        | Position/size, colour, density, variance, raymarch steps + keyframes (+ easing) |
| Weather emitters  | Per-emitter type/position/size/colour/density config + keyframes (+ easing)    |
| Probe + marks     | Probe position; named position marks (name, position, colour) + visibility     |
| Render settings   | Render mode (colour / greyscale / B+W), wireframe, axes gizmo                   |
| Window layout     | Main + all panel positions + section collapse state                            |

**Backward compatibility**: Missing keys backfill (FOV defaults 27°, no keyframes = empty track; pre-marks files get no marks). Missing models prompt for relocation.

---

## UI Architecture

### Window Hierarchy

```
Main Window (1920×1160)
├── ViewportView (1920×1080, Metal rendering)
│   ├── SceneOverlayView (top-left HUD)
└── TimelinePanel (bottom 80pt, SwiftUI)
```

### Floating Inspector Panels

All panels are `NSPanel` (floating, non-modal):

| Panel                  | Menu Shortcut | Purpose                                       |
|------------------------|---------------|-----------------------------------------------|
| Camera                 | ⌘K            | Follow-target picker, stamp keys              |
| Lights & Background    | ⌘L            | Multi-light config + background (solid/gradient/HDRI) + IBL |
| Feedback               | ⌘F            | Feedback delay parameters                     |
| Color Grade            | ⌘⇧G           | Exposure / brightness / contrast / gamma      |
| Atmosphere             | ⌘⇧A           | Fog + weather emitter config                  |
| Model Inspector        | ⌘I            | Per-object transform, material, class, normal mode |
| Probe Inspector        | —             | Probe position + named position marks         |
| Path Animator          | —             | Rotation / Linear keyframe generators (submenu) |
| Timeline Editor        | ⌘J            | Per-track keyframe editor (retime, copy/paste, easing) |
| Settings               | ⌘,            | Folders, export resolution + default codec    |

Detailed per-panel docs live in [`docs/`](docs/).

**Behavior**: Panels remember positions per project. Hide when main window minimized. Do not steal viewport focus (except Timeline Editor for keyboard shortcuts).

---

## Key Design Patterns

### Scene Mode (Director's POV)

Toggle `S` to view scene from Director camera instead of scene camera. Director sees scene camera frustum as wireframe wedge. Useful for:

- Previewing camera follow paths
- Debugging framing
- Recording reference shots

**Solo mode**: Hide all objects except selected group (keys 7/8). Optional depth-only holdouts.

### Group Animation

Multi-part models (robots, rigs) can be transformed as a unit. Group ID derived from source filename. Group keyframes evaluated each frame and pre-multiplied with per-part transforms.

**Preservation**: Group transforms persist through model replacement because matching uses filename→groupID map plus alias handling for substituted models.

### Material System

PBR factors (metallic, roughness, base color) per object. Normal mode selection (auto/generate/vertex). IBL (image-based lighting) shared between preview and export.

### Flat Normal Generation

When model lacks normals, computed from UV derivatives for consistent lighting across imported geometry.

---

## Performance Considerations

### GPU Memory

- All render passes use `.storageModeShared` (unified) or `.managed` (discrete GPU)
- Staging textures for CPU readback during export
- Feedback textures capped at 1920×1080 even on Retina displays

### Animation Evaluation

- Keyframe interpolation deferred to render time (not preview time)
- Camera follow evaluated after hierarchy update each frame
- Atmospheric panels sync to playhead only on scrub

### Export Throughput

- Background-thread rendering queue (QoS: userInitiated)
- `waitUntilCompleted()` on frame blits before pixel readback
- `frameRate`-progress callbacks to UI while rendering

---

## Error Handling & Robustness

### Model Loading

- Missing models prompt for relocation
- Source URL deduplication avoids redundant loads
- Name-based + position-based matching survives structural changes

### Project Files

- Additive schema with a stored version field; per-key defaulting handles old files
- Backfilled defaults for missing keys
- Error messages for encoding/decoding failures

### Export Failures

- `AVAssetWriter` status checks on `startWriting`
- Per-frame fallback if pixel buffer creation fails
- Detailed logging for codec not supported

---

## Dependencies

- **Metal / MetalKit**: Rendering pipelines
- **AVFoundation**: ProRes export via `AVAssetWriter`
- **CoreVideo**: Pixel buffer management
- **GLTFKit2** (SPM dependency): gltf/glb parsing, hierarchy traversal
- **Pure Swift / simd**: Transform math, keyframe interpolation

---

## Future Extension Points

- Additional light types (rect area lights, volume lights)
- Shader model swapping (PBR simplified variants for Intel GPU)
- Real-time waveform/level meter overlay
- Export presets (aspect ratios, frame rates)

> Scene camera path visualization (the **V** motion-path overlay) and a configurable
> export resolution are now implemented.

---

*ThreeDViewport v1.0.2*
