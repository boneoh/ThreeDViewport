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
    case probe    // move the bake Probe (mouse drag / arrow keys / wheel)

    var displayName: String {
        switch self {
        case .camera:   return "Camera"
        case .light:    return "Light"
        case .object:   return "Object"
        case .model:    return "Model"
        case .director: return "Director"
        case .probe:    return "Probe"
        }
    }
}

// MARK: - ViewportView

final class ViewportView: MTKView {

    // Owned scene objects
    let sceneManager:     SceneManager
    let camera:           CameraController
    /// All scene cameras (Phase 1).  The live `camera` controller above edits/renders the
    /// ACTIVE one; the others hold their state until activated.  Phase 1a: exactly one
    /// ("Camera 1"), identical to the single-camera app.
    var cameras:           [SceneCamera] = [SceneCamera(name: "Camera 1")]
    var activeCameraIndex: Int = 0
    /// Scheduled hard cuts (Phase 1c): which camera is the "program" over time during
    /// playback + export.  Empty = always the active camera (1b behavior).
    var cameraCuts:        [CameraCut] = []
    /// Director's-POV camera used in Scene mode (read-only view of the whole
    /// scene from a fly-cam position above and behind the recording camera).
    /// Independent state — never animated, never saved with the project.
    let director:         CameraController
    /// Program camera (the cut schedule's result) that the viewport displays while it
    /// follows the camera cuts.  Shared with the Renderer (which drives its pose each
    /// frame) so picking / drag use the same view as the display.  Independent of the
    /// live/active camera, which stays the edit camera — never overwritten by the program.
    let programCamera:    CameraController
    let lightManager:     LightManager
    let backgroundConfig: BackgroundConfig
    let timeline:         Timeline

    /// True while Scene mode is active.  The Renderer mirrors this flag so its
    /// `viewCamera` swap kicks in.  When false, behaviour is unchanged.
    var sceneModeActive: Bool = false {
        didSet {
            guard oldValue != sceneModeActive else { return }
            renderer?.sceneModeActive = sceneModeActive
            // Scene mode changes which camera applyAnimation drives (program vs the live
            // camera whose frustum is drawn), so force a re-evaluation even though the
            // playhead hasn't moved — otherwise the frustum shows a stale pose until the
            // next scrub.
            renderer?.invalidateAnimationCache()
            needsDisplay = true
        }
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
    // The camera the viewport is displaying: Director in Scene mode; the program camera
    // while cuts follow the playhead (so picking / drag align with what's on screen — the
    // Renderer keeps programCamera's pose current each frame); else the live/active camera.
    private var viewCamera: CameraController {
        if sceneModeActive { return director }
        return cameraCuts.isEmpty ? camera : programCamera
    }

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
    // Curve Path Animator helper state.
    let curvePathState     = CurvePathAnimatorState()
    // Spin Animator helper state.
    let spinAnimatorState  = SpinAnimatorState()
    // Gait (walk) Animator helper state.
    let gaitState          = GaitAnimatorState()

    // Rate-marker schedules (Spin / Orbit animators).  These are the editable source of
    // truth; the dense pose keyframes are regenerated from them.  Keyed by ScheduleKey
    // (identity refactor P3): stable entity id for objects/lights/cameras, gid for groups
    // — so deleting/reordering objects no longer needs index remapping.  Access via
    // spinSchedule(for:)/orbitSchedule(for:)/setSpinSchedule/setOrbitSchedule.
    var spinRateSchedules:  [ScheduleKey: [SpinRateMarker]]   = [:]
    var orbitRateSchedules: [ScheduleKey: OrbitRateSchedule]  = [:]

    /// Maps a Timeline TrackRef to the stable schedule key (nil for ref types that can't
    /// own a rate schedule, or an out-of-range index).
    func scheduleKey(for ref: TrackRef) -> ScheduleKey? {
        switch ref {
        case .object(let i): return sceneManager.objects.indices.contains(i) ? .entity(sceneManager.objects[i].entityID) : nil
        case .light(let i):  return lightManager.lights.indices.contains(i)  ? .entity(lightManager.lights[i].entityID)  : nil
        case .camera(let i): return cameras.indices.contains(i)              ? .entity(cameras[i].entityID)              : nil
        case .group(let gid): return .group(gid)
        default:             return nil
        }
    }

    func spinSchedule(for ref: TrackRef)  -> [SpinRateMarker]?  { scheduleKey(for: ref).flatMap { spinRateSchedules[$0] } }
    func orbitSchedule(for ref: TrackRef) -> OrbitRateSchedule? { scheduleKey(for: ref).flatMap { orbitRateSchedules[$0] } }
    /// True when `ref` has a spin OR orbit schedule (rate-driven track).
    func hasRateSchedule(for ref: TrackRef) -> Bool {
        guard let k = scheduleKey(for: ref) else { return false }
        return spinRateSchedules[k] != nil || orbitRateSchedules[k] != nil
    }

    private var playbackCancellable: AnyCancellable?

    // Phase 6: HUD observable state — AppDelegate embeds the SwiftUI overlay using this.
    let overlayState = SceneOverlayState()

    // Active control mode: camera / light / object.
    // Writing updates the HUD automatically.
    /// True while the 'V' keyframe motion-path overlay is on.  The actual path
    /// (camera / light / object) follows the current controlMode + selection.
    private var showMotionVectors = false

    // Timeline edit locks for the singleton tracks.  Objects / lights / emitters carry
    // their own `isLocked`; these cover Camera and Fog.  See isLocked(_:) / setLocked.
    var cameraLocked = false
    var fogLocked    = false

    private(set) var controlMode: ControlMode = .camera {
        didSet {
            overlayState.controlMode = controlMode
            updateMotionVectorTarget()   // overlay tracks the active entity
            print("[DEBUG] ViewportView: controlMode = " + controlMode.displayName)
        }
    }

    /// While editing a Position Mark in Probe mode, whether the Probe drives the
    /// mark's secondary "target" point (camera aim / light aim) instead of its
    /// primary position.  Toggled with T; reset to the primary point whenever a
    /// different mark is selected (cycleMark / goToMark / displayMark).
    var editingMarkTargetPoint = false

    /// The Position Mark the Probe is currently editing: the selected mark, but
    /// only while in Probe mode with marks visible.  nil = the Probe edits only
    /// itself (HDR bake / import placement).
    private var editingMarkIndex: Int? {
        guard controlMode == .probe, probeConfig.marksVisible,
              let i = probeConfig.selectedMarkIndex,
              probeConfig.marks.indices.contains(i) else { return nil }
        return i
    }

    /// Maps the on/off flag + controlMode to the renderer's motion-vector target.
    private func updateMotionVectorTarget() {
        guard showMotionVectors else { renderer?.motionVectorTarget = .none; return }
        switch controlMode {
        case .camera, .director, .probe: renderer?.motionVectorTarget = .camera
        case .light:                     renderer?.motionVectorTarget = .light
        case .object, .model:            renderer?.motionVectorTarget = .object
        }
    }

    /// Whether the 'V' keyframe motion-path overlay is currently on (View menu read).
    var motionVectorsVisible: Bool { showMotionVectors }

    /// Toggles the motion-path overlay — the View menu's "Vector Path" item, mirroring
    /// the V key.
    func toggleMotionVectors() {
        showMotionVectors.toggle()
        updateMotionVectorTarget()
        needsDisplay = true
        print("[DEBUG] ViewportView: motion vectors = " + String(showMotionVectors))
    }

    // Input state
    private var lastMouseLocation: NSPoint = .zero
    private var isSpaceDown: Bool = false

    // Click-to-select: a left mouse-down that doesn't drag past a small threshold is
    // treated as a click and picks the object under the cursor on mouse-up.
    private var leftMouseDownLocation: NSPoint = .zero
    private var leftMouseDragged:      Bool    = false
    private var rightDragMoved:        Bool    = false   // a right-drag rotation happened
    private let clickMoveThreshold:    CGFloat = 3   // points of motion before it's a drag

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

    /// Fires when the Probe is moved in Probe mode (drag / arrows / wheel).
    /// AppDelegate wires this to mark the document dirty (probe position is saved).
    var onProbeEdited: (() -> Void)?

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
        director.debugName = "Director POV"   // names it in the [LIMIT] diagnostics
        director.clampsTargetToBounds = false // editor free-view roams past ±positionBound
        programCamera    = CameraController()
        programCamera.debugName = "Program (cuts)"
        programCamera.clampsTargetToBounds = false // pose is set from the program each frame
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
            programCamera:    programCamera,
            lightManager:     lightManager,
            backgroundConfig: backgroundConfig,
            timeline:         timeline
        )

        if renderer == nil {
            print("[DEBUG] ViewportView: Renderer init returned nil")
        }

        delegate = renderer

        // Render the program camera the cut schedule selects — while SCRUBBING/paused AND
        // during playback, so the viewport always shows the "current" (program) camera and
        // switches at each cut.  Drives the shared `programCamera` in the Renderer; the live
        // `camera` is never touched (that corrupts saves).  Empty cuts → nil → live camera.
        renderer?.programCameraProvider = { [weak self] t in
            guard let self, !self.cameraCuts.isEmpty else { return nil }
            return self.cameras[self.programCameraIndex(at: t)]
        }

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
            // fovY = 2·atan(12/fl); clamp to the lens-zoom range (10°–90°).
            let raw = 2 * atan(12.0 / max(fl, 1))
            self.camera.fovYRadians = max(SceneLimits.fovMinRadians,
                                          min(SceneLimits.fovMaxRadians, raw))
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
        // Camera slider edit → auto-keyframe-on-edit (gated by its settings).
        cameraPanelState.onSliderEdited = { [weak self] in
            guard let self else { return }
            self.autoKeyframeOnEdit(.camera(self.activeCameraIndex))
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
        // ── Camera management (Phase 1b): select active / add / delete / capture ──
        cameraPanelState.onSelectCamera = { [weak self] i in
            guard let self else { return }
            self.activateCamera(i)
            // Enter Camera mode so the HUD shows the camera + name and the matching
            // Timeline lane highlights (fires onControlModeChanged → selectTrack).
            self.setControlMode(.camera)
            self.syncCameraListToPanel()
            self.refreshCameraPanelState()   // show the newly-active camera's pose
            self.needsDisplay = true
            self.onCameraEdited?()
        }
        cameraPanelState.onAddCamera = { [weak self] in
            guard let self else { return }
            self.addCamera()
            self.syncCameraListToPanel()
            self.needsDisplay = true
            self.onCameraEdited?()
        }
        cameraPanelState.onDeleteCamera = { [weak self] in
            guard let self else { return }
            self.deleteCamera(at: self.activeCameraIndex)
            self.syncCameraListToPanel()
            self.refreshCameraPanelState()
            self.needsDisplay = true
            self.onCameraEdited?()
        }
        cameraPanelState.onCaptureDirector = { [weak self] in
            guard let self else { return }
            self.setActiveCameraToDirector()
            self.refreshCameraPanelState()
            self.needsDisplay = true
            self.onCameraEdited?()
        }
        cameraPanelState.onAddCut = { [weak self] in
            guard let self else { return }
            self.captureActiveCamera()
            self.addCameraCut(at: self.timeline.currentTime, cameraIndex: self.activeCameraIndex)
            self.syncCameraListToPanel()
            self.onCameraEdited?()
        }
        cameraPanelState.onDeleteCut = { [weak self] id in
            guard let self else { return }
            self.deleteCameraCut(id: id)
            self.syncCameraListToPanel()
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

        // On play: reset feedback + snapshot the edit camera (cuts take over the live
        // camera during playback).  On pause: restore the edit camera so authoring
        // continues on the selected camera (Phase 1c).
        playbackCancellable = timeline.$isPlaying
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] playing in
                guard let self else { return }
                if playing {
                    self.feedbackProcessor.reset()
                    self.captureActiveCamera()
                } else {
                    self.loadCameraIntoController(self.activeCameraIndex)
                }
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
        cameras           = [SceneCamera(name: "Camera 1")]   // Phase 1: reset camera list
        activeCameraIndex = 0
        cameraCuts        = []
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
            // Name a single-mesh model after its file; multi-part models keep each
            // part's real glTF node name (the group header already shows the file).
            if objects.count == 1 { objects.first?.name = baseName }

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

    /// Outcome of an add-model attempt (load failure already surfaces its own alert).
    enum AddModelResult { case added, failed }

    // Phase 6: Adds a model to the existing scene without clearing it.
    // The camera is left where it is — Open Model never moves the view.
    //
    // The SAME file may be loaded more than once (e.g. repeated character parts);
    // group animation / base transforms are keyed by (filename, occurrence) so the
    // instances stay distinct on save/load.  Returns `.failed` if the device is nil
    // or the file won't load.
    @discardableResult
    func addModelToScene(url: URL, placeAtProbe: Bool = true) -> AddModelResult {
        guard let dev = device else {
            print("[DEBUG] ViewportView: addModelToScene — device is nil")
            return .failed
        }

        print("[DEBUG] ViewportView: addModelToScene start — " + url.lastPathComponent)

        let loader = GLTFLoader(device: dev)

        if let objects = loader.load(url: url) {
            let (loadedCenter, _) = autoNormalize(objects)

            // Place the new model at the bake Probe: shift so its visual (bounding-box)
            // center lands on the probe.  Children follow via the hierarchy; baseTransform
            // is captured just below, so it picks up the shift too.
            let delta = probeConfig.position - loadedCenter
            if placeAtProbe, simd_length(delta) > 1e-6 {
                let d4 = SIMD4<Float>(delta.x, delta.y, delta.z, 0)
                for obj in objects where obj.parentIndex == nil {
                    obj.transform.columns.3      += d4
                    obj.localTransform.columns.3 += d4
                }
            }

            let baseName = url.deletingPathExtension().lastPathComponent
            let gid = objects.count > 1 ? sceneManager.makeGroupID() : nil
            for obj in objects {
                // For hierarchical parts (parentIndex != nil), baseTransform is the
                // base LOCAL transform; for roots it is the world transform (as before).
                obj.baseTransform = (obj.parentIndex != nil) ? obj.localTransform : obj.transform
                obj.sourceURL     = url
                obj.groupID       = gid
            }
            // Name a single-mesh model after its file; multi-part models keep each
            // part's real glTF node name (the group header already shows the file).
            if objects.count == 1 { objects.first?.name = baseName }

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

            // Switch to a mode that manipulates the new model as the user expects:
            // a multi-part model → Model mode (the whole model moves as one); a
            // single-mesh object → Object mode.
            setControlMode(gid != nil ? .model : .object)

            print("[DEBUG] ViewportView: addModelToScene complete — total objects=\(sceneManager.objects.count) groupID=\(gid.map { String($0) } ?? "none")")
            return .added
        } else {
            let filename = url.lastPathComponent
            let reason   = loader.lastError ?? "The file could not be read."
            print("[DEBUG] ViewportView: GLTFLoader returned nil for " + filename)
            showLoadError(filename: filename, reason: reason)
            return .failed
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
    /// `.director` / `.probe` (neither is a timeline track).
    var currentTrackRef: TrackRef? {
        switch controlMode {
        case .camera: return .camera(activeCameraIndex)
        case .object: return .object(sceneManager.selectedIndex)
        case .light:  return .light(lightManager.selectedIndex)
        case .model:
            // The group header lane when the selection belongs to a group.
            if let gid = sceneManager.selectedGroupID { return .group(gid) }
            return .object(sceneManager.selectedIndex)
        case .director, .probe:
            return nil
        }
    }

    func setControlMode(_ mode: ControlMode) {
        controlMode = mode
        syncOverlayState()
        if let ref = currentTrackRef { onControlModeChanged?(ref) }
    }

    // MARK: - Timeline edit locks

    /// Whether the given Timeline track is locked against edits.  A model (group) is
    /// locked when its parts are locked (set together via the model header).
    func isLocked(_ ref: TrackRef) -> Bool {
        switch ref {
        case .camera(let i):
            // The active camera's lock lives in cameraLocked; others in their slot.
            if i == activeCameraIndex { return cameraLocked }
            return cameras.indices.contains(i) ? cameras[i].isLocked : false
        case .cameraCuts: return false
        case .fog:    return fogLocked
        case .light(let i):
            return i >= 0 && i < lightManager.lights.count && lightManager.lights[i].isLocked
        case .particles(let i):
            guard i >= 0, i < particleManager.emitters.count else { return false }
            return particleManager.emitters[i].isLocked
        case .object(let i):
            return i >= 0 && i < sceneManager.objects.count && sceneManager.objects[i].isLocked
        case .group(let gid):
            // "Model Position" (root-path) track — its own independent lock, so freeing a
            // part doesn't expose the whole-model motion to Model-mode moves.
            return sceneManager.groupTrackLocked[gid] ?? false
        case .model(let gid):
            // Model header reads as locked only when the root path AND every part are locked.
            let members = sceneManager.objects.filter { $0.groupID == gid }
            return (sceneManager.groupTrackLocked[gid] ?? false)
                && !members.isEmpty && members.allSatisfy { $0.isLocked }
        case .importBundle: return false
        case .mark: return probeConfig.isLocked   // marks edit-lock follows the probe
        case .category(let cat):
            // A category header reads as locked only when EVERY lane under it is locked.
            switch cat {
            case .cameras: return cameras.indices.allSatisfy { isLocked(.camera($0)) }
            case .lights:
                let ls = lightManager.lights
                return !ls.isEmpty && ls.allSatisfy { $0.isLocked }
            case .effects:
                let es = particleManager.emitters
                return fogLocked && es.allSatisfy { $0.isLocked }
            case .marks: return probeConfig.isLocked
            }
        }
    }

    /// Sets the lock state for a Timeline track.  A model header cascades to all parts.
    func setLocked(_ ref: TrackRef, _ locked: Bool) {
        switch ref {
        case .camera(let i):
            if i == activeCameraIndex { cameraLocked = locked }
            if cameras.indices.contains(i) { cameras[i].isLocked = locked }
        case .cameraCuts: break
        case .fog:    fogLocked = locked
        case .light(let i):
            if i >= 0, i < lightManager.lights.count { lightManager.lights[i].isLocked = locked }
        case .particles(let i):
            if i >= 0, i < particleManager.emitters.count { particleManager.emitters[i].isLocked = locked }
        case .object(let i):
            guard i >= 0, i < sceneManager.objects.count else { break }
            sceneManager.objects[i].isLocked = locked
            // Locking a parent cascades DOWN to every child/grandchild (and the members of
            // any glued group parented to it); unlocking affects ONLY this object, so a
            // single part can be freed without unlocking the whole rig.
            if locked {
                for j in objectDescendants(of: i) { sceneManager.objects[j].isLocked = true }
                for (gid, link) in sceneManager.groupEnvelopeParent where link.env == i {
                    for obj in sceneManager.objects where obj.groupID == gid { obj.isLocked = true }
                }
            }
        case .group(let gid):
            // "Model Position" (root-path) track — only its own lock; parts unaffected.
            sceneManager.groupTrackLocked[gid] = locked
        case .model(let gid):
            // Whole model — root path AND every part.
            sceneManager.groupTrackLocked[gid] = locked
            for obj in sceneManager.objects where obj.groupID == gid { obj.isLocked = locked }
        case .importBundle: break
        case .mark: probeConfig.isLocked = locked   // marks edit-lock follows the probe
        case .category(let cat):
            // A category header cascades its lock to every lane it groups.
            switch cat {
            case .cameras:
                for i in cameras.indices { setLocked(.camera(i), locked) }
            case .lights:
                for i in lightManager.lights.indices { lightManager.lights[i].isLocked = locked }
            case .effects:
                fogLocked = locked
                particleManager.emitters.forEach { $0.isLocked = locked }
            case .marks:
                probeConfig.isLocked = locked
            }
        }
    }

    /// All objects whose `parentIndex` chain leads back to `i` (children, grandchildren, …).
    private func objectDescendants(of i: Int) -> [Int] {
        let objs = sceneManager.objects
        var result: [Int] = []
        for j in objs.indices where j != i {
            var p = objs[j].parentIndex
            while let pp = p, pp >= 0, pp < objs.count {
                if pp == i { result.append(j); break }
                p = objs[pp].parentIndex
            }
        }
        return result
    }

    /// Locks or unlocks every track (Lock All / Unlock All).
    func setAllLocked(_ locked: Bool) {
        cameraLocked = locked
        fogLocked    = locked
        for i in lightManager.lights.indices { lightManager.lights[i].isLocked = locked }
        particleManager.emitters.forEach { $0.isLocked = locked }
        sceneManager.objects.forEach { $0.isLocked = locked }
        // Root-path ("Model Position") tracks for every multi-part model.
        for gid in Set(sceneManager.objects.compactMap { $0.groupID }) {
            sceneManager.groupTrackLocked[gid] = locked
        }
    }

    // MARK: - Cameras (Phase 1)

    /// Copies the live camera controller's pose + track into the active camera slot.
    /// Call before saving or switching cameras so the slot reflects current edits.
    func captureActiveCamera() {
        guard cameras.indices.contains(activeCameraIndex) else { return }
        let s = cameras[activeCameraIndex]
        s.yaw           = camera.yaw
        s.pitch         = camera.pitch
        s.distance      = camera.distance
        s.target        = camera.target
        s.fovYRadians   = camera.fovYRadians
        s.keyframeTrack = camera.keyframeTrack
        s.isLocked      = cameraLocked
    }

    /// Loads camera slot `i` into the live controller (no capture of the current one).
    private func loadCameraIntoController(_ i: Int) {
        guard cameras.indices.contains(i) else { return }
        let s = cameras[i]
        camera.yaw           = s.yaw
        camera.pitch         = s.pitch
        camera.distance      = s.distance
        camera.target        = s.target
        camera.fovYRadians   = s.fovYRadians
        camera.keyframeTrack = s.keyframeTrack
        camera.debugName     = s.name           // names the active camera in [LIMIT] diagnostics
        cameraLocked         = s.isLocked
    }

    /// Makes camera `i` the active one: stashes the current live state into its slot,
    /// then loads slot `i` into the live controller.
    func activateCamera(_ i: Int) {
        guard cameras.indices.contains(i), i != activeCameraIndex else {
            if cameras.indices.contains(i) { loadCameraIntoController(i) }   // re-sync same index
            return
        }
        captureActiveCamera()
        activeCameraIndex = i
        loadCameraIntoController(i)
    }

    /// Reloads the live controller from the active camera slot (e.g. after its pose/track
    /// was replaced in place by an import).
    func reloadActiveCameraFromSlot() { loadCameraIntoController(activeCameraIndex) }

    /// Adds a new camera starting from the current view, and makes it active.
    func addCamera() {
        captureActiveCamera()
        let cam = SceneCamera(name: uniqueCameraName(),
                              yaw: camera.yaw, pitch: camera.pitch, distance: camera.distance,
                              target: camera.target, fovYRadians: camera.fovYRadians)
        cameras.append(cam)
        activeCameraIndex = cameras.count - 1
        loadCameraIntoController(activeCameraIndex)   // same pose → no view jump
    }

    /// Deletes camera `i` (never the last one).  If the active camera is removed, the
    /// nearest remaining one becomes active.  Cuts pointing at it are dropped; higher
    /// camera indices shift down.
    func deleteCamera(at i: Int) {
        guard cameras.count > 1, cameras.indices.contains(i) else { return }
        let wasActive = (i == activeCameraIndex)
        let deletedID = cameras[i].entityID
        cameras.remove(at: i)
        pruneOrphanMarks()
        // Cuts reference the camera by stable id (P4) — just drop the deleted camera's
        // cuts; the rest stay valid with no index remapping.
        cameraCuts.removeAll { $0.cameraID == deletedID }
        if wasActive {
            activeCameraIndex = min(i, cameras.count - 1)
            loadCameraIntoController(activeCameraIndex)
        } else if i < activeCameraIndex {
            activeCameraIndex -= 1
        }
    }

    // MARK: - Camera cuts (Phase 1c)

    /// Index of the camera with the given stable id, or nil if it no longer exists.
    func cameraIndex(forID id: UUID) -> Int? { cameras.firstIndex { $0.entityID == id } }

    /// The camera index the cut schedule selects at time `t` (the "program" camera).
    /// Empty cuts → the active camera.  Cuts key by camera id (P4), resolved to an index.
    func programCameraIndex(at t: Double) -> Int {
        guard !cameraCuts.isEmpty else { return activeCameraIndex }
        let sorted = cameraCuts.sorted { $0.time < $1.time }
        var id = sorted[0].cameraID                           // before the first cut, hold it
        for c in sorted where c.time <= t + 1e-9 { id = c.cameraID }
        return cameraIndex(forID: id) ?? activeCameraIndex
    }

    /// Adds (or replaces) a cut at `time` to camera `i`, keeping the list time-sorted.
    func addCameraCut(at time: Double, cameraIndex i: Int) {
        guard cameras.indices.contains(i) else { return }
        cameraCuts.removeAll { abs($0.time - time) < 1e-4 }
        cameraCuts.append(CameraCut(time: time, cameraID: cameras[i].entityID))
        cameraCuts.sort { $0.time < $1.time }
    }

    func deleteCameraCut(id: UUID) { cameraCuts.removeAll { $0.id == id } }

    /// Retimes a cut (keeps the list sorted).
    func moveCameraCut(id: UUID, to time: Double) {
        guard let i = cameraCuts.firstIndex(where: { $0.id == id }) else { return }
        cameraCuts[i].time = max(0, time)
        cameraCuts.sort { $0.time < $1.time }
    }

    /// Reassigns which camera a cut switches to.
    func setCameraCut(id: UUID, cameraIndex: Int) {
        guard cameras.indices.contains(cameraIndex),
              let i = cameraCuts.firstIndex(where: { $0.id == id }) else { return }
        cameraCuts[i].cameraID = cameras[cameraIndex].entityID
    }

    /// Sets the active camera's framing to the Director free-view's current pose.
    func setActiveCameraToDirector() {
        camera.yaw         = director.yaw
        camera.pitch       = director.pitch
        camera.distance    = director.distance
        camera.target      = director.target
        camera.fovYRadians = director.fovYRadians
        captureActiveCamera()
    }

    /// "Camera N" not already in use.
    private func uniqueCameraName() -> String {
        let used = Set(cameras.map { $0.name })
        var n = cameras.count + 1
        while used.contains("Camera \(n)") { n += 1 }
        return "Camera \(n)"
    }

    /// Pushes the camera list + active index into the Camera panel (cheap, guarded).
    func syncCameraListToPanel() {
        let names = cameras.map { $0.name }
        if cameraPanelState.cameraNames != names { cameraPanelState.cameraNames = names }
        if cameraPanelState.activeCameraIndex != activeCameraIndex {
            cameraPanelState.activeCameraIndex = activeCameraIndex
        }
        let rows = cameraCuts.sorted { $0.time < $1.time }.map { c in
            CameraPanelState.CutRow(
                id: c.id, time: c.time,
                cameraName: cameras.first { $0.entityID == c.cameraID }?.name ?? "—")
        }
        if cameraPanelState.cuts != rows { cameraPanelState.cuts = rows }
    }

    /// True when the active edit target (current control mode) is a locked track —
    /// used to block viewport edits.  Director / Probe have no track and are never locked.
    var activeTrackIsLocked: Bool {
        guard controlMode != .director, controlMode != .probe,
              let ref = currentTrackRef else { return false }
        return isLocked(ref)
    }

    /// Gentle audible reminder when an edit is blocked because the track is locked.
    /// Throttled so a drag (many frames/sec) or a held arrow key (auto-repeat) makes
    /// one beep, not a stream.
    private var lastLockBeepTime: TimeInterval = 0
    private func beepLocked() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastLockBeepTime > 0.6 {
            NSSound.beep()
            lastLockBeepTime = now
        }
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
            overlayState.selectedItemName = cameras.indices.contains(activeCameraIndex)
                ? cameras[activeCameraIndex].name : ""
        case .object:
            let idx = sceneManager.selectedIndex
            if idx < sceneManager.objects.count {
                let o = sceneManager.objects[idx]
                // An isolated model part reads "model ▸ part" so it's clear which part
                // of which model is selected; everything else uses its display name.
                if let gid = o.groupID {
                    overlayState.selectedItemName =
                        "\(sceneManager.groupName(for: gid)) ▸ \(sceneManager.partName(for: o))"
                } else {
                    overlayState.selectedItemName = sceneManager.displayName(for: o)
                }
            } else {
                overlayState.selectedItemName = ""
            }
        case .light:
            let li = lightManager.selectedIndex
            if li < lightManager.lights.count {
                let l = lightManager.lights[li]
                overlayState.selectedItemName = (l.customName?.isEmpty == false)
                    ? l.customName!
                    : "Light \(li + 1) - \(l.type.displayName)"
            } else {
                overlayState.selectedItemName = ""
            }
        case .model:
            // Show the model's timeline name (with any duplicate-instance suffix).
            if let gid = sceneManager.selectedGroupID {
                overlayState.selectedItemName = sceneManager.groupName(for: gid)
            } else if let obj = sceneManager.selectedObject {
                overlayState.selectedItemName = sceneManager.displayName(for: obj)
            } else {
                overlayState.selectedItemName = ""
            }
        case .director:
            overlayState.selectedItemName = "POV"
        case .probe:
            if let i = editingMarkIndex {
                let m  = probeConfig.marks[i]
                let pt = m.secondaryPosition != nil
                    ? (editingMarkTargetPoint ? " — Target" : " — Eye") : ""
                overlayState.selectedItemName = "Probe → Mark: \(m.name)\(pt)"
            } else {
                overlayState.selectedItemName = "Probe"
            }
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
                           SIMD3<Float>(repeating: -SceneLimits.positionBound),
                           SIMD3<Float>(repeating:  SceneLimits.positionBound))
        if c.x != p.x || c.y != p.y || c.z != p.z { LimitReporter.report("Object position") }
        obj.transform.columns.3 = SIMD4<Float>(c.x, c.y, c.z, p.w)
    }

    /// True if every axis of `p` is within ±positionBound (tiny tolerance so a
    /// ray-clamped dolly that lands exactly on the wall isn't rejected by FP rounding).
    private func withinPositionBound(_ p: SIMD3<Float>) -> Bool {
        let b = SceneLimits.positionBound + 1e-3
        return abs(p.x) <= b && abs(p.y) <= b && abs(p.z) <= b
    }

    /// All-or-nothing object translate: applies `delta` only if EVERY axis stays in
    /// range — so an out-of-range axis can't slide the object along the boundary (the
    /// jolting "jump" a per-axis clamp produces).  Beeps + logs and leaves the object
    /// put when refused.  Used by every viewport translate (drag / arrow / depth / scroll).
    private func translateObject(_ obj: SceneObject, by delta: SIMD3<Float>) {
        let p = obj.transform.columns.3
        let n = SIMD3<Float>(p.x + delta.x, p.y + delta.y, p.z + delta.z)
        guard withinPositionBound(n) else { LimitReporter.report("Object position"); return }
        obj.transform.columns.3 = SIMD4<Float>(n.x, n.y, n.z, p.w)
    }

    /// Moves the bake Probe by a world-space delta (Probe mode), clamped to the
    /// Probe inspector's ±100 range, and flags the project dirty (the probe position
    /// is persisted).  Movement is camera-relative at the call sites, so it follows
    /// the scene camera in normal view and the Director POV in Scene mode.
    private func moveProbe(by delta: SIMD3<Float>) {
        if probeConfig.isLocked { beepLocked(); return }   // locked probe — no viewport move
        let editingMark = editingMarkIndex
        let n = probeConfig.position + delta
        // Marks (esp. camera/light eyes) routinely live outside the Probe's ±100
        // range, so when editing a mark we bypass the bound — the same exemption
        // as the Director POV.  The SceneLimits ranges themselves are untouched.
        if editingMark == nil, !withinPositionBound(n) {
            LimitReporter.report("Probe position"); return
        }
        probeConfig.position = n
        if let i = editingMark {
            if editingMarkTargetPoint { probeConfig.marks[i].secondaryPosition = n }
            else                      { probeConfig.marks[i].position = n }
        }
        onProbeEdited?()
    }

    /// World-space origin of an object (folds in its group transform if grouped), for
    /// aiming the eye→target depth ray.
    private func objectWorldOrigin(_ obj: SceneObject) -> SIMD3<Float> {
        let w: matrix_float4x4
        if let gid = obj.groupID, let gt = sceneManager.groupTransforms[gid] { w = gt * obj.transform }
        else { w = obj.transform }
        return SIMD3<Float>(w.columns.3.x, w.columns.3.y, w.columns.3.z)
    }

    /// World-space origin of the currently selected object (folding its group transform),
    /// or nil if nothing is selected.  Used by the Model Inspector's "Add Mark".
    func selectedObjectWorldPosition() -> SIMD3<Float>? {
        sceneManager.selectedObject.map { objectWorldOrigin($0) }
    }

    /// World-space delta for a depth dolly of a target at world `p` by `move` (signed)
    /// along the eye→target ray — clamped so the target can't reach the eye (a NEAR
    /// limit; crossing it flips behind the camera and "jumps") nor run past the ±100
    /// world box (a FAR limit computed ALONG the ray, so it stops on the boundary
    /// instead of deviating per-axis the way a coordinate-wise clamp does).
    private func dollyDelta(towardWorld p: SIMD3<Float>, by move: Float) -> SIMD3<Float> {
        let eye  = viewCamera.eyePosition
        let toP  = p - eye
        let dist = simd_length(toP)
        guard dist > 1e-4 else { return .zero }
        let dir  = toP / dist

        // Farthest distance along +dir from the eye before any coordinate leaves ±bound.
        let bound = SceneLimits.positionBound
        var maxFar: Float = .greatestFiniteMagnitude
        for a in 0..<3 {
            let d = dir[a]
            guard abs(d) > 1e-5 else { continue }
            let t = max((bound - eye[a]) / d, (-bound - eye[a]) / d)   // boundary ahead along +dir
            if t > 0 { maxFar = min(maxFar, t) }
        }
        let minNear = SceneLimits.dollyNearMin
        let desired = dist + move
        let newDist = min(max(desired, minNear), max(minNear, maxFar))
        if move != 0 && newDist != desired {
            LimitReporter.report(desired < minNear ? "Depth dolly (near limit)"
                                                   : "Depth dolly (world bound)")
        }
        return (eye + dir * newDist) - p
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
        // Frame the actual VISIBLE scene — not the camera.  (The old version seeded the
        // box with the scene camera's eye and counted hidden objects, so a camera parked
        // far out, or invisible geometry, dragged the fit center/radius way off.)
        var wMin = SIMD3<Float>(repeating:  Float.greatestFiniteMagnitude)
        var wMax = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        var hasContent = false
        func add(_ w: SIMD3<Float>) { wMin = simd_min(wMin, w); wMax = simd_max(wMax, w); hasContent = true }

        // ── Objects: world-space bounding boxes (visible geometry only) ────────
        for obj in sceneManager.objects {
            if obj.isEnvelope || !obj.isVisible { continue }   // null node / hidden — don't frame
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
                add(SIMD3<Float>(w4.x, w4.y, w4.z))
            }
        }

        // ── Positional lights: their world position (enabled only) ─────────────
        for light in lightManager.lights where light.isEnabled {
            switch light.type {
            case .point, .spot, .laser: add(light.position)
            case .ambient, .directional: break   // no position to include
            }
        }

        // Nothing visible to frame → center on the scene camera's target, modest radius.
        if !hasContent { wMin = camera.target; wMax = camera.target }

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

        // Look along WORLD axes (not the object's local axes), so a standard view is
        // always aligned to world front / side / top regardless of how the selected
        // object is rotated.  Because the Director is then world-aligned, a
        // POV-relative drag moves along a single WORLD axis (horizontal/vertical) with
        // the wheel on the third — exact placement.  We still frame the selected
        // object (centre + size below); only the viewing DIRECTION is world-aligned.
        // eyeDir is the object-centre → camera direction.
        let eyeDir: SIMD3<Float>
        switch view {
        case .front:  eyeDir = SIMD3<Float>( 0,  0,  1)
        case .rear:   eyeDir = SIMD3<Float>( 0,  0, -1)
        case .right:  eyeDir = SIMD3<Float>( 1,  0,  0)
        case .left:   eyeDir = SIMD3<Float>(-1,  0,  0)
        case .top:    eyeDir = SIMD3<Float>( 0,  1,  0)
        case .bottom: eyeDir = SIMD3<Float>( 0, -1,  0)
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
        director.distance = max(distance, SceneLimits.directorDistanceFloor)

        print("[DEBUG] ViewportView: director snapped to \(view)")
    }

    /// Scene-mode only: aim the Director at the bake Probe from the current viewing
    // ── Gait pace rehearsal (ranged playback) ────────────────────────────────
    // Plays the timeline from the gait's first mark (A) to its last (B), then stops —
    // so the playhead scrubs (showing where the next edit goes) AND every object
    // animates (multi-character interaction previews correctly).  The probe also flies
    // the planned gait path, sampled at the live playhead, so a pre-bake pacing preview
    // still works.  Changes no keyframes.
    private var rehearseTimer:     Timer? = nil
    private var rehearsePath:      [(t: Double, pos: SIMD3<Float>, rot: simd_quatf)] = []
    private var rehearseFirstT:    Double = 0
    private var rehearseLastT:     Double = 0
    private var rehearseSavedLooping: Bool? = nil   // restored when the rehearsal ends

    /// Euler° (for the probe gizmo arrow) of a rotation quaternion.
    private func probeEuler(_ q: simd_quatf) -> SIMD3<Float> {
        TransformMath.eulerFromMatrix(simd_float4x4(q))
    }

    /// Begins the rehearsal: seek to A (first path key), play to B (last), then stop.
    /// `path` is the gait root path (time + world position + facing quaternion) used to
    /// fly the probe in sync with the playhead.  Deselects any mark so it isn't edited.
    func startProbeRehearsal(path: [(t: Double, pos: SIMD3<Float>, rot: simd_quatf)]) {
        stopProbeRehearsal()
        guard path.count >= 2 else { return }
        rehearsePath   = path
        rehearseFirstT = path.first!.t
        rehearseLastT  = path.last!.t
        // Release any selected mark so the rehearsal doesn't drag/highlight it.
        probeConfig.selectedMarkIndex = nil
        overlayState.markName = nil
        probeConfig.isVisible = true
        probeConfig.position  = path.first!.pos
        probeConfig.rotation  = probeEuler(path.first!.rot)
        // Ranged playback A → B: disable looping so it actually stops at B.
        rehearseSavedLooping = timeline.isLooping
        timeline.isLooping = false
        timeline.seek(to: rehearseFirstT)
        timeline.play()
        gaitState.isRehearsing = true
        needsDisplay = true
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tickProbeRehearsal()
        }
        RunLoop.main.add(timer, forMode: .common)
        rehearseTimer = timer
        print("[DEBUG] ViewportView: rehearsal playback "
            + String(format: "%.2f→%.2fs", rehearseFirstT, rehearseLastT))
    }

    /// Stops the rehearsal: pauses playback, restores looping, clears the flag.  Leaves
    /// the playhead where it stopped (≈ B) so the user sees the next edit point.
    func stopProbeRehearsal() {
        rehearseTimer?.invalidate()
        rehearseTimer = nil
        rehearsePath  = []
        if let saved = rehearseSavedLooping { timeline.isLooping = saved; rehearseSavedLooping = nil }
        if gaitState.isRehearsing {
            timeline.pause()
            gaitState.isRehearsing = false
        }
    }

    private func tickProbeRehearsal() {
        guard !rehearsePath.isEmpty else { stopProbeRehearsal(); return }
        let t = timeline.currentTime   // driven by playback now (not wall-clock)
        // Reached the end, or playback wrapped/jumped out of the range → finish.
        if t >= rehearseLastT - 1e-4 || t < rehearseFirstT - 0.25 {
            let last = rehearsePath.last!
            timeline.seek(to: rehearseLastT)          // land exactly on B (next edit point)
            probeConfig.position = last.pos
            probeConfig.rotation = probeEuler(last.rot)
            stopProbeRehearsal()
            gaitState.status = "Rehearsal complete."
            needsDisplay = true
            return
        }
        let s = rehearseSampleAt(t)
        probeConfig.position = s.pos
        probeConfig.rotation = probeEuler(s.rot)
        needsDisplay = true
    }

    /// Interpolates the probe pose along the rehearsal path at time `t`: position lerped,
    /// facing SLERPED (shortest-path) so the arrow never swings the long way at heading
    /// wraps.  Dwell samples (equal pose, advancing time) hold the probe still — the pause.
    private func rehearseSampleAt(_ t: Double) -> (pos: SIMD3<Float>, rot: simd_quatf) {
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        guard let first = rehearsePath.first, let last = rehearsePath.last else { return (.zero, identity) }
        if t <= first.t { return (first.pos, first.rot) }
        if t >= last.t  { return (last.pos, last.rot) }
        for i in 0..<(rehearsePath.count - 1) {
            let a = rehearsePath[i], b = rehearsePath[i + 1]
            if t >= a.t && t <= b.t {
                let span = b.t - a.t
                let f = span > 1e-9 ? Float((t - a.t) / span) : 0
                return (a.pos + (b.pos - a.pos) * f, simd_slerp(a.rot, b.rot, f))
            }
        }
        return (last.pos, last.rot)
    }

    /// angle, pulled in close so you can see / fine-tune the Probe.  Reveals the
    /// gizmo if hidden.  One-shot — dolly (⌘− / scroll) from here to adjust.
    func snapDirectorToProbe() {
        guard sceneModeActive else { return }
        probeConfig.isVisible = true
        director.target   = probeConfig.position
        director.distance = 3.0   // "near" — close enough to place the Probe
        print("[DEBUG] ViewportView: director snapped to Probe")
    }

    /// Inverse of `setProbeToDirectorEye`: move the Director's eye to the Probe's
    /// position, keeping the current view direction (translates the whole rig).
    func setDirectorEyeToProbe() {
        director.target += probeConfig.position - director.eyePosition
        needsDisplay = true
        print("[DEBUG] ViewportView: director eye moved to Probe")
    }

    /// Moves the bake Probe to the Director's eye position (the complement of Shift+T) —
    /// e.g. frame the capture viewpoint with the Director, then drop the Probe there.
    /// Reveals the gizmo; clamps to the Probe's ±100 range.  Most useful in Scene mode.
    func setProbeToDirectorEye() {
        let p = simd_clamp(director.eyePosition,
                           SIMD3<Float>(repeating: -SceneLimits.positionBound),
                           SIMD3<Float>(repeating:  SceneLimits.positionBound))
        probeConfig.position  = p
        probeConfig.isVisible = true
        onProbeEdited?()
        print("[DEBUG] ViewportView: probe set to Director eye \(p)")
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

    /// Translates the group transform by `delta` (world-space).  All-or-nothing: if the
    /// move would push the group translation (or any ungrouped part) out of range on
    /// ANY axis, nothing moves and it beeps + logs — no per-axis slide along the wall.
    private func translateGroup(_ parts: [SceneObject], by delta: SIMD3<Float>) {
        guard let gid = parts.first?.groupID else {
            // Ungrouped fallback — move parts directly, but only if every part stays
            // in range (so the group still moves as one unit).
            for obj in parts {
                let p = obj.transform.columns.3
                if !withinPositionBound(SIMD3<Float>(p.x + delta.x, p.y + delta.y, p.z + delta.z)) {
                    LimitReporter.report("Model position"); return
                }
            }
            for obj in parts { translateObject(obj, by: delta) }
            return
        }
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(delta.x, delta.y, delta.z, 1)
        let current = sceneManager.groupTransforms[gid] ?? matrix_identity_float4x4
        let combined = t * current
        let p = combined.columns.3
        guard withinPositionBound(SIMD3<Float>(p.x, p.y, p.z)) else {
            LimitReporter.report("Model position"); return
        }
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

    /// Removes every keyframe past the timeline end across all tracks — stale keys left
    /// behind when the duration was shortened with "Keep Times", or carried in from older
    /// files.  Returns the number removed.  (Spin/orbit-baked tracks end at the duration,
    /// so nothing live is cut.)
    @discardableResult
    func clipKeyframesPastDuration() -> Int {
        let end = timeline.duration + 1e-6
        var removed = 0
        func clip<K>(_ arr: inout [K], _ time: (K) -> Double) {
            let before = arr.count
            arr.removeAll { time($0) > end }
            removed += before - arr.count
        }
        if let tr = camera.keyframeTrack            { clip(&tr.keyframes) { $0.time } }
        for o in sceneManager.objects               { if let tr = o.keyframeTrack { clip(&tr.keyframes) { $0.time } } }
        for tr in sceneManager.groupKeyframeTracks.values { clip(&tr.keyframes) { $0.time } }
        for case let tr? in lightManager.keyframeTracks   { clip(&tr.keyframes) { $0.time } }
        if let tr = fogSettings.keyframeTrack       { clip(&tr.keyframes) { $0.time } }
        for e in particleManager.emitters           { if let tr = e.keyframeTrack { clip(&tr.keyframes) { $0.time } } }
        return removed
    }

    /// Sets the timeline duration.  When `rescaleKeyframes` is true, every keyframe
    /// across all tracks is repositioned proportionally (time × new/old), snapped to
    /// the frame grid and clamped to the new range, so an animation built at one
    /// length fits the new length.  Project load / new-project paths call
    /// `timeline.duration` directly and never rescale.
    func setTimelineDuration(_ newDuration: Double, rescaleKeyframes: Bool) {
        let old = timeline.duration
        let rescaling = rescaleKeyframes && old > 0.0001 && abs(newDuration - old) > 1e-9
        if rescaling {
            let factor = newDuration / old
            rescaleAllKeyframeTimes(by: factor, newDuration: newDuration)
            // Scale each looped bundle's cycle window so it tracks the rescaled keyframes.
            for (bid, var info) in sceneManager.importBundleLoops {
                info.cycleStart  *= factor
                info.cycleLength *= factor
                sceneManager.importBundleLoops[bid] = info
            }
        }
        timeline.duration = newDuration
        if timeline.currentTime > newDuration { timeline.seek(to: newDuration) }
        // Re-tile looped imports so a longer timeline fills with more repeats (and a
        // shorter one trims them) without re-importing.
        regenerateAllBundleLoops()
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

    // MARK: - Delete scene entities (from the Timeline grid)

    /// Deletes a set of scene objects.  Spin/Orbit schedules are id-keyed (P3) so no
    /// index remap is needed — orphaned schedules are pruned; SceneManager repairs
    /// parentIndex / group tracks.
    func deleteObjects(_ indices: Set<Int>) {
        let del = indices.filter { $0 >= 0 && $0 < sceneManager.objects.count }
        guard !del.isEmpty else { return }
        sceneManager.removeObjects(at: del)
        pruneOrphanRateSchedules()
        pruneOrphanMarks()
        pruneEmptyImportBundles()
        renderer?.invalidateAnimationCache()
    }

    /// Deletes a light.  Orbit schedules are id-keyed (P3) so no remap is needed.
    /// No-op on the last light.
    func deleteLight(_ index: Int) {
        guard index >= 0, index < lightManager.lights.count, lightManager.lights.count > 1 else { return }
        lightManager.removeLight(at: index)
        pruneOrphanRateSchedules()
        pruneOrphanMarks()
        pruneEmptyImportBundles()
        renderer?.invalidateAnimationCache()
    }

    /// Drops Spin/Orbit schedules whose target entity / group no longer exists (P3).
    func pruneOrphanRateSchedules() {
        var liveEntities = Set<UUID>()
        liveEntities.formUnion(sceneManager.objects.map { $0.entityID })
        liveEntities.formUnion(lightManager.lights.map  { $0.entityID })
        liveEntities.formUnion(cameras.map              { $0.entityID })
        let liveGroups = Set(sceneManager.objects.compactMap { $0.groupID })
        func keep(_ key: ScheduleKey) -> Bool {
            switch key {
            case .entity(let id):  return liveEntities.contains(id)
            case .group(let gid):  return liveGroups.contains(gid)
            }
        }
        spinRateSchedules  = spinRateSchedules.filter  { keep($0.key) }
        orbitRateSchedules = orbitRateSchedules.filter { keep($0.key) }
    }

    /// Deletes a particle emitter.  No-op on the last emitter.
    func deleteParticleEmitter(_ index: Int) {
        guard index >= 0, index < particleManager.emitters.count, particleManager.emitters.count > 1 else { return }
        particleManager.removeEmitter(at: index)
        pruneOrphanMarks()
        pruneEmptyImportBundles()
        renderer?.invalidateAnimationCache()
    }

    /// Drops Position Marks whose owning item no longer exists (identity refactor P2).
    /// Matched by stable owner id — no index remapping needed since ids are stable.
    /// Legacy marks without an owner id are left alone (migrated to ids on load).
    func pruneOrphanMarks() {
        var live = Set<UUID>()
        live.formUnion(sceneManager.objects.map     { $0.entityID })
        live.formUnion(lightManager.lights.map      { $0.entityID })
        live.formUnion(particleManager.emitters.map { $0.entityID })
        live.formUnion(cameras.map                  { $0.entityID })
        let before = probeConfig.marks.count
        probeConfig.marks.removeAll { m in
            guard let oid = m.owner?.id else { return false }   // legacy / unowned → keep
            return !live.contains(oid)
        }
        if probeConfig.marks.count != before {
            if let sel = probeConfig.selectedMarkIndex, sel >= probeConfig.marks.count {
                probeConfig.selectedMarkIndex = probeConfig.marks.isEmpty ? nil : probeConfig.marks.count - 1
            }
        }
    }

    /// Drops bundle metadata (name / loop / source) for any import bundle that no
    /// longer has a member object, light, or emitter — so deleting an import doesn't
    /// leave an empty bundle behind (which would persist on save).
    private func pruneEmptyImportBundles() {
        let live = Set(sceneManager.objects.compactMap { $0.importBundleID })
            .union(lightManager.lights.compactMap { $0.importBundleID })
            .union(particleManager.emitters.compactMap { $0.importBundleID })
        for bid in Array(sceneManager.importBundles.keys) where !live.contains(bid) {
            sceneManager.importBundles.removeValue(forKey: bid)
            sceneManager.importBundleLoops.removeValue(forKey: bid)
            sceneManager.importBundleSources.removeValue(forKey: bid)
        }
    }

    // MARK: - Import-bundle looping ("Repeat to Fill Timeline")

    /// Re-tiles every looped import bundle.  Called after load and on any timeline-
    /// duration change.
    func regenerateAllBundleLoops() {
        for (bid, info) in sceneManager.importBundleLoops where info.enabled {
            regenerateBundleLoop(bid: bid)
        }
    }

    /// If `ref`'s bundle is loop-enabled, re-tile it.  Hook for keyframe edits to a
    /// looped bundle's source cycle so the repeats follow the edit.
    func regenerateLoopForRef(_ ref: TrackRef) {
        guard let bid = importBundleID(for: ref),
              sceneManager.importBundleLoops[bid]?.enabled == true else { return }
        regenerateBundleLoop(bid: bid)
    }

    /// The import-bundle ID a track belongs to, or nil.
    func importBundleID(for ref: TrackRef) -> Int? {
        switch ref {
        case .object(let i):
            guard i >= 0, i < sceneManager.objects.count else { return nil }
            return sceneManager.objects[i].importBundleID
        case .group(let gid):
            return sceneManager.objects.first { $0.groupID == gid }?.importBundleID
        case .light(let i):
            guard i >= 0, i < lightManager.lights.count else { return nil }
            return lightManager.lights[i].importBundleID
        default:
            return nil
        }
    }

    /// Rebuilds the repeats for one import bundle.  The source cycle is the keyframes
    /// in `[cycleStart, cycleStart+cycleLength]`; copies are tiled by k·cycleLength
    /// out to the timeline end.  Idempotent — first strips any prior tiles (keyframes
    /// past the source cycle), then re-tiles.  When the bundle's loop is disabled it
    /// only strips, leaving the bare source cycle.
    func regenerateBundleLoop(bid: Int) {
        guard let info = sceneManager.importBundleLoops[bid] else { return }
        let cycleStart = info.cycleStart
        let L          = info.cycleLength
        let cycleEnd   = cycleStart + L
        let end        = timeline.duration
        let seamTol    = 1e-3

        // Strip tiles, then re-tile the source cycle.  Generic over the two keyframe
        // structs (object/group TransformKeyframe, light LightKeyframe): callers pass
        // the array plus a time getter/setter.
        func retile<T>(_ kfs: inout [T], time: (T) -> Double, setTime: (inout T, Double) -> Void) {
            kfs.removeAll { time($0) > cycleEnd + seamTol }
            guard info.enabled, L > seamTol else { kfs.sort { time($0) < time($1) }; return }
            let source = kfs.filter { time($0) >= cycleStart - seamTol && time($0) <= cycleEnd + seamTol }
            guard !source.isEmpty else { return }
            var k = 1
            while cycleStart + Double(k) * L <= end + seamTol {
                let shift = Double(k) * L
                for kf in source {
                    let t = time(kf) + shift
                    if t > end + seamTol { continue }
                    // Drop the seam duplicate (a tile landing on an existing keyframe).
                    if kfs.contains(where: { abs(time($0) - t) <= seamTol }) { continue }
                    var copy = kf; setTime(&copy, t)
                    kfs.append(copy)
                }
                k += 1
            }
            kfs.sort { time($0) < time($1) }
        }

        var seenGroups = Set<Int>()
        for obj in sceneManager.objects where obj.importBundleID == bid {
            if let track = obj.keyframeTrack {
                retile(&track.keyframes, time: { $0.time }, setTime: { $0.time = $1 })
            }
            if let gid = obj.groupID, seenGroups.insert(gid).inserted,
               let gtrack = sceneManager.groupKeyframeTracks[gid] {
                retile(&gtrack.keyframes, time: { $0.time }, setTime: { $0.time = $1 })
            }
        }
        for i in 0..<lightManager.lights.count where lightManager.lights[i].importBundleID == bid {
            if i < lightManager.keyframeTracks.count, let ltrack = lightManager.keyframeTracks[i] {
                retile(&ltrack.keyframes, time: { $0.time }, setTime: { $0.time = $1 })
            }
        }
        for fx in particleManager.emitters where fx.importBundleID == bid {
            if let ptrack = fx.keyframeTrack {
                retile(&ptrack.keyframes, time: { $0.time }, setTime: { $0.time = $1 })
            }
        }
        renderer?.invalidateAnimationCache()
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

    // MARK: - Auto-keyframe on edit

    /// Called at the end of an edit gesture (viewport drag / arrow nudge / slider
    /// commit) for the edited entity.  When the entity is ALREADY animated and the
    /// matching Setting is on, captures the change as a keyframe so a scrub/play won't
    /// discard it — updating the keyframe under the playhead, or inserting a new one
    /// between keyframes.  No-op otherwise.
    func autoKeyframeOnEdit(_ ref: TrackRef) {
        if isLocked(ref) { return }   // locked track — no keyframe changes
        let s = AppSettings.shared
        guard s.autoKeyframeUpdateNearby || s.autoKeyframeInsertBetween else { return }
        // Skip rate-driven tracks: their keyframes are regenerated from spin/orbit
        // markers, so an auto-stamp would just be wiped on the next regenerate.
        if hasRateSchedule(for: ref) { return }
        let times = autoKeyframeTrackTimes(ref)
        guard !times.isEmpty else { return }   // animated-only
        let playhead = timeline.currentTime
        let near = times.contains { abs($0 - playhead) <= stampMergeTolerance }
        guard (near && s.autoKeyframeUpdateNearby) || (!near && s.autoKeyframeInsertBetween) else { return }
        autoKeyframeStamp(ref)
    }

    /// Keyframe times on the entity's track (empty when it has none).
    private func autoKeyframeTrackTimes(_ ref: TrackRef) -> [Double] {
        switch ref {
        case .cameraCuts: return []
        case .object(let i):
            guard i >= 0, i < sceneManager.objects.count else { return [] }
            return sceneManager.objects[i].keyframeTrack?.keyframes.map { $0.time } ?? []
        case .group(let gid):
            return sceneManager.groupKeyframeTracks[gid]?.keyframes.map { $0.time } ?? []
        case .light(let i):
            guard i >= 0, i < lightManager.keyframeTracks.count else { return [] }
            return lightManager.keyframeTracks[i]?.keyframes.map { $0.time } ?? []
        case .camera:
            return camera.keyframeTrack?.keyframes.map { $0.time } ?? []   // active camera only (auto-kf)
        case .fog:
            return fogSettings.keyframeTrack?.keyframes.map { $0.time } ?? []
        case .particles(let i):
            guard i >= 0, i < particleManager.emitters.count else { return [] }
            return particleManager.emitters[i].keyframeTrack?.keyframes.map { $0.time } ?? []
        case .mark, .importBundle, .category, .model:
            return []
        }
    }

    /// Stamps a keyframe for the entity using its existing per-type stamp (which merges
    /// into the nearby keyframe or adds a new one via the shared merge tolerance).
    private func autoKeyframeStamp(_ ref: TrackRef) {
        switch ref {
        case .object(let i):    addKeyframeAtCurrentTime(forObjectAt: i)
        case .group(let gid):   addGroupKeyframeAtCurrentTime(for: gid)
        case .light(let i):     addLightKeyframeAtCurrentTime(forLightAt: i)
        case .camera:           addCameraKeyframeFromPanel()
        case .fog:              addFogKeyframeAtCurrentTime()
        case .particles(let i): addParticleKeyframeAtCurrentTime(forEmitterAt: i)
        case .cameraCuts:       break
        case .mark, .importBundle, .category, .model: break
        }
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
        regenerateLoopForRef(.object(index))   // refresh repeats if this is a looped import
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
        regenerateLoopForRef(.group(gid))      // refresh repeats if this is a looped import
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
        regenerateLoopForRef(.light(index))    // refresh repeats if this is a looped import
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
        onKeyframeStamped?(.camera(activeCameraIndex))
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
                let dist  = max(SceneLimits.orbitDistanceMin, min(SceneLimits.orbitDistanceMax, simd_length(dir)))
                let pitch = asin(max(-1, min(1, dir.y / dist)))
                let yaw   = atan2(dir.x, dir.z)
                camera.keyframeTrack?.addKeyframe(CameraKeyframe(
                    time: s.time, yaw: yaw, pitch: pitch, distance: dist,
                    target: fixedAim, fov: camera.fovYRadians))
            }
            onKeyframeStamped?(.camera(activeCameraIndex))

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

    /// Gait (walk) generator: bakes a locomotion along `markPositions` for the model
    /// `gid` — root path + heading on the group track, limb cycle on the per-part
    /// tracks (matched by canonical joint name).  Replaces keyframes in the generated
    /// time window.  Returns the joint names that were expected but missing.
    @discardableResult
    func generateGait(groupID gid: Int,
                      gait: GaitType,
                      params: GaitParams,
                      markPositions: [SIMD3<Float>],
                      speed: Float,
                      strideLength: Float,
                      autoStride: Bool,
                      footLock: Bool,
                      startTime: Double,
                      plantFeet: Bool,
                      markTimes: [Double]? = nil,
                      markRotations: [SIMD3<Float>?]? = nil) -> (missing: [String], spedUp: Int) {

        // Parts of this model, indexed by their (unique-within-group) name.
        var partIndexByName: [String: Int] = [:]
        var groupPartIndices: [Int] = []
        for (i, obj) in sceneManager.objects.enumerated() where obj.groupID == gid {
            partIndexByName[obj.name] = i
            groupPartIndices.append(i)
        }

        // A gait owns the whole model's tracks (it rebakes the group path + every part),
        // so drop any spin/orbit rate schedule on the group or its parts first.  A stale
        // schedule left registered would otherwise re-bake over the walk on a later edit
        // (and leaves a stray keyframe behind) — the cause of a model tumbling instead of
        // walking when it carried a leftover group spin.
        for ref in [TrackRef.group(gid)] + groupPartIndices.map({ TrackRef.object($0) }) {
            if spinSchedule(for: ref)  != nil { setSpinSchedule(ref: ref, markers: [], keyframesPerRevolution: 12) }
            if orbitSchedule(for: ref) != nil { setOrbitSchedule(ref: ref, schedule: nil, keyframesPerRevolution: 12) }
        }

        let groupScale = TransformMath.scale(of: sceneManager.groupTransforms[gid] ?? matrix_identity_float4x4)

        // Rest-pose (group-local) world transform of a part — composes baseTransforms up
        // the parentIndex chain.  Shared by ground-offset and auto-stride.
        var restCache: [Int: matrix_float4x4] = [:]
        func restWorld(_ i: Int) -> matrix_float4x4 {
            if let m = restCache[i] { return m }
            let o = sceneManager.objects[i]
            let m = (o.parentIndex.map { restWorld($0) } ?? matrix_identity_float4x4) * o.baseTransform
            restCache[i] = m
            return m
        }

        // Ground offset: lowest point of the model in its rest pose (group-local), so
        // setting the root translation to a mark plants the feet there instead of the
        // hips.  Scaled by the group's Y scale.
        var groundOffset: Float = 0
        if plantFeet || footLock {       // foot-IK needs the feet down on the ground marks
            var minY = Float.greatestFiniteMagnitude
            for i in groupPartIndices {
                let o   = sceneManager.objects[i]
                let rw  = restWorld(i)
                let lo  = o.boundingMin, hi = o.boundingMax
                for cx in [lo.x, hi.x] { for cy in [lo.y, hi.y] { for cz in [lo.z, hi.z] {
                    let p = rw * SIMD4<Float>(cx, cy, cz, 1)
                    minY = min(minY, p.y)
                }}}
            }
            if minY < Float.greatestFiniteMagnitude { groundOffset = -minY * groupScale.y }
        }

        // Auto stride: the no-foot-skate stride ≈ 4·legLength·sin(hipSwing).  Cadence
        // (cycles/sec = speed/stride) then follows the speed.  Falls back to the manual
        // value when the leg joints aren't present.
        var effectiveStride = strideLength
        if autoStride {
            let hipIdx  = partIndexByName["upper_leg_L"] ?? partIndexByName["upper_leg_R"]
            let footIdx = partIndexByName["foot_L"]  ?? partIndexByName["ankle_L"]
                       ?? partIndexByName["foot_R"]  ?? partIndexByName["ankle_R"]
            if let h = hipIdx, let f = footIdx {
                let hp = restWorld(h).columns.3, fp = restWorld(f).columns.3
                let legLocal = simd_length(SIMD3<Float>(hp.x - fp.x, hp.y - fp.y, hp.z - fp.z))
                effectiveStride = max(0.02, 4 * legLocal * groupScale.y * sin(params.hipSwing))
            }
        }

        // Foot-IK rig: leg-segment lengths + rest hip positions (group-local), built only
        // when foot-lock is on and the canonical leg joints are present (else legs swing
        // open-loop).  Lengths from the left leg (assumed symmetric).
        var legRig: GaitGenerator.LegRig? = nil
        if footLock, gait != .swim,
           let hL = partIndexByName["upper_leg_L"], let hR = partIndexByName["upper_leg_R"],
           let kn = partIndexByName["knee_L"],
           let ft = partIndexByName["foot_L"] ?? partIndexByName["ankle_L"] {
            let hipLt = restWorld(hL).columns.3, hipRt = restWorld(hR).columns.3
            let kneet = restWorld(kn).columns.3, foott = restWorld(ft).columns.3
            let thigh = simd_length(SIMD3<Float>(hipLt.x - kneet.x, hipLt.y - kneet.y, hipLt.z - kneet.z))
            let shin  = simd_length(SIMD3<Float>(kneet.x - foott.x, kneet.y - foott.y, kneet.z - foott.z))
            if thigh > 1e-4, shin > 1e-4 {
                legRig = GaitGenerator.LegRig(
                    thigh: thigh, shin: shin,
                    hipL: SIMD3<Float>(hipLt.x, hipLt.y, hipLt.z),
                    hipR: SIMD3<Float>(hipRt.x, hipRt.y, hipRt.z))
            }
        }

        let out = GaitGenerator.generate(
            gait: gait, params: params, marks: markPositions, speed: speed,
            strideLength: effectiveStride, startTime: startTime, groundOffset: groundOffset,
            groupScale: groupScale, legRig: legRig, markTimes: markTimes,
            markRotations: markRotations,
            availableJoints: Set(partIndexByName.keys))
        guard let firstRoot = out.rootKeys.first else { return (out.missingJoints, out.spedUpSegments) }

        let lo = firstRoot.time - 1e-6

        // Clear this gait's region ONWARD across the whole model first — the group
        // track and every part — so a previous (longer/slower, or different-gait)
        // bake leaves no tail that keeps the model moving after this one ends.
        sceneManager.groupKeyframeTracks[gid]?.keyframes.removeAll { $0.time >= lo }
        for i in groupPartIndices {
            sceneManager.objects[i].keyframeTrack?.keyframes.removeAll { $0.time >= lo }
        }

        // Root path → group track.
        if sceneManager.groupKeyframeTracks[gid] == nil {
            sceneManager.groupKeyframeTracks[gid] = KeyframeTrack()
        }
        for kf in out.rootKeys { sceneManager.groupKeyframeTracks[gid]?.addKeyframe(kf) }
        onKeyframeStamped?(.group(gid))

        // Limb cycles → per-part tracks.
        for (name, keys) in out.limbKeys {
            guard let i = partIndexByName[name] else { continue }
            let obj = sceneManager.objects[i]
            if obj.keyframeTrack == nil { obj.keyframeTrack = KeyframeTrack() }
            for kf in keys { obj.keyframeTrack?.addKeyframe(kf) }
            onKeyframeStamped?(.object(i))
        }

        return (out.missingJoints, out.spedUpSegments)
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
            onKeyframeStamped?(.camera(activeCameraIndex))

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

    // MARK: - Rate-marker schedules

    /// Replaces an object/model spin schedule and rebakes its keyframes.  Passing an
    /// empty `markers` clears the schedule and the keyframes it owned.
    func setSpinSchedule(ref: TrackRef, markers: [SpinRateMarker],
                         keyframesPerRevolution: Float) {
        let oldFirst  = spinSchedule(for: ref)?.map(\.time).min()
        let newFirst  = markers.map(\.time).min()
        let clearFrom = [oldFirst, newFirst].compactMap { $0 }.min() ?? 0
        let cleaned   = markers.isEmpty ? nil : markers.sorted { $0.time < $1.time }
        if let key = scheduleKey(for: ref) { spinRateSchedules[key] = cleaned }
        regenerateSpinRate(ref: ref, markers: cleaned ?? [],
                           keyframesPerRevolution: keyframesPerRevolution, clearFrom: clearFrom)
        regenerateLoopForRef(ref)   // re-tile if this track is in a looped import bundle
    }

    /// Replaces a camera/light/object orbit schedule and rebakes its keyframes.
    /// Passing `nil` (or an empty marker list) clears the schedule and its keyframes.
    func setOrbitSchedule(ref: TrackRef, schedule: OrbitRateSchedule?,
                          keyframesPerRevolution: Float) {
        let oldFirst  = orbitSchedule(for: ref)?.markers.map(\.time).min()
        let newFirst  = schedule?.markers.map(\.time).min()
        let clearFrom = [oldFirst, newFirst].compactMap { $0 }.min() ?? 0
        let cleaned: OrbitRateSchedule? = (schedule?.markers.isEmpty ?? true) ? nil : schedule
        if let key = scheduleKey(for: ref) { orbitRateSchedules[key] = cleaned }
        regenerateOrbitRate(ref: ref, schedule: cleaned,
                            keyframesPerRevolution: keyframesPerRevolution, clearFrom: clearFrom)
        regenerateLoopForRef(ref)   // re-tile if this track is in a looped import bundle
    }

    /// Rebuilds an object/model spin track from its rate markers.  Clears the owned
    /// region [clearFrom, timeline end] and bakes a constant-velocity spin per
    /// segment; orientation is carried continuously across segment (and axis)
    /// changes via an accumulated rotation.  `keyframesPerRevolution` sets density;
    /// a rate-0 segment holds still.  Forces LINEAR easing for exact constant speed.
    private func regenerateSpinRate(ref: TrackRef, markers: [SpinRateMarker],
                                    keyframesPerRevolution: Float, clearFrom: Double) {
        let sorted  = markers.sorted { $0.time < $1.time }
        let perRev  = max(3.0, Double(keyframesPerRevolution))
        let deg2rad = Float.pi / 180.0
        let end     = timeline.duration

        func axisVec(_ idx: Int) -> SIMD3<Float> {
            switch idx {
            case 0:  return SIMD3<Float>(1, 0, 0)
            case 2:  return SIMD3<Float>(0, 0, 1)
            default: return SIMD3<Float>(0, 1, 0)
            }
        }
        func segCount(rate: Double, revs: Double) -> Int {
            rate == 0 ? 2 : max(2, Int((abs(revs) * perRev).rounded(.up)) + 1)
        }

        switch ref {
        case .object(let i):
            guard i >= 0, i < sceneManager.objects.count else { return }
            let obj = sceneManager.objects[i]
            if obj.keyframeTrack == nil {
                if sorted.isEmpty { return }
                obj.keyframeTrack = KeyframeTrack()
            }
            obj.keyframeTrack?.easingMode = .linear
            // The static pose normally lives in the object's transform.  But an IMPORTED
            // object can carry its pose ONLY in its baked keyframes (its transform was
            // reset to baseTransform on import) — capture that pose at the first marker
            // before clearing so the rebake doesn't drop its translation/scale/orientation.
            let preMat = sorted.first.flatMap { obj.keyframeTrack?.evaluate(at: $0.time) }
            obj.keyframeTrack?.keyframes.removeAll { $0.time >= clearFrom - 1e-6 && $0.time <= end + 1e-6 }

            let baseInv = simd_inverse(obj.baseTransform)
            let current = (obj.parentIndex != nil) ? obj.localTransform : obj.transform
            var (baseT, baseR, baseS) = PathGenerator.decompose(baseInv * current)
            // transform carries no pose offset (current == base) but the keyframes do →
            // take the static pose from the keyframes (the import case; in-project spins,
            // whose pose is in the transform, have a non-identity delta and are unaffected).
            if let preMat,
               simd_length(baseT) < 1e-5,
               simd_length(baseS - SIMD3<Float>(1, 1, 1)) < 1e-4 {
                let d = PathGenerator.decompose(preMat)
                baseT = d.translation; baseR = d.rotation; baseS = d.scale
            }
            let opacity = obj.material.opacity

            var accum = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            for (idx, m) in sorted.enumerated() {
                let t0 = m.time
                let t1 = (idx + 1 < sorted.count) ? sorted[idx + 1].time : end
                guard t1 > t0 + 1e-6 else { continue }
                let dur   = t1 - t0
                let revs  = m.rate  * dur
                let revs2 = m.rate2 * dur
                let axis  = axisVec(m.axisIndex)
                let axis2 = axisVec(m.axisIndex2)
                // Density covers the faster of the two axes; both 0 → just hold.
                let count = segCount(rate: (m.rate == 0 && m.rate2 == 0) ? 0 : 1,
                                     revs: max(abs(revs), abs(revs2)))
                for k in (idx == 0 ? 0 : 1)..<count {
                    let s   = Float(k) / Float(count - 1)
                    var q   = accum * simd_quatf(angle: Float(revs) * 360.0 * deg2rad * s, axis: axis)
                    if m.rate2 != 0 { q = q * simd_quatf(angle: Float(revs2) * 360.0 * deg2rad * s, axis: axis2) }
                    q = simd_normalize(q)
                    obj.keyframeTrack?.addKeyframe(TransformKeyframe(
                        time: t0 + Double(s) * dur, translation: baseT,
                        rotation: simd_normalize(baseR * q), scale: baseS, opacity: opacity))
                }
                var segRot = simd_quatf(angle: Float(revs) * 360.0 * deg2rad, axis: axis)
                if m.rate2 != 0 { segRot = segRot * simd_quatf(angle: Float(revs2) * 360.0 * deg2rad, axis: axis2) }
                accum = simd_normalize(accum * segRot)
            }
            onKeyframeStamped?(.object(i))

        case .group(let gid):
            let parts = sceneManager.objects(inGroup: gid)
            guard !parts.isEmpty else { return }
            if sceneManager.groupKeyframeTracks[gid] == nil {
                if sorted.isEmpty { return }
                sceneManager.groupKeyframeTracks[gid] = KeyframeTrack()
            }
            let track = sceneManager.groupKeyframeTracks[gid]
            track?.easingMode = .linear
            track?.keyframes.removeAll { $0.time >= clearFrom - 1e-6 && $0.time <= end + 1e-6 }

            let g0    = sceneManager.groupTransforms[gid] ?? matrix_identity_float4x4
            let pivot = groupCenter(parts)
            let r0    = PathGenerator.decompose(g0).rotation
            var tFwd = matrix_identity_float4x4; tFwd.columns.3 = SIMD4<Float>( pivot, 1)
            var tInv = matrix_identity_float4x4; tInv.columns.3 = SIMD4<Float>(-pivot, 1)

            var accum = matrix_identity_float4x4
            for (idx, m) in sorted.enumerated() {
                let t0 = m.time
                let t1 = (idx + 1 < sorted.count) ? sorted[idx + 1].time : end
                guard t1 > t0 + 1e-6 else { continue }
                let dur   = t1 - t0
                let revs  = m.rate  * dur
                let revs2 = m.rate2 * dur
                let axisWorld  = simd_act(r0, axisVec(m.axisIndex))
                let axisWorld2 = simd_act(r0, axisVec(m.axisIndex2))
                let count = segCount(rate: (m.rate == 0 && m.rate2 == 0) ? 0 : 1,
                                     revs: max(abs(revs), abs(revs2)))
                for k in (idx == 0 ? 0 : 1)..<count {
                    let s   = Float(k) / Float(count - 1)
                    var rot = accum * rotationMatrix4x4(simd_quatf(angle: Float(revs) * 360.0 * deg2rad * s, axis: axisWorld))
                    if m.rate2 != 0 {
                        rot = rot * rotationMatrix4x4(simd_quatf(angle: Float(revs2) * 360.0 * deg2rad * s, axis: axisWorld2))
                    }
                    let (t, r, sc) = PathGenerator.decompose(tFwd * rot * tInv * g0)
                    track?.addKeyframe(TransformKeyframe(
                        time: t0 + Double(s) * dur, translation: t, rotation: r, scale: sc))
                }
                var segRot = rotationMatrix4x4(simd_quatf(angle: Float(revs) * 360.0 * deg2rad, axis: axisWorld))
                if m.rate2 != 0 {
                    segRot = segRot * rotationMatrix4x4(simd_quatf(angle: Float(revs2) * 360.0 * deg2rad, axis: axisWorld2))
                }
                accum = accum * segRot
            }
            onKeyframeStamped?(.group(gid))

        default:
            return
        }
    }

    /// Rebuilds a camera / light / object orbit track from its rate schedule: a
    /// constant-height planar circle around `schedule.axisStart`, swept at the
    /// markers' rates with a continuous angle across segments.  Clears the owned
    /// region [clearFrom, timeline end].  A `nil` schedule just clears.  LINEAR easing.
    private func regenerateOrbitRate(ref: TrackRef, schedule: OrbitRateSchedule?,
                                     keyframesPerRevolution: Float, clearFrom: Double) {
        let perRev = max(1.0, Double(keyframesPerRevolution))
        let end    = timeline.duration
        let center = schedule?.axisStart ?? .zero

        // Build one continuous-angle sample list spanning all segments.
        var samples: [PathGenerator.Sample] = []
        if let schedule = schedule {
            let sorted  = schedule.markers.sorted { $0.time < $1.time }
            let axisDir = schedule.axisEnd - schedule.axisStart
            let radius  = schedule.radius
            var accAngle: Float = 0
            for (idx, m) in sorted.enumerated() {
                let t0 = m.time
                let t1 = (idx + 1 < sorted.count) ? sorted[idx + 1].time : end
                guard t1 > t0 + 1e-6 else { continue }
                let dur   = t1 - t0
                let revs  = Float(m.rate * dur)
                let endA  = accAngle + revs * 360.0
                let count = (m.rate == 0) ? 2 : max(2, Int((abs(Double(revs)) * perRev).rounded(.up)) + 1)
                let seg = PathGenerator.planarSamples(
                    center: schedule.axisStart, axisDir: axisDir, radius: radius,
                    startAngleDeg: accAngle, endAngleDeg: endA,
                    startTime: t0, endTime: t1, count: count)
                samples.append(contentsOf: idx == 0 ? seg : Array(seg.dropFirst()))
                accAngle = endA
            }
        }
        let lo = clearFrom - 1e-6
        let hi = end + 1e-6

        switch ref {
        case .camera:
            if camera.keyframeTrack == nil {
                if samples.isEmpty { return }
                camera.keyframeTrack = CameraKeyframeTrack()
            }
            camera.keyframeTrack?.easingMode = .linear
            camera.keyframeTrack?.keyframes.removeAll { $0.time >= lo && $0.time <= hi }
            for s in samples {
                let dir   = s.position - center
                let dist  = max(SceneLimits.orbitDistanceMin, min(SceneLimits.orbitDistanceMax, simd_length(dir)))
                let pitch = asin(max(-1, min(1, dir.y / dist)))
                let yaw   = atan2(dir.x, dir.z)
                camera.keyframeTrack?.addKeyframe(CameraKeyframe(
                    time: s.time, yaw: yaw, pitch: pitch, distance: dist,
                    target: center, fov: camera.fovYRadians))
            }
            onKeyframeStamped?(.camera(activeCameraIndex))

        case .light(let i):
            guard i >= 0, i < lightManager.lights.count else { return }
            let light = lightManager.lights[i]
            while lightManager.keyframeTracks.count <= i { lightManager.keyframeTracks.append(nil) }
            if lightManager.keyframeTracks[i] == nil {
                if samples.isEmpty { return }
                lightManager.keyframeTracks[i] = LightKeyframeTrack()
            }
            lightManager.keyframeTracks[i]?.easingMode = .linear
            lightManager.keyframeTracks[i]?.keyframes.removeAll { $0.time >= lo && $0.time <= hi }
            for s in samples {
                lightManager.keyframeTracks[i]?.addKeyframe(LightKeyframe(
                    time: s.time, intensity: light.intensity, color: light.color,
                    target: center, position: s.position,
                    range: light.range, beamThickness: light.beamThickness))
            }
            onKeyframeStamped?(.light(i))

        case .object(let i):
            guard i >= 0, i < sceneManager.objects.count else { return }
            let obj = sceneManager.objects[i]
            if obj.keyframeTrack == nil {
                if samples.isEmpty { return }
                obj.keyframeTrack = KeyframeTrack()
            }
            obj.keyframeTrack?.easingMode = .linear
            obj.keyframeTrack?.keyframes.removeAll { $0.time >= lo && $0.time <= hi }
            // The frame the object's keyframe delta resolves within, in world space:
            // groupMatrix · parentWorld (identity for a plain root).  For a grouped
            // part or glued member the renderer composes these on top, so we convert
            // the world circle into this frame — the part then orbits relative to its
            // model (riding along with any model-level motion) instead of being
            // displaced.  Captured at the current (bake-time) pose.
            let groupMat    = obj.groupID.flatMap { sceneManager.groupTransforms[$0] }
                              ?? matrix_identity_float4x4
            let parentWorld = obj.parentIndex.map { sceneManager.objects[$0].transform }
                              ?? matrix_identity_float4x4
            let frameInv    = simd_inverse(groupMat * parentWorld)
            let baseInv     = simd_inverse(obj.baseTransform)
            let opacity     = obj.material.opacity
            // World-appearance scale (includes the group matrix) so the part keeps its
            // on-screen size after the frame conversion divides the parent/group scale out.
            let objScale    = TransformMath.scale(of: groupMat * obj.transform)
            for s in samples {
                let worldRot = PathGenerator.lookAtRotation(from: s.position, to: s.axisPoint)
                let world    = PathGenerator.makeTransform(translation: s.position, rotation: worldRot, scale: objScale)
                let (t, r, sc) = PathGenerator.decompose(baseInv * frameInv * world)
                obj.keyframeTrack?.addKeyframe(TransformKeyframe(
                    time: s.time, translation: t, rotation: r, scale: sc, opacity: opacity))
            }
            onKeyframeStamped?(.object(i))

        default:
            break
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
        // Resolve the selection to its disambiguated display name ("cube 2") and reuse
        // the named variant, so the anchor lookup AND the stored follow target are the
        // SAME instance.  (Looking the anchor up by obj.name alone resolved a duplicate
        // single-mesh object to the FIRST instance — the camera aimed at the wrong cube.)
        addFollowCameraKeyframeAtCurrentTime(
            followingObjectNamed: sceneManager.displayName(for: obj))
    }

    /// Variant of `addFollowCameraKeyframeAtCurrentTime()` that follows a specific named
    /// object rather than the current selection.  Used by the keyframe-edit commit path
    /// to preserve the original follow target when re-writing an edited keyframe.
    ///
    /// Same capture-as-is behaviour as the no-arg variant.
    func addFollowCameraKeyframeAtCurrentTime(followingObjectNamed targetName: String,
                                              objectID: UUID? = nil) {
        if camera.keyframeTrack == nil {
            camera.keyframeTrack = CameraKeyframeTrack()
            print("[DEBUG] ViewportView: created new CameraKeyframeTrack")
        }
        var followYawOffset:    Float? = nil
        var followPitchOffset:  Float? = nil
        var targetOffset = SIMD3<Float>(0, 0, 0)
        var followForwardLocal: SIMD3<Float>? = nil
        // Resolve the followed object preferring its STABLE id (identity P1) — so editing
        // a follow keyframe after the target was RENAMED still finds it; the name is just
        // a fallback.  Re-store the object's CURRENT display name + id.
        let followObj = sceneManager.followObject(id: objectID, name: targetName)
        let resolvedName = followObj.map { sceneManager.displayName(for: $0) } ?? targetName
        if let anchor = followObj.flatMap({ sceneManager.worldOrbitAnchor(for: $0) }) {
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
            followTargetName:   resolvedName,
            followObjectID:     followObj?.entityID,
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
        onKeyframeStamped?(.camera(activeCameraIndex))
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

    /// Inverse of `positionCameraOnFollowSphere`: given a Camera keyframe time on
    /// the active camera's track, recover the Camera Inspector POV sliders (follow
    /// target display name + distance / azimuth / elevation in the object's local
    /// frame) so clicking a follow keyframe in the Timeline mirrors it into the
    /// panel.  Returns nil for free (non-follow) keyframes.
    ///
    /// Primary path uses the keyframe's stored `followForwardLocal` (forward in the
    /// object's LOCAL frame at stamp time) — `localDir = -followForwardLocal` — so
    /// the result is independent of where the object currently sits (no race with
    /// the click's seek/redraw).  Legacy keyframes lacking it fall back to the live
    /// anchor basis + stored yaw/pitch.
    func povSliderValues(forCameraKeyframeAt kfTime: Double)
        -> (name: String, distance: Float, azimuthDeg: Float, elevationDeg: Float)? {
        guard let track = camera.keyframeTrack,
              let kf = track.keyframes.first(where: { abs($0.time - kfTime) < 0.001 }),
              kf.isFollow else { return nil }
        let obj  = sceneManager.followObject(id: kf.followObjectID, name: kf.followTargetName)
        let name = obj.map { sceneManager.displayName(for: $0) } ?? kf.followTargetName ?? ""

        let localDir: SIMD3<Float>
        if let fwdLocal = kf.followForwardLocal {
            localDir = -fwdLocal                          // outward (anchor → camera), local frame
        } else if let anchor = obj.flatMap({ sceneManager.worldOrbitAnchor(for: $0) }) {
            let worldDir = -cameraForward(yaw: kf.yaw, pitch: kf.pitch)
            localDir = anchor.basis.transpose * worldDir
        } else {
            return nil
        }
        let el = asin(max(-1, min(1, localDir.y)))
        let az = atan2(localDir.x, localDir.z)
        return (name, kf.distance, az * 180 / .pi, el * 180 / .pi)
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
            // The dropdown stores a DISPLAY name ("cube 2"), so match by display name
            // (raw name as a fallback for older projects); comparing only against the
            // raw object name failed for duplicates and silently stamped a free keyframe.
            if sceneManager.objects.contains(where: {
                sceneManager.displayName(for: $0) == name || $0.name == name
            }) {
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
        // panel next polls after playback stops.)  Also skip during export — the
        // export thread mutates the live camera, so polling it both updates need-
        // lessly and races that thread.
        // Lock state is cheap and must track the padlock even mid-play/export.
        if cameraPanelState.isLocked != cameraLocked { cameraPanelState.isLocked = cameraLocked }
        syncCameraListToPanel()   // keep the camera selector current (cheap, guarded)
        guard !timeline.isPlaying, activeExporter == nil else { return }
        let fl = 12.0 / tan(camera.fovYRadians / 2)
        cameraPanelState.refresh(position:    camera.eyePosition,
                                 target:      camera.target,
                                 focalLength: fl)
    }

    // MARK: - Video Export

    func startExport(to url: URL, codec: ExportCodec, fps: ExportFrameRate,
                     exportState: ExportState, includeFX: Bool = true,
                     keepCoverageAlpha: Bool = false,
                     rangeStart: Double = 0, rangeEnd: Double? = nil,
                     onCompletion: ((Error?) -> Void)? = nil) {
        guard let dev = device else {
            print("[DEBUG] ViewportView: startExport — Metal device is nil")
            return
        }
        guard let r = renderer,
              let pipeline = r.pipelineState,
              let depth    = r.depthStencilState,
              let scenePipeline = r.scenePipeline else {
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
            rangeStart:        rangeStart,
            rangeEnd:          rangeEnd,
            pipelineState:     pipeline,
            depthStencilState: depth,
            scenePipeline:     scenePipeline,
            holdoutPipelineState: r.holdoutPipelineState,
            transparentPipelineState: r.transparentPipelineState,
            transparentDepthState:    r.transparentDepthState,
            holdoutRestampDepthState: r.holdoutRestampDepthState,
            depthOnlyPipelineState:   r.depthOnlyPipelineState
        ) else {
            print("[DEBUG] ViewportView: startExport — VideoExporter init returned nil")
            return
        }

        exporter.colorMode          = renderSettings.colorMode
        exporter.keepCoverageAlpha  = keepCoverageAlpha
        exporter.isWireframe        = renderer?.isWireframe      ?? false
        exporter.showAxesGizmo      = renderSettings.showAxesGizmo
        exporter.marks              = probeConfig.marks
        exporter.marksVisible       = probeConfig.marksVisible
        exporter.feedbackSettings   = feedbackSettings
        exporter.colorGradeSettings = colorGradeSettings
        exporter.fxaaEnabled        = renderer?.fxaaEnabled ?? true   // match the viewport
        // FX (fog + weather particles) belong to the Background class: include them
        // only in passes that show Background (Full, Scene).  Solo/Matte passes pass
        // includeFX=false so the actor/macguffin matte stays clean.
        exporter.fogSettings        = includeFX ? fogSettings : nil
        exporter.particleManager    = includeFX ? particleManager : nil
        exporter.includeLaserFX     = includeFX
        exporter.ibl                = renderer?.ibl   // share IBL so exports match preview
        exporter.backgroundEquirect = renderer?.backgroundEquirect   // dedicated bg HDR (if any)
        // Phase 1c: scheduled camera cuts drive the exported camera.  Sync the active
        // camera into its slot first so the program selection is current.
        captureActiveCamera()
        exporter.cameras            = cameras
        exporter.cameraCuts         = cameraCuts
        exporter.activeCameraIndex  = activeCameraIndex
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
            // Export mutated the shared live camera (cuts/animation); restore the edit camera.
            if let self { self.loadCameraIntoController(self.activeCameraIndex) }
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
        // true → keep geometry coverage alpha on the 4444 colour pass instead of
        // luma (opaque foreground; clean premultiplied composite in Resolve).
        var coverageAlpha: Bool = false
    }

    /// Runs the full multi-pass export cycle sequentially, writing
    /// `<projectName>.<NN>.<PassName>.mov` into `folder`.  Passes are chained on
    /// each export's completion (one VideoExporter run per pass).  `onAllComplete`
    /// fires once after the last pass, or on the first error.  The caller restores
    /// scene state afterward (by reloading the just-saved project).
    /// Builds the Export All pass list from the classes/FX present in the scene.
    /// Shared by startExportAll and the pass-count accessor so they never disagree.
    private func exportAllPasses() -> [ExportPass] {
        let present = Set(sceneManager.objects.map { $0.objectClass })
        // FX present if any weather emitter is enabled or fog is on (lasers ride along).
        let fxPresent = particleManager.emitters.contains { $0.isEnabled }
                     || fogSettings.isEnabled
        var passes: [ExportPass] = [
            ExportPass(name: "Scene", visible: [.set, .actor, .macguffin],
                       matte: false, blackBg: false, fx: true)
        ]
        if present.contains(.actor) {
            passes.append(ExportPass(name: "Actor Solo",  visible: [.actor], matte: false, blackBg: true, fx: false, coverageAlpha: true))
            passes.append(ExportPass(name: "Actor Matte", visible: [.actor], matte: true,  blackBg: true, fx: false))
        }
        // Set: the geometry layer (was "Background").  A clean cutout on black — its
        // holdouts are black-on-black, so no HDR can leak through.  Composited over the
        // Background plate downstream.  Coverage alpha (like Actor) for premultiplied use.
        if present.contains(.set) {
            passes.append(ExportPass(name: "Set Solo",  visible: [.set], matte: false, blackBg: true, fx: false, coverageAlpha: true))
            passes.append(ExportPass(name: "Set Matte", visible: [.set], matte: true,  blackBg: true, fx: false))
        }
        // Background: the "real" backdrop = the HDR environment, with ALL foreground
        // (Set/Actor/MacGuffin) held out as black holes for clean additive compositing.
        // visible:[] makes every object a holdout; blackBg:false keeps the HDR.  Glass
        // (transparent) parts are intentionally NOT held out, so the HDR shows through
        // the station windows.  The feedback/excludeBg leak is handled by the committed
        // post-composite re-stamp in VideoExporter.
        passes.append(ExportPass(name: "Background", visible: [], matte: false, blackBg: false, fx: false))
        if present.contains(.macguffin) {
            passes.append(ExportPass(name: "MacGuffin Solo",  visible: [.macguffin], matte: false, blackBg: true, fx: false))
            passes.append(ExportPass(name: "MacGuffin Matte", visible: [.macguffin], matte: true,  blackBg: true, fx: false))
        }
        if fxPresent {
            // FX-only: all geometry held out, FX on, black background.
            passes.append(ExportPass(name: "FX Solo",  visible: [], matte: false, blackBg: true, fx: true))
            passes.append(ExportPass(name: "FX Matte", visible: [], matte: true,  blackBg: true, fx: true))
        }
        return passes
    }

    /// Number of passes Export All will run for the current scene (for the progress UI).
    func exportAllPassCount() -> Int { exportAllPasses().count }

    func startExportAll(folder: URL, projectName: String, cycleNumber: Int,
                        codec: ExportCodec, fps: ExportFrameRate,
                        exportState: ExportState,
                        onAllComplete: @escaping (Error?) -> Void) {
        let passes = exportAllPasses()

        // Background fields to restore for the project-background passes (Full/Scene).
        let origMode  = backgroundConfig.mode
        let origSolid = backgroundConfig.solidColor
        let nn        = String(format: "%02d", cycleNumber)
        let total     = passes.count

        func runPass(_ i: Int) {
            guard i < passes.count else { onAllComplete(nil); return }
            let pass = passes[i]
            applyExportPass(pass, origMode: origMode, origSolid: origSolid)
            exportState.passIndex   = i + 1
            exportState.passCount   = total
            exportState.passName    = pass.name
            exportState.lastMessage = "Exporting pass \(i + 1)/\(total): \(pass.name)"
            let url = folder.appendingPathComponent("\(projectName).\(nn).\(pass.name).mov")
            startExport(to: url, codec: codec, fps: fps, exportState: exportState,
                        includeFX: pass.fx, keepCoverageAlpha: pass.coverageAlpha) { error in
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
        // Click-to-select: remember where the press started; a release with little
        // motion is a click (pick), more motion is a drag (orbit / translate).
        leftMouseDownLocation = lastMouseLocation
        leftMouseDragged      = false
        // Reset axis lock for the new left-drag gesture.
        dragLockAxis = .none
        dragAccumX   = 0
        dragAccumY   = 0
    }

    override func mouseDragged(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if !leftMouseDragged,
           abs(loc.x - leftMouseDownLocation.x) > clickMoveThreshold ||
           abs(loc.y - leftMouseDownLocation.y) > clickMoveThreshold {
            leftMouseDragged = true
        }
        let dx  = Float(loc.x - lastMouseLocation.x)
        let dy  = Float(loc.y - lastMouseLocation.y)
        lastMouseLocation = loc

        // Locked track: block translation/rotation edits (space-orbit still allowed).
        if !isSpaceDown && activeTrackIsLocked { beepLocked(); return }

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

            let scale = dragScale
            let move: SIMD3<Float>
            switch dragLockAxis {
            case .horizontal: move = viewCamera.rightVector * (dx * scale)
            case .vertical:   move = viewCamera.upVector   * (dy * scale)
            case .none:       return
            }
            translateObject(obj, by: move)
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

            let scale = dragScale
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
                let scale = dragScale
                let d = viewCamera.rightVector * (lockedDx * scale)
                      + viewCamera.upVector    * (lockedDy * scale)
                lightManager.translateSelected(by: d)
            default:
                break
            }

        } else if controlMode == .probe {
            // Probe mode: axis-locked, camera-relative translation of the bake Probe
            // (same feel as Object mode).  viewCamera is the Director in Scene mode,
            // the scene camera otherwise.
            if dragLockAxis == .none {
                dragAccumX += dx
                dragAccumY += dy
                let dist = (dragAccumX * dragAccumX + dragAccumY * dragAccumY).squareRoot()
                guard dist >= dragLockThreshold else { return }
                dragLockAxis = abs(dragAccumX) >= abs(dragAccumY) ? .horizontal : .vertical
            }
            let scale = dragScale
            switch dragLockAxis {
            case .horizontal: moveProbe(by: viewCamera.rightVector * (dx * scale))
            case .vertical:   moveProbe(by: viewCamera.upVector    * (dy * scale))
            case .none:       return
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

    override func mouseUp(with event: NSEvent) {
        // A left drag that translated the selected object/model auto-keyframes it (if
        // enabled); a clean click instead picks the object under the cursor.
        if leftMouseDragged {
            if !isSpaceDown, !timeline.isPlaying,
               (controlMode == .object || controlMode == .model), let ref = currentTrackRef {
                autoKeyframeOnEdit(ref)
            }
            return
        }
        // Skip only while space-orbiting.  Works in Scene mode too: pickObject casts the
        // ray through viewCamera (the Director in Scene mode), so a click selects the
        // object under the cursor and makes it the current model.
        guard !isSpaceDown else { return }
        let pt = convert(event.locationInWindow, from: nil)
        if let hit = pickObject(at: pt) {
            if controlMode == .probe {
                // Probe mode: a click drops the Probe onto the clicked surface point and
                // STAYS in Probe mode (no selection) — fast positioning.
                probeConfig.isVisible = true
                moveProbe(by: hit.point - probeConfig.position)
            } else {
                // Option-click isolates the individual part under the cursor; a plain click
                // selects the whole multi-part model.
                selectByPick(objectIndex: hit.index, isolatePart: event.modifierFlags.contains(.option))
            }
        }
    }

    // MARK: - Click-to-select picking

    /// Returns the index of the nearest visible object whose mesh the click ray hits,
    /// or nil for empty space.  Ray-vs-mesh (precise) with a bounding-sphere broad phase.
    private func pickObject(at point: NSPoint) -> (index: Int, point: SIMD3<Float>)? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        // Screen point → NDC (AppKit origin is bottom-left, y up — matches Metal NDC y).
        let ndcX = Float(2 * point.x / bounds.width  - 1)
        let ndcY = Float(2 * point.y / bounds.height - 1)
        let invVP = simd_inverse(viewCamera.viewProjectionMatrix)
        func unproject(_ z: Float) -> SIMD3<Float> {
            let p = invVP * SIMD4<Float>(ndcX, ndcY, z, 1)
            return SIMD3<Float>(p.x, p.y, p.z) / p.w
        }
        let rayOrigin = viewCamera.eyePosition
        let near = unproject(0), far = unproject(1)
        let rayDir = simd_normalize(far - near)

        var bestIndex: Int? = nil
        var bestDist = Float.greatestFiniteMagnitude

        for (i, obj) in sceneManager.objects.enumerated() {
            guard obj.isVisible, !obj.isEnvelope, !obj.cpuPositions.isEmpty else { continue }
            let world = worldMatrix(for: obj)
            // Broad phase — skip objects whose world bounding sphere the ray misses.
            let centerW = world * SIMD4<Float>(obj.boundingCenter, 1)
            let center  = SIMD3<Float>(centerW.x, centerW.y, centerW.z)
            let scale   = max(simd_length(SIMD3<Float>(world.columns.0.x, world.columns.0.y, world.columns.0.z)),
                              max(simd_length(SIMD3<Float>(world.columns.1.x, world.columns.1.y, world.columns.1.z)),
                                  simd_length(SIMD3<Float>(world.columns.2.x, world.columns.2.y, world.columns.2.z))))
            guard rayHitsSphere(origin: rayOrigin, dir: rayDir, center: center,
                                radius: obj.boundingRadius * scale + 1e-4) else { continue }
            // Narrow phase — exact ray-vs-mesh in the object's local space.
            if let t = rayMeshDistance(obj, world: world, rayOrigin: rayOrigin, rayDir: rayDir),
               t < bestDist {
                bestDist  = t
                bestIndex = i
            }
        }
        guard let idx = bestIndex else { return nil }
        // World-space hit point along the (normalized) ray — used by probe click-place.
        return (idx, rayOrigin + rayDir * bestDist)
    }

    /// The rendered world transform of an object (group multiplier composed in when
    /// grouped) — mirrors SceneManager.worldOrbitAnchor's posMat.
    private func worldMatrix(for obj: SceneObject) -> matrix_float4x4 {
        if let gid = obj.groupID, let groupMat = sceneManager.groupTransforms[gid] {
            return groupMat * obj.transform
        }
        return obj.transform
    }

    private func rayHitsSphere(origin: SIMD3<Float>, dir: SIMD3<Float>,
                               center: SIMD3<Float>, radius: Float) -> Bool {
        let oc = origin - center
        let b  = simd_dot(oc, dir)
        let c  = simd_dot(oc, oc) - radius * radius
        // Hit if the discriminant is non-negative and the sphere isn't fully behind.
        return (b * b - c) >= 0 && (c <= 0 || b <= 0)
    }

    /// Nearest ray-vs-triangle distance (world units) for the object's mesh, or nil.
    /// The ray is transformed into the object's local space; the hit point is mapped
    /// back to world for a comparable distance.
    private func rayMeshDistance(_ obj: SceneObject, world: matrix_float4x4,
                                 rayOrigin: SIMD3<Float>, rayDir: SIMD3<Float>) -> Float? {
        let inv = simd_inverse(world)
        let o4  = inv * SIMD4<Float>(rayOrigin, 1)
        let d4  = inv * SIMD4<Float>(rayDir, 0)
        let lo  = SIMD3<Float>(o4.x, o4.y, o4.z)
        let ld  = SIMD3<Float>(d4.x, d4.y, d4.z)   // not normalised (local scale baked in)

        let pos = obj.cpuPositions
        let idx = obj.cpuIndices
        var best: Float? = nil
        let eps: Float = 1e-7
        func vert(_ k: UInt32) -> SIMD3<Float> {
            let b = Int(k) * 3
            return SIMD3<Float>(pos[b], pos[b + 1], pos[b + 2])
        }
        var t = 0
        while t + 2 < idx.count {
            let v0 = vert(idx[t]), v1 = vert(idx[t + 1]), v2 = vert(idx[t + 2])
            t += 3
            // Möller–Trumbore (local space).
            let e1 = v1 - v0, e2 = v2 - v0
            let p  = simd_cross(ld, e2)
            let det = simd_dot(e1, p)
            if abs(det) < eps { continue }
            let invDet = 1 / det
            let tvec = lo - v0
            let u = simd_dot(tvec, p) * invDet
            if u < 0 || u > 1 { continue }
            let q = simd_cross(tvec, e1)
            let v = simd_dot(ld, q) * invDet
            if v < 0 || u + v > 1 { continue }
            let tHit = simd_dot(e2, q) * invDet
            if tHit <= eps { continue }
            // World distance of this local hit.
            let localHit = lo + ld * tHit
            let worldHit = world * SIMD4<Float>(localHit, 1)
            let dist = simd_length(SIMD3<Float>(worldHit.x, worldHit.y, worldHit.z) - rayOrigin)
            if best == nil || dist < best! { best = dist }
        }
        return best
    }

    /// Applies a picked object to the selection, driving the same path the keystroke
    /// cycle and Timeline-row click use (so the dropdowns / HUD / grid all follow).
    private func selectByPick(objectIndex i: Int, isolatePart: Bool) {
        guard i >= 0, i < sceneManager.objects.count else { return }
        // Plain click on a glued member selects the whole glued unit (its envelope), so
        // the assembly moves as one; Option-click drills past it to the part/model under
        // the cursor (the behavior below).
        if !isolatePart, let env = envelopeFor(objectIndex: i) {
            sceneManager.selectedIndex = env
            setControlMode(.object)
            return
        }
        let obj = sceneManager.objects[i]
        if let gid = obj.groupID, !isolatePart {
            // Plain click on a multi-part model → select it as a unit in Model mode.
            if let rootIdx = sceneManager.objects.firstIndex(where: { $0.groupID == gid }) {
                sceneManager.selectedIndex = rootIdx
            }
            setControlMode(.model)
        } else {
            // Standalone object, glued member, or (Option) the isolated part under the
            // cursor → Object mode on exactly that object.
            sceneManager.selectedIndex = i
            setControlMode(.object)
        }
    }

    /// The envelope (glued unit) that object `i` belongs to, or nil if it isn't glued.
    /// Handles glued GROUP members (via `groupEnvelopeParent`) and directly-parented
    /// members (nearest `isEnvelope` ancestor up the `parentIndex` chain).
    private func envelopeFor(objectIndex i: Int) -> Int? {
        let objs = sceneManager.objects
        guard i >= 0, i < objs.count else { return nil }
        if let gid = objs[i].groupID, let link = sceneManager.groupEnvelopeParent[gid] {
            return link.env
        }
        var p = objs[i].parentIndex
        while let pp = p, pp >= 0, pp < objs.count {
            if objs[pp].isEnvelope { return pp }
            p = objs[pp].parentIndex
        }
        return nil
    }

    // MARK: - Right Mouse Input

    override func rightMouseDown(with event: NSEvent) {
        lastMouseLocation = convert(event.locationInWindow, from: nil)
        rightDragMoved    = false
        // Right drag is always free (no axis lock) — nothing to reset.
    }

    override func rightMouseUp(with event: NSEvent) {
        // A right-drag rotated the active entity — auto-keyframe it (if enabled).
        guard rightDragMoved, !sceneModeActive, !timeline.isPlaying, let ref = currentTrackRef else { return }
        autoKeyframeOnEdit(ref)
    }

    override func rightMouseDragged(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        rightDragMoved = true
        let dx  = Float(loc.x - lastMouseLocation.x)
        let dy  = Float(loc.y - lastMouseLocation.y)
        lastMouseLocation = loc

        if activeTrackIsLocked { beepLocked(); return }   // locked track — no rotate

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

        case .probe:
            break   // the Probe is a point — nothing to rotate
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

        // Locked track: block depth/scale edits (Director/Probe view nav still allowed).
        if activeTrackIsLocked { beepLocked(); return }

        // Model mode: scale or push/pull the whole group.
        if controlMode == .model, !timeline.isPlaying {
            let parts = groupParts()
            if !parts.isEmpty {
                if event.modifierFlags.contains(.option) {
                    let factor = exp(delta * 0.02)
                    scaleGroup(parts, by: factor, around: groupCenter(parts))
                } else {
                    let move = delta * viewCamera.distance * 0.05
                    translateGroup(parts, by: dollyDelta(towardWorld: groupCenter(parts), by: move))
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
            let li   = lightManager.selectedIndex
            guard li < lightManager.lights.count else { return }
            lightManager.translateSelected(by: dollyDelta(towardWorld: lightManager.lights[li].position, by: move))
            return
        }

        // Probe mode: scroll dollies the Probe toward / away along the eye→probe ray,
        // so it stays locked to its on-screen position (no perspective drift / jump).
        if controlMode == .probe, !timeline.isPlaying {
            let move = delta * viewCamera.distance * 0.05
            moveProbe(by: dollyDelta(towardWorld: probeConfig.position, by: move))
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
            // Plain scroll → dolly along the eye→object ray, distance-clamped so it
            // stays on target and never crosses the eye or deviates at the ±100 box.
            let move = delta * viewCamera.distance * 0.05
            let d    = dollyDelta(towardWorld: objectWorldOrigin(obj), by: move)
            translateObject(obj, by: d)
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
        case .director, .probe:
            // The Director POV / Probe have no keyframe track.
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
        // Director is the active view in Scene mode, so dragScale is director-based
        // here — pans track the cursor at any distance / FOV (drag-sensitivity applies).
        let s = dragScale
        camera.translateTarget(by: director.rightVector * (dx * s) + director.upVector * (dy * s))
    }

    private func dollySceneCameraAlongDirector(delta: Float) {
        camera.translateTarget(by: director.forwardVector * (delta * 0.05 * max(director.distance, 1.0)))
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
        if activeTrackIsLocked { beepLocked(); return }   // locked track — no arrow-key edits

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
            let translateDelta = (right * dxF + up * dyF) * translateStepWorld
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
                let d = (right * dxF + up * dyF) * translateStepWorld
                translateObject(obj, by: d)
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
                translateGroup(parts, by: (right * dxF + up * dyF) * translateStepWorld)
            }

        case .probe:
            // Camera-relative move in the screen plane; Shift+↑/↓ dollies along the
            // eye→probe ray (distance-clamped, no eye-cross/drift) since the Probe can't rotate.
            if shift {
                moveProbe(by: dollyDelta(towardWorld: probeConfig.position, by: dyF * translateStepWorld))
            } else {
                moveProbe(by: (right * dxF + up * dyF) * translateStepWorld)
            }
        }
        if !sceneModeActive, let ref = currentTrackRef { autoKeyframeOnEdit(ref) }
    }

    /// `+` / `−` keys: depth movement along camera-forward, or scale (with Option).
    /// Camera mode is unaffected by Option.
    private func applyDepthKey(positive: Bool, optionDown: Bool) {
        if activeTrackIsLocked { beepLocked(); return }   // locked track — no +/- depth/scale edits

        let sign: Float = positive ? 1 : -1

        switch controlMode {
        case .camera:
            // +/− changes focal length (FOV). Scroll wheel handles dolly.
            if camera.lensZoom(delta: sign * zoomStep / 0.05) { LimitReporter.report("Lens FOV") }

        case .director:
            // Director POV (Scene mode only): +/− dollies the viewpoint in / out,
            // matching the scroll wheel ("get closer to the part").  FOV is on ⌘+/⌘−.
            director.dolly(delta: sign * zoomStep / 0.05)

        case .light:
            let li = lightManager.selectedIndex
            guard li < lightManager.lights.count else { return }
            lightManager.translateSelected(by: dollyDelta(towardWorld: lightManager.lights[li].position,
                                                          by: sign * translateStepWorld * 2))

        case .object:
            guard let obj = sceneManager.selectedObject else { return }
            if optionDown {
                let factor: Float = positive ? scaleStep : 1.0 / scaleStep
                let sv = SIMD4<Float>(factor, factor, factor, 1)
                obj.transform.columns.0 *= sv
                obj.transform.columns.1 *= sv
                obj.transform.columns.2 *= sv
            } else {
                // Dolly along the eye→object ray, distance-clamped (no eye-cross / drift).
                let d = dollyDelta(towardWorld: objectWorldOrigin(obj), by: sign * translateStepWorld)
                translateObject(obj, by: d)
            }
            syncLocalTransform(obj)

        case .model:
            let parts = groupParts()
            guard !parts.isEmpty else { return }
            if optionDown {
                let factor: Float = positive ? scaleStep : 1.0 / scaleStep
                scaleGroup(parts, by: factor, around: groupCenter(parts))
            } else {
                translateGroup(parts, by: dollyDelta(towardWorld: groupCenter(parts), by: sign * translateStepWorld))
            }

        case .probe:
            // +/− dollies the Probe along the eye→probe ray, distance-clamped.
            moveProbe(by: dollyDelta(towardWorld: probeConfig.position, by: sign * translateStepWorld))
        }
        if !sceneModeActive, let ref = currentTrackRef { autoKeyframeOnEdit(ref) }
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
        static let t:        UInt16 = 17   // T — Probe mode (move the bake Probe)
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
    private let lightStep:     Float = Float.pi / 36.0  // 5° per key (light azimuth / elevation)
    private let rotStep:       Float = Float.pi / 36.0  // 5° per key (object/camera rotation)
    private let intensityStep: Float = 0.1
    private let zoomStep:      Float = 0.1              // fraction of current distance per key
    private let scaleStep:     Float = 1.05             // Option+=/− scales object by ±5% per key
    /// World units per screen point at the view's focus distance, accounting for FOV
    /// (focal length).  Base for drag / arrow / depth-key sensitivity so movement
    /// tracks on-screen size whether you're zoomed in close on a small object or
    /// pulled back.  viewCamera is the Director in Scene mode, the scene camera otherwise.
    private var worldUnitsPerPoint: Float {
        let h = max(Float(bounds.height), 1)
        return 2 * viewCamera.distance * tan(viewCamera.fovYRadians / 2) / h
    }
    /// Mouse-drag move scale — 1:1 with the cursor at the default sensitivity of 1.0;
    /// the user-tunable Settings multiplier scales it.
    private var dragScale: Float {
        worldUnitsPerPoint * Float(AppSettings.shared.dragSensitivity)
    }
    /// Per-press translation step for arrow / +- depth keys — 1 screen point per press
    /// at the default sensitivity of 1.0 (very fine), scaled by the Settings multiplier.
    /// Hold the key to repeat for larger moves.
    private var translateStepWorld: Float {
        worldUnitsPerPoint * Float(AppSettings.shared.arrowSensitivity)
    }

    override func keyDown(with event: NSEvent) {
        let kc = event.keyCode

        // ── Return key — commit active keyframe edit in Timeline Editor ─────────
        if kc == KC.returnKey, !event.isARepeat {
            onEnterKey?()
            return
        }

        // ── Insert key — stamp a keyframe for the current mode / selection ──────
        if kc == KC.insert, !event.isARepeat {
            if activeTrackIsLocked { beepLocked(); return }   // locked track — no keyframe stamp
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
            case .director, .probe:
                break   // Director POV / Probe have no keyframes
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
                if activeTrackIsLocked { beepLocked(); return }   // locked track — no keyframe stamp
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
                case .director, .probe:
                    break   // Director POV / Probe have no keyframes
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
                // C — Camera mode.  A second press while already in Camera mode cycles
                // to the next camera (wrap-around), like O (objects) and L (lights).
                // (Director POV is now reached with D.)  In Scene mode this targets the
                // scene camera for posing while the view stays through the Director.
                if controlMode == .camera, cameras.count > 1 {
                    activateCamera((activeCameraIndex + 1) % cameras.count)
                    syncCameraListToPanel()
                    refreshCameraPanelState()   // dropdown + pose follow the new camera
                } else {
                    controlMode = .camera
                }
                syncOverlayState()
                onControlModeChanged?(.camera(activeCameraIndex))
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

            case KC.t:
                // Shift+T (Scene mode) — fly the Director to the Probe, looking at it.
                if event.modifierFlags.contains(.shift) {
                    if sceneModeActive { snapDirectorToProbe() }
                    return
                }
                if controlMode == .probe {
                    // Already in Probe mode — for a DUAL mark (camera eye+aim,
                    // light pos+aim) T flips the Probe between the primary point
                    // and the target point, so arrow / drag / wheel edits move
                    // whichever one the gizmo now sits on.  (Single mark: no-op.)
                    if let i = editingMarkIndex, probeConfig.marks[i].secondaryPosition != nil {
                        editingMarkTargetPoint.toggle()
                        probeConfig.position = editingMarkTargetPoint
                            ? (probeConfig.marks[i].secondaryPosition ?? probeConfig.marks[i].position)
                            : probeConfig.marks[i].position
                        syncOverlayState()
                        needsDisplay = true
                    }
                    return
                }
                // T — Probe mode: move the bake Probe with drag / arrow keys / wheel.
                // Reveal the gizmo so it's visible while positioning.  The Probe isn't
                // a timeline track, so no onControlModeChanged broadcast (like Director).
                controlMode = .probe
                probeConfig.isVisible = true
                editingMarkTargetPoint = false
                // If a mark is selected, sit the Probe on it so edits start from
                // its location (Timeline-click selection doesn't recall the Probe).
                if let i = editingMarkIndex { probeConfig.position = probeConfig.marks[i].position }
                syncOverlayState()
                return

            case KC.d:
                // D — go to the Director POV.  One-way (never toggles out), since the
                // Director only exists in Scene mode.  Not in Scene mode → enter it +
                // Director (auto-fit on first use, matching S).  In Scene mode but not
                // yet the Director → switch to it.  Already the Director → ignored.
                // Director has no timeline lane, so onControlModeChanged isn't sent.
                if !sceneModeActive {
                    sceneModeActive = true
                    if !directorEverFit { autoFitDirector() }
                    controlMode = .director
                    syncOverlayState()
                } else if controlMode != .director {
                    controlMode = .director
                    syncOverlayState()
                }
                return

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
                    onControlModeChanged?(.camera(activeCameraIndex))
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
            // ⌘+ in Scene mode narrows the Director's FOV (zoom-in lens).  Plain +
            // dollies the Director in (see applyDepthKey .director).
            if sceneModeActive && event.modifierFlags.contains(.command) {
                if director.lensZoom(delta: zoomStep / 0.05) { LimitReporter.report("Director FOV") }
            } else {
                applyDepthKey(positive: true, optionDown: event.modifierFlags.contains(.option))
            }

        // ── Minus / KP− ───────────────────────────────────────────────────────
        case KC.kpMinus, KC.regMinus:
            // ⌘− in Scene mode widens the Director's FOV (zoom-out lens).  Plain −
            // dollies the Director out (see applyDepthKey .director).
            if sceneModeActive && event.modifierFlags.contains(.command) {
                if director.lensZoom(delta: -(zoomStep / 0.05)) { LimitReporter.report("Director FOV") }
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

        // Load all model files (project files ignored in mixed drops).  The same file
        // may be added more than once; load failures surface their own error.
        var anyLoaded = false
        for url in modelURLs {
            if addModelToScene(url: url) == .added { anyLoaded = true }
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
