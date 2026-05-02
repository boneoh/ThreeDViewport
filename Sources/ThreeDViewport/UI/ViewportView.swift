import AppKit
import MetalKit

final class ViewportView: MTKView {

    // Owned scene objects
    let sceneManager: SceneManager
    let camera: CameraController
    let lightManager: LightManager
    let timeline: Timeline
    var renderer: Renderer?

    // Input state
    private var lastMouseLocation: NSPoint = .zero
    private var isSpaceDown: Bool = false

    // Holds the VideoExporter alive for the duration of an export.
    // Nil when no export is in progress.
    private var activeExporter: VideoExporter?

    // MARK: - Init

    init(frame: NSRect) {
        sceneManager = SceneManager()
        camera       = CameraController()
        lightManager = LightManager()
        timeline     = Timeline()

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
            device:       metalDevice,
            sceneManager: sceneManager,
            camera:       camera,
            lightManager: lightManager,
            timeline:     timeline
        )

        if renderer == nil {
            print("[DEBUG] ViewportView: Renderer init returned nil")
        }

        delegate = renderer
    }

    required init(coder: NSCoder) {
        fatalError("ViewportView does not support NSCoder initialisation")
    }

    // MARK: - Model Loading

    func loadModel(url: URL) {
        guard let dev = device else {
            print("[DEBUG] ViewportView: loadModel — device is nil")
            return
        }

        print("[DEBUG] ViewportView: loadModel start — " + url.lastPathComponent)

        let loader = GLTFLoader(device: dev)

        if let obj = loader.load(url: url) {
            autoNormalize(obj)

            // Save the final world transform as the animation base
            obj.baseTransform = obj.transform

            sceneManager.objects = [obj]
            camera.fitToScene(boundingRadius: obj.boundingRadius, center: obj.boundingCenter)

            // Phase 2: create a demo rotation animation so the timeline is immediately useful
            createDemoAnimation(for: obj)

            print("[DEBUG] ViewportView: model loaded, objects count = " + String(sceneManager.objects.count))
        } else {
            print("[DEBUG] ViewportView: GLTFLoader returned nil for " + url.lastPathComponent)
        }
    }

    // MARK: - Auto-normalization

    private func autoNormalize(_ obj: SceneObject) {
        let targetRadius: Float = 1.0
        let t = obj.transform
        let localCenter = obj.boundingCenter
        let localRadius = obj.boundingRadius

        // World-space bounding center
        let lc4 = SIMD4<Float>(localCenter.x, localCenter.y, localCenter.z, 1.0)
        let wc4 = t * lc4
        let worldCenter = SIMD3<Float>(wc4.x, wc4.y, wc4.z)

        // World-space bounding radius (largest column scale in upper-left 3x3)
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

        // Always promote bounding sphere to world space so fitToScene is correct
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

    // MARK: - Phase 2: Demo animation

    // Creates a Y-axis rotation animation (0° → 180° → 0°) over the timeline duration.
    // The animation is a DELTA applied on top of baseTransform, so position/scale are preserved.
    // Replace or augment this in Phase 3 when interactive keyframe editing is added.
    private func createDemoAnimation(for obj: SceneObject) {
        let animDuration = timeline.duration

        let track = KeyframeTrack()
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let half     = simd_quatf(angle: Float.pi, axis: SIMD3<Float>(0, 1, 0))

        // t=0          identity (0°)
        // t=duration/2 half-turn (180°)
        // t=duration   back to identity (360° = same as 0°, approached from 180°)
        track.addKeyframe(TransformKeyframe(time: 0,              rotation: identity))
        track.addKeyframe(TransformKeyframe(time: animDuration * 0.5, rotation: half))
        track.addKeyframe(TransformKeyframe(time: animDuration,   rotation: identity))

        obj.keyframeTrack = track

        print("[DEBUG] ViewportView: demo rotation animation created, duration="
            + String(animDuration) + "s keyframes=" + String(track.keyframes.count))
    }

    // MARK: - Add Keyframe (Phase 2)

    // Captures the current object transform at the current timeline time.
    // Phase 3 will make the transform editable interactively; for now this
    // records the existing transform (useful after demo edits or scripted moves).
    func addKeyframeAtCurrentTime() {
        guard let obj = sceneManager.primaryObject else {
            print("[DEBUG] ViewportView: addKeyframeAtCurrentTime — no primary object")
            return
        }

        if obj.keyframeTrack == nil {
            obj.keyframeTrack = KeyframeTrack()
            print("[DEBUG] ViewportView: created new KeyframeTrack for '" + obj.name + "'")
        }

        // The renderer applies:  obj.transform = baseTransform * animDelta
        // So keyframes must store the DELTA, not the absolute world transform.
        // Recover: animDelta = inverse(baseTransform) * currentTransform
        // This matches how the demo rotation keyframes work (pure-rotation deltas).
        let invBase = simd_inverse(obj.baseTransform)
        let m = invBase * obj.transform

        let translation = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)

        let sx = simd_length(SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z))
        let sy = simd_length(SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z))
        let sz = simd_length(SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        let scale = SIMD3<Float>(sx, sy, sz)

        // Extract rotation by normalising the upper-left 3x3 columns of the delta
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
            print("[DEBUG] ViewportView: addKeyframe — near-zero delta scale column, using identity rotation")
        }

        let kf = TransformKeyframe(
            time:        timeline.currentTime,
            translation: translation,
            rotation:    rotation,
            scale:       scale
        )
        obj.keyframeTrack?.addKeyframe(kf)

        print("[DEBUG] ViewportView: keyframe delta added at t="
            + String(format: "%.3f", timeline.currentTime)
            + " translation=(" + String(format: "%.4f", translation.x)
            + "," + String(format: "%.4f", translation.y)
            + "," + String(format: "%.4f", translation.z) + ")"
            + " scale=(" + String(format: "%.4f", scale.x)
            + "," + String(format: "%.4f", scale.y)
            + "," + String(format: "%.4f", scale.z) + ")"
            + " for '" + obj.name + "'")
    }

    // MARK: - Phase 3: Video Export

    // Pauses the render loop, renders every animation frame offscreen via
    // VideoExporter, and writes ProRes 4444 to the given URL.
    // exportState is written on the main thread so TimelinePanel stays in sync.
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

        // Stop playback and freeze the render loop to prevent racing with the export queue
        timeline.pause()
        isPaused = true

        // Ensure camera aspect ratio matches the export resolution
        camera.aspectRatio = Float(exporter.width) / Float(exporter.height)

        exportState.isExporting = true
        exportState.progress    = 0.0
        exportState.lastMessage = ""

        // Retain the exporter for the full duration of the export.
        // The completion block clears it, allowing deallocation.
        activeExporter = exporter

        exporter.export(to: url, codec: codec, progress: { [weak exportState] p in
            exportState?.progress = p
        }, completion: { [weak self, weak exportState] error in
            // Release exporter and restore live render loop
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
            // Space + drag: pan the camera in any mode
            camera.pan(deltaX: dx, deltaY: dy)

        } else if !timeline.isPlaying, let obj = sceneManager.primaryObject {
            // Paused + drag: rotate the object in world space so the pose can be
            // keyframed. Horizontal drag = Y-axis yaw; vertical drag = X-axis pitch.
            let sensitivity: Float = 0.005
            let yaw   = simd_quatf(angle:  dx * sensitivity, axis: SIMD3<Float>(0, 1, 0))
            let pitch = simd_quatf(angle: -dy * sensitivity, axis: SIMD3<Float>(1, 0, 0))
            let delta = simd_normalize(pitch * yaw)
            // Pre-multiply so the rotation is applied in world space
            obj.transform = rotationMatrix4x4(delta) * obj.transform

        } else {
            // Playing + drag: orbit the camera so you can view the animation from any angle
            camera.orbit(deltaX: dx, deltaY: dy)
        }
    }

    // Converts a unit quaternion to a column-major 4x4 rotation matrix.
    // Uses the explicit Shepperd formula — consistent with KeyframeTrack.rotationMatrix.
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

    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat else { return }

        switch event.keyCode {
        case 49:  // Space — pan mode
            isSpaceDown = true

        case 5:   // G — wireframe toggle
            if let r = renderer {
                r.isWireframe.toggle()
                print("[DEBUG] ViewportView: wireframe = " + String(r.isWireframe))
            }

        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        switch event.keyCode {
        case 49: isSpaceDown = false
        default: super.keyUp(with: event)
        }
    }
}
