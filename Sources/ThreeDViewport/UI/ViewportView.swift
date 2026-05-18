import AppKit
import Combine
import MetalKit
import simd

// MARK: - Control mode

// Determines which scene element receives keyboard arrow-key input.
enum ControlMode {
    case camera
    case light
    case object   // individual part
    case model    // all parts of a group move as one rigid body

    var displayName: String {
        switch self {
        case .camera: return "Camera"
        case .light:  return "Light"
        case .object: return "Object"
        case .model:  return "Model"
        }
    }
}

// MARK: - ViewportView

final class ViewportView: MTKView {

    // Owned scene objects
    let sceneManager:     SceneManager
    let camera:           CameraController
    /// Director's-POV camera used in Scene mode (read-only view of the whole
    /// scene from a fly-cam position above and behind the recording camera).
    /// Independent state — never animated, never saved with the project.
    let director:         CameraController
    let lightManager:     LightManager
    let backgroundConfig: BackgroundConfig
    let timeline:         Timeline

    /// True while Scene mode is active.  The Renderer mirrors this flag so its
    /// `viewCamera` swap kicks in.  When false, behaviour is unchanged.
    var sceneModeActive: Bool = false {
        didSet { renderer?.sceneModeActive = sceneModeActive }
    }
    /// First-time-per-session auto-fit guard.  Toggling Scene off then on does
    /// NOT re-fit; the user has to press ⌘R to refit.
    private var directorEverFit: Bool = false
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

    // Camera panel — sticky follow-target picker shared with the floating
    // CameraPanel inspector.  Lives here so the choice survives panel
    // hide/show cycles.
    let cameraPanelState   = CameraPanelState()
    private var playbackCancellable: AnyCancellable?

    // Phase 6: HUD observable state — AppDelegate embeds the SwiftUI overlay using this.
    let overlayState = SceneOverlayState()

    // Active control mode: camera / light / object.
    // Writing updates the HUD automatically.
    private var controlMode: ControlMode = .camera {
        didSet {
            overlayState.controlMode = controlMode
            // Camera-mode awareness — lets the renderer suspend the camera-follow
            // override while the user is editing the camera with the timeline
            // paused.  See Renderer.applyCameraFollow.
            renderer?.cameraModeActive = (controlMode == .camera)
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

    // MARK: - Drag-and-drop callbacks (wired by AppDelegate)

    /// Fires after one or more model files are successfully drop-loaded.
    /// AppDelegate wires this to markDirty() and updateWindowHeight().
    var onModelDropped: (() -> Void)?

    /// Fires when the user drops a single .3dvp project file.
    /// AppDelegate wires this through handleDroppedProject() (with dirty-check).
    var onDropProjectFile: ((URL) -> Void)?

    // Overlay that highlights the viewport during a valid drag hover.
    private var dragHighlightView: DragHighlightView?

    // MARK: - Init

    init(frame: NSRect) {
        sceneManager     = SceneManager()
        camera           = CameraController()
        director         = CameraController()
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
            director:         director,
            lightManager:     lightManager,
            backgroundConfig: backgroundConfig,
            timeline:         timeline
        )
        // Seed cameraModeActive — controlMode's didSet only fires on changes,
        // not on initial assignment, so the flag would otherwise stay false
        // until the user pressed C / O / L / M for the first time.
        renderer?.cameraModeActive = (controlMode == .camera)

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

        // Register as a drag-and-drop destination for .glb / .gltf / .3dvp files.
        registerForDraggedTypes([.fileURL])
        let hl = DragHighlightView(frame: bounds)
        hl.autoresizingMask = [.width, .height]
        hl.isHidden = true
        addSubview(hl)
        dragHighlightView = hl

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

        if let objects = loader.load(url: url) {
            let (center, radius) = autoNormalize(objects)

            let baseName = url.deletingPathExtension().lastPathComponent
            // All parts from the same file share a group ID so they can be
            // moved together in Model mode.
            let gid = objects.count > 1 ? sceneManager.makeGroupID() : nil
            for obj in objects {
                // For hierarchical parts (parentIndex != nil), baseTransform is the
                // base LOCAL transform; for roots it is the world transform (as before).
                obj.baseTransform = (obj.parentIndex != nil) ? obj.localTransform : obj.transform
                obj.sourceURL     = url
                obj.groupID       = gid
            }
            objects.first?.name = baseName

            sceneManager.objects = objects
            sceneManager.selectedIndex = 0
            camera.fitToScene(boundingRadius: radius, center: center)
            syncOverlayState()

            print("[DEBUG] ViewportView: loadModel complete — objects=\(objects.count) groupID=\(gid.map { String($0) } ?? "none")")
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

        if let objects = loader.load(url: url) {
            let (center, radius) = autoNormalize(objects)

            let baseName = url.deletingPathExtension().lastPathComponent
            let gid = objects.count > 1 ? sceneManager.makeGroupID() : nil
            for obj in objects {
                // For hierarchical parts (parentIndex != nil), baseTransform is the
                // base LOCAL transform; for roots it is the world transform (as before).
                obj.baseTransform = (obj.parentIndex != nil) ? obj.localTransform : obj.transform
                obj.sourceURL     = url
                obj.groupID       = gid
            }
            objects.first?.name = baseName

            let isFirst = sceneManager.objects.isEmpty
            // Offset every parentIndex in the new batch by the number of objects
            // already in the scene.  GLTFLoader sets parentIndex relative to the
            // local (per-file) array starting at 0; after appending they must refer
            // to positions in the global sceneManager.objects array.
            let offset = sceneManager.objects.count
            for obj in objects where obj.parentIndex != nil {
                obj.parentIndex! += offset
            }
            sceneManager.objects.append(contentsOf: objects)
            // Select the root of the newly added model (first object with parentIndex == nil).
            let firstRootLocal = objects.firstIndex(where: { $0.parentIndex == nil }) ?? 0
            sceneManager.selectedIndex = offset + firstRootLocal

            if isFirst {
                camera.fitToScene(boundingRadius: radius, center: center)
            }

            // Switch to Object mode so the user can immediately manipulate the new model.
            setControlMode(.object)

            print("[DEBUG] ViewportView: addModelToScene complete — total objects=\(sceneManager.objects.count) groupID=\(gid.map { String($0) } ?? "none")")
        } else {
            let filename = url.lastPathComponent
            let reason   = loader.lastError ?? "The file could not be read."
            print("[DEBUG] ViewportView: GLTFLoader returned nil for " + filename)
            showLoadError(filename: filename, reason: reason)
        }
    }

    // MARK: - Replace Selected Model

    /// Replaces the geometry and material of the currently selected object (or its
    /// whole group) with a freshly loaded .glb file while preserving every aspect
    /// of the scene state: transforms, keyframe tracks, baseTransform, groupID,
    /// parentIndex, name, and visibility.
    ///
    /// If the new file has a different part count from the selection the operation
    /// is aborted with an error alert — replacing a differently-structured model
    /// would silently corrupt the per-part animation data.
    func replaceSelectedModel(url: URL) {
        guard let dev = device else { return }

        // Determine which objects are being replaced.
        guard let selected = sceneManager.selectedObject else {
            print("[DEBUG] ViewportView: replaceSelectedModel — nothing selected")
            return
        }
        let targets: [SceneObject]
        if let gid = selected.groupID {
            targets = sceneManager.objects(inGroup: gid)
        } else {
            targets = [selected]
        }

        print("[DEBUG] ViewportView: replaceSelectedModel — \(url.lastPathComponent)"
            + " replacing \(targets.count) part(s)")

        // Load the replacement geometry (no autoNormalize — existing transforms are kept).
        let loader = GLTFLoader(device: dev)
        guard let newObjects = loader.load(url: url) else {
            let reason = loader.lastError ?? "The file could not be read."
            showLoadError(filename: url.lastPathComponent, reason: reason)
            return
        }

        // Part-count mismatch → abort.
        if newObjects.count != targets.count {
            let alert = NSAlert()
            alert.alertStyle      = .warning
            alert.messageText     = "Cannot Replace Model"
            alert.informativeText = "\"\(url.lastPathComponent)\" has \(newObjects.count)"
                + " part\(newObjects.count == 1 ? "" : "s")"
                + " but the selected model has \(targets.count)."
                + " Both models must have the same number of parts"
                + " to preserve the animation."
            alert.addButton(withTitle: "OK")
            if let w = window { alert.beginSheetModal(for: w) } else { alert.runModal() }
            print("[DEBUG] ViewportView: replaceSelectedModel — aborted, part count mismatch"
                + " (new=\(newObjects.count) existing=\(targets.count))")
            return
        }

        // Swap geometry + material on each target in order, preserving all scene state.
        for (target, source) in zip(targets, newObjects) {
            target.positionBuffer = source.positionBuffer
            target.normalBuffer   = source.normalBuffer
            target.uvBuffer       = source.uvBuffer
            target.tangentBuffer  = source.tangentBuffer
            target.indexBuffer    = source.indexBuffer
            target.indexCount     = source.indexCount
            target.material       = source.material
            target.boundingCenter = source.boundingCenter
            target.boundingRadius = source.boundingRadius
            target.boundingMin    = source.boundingMin
            target.boundingMax    = source.boundingMax
            target.sourceURL      = url
            // Preserved: transform, baseTransform, localTransform, parentIndex,
            //            groupID, keyframeTrack, isVisible, name.
        }

        // Rename the first (root) object to match the new file's base name.
        // Project save/reload matches objects by name; addModelToScene always sets
        // objects[0].name = url.baseName on load, so the saved name must agree with
        // the replacement file — otherwise the root object fails to match on reload,
        // its baseTransform is not restored, and FK propagation puts all parts at
        // the wrong world position.
        targets.first?.name = url.deletingPathExtension().lastPathComponent

        needsDisplay = true
        print("[DEBUG] ViewportView: replaceSelectedModel — done, \(targets.count) part(s) replaced")
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
        case .model:
            // Broadcast the group lane so the timeline highlights the right header row.
            if let gid = sceneManager.selectedGroupID {
                onControlModeChanged?(.group(gid))
            } else {
                onControlModeChanged?(.object(sceneManager.selectedIndex))
            }
        }
    }

    // MARK: - Overlay sync

    // Rebuilds the minimal HUD state from live scene data.
    // Call after any mode change or selection change.
    func syncOverlayState() {
        overlayState.controlMode     = controlMode
        overlayState.sceneModeActive = sceneModeActive
        switch controlMode {
        case .camera:
            overlayState.selectedItemName = ""
        case .object:
            let idx = sceneManager.selectedIndex
            overlayState.selectedItemName = idx < sceneManager.objects.count
                ? sceneManager.objects[idx].name : ""
        case .light:
            overlayState.selectedItemName = "Light \(lightManager.selectedIndex + 1)"
        case .model:
            // Show how many parts belong to the current group.
            if let gid = sceneManager.selectedGroupID {
                let count = sceneManager.objects(inGroup: gid).count
                let name  = sceneManager.selectedObject?.name ?? "Model"
                overlayState.selectedItemName = "\(name) (\(count) parts)"
            } else {
                overlayState.selectedItemName = sceneManager.selectedObject?.name ?? ""
            }
        }
    }

    // MARK: - FK hierarchy sync helper

    /// After directly modifying a hierarchical object's `transform` in Object mode,
    /// back-computes `localTransform` so the next `applyHierarchy()` call produces
    /// the same result.  For root / non-hierarchical objects, keeps `localTransform`
    /// equal to `transform` (they are the same thing for roots).
    private func syncLocalTransform(_ obj: SceneObject) {
        guard let parentIdx = obj.parentIndex,
              parentIdx < sceneManager.objects.count else {
            // Root or no parent: localTransform == transform
            obj.localTransform = obj.transform
            return
        }
        // Back-compute: localTransform = inverse(parentWorld) × myWorld
        obj.localTransform = simd_inverse(sceneManager.objects[parentIdx].transform)
                           * obj.transform
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
        syncLocalTransform(obj)

        print("[DEBUG] ViewportView: resetObjectOrientation — " + obj.name)
    }

    // MARK: - Director auto-fit (Scene mode)

    /// Computes a bounding sphere over the scene contents (objects + positional
    /// lights + scene camera eye) and positions `director` to frame it from
    /// above and behind the recording camera.
    ///
    /// Called the first time the user enters Scene mode and again on ⌘R.  The
    /// resulting pose persists for the session unless the user explicitly refits.
    func autoFitDirector() {
        // Seed with the scene camera's eye so we always have at least one point.
        let camEye = camera.eyePosition
        var wMin = camEye
        var wMax = camEye

        // ── Objects: world-space bounding boxes ────────────────────────────────
        for obj in sceneManager.objects {
            let groupT = obj.groupID.flatMap { sceneManager.groupTransforms[$0] }
                ?? matrix_identity_float4x4
            let rendered = groupT * obj.transform
            let corners: [SIMD3<Float>] = [
                SIMD3(obj.boundingMin.x, obj.boundingMin.y, obj.boundingMin.z),
                SIMD3(obj.boundingMax.x, obj.boundingMin.y, obj.boundingMin.z),
                SIMD3(obj.boundingMin.x, obj.boundingMax.y, obj.boundingMin.z),
                SIMD3(obj.boundingMax.x, obj.boundingMax.y, obj.boundingMin.z),
                SIMD3(obj.boundingMin.x, obj.boundingMin.y, obj.boundingMax.z),
                SIMD3(obj.boundingMax.x, obj.boundingMin.y, obj.boundingMax.z),
                SIMD3(obj.boundingMin.x, obj.boundingMax.y, obj.boundingMax.z),
                SIMD3(obj.boundingMax.x, obj.boundingMax.y, obj.boundingMax.z),
            ]
            for c in corners {
                let w4 = rendered * SIMD4<Float>(c, 1)
                let w  = SIMD3<Float>(w4.x, w4.y, w4.z)
                wMin = simd_min(wMin, w)
                wMax = simd_max(wMax, w)
            }
        }

        // ── Positional lights: their world position ────────────────────────────
        for light in lightManager.lights {
            switch light.type {
            case .point, .spot, .laser:
                wMin = simd_min(wMin, light.position)
                wMax = simd_max(wMax, light.position)
            case .ambient, .directional:
                break   // no position to include
            }
        }

        // ── Derive sphere ──────────────────────────────────────────────────────
        let center     = (wMin + wMax) * 0.5
        let halfExtent = (wMax - wMin) * 0.5
        let radius     = max(simd_length(halfExtent), 0.5)

        // ── Place director above and behind the scene camera ───────────────────
        // Same yaw as the scene camera so the director is on the camera's "side"
        // of the scene; pitch elevated so we're looking down on it.
        director.target      = center
        director.distance    = radius * 3.0
        director.yaw         = camera.yaw
        director.pitch       = max(camera.pitch + 0.5, 0.5)   // ≥ ~29° above horizon
        director.fovYRadians = 50.0 * Float.pi / 180.0        // wider than scene cam
        directorEverFit      = true

        print("[DEBUG] ViewportView: director auto-fit — center=("
            + String(format: "%.2f", center.x) + ","
            + String(format: "%.2f", center.y) + ","
            + String(format: "%.2f", center.z) + ")"
            + " radius=" + String(format: "%.2f", radius)
            + " distance=" + String(format: "%.2f", director.distance))
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

    // MARK: - Group helpers (Model mode)

    /// Returns the parts to move in Model mode: all group members if the selected
    /// object has a groupID, otherwise just the selected object alone.
    private func groupParts() -> [SceneObject] {
        guard let obj = sceneManager.selectedObject ?? sceneManager.primaryObject else {
            return []
        }
        if let gid = obj.groupID {
            return sceneManager.objects(inGroup: gid)
        }
        return [obj]
    }

    /// Visual world-space centre of a group, accounting for the group transform layer.
    /// Phase 2: final rendered position = groupTransform × obj.transform, so the
    /// pivot used for rotations must be computed from that combined matrix.
    private func groupCenter(_ parts: [SceneObject]) -> SIMD3<Float> {
        let gid    = parts.first?.groupID
        let groupT = gid.flatMap { sceneManager.groupTransforms[$0] } ?? matrix_identity_float4x4
        var wMin = SIMD3<Float>(repeating:  Float.infinity)
        var wMax = SIMD3<Float>(repeating: -Float.infinity)
        for obj in parts {
            let rendered = groupT * obj.transform
            let wc = rendered * SIMD4<Float>(obj.boundingCenter, 1)
            wMin = simd_min(wMin, SIMD3<Float>(wc.x, wc.y, wc.z))
            wMax = simd_max(wMax, SIMD3<Float>(wc.x, wc.y, wc.z))
        }
        return (wMin + wMax) * 0.5
    }

    // ── Phase 2: Model-mode movement drives the GROUP TRANSFORM layer ─────────
    // Instead of modifying each part's transform directly, we accumulate a
    // single group-level matrix in SceneManager.groupTransforms[gid].
    // The renderer multiplies: groupTransform × obj.transform for each part.

    /// Translates the group transform by `delta` (world-space).
    private func translateGroup(_ parts: [SceneObject], by delta: SIMD3<Float>) {
        guard let gid = parts.first?.groupID else {
            // Ungrouped fallback — move parts directly.
            for obj in parts {
                obj.transform.columns.3.x += delta.x
                obj.transform.columns.3.y += delta.y
                obj.transform.columns.3.z += delta.z
            }
            return
        }
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(delta.x, delta.y, delta.z, 1)
        let current = sceneManager.groupTransforms[gid] ?? matrix_identity_float4x4
        sceneManager.groupTransforms[gid] = t * current
    }

    /// Rotates the group transform by `q` around the shared world-space `pivot`.
    private func rotateGroup(_ parts: [SceneObject], by q: simd_quatf, around pivot: SIMD3<Float>) {
        guard let gid = parts.first?.groupID else {
            // Ungrouped fallback.
            let rot = rotationMatrix4x4(q)
            var tFwd = matrix_identity_float4x4;  tFwd.columns.3 = SIMD4<Float>( pivot.x,  pivot.y,  pivot.z, 1)
            var tInv = matrix_identity_float4x4;  tInv.columns.3 = SIMD4<Float>(-pivot.x, -pivot.y, -pivot.z, 1)
            let compound = tFwd * rot * tInv
            for obj in parts { obj.transform = compound * obj.transform }
            return
        }
        let rot = rotationMatrix4x4(q)
        var tFwd = matrix_identity_float4x4;  tFwd.columns.3 = SIMD4<Float>( pivot.x,  pivot.y,  pivot.z, 1)
        var tInv = matrix_identity_float4x4;  tInv.columns.3 = SIMD4<Float>(-pivot.x, -pivot.y, -pivot.z, 1)
        let compound = tFwd * rot * tInv
        let current  = sceneManager.groupTransforms[gid] ?? matrix_identity_float4x4
        sceneManager.groupTransforms[gid] = compound * current
    }

    /// Scales the group transform uniformly around the shared world-space `pivot`.
    private func scaleGroup(_ parts: [SceneObject], by factor: Float, around pivot: SIMD3<Float>) {
        guard let gid = parts.first?.groupID else {
            // Ungrouped fallback.
            for obj in parts {
                obj.transform.columns.0 *= factor
                obj.transform.columns.1 *= factor
                obj.transform.columns.2 *= factor
                let t    = SIMD3<Float>(obj.transform.columns.3.x,
                                        obj.transform.columns.3.y,
                                        obj.transform.columns.3.z)
                let newT = pivot + (t - pivot) * factor
                obj.transform.columns.3 = SIMD4<Float>(newT.x, newT.y, newT.z, 1)
            }
            return
        }
        var s = matrix_identity_float4x4
        s.columns.0.x = factor; s.columns.1.y = factor; s.columns.2.z = factor
        var tFwd = matrix_identity_float4x4;  tFwd.columns.3 = SIMD4<Float>( pivot.x,  pivot.y,  pivot.z, 1)
        var tInv = matrix_identity_float4x4;  tInv.columns.3 = SIMD4<Float>(-pivot.x, -pivot.y, -pivot.z, 1)
        let compound = tFwd * s * tInv
        let current  = sceneManager.groupTransforms[gid] ?? matrix_identity_float4x4
        sceneManager.groupTransforms[gid] = compound * current
    }

    // MARK: - Auto-normalization

    /// Computes a single uniform scale from the **combined** world-space AABB of all
    /// parts, then applies it to every object.  This guarantees that multi-part models
    /// (e.g. a character with 30+ named nodes) are scaled correctly as a whole rather
    /// than each part being sized independently based on its own tiny bounding sphere.
    ///
    /// Returns the post-scale (center, radius) for camera placement.
    @discardableResult
    private func autoNormalize(_ objects: [SceneObject]) -> (center: SIMD3<Float>, radius: Float) {
        guard !objects.isEmpty else { return (.zero, 1.0) }

        let targetRadius: Float = 1.0

        // ── Step 1: expand a world-space AABB from all 8 corners of each part ──
        var worldMin = SIMD3<Float>(repeating:  Float.infinity)
        var worldMax = SIMD3<Float>(repeating: -Float.infinity)

        for obj in objects {
            let t = obj.transform
            for ix in [obj.boundingMin.x, obj.boundingMax.x] {
                for iy in [obj.boundingMin.y, obj.boundingMax.y] {
                    for iz in [obj.boundingMin.z, obj.boundingMax.z] {
                        let wp = t * SIMD4<Float>(ix, iy, iz, 1)
                        let w  = SIMD3<Float>(wp.x, wp.y, wp.z)
                        worldMin = simd_min(worldMin, w)
                        worldMax = simd_max(worldMax, w)
                    }
                }
            }
        }

        let worldCenter = (worldMin + worldMax) * 0.5
        let worldRadius = simd_length(worldMax - worldMin) * 0.5

        print("[DEBUG] ViewportView: autoNormalize \(objects.count) part(s) — worldRadius=\(worldRadius)")

        guard worldRadius > 0.0001 else {
            print("[DEBUG] ViewportView: autoNormalize — worldRadius near zero, skipping")
            return (worldCenter, 1.0)
        }

        let scale = targetRadius / worldRadius
        guard abs(scale - 1.0) > 0.02 else {
            print("[DEBUG] ViewportView: autoNormalize — already near 1.0, skipping")
            return (worldCenter, worldRadius)
        }

        // ── Step 2: apply the same scale matrix to every part ─────────────────
        var S = matrix_identity_float4x4
        S.columns.0.x = scale
        S.columns.1.y = scale
        S.columns.2.z = scale

        for obj in objects {
            obj.transform = S * obj.transform
            // For root parts (no parent), localTransform equals transform.
            // Non-root parts' localTransforms are unchanged because uniform scale
            // distributes correctly through the hierarchy: the scaled parent world
            // transform times the unchanged local transform gives the correctly-scaled
            // child world transform.  applyHierarchy() propagates this each frame.
            if obj.parentIndex == nil {
                obj.localTransform = obj.transform
            }
            // boundingCenter / boundingRadius stay in mesh-local space — both
            // consumers (groupCenter, worldOrbitAnchor) re-apply the object's
            // current world transform to get the live world position.  Baking
            // the load-pose world transform into boundingCenter here was the
            // source of a long-standing camera-follow drift bug: animated parts
            // saw `posMat * (loadTransform * localCenter)` instead of
            // `posMat * localCenter`, and the anchor drifted as the part moved.
        }

        let finalCenter = worldCenter * scale
        print("[DEBUG] ViewportView: autoNormalize scale=\(scale) — worldRadius \(worldRadius) → \(targetRadius)")
        return (finalCenter, targetRadius)
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

        // In model mode, keyframes apply to the selected part only.
        // Full group keyframing is a future enhancement.
        if obj.keyframeTrack == nil {
            obj.keyframeTrack = KeyframeTrack()
            print("[DEBUG] ViewportView: created new KeyframeTrack for '" + obj.name + "'")
        }

        let invBase = simd_inverse(obj.baseTransform)
        // For hierarchical parts, the delta is relative to the base LOCAL transform;
        // for root parts, it is relative to the base world transform (unchanged).
        let m = invBase * (obj.parentIndex != nil ? obj.localTransform : obj.transform)

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

    // MARK: - Add Group Keyframe (Phase 2)

    /// Stamps a group-level keyframe at the current time by decomposing the live
    /// group transform stored in SceneManager.groupTransforms[gid] into TRS.
    /// The group track sits above per-part animation in the render stack:
    ///   finalTransform = groupTransform × (baseTransform × partDelta)
    func addGroupKeyframeAtCurrentTime(for gid: Int) {
        if sceneManager.groupKeyframeTracks[gid] == nil {
            sceneManager.groupKeyframeTracks[gid] = KeyframeTrack()
            print("[DEBUG] ViewportView: created group KeyframeTrack for groupID=\(gid)")
        }

        // If no group transform has been set yet, record identity (no offset).
        let m = sceneManager.groupTransforms[gid] ?? matrix_identity_float4x4

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
            print("[DEBUG] ViewportView: addGroupKeyframe — near-zero scale, using identity rotation")
        }

        let kf = TransformKeyframe(
            time:        timeline.currentTime,
            translation: translation,
            rotation:    rotation,
            scale:       scale
        )
        sceneManager.groupKeyframeTracks[gid]?.addKeyframe(kf)
        print("[DEBUG] ViewportView: group keyframe added at t="
            + String(format: "%.3f", timeline.currentTime)
            + " for groupID=\(gid)")
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
            target:   camera.target,
            fov:      camera.fovYRadians
        )
        camera.keyframeTrack?.addKeyframe(kf)

        print("[DEBUG] ViewportView: camera keyframe added at t="
            + String(format: "%.3f", timeline.currentTime)
            + " yaw=" + String(format: "%.4f", camera.yaw)
            + " pitch=" + String(format: "%.4f", camera.pitch)
            + " distance=" + String(format: "%.4f", camera.distance)
            + " fov=" + String(format: "%.4f", camera.fovYRadians))
    }

    /// World-space forward direction for the camera's current yaw / pitch.
    /// Mirrors the convention in `CameraController.eyePosition` so the
    /// inverse (`atan2(-fwd.x, -fwd.z)`, `asin(-fwd.y)`) round-trips exactly.
    private func cameraForward(yaw: Float, pitch: Float) -> SIMD3<Float> {
        let cp = cos(pitch)
        return SIMD3<Float>(-cp * sin(yaw), -sin(pitch), -cp * cos(yaw))
    }

    /// Adds a camera follow keyframe at the current playhead time.
    /// The follow target is the currently selected (or primary) object.
    ///
    /// Captures the camera's current state **as-is** (no aim adjustment) plus a
    /// `targetOffset` recording how far the user's chosen aim point is from the
    /// followed object's anchor, stored in the object's **local frame**.  At
    /// playback time, `target = anchor.pos + anchor.basis * targetOffset`
    /// reproduces the same relative framing wherever the anchor has moved AND
    /// rotated to — so the entire composition translates *and rotates* with
    /// the object.  `followYawOffset` does the same for the camera's yaw
    /// versus the body's facing direction.
    func addFollowCameraKeyframeAtCurrentTime() {
        guard let obj = sceneManager.selectedObject ?? sceneManager.primaryObject else {
            print("[DEBUG] ViewportView: addFollowCameraKeyframe — no object selected")
            return
        }
        if camera.keyframeTrack == nil {
            camera.keyframeTrack = CameraKeyframeTrack()
            print("[DEBUG] ViewportView: created new CameraKeyframeTrack")
        }

        var followYawOffset:    Float? = nil
        var followPitchOffset:  Float? = nil
        var targetOffset = SIMD3<Float>(0, 0, 0)
        var followForwardLocal: SIMD3<Float>? = nil
        if let anchor = sceneManager.worldOrbitAnchor(ofObjectNamed: obj.name) {
            followYawOffset   = camera.yaw    - anchor.behindYaw
            followPitchOffset = camera.pitch  - anchor.behindPitch
            // Convert the world-space delta into the followed object's local
            // frame.  For orthonormal basis, transpose = inverse.
            let worldDelta = camera.target - anchor.pos
            targetOffset   = anchor.basis.transpose * worldDelta
            // Capture the camera's forward direction in the object's local
            // frame so playback can rotate it by the object's current basis
            // and reproduce the camera-to-head direction exactly, regardless
            // of the object's later orientation.  See CameraKeyframe docs.
            let forwardWorld = cameraForward(yaw: camera.yaw, pitch: camera.pitch)
            followForwardLocal = anchor.basis.transpose * forwardWorld
        }

        let kf = CameraKeyframe(
            time:               timeline.currentTime,
            yaw:                camera.yaw,
            pitch:              camera.pitch,
            distance:           camera.distance,
            target:             camera.target,
            fov:                camera.fovYRadians,
            followTargetName:   obj.name,
            followYawOffset:    followYawOffset,
            followPitchOffset:  followPitchOffset,
            targetOffset:       targetOffset,
            followForwardLocal: followForwardLocal
        )
        camera.keyframeTrack?.addKeyframe(kf)

        let yawOffStr   = followYawOffset  .map { String(format: "%.4f", $0) } ?? "nil"
        let pitchOffStr = followPitchOffset.map { String(format: "%.4f", $0) } ?? "nil"
        print("[DEBUG] ViewportView: follow camera keyframe added at t="
            + String(format: "%.3f", timeline.currentTime)
            + " followTarget='\(obj.name)'"
            + " yaw=" + String(format: "%.4f", camera.yaw)
            + " followYawOffset=" + yawOffStr
            + " followPitchOffset=" + pitchOffStr
            + " distance=" + String(format: "%.4f", camera.distance))
    }

    /// Variant of `addFollowCameraKeyframeAtCurrentTime()` that follows a specific named
    /// object rather than the current selection.  Used by the keyframe-edit commit path
    /// to preserve the original follow target when re-writing an edited keyframe.
    ///
    /// Same capture-as-is behaviour as the no-arg variant.
    func addFollowCameraKeyframeAtCurrentTime(followingObjectNamed targetName: String) {
        if camera.keyframeTrack == nil {
            camera.keyframeTrack = CameraKeyframeTrack()
            print("[DEBUG] ViewportView: created new CameraKeyframeTrack")
        }
        var followYawOffset:    Float? = nil
        var followPitchOffset:  Float? = nil
        var targetOffset = SIMD3<Float>(0, 0, 0)
        var followForwardLocal: SIMD3<Float>? = nil
        if let anchor = sceneManager.worldOrbitAnchor(ofObjectNamed: targetName) {
            followYawOffset   = camera.yaw    - anchor.behindYaw
            followPitchOffset = camera.pitch  - anchor.behindPitch
            // Convert the world-space delta into the followed object's local
            // frame.  For orthonormal basis, transpose = inverse.
            let worldDelta = camera.target - anchor.pos
            targetOffset   = anchor.basis.transpose * worldDelta
            let forwardWorld = cameraForward(yaw: camera.yaw, pitch: camera.pitch)
            followForwardLocal = anchor.basis.transpose * forwardWorld
        }
        let kf = CameraKeyframe(
            time:               timeline.currentTime,
            yaw:                camera.yaw,
            pitch:              camera.pitch,
            distance:           camera.distance,
            target:             camera.target,
            fov:                camera.fovYRadians,
            followTargetName:   targetName,
            followYawOffset:    followYawOffset,
            followPitchOffset:  followPitchOffset,
            targetOffset:       targetOffset,
            followForwardLocal: followForwardLocal
        )
        camera.keyframeTrack?.addKeyframe(kf)

        let yawOffStr   = followYawOffset  .map { String(format: "%.4f", $0) } ?? "nil"
        let pitchOffStr = followPitchOffset.map { String(format: "%.4f", $0) } ?? "nil"
        print("[DEBUG] ViewportView: follow camera keyframe updated at t="
            + String(format: "%.3f", timeline.currentTime)
            + " followTarget='\(targetName)'"
            + " followYawOffset=" + yawOffStr
            + " followPitchOffset=" + pitchOffStr)
    }

    /// Stamps a camera keyframe using the Camera panel's sticky follow-target
    /// choice — nil = free camera, otherwise the named object.  Bypasses the
    /// scene-selection-driven menu path so the user can stamp many follow
    /// keyframes for the same target without re-selecting it each time.
    /// If the chosen target no longer exists in the scene, falls back to a
    /// free keyframe and logs.
    func addCameraKeyframeFromPanel() {
        if let name = cameraPanelState.followTargetName {
            if sceneManager.objects.contains(where: { $0.name == name }) {
                addFollowCameraKeyframeAtCurrentTime(followingObjectNamed: name)
            } else {
                print("[DEBUG] ViewportView: panel follow target '\(name)' missing"
                    + " — stamping a free camera keyframe instead")
                addCameraKeyframeAtCurrentTime()
            }
        } else {
            addCameraKeyframeAtCurrentTime()
        }
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
        // Reset axis lock for the new left-drag gesture.
        dragLockAxis = .none
        dragAccumX   = 0
        dragAccumY   = 0
    }

    override func mouseDragged(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let dx  = Float(loc.x - lastMouseLocation.x)
        let dy  = Float(loc.y - lastMouseLocation.y)
        lastMouseLocation = loc

        if isSpaceDown {
            // Space+drag: free orbit.  In Scene mode this navigates the Director
            // (the rendering camera in that mode); otherwise it orbits the scene
            // camera.  Either way it orbits whatever you're currently looking through.
            if sceneModeActive {
                director.orbit(deltaX: dx, deltaY: dy)
            } else {
                camera.orbit(deltaX: dx, deltaY: dy)
            }

        } else if controlMode == .object {
            // Object mode: axis-locked translation.
            // Accumulate until one axis dominates, then move only along that axis
            // so horizontal/vertical alignment is clean and precise.
            guard !timeline.isPlaying,
                  let obj = sceneManager.selectedObject ?? sceneManager.primaryObject
            else { return }

            if dragLockAxis == .none {
                dragAccumX += dx
                dragAccumY += dy
                let dist = (dragAccumX * dragAccumX + dragAccumY * dragAccumY).squareRoot()
                guard dist >= dragLockThreshold else { return }
                dragLockAxis = abs(dragAccumX) >= abs(dragAccumY) ? .horizontal : .vertical
            }

            let scale = camera.distance * 0.001
            let move: SIMD3<Float>
            switch dragLockAxis {
            case .horizontal: move = camera.rightVector * (dx * scale)
            case .vertical:   move = camera.upVector   * (dy * scale)
            case .none:       return
            }
            obj.transform.columns.3.x += move.x
            obj.transform.columns.3.y += move.y
            obj.transform.columns.3.z += move.z
            syncLocalTransform(obj)

        } else if controlMode == .model {
            // Model mode: axis-locked translation of all group parts.
            guard !timeline.isPlaying else { return }
            let parts = groupParts()
            guard !parts.isEmpty else { return }

            if dragLockAxis == .none {
                dragAccumX += dx
                dragAccumY += dy
                let dist = (dragAccumX * dragAccumX + dragAccumY * dragAccumY).squareRoot()
                guard dist >= dragLockThreshold else { return }
                dragLockAxis = abs(dragAccumX) >= abs(dragAccumY) ? .horizontal : .vertical
            }

            let scale = camera.distance * 0.001
            let move: SIMD3<Float>
            switch dragLockAxis {
            case .horizontal: move = camera.rightVector * (dx * scale)
            case .vertical:   move = camera.upVector   * (dy * scale)
            case .none:       return
            }
            translateGroup(parts, by: move)

        } else if controlMode == .light {
            // Light mode: axis-locked drag.
            //   Directional → steer (rotate direction)
            //   Point / spot / laser → translate position camera-relative
            //   Ambient → no-op
            if dragLockAxis == .none {
                dragAccumX += dx
                dragAccumY += dy
                let dist = (dragAccumX * dragAccumX + dragAccumY * dragAccumY).squareRoot()
                guard dist >= dragLockThreshold else { return }
                dragLockAxis = abs(dragAccumX) >= abs(dragAccumY) ? .horizontal : .vertical
            }

            let lockedDx: Float = (dragLockAxis == .horizontal) ? dx : 0
            let lockedDy: Float = (dragLockAxis == .vertical)   ? dy : 0

            switch lightManager.selectedLight?.type {
            case .directional:
                let sensitivity: Float = 0.005
                lightManager.rotateSelected(deltaAzimuth:   -lockedDx * sensitivity,
                                            deltaElevation: -lockedDy * sensitivity)
            case .point, .spot, .laser:
                let scale = camera.distance * 0.001
                let d = camera.rightVector * (lockedDx * scale)
                      + camera.upVector    * (lockedDy * scale)
                lightManager.translateSelected(by: d)
            default:
                break
            }

        } else {
            // Camera mode: axis-locked pan.
            if dragLockAxis == .none {
                dragAccumX += dx
                dragAccumY += dy
                let dist = (dragAccumX * dragAccumX + dragAccumY * dragAccumY).squareRoot()
                guard dist >= dragLockThreshold else { return }
                dragLockAxis = abs(dragAccumX) >= abs(dragAccumY) ? .horizontal : .vertical
            }

            switch dragLockAxis {
            case .horizontal: camera.pan(deltaX: -dx, deltaY: 0)
            case .vertical:   camera.pan(deltaX: 0,   deltaY: dy)
            case .none:       return
            }
        }
    }

    // MARK: - Right Mouse Input

    override func rightMouseDown(with event: NSEvent) {
        lastMouseLocation = convert(event.locationInWindow, from: nil)
        // Right drag is always free (no axis lock) — nothing to reset.
    }

    override func rightMouseDragged(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let dx  = Float(loc.x - lastMouseLocation.x)
        let dy  = Float(loc.y - lastMouseLocation.y)
        lastMouseLocation = loc

        let sensitivity: Float = 0.005
        switch controlMode {
        case .object:
            // Free rotation on both axes simultaneously — no axis lock.
            // Horizontal drag yaws around the world-up vector; vertical drag
            // pitches around the camera-right vector.  Both apply in the same
            // frame so diagonal strokes rotate cleanly in any direction.
            guard !timeline.isPlaying,
                  let obj = sceneManager.selectedObject ?? sceneManager.primaryObject
            else { return }

            let hRot = rotationMatrix4x4(simd_quatf(angle:  dx * sensitivity,
                                                     axis: camera.upVector))
            let vRot = rotationMatrix4x4(simd_quatf(angle: -dy * sensitivity,
                                                     axis: camera.rightVector))
            let rot  = vRot * hRot   // horizontal applied first, vertical on top

            let localCentre = (obj.boundingMin + obj.boundingMax) * 0.5
            let wc4   = obj.transform * SIMD4<Float>(localCentre, 1)
            let pivot = SIMD3<Float>(wc4.x, wc4.y, wc4.z)

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

            let mc4    = obj.transform * SIMD4<Float>(localCentre, 0)
            let newPos = pivot - SIMD3<Float>(mc4.x, mc4.y, mc4.z)
            obj.transform.columns.3 = SIMD4<Float>(newPos.x, newPos.y, newPos.z, 1)
            syncLocalTransform(obj)

        case .model:
            // Free rotation of the whole group on both axes simultaneously.
            guard !timeline.isPlaying else { return }
            let parts = groupParts()
            guard !parts.isEmpty else { return }

            let hQuat = simd_quatf(angle:  dx * sensitivity, axis: camera.upVector)
            let vQuat = simd_quatf(angle: -dy * sensitivity, axis: camera.rightVector)
            let pivot = groupCenter(parts)
            rotateGroup(parts, by: vQuat * hQuat, around: pivot)

        case .light:
            // Right drag: rotate the selected light (azimuth + elevation).
            lightManager.rotateSelected(deltaAzimuth: -dx * sensitivity, deltaElevation: -dy * sensitivity)

        case .camera:
            // Right drag: free-look on both axes.
            camera.freeLook(deltaYaw: -dx * sensitivity, deltaPitch: dy * sensitivity)
        }
    }

    /// Rotates `obj` by quaternion `q` in-place: only the 3×3 orientation block
    /// is updated; the translation (columns.3) is left unchanged.  This is what
    /// keyboard Shift+arrow / bracket rotation uses so the object spins without
    /// any position drift.
    private func rotateInPlace(_ obj: SceneObject, by q: simd_quatf) {
        let rot = rotationMatrix4x4(q)
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
        syncLocalTransform(obj)
    }

    /// Rotates `obj` by quaternion `q` around its bounding-box centre (world space),
    /// so the object spins in-place rather than orbiting the world origin.
    /// Used by right-drag (fine increments); keyboard rotation uses rotateInPlace.
    private func rotateAroundBoundingCenter(_ obj: SceneObject, by q: simd_quatf) {
        let localCentre = (obj.boundingMin + obj.boundingMax) * 0.5
        let wc4   = obj.transform * SIMD4<Float>(localCentre, 1)
        let pivot = SIMD3<Float>(wc4.x, wc4.y, wc4.z)

        let rot = rotationMatrix4x4(q)

        // Rotate the orientation columns (w=0 so translation is unaffected).
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

        // Reposition so the local bounding centre stays at its world-space pivot.
        let mc4    = obj.transform * SIMD4<Float>(localCentre, 0)
        let newPos = pivot - SIMD3<Float>(mc4.x, mc4.y, mc4.z)
        obj.transform.columns.3 = SIMD4<Float>(newPos.x, newPos.y, newPos.z, 1)

        syncLocalTransform(obj)
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

        // Model mode: scale or push/pull the whole group.
        if controlMode == .model, !timeline.isPlaying {
            let parts = groupParts()
            if !parts.isEmpty {
                if event.modifierFlags.contains(.option) {
                    let factor = exp(delta * 0.02)
                    scaleGroup(parts, by: factor, around: groupCenter(parts))
                } else {
                    let move = delta * camera.distance * 0.05
                    translateGroup(parts, by: camera.forwardVector * move)
                }
                return
            }
        }

        // Camera mode: scroll wheel dollies the rig (translates along forward).
        // Focal-length / FOV change is on the +/− keys instead.
        if controlMode == .camera, !timeline.isPlaying {
            camera.dolly(delta: delta)
            return
        }

        // Light mode: move the selected light toward / away from the scene
        // (along the camera's forward axis — "into / out of the screen").
        if controlMode == .light, !timeline.isPlaying {
            let move = delta * camera.distance * 0.05
            lightManager.translateSelected(by: camera.forwardVector * move)
            return
        }

        guard controlMode == .object,
              !timeline.isPlaying,
              let obj = sceneManager.selectedObject ?? sceneManager.primaryObject
        else {
            camera.zoom(delta: delta)
            return
        }

        if event.modifierFlags.contains(.option) {
            // ⌥ + scroll → uniform scale around the object's visual centre.
            let factor = exp(delta * 0.02)

            let localCentre = (obj.boundingMin + obj.boundingMax) * 0.5
            let wc4   = obj.transform * SIMD4<Float>(localCentre, 1)
            let pivot = SIMD3<Float>(wc4.x, wc4.y, wc4.z)

            obj.transform.columns.0 *= factor
            obj.transform.columns.1 *= factor
            obj.transform.columns.2 *= factor

            let mc4    = obj.transform * SIMD4<Float>(localCentre, 0)
            let newPos = pivot - SIMD3<Float>(mc4.x, mc4.y, mc4.z)
            obj.transform.columns.3 = SIMD4<Float>(newPos.x, newPos.y, newPos.z, 1)
            syncLocalTransform(obj)

        } else {
            // Plain scroll → translate along the camera forward axis (depth push/pull)
            let move = delta * camera.distance * 0.05
            let fwd  = camera.forwardVector
            obj.transform.columns.3.x += fwd.x * move
            obj.transform.columns.3.y += fwd.y * move
            obj.transform.columns.3.z += fwd.z * move
            syncLocalTransform(obj)
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
        case .model:
            // Seek uses the selected part's track in model mode.
            let idx = sceneManager.selectedIndex
            times = idx < sceneManager.objects.count
                ? (sceneManager.objects[idx].keyframeTrack?.keyframes.map { $0.time } ?? [])
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

    // MARK: - Arrow-key dispatch
    //
    // Plain arrow = primary action; Shift+arrow = secondary.
    //   • Camera primary  : `camera.pan` (truck/pedestal)
    //   • Camera secondary: `camera.freeLook` (aim rotation)
    //   • Object/Model primary  : translate, camera-relative
    //   • Object/Model secondary: rotate (rotateInPlace around world axes)
    //   • Light primary  : steer (directional) or translate position camera-relative (point/spot/laser)
    //   • Light secondary: rotate direction (directional/spot/laser); no-op for point/ambient
    //
    // (dx, dy) ∈ {(±1, 0), (0, ±1)} — screen-space direction (right = +x, up = +y).

    private func applyArrow(dx: Int, dy: Int, shift: Bool) {
        let dxF   = Float(dx)
        let dyF   = Float(dy)
        let right = camera.rightVector
        let up    = camera.upVector

        switch controlMode {
        case .camera:
            if shift {
                // Free-look (aim rotates).  Sign convention matches the previous
                // Shift+arrow behavior: dx>0 → free-look yaw +rotStep, dy>0 → +pitch.
                camera.freeLook(deltaYaw: dxF * rotStep, deltaPitch: dyF * rotStep)
            } else {
                // Truck / pedestal.  Sign convention matches the previous plain-arrow
                // behavior: dx>0 (→) calls camera.pan(deltaX: -panStep, 0), and
                // dx<0 (←) calls camera.pan(deltaX: +panStep, 0).
                camera.pan(deltaX: -dxF * panStep, deltaY: dyF * panStep)
            }

        case .light:
            let translateDelta = (right * dxF + up * dyF) * translateStep
            if shift {
                // Secondary: rotate direction (directional/spot/laser).  point/ambient: no-op.
                lightManager.rotateSelected(deltaAzimuth:   -dxF * lightStep,
                                            deltaElevation: -dyF * lightStep)
            } else {
                // Primary: steer for directional only; translate for point/spot/laser.
                switch lightManager.selectedLight?.type {
                case .directional:
                    lightManager.rotateSelected(deltaAzimuth:   -dxF * lightStep,
                                                deltaElevation: -dyF * lightStep)
                case .point, .spot, .laser:
                    lightManager.translateSelected(by: translateDelta)
                default:
                    break
                }
            }

        case .object:
            guard let obj = sceneManager.selectedObject else { return }
            if shift {
                // Secondary: rotate around world Y (for ←/→) or world X (for ↑/↓).
                if dx != 0 {
                    rotateInPlace(obj, by: simd_quatf(angle:  dxF * rotStep,
                                                       axis: SIMD3<Float>(0, 1, 0)))
                }
                if dy != 0 {
                    rotateInPlace(obj, by: simd_quatf(angle: -dyF * rotStep,
                                                       axis: SIMD3<Float>(1, 0, 0)))
                }
            } else {
                // Primary: camera-relative translation.
                let d = (right * dxF + up * dyF) * translateStep
                obj.transform.columns.3.x += d.x
                obj.transform.columns.3.y += d.y
                obj.transform.columns.3.z += d.z
                syncLocalTransform(obj)
            }

        case .model:
            let parts = groupParts()
            guard !parts.isEmpty else { return }
            if shift {
                let pivot = groupCenter(parts)
                if dx != 0 {
                    rotateGroup(parts,
                                by: simd_quatf(angle:  dxF * rotStep,
                                               axis: SIMD3<Float>(0, 1, 0)),
                                around: pivot)
                }
                if dy != 0 {
                    rotateGroup(parts,
                                by: simd_quatf(angle: -dyF * rotStep,
                                               axis: SIMD3<Float>(1, 0, 0)),
                                around: pivot)
                }
            } else {
                translateGroup(parts, by: (right * dxF + up * dyF) * translateStep)
            }
        }
    }

    /// `+` / `−` keys: depth movement along camera-forward, or scale (with Option).
    /// Camera mode is unaffected by Option.
    private func applyDepthKey(positive: Bool, optionDown: Bool) {
        let sign: Float = positive ? 1 : -1
        let fwd = camera.forwardVector

        switch controlMode {
        case .camera:
            // +/− changes focal length (FOV). Scroll wheel handles dolly.
            camera.lensZoom(delta: sign * zoomStep / 0.05)

        case .light:
            lightManager.translateSelected(by: fwd * (sign * translateStep * 2))

        case .object:
            guard let obj = sceneManager.selectedObject else { return }
            if optionDown {
                let factor: Float = positive ? scaleStep : 1.0 / scaleStep
                let sv = SIMD4<Float>(factor, factor, factor, 1)
                obj.transform.columns.0 *= sv
                obj.transform.columns.1 *= sv
                obj.transform.columns.2 *= sv
            } else {
                let d = fwd * (sign * translateStep)
                obj.transform.columns.3.x += d.x
                obj.transform.columns.3.y += d.y
                obj.transform.columns.3.z += d.z
            }
            syncLocalTransform(obj)

        case .model:
            let parts = groupParts()
            guard !parts.isEmpty else { return }
            if optionDown {
                let factor: Float = positive ? scaleStep : 1.0 / scaleStep
                scaleGroup(parts, by: factor, around: groupCenter(parts))
            } else {
                translateGroup(parts, by: fwd * (sign * translateStep))
            }
        }
    }

    // MARK: - Keyboard Input

    // Key code constants
    private enum KC {
        static let space:    UInt16 = 49
        static let w:        UInt16 = 13   // wireframe
        static let g:        UInt16 = 5    // color / greyscale toggle
        static let c:        UInt16 = 8    // camera mode
        static let l:        UInt16 = 37   // light mode
        static let o:        UInt16 = 31   // object mode / cycle
        static let p:        UInt16 = 35   // play / pause
        static let r:        UInt16 = 15   // reset object orientation to base
        static let s:        UInt16 = 1    // toggle Scene mode (Director view)
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
        static let m:            UInt16 = 46   // M — model (group) mode
        static let f:            UInt16 = 3    // F — nudge keyframe 1 frame forward
        static let b:            UInt16 = 11   // B — nudge keyframe 1 frame backward
        static let insert:       UInt16 = 114  // Insert / Help key
        static let i:            UInt16 = 34   // I — alias for Insert (add keyframe)
        // Playhead navigation
        static let home:         UInt16 = 115  // Home
        static let end:          UInt16 = 119  // End
        // Letter aliases for laptops without dedicated Home / End keys.
        static let h:            UInt16 = 4    // H — alias for Home
        static let e:            UInt16 = 14   // E — alias for End
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
            case .model:
                if let gid = sceneManager.selectedGroupID {
                    addGroupKeyframeAtCurrentTime(for: gid)
                } else {
                    addKeyframeAtCurrentTime()   // ungrouped fallback
                }
            case .light:
                addLightKeyframeAtCurrentTime(forLightAt: lightManager.selectedIndex)
            }
            return
        }

        // ── Home / H — jump playhead to start ─────────────────────────────────
        if (kc == KC.home || kc == KC.h), !event.isARepeat {
            timeline.seek(to: 0)
            return
        }

        // ── End / E — jump playhead to end ────────────────────────────────────
        if (kc == KC.end || kc == KC.e), !event.isARepeat {
            timeline.seek(to: timeline.duration)
            return
        }

        // ── Tab / Shift+Tab — next / previous keyframe for active track ───────
        if kc == KC.tab, !event.isARepeat {
            let backward = event.modifierFlags.contains(.shift)
            seekToAdjacentKeyframe(backward: backward)
            return
        }

        // ── F / B — nudge selected keyframe one frame forward / backward ──────
        if kc == KC.f, !event.isARepeat {
            timelineKeyTarget?.nudgeSelectedKeyframe(by: 1.0 / 30.0)
            return
        }
        if kc == KC.b, !event.isARepeat {
            timelineKeyTarget?.nudgeSelectedKeyframe(by: -1.0 / 30.0)
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
                case .model:
                    if let gid = sceneManager.selectedGroupID {
                        addGroupKeyframeAtCurrentTime(for: gid)
                    } else {
                        addKeyframeAtCurrentTime()
                    }
                case .light:
                    addLightKeyframeAtCurrentTime(forLightAt: lightManager.selectedIndex)
                }
                return

            case KC.w:
                renderer?.isWireframe.toggle()
                print("[DEBUG] ViewportView: wireframe = " + String(renderer?.isWireframe ?? false))
                return

            case KC.g:
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
                }
                syncOverlayState()
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

            case KC.m:
                // M — switch to Model mode (move all parts of a group as one).
                controlMode = .model
                syncOverlayState()
                if let gid = sceneManager.selectedGroupID {
                    onControlModeChanged?(.group(gid))
                } else {
                    onControlModeChanged?(.object(sceneManager.selectedIndex))
                }
                return

            case KC.r:
                // R — reset rotation / orientation to defaults.
                //   ⌘R while in Scene mode: re-auto-fit the Director.
                //   Object/Model : restore original loaded rotation (position/scale preserved).
                //   Camera       : reset to default yaw/pitch/distance/target.
                //   Light        : reset selected light's direction to its default.
                if event.modifierFlags.contains(.command) {
                    if sceneModeActive {
                        autoFitDirector()
                        print("[DEBUG] ViewportView: Director re-auto-fit")
                    }
                    return
                }
                if controlMode == .object,
                   let obj = sceneManager.selectedObject ?? sceneManager.primaryObject {
                    resetObjectOrientation(obj)
                } else if controlMode == .camera {
                    camera.reset()
                } else if controlMode == .light {
                    lightManager.resetSelected()
                }
                return

            case KC.s:
                // S — toggle Scene mode (view from Director's POV).
                //   First entry in this session auto-fits the Director to the scene.
                //   Subsequent toggles keep the last Director pose (⌘R to re-fit).
                sceneModeActive.toggle()
                if sceneModeActive && !directorEverFit {
                    autoFitDirector()
                }
                syncOverlayState()
                print("[DEBUG] ViewportView: Scene mode = " + (sceneModeActive ? "ON" : "OFF"))
                return

            default:
                break
            }
        }

        // ── Directional keys — allow repeat so holding feels smooth ──────────
        switch kc {

        // ── Left arrow / KP4 ─────────────────────────────────────────────────
        case KC.left, KC.kp4:
            applyArrow(dx: -1, dy: 0, shift: event.modifierFlags.contains(.shift))

        // ── Right arrow / KP6 ────────────────────────────────────────────────
        case KC.right, KC.kp6:
            applyArrow(dx: 1, dy: 0, shift: event.modifierFlags.contains(.shift))

        // ── Up arrow / KP8 ───────────────────────────────────────────────────
        case KC.up, KC.kp8:
            applyArrow(dx: 0, dy: 1, shift: event.modifierFlags.contains(.shift))

        // ── Down arrow / KP2 ─────────────────────────────────────────────────
        case KC.down, KC.kp2:
            applyArrow(dx: 0, dy: -1, shift: event.modifierFlags.contains(.shift))

        // ── [ / { — roll left (object or group) ───────────────────────────────
        case KC.leftBracket:
            // Object/Model: roll left (Z−).  Camera: orbit yaw left.  Light: rotate azimuth left.
            if controlMode == .camera {
                camera.yaw -= rotStep
            } else if controlMode == .light {
                lightManager.rotateSelected(deltaAzimuth: lightStep, deltaElevation: 0)
            } else if controlMode == .object, let obj = sceneManager.selectedObject {
                rotateInPlace(obj, by: simd_quatf(angle: -rotStep, axis: SIMD3<Float>(0, 0, 1)))
            } else if controlMode == .model {
                let parts = groupParts()
                rotateGroup(parts, by: simd_quatf(angle: -rotStep, axis: SIMD3<Float>(0, 0, 1)), around: groupCenter(parts))
            }

        // ── ] / } — roll right (object or group); orbit yaw right (camera); azimuth right (light)
        case KC.rightBracket:
            if controlMode == .camera {
                camera.yaw += rotStep
            } else if controlMode == .light {
                lightManager.rotateSelected(deltaAzimuth: -lightStep, deltaElevation: 0)
            } else if controlMode == .object, let obj = sceneManager.selectedObject {
                rotateInPlace(obj, by: simd_quatf(angle: rotStep, axis: SIMD3<Float>(0, 0, 1)))
            } else if controlMode == .model {
                let parts = groupParts()
                rotateGroup(parts, by: simd_quatf(angle: rotStep, axis: SIMD3<Float>(0, 0, 1)), around: groupCenter(parts))
            }

        // ── Plus / KP+ ────────────────────────────────────────────────────────
        case KC.kpPlus, KC.regEqual:
            // ⌘+ in Scene mode dollies the Director in.  Otherwise standard +/− behaviour.
            if sceneModeActive && event.modifierFlags.contains(.command) {
                director.dolly(delta: zoomStep / 0.05)
            } else {
                applyDepthKey(positive: true, optionDown: event.modifierFlags.contains(.option))
            }

        // ── Minus / KP− ───────────────────────────────────────────────────────
        case KC.kpMinus, KC.regMinus:
            // ⌘− in Scene mode dollies the Director out.  Otherwise standard +/− behaviour.
            if sceneModeActive && event.modifierFlags.contains(.command) {
                director.dolly(delta: -(zoomStep / 0.05))
            } else {
                applyDepthKey(positive: false, optionDown: event.modifierFlags.contains(.option))
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

    // MARK: - Drag & Drop (NSDraggingDestination)

    private static let acceptedExtensions: Set<String> = ["glb", "gltf", "3dvp"]

    /// Extracts file URLs from a drag pasteboard, filtering to supported extensions.
    private func dragURLs(from info: NSDraggingInfo) -> [URL] {
        guard let items = info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL]
        else { return [] }
        return items.filter {
            Self.acceptedExtensions.contains($0.pathExtension.lowercased())
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !dragURLs(from: sender).isEmpty else { return [] }
        dragHighlightView?.isHidden = false
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = dragURLs(from: sender)
        if urls.isEmpty {
            dragHighlightView?.isHidden = true
            return []
        }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragHighlightView?.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dragHighlightView?.isHidden = true

        let urls = dragURLs(from: sender)
        guard !urls.isEmpty else { return false }

        let projectURLs = urls.filter { $0.pathExtension.lowercased() == "3dvp" }
        let modelURLs   = urls.filter { ["glb", "gltf"].contains($0.pathExtension.lowercased()) }

        // Single project file with no model files — delegate to AppDelegate for dirty-check.
        if projectURLs.count == 1 && modelURLs.isEmpty {
            onDropProjectFile?(projectURLs[0])
            return true
        }

        // Load all model files (project files ignored in mixed drops).
        var anyLoaded = false
        for url in modelURLs {
            addModelToScene(url: url)
            anyLoaded = true
        }
        if anyLoaded { onModelDropped?() }
        return anyLoaded
    }
}

// MARK: - Drag highlight overlay

/// Transparent overlay drawn on top of the Metal surface during a valid drag hover.
private final class DragHighlightView: NSView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isOpaque = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // Subtle accent tint over the entire viewport.
        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
        bounds.fill()

        // Inset rounded-rect border in the accent colour.
        let inset: CGFloat = 6
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset),
            xRadius: 10, yRadius: 10
        )
        path.lineWidth = 3
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}
