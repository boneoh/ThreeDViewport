import AppKit
import Combine
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

    // Phase 8: observable rendering settings (color / greyscale / gizmo)
    let renderSettings = RenderSettings()
    private var colorModeCancellable:   AnyCancellable?
    private var axesGizmoCancellable:   AnyCancellable?
    private var loopRevCancellable:     AnyCancellable?

    // Feedback delay-line system
    let feedbackSettings    = FeedbackSettings()
    let feedbackProcessor:   FeedbackProcessor   // created after Metal device is ready
    let colorGradeSettings = ColorGradeSettings()
    private var playbackCancellable: AnyCancellable?

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

    // Right-drag axis lock (object mode).
    // We accumulate displacement until one axis clearly dominates, then lock
    // for the rest of the gesture so the user can't accidentally rotate diagonally.
    private enum DragAxis { case none, horizontal, vertical }
    private var dragLockAxis:      DragAxis = .none
    private var dragAccumX:        Float    = 0   // total pixels since rightMouseDown
    private var dragAccumY:        Float    = 0
    private let dragLockThreshold: Float    = 8   // pixels before axis is committed

    // Holds the VideoExporter alive for the duration of an export.
    private var activeExporter: VideoExporter?

    /// Called when the user presses Return/Enter in the viewport.
    /// Wired by AppDelegate to commit any active keyframe edit in the Timeline Editor.
    var onEnterKey: (() -> Void)?

    /// Called whenever the active control mode or its selection changes.
    /// AppDelegate wires this to keep the Timeline Editor's row highlight in sync.
    var onControlModeChanged: ((TrackRef) -> Void)?

    /// Timeline Editor view to forward unhandled keys to.  Set by AppDelegate.
    weak var timelineKeyTarget: TimelineEditorView?

    /// Set to true by the Timeline Editor before it calls keyDown on us so we
    /// know not to forward the event back (prevents a ping-pong loop).
    var isReceivingForwardedKey: Bool = false

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

        feedbackProcessor = FeedbackProcessor(device: metalDevice)

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

        // Wire feedback processor + settings into renderer
        renderer?.feedbackProcessor   = feedbackProcessor
        renderer?.feedbackSettings    = feedbackSettings
        renderer?.colorGradeSettings  = colorGradeSettings

        // Sync renderSettings → renderer whenever toggles change
        colorModeCancellable = renderSettings.$isColorMode.sink { [weak self] value in
            self?.renderer?.isColorMode = value
            print("[DEBUG] ViewportView: colorMode = " + (value ? "color" : "greyscale"))
        }
        axesGizmoCancellable = renderSettings.$showAxesGizmo.sink { [weak self] value in
            self?.renderer?.showAxesGizmo = value
            print("[DEBUG] ViewportView: showAxesGizmo = \(value)")
        }

        // Reset feedback queue whenever playback starts so old frames don't contaminate new runs
        playbackCancellable = timeline.$isPlaying
            .filter { $0 }
            .sink { [weak self] _ in
                self?.feedbackProcessor.reset()
            }

        // Clear feedback buffer each time the loop wraps so end-of-loop content
        // doesn't bleed into the beginning of the next loop.
        loopRevCancellable = timeline.$loopRevolution
            .dropFirst()
            .sink { [weak self] _ in
                self?.feedbackProcessor.reset()
            }

        syncOverlayState()
    }

    required init(coder: NSCoder) {
        fatalError("ViewportView does not support NSCoder initialisation")
    }

    // MARK: - New Project

    /// Resets the viewport to a clean blank state: no models, default camera,
    /// timeline rewound, feedback cleared.  Lights and background are left
    /// as-is so the user keeps their preferred setup.
    func newProject() {
        sceneManager.clear()
        timeline.stop()
        timeline.duration  = 10.0
        timeline.isLooping = false
        camera.yaw      = 0.0
        camera.pitch    = 0.4
        camera.distance = 5.0
        camera.target   = SIMD3<Float>(0, 0, 0)
        camera.keyframeTrack = nil
        feedbackProcessor.reset()
        syncOverlayState()
        print("[DEBUG] ViewportView: new project — scene cleared")
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
            obj.name          = url.deletingPathExtension().lastPathComponent

            sceneManager.objects = [obj]
            sceneManager.selectedIndex = 0
            camera.fitToScene(boundingRadius: obj.boundingRadius, center: obj.boundingCenter)
            syncOverlayState()

            print("[DEBUG] ViewportView: loadModel complete — objects=" + String(sceneManager.objects.count))
        } else {
            let filename = url.lastPathComponent
            let reason   = loader.lastError ?? "The file could not be read."
            print("[DEBUG] ViewportView: GLTFLoader returned nil for " + filename)
            showLoadError(filename: filename, reason: reason)
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
            obj.name          = url.deletingPathExtension().lastPathComponent

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
            let filename = url.lastPathComponent
            let reason   = loader.lastError ?? "The file could not be read."
            print("[DEBUG] ViewportView: GLTFLoader returned nil for " + filename)
            showLoadError(filename: filename, reason: reason)
        }
    }

    // MARK: - Control Mode (external access for edit-mode wiring)

    /// Sets the active control mode from outside the viewport (e.g. AppDelegate keyframe edit wiring).
    /// Updates the HUD overlay and notifies the timeline editor to highlight the matching lane.
    func setControlMode(_ mode: ControlMode) {
        controlMode = mode
        syncOverlayState()
        switch mode {
        case .camera:        onControlModeChanged?(.camera)
        case .object:        onControlModeChanged?(.object(sceneManager.selectedIndex))
        case .light:         onControlModeChanged?(.light(lightManager.selectedIndex))
        }
    }

    // MARK: - Overlay sync

    // Rebuilds the minimal HUD state from live scene data.
    // Call after any mode change or selection change.
    func syncOverlayState() {
        overlayState.controlMode = controlMode
        switch controlMode {
        case .camera:
            overlayState.selectedItemName = ""
        case .object:
            let idx = sceneManager.selectedIndex
            overlayState.selectedItemName = idx < sceneManager.objects.count
                ? sceneManager.objects[idx].name : ""
        case .light:
            overlayState.selectedItemName = "Light \(lightManager.selectedIndex + 1)"
        }
    }

    // MARK: - Orientation reset

    /// Resets `obj`'s rotation to its base-transform orientation while keeping
    /// the current world-space position and scale unchanged.
    ///
    /// The base-transform stores the rotation as baked into the 3×3 columns
    /// (each column = rotation_axis × scale_factor).  We extract the pure
    /// rotation by normalising those columns, then re-apply the current scale.
    func resetObjectOrientation(_ obj: SceneObject) {
        // Current scale = length of each 3×3 column vector
        let s0 = simd_length(SIMD3<Float>(obj.transform.columns.0.x,
                                           obj.transform.columns.0.y,
                                           obj.transform.columns.0.z))
        let s1 = simd_length(SIMD3<Float>(obj.transform.columns.1.x,
                                           obj.transform.columns.1.y,
                                           obj.transform.columns.1.z))
        let s2 = simd_length(SIMD3<Float>(obj.transform.columns.2.x,
                                           obj.transform.columns.2.y,
                                           obj.transform.columns.2.z))

        // Base rotation = normalised columns of the base transform's 3×3 block
        let b0 = simd_normalize(SIMD3<Float>(obj.baseTransform.columns.0.x,
                                              obj.baseTransform.columns.0.y,
                                              obj.baseTransform.columns.0.z))
        let b1 = simd_normalize(SIMD3<Float>(obj.baseTransform.columns.1.x,
                                              obj.baseTransform.columns.1.y,
                                              obj.baseTransform.columns.1.z))
        let b2 = simd_normalize(SIMD3<Float>(obj.baseTransform.columns.2.x,
                                              obj.baseTransform.columns.2.y,
                                              obj.baseTransform.columns.2.z))

        // Write rotation×scale back, keep the translation column unchanged
        obj.transform.columns.0 = SIMD4<Float>(b0 * s0, 0)
        obj.transform.columns.1 = SIMD4<Float>(b1 * s1, 0)
        obj.transform.columns.2 = SIMD4<Float>(b2 * s2, 0)

        print("[DEBUG] ViewportView: resetObjectOrientation — " + obj.name)
    }

    // MARK: - Load error alert

    private func showLoadError(filename: String, reason: String) {
        let alert = NSAlert()
        alert.alertStyle     = .warning
        alert.messageText    = "Could not open \"\(filename)\""
        alert.informativeText = reason
        alert.addButton(withTitle: "OK")
        if let window = window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
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

    // MARK: - Add Object Keyframe

    /// Stamps a keyframe for the currently selected (or primary) object.
    /// Called by the timeline panel's "Add Object Keyframe" button.
    func addKeyframeAtCurrentTime() {
        guard let obj = sceneManager.selectedObject ?? sceneManager.primaryObject else {
            print("[DEBUG] ViewportView: addKeyframeAtCurrentTime — no object selected")
            return
        }
        let index = sceneManager.objects.firstIndex { $0 === obj } ?? sceneManager.selectedIndex
        addKeyframeAtCurrentTime(forObjectAt: index)
    }

    /// Stamps a keyframe for the object at `index` using its current live transform.
    /// Called by the Timeline Editor's Insert key handler.
    func addKeyframeAtCurrentTime(forObjectAt index: Int) {
        guard index >= 0, index < sceneManager.objects.count else {
            print("[DEBUG] ViewportView: addKeyframeAtCurrentTime(forObjectAt:) — index out of range")
            return
        }
        let obj = sceneManager.objects[index]

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

    // MARK: - Add Light Keyframe

    /// Stamps a keyframe for the light at `index` using its current live state.
    /// Called by the Timeline Editor's Insert key handler and by edit-mode commit.
    func addLightKeyframeAtCurrentTime(forLightAt index: Int) {
        guard index >= 0, index < lightManager.lights.count else {
            print("[DEBUG] ViewportView: addLightKeyframeAtCurrentTime — index out of range")
            return
        }
        let light = lightManager.lights[index]

        // Create the track slot if this is the first keyframe for this light.
        while lightManager.keyframeTracks.count <= index {
            lightManager.keyframeTracks.append(nil)
        }
        if lightManager.keyframeTracks[index] == nil {
            lightManager.keyframeTracks[index] = LightKeyframeTrack()
            print("[DEBUG] ViewportView: created LightKeyframeTrack for light \(index)")
        }

        let kf = LightKeyframe(
            time:          timeline.currentTime,
            intensity:     light.intensity,
            color:         light.color,
            direction:     light.direction,
            position:      light.position,
            range:         light.range,
            beamThickness: light.beamThickness
        )
        lightManager.keyframeTracks[index]?.addKeyframe(kf)

        print("[DEBUG] ViewportView: light keyframe added at t="
            + String(format: "%.3f", timeline.currentTime)
            + " light=\(index)")
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
            backgroundConfig:  backgroundConfig,
            timeline:          timeline,
            pipelineState:     pipeline,
            depthStencilState: depth
        ) else {
            print("[DEBUG] ViewportView: startExport — VideoExporter init returned nil")
            return
        }

        exporter.isColorMode        = renderSettings.isColorMode
        exporter.isWireframe        = renderer?.isWireframe      ?? false
        exporter.showAxesGizmo      = renderSettings.showAxesGizmo
        exporter.feedbackSettings   = feedbackSettings
        exporter.colorGradeSettings = colorGradeSettings
        feedbackProcessor.reset()   // clear live queue; exporter has its own processor
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
            // Space+drag: orbit camera around target (available in all modes).
            camera.orbit(deltaX: dx, deltaY: dy)

        } else if controlMode == .object {
            // Object mode: translate selected object — or do nothing if conditions
            // aren't met (timeline playing, no object).  Never fall through to
            // camera pan here; that asymmetry was the cause of the "all objects
            // move" bug (left-drag was panning the camera instead of doing nothing).
            guard !timeline.isPlaying,
                  let obj = sceneManager.selectedObject ?? sceneManager.primaryObject
            else { return }
            // Translate in the camera's view plane.
            // Scale with distance so the feel is consistent at any zoom level.
            let scale = camera.distance * 0.001
            let move  = camera.rightVector * (dx * scale)
                      + camera.upVector   * (dy * scale)
            obj.transform.columns.3.x += move.x
            obj.transform.columns.3.y += move.y
            obj.transform.columns.3.z += move.z

        } else {
            // Camera / Light mode: pan the camera.
            camera.pan(deltaX: dx, deltaY: dy)
        }
    }

    // MARK: - Right Mouse Input

    override func rightMouseDown(with event: NSEvent) {
        lastMouseLocation = convert(event.locationInWindow, from: nil)
        dragLockAxis = .none
        dragAccumX   = 0
        dragAccumY   = 0
    }

    override func rightMouseDragged(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let dx  = Float(loc.x - lastMouseLocation.x)
        let dy  = Float(loc.y - lastMouseLocation.y)
        lastMouseLocation = loc

        let sensitivity: Float = 0.005
        switch controlMode {
        case .object:
            guard !timeline.isPlaying,
                  let obj = sceneManager.selectedObject ?? sceneManager.primaryObject
            else { return }

            // ── Axis lock ─────────────────────────────────────────────────────
            // Accumulate displacement until one screen axis clearly dominates,
            // then commit for the rest of the gesture.  This prevents diagonal
            // drift and makes single-axis spins easy to execute.
            if dragLockAxis == .none {
                dragAccumX += dx
                dragAccumY += dy
                let dist = (dragAccumX * dragAccumX + dragAccumY * dragAccumY).squareRoot()
                guard dist >= dragLockThreshold else { return }
                dragLockAxis = abs(dragAccumX) >= abs(dragAccumY) ? .horizontal : .vertical
            }

            // Apply only the locked-axis component of this frame's delta.
            // Camera-space axes:
            //   Horizontal drag → spin around camera.upVector    (screen left/right)
            //   Vertical drag   → tilt around camera.rightVector (screen up/down)
            let rotAxis: SIMD3<Float>
            let angle:   Float
            switch dragLockAxis {
            case .horizontal:
                rotAxis = camera.upVector
                angle   =  dx * sensitivity
            case .vertical:
                rotAxis = camera.rightVector
                angle   = -dy * sensitivity
            case .none:
                return
            }
            let rot = rotationMatrix4x4(simd_quatf(angle: angle, axis: rotAxis))

            // Pivot = local AABB midpoint in world space (invariant under rotation).
            // boundingMin/boundingMax are always in local space (set by GLTFLoader
            // and never modified after load).
            let localCentre = (obj.boundingMin + obj.boundingMax) * 0.5
            let wc4   = obj.transform * SIMD4<Float>(localCentre, 1)
            let pivot = SIMD3<Float>(wc4.x, wc4.y, wc4.z)

            // Rotate the 3×3 orientation block.
            let c0 = rot * SIMD4<Float>(obj.transform.columns.0.x,
                                         obj.transform.columns.0.y,
                                         obj.transform.columns.0.z, 0)
            let c1 = rot * SIMD4<Float>(obj.transform.columns.1.x,
                                         obj.transform.columns.1.y,
                                         obj.transform.columns.1.z, 0)
            let c2 = rot * SIMD4<Float>(obj.transform.columns.2.x,
                                         obj.transform.columns.2.y,
                                         obj.transform.columns.2.z, 0)
            obj.transform.columns.0 = SIMD4<Float>(c0.x, c0.y, c0.z, 0)
            obj.transform.columns.1 = SIMD4<Float>(c1.x, c1.y, c1.z, 0)
            obj.transform.columns.2 = SIMD4<Float>(c2.x, c2.y, c2.z, 0)

            // Recompute translation so `pivot` stays fixed in world space.
            // t_new = pivot − M_new · localCentre  (w=0 skips the old translation)
            let mc4    = obj.transform * SIMD4<Float>(localCentre, 0)
            let newPos = pivot - SIMD3<Float>(mc4.x, mc4.y, mc4.z)
            obj.transform.columns.3 = SIMD4<Float>(newPos.x, newPos.y, newPos.z, 1)

        case .camera, .light:
            // Right drag in camera / light mode: free-look.
            // Camera position stays fixed; aim direction rotates.
            camera.freeLook(deltaYaw: dx * sensitivity, deltaPitch: dy * sensitivity)
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
        let delta = Float(event.scrollingDeltaY)

        guard controlMode == .object,
              !timeline.isPlaying,
              let obj = sceneManager.selectedObject ?? sceneManager.primaryObject
        else {
            camera.zoom(delta: delta)
            return
        }

        if event.modifierFlags.contains(.option) {
            // ⌥ + scroll → uniform scale around the object's visual centre.
            // exp() keeps the factor strictly positive and gives symmetric
            // feel: the same delta undoes a previous equal-and-opposite delta.
            let factor = exp(delta * 0.02)

            // Pivot = world-space AABB centre (same reliable source as rotation)
            let localCentre = (obj.boundingMin + obj.boundingMax) * 0.5
            let wc4   = obj.transform * SIMD4<Float>(localCentre, 1)
            let pivot = SIMD3<Float>(wc4.x, wc4.y, wc4.z)

            // Scale the 3×3 orientation+scale columns uniformly.
            // w=0 on each column, so 0 * factor = 0 — w stays clean.
            obj.transform.columns.0 *= factor
            obj.transform.columns.1 *= factor
            obj.transform.columns.2 *= factor

            // Recompute translation so the visual centre stays at `pivot`.
            // t_new = pivot − M_new · localCentre  (w=0 isolates the 3×3)
            let mc4    = obj.transform * SIMD4<Float>(localCentre, 0)
            let newPos = pivot - SIMD3<Float>(mc4.x, mc4.y, mc4.z)
            obj.transform.columns.3 = SIMD4<Float>(newPos.x, newPos.y, newPos.z, 1)

        } else {
            // Plain scroll → translate along the camera forward axis (depth push/pull)
            let move = delta * camera.distance * 0.05
            let fwd  = camera.forwardVector
            obj.transform.columns.3.x += fwd.x * move
            obj.transform.columns.3.y += fwd.y * move
            obj.transform.columns.3.z += fwd.z * move
        }
    }

    // MARK: - Keyframe navigation

    /// Seeks the playhead to the next (backward=false) or previous (backward=true)
    /// keyframe on the track that matches the current control mode and selection.
    func seekToAdjacentKeyframe(backward: Bool) {
        let times: [Double]
        switch controlMode {
        case .camera:
            times = camera.keyframeTrack?.keyframes.map { $0.time } ?? []
        case .object:
            let idx = sceneManager.selectedIndex
            times = idx < sceneManager.objects.count
                ? (sceneManager.objects[idx].keyframeTrack?.keyframes.map { $0.time } ?? [])
                : []
        case .light:
            let idx = lightManager.selectedIndex
            times = idx < lightManager.keyframeTracks.count
                ? (lightManager.keyframeTracks[idx]?.keyframes.map { $0.time } ?? [])
                : []
        }
        guard !times.isEmpty else { return }
        let sorted = times.sorted()
        let cur    = timeline.currentTime
        let eps    = 1.0 / timeline.frameRate / 2  // half-frame tolerance
        if backward {
            if let t = sorted.last(where: { $0 < cur - eps }) { timeline.seek(to: t) }
        } else {
            if let t = sorted.first(where: { $0 > cur + eps }) { timeline.seek(to: t) }
        }
    }

    // MARK: - Keyboard Input

    // Key code constants
    private enum KC {
        static let space:    UInt16 = 49
        static let g:        UInt16 = 5    // wireframe
        static let t:        UInt16 = 17   // color / greyscale toggle
        static let c:        UInt16 = 8    // camera mode
        static let l:        UInt16 = 37   // light mode
        static let o:        UInt16 = 31   // object mode / cycle
        static let p:        UInt16 = 35   // play / pause
        static let r:        UInt16 = 15   // reset object orientation to base
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
        // Zoom / intensity / depth
        static let kpPlus:   UInt16 = 69   // keypad +
        static let kpMinus:  UInt16 = 78   // keypad −
        static let regMinus: UInt16 = 27   // regular − / _ (Shift+−)
        static let regEqual: UInt16 = 24   // regular = / + (Shift+=)
        // Roll (object) — both shifted and unshifted land on same key code
        static let leftBracket:  UInt16 = 33   // [ and {
        static let rightBracket: UInt16 = 30   // ] and }
        // Commit / dismiss
        static let returnKey:    UInt16 = 36   // Return / Enter
        // Keyframe insertion / deletion shortcuts
        static let insert:       UInt16 = 114  // Insert / Help key
        static let i:            UInt16 = 34   // I — alias for Insert (add keyframe)
        // Playhead navigation
        static let home:         UInt16 = 115  // Home
        static let end:          UInt16 = 119  // End
        static let tab:          UInt16 = 48   // Tab
    }

    // Step sizes for arrow-key navigation
    // panStep is passed to camera.pan() which applies its own sensitivity×distance scaling,
    // so the on-screen movement stays proportional to the current zoom level.
    private let panStep:       Float = 50.0             // camera pan pixels-equivalent per key
    private let translateStep: Float = 0.05             // world-units per key (object)
    private let lightStep:     Float = Float.pi / 36.0  // 5° per key (light azimuth / elevation)
    private let rotStep:       Float = Float.pi / 36.0  // 5° per key (object/camera rotation)
    private let intensityStep: Float = 0.1
    private let zoomStep:      Float = 0.1              // fraction of current distance per key
    private let scaleStep:     Float = 1.05             // Option+=/− scales object by ±5% per key

    override func keyDown(with event: NSEvent) {
        let kc = event.keyCode

        // ── Return key — commit active keyframe edit in Timeline Editor ─────────
        if kc == KC.returnKey, !event.isARepeat {
            onEnterKey?()
            return
        }

        // ── Insert key — stamp a keyframe for the current mode / selection ──────
        if kc == KC.insert, !event.isARepeat {
            switch controlMode {
            case .camera:
                addCameraKeyframeAtCurrentTime()
            case .object:
                addKeyframeAtCurrentTime()
            case .light:
                addLightKeyframeAtCurrentTime(forLightAt: lightManager.selectedIndex)
            }
            return
        }

        // ── Home — jump playhead to start ─────────────────────────────────────
        if kc == KC.home, !event.isARepeat {
            timeline.seek(to: 0)
            return
        }

        // ── End — jump playhead to end ────────────────────────────────────────
        if kc == KC.end, !event.isARepeat {
            timeline.seek(to: timeline.duration)
            return
        }

        // ── Tab / Shift+Tab — next / previous keyframe for active track ───────
        if kc == KC.tab, !event.isARepeat {
            let backward = event.modifierFlags.contains(.shift)
            seekToAdjacentKeyframe(backward: backward)
            return
        }

        // ── Mode-switch keys — single-fire only (no repeat) ──────────────────
        if !event.isARepeat {
            switch kc {
            case KC.space:
                isSpaceDown = true
                return

            case KC.p:
                timeline.togglePlayPause()
                return

            case KC.i:
                // I — add keyframe at current time (alias for Insert key)
                switch controlMode {
                case .camera:
                    addCameraKeyframeAtCurrentTime()
                case .object:
                    addKeyframeAtCurrentTime()
                case .light:
                    addLightKeyframeAtCurrentTime(forLightAt: lightManager.selectedIndex)
                }
                return

            case KC.g:
                renderer?.isWireframe.toggle()
                print("[DEBUG] ViewportView: wireframe = " + String(renderer?.isWireframe ?? false))
                return

            case KC.t:
                renderSettings.isColorMode.toggle()
                return

            case KC.c:
                controlMode = .camera
                syncOverlayState()
                onControlModeChanged?(.camera)
                return

            case KC.l:
                if controlMode == .light {
                    // Already in light mode — cycle to next light.
                    lightManager.cycleSelection()
                } else {
                    controlMode = .light
                    syncOverlayState()
                }
                onControlModeChanged?(.light(lightManager.selectedIndex))
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
                onControlModeChanged?(.object(sceneManager.selectedIndex))
                return

            case KC.r:
                // R — reset the selected object's rotation to its original loaded orientation.
                // Position and scale are preserved; only the rotation is replaced.
                if controlMode == .object,
                   let obj = sceneManager.selectedObject ?? sceneManager.primaryObject {
                    resetObjectOrientation(obj)
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
                if event.modifierFlags.contains(.shift) {
                    camera.freeLook(deltaYaw: -rotStep, deltaPitch: 0)
                } else {
                    camera.pan(deltaX: panStep, deltaY: 0)
                }
            case .light:
                lightManager.rotateSelected(deltaAzimuth: -lightStep, deltaElevation: 0)
            case .object:
                if let obj = sceneManager.selectedObject {
                    if event.modifierFlags.contains(.shift) {
                        let q = simd_quatf(angle: -rotStep, axis: SIMD3<Float>(0, 1, 0))
                        obj.transform = rotationMatrix4x4(q) * obj.transform
                    } else {
                        obj.transform.columns.3.x -= translateStep
                    }
                }
            }

        // ── Right arrow / KP6 ────────────────────────────────────────────────
        case KC.right, KC.kp6:
            switch controlMode {
            case .camera:
                if event.modifierFlags.contains(.shift) {
                    camera.freeLook(deltaYaw: rotStep, deltaPitch: 0)
                } else {
                    camera.pan(deltaX: -panStep, deltaY: 0)
                }
            case .light:
                lightManager.rotateSelected(deltaAzimuth: lightStep, deltaElevation: 0)
            case .object:
                if let obj = sceneManager.selectedObject {
                    if event.modifierFlags.contains(.shift) {
                        let q = simd_quatf(angle: rotStep, axis: SIMD3<Float>(0, 1, 0))
                        obj.transform = rotationMatrix4x4(q) * obj.transform
                    } else {
                        obj.transform.columns.3.x += translateStep
                    }
                }
            }

        // ── Up arrow / KP8 ───────────────────────────────────────────────────
        case KC.up, KC.kp8:
            switch controlMode {
            case .camera:
                if event.modifierFlags.contains(.shift) {
                    camera.freeLook(deltaYaw: 0, deltaPitch: rotStep)
                } else {
                    camera.pan(deltaX: 0, deltaY: panStep)
                }
            case .light:
                lightManager.rotateSelected(deltaAzimuth: 0, deltaElevation: -lightStep)
            case .object:
                if let obj = sceneManager.selectedObject {
                    if event.modifierFlags.contains(.shift) {
                        let q = simd_quatf(angle: rotStep, axis: SIMD3<Float>(1, 0, 0))
                        obj.transform = rotationMatrix4x4(q) * obj.transform
                    } else {
                        obj.transform.columns.3.y += translateStep
                    }
                }
            }

        // ── Down arrow / KP2 ─────────────────────────────────────────────────
        case KC.down, KC.kp2:
            switch controlMode {
            case .camera:
                if event.modifierFlags.contains(.shift) {
                    camera.freeLook(deltaYaw: 0, deltaPitch: -rotStep)
                } else {
                    camera.pan(deltaX: 0, deltaY: -panStep)
                }
            case .light:
                lightManager.rotateSelected(deltaAzimuth: 0, deltaElevation: lightStep)
            case .object:
                if let obj = sceneManager.selectedObject {
                    if event.modifierFlags.contains(.shift) {
                        let q = simd_quatf(angle: -rotStep, axis: SIMD3<Float>(1, 0, 0))
                        obj.transform = rotationMatrix4x4(q) * obj.transform
                    } else {
                        obj.transform.columns.3.y -= translateStep
                    }
                }
            }

        // ── [ / { — roll object left ──────────────────────────────────────────
        case KC.leftBracket:
            if controlMode == .object, let obj = sceneManager.selectedObject {
                let q = simd_quatf(angle: -rotStep, axis: SIMD3<Float>(0, 0, 1))
                obj.transform = rotationMatrix4x4(q) * obj.transform
            }

        // ── ] / } — roll object right ─────────────────────────────────────────
        case KC.rightBracket:
            if controlMode == .object, let obj = sceneManager.selectedObject {
                let q = simd_quatf(angle: rotStep, axis: SIMD3<Float>(0, 0, 1))
                obj.transform = rotationMatrix4x4(q) * obj.transform
            }

        // ── Plus / KP+ — zoom in / light depth in / object +Z / Option: scale up ─
        case KC.kpPlus, KC.regEqual:
            switch controlMode {
            case .camera:
                camera.zoom(delta: camera.distance * zoomStep / 0.05)
            case .light:
                // Move positional light forward along its direction (+Z into scene)
                lightManager.moveSelectedDepth(delta: translateStep * 2)
            case .object:
                if let obj = sceneManager.selectedObject {
                    if event.modifierFlags.contains(.option) {
                        // Option+= : scale object up 5%
                        let sv = SIMD4<Float>(scaleStep, scaleStep, scaleStep, 1)
                        obj.transform.columns.0 *= sv
                        obj.transform.columns.1 *= sv
                        obj.transform.columns.2 *= sv
                        print("[DEBUG] ViewportView: object scale up ×\(scaleStep)")
                    } else {
                        obj.transform.columns.3.z += translateStep
                    }
                }
            }

        // ── Minus / KP− — zoom out / light depth out / object −Z / Option: scale down ─
        case KC.kpMinus, KC.regMinus:
            switch controlMode {
            case .camera:
                camera.zoom(delta: -(camera.distance * zoomStep / 0.05))
            case .light:
                lightManager.moveSelectedDepth(delta: -translateStep * 2)
            case .object:
                if let obj = sceneManager.selectedObject {
                    if event.modifierFlags.contains(.option) {
                        // Option+- : scale object down 5%
                        let s: Float = 1.0 / scaleStep
                        let sv = SIMD4<Float>(s, s, s, 1)
                        obj.transform.columns.0 *= sv
                        obj.transform.columns.1 *= sv
                        obj.transform.columns.2 *= sv
                        print("[DEBUG] ViewportView: object scale down ×\(s)")
                    } else {
                        obj.transform.columns.3.z -= translateStep
                    }
                }
            }

        default:
            // Forward unrecognised keys to the Timeline Editor (if present and not
            // already bouncing a key back to us — prevents a ping-pong loop).
            if let target = timelineKeyTarget, !isReceivingForwardedKey {
                target.isReceivingForwardedKey = true
                target.keyDown(with: event)
                target.isReceivingForwardedKey = false
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        switch event.keyCode {
        case KC.space: isSpaceDown = false
        default:       super.keyUp(with: event)
        }
    }
}
