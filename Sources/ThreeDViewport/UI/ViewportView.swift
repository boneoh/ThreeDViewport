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
    case director // Scene-mode only: arrow keys / mouse navigate the Director POV

    var displayName: String {
        switch self {
        case .camera:   return "Camera"
        case .light:    return "Light"
        case .object:   return "Object"
        case .model:    return "Model"
        case .director: return "Director"
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
    /// Scene-mode "solo" view aids (keys 7 / 8).  Non-destructive — they only
    /// affect what the live Renderer draws; real isVisible / occludeWhenHidden are
    /// never changed.  Reset when leaving Scene mode.
    ///   7 → hide everything except the selected object's group.
    ///   8 → make those hidden others still occlude (holdout); only matters with 7.
    var sceneSoloHideOthers: Bool = false {
        didSet { renderer?.sceneSoloHideOthers = sceneSoloHideOthers }
    }
    var sceneSoloOccludeOthers: Bool = false {
        didSet { renderer?.sceneSoloOccludeOthers = sceneSoloOccludeOthers }
    }
    /// First-time-per-session auto-fit guard.  Toggling Scene off then on does
    /// NOT re-fit; the user has to press ⌘R to refit.
    private var directorEverFit: Bool = false
    var renderer: Renderer?

    /// Camera whose basis (right/up/forward) and distance drive object, light,
    /// and model manipulation, so movement matches what the user sees: the
    /// Director in Scene mode, the scene camera otherwise.  Outside Scene mode
    /// this is `camera`, so behaviour is unchanged.
    private var viewCamera: CameraController { sceneModeActive ? director : camera }

    // Phase 8: observable rendering settings (color / greyscale / gizmo)
    let renderSettings = RenderSettings()
    private var colorModeCancellable:   AnyCancellable?
    private var axesGizmoCancellable:   AnyCancellable?
    private var iblIntensityCancellable: AnyCancellable?
    private var loopRevCancellable:     AnyCancellable?

    // Feedback delay-line system
    let feedbackSettings    = FeedbackSettings()
    let feedbackProcessor:   FeedbackProcessor   // created after Metal device is ready
    let colorGradeSettings = ColorGradeSettings()
    let fogSettings        = FogSettings()
    let particleManager    = ParticleManager()
    let coordinateClipboard = CoordinateClipboard()
    let atmospherePanelState = AtmospherePanelState()
    let probeConfig          = ProbeConfig()

    // Camera panel — sticky follow-target picker shared with the floating
    // CameraPanel inspector.  Lives here so the choice survives panel
    // hide/show cycles.
    let cameraPanelState   = CameraPanelState()
    // Orbit Path Animator helper state — lives here so captures + field values
    // survive panel hide/show cycles.
    let orbitPathState  = OrbitPathAnimatorState()
    // Linear Path Animator helper state.
    let linearPathState    = LinearPathAnimatorState()
    // Spin Animator helper state.
    let spinAnimatorState  = SpinAnimatorState()
    private var playbackCancellable: AnyCancellable?

    // Phase 6: HUD observable state — AppDelegate embeds the SwiftUI overlay using this.
    let overlayState = SceneOverlayState()

    // Active control mode: camera / light / object.
    // Writing updates the HUD automatically.
    /// True while the 'V' keyframe motion-path overlay is on.  The actual path
    /// (camera / light / object) follows the current controlMode + selection.
    private var showMotionVectors = false

    private var controlMode: ControlMode = .camera {
        didSet {
            overlayState.controlMode = controlMode
            updateMotionVectorTarget()   // overlay tracks the active entity
            print("[DEBUG] ViewportView: controlMode = " + controlMode.displayName)
        }
    }

    /// Maps the on/off flag + controlMode to the renderer's motion-vector target.
    private func updateMotionVectorTarget() {
        guard showMotionVectors else { renderer?.motionVectorTarget = .none; return }
        switch controlMode {
        case .camera, .director: renderer?.motionVectorTarget = .camera
        case .light:             renderer?.motionVectorTarget = .light
        case .object, .model:    renderer?.motionVectorTarget = .object
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

    /// Called immediately after a keyframe is stamped from anywhere (I / Insert
    /// key, transport-panel button, Camera panel button, edit-mode commit).
    /// AppDelegate wires this to highlight the just-stamped diamond in the
    /// Timeline Editor so the user can nudge it with F / B without first having
    /// to click it.
    var onKeyframeStamped: ((TrackRef) -> Void)?

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

    /// Fires after all keyframes for a model are cleared during a part-count-mismatch replace.
    /// AppDelegate wires this to refresh the Timeline Editor and mark the document dirty.
    var onKeyframesCleared: (() -> Void)?

    /// Fires when the user edits the camera from the Camera panel (e.g. Target).
    /// AppDelegate wires this to mark the document dirty.
    var onCameraEdited: (() -> Void)?

    // Probe-mark key actions, wired by AppDelegate (which owns the prompt + dirty).
    var onToggleMarks: (() -> Void)?
    var onCycleMark:   ((Int) -> Void)?   // +1 next, −1 previous
    var onDeleteMark:  (() -> Void)?

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
        // Color-grade post-process reads back drawable.texture via a blit copy,
        // which Metal validation forbids on framebufferOnly textures.
        framebufferOnly          = false
        clearColor               = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        // 50 paces cleanly on common refresh rates (100 Hz → 50 fps, 60 Hz → 30,
        // 120 Hz → 40) — always ≥ 30.  Playback speed is decoupled from this via
        // Timeline.tick(dt:)'s wall-clock advance, so a higher draw rate just means
        // smoother real-time preview, not faster playback.
        preferredFramesPerSecond = 50
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

        if renderer == nil {
            print("[DEBUG] ViewportView: Renderer init returned nil")
        }

        delegate = renderer

        // Wire feedback processor + settings into renderer
        renderer?.feedbackProcessor   = feedbackProcessor
        renderer?.feedbackSettings    = feedbackSettings
        renderer?.colorGradeSettings  = colorGradeSettings
        renderer?.fogSettings         = fogSettings
        renderer?.particleManager     = particleManager
        renderer?.probeConfig         = probeConfig

        // Camera panel — Position / Target edits write back to the real rendering
        // camera (never the Director), so the inspector stays meaningful in Scene mode.
        cameraPanelState.onPositionEdited = { [weak self] v in
            guard let self else { return }
            self.camera.setEyePosition(v)
            self.needsDisplay = true
            self.onCameraEdited?()
        }
        cameraPanelState.onTargetEdited = { [weak self] v in
            guard let self else { return }
            self.camera.setTargetKeepingEye(v)   // re-aim, keep eye fixed (don't drag Position)
            self.needsDisplay = true
            self.onCameraEdited?()
        }
        cameraPanelState.onFocalLengthEdited = { [weak self] fl in
            guard let self else { return }
            // fovY = 2·atan(12/fl); clamp to the existing lens-zoom range (10°–90°).
            let raw   = 2 * atan(12.0 / max(fl, 1))
            let minFv = Float.pi / 18.0
            let maxFv = Float.pi / 2.0
            self.camera.fovYRadians = max(minFv, min(maxFv, raw))
            self.needsDisplay = true
            self.onCameraEdited?()
        }
        // Conditional auto-stamp after Paste/Z on Position or Target: stamp only
        // when the camera track already has keyframes.
        cameraPanelState.onAutoStamp = { [weak self] in
            guard let self,
                  let track = self.camera.keyframeTrack,
                  !track.keyframes.isEmpty else { return }
            self.addCameraKeyframeFromPanel()
        }
        // POV sliders → reposition camera on the sphere around the followed target.
        cameraPanelState.onPOVLivePreview = { [weak self] name, dist, azDeg, elDeg in
            guard let self else { return }
            self.positionCameraOnFollowSphere(followingObjectNamed: name,
                                               distance: dist,
                                               azimuthDeg: azDeg,
                                               elevationDeg: elDeg)
            self.onCameraEdited?()
        }
        // POV stamp button → POV-flavoured follow keyframe at current playhead.
        cameraPanelState.onPOVStamp = { [weak self] name, dist, azDeg, elDeg in
            guard let self else { return }
            self.addPOVCameraKeyframeAtCurrentTime(followingObjectNamed: name,
                                                    distance: dist,
                                                    azimuthDeg: azDeg,
                                                    elevationDeg: elDeg)
            self.onCameraEdited?()
        }

        // Sync renderSettings → renderer whenever toggles change
        colorModeCancellable = renderSettings.$colorMode.sink { [weak self] value in
            self?.renderer?.colorMode = value
            print("[DEBUG] ViewportView: colorMode = " + value.displayName)
        }
        axesGizmoCancellable = renderSettings.$showAxesGizmo.sink { [weak self] value in
            self?.renderer?.showAxesGizmo = value
            print("[DEBUG] ViewportView: showAxesGizmo = \(value)")
        }
        iblIntensityCancellable = renderSettings.$iblIntensity.sink { [weak self] value in
            self?.renderer?.ibl?.intensity = value
            self?.needsDisplay = true
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

        // Part-count mismatch → ask user whether to replace (losing keyframes) or cancel.
        if newObjects.count != targets.count {
            let alert = NSAlert()
            alert.alertStyle      = .warning
            alert.messageText     = "Part Count Mismatch"
            alert.informativeText = "\"\(url.lastPathComponent)\" has \(newObjects.count)"
                + " part\(newObjects.count == 1 ? "" : "s")"
                + " but the selected model has \(targets.count)."
                + " Replacing will delete all keyframes for this model."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            print("[DEBUG] ViewportView: replaceSelectedModel — part count mismatch"
                + " (new=\(newObjects.count) existing=\(targets.count)), prompting user")

            let doReplace: () -> Void = { [weak self] in
                guard let self else { return }
                // Clear per-part keyframes.
                for target in targets { target.keyframeTrack?.removeAll() }
                // Clear the group keyframe track if applicable.
                if let gid = targets.first?.groupID {
                    sceneManager.groupKeyframeTracks[gid]?.removeAll()
                }
                self.performModelSwap(targets: targets, newObjects: newObjects, url: url)
                self.onKeyframesCleared?()
            }

            if let w = window {
                alert.beginSheetModal(for: w) { response in
                    if response == .alertFirstButtonReturn { doReplace() }
                }
            } else {
                if alert.runModal() == .alertFirstButtonReturn { doReplace() }
            }
            return
        }

        performModelSwap(targets: targets, newObjects: newObjects, url: url)
    }

    private func performModelSwap(targets: [SceneObject], newObjects: [SceneObject], url: URL) {
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

    /// Regenerates the normal buffer for each object in `targets` using the given mode
    /// and uploads it to the GPU.  Called by AppDelegate when the user changes the
    /// normal mode in the Model Inspector.
    func applyNormalMode(_ mode: NormalMode, toTargets targets: [SceneObject]) {
        guard let dev = device else { return }
        for obj in targets {
            let newNormals: [Float]
            switch mode {
            case .auto:   newNormals = obj.originalNormals
            case .smooth: newNormals = generateSmoothedNormals(positions: obj.cpuPositions, indices: obj.cpuIndices)
            case .flat:   newNormals = generateFlatNormals(positions: obj.cpuPositions, indices: obj.cpuIndices)
            }
            guard !newNormals.isEmpty else { continue }
            let byteLen = newNormals.count * MemoryLayout<Float>.stride
            if let buf = dev.makeBuffer(bytes: newNormals, length: byteLen, options: .storageModeShared) {
                buf.label    = "normals"
                obj.normalBuffer = buf
            }
        }
        needsDisplay = true
        print("[DEBUG] ViewportView: applyNormalMode \(mode) to \(targets.count) part(s)")
    }

    /// Sets the active control mode from outside the viewport (e.g. AppDelegate keyframe edit wiring).
    /// Updates the HUD overlay and notifies the timeline editor to highlight the matching lane.
    /// The TrackRef matching the current control mode + selection.  Single source
    /// of truth for "which timeline lane is active", reused by setControlMode and
    /// emitCurrentControlMode.
    /// The TrackRef matching the current control mode + selection, or nil for
    /// `.director` (the Director POV is not a timeline track).
    var currentTrackRef: TrackRef? {
        switch controlMode {
        case .camera: return .camera
        case .object: return .object(sceneManager.selectedIndex)
        case .light:  return .light(lightManager.selectedIndex)
        case .model:
            // The group header lane when the selection belongs to a group.
            if let gid = sceneManager.selectedGroupID { return .group(gid) }
            return .object(sceneManager.selectedIndex)
        case .director:
            return nil
        }
    }

    func setControlMode(_ mode: ControlMode) {
        controlMode = mode
        syncOverlayState()
        if let ref = currentTrackRef { onControlModeChanged?(ref) }
    }

    /// Re-broadcasts the current selection via onControlModeChanged.  Called when
    /// the Timeline Editor opens so it highlights the active lane immediately,
    /// instead of waiting for the next selection change.
    func emitCurrentControlMode() {
        if let ref = currentTrackRef { onControlModeChanged?(ref) }
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
        case .director:
            overlayState.selectedItemName = "POV"
        }
        // Solo aids (Scene mode) — show a marker so it's clear the others are
        // hidden by solo, not actually removed from the scene.
        if sceneModeActive && sceneSoloHideOthers {
            let marker = sceneSoloOccludeOthers ? "[Solo+Occlude]" : "[Solo]"
            overlayState.selectedItemName += overlayState.selectedItemName.isEmpty ? marker : "  " + marker
        }
    }

    // MARK: - FK hierarchy sync helper

    /// After directly modifying a hierarchical object's `transform` in Object mode,
    /// back-computes `localTransform` so the next `applyHierarchy()` call produces
    /// the same result.  For root / non-hierarchical objects, keeps `localTransform`
    /// equal to `transform` (they are the same thing for roots).
    /// Clamps an object's world translation to ±100 per axis so mouse drag,
    /// arrow keys, scroll-wheel translate, and depth keys honour the same hard
    /// limit as the Model Inspector's Position sliders.
    private func clampObjectPosition(_ obj: SceneObject) {
        let p = obj.transform.columns.3
        let c = simd_clamp(SIMD3<Float>(p.x, p.y, p.z),
                           SIMD3<Float>(repeating: -100),
                           SIMD3<Float>(repeating:  100))
        obj.transform.columns.3 = SIMD4<Float>(c.x, c.y, c.z, p.w)
    }

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
            if obj.isEnvelope { continue }   // null node — no geometry to frame
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

    // MARK: - Director standard views (Scene mode)

    /// One of the six axis-aligned views the number keys 1–6 snap the Director to.
    enum StandardView { case front, left, rear, right, top, bottom }

    /// Snaps the Director to an object-relative standard view of the current
    /// selection's group, framed to fit.  Object-relative: the view axes come from
    /// the group root's (parent's) current world orientation, so "Front" always
    /// shows the object's front no matter how it's flown / turned.  The orbit
    /// Director can't roll, so a banked object appears tilted but is seen from the
    /// correct side.  One-shot snap at the current pose — re-press after scrubbing.
    func snapDirectorToObjectView(_ view: StandardView) {
        guard sceneModeActive else { return }
        let parts = groupParts()
        guard !parts.isEmpty else { return }

        // Orientation reference: the group root (parentIndex == nil), else the
        // selected object.  Its rendered world rotation gives the local axes.
        let root   = parts.first(where: { $0.parentIndex == nil }) ?? parts[0]
        let groupT = root.groupID.flatMap { sceneManager.groupTransforms[$0] }
                   ?? matrix_identity_float4x4
        let world  = groupT * root.transform
        let localRight = simd_normalize(SIMD3<Float>(world.columns.0.x, world.columns.0.y, world.columns.0.z))
        let localUp    = simd_normalize(SIMD3<Float>(world.columns.1.x, world.columns.1.y, world.columns.1.z))
        let localFwd   = simd_normalize(SIMD3<Float>(world.columns.2.x, world.columns.2.y, world.columns.2.z))

        // Eye direction (object centre → camera).  This model's front is +Z, right
        // is +X, up is +Y.  Flip a pair here if a model reads reversed.
        let eyeDir: SIMD3<Float>
        switch view {
        case .front:  eyeDir =  localFwd
        case .rear:   eyeDir = -localFwd
        case .right:  eyeDir =  localRight
        case .left:   eyeDir = -localRight
        case .top:    eyeDir =  localUp
        case .bottom: eyeDir = -localUp
        }

        let (center, radius) = groupWorldBounds(parts)
        // Convert the world view direction into the orbit camera's yaw / pitch.
        let dir   = simd_normalize(eyeDir)
        var pitch = asin(max(-1, min(1, dir.y)))
        pitch     = max(-Float.pi / 2 + 0.01, min(Float.pi / 2 - 0.01, pitch))
        let yaw   = atan2(dir.x, dir.z)
        // Fit distance for the Director's current FOV (small margin so it isn't flush).
        let fov      = director.fovYRadians
        let distance = radius / max(sin(fov * 0.5), 0.01) * 1.05

        director.target   = center
        director.yaw      = yaw
        director.pitch    = pitch
        director.distance = max(distance, 0.1)

        print("[DEBUG] ViewportView: director snapped to \(view)")
    }

    /// World-space bounding sphere (centre + radius) over `parts` at their current
    /// pose, including the group-transform layer.  Mirrors autoFitDirector's AABB.
    private func groupWorldBounds(_ parts: [SceneObject]) -> (center: SIMD3<Float>, radius: Float) {
        let gid    = parts.first?.groupID
        let groupT = gid.flatMap { sceneManager.groupTransforms[$0] } ?? matrix_identity_float4x4
        var wMin = SIMD3<Float>(repeating:  Float.infinity)
        var wMax = SIMD3<Float>(repeating: -Float.infinity)
        for obj in parts {
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
                wMin = simd_min(wMin, SIMD3<Float>(w4.x, w4.y, w4.z))
                wMax = simd_max(wMax, SIMD3<Float>(w4.x, w4.y, w4.z))
            }
        }
        let center     = (wMin + wMax) * 0.5
        let halfExtent = (wMax - wMin) * 0.5
        let radius     = max(simd_length(halfExtent), 0.1)
        return (center, radius)
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
                clampObjectPosition(obj)
            }
            return
        }
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(delta.x, delta.y, delta.z, 1)
        let current = sceneManager.groupTransforms[gid] ?? matrix_identity_float4x4
        var combined = t * current
        // Clamp the group transform's translation column to ±100 per axis so
        // Model-mode drag / arrow / depth-key moves honour the same hard limit
        // as the Position sliders.
        let p = combined.columns.3
        let c = simd_clamp(SIMD3<Float>(p.x, p.y, p.z),
                           SIMD3<Float>(repeating: -100),
                           SIMD3<Float>(repeating:  100))
        combined.columns.3 = SIMD4<Float>(c.x, c.y, c.z, p.w)
        sceneManager.groupTransforms[gid] = combined
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

    // MARK: - Timeline duration

    /// True if any track (object / camera / light / group) holds at least one keyframe.
    /// Used to decide whether changing the duration needs the rescale prompt.
    var hasAnyKeyframes: Bool {
        if let kf = camera.keyframeTrack?.keyframes, !kf.isEmpty { return true }
        if sceneManager.objects.contains(where: { !($0.keyframeTrack?.keyframes.isEmpty ?? true) }) { return true }
        if lightManager.keyframeTracks.contains(where: { !($0?.keyframes.isEmpty ?? true) }) { return true }
        if sceneManager.groupKeyframeTracks.values.contains(where: { !$0.keyframes.isEmpty }) { return true }
        return false
    }

    /// Sets the timeline duration.  When `rescaleKeyframes` is true, every keyframe
    /// across all tracks is repositioned proportionally (time × new/old), snapped to
    /// the frame grid and clamped to the new range, so an animation built at one
    /// length fits the new length.  Project load / new-project paths call
    /// `timeline.duration` directly and never rescale.
    func setTimelineDuration(_ newDuration: Double, rescaleKeyframes: Bool) {
        let old = timeline.duration
        if rescaleKeyframes, old > 0.0001, abs(newDuration - old) > 1e-9 {
            rescaleAllKeyframeTimes(by: newDuration / old, newDuration: newDuration)
        }
        timeline.duration = newDuration
        if timeline.currentTime > newDuration { timeline.seek(to: newDuration) }
        // Force re-evaluation so the viewport reflects the moved keyframes immediately.
        renderer?.invalidateAnimationCache()
    }

    /// Scales every keyframe's time by `factor`, snapped to the frame grid and
    /// clamped to `[0, newDuration]`, then re-sorts each track.
    private func rescaleAllKeyframeTimes(by factor: Double, newDuration: Double) {
        let fr = timeline.frameRate
        func remap(_ t: Double) -> Double {
            min(max(0, (t * factor * fr).rounded() / fr), newDuration)
        }
        func rescale(_ track: KeyframeTrack) {
            for i in track.keyframes.indices { track.keyframes[i].time = remap(track.keyframes[i].time) }
            track.keyframes.sort { $0.time < $1.time }
        }
        for obj in sceneManager.objects { if let tr = obj.keyframeTrack { rescale(tr) } }
        for tr in sceneManager.groupKeyframeTracks.values { rescale(tr) }
        if let tr = camera.keyframeTrack {
            for i in tr.keyframes.indices { tr.keyframes[i].time = remap(tr.keyframes[i].time) }
            tr.keyframes.sort { $0.time < $1.time }
        }
        for case let tr? in lightManager.keyframeTracks {
            for i in tr.keyframes.indices { tr.keyframes[i].time = remap(tr.keyframes[i].time) }
            tr.keyframes.sort { $0.time < $1.time }
        }
    }

    // MARK: - Add Object Keyframe

    /// Merge window for stamping: a new keyframe within 1.5 frames of an existing
    /// one on the same track replaces it instead of stacking a near-duplicate.
    /// Tracks the project frame rate.
    private var stampMergeTolerance: Double { 1.5 / timeline.frameRate }

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
            scale:       scale,
            opacity:     obj.material.opacity
        )
        obj.keyframeTrack?.addKeyframe(kf, mergeTolerance: stampMergeTolerance)

        print("[DEBUG] ViewportView: keyframe added at t=" + String(format: "%.3f", timeline.currentTime)
            + " for '" + obj.name + "'")
        onKeyframeStamped?(.object(index))
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
        sceneManager.groupKeyframeTracks[gid]?.addKeyframe(kf, mergeTolerance: stampMergeTolerance)
        print("[DEBUG] ViewportView: group keyframe added at t="
            + String(format: "%.3f", timeline.currentTime)
            + " for groupID=\(gid)")
        onKeyframeStamped?(.group(gid))
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
            target:        light.target,
            position:      light.position,
            range:         light.range,
            beamThickness: light.beamThickness
        )
        lightManager.keyframeTracks[index]?.addKeyframe(kf, mergeTolerance: stampMergeTolerance)

        print("[DEBUG] ViewportView: light keyframe added at t="
            + String(format: "%.3f", timeline.currentTime)
            + " light=\(index)")
        onKeyframeStamped?(.light(index))
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
        camera.keyframeTrack?.addKeyframe(kf, mergeTolerance: stampMergeTolerance)

        print("[DEBUG] ViewportView: camera keyframe added at t="
            + String(format: "%.3f", timeline.currentTime)
            + " yaw=" + String(format: "%.4f", camera.yaw)
            + " pitch=" + String(format: "%.4f", camera.pitch)
            + " distance=" + String(format: "%.4f", camera.distance)
            + " fov=" + String(format: "%.4f", camera.fovYRadians))
        onKeyframeStamped?(.camera)
    }

    // MARK: - Path Animator

    /// Replaces all keyframes of `ref` within [startTime, endTime] with keyframes
    /// following the sampled helix.  Camera and lights aim at `fixedAim` (the axis
    /// midpoint); objects aim at the per-sample axis point (same height).  Only
    /// camera / light / object tracks are supported.
    func generatePath(ref: TrackRef,
                      samples:   [PathGenerator.Sample],
                      fixedAim:  SIMD3<Float>) {
        guard let first = samples.first, let last = samples.last else { return }
        let lo = min(first.time, last.time) - 1e-6
        let hi = max(first.time, last.time) + 1e-6

        switch ref {
        case .camera:
            if camera.keyframeTrack == nil { camera.keyframeTrack = CameraKeyframeTrack() }
            camera.keyframeTrack?.keyframes.removeAll { $0.time >= lo && $0.time <= hi }
            for s in samples {
                let dir   = s.position - fixedAim                  // eye − target
                let dist  = max(0.05, min(5000, simd_length(dir)))
                let pitch = asin(max(-1, min(1, dir.y / dist)))
                let yaw   = atan2(dir.x, dir.z)
                camera.keyframeTrack?.addKeyframe(CameraKeyframe(
                    time: s.time, yaw: yaw, pitch: pitch, distance: dist,
                    target: fixedAim, fov: camera.fovYRadians))
            }
            onKeyframeStamped?(.camera)

        case .light(let i):
            guard i >= 0, i < lightManager.lights.count else { return }
            let light = lightManager.lights[i]
            while lightManager.keyframeTracks.count <= i { lightManager.keyframeTracks.append(nil) }
            if lightManager.keyframeTracks[i] == nil { lightManager.keyframeTracks[i] = LightKeyframeTrack() }
            lightManager.keyframeTracks[i]?.keyframes.removeAll { $0.time >= lo && $0.time <= hi }
            for s in samples {
                lightManager.keyframeTracks[i]?.addKeyframe(LightKeyframe(
                    time: s.time, intensity: light.intensity, color: light.color,
                    target: fixedAim, position: s.position,
                    range: light.range, beamThickness: light.beamThickness))
            }
            onKeyframeStamped?(.light(i))

        case .object(let i):
            guard i >= 0, i < sceneManager.objects.count else { return }
            let obj = sceneManager.objects[i]
            if obj.keyframeTrack == nil { obj.keyframeTrack = KeyframeTrack() }
            obj.keyframeTrack?.keyframes.removeAll { $0.time >= lo && $0.time <= hi }
            let baseInv  = simd_inverse(obj.baseTransform)   // delta = inverse(base) · world
            let opacity  = obj.material.opacity
            let objScale = TransformMath.scale(of: obj.transform)   // preserve current size
            for s in samples {
                let worldRot = PathGenerator.lookAtRotation(from: s.position, to: s.axisPoint)
                let world    = PathGenerator.makeTransform(translation: s.position, rotation: worldRot, scale: objScale)
                let (t, r, sc) = PathGenerator.decompose(baseInv * world)
                obj.keyframeTrack?.addKeyframe(TransformKeyframe(
                    time: s.time, translation: t, rotation: r, scale: sc, opacity: opacity))
            }
            onKeyframeStamped?(.object(i))

        default:
            break   // group / fog / particles not supported
        }
    }

    /// Linear variant: replaces the selected track's keyframes in [start, end] with
    /// keyframes moving along a straight line.  Camera/lights keep their current
    /// orientation (parallel dolly); objects face the direction of travel.
    func generateLinearPath(ref: TrackRef,
                            samples:   [(time: Double, position: SIMD3<Float>)],
                            travelDir: SIMD3<Float>) {
        guard let first = samples.first, let last = samples.last else { return }
        let lo = min(first.time, last.time) - 1e-6
        let hi = max(first.time, last.time) + 1e-6

        switch ref {
        case .camera:
            if camera.keyframeTrack == nil { camera.keyframeTrack = CameraKeyframeTrack() }
            camera.keyframeTrack?.keyframes.removeAll { $0.time >= lo && $0.time <= hi }
            // Fixed orientation: keep current yaw/pitch/distance; translate eye→target
            // together so the view direction is preserved (parallel dolly).
            let offset   = camera.eyePosition - camera.target
            let yaw      = camera.yaw
            let pitch    = camera.pitch
            let distance = camera.distance
            let fov      = camera.fovYRadians
            for s in samples {
                camera.keyframeTrack?.addKeyframe(CameraKeyframe(
                    time: s.time, yaw: yaw, pitch: pitch, distance: distance,
                    target: s.position - offset, fov: fov))
            }
            onKeyframeStamped?(.camera)

        case .light(let i):
            guard i >= 0, i < lightManager.lights.count else { return }
            let light = lightManager.lights[i]
            let aimOffset = light.target - light.position   // keep beam direction constant
            while lightManager.keyframeTracks.count <= i { lightManager.keyframeTracks.append(nil) }
            if lightManager.keyframeTracks[i] == nil { lightManager.keyframeTracks[i] = LightKeyframeTrack() }
            lightManager.keyframeTracks[i]?.keyframes.removeAll { $0.time >= lo && $0.time <= hi }
            for s in samples {
                lightManager.keyframeTracks[i]?.addKeyframe(LightKeyframe(
                    time: s.time, intensity: light.intensity, color: light.color,
                    target: s.position + aimOffset, position: s.position,
                    range: light.range, beamThickness: light.beamThickness))
            }
            onKeyframeStamped?(.light(i))

        case .object(let i):
            guard i >= 0, i < sceneManager.objects.count else { return }
            let obj = sceneManager.objects[i]
            if obj.keyframeTrack == nil { obj.keyframeTrack = KeyframeTrack() }
            obj.keyframeTrack?.keyframes.removeAll { $0.time >= lo && $0.time <= hi }
            let baseInv  = simd_inverse(obj.baseTransform)
            let opacity  = obj.material.opacity
            let objScale = TransformMath.scale(of: obj.transform)   // preserve current size
            let canAim   = simd_length(travelDir) > 1e-6
            for s in samples {
                let worldRot = canAim
                    ? PathGenerator.lookAtRotation(from: s.position, to: s.position + travelDir)
                    : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
                let world    = PathGenerator.makeTransform(translation: s.position, rotation: worldRot, scale: objScale)
                let (t, r, sc) = PathGenerator.decompose(baseInv * world)
                obj.keyframeTrack?.addKeyframe(TransformKeyframe(
                    time: s.time, translation: t, rotation: r, scale: sc, opacity: opacity))
            }
            onKeyframeStamped?(.object(i))

        default:
            break   // group / fog / particles not supported
        }
    }

    // MARK: - Spin Animator

    /// Replaces an object **or model** track's keyframes in [start, end] with a
    /// constant, wobble-free self-spin about its own local X/Y/Z axis.
    ///
    /// **Object** (`.object`): the object's CURRENT pose is baked into every keyframe
    /// so the spin preserves its position and scale (delta = inverse(base) × current,
    /// `current` = localTransform for a glued child, transform for a root); the spin is
    /// post-multiplied onto the delta's rotation so it turns about its own local axis
    /// without drifting to the origin or resetting scale.
    ///
    /// **Model** (`.group`): writes the group-level track, spinning the whole model
    /// about its own world-space **centre**.  A pivot rotation `T(P)·R·T(-P)` is
    /// pre-multiplied onto the current group transform G0 (so θ=0 reproduces G0 — no
    /// pop), and the spin axis follows the model's current orientation.
    ///
    /// Either way the track is forced to LINEAR easing: slerp between equal-angle
    /// steps is exact constant-velocity rotation (no spline overshoot).  `axisIndex`
    /// 0/1/2 = local X/Y/Z.  Signed `revolutions` sets direction.
    func generateSpin(ref: TrackRef,
                      axisIndex:  Int,
                      revolutions: Float,
                      keyframesPerRevolution: Float,
                      startTime: Double,
                      endTime:   Double) {
        let lo = min(startTime, endTime) - 1e-6
        let hi = max(startTime, endTime) + 1e-6

        let axis: SIMD3<Float>
        switch axisIndex {
        case 0:  axis = SIMD3<Float>(1, 0, 0)
        case 2:  axis = SIMD3<Float>(0, 0, 1)
        default: axis = SIMD3<Float>(0, 1, 0)
        }

        let perRev = max(3.0, keyframesPerRevolution)   // <180° steps → correct short-arc slerp
        let count  = max(2, Int((abs(revolutions) * perRev).rounded(.up)) + 1)
        let deg2rad = Float.pi / 180.0
        let tStart = min(startTime, endTime)
        let tEnd   = max(startTime, endTime)
        // Even angle/time steps over the window: s ∈ [0, 1], angle starts at 0 (no pop).
        func angle(_ s: Float) -> Float  { revolutions * 360.0 * s * deg2rad }
        func time(_ s: Float)  -> Double { tStart + Double(s) * (tEnd - tStart) }

        switch ref {
        case .object(let i):
            guard i >= 0, i < sceneManager.objects.count else { return }
            let obj = sceneManager.objects[i]
            if obj.keyframeTrack == nil { obj.keyframeTrack = KeyframeTrack() }
            obj.keyframeTrack?.easingMode = .linear
            obj.keyframeTrack?.keyframes.removeAll { $0.time >= lo && $0.time <= hi }

            // Bake the object's current pose (relative to baseTransform) so the spin
            // keeps its live position and scale instead of snapping to the base.
            let baseInv = simd_inverse(obj.baseTransform)
            let current = (obj.parentIndex != nil) ? obj.localTransform : obj.transform
            let (baseT, baseR, baseS) = PathGenerator.decompose(baseInv * current)
            let opacity = obj.material.opacity

            for k in 0..<count {
                let s    = Float(k) / Float(count - 1)
                let spin = simd_quatf(angle: angle(s), axis: axis)   // about own local axis
                obj.keyframeTrack?.addKeyframe(TransformKeyframe(
                    time:        time(s),
                    translation: baseT,                  // keep current position
                    rotation:    simd_normalize(baseR * spin),
                    scale:       baseS,                  // keep current scale
                    opacity:     opacity))
            }
            onKeyframeStamped?(.object(i))
            print("[DEBUG] ViewportView: generateSpin — \(count) keyframes for object '\(obj.name)'"
                + " axis=\(axisIndex) revs=\(revolutions)")

        case .group(let gid):
            let parts = sceneManager.objects(inGroup: gid)
            guard !parts.isEmpty else { return }
            if sceneManager.groupKeyframeTracks[gid] == nil {
                sceneManager.groupKeyframeTracks[gid] = KeyframeTrack()
            }
            let track = sceneManager.groupKeyframeTracks[gid]
            track?.easingMode = .linear
            track?.keyframes.removeAll { $0.time >= lo && $0.time <= hi }

            // Spin the model about its own world centre.  The group track stores the
            // full groupTransform (rendered as groupT × part.transform); pre-multiplying
            // a pivot rotation about that centre keeps the model in place.
            let g0    = sceneManager.groupTransforms[gid] ?? matrix_identity_float4x4
            let pivot = groupCenter(parts)
            // Spin about the model's own axis = current group orientation × axis.
            let r0        = PathGenerator.decompose(g0).rotation
            let axisWorld = simd_act(r0, axis)
            var tFwd = matrix_identity_float4x4; tFwd.columns.3 = SIMD4<Float>( pivot, 1)
            var tInv = matrix_identity_float4x4; tInv.columns.3 = SIMD4<Float>(-pivot, 1)

            for k in 0..<count {
                let s   = Float(k) / Float(count - 1)
                let rot = rotationMatrix4x4(simd_quatf(angle: angle(s), axis: axisWorld))
                let (t, r, sc) = PathGenerator.decompose(tFwd * rot * tInv * g0)
                track?.addKeyframe(TransformKeyframe(
                    time: time(s), translation: t, rotation: r, scale: sc))
            }
            onKeyframeStamped?(.group(gid))
            print("[DEBUG] ViewportView: generateSpin — \(count) keyframes for model gid=\(gid)"
                + " axis=\(axisIndex) revs=\(revolutions)")

        default:
            return
        }
    }

    // MARK: - Add / Clear Atmosphere Keyframes

    /// Stamps a fog keyframe snapshotting the current static fog values at the
    /// playhead.  `objectWillChange.send()` refreshes the panel's count and marks
    /// the project dirty (the AppDelegate dirty sink observes fogSettings).
    func addFogKeyframeAtCurrentTime() {
        if fogSettings.keyframeTrack == nil { fogSettings.keyframeTrack = AtmosphereKeyframeTrack() }
        fogSettings.keyframeTrack?.addKeyframe(
            fogSettings.snapshot(at: timeline.currentTime),
            mergeTolerance: stampMergeTolerance)
        fogSettings.objectWillChange.send()
        print("[DEBUG] ViewportView: fog keyframe added at t="
            + String(format: "%.3f", timeline.currentTime))
        onKeyframeStamped?(.fog)
    }

    func clearFogKeyframes() {
        fogSettings.keyframeTrack = nil
        fogSettings.objectWillChange.send()
        print("[DEBUG] ViewportView: fog keyframes cleared")
    }

    func addParticleKeyframeAtCurrentTime(forEmitterAt index: Int) {
        guard particleManager.emitters.indices.contains(index) else { return }
        let fx = particleManager.emitters[index]
        if fx.keyframeTrack == nil { fx.keyframeTrack = AtmosphereKeyframeTrack() }
        fx.keyframeTrack?.addKeyframe(
            fx.snapshot(at: timeline.currentTime),
            mergeTolerance: stampMergeTolerance)
        fx.objectWillChange.send()
        print("[DEBUG] ViewportView: particle keyframe added at t="
            + String(format: "%.3f", timeline.currentTime) + " emitter=\(index)")
        onKeyframeStamped?(.particles(index))
    }

    func clearParticleKeyframes(at index: Int) {
        guard particleManager.emitters.indices.contains(index) else { return }
        particleManager.emitters[index].keyframeTrack = nil
        particleManager.emitters[index].objectWillChange.send()
        print("[DEBUG] ViewportView: particle keyframes cleared emitter=\(index)")
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
        camera.keyframeTrack?.addKeyframe(kf, mergeTolerance: stampMergeTolerance)

        let yawOffStr   = followYawOffset  .map { String(format: "%.4f", $0) } ?? "nil"
        let pitchOffStr = followPitchOffset.map { String(format: "%.4f", $0) } ?? "nil"
        print("[DEBUG] ViewportView: follow camera keyframe added at t="
            + String(format: "%.3f", timeline.currentTime)
            + " followTarget='\(obj.name)'"
            + " yaw=" + String(format: "%.4f", camera.yaw)
            + " followYawOffset=" + yawOffStr
            + " followPitchOffset=" + pitchOffStr
            + " distance=" + String(format: "%.4f", camera.distance))
        onKeyframeStamped?(.camera)
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
        camera.keyframeTrack?.addKeyframe(kf, mergeTolerance: stampMergeTolerance)

        let yawOffStr   = followYawOffset  .map { String(format: "%.4f", $0) } ?? "nil"
        let pitchOffStr = followPitchOffset.map { String(format: "%.4f", $0) } ?? "nil"
        print("[DEBUG] ViewportView: follow camera keyframe updated at t="
            + String(format: "%.3f", timeline.currentTime)
            + " followTarget='\(targetName)'"
            + " followYawOffset=" + yawOffStr
            + " followPitchOffset=" + pitchOffStr)
        onKeyframeStamped?(.camera)
    }

    /// Positions the camera on a sphere of `distance` around the followed
    /// object's bounding centre.  Azimuth and elevation are angles in degrees
    /// in the object's local frame — azimuth 0° = directly behind (+Z in glTF,
    /// since −Z is forward), +90° = right side, ±180° = in front of the face;
    /// elevation 0° = head height, +90° = directly above.  Live-preview for
    /// the Camera Inspector POV sliders.  Returns false if the named object
    /// can't be found in the scene.
    @discardableResult
    func positionCameraOnFollowSphere(followingObjectNamed name: String,
                                       distance: Float,
                                       azimuthDeg: Float,
                                       elevationDeg: Float) -> Bool {
        guard let anchor = sceneManager.worldOrbitAnchor(ofObjectNamed: name) else { return false }
        let psi = azimuthDeg   * .pi / 180
        let phi = elevationDeg * .pi / 180
        // Local outward radial: ψ rotates around +Y, φ tilts up.
        let localDir = SIMD3<Float>(sin(psi) * cos(phi),
                                    sin(phi),
                                    cos(psi) * cos(phi))
        let worldDir = anchor.basis * localDir
        // Camera looks AT the anchor, so forward = −worldDir.
        camera.target   = anchor.pos
        camera.distance = distance
        camera.yaw      = atan2(worldDir.x, worldDir.z)
        camera.pitch    = asin(max(-1, min(1, worldDir.y)))
        needsDisplay    = true
        return true
    }

    /// Stamps a POV-flavoured follow camera keyframe at the current playhead.
    /// First positions the camera on the sphere around `targetName`, then
    /// captures via the existing follow-stamp path with `followUpLocal =
    /// (0, 1, 0)` so playback rolls the camera with the followed object.
    func addPOVCameraKeyframeAtCurrentTime(followingObjectNamed targetName: String,
                                            distance: Float,
                                            azimuthDeg: Float,
                                            elevationDeg: Float) {
        guard positionCameraOnFollowSphere(followingObjectNamed: targetName,
                                            distance: distance,
                                            azimuthDeg: azimuthDeg,
                                            elevationDeg: elevationDeg) else {
            print("[DEBUG] ViewportView: addPOVCameraKeyframe — target '\(targetName)' not found")
            return
        }
        // Reuse the existing capture pipeline so all the local-frame conversion
        // math (targetOffset, followForwardLocal) stays in one place.  Then
        // patch the freshly-added keyframe to carry followUpLocal = (0, 1, 0).
        addFollowCameraKeyframeAtCurrentTime(followingObjectNamed: targetName)
        if let track = camera.keyframeTrack,
           let lastIdx = track.keyframes.indices.last {
            track.keyframes[lastIdx].followUpLocal = SIMD3<Float>(0, 1, 0)
            print("[DEBUG] ViewportView: tagged camera keyframe at t="
                + String(format: "%.3f", track.keyframes[lastIdx].time)
                + " with followUpLocal=(0,1,0) for POV roll-with-target")
        }
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

    /// Pulls the real rendering camera's live position/target into the Camera
    /// panel state (never the Director, even in Scene mode).  Driven by a 0.1s
    /// timer in CameraPanel while the panel is visible, so the read-only Position
    /// and editable Target track viewport moves.
    func refreshCameraPanelState() {
        // Skip the 10 Hz live-readout poll during playback: the camera may be
        // animating, and refreshing @Published panel fields every tick re-renders
        // the Camera panel and starves the render loop.  (Values resync when the
        // panel next polls after playback stops.)
        guard !timeline.isPlaying else { return }
        let fl = 12.0 / tan(camera.fovYRadians / 2)
        cameraPanelState.refresh(position:    camera.eyePosition,
                                 target:      camera.target,
                                 focalLength: fl)
    }

    // MARK: - Video Export

    func startExport(to url: URL, codec: ExportCodec, fps: ExportFrameRate,
                     exportState: ExportState, includeFX: Bool = true,
                     suppressGlass: Bool = false,
                     onCompletion: ((Error?) -> Void)? = nil) {
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
            fps:               fps,
            pipelineState:     pipeline,
            depthStencilState: depth,
            holdoutPipelineState: r.holdoutPipelineState,
            transparentPipelineState: r.transparentPipelineState,
            transparentDepthState:    r.transparentDepthState
        ) else {
            print("[DEBUG] ViewportView: startExport — VideoExporter init returned nil")
            return
        }

        exporter.colorMode          = renderSettings.colorMode
        exporter.isWireframe        = renderer?.isWireframe      ?? false
        exporter.showAxesGizmo      = renderSettings.showAxesGizmo
        exporter.marks              = probeConfig.marks
        exporter.marksVisible       = probeConfig.marksVisible
        exporter.feedbackSettings   = feedbackSettings
        exporter.colorGradeSettings = colorGradeSettings
        // FX (fog + weather particles) belong to the Background class: include them
        // only in passes that show Background (Full, Scene).  Solo/Matte passes pass
        // includeFX=false so the actor/macguffin matte stays clean.
        exporter.fogSettings        = includeFX ? fogSettings : nil
        exporter.particleManager    = includeFX ? particleManager : nil
        exporter.includeLaserFX     = includeFX
        exporter.suppressTransparent = suppressGlass
        exporter.ibl                = renderer?.ibl   // share IBL so exports match preview
        exporter.backgroundEquirect = renderer?.backgroundEquirect   // dedicated bg HDR (if any)
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
            onCompletion?(error)
        })
    }

    // MARK: - Export All (multi-pass cycle)

    private struct ExportPass {
        let name:    String          // used in the filename
        let visible: Set<ObjectClass>// shown; EVERY other class is hidden + holdout
        let matte:   Bool            // true → Black+White matte colour mode
        let blackBg: Bool            // true → solid-black background override
        let fx:      Bool            // true → render fog + particles + lasers
        var suppressGlass: Bool = false  // true → don't draw transparent (glass) objects
    }

    /// Runs the full multi-pass export cycle sequentially, writing
    /// `<projectName>.<NN>.<PassName>.mov` into `folder`.  Passes are chained on
    /// each export's completion (one VideoExporter run per pass).  `onAllComplete`
    /// fires once after the last pass, or on the first error.  The caller restores
    /// scene state afterward (by reloading the just-saved project).
    func startExportAll(folder: URL, projectName: String, cycleNumber: Int,
                        codec: ExportCodec, fps: ExportFrameRate,
                        exportState: ExportState,
                        onAllComplete: @escaping (Error?) -> Void) {
        let present = Set(sceneManager.objects.map { $0.objectClass })
        // FX present if any weather emitter is enabled or fog is on (lasers ride along).
        let fxPresent = particleManager.emitters.contains { $0.isEnabled }
                     || fogSettings.isEnabled
        var passes: [ExportPass] = [
            ExportPass(name: "Scene", visible: [.background, .actor, .macguffin],
                       matte: false, blackBg: false, fx: true)
        ]
        if present.contains(.actor) {
            passes.append(ExportPass(name: "Actor Solo",  visible: [.actor], matte: false, blackBg: true, fx: false))
            passes.append(ExportPass(name: "Actor Matte", visible: [.actor], matte: true,  blackBg: true, fx: false))
        }
        passes.append(ExportPass(name: "Background", visible: [.background], matte: false, blackBg: false, fx: false,
                                 suppressGlass: true))
        if present.contains(.macguffin) {
            passes.append(ExportPass(name: "MacGuffin Solo",  visible: [.macguffin], matte: false, blackBg: true, fx: false))
            passes.append(ExportPass(name: "MacGuffin Matte", visible: [.macguffin], matte: true,  blackBg: true, fx: false))
        }
        if fxPresent {
            // FX-only: all geometry held out, FX on, black background.
            passes.append(ExportPass(name: "FX Solo",  visible: [], matte: false, blackBg: true, fx: true))
            passes.append(ExportPass(name: "FX Matte", visible: [], matte: true,  blackBg: true, fx: true))
        }

        // Background fields to restore for the project-background passes (Full/Scene).
        let origMode  = backgroundConfig.mode
        let origSolid = backgroundConfig.solidColor
        let nn        = String(format: "%02d", cycleNumber)
        let total     = passes.count

        func runPass(_ i: Int) {
            guard i < passes.count else { onAllComplete(nil); return }
            let pass = passes[i]
            applyExportPass(pass, origMode: origMode, origSolid: origSolid)
            exportState.lastMessage = "Exporting pass \(i + 1)/\(total): \(pass.name)"
            let url = folder.appendingPathComponent("\(projectName).\(nn).\(pass.name).mov")
            startExport(to: url, codec: codec, fps: fps, exportState: exportState,
                        includeFX: pass.fx, suppressGlass: pass.suppressGlass) { error in
                if let error = error { onAllComplete(error); return }
                runPass(i + 1)   // startExport's completion is delivered on the main thread
            }
        }
        runPass(0)
    }

    /// Sets per-pass scene state: object visibility/holdout by class, colour mode,
    /// and background.  Classes not in `pass.visible` are hidden AND set to occlude
    /// (holdout), so they cut correct holes for compositing.
    private func applyExportPass(_ pass: ExportPass,
                                 origMode: BackgroundMode, origSolid: SIMD3<Float>) {
        for obj in sceneManager.objects {
            if pass.visible.contains(obj.objectClass) {
                obj.isVisible = true
            } else {
                obj.isVisible         = false
                obj.occludeWhenHidden = true
            }
        }
        renderSettings.colorMode = pass.matte ? .blackWhite : .color
        if pass.blackBg {
            backgroundConfig.mode       = .solid
            backgroundConfig.solidColor = SIMD3<Float>(0, 0, 0)
        } else {
            backgroundConfig.mode       = origMode
            backgroundConfig.solidColor = origSolid
        }
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

            let scale = viewCamera.distance * 0.001
            let move: SIMD3<Float>
            switch dragLockAxis {
            case .horizontal: move = viewCamera.rightVector * (dx * scale)
            case .vertical:   move = viewCamera.upVector   * (dy * scale)
            case .none:       return
            }
            obj.transform.columns.3.x += move.x
            obj.transform.columns.3.y += move.y
            obj.transform.columns.3.z += move.z
            clampObjectPosition(obj)
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

            let scale = viewCamera.distance * 0.001
            let move: SIMD3<Float>
            switch dragLockAxis {
            case .horizontal: move = viewCamera.rightVector * (dx * scale)
            case .vertical:   move = viewCamera.upVector   * (dy * scale)
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
                let scale = viewCamera.distance * 0.001
                let d = viewCamera.rightVector * (lockedDx * scale)
                      + viewCamera.upVector    * (lockedDy * scale)
                lightManager.translateSelected(by: d)
            default:
                break
            }

        } else if controlMode == .director {
            // Director POV: axis-locked pan of the viewpoint (Scene mode only).
            if dragLockAxis == .none {
                dragAccumX += dx
                dragAccumY += dy
                let dist = (dragAccumX * dragAccumX + dragAccumY * dragAccumY).squareRoot()
                guard dist >= dragLockThreshold else { return }
                dragLockAxis = abs(dragAccumX) >= abs(dragAccumY) ? .horizontal : .vertical
            }
            switch dragLockAxis {
            case .horizontal: director.pan(deltaX: -dx, deltaY: 0)
            case .vertical:   director.pan(deltaX: 0,  deltaY: dy)
            case .none:       return
            }

        } else {
            // Camera mode: axis-locked orbit around the fixed target (Target stays
            // put, only Position moves).  Scene mode keeps its own scene-camera pan.
            if dragLockAxis == .none {
                dragAccumX += dx
                dragAccumY += dy
                let dist = (dragAccumX * dragAccumX + dragAccumY * dragAccumY).squareRoot()
                guard dist >= dragLockThreshold else { return }
                dragLockAxis = abs(dragAccumX) >= abs(dragAccumY) ? .horizontal : .vertical
            }

            switch dragLockAxis {
            case .horizontal:
                if sceneModeActive { panSceneCameraInDirectorPlane(dx: dx, dy: 0) }
                else               { camera.orbit(deltaX: dx, deltaY: 0) }
            case .vertical:
                if sceneModeActive { panSceneCameraInDirectorPlane(dx: 0, dy: dy) }
                else               { camera.orbit(deltaX: 0, deltaY: dy) }
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
            // Horizontal drag yaws around the view's up vector; vertical drag
            // pitches around the view's right vector (viewCamera = Director in
            // Scene mode, scene camera otherwise).  Both apply in the same
            // frame so diagonal strokes rotate cleanly in any direction.
            guard !timeline.isPlaying,
                  let obj = sceneManager.selectedObject ?? sceneManager.primaryObject
            else { return }

            let hRot = rotationMatrix4x4(simd_quatf(angle:  dx * sensitivity,
                                                     axis: viewCamera.upVector))
            let vRot = rotationMatrix4x4(simd_quatf(angle: -dy * sensitivity,
                                                     axis: viewCamera.rightVector))
            let rot  = vRot * hRot   // horizontal applied first, vertical on top

            // Pivot in the part's LOCAL space: rigged parts (those with a parent)
            // pivot at the joint origin (0,0,0) so the whole sub-chain swings around
            // the joint — true FK posing, matching the keyboard.  Standalone objects
            // keep pivoting around their visual centre.
            let localPivot = obj.parentIndex != nil
                ? SIMD3<Float>(0, 0, 0)
                : (obj.boundingMin + obj.boundingMax) * 0.5
            let wc4   = obj.transform * SIMD4<Float>(localPivot, 1)
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

            let mc4    = obj.transform * SIMD4<Float>(localPivot, 0)
            let newPos = pivot - SIMD3<Float>(mc4.x, mc4.y, mc4.z)
            obj.transform.columns.3 = SIMD4<Float>(newPos.x, newPos.y, newPos.z, 1)
            syncLocalTransform(obj)

        case .model:
            // Free rotation of the whole group on both axes simultaneously.
            guard !timeline.isPlaying else { return }
            let parts = groupParts()
            guard !parts.isEmpty else { return }

            let hQuat = simd_quatf(angle:  dx * sensitivity, axis: viewCamera.upVector)
            let vQuat = simd_quatf(angle: -dy * sensitivity, axis: viewCamera.rightVector)
            let pivot = groupCenter(parts)
            rotateGroup(parts, by: vQuat * hQuat, around: pivot)

        case .light:
            // Right drag: rotate the selected light (azimuth + elevation).
            lightManager.rotateSelected(deltaAzimuth: -dx * sensitivity, deltaElevation: -dy * sensitivity)

        case .camera:
            // Right drag: free-look on both axes.
            camera.freeLook(deltaYaw: -dx * sensitivity, deltaPitch: dy * sensitivity)

        case .director:
            // Director POV (Scene mode only): free-look the viewpoint.
            director.freeLook(deltaYaw: -dx * sensitivity, deltaPitch: dy * sensitivity)
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
                    let move = delta * viewCamera.distance * 0.05
                    translateGroup(parts, by: viewCamera.forwardVector * move)
                }
                return
            }
        }

        // Director mode (Scene mode only): scroll wheel dollies the Director POV
        // in / out — the "get closer to the part" move.
        if controlMode == .director, !timeline.isPlaying {
            director.dolly(delta: delta)
            return
        }

        // Camera mode: scroll wheel dollies the rig (translates along forward).
        // Focal-length / FOV change is on the +/− keys instead.
        if controlMode == .camera, !timeline.isPlaying {
            // Scene mode: dolly the scene camera along the Director's forward axis
            // (into / out of the view you see); otherwise dolly its own rig.
            if sceneModeActive { dollySceneCameraAlongDirector(delta: delta) }
            else               { camera.dolly(delta: delta) }
            return
        }

        // Light mode: move the selected light toward / away from the scene
        // (along the camera's forward axis — "into / out of the screen").
        if controlMode == .light, !timeline.isPlaying {
            let move = delta * viewCamera.distance * 0.05
            lightManager.translateSelected(by: viewCamera.forwardVector * move)
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
            clampObjectPosition(obj)
            syncLocalTransform(obj)

        } else {
            // Plain scroll → translate along the view forward axis (depth push/pull)
            let move = delta * viewCamera.distance * 0.05
            let fwd  = viewCamera.forwardVector
            obj.transform.columns.3.x += fwd.x * move
            obj.transform.columns.3.y += fwd.y * move
            obj.transform.columns.3.z += fwd.z * move
            clampObjectPosition(obj)
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
        case .director:
            // The Director POV has no keyframe track.
            times = []
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

    // MARK: - Scene-camera moves relative to the Director (Scene mode)
    //
    // In Scene mode the user views through the Director, so positioning the
    // scene camera should follow the Director's POV rather than the scene
    // camera's own basis.  These slide the scene camera's `target` (which drags
    // the whole rig, since the eye is derived from target + yaw/pitch/distance).
    // Sensitivity uses the Director's distance so feel matches the view.

    private func panSceneCameraInDirectorPlane(dx: Float, dy: Float) {
        let s = director.distance * 0.001
        camera.target += director.rightVector * (dx * s)
        camera.target += director.upVector    * (dy * s)
    }

    private func dollySceneCameraAlongDirector(delta: Float) {
        camera.target += director.forwardVector * (delta * 0.05 * max(director.distance, 1.0))
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
        let right = viewCamera.rightVector
        let up    = viewCamera.upVector

        switch controlMode {
        case .camera:
            if shift {
                // Free-look (aim rotates).  Sign convention matches the previous
                // Shift+arrow behavior: dx>0 → free-look yaw +rotStep, dy>0 → +pitch.
                camera.freeLook(deltaYaw: dxF * rotStep, deltaPitch: dyF * rotStep)
            } else {
                // Plain arrow keys → orbit around the fixed target (Target stays put,
                // only Position moves).  Scene mode keeps its own scene-camera pan.
                if sceneModeActive {
                    panSceneCameraInDirectorPlane(dx: dxF * panStep, dy: dyF * panStep)
                } else {
                    camera.orbit(deltaX: dxF * orbitKeyStep, deltaY: dyF * orbitKeyStep)
                }
            }

        case .director:
            // Navigate the Director POV (Scene mode only).  Mirrors Camera mode
            // but operates on `director`: plain arrows pan, Shift+arrows aim.
            if shift {
                director.freeLook(deltaYaw: dxF * rotStep, deltaPitch: dyF * rotStep)
            } else {
                director.pan(deltaX: -dxF * panStep, deltaY: dyF * panStep)
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
                clampObjectPosition(obj)
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
        let fwd = viewCamera.forwardVector

        switch controlMode {
        case .camera:
            // +/− changes focal length (FOV). Scroll wheel handles dolly.
            camera.lensZoom(delta: sign * zoomStep / 0.05)

        case .director:
            // Director POV (Scene mode only): +/− changes the Director's FOV.
            director.lensZoom(delta: sign * zoomStep / 0.05)

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
                clampObjectPosition(obj)
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
        static let d:        UInt16 = 2    // Director mode (Scene mode only)
        static let k:        UInt16 = 40   // toggle probe marks visibility
        static let n:        UInt16 = 45   // cycle marks (Shift = previous)
        static let delete:   UInt16 = 51   // delete selected mark (gated)
        static let v:        UInt16 = 9    // toggle keyframe motion-path vectors
        // Number row 1–6 — Director standard views (Scene mode only)
        static let num1:     UInt16 = 18   // Front
        static let num2:     UInt16 = 19   // Left
        static let num3:     UInt16 = 20   // Rear
        static let num4:     UInt16 = 21   // Right
        static let num5:     UInt16 = 23   // Top
        static let num6:     UInt16 = 22   // Bottom
        static let num7:     UInt16 = 26   // Solo: hide others (Scene mode)
        static let num8:     UInt16 = 28   // Solo: occlude hidden others (Scene mode)
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
    private let orbitKeyStep:  Float = Float.pi / 36.0 / 0.005   // 5° per key (camera.orbit sensitivity = 0.005)
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
            case .director:
                break   // Director POV has no keyframes
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

        // ── Tab / Shift+Tab — next / previous visible keyframe ────────────────
        // When the Timeline Editor is open, share its "visible rows" navigation so
        // viewport and editor behave identically; otherwise fall back to the
        // active-track seek.
        if kc == KC.tab, !event.isARepeat {
            let backward = event.modifierFlags.contains(.shift)
            if let editor = timelineKeyTarget, editor.window?.isVisible == true {
                editor.seekAdjacentVisibleKeyframe(backward: backward)
            } else {
                seekToAdjacentKeyframe(backward: backward)
            }
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
                case .director:
                    break   // Director POV has no keyframes
                }
                return

            case KC.w:
                renderer?.isWireframe.toggle()
                print("[DEBUG] ViewportView: wireframe = " + String(renderer?.isWireframe ?? false))
                return

            case KC.g:
                // Cycle Greyscale → Color → Black+White.
                renderSettings.colorMode = renderSettings.colorMode.next
                return

            case KC.v:
                // Toggle the keyframe motion-path overlay for the selected entity.
                showMotionVectors.toggle()
                updateMotionVectorTarget()
                needsDisplay = true
                print("[DEBUG] ViewportView: motion vectors = " + String(showMotionVectors))
                return

            case KC.k:
                // K — show/hide all probe marks.
                onToggleMarks?()
                needsDisplay = true
                return

            case KC.n:
                // N — cycle to next mark (Shift+N = previous); recalls the probe to it.
                onCycleMark?(event.modifierFlags.contains(.shift) ? -1 : 1)
                needsDisplay = true
                return

            case KC.delete:
                // Delete — remove the selected mark (no-op unless marks shown + selected).
                onDeleteMark?()
                needsDisplay = true
                return

            case KC.c:
                // C — Camera mode.  In Scene mode it toggles between the scene
                // Camera and the Director POV (the second viewpoint that
                // exists only in Scene mode).  Outside Scene mode it just
                // sets Camera as before.  Director has no timeline lane, so
                // onControlModeChanged is not broadcast for that branch.
                if sceneModeActive && controlMode == .camera {
                    controlMode = .director
                    syncOverlayState()
                } else {
                    controlMode = .camera
                    syncOverlayState()
                    onControlModeChanged?(.camera)
                }
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
                // M — Model mode (move all parts of a group as one).  Like O, a
                // second press while already in Model mode cycles to the next model
                // (alphabetical, one entry per root object/group).
                if controlMode == .model {
                    sceneManager.cycleSelection()
                }
                controlMode = .model
                syncOverlayState()
                if let gid = sceneManager.selectedGroupID {
                    onControlModeChanged?(.group(gid))
                } else {
                    onControlModeChanged?(.object(sceneManager.selectedIndex))
                }
                return

            // D is intentionally not handled here — it's reserved for "delete
            // selected keyframe" in the Timeline Editor.  Director POV entry
            // moved to C (it toggles with Camera while Scene mode is active).

            // Number row 1–6: snap the Director to a standard view of the selection
            // (Scene mode only).  Outside Scene mode they fall through unconsumed.
            case KC.num1: if sceneModeActive { snapDirectorToObjectView(.front);  return }
            case KC.num2: if sceneModeActive { snapDirectorToObjectView(.left);   return }
            case KC.num3: if sceneModeActive { snapDirectorToObjectView(.rear);   return }
            case KC.num4: if sceneModeActive { snapDirectorToObjectView(.right);  return }
            case KC.num5: if sceneModeActive { snapDirectorToObjectView(.top);    return }
            case KC.num6: if sceneModeActive { snapDirectorToObjectView(.bottom); return }

            // 7 / 8: Scene-mode solo aids — hide / occlude everything except the
            // selected object's group.  Non-destructive; reset on leaving Scene mode.
            case KC.num7: if sceneModeActive { sceneSoloHideOthers.toggle();    syncOverlayState(); return }
            case KC.num8: if sceneModeActive { sceneSoloOccludeOthers.toggle(); syncOverlayState(); return }

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
                if sceneModeActive {
                    if !directorEverFit { autoFitDirector() }
                    // Auto-engage Director navigation — you usually reframe first.
                    controlMode = .director
                } else if controlMode == .director {
                    // Director mode is meaningless outside Scene mode — revert to
                    // Camera and restore the matching timeline-lane highlight.
                    controlMode = .camera
                    onControlModeChanged?(.camera)
                }
                if !sceneModeActive {
                    // Solo is a Scene-mode aid — clear it on exit so the real
                    // visibility / occlusion settings are shown again.
                    sceneSoloHideOthers    = false
                    sceneSoloOccludeOthers = false
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
