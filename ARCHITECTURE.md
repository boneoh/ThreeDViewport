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
- **Holdout pipeline**: Depth-only rendering for occlusion
- **Background pipeline**: Gradient or solid backgrounds
- **Laser systems**: Beam billboards and hit effect particles
- **Weather particles**: Instanced billboard emitters
- **Fog volume**: Raymarched volumetric fog using scene depth
- **Axes gizmo**: Orientation widget in viewport corner
- **Color grade**: Post-process brightness/contrast/gamma
- **Scene mode**: Director camera for overhead viewport of animated scene

**Key design**: Single source-of-truth for rendering. Export path reuses the same pipeline states.

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

Each light has keyframe tracks for intensity, color, position, and direction. Static config persisted per-light.

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

Offline rendering to ProRes `.mov` at 1920×1080:

1. **Offscreen Metal textures**: Private render target
2. **Frame loop**: Evaluate animation → render → blit to CPU staging
3. **AVAssetWriter**: Append CVPixelBuffers at rational timestamps
4. **Codec options**: ProRes 4444 (alpha=luma) or ProRes 422 HQ (black background)

**Key pipeline reuse**: Same Metal library functions as live preview. Holdout, gizmo, laser, weather, fog, and color grade all match preview exactly.

**Timing**: Uses rational CMTime (e.g. 30000/1001 for 29.97fps) for exact NTSC rates.

---

## Project File Format (v25)

Human-readable JSON schema (`.3dvp`). Additive evolution—older files load with backfilled defaults.

**Persisted state**:

| Category          | Fields                                                                         |
|-------------------|--------------------------------------------------------------------------------|
| Timeline          | Duration, loop toggle, frame rate, loop revolutions                            |
| Camera            | Static pose (yaw/pitch/dist/target/FOV) + keyframe track with follow metadata |
| Objects           | Paths, base transforms, keyframes, material factors, normal mode               |
| Light configs     | Type, intensity, color, position, cone angles, beam thickness                  |
| Light keyframes   | Per-light intensity/color/direction tracks                                    |
| Group keyframes   | Filename-keyed group transforms (v14+)                                        |
| Background        | Solid/gradient colors                                                         |
| Feedback          | Interval, decay, length, blend mode                                           |
| Color grade       | Exposure, brightness, contrast, gamma                                         |
| Fog volume        | Box min/max, color, density, variance, raymarch steps                         |
| Weather emitters  | Per-emitter type/position/color/density config + keyframes                   |
| Window layout     | Main + all panel positions + section collapse state                           |

**Backward compatibility**: Missing keys backfill (FOV defaults 27°, no keyframes = empty track). Missing models prompt for relocation.

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

| Panel                  | Menu Shortcut | Purpose                              |
|------------------------|---------------|--------------------------------------|
| Camera                 | ⌘K            | Follow-target picker, stamp keys     |
| Lights & Background    | ⌘L            | Multi-light config + bg gradient     |
| Feedback               | ⌘F            | Feedback delay parameters            |
| Color Grade            | ⌘⇧G           | Brightness/contrast/gamma            |
| Atmosphere             | ⌘⇧A           | Fog + weather emitter config         |
| Model Inspector        | ⌘I            | Per-object material/normal mode      |
| Timeline Editor        | ⌘J            | Per-track keyframe retiming editor   |

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

- Schema version check (current: v25)
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
- Scene camera path visualization

---

*ThreeDViewport v1.0.2*
