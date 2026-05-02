import AppKit
import MetalKit
import simd

// MARK: - Control mode

// Determines which scene element receives keyboard arrow-key input.
enum ControlMode {
    case camera
    case light
    case object

    var displayName: String {
        switch self {
        case .camera: return "Camera"
        case .light:  return "Light"
        case .object: return "Object"
        }
    }
}

// MARK: - ViewportView

final class ViewportView: MTKView {

    // Owned scene objects
    let sceneManager:     SceneManager
    let camera:           CameraController
    let lightManager:     LightManager
    let backgroundConfig: BackgroundConfig
    let timeline:         Timeline
    var renderer: Renderer?

    // Phase 6: HUD observable state — AppDelegate embeds the SwiftUI overlay using this.
    let overlayState = SceneOverlayState()

    // Active control mode: camera / light / object.
    // Writing updates the HUD automatically.
    private var controlMode: ControlMode = .camera {
        didSet {
            overlayState.controlMode = controlMode
            print("[DEBUG] ViewportView: controlMode = " + controlMode.displayName)
        }
    }

    // Input state
    private var lastMouseLocation: NSPoint = .zero
    private var isSpaceDown: Bool = false

    // Holds the VideoExporter alive for the duration of an export.
    private var activeExporter: VideoExporter?

    // MARK: - Init

    init(frame: NSRect) {
        sceneManager     = SceneManager()
        camera           = CameraController()
        lightManager     = LightManager()
        backgroundConfig = BackgroundConfig()
        timeline         = Timeline()

        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            fatalError("[DEBUG] ViewportView: MTLCreateSystemDefaultDevice returned nil — Metal not supported")
        }

        super.init(frame: frame, device: metalDevice)

        print("[DEBUG] ViewportView: Metal device '" + metalDevice.name + "'")

        colorPixelFormat         = .bgra8Unorm
        depthStencilPixelFormat  = .depth32Float
        clearColor               = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        preferredFramesPerSecond = 30
        isPaused                 = false
        enableSetNeedsDisplay    = false

        renderer = Renderer(
            device:           metalDevice,
            sceneManager:     sceneManager,
            camera:           camera,
            lightManager:     lightManager,
            backgroundConfig: backgroundConfig,
            timeline:         timeline
        )

        if renderer == nil {
            print("[DEBUG] ViewportView: Renderer init returned nil")
        }

        delegate = renderer

        // Wire visibility toggle callback
        overlayState.onToggleVisibility = { [weak self] index in
            self?.sceneManager.toggleVisibility(at: index)
            self?.syncOverlayState()
        }

        syncOverlayState()
    }

    required init(coder: NSCoder) {
        fatalError("ViewportView does not support NSCoder initialisation")
    }

    // MARK: - Model Loading

    // Replaces the entire scene with a single model (Open Model... menu item).
    func loadModel(url: URL) {
        guard let dev = device else {
            print("[DEBUG] ViewportView: loadModel — device is nil")
            return
        }

        print("[DEBUG] ViewportView: loadModel start — " + url.lastPathComponent)

        let loader = GLTFLoader(device: dev)

        if let obj = loader.load(url: url) {
            autoNormalize(obj)
            obj.baseTransform = obj.transform
            obj.sourceURL     = url

            sceneManager.objects = [obj]
            sceneManager.selectedIndex = 0
            camera.fitToScene(boundingRadius: obj.boundingRadius, center: obj.boundingCenter)
            createDemoAnimation(for: obj)
            syncOverlayState()

            print("[DEBUG] ViewportView: loadModel complete — objects=" + String(sceneManager.objects.count))
        } else {
            print("[DEBUG] ViewportView: GLTFLoader returned nil for " + url.lastPathComponent)
        }
    }

    // Phase 6: Adds a model to the existing scene without clearing it.
    // Camera is only repositioned when this is the very first object.
    func addModelToScene(url: URL) {
        guard let dev = device else {
            print("[DEBUG] ViewportView: addModelToScene — device is nil")
            return
        }

        print("[DEBUG] ViewportView: addModelToScene start — " + url.lastPathComponent)

        let loader = GLTFLoader(device: dev)

        if let obj = loader.load(url: url) {
            autoNormalize(obj)
            obj.baseTransform = obj.transform
            obj.sourceURL     = url

            let isFirst = sceneManager.objects.isEmpty
            sceneManager.objects.append(obj)
            sceneManager.selectedIndex = sceneManager.objects.count - 1

            if isFirst {
                camera.fitToScene(boundingRadius: obj.boundingRadius, center: obj.boundingCenter)
            }

            // No demo animation for additional objects — user authors their own keyframes.
            syncOverlayState()

            print("[DEBUG] ViewportView: addModelToScene complete — total objects=" + String(sceneManager.objects.count))
        } else {
            print("[DEBUG] ViewportView: GLTFLoader returned nil for " + url.lastPathComponent)
        }
    }

    // MARK: - Overlay sync

    // Rebuilds the HUD state from live scene data.
    // Call after any mutation that changes object count, names, or visibility.
    func syncOverlayState() {
        overlayState.controlMode      = controlMode
        overlayState.objectNames      = sceneManager.objects.map { $0.name }
        overlayState.objectVisibility = sceneManager.objects.map { $0.isVisible }
        overlayState.selectedIndex    = sceneManager.selectedIndex
    }

    // MARK: - Auto-normalization

    private func autoNormalize(_ obj: SceneObject) {
        let targetRadius: Float = 1.0
        let t = obj.transform
        let localCenter = obj.boundingCenter
        let localRadius = obj.boundingRadius

        let lc4 = SIMD4<Float>(localCenter.x, localCenter.y, localCenter.z, 1.0)
        let wc4 = t * lc4
        let worldCenter = SIMD3<Float>(wc4.x, wc4.y, wc4.z)

        let sx = simd_length(SIMD3<Float>(t.columns.0.x, t.columns.0.y, t.columns.0.z))
        let sy = simd_length(SIMD3<Float>(t.columns.1.x, t.columns.1.y, t.columns.1.z))
        let sz = simd_length(SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z))
        let transformScale = max(sx, max(sy, sz))

        if transformScale < 0.0001 {
            print("[DEBUG] ViewportView: autoNormalize — transform scale near zero, skipping")
            return
        }

        let worldRadius = localRadius * transformScale
        print("[DEBUG] ViewportView: autoNormalize localRadius=" + String(localRadius)
            + " transformScale=" + String(transformScale)
            + " worldRadius=" + String(worldRadius))

        guard worldRadius > 0.0001 else {
            print("[DEBUG] ViewportView: autoNormalize — worldRadius near zero, skipping")
            return
        }

        obj.boundingCenter = worldCenter
        obj.boundingRadius = worldRadius

        let scale = targetRadius / worldRadius
        guard abs(scale - 1.0) > 0.02 else {
            print("[DEBUG] ViewportView: autoNormalize — worldRadius " + String(worldRadius) + " already near 1.0")
            return
        }

        var S = matrix_identity_float4x4
        S.columns.0.x = scale
        S.columns.1.y = scale
        S.columns.2.z = scale

        obj.transform      = S * t
        obj.boundingCenter = worldCenter * scale
        obj.boundingRadius = targetRadius

        print("[DEBUG] ViewportView: autoNormalize scale=" + String(scale)
            + " worldRadius=" + String(worldRadius) + " -> " + String(targetRadius))
    }

    // MARK: - Demo animation

    private func createDemoAnimation(for obj: SceneObject) {
        let animDuration = timeline.duration
        let track    = KeyframeTrack()
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let half     = simd_quatf(angle: Float.pi, axis: SIMD3<Float>(0, 1, 0))

        track.addKeyframe(TransformKeyframe(time: 0,                 rotation: identity))
        track.addKeyframe(TransformKeyframe(time: animDuration * 0.5, rotation: half))
        track.addKeyframe(TransformKeyframe(time: animDuration,       rotation: identity))

        obj.keyframeTrack = track

        print("[DEBUG] ViewportView: demo rotation created, duration=" + String(animDuration)
            + "s keyframes=" + String(track.keyframes.count))
    }

    // MARK: - Add Object Keyframe

    func addKeyframeAtCurrentTime() {
        // Use selectedObject so the keyframe targets the active object.
        guard let obj = sceneManager.selectedObject ?? sceneManager.primaryObject else {
            print("[DEBUG] ViewportView: addKeyframeAtCurrentTime — no object selected")
            return
        }

        if obj.keyframeTrack == nil {
            obj.keyframeTrack = KeyframeTrack()
            print("[DEBUG] ViewportView: created new KeyframeTrack for '" + obj.name + "'")
        }

        let invBase = simd_inverse(obj.baseTransform)
        let m = invBase * obj.transform

        let translation = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)

        let sx = simd_length(SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z))
        let sy = simd_length(SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z))
        let sz = simd_length(SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        let scale = SIMD3<Float>(sx, sy, sz)

        let rotation: simd_quatf
        if sx > 0.0001 && sy > 0.0001 && sz > 0.0001 {
            let rotMat = matrix_float3x3(columns: (
                SIMD3<Float>(m.columns.0.x / sx, m.columns.0.y / sx, m.columns.0.z / sx),
                SIMD3<Float>(m.columns.1.x / sy, m.columns.1.y / sy, m.columns.1.z / sy),
                SIMD3<Float>(m.columns.2.x / sz, m.columns.2.y / sz, m.columns.2.z / sz)
            ))
            rotation = simd_quatf(rotMat)
        } else {
            rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            print("[DEBUG] ViewportView: addKeyframe — near-zero delta scale, using identity rotation")
        }

        let kf = TransformKeyframe(
            time:        timeline.currentTime,
            translation: translation,
            rotation:    rotation,
            scale:       scale
        )
        obj.keyframeTrack?.addKeyframe(kf)

        print("[DEBUG] ViewportView: keyframe added at t=" + String(format: "%.3f", timeline.currentTime)
            + " for '" + obj.name + "'")
    }

    // MARK: - Add Camera Keyframe

    func addCameraKeyframeAtCurrentTime() {
        if camera.keyframeTrack == nil {
            camera.keyframeTrack = CameraKeyframeTrack()
            print("[DEBUG] ViewportView: created new CameraKeyframeTrack")
        }

        let kf = CameraKeyframe(
            time:     timeline.currentTime,
            yaw:      camera.yaw,
            pitch:    camera.pitch,
            distance: camera.distance,
            target:   camera.target
        )
        camera.keyframeTrack?.addKeyframe(kf)

        print("[DEBUG] ViewportView: camera keyframe added at t="
            + String(format: "%.3f", timeline.currentTime)
            + " yaw=" + String(format: "%.4f", camera.yaw)
            + " pitch=" + String(format: "%.4f", camera.pitch)
            + " distance=" + String(format: "%.4f", camera.distance))
    }

    // MARK: - Video Export

    func startExport(to url: URL, codec: ExportCodec, exportState: ExportState) {
        guard let dev = device else {
            print("[DEBUG] ViewportView: startExport — Metal device is nil")
            return
        }
        guard let r = renderer,
              let pipeline = r.pipelineState,
              let depth    = r.depthStencilState else {
            print("[DEBUG] ViewportView: startExport — renderer pipeline not ready")
            exportState.lastMessage = "Export failed: renderer not ready"
            return
        }
        guard let exporter = VideoExporter(
            device:            dev,
            commandQueue:      r.commandQueue,
            sceneManager:      sceneManager,
            camera:            camera,
            lightManager:      lightManager,
            timeline:          timeline,
            pipelineState:     pipeline,
            depthStencilState: depth
        ) else {
            print("[DEBUG] ViewportView: startExport — VideoExporter init returned nil")
            return
        }

        timeline.pause()
        isPaused = true
        camera.aspectRatio = Float(exporter.width) / Float(exporter.height)

        exportState.isExporting = true
        exportState.progress    = 0.0
        exportState.lastMessage = ""

        activeExporter = exporter

        exporter.export(to: url, codec: codec, progress: { [weak exportState] p in
            exportState?.progress = p
        }, completion: { [weak self, weak exportState] error in
            self?.activeExporter = nil
            self?.isPaused = false
            exportState?.isExporting = false
            if let error = error {
                exportState?.lastMessage = "Export failed: " + error.localizedDescription
                print("[DEBUG] ViewportView: export failed — " + error.localizedDescription)
            } else {
                exportState?.lastMessage = "Export complete!"
            }
        })
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { return true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    // MARK: - Mouse Input

    override func mouseDown(with event: NSEvent) {
        lastMouseLocation = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let dx  = Float(loc.x - lastMouseLocation.x)
        let dy  = Float(loc.y - lastMouseLocation.y)
        lastMouseLocation = loc

        if isSpaceDown {
            camera.pan(deltaX: dx, deltaY: dy)

        } else if !timeline.isPlaying,
                  let obj = sceneManager.selectedObject ?? sceneManager.primaryObject {
            // Paused + drag: rotate the selected object in world space for pose authoring.
            let sensitivity: Float = 0.005
            let yaw   = simd_quatf(angle:  dx * sensitivity, axis: SIMD3<Float>(0, 1, 0))
            let pitch = simd_quatf(angle: -dy * sensitivity, axis: SIMD3<Float>(1, 0, 0))
            let delta = simd_normalize(pitch * yaw)
            obj.transform = rotationMatrix4x4(delta) * obj.transform

        } else {
            camera.orbit(deltaX: dx, deltaY: dy)
        }
    }

    private func rotationMatrix4x4(_ q: simd_quatf) -> matrix_float4x4 {
        let n = simd_normalize(q)
        let x = n.imag.x, y = n.imag.y, z = n.imag.z, w = n.real
        return matrix_float4x4(columns: (
            SIMD4<Float>(1 - 2*(y*y + z*z),     2*(x*y + z*w),     2*(x*z - y*w), 0),
            SIMD4<Float>(    2*(x*y - z*w), 1 - 2*(x*x + z*z),     2*(y*z + x*w), 0),
            SIMD4<Float>(    2*(x*z + y*w),     2*(y*z - x*w), 1 - 2*(x*x + y*y), 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    override func scrollWheel(with event: NSEvent) {
        camera.zoom(delta: Float(event.scrollingDeltaY))
    }

    // MARK: - Keyboard Input

    // Key code constants
    private enum KC {
        static let space:    UInt16 = 49
        static let g:        UInt16 = 5    // wireframe
        static let c:        UInt16 = 8    // camera mode
        static let l:        UInt16 = 37   // light mode
        static let o:        UInt16 = 31   // object mode / cycle
        // Regular arrow keys
        static let left:     UInt16 = 123
        static let right:    UInt16 = 124
        static let down:     UInt16 = 125
        static let up:       UInt16 = 126
        // Keypad arrow keys
        static let kp4:      UInt16 = 86   // ←
        static let kp6:      UInt16 = 88   // →
        static let kp8:      UInt16 = 91   // ↑
        static let kp2:      UInt16 = 84   // ↓
        // Zoom / intensity
        static let kpPlus:   UInt16 = 69   // keypad +
        static let kpMinus:  UInt16 = 78   // keypad −
        static let regMinus: UInt16 = 27   // regular −
        static let regEqual: UInt16 = 24   // regular = / + (Shift+=)
    }

    // Step sizes for arrow-key navigation
    // panStep is passed to camera.pan() which applies its own sensitivity×distance scaling,
    // so the on-screen movement stays proportional to the current zoom level.
    private let panStep:       Float = 50.0             // camera pan pixels-equivalent per key
    private let translateStep: Float = 0.05             // world-units per key (object & object Z)
    private let lightStep:     Float = Float.pi / 36.0  // 5° per key (light azimuth / elevation)
    private let intensityStep: Float = 0.1
    private let zoomStep:      Float = 0.1              // fraction of current distance per key

    override func keyDown(with event: NSEvent) {
        let kc = event.keyCode

        // ── Mode-switch keys — single-fire only (no repeat) ──────────────────
        if !event.isARepeat {
            switch kc {
            case KC.space:
                isSpaceDown = true
                return

            case KC.g:
                renderer?.isWireframe.toggle()
                print("[DEBUG] ViewportView: wireframe = " + String(renderer?.isWireframe ?? false))
                return

            case KC.c:
                controlMode = .camera
                syncOverlayState()
                return

            case KC.l:
                if controlMode == .light {
                    // Already in light mode — cycle to next light.
                    lightManager.cycleSelection()
                } else {
                    controlMode = .light
                    syncOverlayState()
                }
                return

            case KC.o:
                if controlMode == .object {
                    // Already in object mode — cycle to next object.
                    sceneManager.cycleSelection()
                    syncOverlayState()
                } else {
                    controlMode = .object
                    syncOverlayState()
                }
                return

            default:
                break
            }
        }

        // ── Directional keys — allow repeat so holding feels smooth ──────────
        switch kc {

        // ── Left arrow / KP4 ─────────────────────────────────────────────────
        case KC.left, KC.kp4:
            switch controlMode {
            case .camera:
                // Pan camera left in view space
                camera.pan(deltaX: -panStep, deltaY: 0)
            case .light:
                // Azimuth left for directional/spot/laser; horizontal for point
                lightManager.rotateSelected(deltaAzimuth: -lightStep, deltaElevation: 0)
            case .object:
                if let obj = sceneManager.selectedObject {
                    obj.transform.columns.3.x -= translateStep
                }
            }

        // ── Right arrow / KP6 ────────────────────────────────────────────────
        case KC.right, KC.kp6:
            switch controlMode {
            case .camera:
                camera.pan(deltaX: panStep, deltaY: 0)
            case .light:
                lightManager.rotateSelected(deltaAzimuth: lightStep, deltaElevation: 0)
            case .object:
                if let obj = sceneManager.selectedObject {
                    obj.transform.columns.3.x += translateStep
                }
            }

        // ── Up arrow / KP8 ───────────────────────────────────────────────────
        case KC.up, KC.kp8:
            switch controlMode {
            case .camera:
                camera.pan(deltaX: 0, deltaY: panStep)
            case .light:
                lightManager.rotateSelected(deltaAzimuth: 0, deltaElevation: -lightStep)
            case .object:
                if let obj = sceneManager.selectedObject {
                    obj.transform.columns.3.y += translateStep
                }
            }

        // ── Down arrow / KP2 ─────────────────────────────────────────────────
        case KC.down, KC.kp2:
            switch controlMode {
            case .camera:
                camera.pan(deltaX: 0, deltaY: -panStep)
            case .light:
                lightManager.rotateSelected(deltaAzimuth: 0, deltaElevation: lightStep)
            case .object:
                if let obj = sceneManager.selectedObject {
                    obj.transform.columns.3.y -= translateStep
                }
            }

        // ── Plus / KP+ — zoom in / light depth in / object +Z ────────────────
        case KC.kpPlus, KC.regEqual:
            switch controlMode {
            case .camera:
                camera.zoom(delta: camera.distance * zoomStep / 0.05)
            case .light:
                // Move positional light forward along its direction (+Z into scene)
                lightManager.moveSelectedDepth(delta: translateStep * 2)
            case .object:
                if let obj = sceneManager.selectedObject {
                    obj.transform.columns.3.z += translateStep
                }
            }

        // ── Minus / KP− — zoom out / light depth out / object −Z ─────────────
        case KC.kpMinus, KC.regMinus:
            switch controlMode {
            case .camera:
                camera.zoom(delta: -(camera.distance * zoomStep / 0.05))
            case .light:
                lightManager.moveSelectedDepth(delta: -translateStep * 2)
            case .object:
                if let obj = sceneManager.selectedObject {
                    obj.transform.columns.3.z -= translateStep
                }
            }

        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        switch event.keyCode {
        case KC.space: isSpaceDown = false
        default:       super.keyUp(with: event)
        }
    }
}
