# ThreeDViewport v2 - Requirements

## Overview
macOS application for loading .glb models, animating objects/camera/lights, and exporting video.

## Tech Stack

| Component | Choice |
|-----------|--------|
| Rendering | Native Metal (custom shaders) |
| glTF Loading | SwiftGLTFParser (upstream) |
| UI | Mixed: AppKit viewport + SwiftUI panels |
| Export | 30fps ProRes .mov  1080p30 |

## Structure
```
ThreeDViewport/
├── App/                 (AppDelegate, main entry)
├── Renderer/            (Metal renderer, shaders)
├── Scene/               (SceneManager, SceneObject, GLTFLoader)
├── Camera/              (CameraController, CameraKeyframe)
├── Lights/              (LightManager, LightConfig)
├── Animation/           (Timeline, Interpolation, Keyframes)
├── UI/
│   ├── ViewportView.swift (Metal viewport - AppKit)
│   └── Panels/          (SwiftUI panels)
└── Project/             (ProjectFile, ProjectJSON)
```

## Project File Format
Single .json file storing paths to glb models, camera animation, light animation, and object transforms. No inline binary data.
No Swift String Interpolations


## Keyboard Controls
- **Mouse drag**: Orbit camera  
- **Scroll wheel**: Zoom  
- **Space + drag**: Pan  
- **G key**: Toggle wireframe  
- **Shift + click**: Multi-select objects  

## MVP Phase 1 Scope
**Must deliver:**
- Load single .glb model
- Orbit camera (mouse controls)
- Directional light
- Render at 30fps (native Metal)
- Wireframe toggle (G key)

**Out of scope:**
- Multiple objects
- Animation system
- Project file I/O
- Timeline UI

## Success Criteria
Can load Duck.glb, orbit camera, see model in wireframe, application doesn't crash.

---

## Future Phases

### Phase 2: Animation
- Single object animation (position/scale/rotation)
- Basic timeline UI

### Phase 3: Multi-Object
- Multiple .glb加载
- All objects animatable

### Phase 4: Export
- Camera animation
- JSON project save/load
- Video export (ProRes)
