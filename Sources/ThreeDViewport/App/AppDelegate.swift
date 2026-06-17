import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import simd

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate,
                         NSMenuItemValidation {

    var window: NSWindow?
    var viewportView: ViewportView?
    let exportState = ExportState()

    // Export Progress panel — shown while an export runs (main window minimized).
    private var exportProgressPanel: NSPanel?

    // Phase 7: Floating lights & background inspector panel.
    private var lightsPanel: NSPanel?

    // Feedback delay-line panel.
    private var feedbackPanel: NSPanel?

    // Brightness / contrast color grade panel.
    private var colorGradePanel: NSPanel?
    private var atmospherePanel: NSPanel?

    // Camera keyframe inspector panel.
    private var cameraPanel: NSPanel?

    // Model inspector panel.
    private var modelInspectorPanel: NSPanel?
    private var modelInspectorState: ModelInspectorState?

    // Effects grid window (per-object visible / holdout / class).
    private var effectsGridWC:    EffectsGridWindowController?
    private var effectsGridState: EffectsGridState?

    // Bake probe inspector panel.
    private var probeInspectorPanel: NSPanel?

    // Last colour chosen in the Mark Position prompt — defaults the next mark's
    // colour so a run of related marks can share one colour.
    private var lastMarkColor: NSColor = .systemYellow

    // Orbit Path Animator helper panel.
    private var orbitPathPanel: NSPanel?

    // Linear Path Animator helper panel.
    private var linearPathPanel: NSPanel?

    // Curve Path Animator helper panel.
    private var curvePathPanel: NSPanel?

    // Spin Animator helper panel.
    private var spinPanel: NSPanel?

    // Gait (walk) Animator helper panel.
    private var gaitPanel: NSPanel?

    // Global settings panel.
    private var settingsPanel: NSPanel?

    // Edit > Remove submenu — repopulated dynamically by NSMenuDelegate.
    private var removeSubmenu: NSMenu?
    // Marks menu — Go To / Delete submenus repopulated dynamically by NSMenuDelegate.
    private var goToMarkSubmenu:  NSMenu?
    private var deleteMarkSubmenu: NSMenu?

    // Timeline editor (AppKit canvas panel).
    private var timelineEditorWC: TimelineEditorWindowController?

    // ── Keyframe edit-mode snapshot ───────────────────────────────────────────
    // Stores the state that existed when the user entered edit mode, so we can
    // restore it on Escape / cancel.
    private enum KFEditSnapshot {
        case object(index: Int, savedTransform: matrix_float4x4, kfTime: Double)
        case camera(yaw: Float, pitch: Float, distance: Float,
                    target: SIMD3<Float>,
                    followTargetName: String?,   // nil = was a free keyframe
                    kfTime: Double)
        case light(index: Int, savedIntensity: Float, savedColor: SIMD3<Float>,
                   savedTarget: SIMD3<Float>, savedPosition: SIMD3<Float>, kfTime: Double)
        case group(gid: Int, savedTransform: matrix_float4x4, kfTime: Double)
        // Atmosphere: only the time is needed — the panel follows the playhead, so
        // commit re-stamps the edited panel value and cancel re-syncs from the track.
        case fog(kfTime: Double)
        case particles(index: Int, kfTime: Double)
    }
    private var kfEditSnapshot: KFEditSnapshot? = nil

    // Explicitly-tracked main window frame.
    // Updated by windowDidMove / windowDidResize so we always have the latest
    // user-positioned frame, even if the NSWindow frame property lags.
    private var trackedMainWindowFrame: NSRect?

    // Frame we want the main window to be at after the next sheet dismissal.
    // Set by applyWindowLayout so that windowDidEndSheet can re-apply the
    // saved position after macOS's sheet-dismissal animation moves the window.
    // Cleared by windowWillBeginSheet so stale values don't fire on unrelated sheets.
    private var pendingMainWindowFrame: NSRect?

    // Tracks which secondary windows were hidden when the main window miniaturized.
    private var panelsHiddenByMiniaturize: Set<String> = []

    // Tracks the last saved/opened project URL for ⌘S "save in place".
    private var currentProjectURL: URL?

    // When the launch or New-Project flow loaded `template.3dvp`, this holds the
    // pre-filled name ("Project N") for the next Save-As panel. Cleared whenever
    // the project is actually saved or a different project is opened.
    private var suggestedProjectName: String?

    // Finder "open document" handling.  `hasFinishedLaunching` distinguishes a
    // file that launched the app (defer until the window exists) from one opened
    // while the app is already running.  `pendingOpenURL` holds a .3dvp delivered
    // during launch, to be loaded instead of the template.
    private var hasFinishedLaunching = false
    private var pendingOpenURL: URL?

    // True whenever the project has unsaved changes.
    private var isDirty: Bool = false

    // Set when the user clicks "Save" in the Quit-time prompt for a project
    // without a URL.  The saveProjectAs sheet completion checks this flag and
    // re-issues termination after a successful save.  Without it, the sheet
    // would close and the user would have to invoke Quit a second time.
    private var pendingQuitAfterSave: Bool = false

    // Combine subscriptions that set isDirty when any Observable setting changes.
    private var settingsCancellables = Set<AnyCancellable>()
    /// Per-emitter dirty subscriptions, rebuilt whenever the emitter list changes.
    private var particleEmitterCancellables = Set<AnyCancellable>()
    /// Panel emitter-selection → timeline lane highlight (lives with the editor).
    private var particleSelectionCancellable: AnyCancellable?

    private let timelinePanelHeight: CGFloat = 80

    // Bounding box for the scene HUD overlay in the top-left of the viewport.
    // The HUD itself shrinks to fit its content; these dimensions just set the
    // upper limit (and the hit-testing-disabled SwiftUI passes clicks through to
    // Metal in the empty area).  Width is generous so 50-char .glb part names
    // don't get middle-truncated by a cramped NSHostingView frame.
    private let overlayHeight: CGFloat = 270
    private let overlayWidth:  CGFloat = 1100

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[DEBUG] AppDelegate: applicationDidFinishLaunching")

        // Apply the persisted diagnostic-logging toggle (AppLog + per-frame perf).
        AppSettings.shared.applyLoggingFlags()

        // Opt-in performance logging: launch with `--perf-log` to force the per-frame
        // CPU/GPU/FPS stats on even when the persisted toggle is off.
        if CommandLine.arguments.contains("--perf-log") {
            Renderer.perfLoggingEnabled = true
            AppLog.enabled = true
            print("[PERF] performance logging enabled via --perf-log")
        }

        let windowWidth:    CGFloat = 1920
        let viewportHeight: CGFloat = 1080
        let windowHeight:   CGFloat = viewportHeight + timelinePanelHeight

        let rect = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)

        let w = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window = w
        w.title        = "ThreeDViewport"
        w.delegate     = self
        // Disable macOS's built-in window-state restoration so it never
        // overrides our project-file-driven window layout.  Without this,
        // macOS animates the window back to its OS-remembered position after
        // every applyWindowLayout setFrame call.
        w.isRestorable = false
        w.center()

        // ── Container ─────────────────────────────────────────────────────────
        let container = NSView(frame: rect)
        container.autoresizingMask = [.width, .height]

        // ── ViewportView (top 1920×1080 — the recordable Metal area) ──────────
        let viewportFrame = NSRect(x: 0,
                                   y: timelinePanelHeight,
                                   width: windowWidth,
                                   height: viewportHeight)
        let viewport = ViewportView(frame: viewportFrame)
        viewport.autoresizingMask = [.width, .height]
        viewportView = viewport

        // Wire drag-and-drop model drops → markDirty + updateWindowHeight.
        viewport.onModelDropped = { [weak self] in
            self?.markDirty()
            self?.timelineEditorWC?.updateWindowHeight()
        }
        // Wire drag-and-drop project drops → dirty-check then load.
        viewport.onDropProjectFile = { [weak self] url in
            self?.handleDroppedProject(url)
        }
        // Highlight a freshly-stamped keyframe in the Timeline Editor so the
        // user can immediately nudge it with F / B.  No-op when the editor
        // isn't open (timelineEditorWC == nil) or hasn't built a lane yet.
        viewport.onKeyframeStamped = { [weak self, weak viewport] ref in
            guard let editor = self?.timelineEditorWC?.editorView,
                  let time = viewport?.timeline.currentTime else { return }
            editor.selectKeyframe(ref: ref, atTime: time)
        }
        viewport.onKeyframesCleared = { [weak self] in
            self?.timelineEditorWC?.editorView.needsDisplay = true
            self?.markDirty()
        }
        viewport.onToggleMarks = { [weak self] in self?.toggleMarks(self as Any) }
        viewport.onCycleMark   = { [weak self] step in self?.cycleMark(by: step) }
        viewport.onDeleteMark  = { [weak self] in self?.deleteSelectedMark() }
        viewport.onCameraEdited = { [weak self] in self?.markDirty() }
        viewport.onProbeEdited  = { [weak self] in self?.markDirty() }
        viewport.sceneManager.onSelectionChanged = { [weak self, weak viewport] in
            guard let self, let viewport else { return }
            let selected = viewport.sceneManager.selectedObject
            let targets: [SceneObject]
            if let gid = selected?.groupID {
                targets = viewport.sceneManager.objects(inGroup: gid)
            } else if let obj = selected {
                targets = [obj]
            } else {
                targets = []
            }
            self.modelInspectorState?.update(targets: targets,
                                             displayName: self.timelineDisplayName(for: targets))
            // Refresh the Effects grid's rows + highlight (fires on object-array
            // changes too, so add/remove/load all keep the grid current).
            self.effectsGridState?.sync()
        }

        // Viewport / timeline selection change → highlight the timeline lane AND
        // keep any open Path Animator panel's Target in step with the selection.
        // Centralised here (rather than in showTimelineEditor) so the sync works even
        // before the timeline editor has been opened.
        viewport.onControlModeChanged = { [weak self] ref in
            self?.timelineEditorWC?.editorView.selectTrack(ref)
            self?.syncPathAnimatorPanelsToSelection(ref)
        }

        if viewport.device == nil {
            print("[DEBUG] AppDelegate: ViewportView MTLDevice is nil — Metal not available")
        }

        // ── Timeline panel (bottom 80pt) ──────────────────────────────────────
        let panelFrame = NSRect(x: 0, y: 0, width: windowWidth, height: timelinePanelHeight)

        let timelineView = TimelinePanel(
            timeline:    viewport.timeline,
            exportState: exportState,
            onAddKeyframe: { [weak viewport] in
                viewport?.addKeyframeAtCurrentTime()
            },
            onExport: { [weak self] in
                self?.showExportPanel()
            },
            onSetDuration: { [weak self] newDuration in
                self?.changeTimelineDuration(to: newDuration)
            }
        )

        let hostingView = NSHostingView(rootView: timelineView)
        hostingView.frame = panelFrame
        hostingView.autoresizingMask = [.width, .maxYMargin]

        // ── Scene HUD overlay (top-left of viewport, Phase 6) ─────────────────
        // Positioned in container coordinates.  The overlay covers only a small
        // corner so the rest of the Metal area remains fully interactive.
        // autoresizingMask keeps it anchored to the top-left as the window resizes.
        let overlayY = timelinePanelHeight + viewportHeight - overlayHeight
        let overlayFrame = NSRect(x: 0, y: overlayY, width: overlayWidth, height: overlayHeight)

        let overlayView = NSHostingView(
            rootView: SceneOverlayView(state: viewport.overlayState)
        )
        overlayView.frame = overlayFrame
        overlayView.autoresizingMask = [.maxXMargin, .minYMargin]
        overlayView.layer?.isOpaque = false

        // ── Assemble ──────────────────────────────────────────────────────────
        container.addSubview(viewport)
        container.addSubview(hostingView)
        container.addSubview(overlayView)   // on top of Metal view
        w.contentView = container
        w.makeKeyAndOrderFront(nil)

        setupMenu()

        print("[DEBUG] AppDelegate: window ready — viewport="
            + String(Int(windowWidth)) + "x" + String(Int(viewportHeight))
            + " timeline=" + String(Int(windowWidth)) + "x" + String(Int(timelinePanelHeight)))

        subscribeToSettingsChanges(viewport)

        hasFinishedLaunching = true
        // If a .3dvp launched the app (Finder double-click / Open With), load it
        // instead of the template.  Deferred a tick so the open event — usually
        // delivered right after this method returns — has set pendingOpenURL first.
        // Either ordering is safe: if the event arrives later, application(open:)
        // loads it over the template.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let url = self.pendingOpenURL {
                self.pendingOpenURL = nil
                self.loadProject(from: url)
            } else {
                self.applyTemplateIfPresent()
            }
        }
    }

    /// Finder double-click / "Open With" / `open file.3dvp` → load the project.
    /// Only the first .3dvp is used (single-document app); extras are ignored.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension.lowercased() == "3dvp" }) else { return }
        if hasFinishedLaunching {
            handleDroppedProject(url)   // running: prompt on unsaved changes, then load
        } else {
            pendingOpenURL = url        // launching: the deferred launch step loads it
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard isDirty else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText     = "Save project before quitting?"
        alert.informativeText = "Your unsaved changes will be lost if you don't save."
        alert.addButton(withTitle: "Save")        // first  (.alertFirstButtonReturn)
        alert.addButton(withTitle: "Don't Save")  // second
        alert.addButton(withTitle: "Cancel")      // third  (.alertThirdButtonReturn)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // Save in place if we have a URL; otherwise show Save As (cancels this quit)
            if let url = currentProjectURL, let viewport = viewportView {
                do {
                    try ProjectFile.save(to: url, viewport: viewport,
                                         windowLayout: currentWindowLayout())
                    isDirty = false
                    return .terminateNow
                } catch {
                    showErrorAlert(message: "Could not save project",
                                   detail: error.localizedDescription)
                    return .terminateCancel
                }
            } else {
                // No URL yet — show Save As.  Flag the pending quit so the
                // sheet's completion can re-issue termination once the save
                // succeeds, sparing the user a second Quit invocation.
                pendingQuitAfterSave = true
                saveProjectAs(self)
                return .terminateCancel
            }
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    /// When this app instance reactivates, re-check the system pasteboard so the
    /// coordinate Paste icons light up after a *different* instance copied (the
    /// pasteboard has no cross-process change notification — see CoordinateClipboard).
    func applicationDidBecomeActive(_ notification: Notification) {
        viewportView?.coordinateClipboard.refreshFromPasteboard()
    }

    // MARK: - Window layout helpers

    /// Collects the current position and size of every managed window/panel.
    private func currentWindowLayout() -> WindowLayoutData {
        var layout = WindowLayoutData()
        // Prefer the delegate-tracked frame (updated on every move/resize) over
        // reading window.frame directly, which can return a stale value in some
        // macOS edge cases (e.g. right after sheet dismissal).
        let trackedF = trackedMainWindowFrame
        let liveF    = window?.frame
        let f = trackedF ?? liveF

        if let f = f {
            layout.mainWindow = WindowFrameData(x: f.origin.x, y: f.origin.y,
                                                w: f.size.width, h: f.size.height)
        }
        if let wc = timelineEditorWC, wc.window?.isVisible == true,
           let f = wc.window?.frame {
            layout.timelineEditor = WindowFrameData(x: f.origin.x, y: f.origin.y,
                                                    w: f.size.width, h: f.size.height)
        }
        if let wc = effectsGridWC, wc.window?.isVisible == true,
           let f = wc.window?.frame {
            layout.effectsGrid = WindowFrameData(x: f.origin.x, y: f.origin.y,
                                                 w: f.size.width, h: f.size.height)
        }
        if let panel = lightsPanel, panel.isVisible {
            let f = panel.frame
            layout.lightsPanel = WindowFrameData(x: f.origin.x, y: f.origin.y,
                                                 w: f.size.width, h: f.size.height)
        }
        if let panel = feedbackPanel, panel.isVisible {
            let f = panel.frame
            layout.feedbackPanel = WindowFrameData(x: f.origin.x, y: f.origin.y,
                                                   w: f.size.width, h: f.size.height)
        }
        if let panel = colorGradePanel, panel.isVisible {
            let f = panel.frame
            layout.colorGradePanel = WindowFrameData(x: f.origin.x, y: f.origin.y,
                                                     w: f.size.width, h: f.size.height)
        }
        if let panel = cameraPanel, panel.isVisible {
            let f = panel.frame
            layout.cameraPanel = WindowFrameData(x: f.origin.x, y: f.origin.y,
                                                 w: f.size.width, h: f.size.height)
        }
        if let panel = modelInspectorPanel, panel.isVisible {
            let f = panel.frame
            layout.modelInspectorPanel = WindowFrameData(x: f.origin.x, y: f.origin.y,
                                                         w: f.size.width, h: f.size.height)
        }
        if let panel = atmospherePanel, panel.isVisible {
            let f = panel.frame
            layout.atmospherePanel = WindowFrameData(x: f.origin.x, y: f.origin.y,
                                                     w: f.size.width, h: f.size.height)
        }
        if let panel = probeInspectorPanel, panel.isVisible {
            let f = panel.frame
            layout.probeInspectorPanel = WindowFrameData(x: f.origin.x, y: f.origin.y,
                                                         w: f.size.width, h: f.size.height)
        }
        // Path Animator panels.
        func frameIfVisible(_ p: NSPanel?) -> WindowFrameData? {
            guard let p = p, p.isVisible else { return nil }
            let f = p.frame
            return WindowFrameData(x: f.origin.x, y: f.origin.y, w: f.size.width, h: f.size.height)
        }
        layout.spinPanel   = frameIfVisible(spinPanel)
        layout.orbitPanel  = frameIfVisible(orbitPathPanel)
        layout.linearPanel = frameIfVisible(linearPathPanel)
        layout.curvePanel  = frameIfVisible(curvePathPanel)
        layout.gaitPanel   = frameIfVisible(gaitPanel)
        // Atmosphere section expand/collapse (saved regardless of panel visibility).
        if let vp = viewportView {
            layout.atmosphereFogExpanded      = vp.atmospherePanelState.fogExpanded
            layout.atmosphereWeatherExpanded  = vp.atmospherePanelState.weatherExpanded
            layout.atmosphereAdvancedExpanded = vp.atmospherePanelState.advancedExpanded
        }
        return layout
    }

    /// Restores window/panel positions from a saved layout.
    private func applyWindowLayout(_ layout: WindowLayoutData) {
        // Main window — only restore if the saved frame is non-zero (older project files
        // that pre-date the window-layout feature decode a default WindowFrameData with
        // all-zero fields; applying that would collapse the window to zero size).
        let mf = layout.mainWindow
        if mf.w > 0 && mf.h > 0 {
            let restoredFrame = NSRect(x: mf.x, y: mf.y, width: mf.w, height: mf.h)
            window?.setFrame(restoredFrame, display: true)
            // Seed the tracked frame so currentWindowLayout() returns the restored
            // position correctly even before the user moves the window again.
            trackedMainWindowFrame = restoredFrame
            // Remember the target frame so windowDidEndSheet can re-apply it after
            // macOS's sheet-dismissal animation slides the window back to its
            // pre-sheet position (overriding our setFrame above).
            pendingMainWindowFrame = restoredFrame
        }

        // Timeline editor — open and position if it was visible
        if let tf = layout.timelineEditor {
            if timelineEditorWC == nil { showTimelineEditor(self) }
            timelineEditorWC?.window?.setFrame(
                NSRect(x: tf.x, y: tf.y, width: tf.w, height: tf.h), display: true)
        }

        // Effects grid — open and position if it was visible
        if let ef = layout.effectsGrid {
            if effectsGridWC == nil { showEffectsGrid(self) }
            effectsGridWC?.window?.setFrame(
                NSRect(x: ef.x, y: ef.y, width: ef.w, height: ef.h), display: true)
        }

        // Lights panel — open and position if it was visible
        if let lf = layout.lightsPanel {
            if lightsPanel == nil { showLightsInspector(self) }
            lightsPanel?.setFrame(
                NSRect(x: lf.x, y: lf.y, width: lf.w, height: lf.h), display: true)
        }

        // Feedback panel — open and position if it was visible
        if let ff = layout.feedbackPanel {
            if feedbackPanel == nil { showFeedbackPanel(self) }
            feedbackPanel?.setFrame(
                NSRect(x: ff.x, y: ff.y, width: ff.w, height: ff.h), display: true)
        }

        // Color grade panel — open and position if it was visible
        if let gf = layout.colorGradePanel {
            if colorGradePanel == nil { showColorGradePanel(self) }
            colorGradePanel?.setFrame(
                NSRect(x: gf.x, y: gf.y, width: gf.w, height: gf.h), display: true)
        }

        // Camera panel — open and position if it was visible
        if let cf = layout.cameraPanel {
            if cameraPanel == nil { showCameraPanel(self) }
            cameraPanel?.setFrame(
                NSRect(x: cf.x, y: cf.y, width: cf.w, height: cf.h), display: true)
        }

        // Model inspector panel — open and position if it was visible
        if let mf = layout.modelInspectorPanel {
            if modelInspectorPanel == nil { showModelInspector(self) }
            modelInspectorPanel?.setFrame(
                NSRect(x: mf.x, y: mf.y, width: mf.w, height: mf.h), display: true)
        }

        // Atmosphere section state — restore BEFORE (re)opening the panel so it
        // appears in the saved expand/collapse configuration.
        if let vp = viewportView {
            if let v = layout.atmosphereFogExpanded      { vp.atmospherePanelState.fogExpanded = v }
            if let v = layout.atmosphereWeatherExpanded  { vp.atmospherePanelState.weatherExpanded = v }
            if let v = layout.atmosphereAdvancedExpanded { vp.atmospherePanelState.advancedExpanded = v }
        }

        // Atmosphere panel — open and position if it was visible
        if let af = layout.atmospherePanel {
            if atmospherePanel == nil { showAtmospherePanel(self) }
            atmospherePanel?.setFrame(
                NSRect(x: af.x, y: af.y, width: af.w, height: af.h), display: true)
        }

        // Probe inspector — open and position if it was visible
        if let pf = layout.probeInspectorPanel {
            if probeInspectorPanel == nil { showProbeInspector(self) }
            probeInspectorPanel?.setFrame(
                NSRect(x: pf.x, y: pf.y, width: pf.w, height: pf.h), display: true)
        }

        // Path Animator panels — open and position if they were visible.
        if let sf = layout.spinPanel {
            if spinPanel == nil { showSpinAnimator(self) }
            spinPanel?.setFrame(NSRect(x: sf.x, y: sf.y, width: sf.w, height: sf.h), display: true)
        }
        if let of = layout.orbitPanel {
            if orbitPathPanel == nil { showOrbitPathAnimator(self) }
            orbitPathPanel?.setFrame(NSRect(x: of.x, y: of.y, width: of.w, height: of.h), display: true)
        }
        if let lf = layout.linearPanel {
            if linearPathPanel == nil { showLinearPathAnimator(self) }
            linearPathPanel?.setFrame(NSRect(x: lf.x, y: lf.y, width: lf.w, height: lf.h), display: true)
        }
        if let cf = layout.curvePanel {
            if curvePathPanel == nil { showCurvePathAnimator(self) }
            curvePathPanel?.setFrame(NSRect(x: cf.x, y: cf.y, width: cf.w, height: cf.h), display: true)
        }
        if let gf = layout.gaitPanel {
            if gaitPanel == nil { showGaitAnimator(self) }
            gaitPanel?.setFrame(NSRect(x: gf.x, y: gf.y, width: gf.w, height: gf.h), display: true)
        }
    }

    // MARK: - Dirty tracking

    private func markDirty() { isDirty = true }

    /// Responder-chain entry point so detached UI (e.g. the Timeline footer) can
    /// flag the project dirty without holding an AppDelegate reference.
    @objc func markDirtyFromUI(_ sender: Any?) { markDirty() }

    /// Subscribe to every ObservableObject that holds saveable state so that any
    /// change made via the SwiftUI inspector panels automatically sets isDirty.
    /// Uses synchronous delivery (no receive(on:)) so that subscriptions fire before
    /// the loadProject isDirty=false line runs, not after it.
    private func subscribeToSettingsChanges(_ viewport: ViewportView) {
        settingsCancellables.removeAll()

        // LightManager.lights covers intensity, colour, direction, position,
        // range, beamThickness, type, isEnabled, cone angles — everything in LightConfig.
        viewport.lightManager.objectWillChange
            .sink { [weak self] in self?.markDirty() }
            .store(in: &settingsCancellables)

        // Resize the timeline editor whenever the light count changes.
        // objectWillChange fires BEFORE the mutation, so dispatch async to read
        // the committed new count on the next run-loop turn.
        viewport.lightManager.objectWillChange
            .sink { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    self?.timelineEditorWC?.updateWindowHeight()
                }
            }
            .store(in: &settingsCancellables)

        // Selecting a different light in the Lights & Background inspector
        // (or anywhere else that mutates `selectedIndex`) switches the viewport
        // into Light mode and re-emits onControlModeChanged with the new index,
        // so the Timeline Editor lane lines up with the inspector's selection.
        //
        // `@Published` fires in willSet — `selectedIndex` is still the OLD value
        // when the sink runs synchronously.  `receive(on: .main)` defers to the
        // next run-loop tick so `currentTrackRef` reads the settled NEW value.
        viewport.lightManager.$selectedIndex
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak viewport] _ in viewport?.setControlMode(.light) }
            .store(in: &settingsCancellables)

        // FeedbackSettings covers all feedback panel controls.
        viewport.feedbackSettings.objectWillChange
            .sink { [weak self] in self?.markDirty() }
            .store(in: &settingsCancellables)

        // RenderSettings covers colour mode and axes gizmo toggle.
        viewport.renderSettings.objectWillChange
            .sink { [weak self] in self?.markDirty() }
            .store(in: &settingsCancellables)

        // BackgroundConfig covers mode, solid colour, gradient colours.
        viewport.backgroundConfig.objectWillChange
            .sink { [weak self] in self?.markDirty() }
            .store(in: &settingsCancellables)

        // Probe position (the gizmo-visibility toggle is editor-only, so key on
        // position rather than objectWillChange to avoid spurious dirtying).
        viewport.probeConfig.$position
            .dropFirst()
            .sink { [weak self] _ in self?.markDirty() }
            .store(in: &settingsCancellables)
        // Probe lock toggle also dirties the project (position-only observation above
        // skips it).
        viewport.probeConfig.$isLocked
            .dropFirst()
            .sink { [weak self] _ in self?.markDirty() }
            .store(in: &settingsCancellables)

        // ColorGradeSettings covers brightness and contrast.
        viewport.colorGradeSettings.objectWillChange
            .sink { [weak self] in self?.markDirty() }
            .store(in: &settingsCancellables)

        // FogSettings (atmosphere).  Ignore writes made by the playhead-follow sync
        // (scrubbing the panel to the animation must not mark the project dirty).
        viewport.fogSettings.objectWillChange
            .sink { [weak self, weak viewport] in
                guard viewport?.fogSettings.suppressDirty != true else { return }
                self?.markDirty()
            }
            .store(in: &settingsCancellables)

        // ParticleManager (weather): add/remove/select.  Also resize the timeline
        // when the emitter count changes (one lane per emitter).
        viewport.particleManager.objectWillChange
            .sink { [weak self] in
                self?.markDirty()
                DispatchQueue.main.async { [weak self] in self?.timelineEditorWC?.updateWindowHeight() }
            }
            .store(in: &settingsCancellables)
        // Re-wire the per-emitter property-edit subscriptions whenever the list
        // changes (async so the committed array is read, not the pre-mutation one).
        viewport.particleManager.$emitters
            .sink { [weak self, weak viewport] _ in
                DispatchQueue.main.async {
                    guard let self = self, let viewport = viewport else { return }
                    self.resubscribeParticleEmitters(viewport)
                }
            }
            .store(in: &settingsCancellables)
        resubscribeParticleEmitters(viewport)   // initial subscription

        print("[DEBUG] AppDelegate: subscribed to settings changes for dirty tracking")
    }

    /// (Re)subscribes a dirty sink to each particle emitter's property edits.
    /// Called initially and whenever the emitter list changes.  Per-emitter
    /// `suppressDirty` skips the playhead-follow sync writes.
    private func resubscribeParticleEmitters(_ viewport: ViewportView) {
        particleEmitterCancellables.removeAll()
        for emitter in viewport.particleManager.emitters {
            emitter.objectWillChange
                .sink { [weak self] in
                    guard emitter.suppressDirty != true else { return }
                    self?.markDirty()
                }
                .store(in: &particleEmitterCancellables)
        }
    }

    // MARK: - Menu

    private func setupMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu

        let aboutItem = NSMenuItem(
            title: "About ThreeDViewport",
            action: #selector(showAbout(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = self
        appMenu.addItem(aboutItem)

        appMenu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)

        let newInstanceItem = NSMenuItem(
            title: "New Instance",
            action: #selector(openNewInstance(_:)),
            keyEquivalent: ""
        )
        newInstanceItem.target = self
        appMenu.addItem(newInstanceItem)

        appMenu.addItem(.separator())

        appMenu.addItem(NSMenuItem(
            title: "Quit ThreeDViewport",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu

        // Open Model — adds to scene (⌘O); use New Project to start fresh
        let openModelItem = NSMenuItem(
            title: "Open Model...",
            action: #selector(openModel(_:)),
            keyEquivalent: "o"
        )
        openModelItem.target = self
        fileMenu.addItem(openModelItem)

        let replaceModelItem = NSMenuItem(
            title: "Replace Selected Model...",
            action: #selector(replaceSelectedModel(_:)),
            keyEquivalent: ""
        )
        replaceModelItem.target = self
        fileMenu.addItem(replaceModelItem)

        fileMenu.addItem(.separator())

        // New Project (⌘N)
        let newProjectItem = NSMenuItem(
            title: "New Project",
            action: #selector(newProject(_:)),
            keyEquivalent: "n"
        )
        newProjectItem.target = self
        fileMenu.addItem(newProjectItem)

        let openProjectItem = NSMenuItem(
            title: "Open Project...",
            action: #selector(openProject(_:)),
            keyEquivalent: ""
        )
        openProjectItem.target = self
        fileMenu.addItem(openProjectItem)

        let importProjectItem = NSMenuItem(
            title: "Import Project…",
            action: #selector(importProject(_:)),
            keyEquivalent: ""
        )
        importProjectItem.target = self
        fileMenu.addItem(importProjectItem)

        let saveProjectItem = NSMenuItem(
            title: "Save Project",
            action: #selector(saveProject(_:)),
            keyEquivalent: "s"
        )
        saveProjectItem.target = self
        fileMenu.addItem(saveProjectItem)

        let saveProjectAsItem = NSMenuItem(
            title: "Save Project As...",
            action: #selector(saveProjectAs(_:)),
            keyEquivalent: "S"   // ⌘⇧S
        )
        saveProjectAsItem.target = self
        fileMenu.addItem(saveProjectAsItem)

        fileMenu.addItem(NSMenuItem.separator())

        // Export Model — enabled (validateMenuItem) whenever an object is selected.
        let exportModelItem = NSMenuItem(
            title: "Export Model…",
            action: #selector(exportModel(_:)),
            keyEquivalent: ""
        )
        exportModelItem.target = self
        fileMenu.addItem(exportModelItem)

        fileMenu.addItem(NSMenuItem.separator())

        let openLightingHDRItem = NSMenuItem(
            title: "Open Lighting HDR...",
            action: #selector(openLightingHDR(_:)),
            keyEquivalent: ""
        )
        openLightingHDRItem.target = self
        fileMenu.addItem(openLightingHDRItem)

        let openBackgroundHDRItem = NSMenuItem(
            title: "Open Background HDR...",
            action: #selector(openBackgroundHDR(_:)),
            keyEquivalent: ""
        )
        openBackgroundHDRItem.target = self
        fileMenu.addItem(openBackgroundHDRItem)

        let bakeHDRItem = NSMenuItem(
            title: "Export Scene to HDR File...",
            action: #selector(bakeSceneToHDR(_:)),
            keyEquivalent: ""
        )
        bakeHDRItem.target = self
        fileMenu.addItem(bakeHDRItem)

        fileMenu.addItem(NSMenuItem.separator())

        let exportItem = NSMenuItem(
            title: "Export ProRes Video...",
            action: #selector(exportVideo(_:)),
            keyEquivalent: "e"
        )
        exportItem.target = self
        fileMenu.addItem(exportItem)

        let exportAllItem = NSMenuItem(
            title: "Export All Passes...",
            action: #selector(exportAll(_:)),
            keyEquivalent: "e"
        )
        exportAllItem.keyEquivalentModifierMask = [.command, .shift]
        exportAllItem.target = self
        fileMenu.addItem(exportAllItem)

        // ── Edit menu ─────────────────────────────────────────────────────────
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu

        // Add Follow Camera Keyframe — requires an object to be selected
        let followCamItem = NSMenuItem(
            title:          "Add Follow Camera Keyframe",
            action:         #selector(addFollowCameraKeyframe(_:)),
            keyEquivalent:  ""
        )
        followCamItem.target = self
        editMenu.addItem(followCamItem)

        // Duplicate Object — adds another instance of the selected object/model,
        // carrying its material overrides + placement (validateMenuItem gates it).
        let duplicateItem = NSMenuItem(
            title: "Duplicate Object",
            action: #selector(duplicateObject(_:)),
            keyEquivalent: "d"
        )
        duplicateItem.target = self
        editMenu.addItem(duplicateItem)

        editMenu.addItem(.separator())

        let removeItem = NSMenuItem(title: "Remove", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "Remove")
        sub.delegate = self
        removeItem.submenu = sub
        removeSubmenu = sub
        editMenu.addItem(removeItem)

        let removeAllItem = NSMenuItem(
            title: "Remove All",
            action: #selector(confirmRemoveAll(_:)),
            keyEquivalent: ""
        )
        removeAllItem.target = self
        editMenu.addItem(removeAllItem)

        editMenu.addItem(.separator())

        // Glue — bind two or more objects into one animatable unit (envelope).
        let glueItem = NSMenuItem(
            title: "Glue Objects…",
            action: #selector(glueObjects(_:)),
            keyEquivalent: ""
        )
        glueItem.target = self
        editMenu.addItem(glueItem)

        // Edit Glue Members — enabled (via validateMenuItem) only when an envelope is
        // selected; add/remove members without ungluing.
        let editGlueItem = NSMenuItem(
            title: "Edit Glue Members…",
            action: #selector(editGlueMembers(_:)),
            keyEquivalent: ""
        )
        editGlueItem.target = self
        editMenu.addItem(editGlueItem)

        // Unglue — enabled (via validateMenuItem) only when an envelope is selected.
        let unglueItem = NSMenuItem(
            title: "Unglue",
            action: #selector(unglueSelected(_:)),
            keyEquivalent: ""
        )
        unglueItem.target = self
        editMenu.addItem(unglueItem)

        // ── View menu — rendering toggles only ───────────────────────────────
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu

        // Render Mode — cycles Greyscale → Color → Black+White; title updated in validateMenuItem
        let greyItem = NSMenuItem(
            title: "Render Mode",
            action: #selector(toggleColorMode(_:)),
            keyEquivalent: "g"
        )
        greyItem.target = self
        viewMenu.addItem(greyItem)

        // Wireframe — checkmark driven by validateMenuItem
        let wireItem = NSMenuItem(
            title: "Wireframe",
            action: #selector(toggleWireframe(_:)),
            keyEquivalent: ""
        )
        wireItem.target = self
        viewMenu.addItem(wireItem)

        // Axes Gizmo — shows XYZ orientation widget in the bottom-right corner
        let gizmoItem = NSMenuItem(
            title: "Axes Gizmo",
            action: #selector(toggleAxesGizmo(_:)),
            keyEquivalent: ""
        )
        gizmoItem.target = self
        viewMenu.addItem(gizmoItem)

        // Vector Path — toggles the keyframe motion-path overlay (also the V key).
        let vectorPathItem = NSMenuItem(
            title: "Vector Path",
            action: #selector(toggleVectorPath(_:)),
            keyEquivalent: ""
        )
        vectorPathItem.target = self
        viewMenu.addItem(vectorPathItem)

        viewMenu.addItem(.separator())

        // Loop Playback — when on, animation restarts instead of stopping at the end
        let loopItem = NSMenuItem(
            title: "Loop Playback",
            action: #selector(toggleLoopPlayback(_:)),
            keyEquivalent: ""
        )
        loopItem.target = self
        viewMenu.addItem(loopItem)

        // ── Position Marks menu — saved Probe world positions ──────────────────
        // (Named "Position Marks" to distinguish from the Timeline In/Out marks.)
        let marksItem = NSMenuItem()
        mainMenu.addItem(marksItem)
        let marksMenu = NSMenu(title: "Position Marks")
        marksItem.submenu = marksMenu

        let addMarkItem = NSMenuItem(title: "Add Position Mark",
                                     action: #selector(promptForMarkMenu(_:)),
                                     keyEquivalent: "")
        addMarkItem.target = self
        marksMenu.addItem(addMarkItem)

        // Probe placement: drop the Probe at the Director's eye (complement of Shift+T).
        let probeToEyeItem = NSMenuItem(title: "Set Probe to Director Eye",
                                        action: #selector(setProbeToDirectorEyeMenu(_:)),
                                        keyEquivalent: "")
        probeToEyeItem.target = self
        marksMenu.addItem(probeToEyeItem)

        // Inverse: move the Director's eye to the Probe (keeping its view direction).
        let eyeToProbeItem = NSMenuItem(title: "Set Director Eye to Probe",
                                        action: #selector(setDirectorEyeToProbeMenu(_:)),
                                        keyEquivalent: "")
        eyeToProbeItem.target = self
        marksMenu.addItem(eyeToProbeItem)

        let goToMarkItem = NSMenuItem(title: "Go To Position Mark", action: nil, keyEquivalent: "")
        let goToSub = NSMenu(title: "Go To Position Mark")
        goToSub.delegate = self
        goToMarkItem.submenu = goToSub
        goToMarkSubmenu = goToSub
        marksMenu.addItem(goToMarkItem)

        let deleteMarkItem = NSMenuItem(title: "Delete Position Mark", action: nil, keyEquivalent: "")
        let deleteSub = NSMenu(title: "Delete Position Mark")
        deleteSub.delegate = self
        deleteMarkItem.submenu = deleteSub
        deleteMarkSubmenu = deleteSub
        marksMenu.addItem(deleteMarkItem)

        marksMenu.addItem(.separator())

        let showMarksItem = NSMenuItem(title: "Show Position Marks",
                                       action: #selector(toggleMarks(_:)),
                                       keyEquivalent: "")
        showMarksItem.target = self
        marksMenu.addItem(showMarksItem)

        // ── Timeline menu — In/Out marks + range playback ──────────────────────
        let timelineItem = NSMenuItem()
        mainMenu.addItem(timelineItem)
        let timelineMenu = NSMenu(title: "Timeline")
        timelineItem.submenu = timelineMenu

        let setInItem = NSMenuItem(title: "Set In Point",
                                   action: #selector(setTimelineInPoint(_:)), keyEquivalent: "")
        setInItem.target = self
        timelineMenu.addItem(setInItem)

        let setOutItem = NSMenuItem(title: "Set Out Point",
                                    action: #selector(setTimelineOutPoint(_:)), keyEquivalent: "")
        setOutItem.target = self
        timelineMenu.addItem(setOutItem)

        let clearInOutItem = NSMenuItem(title: "Clear In/Out",
                                        action: #selector(clearTimelineInOut(_:)), keyEquivalent: "")
        clearInOutItem.target = self
        timelineMenu.addItem(clearInOutItem)

        timelineMenu.addItem(.separator())

        let loopInOutItem = NSMenuItem(title: "Loop In to Out",
                                       action: #selector(toggleLoopInOut(_:)), keyEquivalent: "")
        loopInOutItem.target = self
        timelineMenu.addItem(loopInOutItem)

        // ── Window menu — panels + macOS-standard items ────────────────────────
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu

        // Show Main Window — deminiaturizes and restores secondary windows
        let showMainItem = NSMenuItem(
            title: "Show Main Window",
            action: #selector(showMainWindow(_:)),
            keyEquivalent: ""
        )
        showMainItem.target = self
        windowMenu.addItem(showMainItem)

        windowMenu.addItem(.separator())

        // Standard macOS window management
        windowMenu.addItem(NSMenuItem(
            title: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        ))
        windowMenu.addItem(NSMenuItem(
            title: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        ))

        windowMenu.addItem(.separator())

        windowMenu.addItem(NSMenuItem(
            title: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        ))

        windowMenu.addItem(.separator())

        // Floating inspector panels.  Added in any order below, then sorted
        // alphabetically by title (see windowPanelStart sort after the last item),
        // so new panels don't need to be inserted in the right place by hand.
        let windowPanelStart = windowMenu.items.count
        let atmosphereItem = NSMenuItem(
            title: "Atmosphere…",
            action: #selector(showAtmospherePanel(_:)),
            keyEquivalent: "A"   // ⌘⇧A
        )
        atmosphereItem.target = self
        windowMenu.addItem(atmosphereItem)

        let cameraPanelItem = NSMenuItem(
            title: "Camera…",
            action: #selector(showCameraPanel(_:)),
            keyEquivalent: "k"
        )
        cameraPanelItem.target = self
        windowMenu.addItem(cameraPanelItem)

        let colorGradeItem = NSMenuItem(
            title: "Color Grade…",
            action: #selector(showColorGradePanel(_:)),
            keyEquivalent: "G"   // ⌘⇧G — uppercase encodes the shift modifier
        )
        colorGradeItem.target = self
        windowMenu.addItem(colorGradeItem)

        let feedbackItem = NSMenuItem(
            title: "Feedback…",
            action: #selector(showFeedbackPanel(_:)),
            keyEquivalent: "f"
        )
        feedbackItem.target = self
        windowMenu.addItem(feedbackItem)

        let lightsItem = NSMenuItem(
            title: "Lights & Background…",
            action: #selector(showLightsInspector(_:)),
            keyEquivalent: "l"
        )
        lightsItem.target = self
        windowMenu.addItem(lightsItem)

        let modelInspectorItem = NSMenuItem(
            title: "Model Inspector…",
            action: #selector(showModelInspector(_:)),
            keyEquivalent: "i"
        )
        modelInspectorItem.target = self
        windowMenu.addItem(modelInspectorItem)

        let probeInspectorItem = NSMenuItem(
            title: "Probe Inspector…",
            action: #selector(showProbeInspector(_:)),
            keyEquivalent: ""
        )
        probeInspectorItem.target = self
        windowMenu.addItem(probeInspectorItem)
        // (Show Marks moved to the dedicated Marks menu.)

        let pathAnimatorItem = NSMenuItem(title: "Path Animator", action: nil, keyEquivalent: "")
        let pathSubmenu = NSMenu(title: "Path Animator")
        let orbitPathItem = NSMenuItem(
            title: "Orbit…",
            action: #selector(showOrbitPathAnimator(_:)),
            keyEquivalent: ""
        )
        orbitPathItem.target = self
        pathSubmenu.addItem(orbitPathItem)
        let linearPathItem = NSMenuItem(
            title: "Linear…",
            action: #selector(showLinearPathAnimator(_:)),
            keyEquivalent: ""
        )
        linearPathItem.target = self
        pathSubmenu.addItem(linearPathItem)
        let curvePathItem = NSMenuItem(
            title: "Curve…",
            action: #selector(showCurvePathAnimator(_:)),
            keyEquivalent: ""
        )
        curvePathItem.target = self
        pathSubmenu.addItem(curvePathItem)
        let gaitItem = NSMenuItem(
            title: "Gait…",
            action: #selector(showGaitAnimator(_:)),
            keyEquivalent: ""
        )
        gaitItem.target = self
        pathSubmenu.addItem(gaitItem)
        let spinItem = NSMenuItem(
            title: "Spin…",
            action: #selector(showSpinAnimator(_:)),
            keyEquivalent: ""
        )
        spinItem.target = self
        pathSubmenu.addItem(spinItem)
        pathAnimatorItem.submenu = pathSubmenu
        windowMenu.addItem(pathAnimatorItem)

        let timelineEditorItem = NSMenuItem(
            title: "Timeline Editor",
            action: #selector(showTimelineEditor(_:)),
            keyEquivalent: "j"
        )
        timelineEditorItem.target = self
        windowMenu.addItem(timelineEditorItem)

        let effectsGridItem = NSMenuItem(
            title: "Effects",
            action: #selector(showEffectsGrid(_:)),
            keyEquivalent: ""
        )
        effectsGridItem.target = self
        windowMenu.addItem(effectsGridItem)

        // Sort the floating-panel section alphabetically by title (leaves the
        // standard window-management items above it untouched).
        let panelItems = Array(windowMenu.items[windowPanelStart...])
        for item in panelItems { windowMenu.removeItem(item) }
        for item in panelItems.sorted(by: { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) {
            windowMenu.addItem(item)
        }

        // Register as the system Window menu so AppKit tracks open windows.
        NSApplication.shared.windowsMenu = windowMenu

        NSApplication.shared.mainMenu = mainMenu
        print("[DEBUG] AppDelegate: menu setup complete")
    }

    // MARK: - About

    @objc private func showAbout(_ sender: Any) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName:    "ThreeDViewport",
            .credits: NSAttributedString(
                string: "A Metal-accelerated 3D animation viewport.\n"
                      + "Load glTF/GLB models, animate with keyframes,\n"
                      + "and export to ProRes video.",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
                ]
            )
        ])
    }

    // MARK: - Default directories

    /// Returns the configured folder for a category ("Projects", "Movies",
    /// "Models"), creating it if needed.  Paths come from AppSettings (which
    /// default to ~/Documents/ThreeDViewport/<subfolder>).
    private func defaultDirectory(for subfolder: String) -> URL {
        let s = AppSettings.shared
        let path: String
        switch subfolder {
        case "Projects": path = s.projectsPath
        case "Movies":   path = s.moviesPath
        case "Models":   path = s.modelsPathSecondary
        case "HDRs":     path = s.hdrFolderPath
        case "ExportedModels":         path = s.exportedModelsPath
        case "ExportedModelProjects":  path = s.exportedModelProjectsPath
        default:
            // Unknown category — preserve the original Documents-based behavior.
            let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ThreeDViewport")
                .appendingPathComponent(subfolder)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            return base
        }
        let url = AppSettings.expand(path)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Default starting folder for any "pick a model file" sheet.  Uses the
    /// primary models path if it exists, otherwise the secondary (fallback).
    /// The primary is never auto-created — the user opts in by making it.
    private func defaultModelDirectory() -> URL {
        let primary = AppSettings.expand(AppSettings.shared.modelsPathPrimary)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: primary.path, isDirectory: &isDir),
           isDir.boolValue {
            return primary
        }
        return defaultDirectory(for: "Models")
    }

    /// Returns the next "rev letter" project filename derived from `baseName`.
    /// Strips any trailing ` rev <letters>` suffix to find the root, scans `dir`
    /// for existing `<root> rev <letters>.3dvp` files, and returns
    /// `<root> rev <next>` where `<next>` is one above the highest existing
    /// letter sequence (A → B → … → Z → AA → AB → …).  When no revision file
    /// exists yet, defaults to `<root> rev A`.
    private func nextProjectRevisionName(baseName: String, in dir: URL) -> String {
        // Strip an existing " rev <letters>" suffix to find the root name.
        let revPattern = #" rev ([A-Z]+)$"#
        var root = baseName
        if let regex = try? NSRegularExpression(pattern: revPattern),
           let match = regex.firstMatch(in: baseName,
                                        range: NSRange(baseName.startIndex..., in: baseName)),
           let r = Range(match.range, in: baseName) {
            root = String(baseName[..<r.lowerBound])
        }

        // Letters → integer (A=1, B=2, …, Z=26, AA=27, AB=28, …).
        func value(of letters: String) -> Int {
            var v = 0
            for c in letters {
                guard let a = c.asciiValue, a >= 65, a <= 90 else { return 0 }
                v = v * 26 + Int(a - 64)
            }
            return v
        }
        // Integer → letters (1=A, …, 27=AA, …).
        func letters(of n: Int) -> String {
            var n = n
            var out = ""
            while n > 0 {
                let r = (n - 1) % 26
                out = String(UnicodeScalar(65 + r)!) + out
                n = (n - 1) / 26
            }
            return out
        }

        let prefix = root + " rev "
        let names  = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var highest = 0
        for name in names where name.hasSuffix(".3dvp") {
            let stem = String(name.dropLast(5))
            guard stem.hasPrefix(prefix) else { continue }
            let suffix = String(stem.dropFirst(prefix.count))
            let v = value(of: suffix)
            if v > highest { highest = v }
        }
        return "\(root) rev \(letters(of: highest + 1))"
    }

    /// Returns the next available `<projectName>.NN.mov` filename in `dir`.
    /// Scans existing files matching that pattern, picks the highest NN, and
    /// returns NN+1 (zero-padded to at least two digits).  When the folder
    /// has no matching files, starts at `.01`.  Custom-named files in the
    /// same folder don't affect the count.
    private func nextMovieFilename(projectName: String, in dir: URL) -> String {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let prefix = projectName + "."
        var highest = 0
        for name in names {
            guard name.hasPrefix(prefix), name.hasSuffix(".mov") else { continue }
            let middle = name.dropFirst(prefix.count).dropLast(4)   // strip prefix + ".mov"
            if let n = Int(middle), n > highest { highest = n }
        }
        return String(format: "%@.%02d.mov", projectName, highest + 1)
    }

    /// Next cycle/take number for "Export All": scans `dir` for any
    /// `<projectName>.NN[.PassName].mov` and returns the highest NN + 1.  Shares the
    /// numbering sequence with single exports so cycles never collide with them.
    private func nextCycleNumber(projectName: String, in dir: URL) -> Int {
        let names  = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let prefix = projectName + "."
        var highest = 0
        for name in names {
            guard name.hasPrefix(prefix), name.hasSuffix(".mov") else { continue }
            let nnPart = name.dropFirst(prefix.count).prefix { $0.isNumber }
            if let n = Int(nnPart), n > highest { highest = n }
        }
        return highest + 1
    }

    /// Returns the next available `<base>.NN.<ext>` filename in `dir` (NN ≥ 01,
    /// zero-padded).  Generic version of `nextMovieFilename` used for HDR exports.
    private func nextNumberedFilename(base: String, ext: String, in dir: URL) -> String {
        let names  = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let prefix = base + "."
        let suffix = "." + ext
        var highest = 0
        for name in names {
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { continue }
            let middle = name.dropFirst(prefix.count).dropLast(suffix.count)
            if let n = Int(middle), n > highest { highest = n }
        }
        return String(format: "%@.%02d.%@", base, highest + 1, ext)
    }

    // MARK: - Template projects

    /// If `template.3dvp` exists in the Projects folder, load it as the starting
    /// scene for a fresh session, then detach so Save acts as Save-As and
    /// pre-fill the name with the next available "Project N".
    private func applyTemplateIfPresent() {
        let templateURL = defaultDirectory(for: "Projects")
            .appendingPathComponent("template.3dvp")
        guard FileManager.default.fileExists(atPath: templateURL.path) else {
            // Surface the missing template so the user knows why they got an
            // empty scene — and where to drop the file if they want one.
            let alert = NSAlert()
            alert.messageText     = "Template file not found"
            alert.informativeText = "No template was loaded — expected at:\n" + templateURL.path
            alert.alertStyle      = .informational
            alert.runModal()
            return
        }

        loadProject(from: templateURL)

        let name = nextProjectName()
        currentProjectURL    = nil
        isDirty              = false
        suggestedProjectName = name
        window?.title        = "ThreeDViewport — " + name
        print("[DEBUG] AppDelegate: template loaded as " + name)
    }

    /// Scans the Projects folder for files named "Project <int>.3dvp" and
    /// returns "Project N" where N = max(found) + 1, or "Project 1" if none exist.
    private func nextProjectName() -> String {
        let dir = defaultDirectory(for: "Projects")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var maxN = 0
        for name in entries where name.hasSuffix(".3dvp") {
            let stem = (name as NSString).deletingPathExtension
            guard stem.hasPrefix("Project ") else { continue }
            let tail = stem.dropFirst("Project ".count)
            if let n = Int(tail), n > maxN { maxN = n }
        }
        return "Project " + String(maxN + 1)
    }

    // MARK: - New Project

    @objc private func newProject(_ sender: Any) {
        guard let window = window else { return }

        // Confirm if there's an unsaved scene with models in it
        if viewportView?.sceneManager.objects.isEmpty == false {
            let alert = NSAlert()
            alert.messageText     = "New Project"
            alert.informativeText = "This will clear the current scene. Any unsaved changes will be lost."
            alert.alertStyle      = .warning
            alert.addButton(withTitle: "New Project")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn {
                    self?.performNewProject()
                }
            }
        } else {
            performNewProject()
        }
    }

    private func performNewProject() {
        viewportView?.newProject()
        currentProjectURL    = nil
        suggestedProjectName = nil
        window?.title        = "ThreeDViewport"
        timelineEditorWC?.updateWindowHeight()
        print("[DEBUG] AppDelegate: new project")

        applyTemplateIfPresent()
        syncGaitPanelToProject()
    }

    // MARK: - Open Model (adds to scene; use New Project to start fresh)

    @objc private func openModel(_ sender: Any) {
        guard let window = window else {
            print("[DEBUG] AppDelegate: openModel — window is nil")
            return
        }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories    = false
        panel.canChooseFiles          = true
        panel.title        = "Open Model"
        panel.directoryURL = defaultModelDirectory()

        let modelTypes = [UTType(filenameExtension: "glb"), UTType(filenameExtension: "gltf")]
            .compactMap { $0 }
        if !modelTypes.isEmpty {
            panel.allowedContentTypes = modelTypes
        }

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else {
                print("[DEBUG] AppDelegate: open panel cancelled or url is nil")
                return
            }
            print("[DEBUG] AppDelegate: openModel — " + url.lastPathComponent)
            // The same file may be added more than once; a load failure already
            // shows its own error from addModelToScene.
            if self?.viewportView?.addModelToScene(url: url) == .added {
                self?.markDirty()
                self?.timelineEditorWC?.updateWindowHeight()
                self?.refreshCameraFollowTargets()
            }
        }
    }

    // MARK: - Add Model to Scene (Phase 6)

    // NOTE: Unreachable dead code — this @objc handler is not wired to any menu
    // item (no `#selector(addModelToScene)` registration anywhere).  The live
    // "add a model" path is `openModel(_:)`, which calls
    // `viewportView.addModelToScene(url:)` directly.  Commented out 2026-05-20;
    // remove entirely if it's still unused.
//    @objc private func addModelToScene(_ sender: Any) {
//        guard let window = window else {
//            print("[DEBUG] AppDelegate: addModelToScene — window is nil")
//            return
//        }
//
//        let panel = NSOpenPanel()
//        panel.allowsMultipleSelection = false
//        panel.canChooseDirectories    = false
//        panel.canChooseFiles          = true
//        panel.title        = "Add Model to Scene"
//        panel.directoryURL = defaultModelDirectory()
//
//        let modelTypes = [UTType(filenameExtension: "glb"), UTType(filenameExtension: "gltf")]
//            .compactMap { $0 }
//        if !modelTypes.isEmpty {
//            panel.allowedContentTypes = modelTypes
//        }
//
//        panel.beginSheetModal(for: window) { [weak self] response in
//            guard response == .OK, let url = panel.url else {
//                print("[DEBUG] AppDelegate: add-model panel cancelled")
//                return
//            }
//            print("[DEBUG] AppDelegate: addModelToScene — " + url.lastPathComponent)
//            self?.viewportView?.addModelToScene(url: url)
//            self?.markDirty()
//        }
//    }

    // MARK: - Replace Selected Model

    @objc private func replaceSelectedModel(_ sender: Any) {
        guard let window = window else { return }

        let selectedName = viewportView?.sceneManager.selectedObject?.name ?? "selected model"

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories    = false
        panel.canChooseFiles          = true
        panel.title                   = "Replace Selected Model"
        panel.prompt                  = "Replace"
        panel.message                 = "Choose a .glb file to replace \"\(selectedName)\"."
        panel.directoryURL            = defaultModelDirectory()

        let modelTypes = [UTType(filenameExtension: "glb"), UTType(filenameExtension: "gltf")]
            .compactMap { $0 }
        if !modelTypes.isEmpty {
            panel.allowedContentTypes = modelTypes
        }

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            print("[DEBUG] AppDelegate: replaceSelectedModel — " + url.lastPathComponent)
            self?.viewportView?.replaceSelectedModel(url: url)
            self?.markDirty()
            self?.refreshCameraFollowTargets()
        }
    }

    // MARK: - Open Project

    @objc private func openProject(_ sender: Any) {
        guard let window = window else { return }

        let panel = NSOpenPanel()
        panel.title                   = "Open Project"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories    = false
        panel.canChooseFiles          = true
        panel.directoryURL            = defaultDirectory(for: "Projects")

        if let projType = UTType(filenameExtension: "3dvp") {
            panel.allowedContentTypes = [projType]
        }

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.loadProject(from: url)
        }
    }

    // MARK: - Import Project (append into the current scene)

    @objc private func importProject(_ sender: Any) {
        guard let window = window, let viewport = viewportView else { return }

        let panel = NSOpenPanel()
        panel.title                   = "Import Project"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories    = false
        panel.canChooseFiles          = true
        panel.directoryURL            = defaultDirectory(for: "Projects")
        if let projType = UTType(filenameExtension: "3dvp") { panel.allowedContentTypes = [projType] }

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }

            // Peek the source's timeline marks so the dialog can offer a ranged
            // import.  Only a clean both-marks-set state enables slicing; a half-
            // marked source (one mark) is treated as no range, to avoid a surprise
            // slice from an ambiguous file.
            var sourceInOut: (in: Double, out: Double)? = nil
            var sourceHalfMarked = false
            if let json = try? Data(contentsOf: url),
               let data = try? JSONDecoder().decode(ProjectData.self, from: json) {
                // Refuse up front if any referenced model file is missing — the import's
                // positional per-object restore would otherwise mis-map every later
                // object (and can't recover a missing model's part count).
                let paths   = data.modelPaths.isEmpty ? (data.modelPath.map { [$0] } ?? []) : data.modelPaths
                let missing = paths.filter { !FileManager.default.fileExists(atPath: $0) }
                if !missing.isEmpty {
                    let list = missing.map { "• " + ($0 as NSString).lastPathComponent }.joined(separator: "\n")
                    self.showErrorAlert(
                        message: "Can't import — model file(s) missing",
                        detail: "This project references model files that aren't on disk:\n\n\(list)\n\n"
                              + "Restore the file(s) or fix their paths, then try again.")
                    return
                }
                let i = data.timeline.inPoint
                let o = data.timeline.outPoint
                if let i = i, let o = o, o > i {
                    sourceInOut = (in: i, out: o)
                } else if i != nil || o != nil {
                    // Exactly one mark, or an inverted pair — slicing unavailable; warn.
                    sourceHalfMarked = true
                }
            }

            // Placement / timing dialog (position defaults to the Probe).
            let options = ImportProjectOptions(insertTime: viewport.timeline.currentTime,
                                               probe: viewport.probeConfig.position,
                                               sourceInOut: sourceInOut,
                                               sourceHalfMarked: sourceHalfMarked)
            let alert = NSAlert()
            alert.messageText     = "Import \"\(url.deletingPathExtension().lastPathComponent)\""
            alert.informativeText = "Append its models, animation, and materials to the current scene."
            alert.addButton(withTitle: "Import")
            alert.addButton(withTitle: "Cancel")
            let hosting = NSHostingView(rootView: ImportProjectSheet(options: options))
            hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
            alert.accessoryView = hosting
            alert.layout()
            alert.window.makeFirstResponder(hosting)
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            let opts = ProjectFile.ImportOptions(
                insertTime:     options.insertTimeValue,
                transform:      options.transformMatrix(),
                includeLights:  options.includeLights,
                includeEffects: options.includeEffects,
                sliceRange:     options.effectiveSlice)
            let bundlesBefore = Set(viewport.sceneManager.importBundleSources.keys)
            guard ProjectFile.importProject(from: url, into: viewport, options: opts) else {
                self.showErrorAlert(message: "Import failed",
                                    detail: "Could not read the project file.")
                return
            }
            // Opt-in: make the imported spin/orbit editable (re-apply the source's rate
            // markers, extended to the host end).  Reuses the bundle-header "Extend
            // Spin/Orbit to End" logic, silently (no alert if there's none to extend).
            if options.makeSpinEditable {
                let newBundles = Set(viewport.sceneManager.importBundleSources.keys)
                    .subtracting(bundlesBefore)
                for bid in newBundles { self.extendBundleSpinOrbit(bid, silent: true) }
            }
            self.markDirty()
            viewport.syncOverlayState()
            self.refreshCameraFollowTargets()
            self.timelineEditorWC?.editorView.needsDisplay = true
            self.timelineEditorWC?.updateWindowHeight()
            viewport.renderer?.invalidateAnimationCache()
            print("[DEBUG] AppDelegate: imported project " + url.lastPathComponent)

            // Opt-in: open the Glue dialog pre-filled with the just-imported items so
            // the user can bind them into one envelope (anchor + name editable; Cancel
            // leaves them imported, ungrouped).
            if options.glueImported {
                let newBundles = Set(viewport.sceneManager.importBundleSources.keys)
                    .subtracting(bundlesBefore)
                if !newBundles.isEmpty {
                    self.presentGlueDialog(preselectBundles: newBundles,
                                           defaultName: url.deletingPathExtension().lastPathComponent)
                }
            }
        }
    }

    /// Called when the user drags a .3dvp file onto the viewport.
    /// Prompts to discard unsaved changes (if any) before loading.
    private func handleDroppedProject(_ url: URL) {
        if isDirty {
            let alert = NSAlert()
            alert.messageText     = "Open \"\(url.deletingPathExtension().lastPathComponent)\"?"
            alert.informativeText = "Unsaved changes will be lost."
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        loadProject(from: url)
    }

    private func loadProject(from url: URL) {
        guard let viewport = viewportView else { return }

        let resolver: (String) -> URL? = { [weak self] missingPath in
            let filename = URL(fileURLWithPath: missingPath).lastPathComponent
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories    = false
            panel.canChooseFiles          = true
            panel.title                   = "Locate Missing Model"
            panel.prompt                  = "Locate"
            panel.message                 = "\"\(filename)\" could not be found. Please locate it, or cancel to skip."
            panel.directoryURL            = self?.defaultModelDirectory()

            let modelTypes = [UTType(filenameExtension: "glb"), UTType(filenameExtension: "gltf")]
                .compactMap { $0 }
            if !modelTypes.isEmpty {
                panel.allowedContentTypes = modelTypes
            }

            return panel.runModal() == .OK ? panel.url : nil
        }

        do {
            let data = try ProjectFile.load(from: url, into: viewport,
                                            missingModelResolver: resolver)
            currentProjectURL    = url
            suggestedProjectName = nil
            isDirty = false
            window?.title = "ThreeDViewport — " + url.deletingPathExtension().lastPathComponent
            // Resize the timeline editor if the number of tracks changed.
            timelineEditorWC?.updateWindowHeight()
            // Restore window/panel positions saved with the project.
            applyWindowLayout(data.windowLayout)
            // Sync the Camera panel's Follow Target list to the new scene so it
            // doesn't keep showing objects from the previously-loaded project.
            refreshCameraFollowTargets()
            syncGaitPanelToProject()
            checkMissingHDRs(in: viewport)
            checkAndOfferGroupOffsetMigration(in: viewport)
            print("[DEBUG] AppDelegate: project loaded from " + url.lastPathComponent)
        } catch {
            showErrorAlert(message: "Could not open project", detail: error.localizedDescription)
        }
    }

    // MARK: - HDR environment (Lighting / Background)

    @objc private func openLightingHDR(_ sender: Any) {
        pickHDR(title: "Open Lighting HDR") { [weak self] url in
            guard let self, let vp = self.viewportView else { return }
            if vp.renderer?.reloadLightingHDR(url) == true {
                vp.renderSettings.lightingHDRPath = url.path
                vp.needsDisplay = true
                self.markDirty()
                print("[DEBUG] AppDelegate: lighting HDR → " + url.lastPathComponent)
            } else {
                self.showErrorAlert(message: "Couldn't load Lighting HDR",
                    detail: "\"\(url.lastPathComponent)\" couldn't be read as a Radiance .hdr image.")
            }
        }
    }

    @objc private func openBackgroundHDR(_ sender: Any) {
        pickHDR(title: "Open Background HDR") { [weak self] url in
            guard let self, let vp = self.viewportView else { return }
            if vp.renderer?.setBackgroundHDR(url) == true {
                vp.backgroundConfig.backgroundHDRPath = url.path
                vp.backgroundConfig.mode = .environment   // show the new backdrop immediately
                vp.needsDisplay = true
                self.markDirty()
                print("[DEBUG] AppDelegate: background HDR → " + url.lastPathComponent)
            } else {
                self.showErrorAlert(message: "Couldn't load Background HDR",
                    detail: "\"\(url.lastPathComponent)\" couldn't be read as a Radiance .hdr image.")
            }
        }
    }

    @objc private func bakeSceneToHDR(_ sender: Any) {
        guard let viewport = viewportView, let device = viewport.device else { return }

        let options = BakeOptions()
        let hdrDir  = defaultDirectory(for: "HDRs")

        // Default name from the project, with an incrementing .NN suffix (like exports).
        let baseName: String
        if let url = currentProjectURL {
            baseName = url.deletingPathExtension().lastPathComponent
        } else if let s = suggestedProjectName, !s.isEmpty {
            baseName = s
        } else {
            baseName = "environment"
        }

        let panel = NSSavePanel()
        panel.title                = "Export Scene to HDR"
        panel.nameFieldStringValue = nextNumberedFilename(base: baseName, ext: "hdr", in: hdrDir)
        panel.canCreateDirectories = true
        panel.directoryURL         = hdrDir
        if let hdr = UTType(filenameExtension: "hdr") { panel.allowedContentTypes = [hdr] }
        panel.accessoryView = NSHostingView(rootView: BakeOptionsView(options: options))

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let ok = EnvironmentBaker.bake(
            to:                  url,
            width:               options.width,
            height:              options.height,
            probePosition:       viewport.probeConfig.position,
            includeBackground:   options.includeBackground,
            backgroundIntensity: viewport.backgroundConfig.environmentIntensity,
            backgroundHorizon:   viewport.backgroundConfig.environmentHorizon,
            device:              device,
            sceneManager:        viewport.sceneManager,
            lightManager:        viewport.lightManager,
            ibl:                 viewport.renderer?.ibl,
            backgroundEquirect:  viewport.renderer?.backgroundEquirect)

        if ok {
            print("[DEBUG] AppDelegate: exported environment → " + url.lastPathComponent)
            let alert = NSAlert()
            alert.messageText     = "HDR Export Completed"
            alert.informativeText = "Saved \u{201C}\(url.lastPathComponent)\u{201D}."
            alert.alertStyle      = .informational
            alert.runModal()
        } else {
            showErrorAlert(message: "HDR Export failed",
                           detail: "Could not render or write the environment HDR.")
        }
    }

    /// Modal `.hdr` file picker; calls `completion` with the chosen URL.
    private func pickHDR(title: String, _ completion: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title                   = title
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories    = false
        panel.canChooseFiles          = true
        panel.directoryURL            = defaultDirectory(for: "HDRs")
        if let hdr = UTType(filenameExtension: "hdr") { panel.allowedContentTypes = [hdr] }
        if panel.runModal() == .OK, let url = panel.url { completion(url) }
    }

    /// After a project opens, look for groups whose root has a non-zero
    /// translation baked into `obj.transform.columns.3`.  This is a leftover
    /// from old Position/Rotation/Scale slider edits (before the writers were
    /// changed to mutate `groupTransforms[gid]` instead).  With the slider
    /// edits stuck in the static layout, slerp on the group keyframes' rotation
    /// rotates the offset vector around a sphere, producing a wide arc between
    /// keyframes even though the endpoints render correctly.
    ///
    /// Fix: for each affected group, fold the root's translation into every
    /// keyframe's translation (the rendered position at each existing keyframe
    /// stays identical — see the algebra in MODELS.md), then zero the root's
    /// `obj.transform` and `baseTransform` translation columns.  Asks first.
    private func checkAndOfferGroupOffsetMigration(in vp: ViewportView) {
        struct Candidate {
            let name:   String
            let root:   SceneObject
            let track:  KeyframeTrack
            let offset: SIMD3<Float>
        }
        let sm = vp.sceneManager
        var candidates: [Candidate] = []
        print("[DEBUG] AppDelegate: offset-migration check — scanning"
            + " \(sm.groupKeyframeTracks.count) group track(s)")
        for (gid, track) in sm.groupKeyframeTracks where !track.keyframes.isEmpty {
            guard let root = sm.objects(inGroup: gid).first(where: { $0.parentIndex == nil }) else {
                print("[DEBUG] AppDelegate: offset-migration — no root found for gid=\(gid)")
                continue
            }
            let t      = root.transform.columns.3
            let offset = SIMD3<Float>(t.x, t.y, t.z)
            let len    = simd_length(offset)
            // The arcing artifact only occurs when the group keyframes' ROTATION varies
            // — slerp then sweeps the baked offset around an arc.  A pure translation /
            // scale animation (all keyframe rotations equal) keeps the offset constant,
            // so there is nothing to fix.  This is now common because Export Model bakes
            // each part's DISPLAYED pose, so a re-imported model's root part is legitimately
            // off-origin; don't nag about it.
            let rotates: Bool = {
                guard let first = track.keyframes.first?.rotation else { return false }
                let q0 = simd_normalize(first)
                return track.keyframes.dropFirst().contains {
                    abs(simd_dot(q0, simd_normalize($0.rotation))) < 0.9999
                }
            }()
            print("[DEBUG] AppDelegate: offset-migration — gid=\(gid) root='\(root.name)'"
                + " offset=(\(t.x), \(t.y), \(t.z)) len=\(len) rotates=\(rotates)")
            if len > 1e-4 && rotates {
                candidates.append(Candidate(name: root.name, root: root,
                                            track: track, offset: offset))
            }
        }
        guard !candidates.isEmpty else {
            print("[DEBUG] AppDelegate: offset-migration — no candidates, skipping prompt")
            return
        }

        let listText = candidates.map { c in
            String(format: "• %@ — offset (%.2f, %.2f, %.2f) across %d keyframes",
                   c.name, c.offset.x, c.offset.y, c.offset.z, c.track.keyframes.count)
        }.joined(separator: "\n")

        let alert = NSAlert()
        alert.messageText = "Bake stale root translation into keyframes?"
        alert.informativeText =
            "This project has \(candidates.count) animated group(s) with a non-zero "
            + "translation baked into the root part:\n\n"
            + listText
            + "\n\nThis is a leftover from old slider edits and causes the model to "
            + "arc between keyframes instead of moving in a straight line. Baking "
            + "the offset into each keyframe's translation fixes the interpolation; "
            + "the rendered position at every existing keyframe stays identical."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Bake")
        alert.addButton(withTitle: "Skip")

        guard alert.runModal() == .alertFirstButtonReturn else {
            print("[DEBUG] AppDelegate: user skipped group offset migration "
                + "for \(candidates.count) group(s)")
            return
        }

        for c in candidates {
            for i in 0..<c.track.keyframes.count {
                let kf = c.track.keyframes[i]
                // newKf.trans = oldKf.trans + R(kf.rotation) · diag(kf.scale) · offset
                // Compute the rotation matrix the same way Keyframes.swift's makeMatrix
                // does, so the bake is bit-for-bit consistent with playback.
                let n  = simd_normalize(kf.rotation)
                let x  = n.imag.x, y = n.imag.y, z = n.imag.z, w = n.real
                let c0 = SIMD3<Float>(1 - 2*(y*y + z*z),     2*(x*y + z*w),     2*(x*z - y*w))
                let c1 = SIMD3<Float>(    2*(x*y - z*w), 1 - 2*(x*x + z*z),     2*(y*z + x*w))
                let c2 = SIMD3<Float>(    2*(x*z + y*w),     2*(y*z - x*w), 1 - 2*(x*x + y*y))
                let scaledOffset = SIMD3<Float>(kf.scale.x * c.offset.x,
                                                 kf.scale.y * c.offset.y,
                                                 kf.scale.z * c.offset.z)
                let rotated = c0 * scaledOffset.x + c1 * scaledOffset.y + c2 * scaledOffset.z
                c.track.keyframes[i].translation = kf.translation + rotated
            }
            // Zero out the root's static translation in both transform and
            // baseTransform.  Save-load uses obj.transform for groups without
            // per-object keyframes and baseTransform for those that have any;
            // updating both keeps the data consistent either way.
            c.root.transform.columns.3     = SIMD4<Float>(0, 0, 0, 1)
            c.root.baseTransform.columns.3 = SIMD4<Float>(0, 0, 0, 1)
            print("[DEBUG] AppDelegate: baked offset \(c.offset) into \(c.track.keyframes.count) "
                + "keyframes of group root '\(c.name)'")
        }
        markDirty()
        vp.renderer?.invalidateAnimationCache()
        vp.needsDisplay = true
    }

    /// After a project opens, warn if any referenced HDR file is missing on disk.
    private func checkMissingHDRs(in vp: ViewportView) {
        var missing: [String] = []
        let lp = vp.renderSettings.lightingHDRPath
        if !lp.isEmpty, !FileManager.default.fileExists(atPath: AppSettings.expand(lp).path) {
            missing.append("Lighting HDR — " + lp)
        }
        let bp = vp.backgroundConfig.backgroundHDRPath
        if !bp.isEmpty, !FileManager.default.fileExists(atPath: AppSettings.expand(bp).path) {
            missing.append("Background HDR — " + bp)
        }
        guard !missing.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Missing HDR file" + (missing.count > 1 ? "s" : "")
        alert.informativeText = "This project references HDR file(s) that couldn't be found:\n\n"
            + missing.joined(separator: "\n")
            + "\n\nThe bundled environment is used until you re-link them via "
            + "File ▸ Open Lighting/Background HDR."
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Save Project

    @objc private func saveProject(_ sender: Any) {
        guard confirmSaveKeyframes() else { return }
        if let url = currentProjectURL {
            guard let viewport = viewportView else { return }
            do {
                try ProjectFile.save(to: url, viewport: viewport,
                                     windowLayout: currentWindowLayout())
                isDirty = false
                print("[DEBUG] AppDelegate: project saved to " + url.lastPathComponent)
            } catch {
                showErrorAlert(message: "Could not save project", detail: error.localizedDescription)
            }
        } else {
            presentSaveAsPanel()
        }
    }

    @objc private func saveProjectAs(_ sender: Any) {
        guard confirmSaveKeyframes() else { pendingQuitAfterSave = false; return }
        presentSaveAsPanel()
    }

    private func presentSaveAsPanel() {
        guard let window = window else { return }
        guard let viewport = viewportView else { return }

        let panel = NSSavePanel()
        panel.title                = "Save Project"
        panel.canCreateDirectories = true
        // Default to the folder the current project was opened from / last saved to,
        // falling back to the Projects folder for a never-saved project.
        let targetDir = currentProjectURL?.deletingLastPathComponent()
                     ?? defaultDirectory(for: "Projects")
        panel.directoryURL         = targetDir

        // Default filename:
        //   • Saved project → append the next "rev <letter>" suffix, e.g.
        //     `Project 1` → `Project 1 rev A`, `Project 1 rev A` → `Project 1 rev B`.
        //     The suffix is computed by scanning the project's own folder.
        //   • Unsaved project with a template-derived name → use it as-is.
        //   • Unsaved project with a loaded model → name from the first model's filename.
        //   • Empty fallback → "project.3dvp".
        if let current = currentProjectURL {
            let base = current.deletingPathExtension().lastPathComponent
            panel.nameFieldStringValue = nextProjectRevisionName(baseName: base,
                                                                  in: targetDir) + ".3dvp"
        } else if let suggested = suggestedProjectName {
            panel.nameFieldStringValue = suggested + ".3dvp"
        } else if let firstURL = viewport.sceneManager.objects.first?.sourceURL {
            panel.nameFieldStringValue = firstURL.deletingPathExtension().lastPathComponent + ".3dvp"
        } else {
            panel.nameFieldStringValue = "project.3dvp"
        }

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self = self else { return }
            // User cancelled — drop any pending-quit intent so the next Quit
            // doesn't ricochet into another save sheet.
            guard response == .OK, var url = panel.url else {
                self.pendingQuitAfterSave = false
                return
            }
            // Ensure the file always gets the .3dvp extension even if the user omitted it.
            if url.pathExtension.lowercased() != "3dvp" {
                url = url.appendingPathExtension("3dvp")
            }
            do {
                try ProjectFile.save(to: url, viewport: viewport,
                                     windowLayout: self.currentWindowLayout())
                self.currentProjectURL    = url
                self.suggestedProjectName = nil
                self.isDirty = false
                self.window?.title = "ThreeDViewport — "
                    + url.deletingPathExtension().lastPathComponent
                print("[DEBUG] AppDelegate: project saved as " + url.lastPathComponent)
                // If the user reached Save As via the Quit prompt, finish the
                // quit they started now that the save succeeded.
                if self.pendingQuitAfterSave {
                    self.pendingQuitAfterSave = false
                    NSApp.terminate(self)
                }
            } catch {
                self.pendingQuitAfterSave = false
                self.showErrorAlert(message: "Could not save project",
                                    detail: error.localizedDescription)
            }
        }
    }

    // MARK: - Save keyframe-coverage check

    /// Lists the friendly names of animatable units (camera, enabled lights,
    /// standalone objects, models, envelopes) that have NO keyframes anywhere — a
    /// likely "forgot to animate it" oversight.  Parts driven by their group /
    /// envelope are NOT flagged (that's correct coverage).
    private func unkeyframedUnits() -> [String] {
        guard let vp = viewportView else { return [] }
        var flagged: [String] = []

        // Camera.
        if vp.camera.keyframeTrack?.keyframes.isEmpty ?? true { flagged.append("Camera") }

        // Enabled lights.
        for (i, light) in vp.lightManager.lights.enumerated() where light.isEnabled {
            let track = i < vp.lightManager.keyframeTracks.count ? vp.lightManager.keyframeTracks[i] : nil
            if track?.keyframes.isEmpty ?? true {
                flagged.append("Light \(i + 1) — \(light.type.displayName)")
            }
        }

        // Objects / models / envelopes — one entry per root unit.
        let sm = vp.sceneManager
        func ownHasKeys(_ o: SceneObject) -> Bool { !(o.keyframeTrack?.keyframes.isEmpty ?? true) }
        var seenGroups = Set<Int>()
        for (idx, obj) in sm.objects.enumerated() where obj.parentIndex == nil {
            if obj.isEnvelope {
                let memberAnimated = sm.objects.contains { $0.parentIndex == idx && ownHasKeys($0) }
                if !ownHasKeys(obj) && !memberAnimated { flagged.append(obj.name) }
            } else if let gid = obj.groupID {
                guard seenGroups.insert(gid).inserted else { continue }
                let groupTrack = sm.groupKeyframeTracks[gid]
                let groupAnimated = !(groupTrack?.keyframes.isEmpty ?? true)
                    || sm.objects(inGroup: gid).contains { ownHasKeys($0) }
                if !groupAnimated { flagged.append(sm.groupName(for: gid)) }
            } else {
                if !ownHasKeys(obj) { flagged.append(obj.name) }
            }
        }
        return flagged
    }

    /// Warns (Save Anyway / Cancel) when some animatable units have no keyframes.
    /// Returns true to proceed with the save.
    private func confirmSaveKeyframes() -> Bool {
        let flagged = unkeyframedUnits()
        guard !flagged.isEmpty else { return true }
        let alert = NSAlert()
        alert.alertStyle      = .warning
        alert.messageText     = "Some items have no keyframes"
        alert.informativeText = "These have no animation keyframes — was that intentional?\n\n• "
            + flagged.joined(separator: "\n• ")
        alert.addButton(withTitle: "Save Anyway")   // first = default (Return)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - NSWindowDelegate — main window miniaturize tracking

    func windowWillMiniaturize(_ notification: Notification) {
        panelsHiddenByMiniaturize.removeAll()
        if let p = lightsPanel, p.isVisible {
            p.orderOut(nil)
            panelsHiddenByMiniaturize.insert("lights")
        }
        if let p = feedbackPanel, p.isVisible {
            p.orderOut(nil)
            panelsHiddenByMiniaturize.insert("feedback")
        }
        if let p = colorGradePanel, p.isVisible {
            p.orderOut(nil)
            panelsHiddenByMiniaturize.insert("colorGrade")
        }
        if let p = cameraPanel, p.isVisible {
            p.orderOut(nil)
            panelsHiddenByMiniaturize.insert("camera")
        }
        if let p = modelInspectorPanel, p.isVisible {
            p.orderOut(nil)
            panelsHiddenByMiniaturize.insert("modelInspector")
        }
        if let p = atmospherePanel, p.isVisible {
            p.orderOut(nil)
            panelsHiddenByMiniaturize.insert("atmosphere")
        }
        if let p = probeInspectorPanel, p.isVisible {
            p.orderOut(nil)
            panelsHiddenByMiniaturize.insert("probeInspector")
        }
        if let p = spinPanel, p.isVisible {
            p.orderOut(nil)
            panelsHiddenByMiniaturize.insert("spin")
        }
        if let p = orbitPathPanel, p.isVisible {
            p.orderOut(nil)
            panelsHiddenByMiniaturize.insert("orbit")
        }
        if let p = linearPathPanel, p.isVisible {
            p.orderOut(nil)
            panelsHiddenByMiniaturize.insert("linear")
        }
        if let p = curvePathPanel, p.isVisible {
            p.orderOut(nil)
            panelsHiddenByMiniaturize.insert("curve")
        }
        if let p = gaitPanel, p.isVisible {
            p.orderOut(nil)
            panelsHiddenByMiniaturize.insert("gait")
        }
        if let wc = timelineEditorWC, wc.window?.isVisible == true {
            wc.window?.orderOut(nil)
            panelsHiddenByMiniaturize.insert("timeline")
        }
        if let wc = effectsGridWC, wc.window?.isVisible == true {
            wc.window?.orderOut(nil)
            panelsHiddenByMiniaturize.insert("effects")
        }
        print("[DEBUG] AppDelegate: main window miniaturizing — hid: "
            + panelsHiddenByMiniaturize.sorted().joined(separator: ", "))
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        restoreHiddenPanels()
    }

    // Track every user-initiated move or resize so currentWindowLayout() always
    // has an up-to-date frame, even if NSWindow.frame lags in some edge cases.
    func windowDidMove(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        trackedMainWindowFrame = window?.frame
    }

    func windowDidResize(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        trackedMainWindowFrame = window?.frame
    }

    // After a sheet opens, clear any stale pendingMainWindowFrame from a previous
    // project load so the Save As (or any other) sheet closing doesn't try to
    // restore an outdated position.
    func windowWillBeginSheet(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        pendingMainWindowFrame = nil
    }

    // macOS plays a sheet-dismissal animation on the parent window AFTER the
    // completion handler fires.  That animation overrides the setFrame we called
    // in applyWindowLayout.  windowDidEndSheet fires once the animation is done,
    // giving us a clean moment to re-apply the saved position.
    func windowDidEndSheet(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        guard let frame = pendingMainWindowFrame else { return }
        pendingMainWindowFrame = nil
        window?.setFrame(frame, display: true)
        trackedMainWindowFrame = frame
    }

    private func restoreHiddenPanels() {
        if panelsHiddenByMiniaturize.contains("lights")     { lightsPanel?.makeKeyAndOrderFront(nil) }
        if panelsHiddenByMiniaturize.contains("feedback")   { feedbackPanel?.makeKeyAndOrderFront(nil) }
        if panelsHiddenByMiniaturize.contains("colorGrade") { colorGradePanel?.makeKeyAndOrderFront(nil) }
        if panelsHiddenByMiniaturize.contains("camera")         { cameraPanel?.makeKeyAndOrderFront(nil) }
        if panelsHiddenByMiniaturize.contains("modelInspector") { modelInspectorPanel?.makeKeyAndOrderFront(nil) }
        if panelsHiddenByMiniaturize.contains("atmosphere")     { atmospherePanel?.makeKeyAndOrderFront(nil) }
        if panelsHiddenByMiniaturize.contains("probeInspector") { probeInspectorPanel?.makeKeyAndOrderFront(nil) }
        if panelsHiddenByMiniaturize.contains("spin")   { spinPanel?.makeKeyAndOrderFront(nil) }
        if panelsHiddenByMiniaturize.contains("orbit")  { orbitPathPanel?.makeKeyAndOrderFront(nil) }
        if panelsHiddenByMiniaturize.contains("linear") { linearPathPanel?.makeKeyAndOrderFront(nil) }
        if panelsHiddenByMiniaturize.contains("curve")  { curvePathPanel?.makeKeyAndOrderFront(nil) }
        if panelsHiddenByMiniaturize.contains("gait")   { gaitPanel?.makeKeyAndOrderFront(nil) }
        if panelsHiddenByMiniaturize.contains("timeline")       { timelineEditorWC?.showWindow(nil) }
        if panelsHiddenByMiniaturize.contains("effects")        { effectsGridWC?.showWindow(nil) }
        if !panelsHiddenByMiniaturize.isEmpty {
            print("[DEBUG] AppDelegate: restored panels: "
                + panelsHiddenByMiniaturize.sorted().joined(separator: ", "))
        }
        panelsHiddenByMiniaturize.removeAll()
    }

    // MARK: - Show Main Window

    @objc private func showMainWindow(_ sender: Any) {
        if let w = window {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        }
        // Restore any secondary windows that were hidden by the miniaturize
        if !panelsHiddenByMiniaturize.isEmpty {
            restoreHiddenPanels()
        }
    }

    // MARK: - Error helper

    private func showErrorAlert(message: String, detail: String) {
        guard let window = window else { return }
        let alert = NSAlert()
        alert.messageText     = message
        alert.informativeText = detail
        alert.alertStyle      = .warning
        alert.beginSheetModal(for: window)
        print("[DEBUG] AppDelegate: alert — " + message + " — " + detail)
    }

    // MARK: - Rendering Toggles

    @objc private func toggleColorMode(_ sender: Any) {
        // Cycle Greyscale → Color → Black+White (matches the G key).
        guard let rs = viewportView?.renderSettings else { return }
        rs.colorMode = rs.colorMode.next
        print("[DEBUG] AppDelegate: render mode → " + rs.colorMode.displayName)
    }

    @objc private func toggleWireframe(_ sender: Any) {
        viewportView?.renderer?.isWireframe.toggle()
        markDirty()
        print("[DEBUG] AppDelegate: wireframe toggled to "
            + String(viewportView?.renderer?.isWireframe ?? false))
    }

    @objc private func toggleAxesGizmo(_ sender: Any) {
        viewportView?.renderSettings.showAxesGizmo.toggle()
        print("[DEBUG] AppDelegate: axesGizmo toggled to "
            + String(viewportView?.renderSettings.showAxesGizmo ?? false))
    }

    @objc private func toggleLoopPlayback(_ sender: Any) {
        viewportView?.timeline.isLooping.toggle()
        markDirty()
        print("[DEBUG] AppDelegate: loopPlayback toggled to "
            + String(viewportView?.timeline.isLooping ?? false))
    }

    // MARK: - Add Follow Camera Keyframe

    @objc private func addFollowCameraKeyframe(_ sender: Any) {
        guard let viewport = viewportView else { return }
        viewport.addFollowCameraKeyframeAtCurrentTime()
        markDirty()
        timelineEditorWC?.editorView.needsDisplay = true
    }

    // Keep menu item checkmarks in sync with current rendering state.
    /// True when the active selection is an editable object/model — not the camera,
    /// a light, the director, or a fog/particle (Effects) lane.  The control mode is
    /// the reliable signal; the timeline lane additionally catches fog/particles
    /// (which have no viewport control mode of their own).
    private var isObjectOrModelSelected: Bool {
        switch viewportView?.currentTrackRef {
        case .object, .group: break
        default:              return false
        }
        if let tl = timelineEditorWC?.editorView.selectedTrackRef {
            switch tl {
            case .fog, .particles: return false
            default:               break
            }
        }
        return true
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(replaceSelectedModel(_:)) {
            // All-or-nothing: Replace works on a WHOLE model (Model mode) or a
            // standalone single object — never an individual part of a multi-part
            // model (replacing one part swaps the whole group with mismatched names
            // and corrupts it).  Disabled when no object is selected.
            guard let vp = viewportView, let sel = vp.sceneManager.selectedObject else { return false }
            if vp.controlMode == .model { return true }       // whole model
            return sel.groupID == nil && !sel.isEnvelope      // standalone single object
        }
        if menuItem.action == #selector(addFollowCameraKeyframe(_:)) {
            // Disabled when no model is in the scene (need something to follow).
            return viewportView?.sceneManager.primaryObject != nil
        }
        if menuItem.action == #selector(glueObjects(_:)) {
            // Need at least two root objects to bind together.
            return (viewportView?.sceneManager.rootObjectIndicesSorted.count ?? 0) >= 2
        }
        if menuItem.action == #selector(unglueSelected(_:))
            || menuItem.action == #selector(editGlueMembers(_:)) {
            // Enabled only when the current selection is an envelope.
            return viewportView?.sceneManager.selectedObject?.isEnvelope == true
        }
        if menuItem.action == #selector(exportModel(_:)) {
            return isObjectOrModelSelected
        }
        if menuItem.action == #selector(duplicateObject(_:)) {
            // Same object/model gate, plus needs a source file to reload from (so an
            // envelope / geometryless selection is excluded).
            return isObjectOrModelSelected
                && viewportView?.sceneManager.selectedObject?.sourceURL != nil
        }
        if menuItem.action == #selector(toggleColorMode(_:)) {
            // Three modes can't be shown by a single checkmark, so reflect the
            // current mode in the title instead and leave the checkmark off.
            let mode = viewportView?.renderSettings.colorMode ?? .color
            menuItem.title = "Render Mode: " + mode.displayName
            menuItem.state = .off
        }
        if menuItem.action == #selector(toggleWireframe(_:)) {
            let isWireframe = viewportView?.renderer?.isWireframe ?? false
            menuItem.state = isWireframe ? .on : .off
        }
        if menuItem.action == #selector(toggleAxesGizmo(_:)) {
            let isOn = viewportView?.renderSettings.showAxesGizmo ?? false
            menuItem.state = isOn ? .on : .off
        }
        if menuItem.action == #selector(toggleLoopPlayback(_:)) {
            let isOn = viewportView?.timeline.isLooping ?? false
            menuItem.state = isOn ? .on : .off
        }
        if menuItem.action == #selector(toggleVectorPath(_:)) {
            menuItem.state = (viewportView?.motionVectorsVisible ?? false) ? .on : .off
        }
        if menuItem.action == #selector(toggleMarks(_:)) {
            menuItem.state = (viewportView?.probeConfig.marksVisible ?? false) ? .on : .off
        }
        if menuItem.action == #selector(toggleLoopInOut(_:)) {
            menuItem.state = (viewportView?.timeline.loopInOut ?? false) ? .on : .off
        }
        if menuItem.action == #selector(clearTimelineInOut(_:)) {
            let tl = viewportView?.timeline
            return tl?.inPoint != nil || tl?.outPoint != nil
        }
        return true
    }

    // MARK: - Settings

    /// Launches a second, independent instance of this app (separate process) so the
    /// cross-instance copy/paste workflow has another window to paste into.
    @objc private func openNewInstance(_ sender: Any) {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error = error {
                print("[DEBUG] AppDelegate: openNewInstance failed: \(error)")
            }
        }
    }

    @objc private func showSettings(_ sender: Any) {
        // Toggle closed if already showing.
        if let panel = settingsPanel, panel.isVisible {
            panel.orderOut(nil)
            return
        }

        let isNew = settingsPanel == nil
        let panel: NSPanel
        if let existing = settingsPanel {
            panel = existing
        } else {
            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
                styleMask:   [.titled, .closable, .utilityWindow],
                backing:     .buffered,
                defer:       false
            )
            panel.title             = "Settings"
            panel.isFloatingPanel   = true
            panel.hidesOnDeactivate = false
            settingsPanel = panel
        }

        // Install a fresh view every time it opens so the working copies re-seed
        // from the current AppSettings — Cancel must truly discard edits, and a
        // reopen must show the saved values, not the last (possibly cancelled) ones.
        let hosting = NSHostingView(rootView: SettingsPanel(
            settings: AppSettings.shared,
            onClose:  { [weak self] in self?.settingsPanel?.orderOut(nil) }))
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        if isNew { panel.center() }

        panel.makeKeyAndOrderFront(nil)
        print("[DEBUG] AppDelegate: settings panel opened")
    }

    // MARK: - Lights & Background Inspector (Phase 7)

    @objc private func showLightsInspector(_ sender: Any) {
        // Toggle: if already visible, close it; otherwise create and show.
        if let panel = lightsPanel {
            if panel.isVisible {
                panel.orderOut(nil)
            } else {
                panel.makeKeyAndOrderFront(nil)
            }
            return
        }

        guard let viewport = viewportView else { return }

        let panel = KeyForwardingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 296, height: 720),
            styleMask:   [.titled, .closable, .miniaturizable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        panel.title         = "Lights & Background"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.forwardTarget          = viewport   // unhandled keys → viewport
        panel.level                  = .normal    // don't float above other applications
        panel.hidesOnDeactivate = false

        let inspectorView = LightsInspectorPanel(
            lightManager:     viewport.lightManager,
            backgroundConfig: viewport.backgroundConfig,
            renderSettings:   viewport.renderSettings,
            clipboard:        viewport.coordinateClipboard,
            camera:           viewport.camera,
            // Conditional auto-stamp after Paste/Z on a light's Position/Target:
            // stamp only when that light's track already has keyframes.
            onAutoStampLight: { [weak viewport] i in
                guard let vp = viewport,
                      i < vp.lightManager.keyframeTracks.count,
                      let track = vp.lightManager.keyframeTracks[i],
                      !track.keyframes.isEmpty else { return }
                vp.addLightKeyframeAtCurrentTime(forLightAt: i)
            },
            onAutoKeyframeLight: { [weak viewport] i in viewport?.autoKeyframeOnEdit(.light(i)) }
        )

        let hostingView = FirstClickHostingView(rootView: inspectorView)
        panel.contentView = hostingView

        // Position top-right of the main window if possible.
        if let win = window {
            let winFrame  = win.frame
            let panelSize = panel.frame.size
            let originX   = winFrame.maxX - panelSize.width - 20
            let originY   = winFrame.maxY - panelSize.height - 40
            panel.setFrameOrigin(NSPoint(x: originX, y: originY))
        } else {
            panel.center()
        }

        lightsPanel = panel

        // When the panel becomes key, switch the viewport to Light mode.  The
        // resulting onControlModeChanged carries .light(lightManager.selectedIndex),
        // so the Timeline Editor lane lines up with the currently-selected light.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object:  panel,
            queue:   .main
        ) { [weak viewport] _ in
            viewport?.setControlMode(.light)
        }

        panel.makeKeyAndOrderFront(nil)
        print("[DEBUG] AppDelegate: lights inspector panel opened")
    }

    // MARK: - Feedback Panel

    @objc private func showFeedbackPanel(_ sender: Any) {
        if let panel = feedbackPanel {
            panel.isVisible ? panel.orderOut(nil) : panel.makeKeyAndOrderFront(nil)
            return
        }

        guard let viewport = viewportView else { return }

        let panel = KeyForwardingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 296, height: 280),
            styleMask:   [.titled, .closable, .miniaturizable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        panel.title              = "Feedback"
        panel.isFloatingPanel    = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.forwardTarget          = viewport   // unhandled keys → viewport
        panel.level                  = .normal    // don't float above other applications
        panel.hidesOnDeactivate  = false

        let feedbackView = FeedbackPanelWrapper(
            settings:  viewport.feedbackSettings,
            processor: viewport.feedbackProcessor
        )
        panel.contentView = FirstClickHostingView(rootView: feedbackView)

        if let win = window {
            let winFrame  = win.frame
            let panelSize = panel.frame.size
            let originX   = winFrame.maxX - panelSize.width - 20
            let originY   = winFrame.maxY - panelSize.height - 40 - 740  // below lights panel
            panel.setFrameOrigin(NSPoint(x: originX, y: max(originY, 40)))
        } else {
            panel.center()
        }

        feedbackPanel = panel
        panel.makeKeyAndOrderFront(nil)
        print("[DEBUG] AppDelegate: feedback panel opened")
    }

    // MARK: - Color Grade Panel

    @objc private func showColorGradePanel(_ sender: Any) {
        if let panel = colorGradePanel {
            panel.isVisible ? panel.orderOut(nil) : panel.makeKeyAndOrderFront(nil)
            return
        }

        guard let viewport = viewportView else { return }

        let panel = KeyForwardingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 296, height: 200),
            styleMask:   [.titled, .closable, .miniaturizable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        panel.title              = "Color Grade"
        panel.isFloatingPanel    = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.forwardTarget          = viewport   // unhandled keys → viewport
        panel.level                  = .normal    // don't float above other applications
        panel.hidesOnDeactivate  = false

        let gradeView = ColorGradePanel(settings: viewport.colorGradeSettings)
        panel.contentView = FirstClickHostingView(rootView: gradeView)

        if let win = window {
            let winFrame  = win.frame
            let panelSize = panel.frame.size
            let originX   = winFrame.maxX - panelSize.width - 20
            // Position below lights panel (~720 tall) and feedback panel (~280 tall)
            let originY   = winFrame.maxY - panelSize.height - 40 - 740 - 300
            panel.setFrameOrigin(NSPoint(x: originX, y: max(originY, 40)))
        } else {
            panel.center()
        }

        colorGradePanel = panel
        panel.makeKeyAndOrderFront(nil)
        print("[DEBUG] AppDelegate: color grade panel opened")
    }

    // MARK: - Atmosphere Panel

    @objc private func showAtmospherePanel(_ sender: Any) {
        if let panel = atmospherePanel {
            panel.isVisible ? panel.orderOut(nil) : panel.makeKeyAndOrderFront(nil)
            return
        }

        guard let viewport = viewportView else { return }

        let panel = KeyForwardingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 296, height: 280),
            styleMask:   [.titled, .closable, .miniaturizable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        panel.title              = "Atmosphere"
        panel.isFloatingPanel    = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.forwardTarget          = viewport   // unhandled keys → viewport
        panel.level                  = .normal    // don't float above other applications
        panel.hidesOnDeactivate  = false

        // Fog lock lives on the viewport (not observable) — feed it to the panel.
        viewport.atmospherePanelState.fogLockedProvider = { [weak viewport] in viewport?.fogLocked ?? false }

        let atmoView = AtmospherePanel(
            fog: viewport.fogSettings,
            particleManager: viewport.particleManager,
            clipboard: viewport.coordinateClipboard,
            sections: viewport.atmospherePanelState,
            onStampFog:       { [weak viewport] in viewport?.addFogKeyframeAtCurrentTime() },
            onClearFog:       { [weak viewport] in viewport?.clearFogKeyframes() },
            onStampParticles: { [weak viewport] in
                guard let vp = viewport else { return }
                vp.addParticleKeyframeAtCurrentTime(forEmitterAt: vp.particleManager.selectedIndex)
            },
            onClearParticles: { [weak viewport] in
                guard let vp = viewport else { return }
                vp.clearParticleKeyframes(at: vp.particleManager.selectedIndex)
            },
            // Conditional auto-stamp after Paste/Z on Fog/Emitter Position: stamp
            // only when the corresponding track already has keyframes.
            onAutoStampFog: { [weak viewport] in
                guard let vp = viewport,
                      let track = vp.fogSettings.keyframeTrack,
                      !track.keyframes.isEmpty else { return }
                vp.addFogKeyframeAtCurrentTime()
            },
            onAutoStampParticles: { [weak viewport] in
                guard let vp = viewport else { return }
                let i = vp.particleManager.selectedIndex
                guard i < vp.particleManager.emitters.count,
                      let track = vp.particleManager.emitters[i].keyframeTrack,
                      !track.keyframes.isEmpty else { return }
                vp.addParticleKeyframeAtCurrentTime(forEmitterAt: i)
            },
            onAutoKeyframeFog: { [weak viewport] in viewport?.autoKeyframeOnEdit(.fog) },
            onAutoKeyframeParticles: { [weak viewport] in
                guard let vp = viewport else { return }
                vp.autoKeyframeOnEdit(.particles(vp.particleManager.selectedIndex))
            })
        panel.contentView = FirstClickHostingView(rootView: atmoView)

        if let win = window {
            let winFrame  = win.frame
            let panelSize = panel.frame.size
            let originX   = winFrame.maxX - panelSize.width - 20
            let originY   = winFrame.maxY - panelSize.height - 40 - 740 - 300 - 220
            panel.setFrameOrigin(NSPoint(x: originX, y: max(originY, 40)))
        } else {
            panel.center()
        }

        atmospherePanel = panel
        panel.makeKeyAndOrderFront(nil)
        print("[DEBUG] AppDelegate: atmosphere panel opened")
    }

    // MARK: - Camera Panel

    /// Refreshes the Camera panel's Follow Target list from the current scene.
    /// Call after any scene mutation (project load, model open/replace/remove)
    /// so the picker never shows stale objects from a previous scene.
    /// The Timeline Editor's first-column display name for a selection: a group's
    /// (possibly duplicate-suffixed) display name for a model, else the object name.
    private func timelineDisplayName(for targets: [SceneObject]) -> String {
        guard let first = targets.first, let sm = viewportView?.sceneManager else { return "" }
        return first.groupID.map { sm.groupName(for: $0) } ?? sm.displayName(for: first)
    }

    private func refreshCameraFollowTargets() {
        guard let viewport = viewportView else { return }
        // Sort alphabetically (natural order so `head10` follows `head2`,
        // not `head1`).  "None — Free Camera" is rendered separately at
        // the top of the picker, so it isn't in this list.
        // Dedupe — two robots both export "head" / "ankle_L" / etc.; SwiftUI
        // Picker's id:\.self crashes warnings on duplicate strings, and a
        // picker with two identical tags can't represent a stable selection.
        // Use the same display names as the Timeline Editor's first column: a group
        // root shows the group's (possibly suffixed) name; parts/standalone show
        // their object name.  Envelopes (glued assemblies) are included so the whole
        // unit can be followed — they appear in the timeline as a standalone row.
        let sm = viewport.sceneManager
        var seen = Set<String>()
        viewport.cameraPanelState.availableObjectNames =
            sm.objects
                .map { sm.displayName(for: $0) }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .filter { seen.insert($0).inserted }
        // Reconcile the chosen target with the new list.  Older projects stored a
        // grouped model's ROOT object name (e.g. "hand"); migrate it to the group's
        // display name (e.g. "hand 1") so the picker shows a valid selection.  If
        // the target is truly gone, fall back to free camera.
        if let chosen = viewport.cameraPanelState.followTargetName,
           !viewport.cameraPanelState.availableObjectNames.contains(chosen) {
            if let root = sm.objects.first(where: {
                $0.name == chosen && $0.parentIndex == nil && $0.groupID != nil }) {
                viewport.cameraPanelState.followTargetName = sm.groupName(for: root.groupID!)
            } else {
                viewport.cameraPanelState.followTargetName = nil
            }
        }
    }

    @objc private func showCameraPanel(_ sender: Any) {
        // Refresh the picker's object-name list every time the menu item is
        // invoked, so newly-loaded models appear without requiring a restart
        // of the panel.  Cheap enough to do unconditionally.
        refreshCameraFollowTargets()

        if let panel = cameraPanel {
            panel.isVisible ? panel.orderOut(nil) : panel.makeKeyAndOrderFront(nil)
            return
        }

        guard let viewport = viewportView else { return }

        let panel = KeyForwardingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 296, height: 260),
            styleMask:   [.titled, .closable, .miniaturizable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        panel.title              = "Camera"
        panel.isFloatingPanel    = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.forwardTarget          = viewport   // unhandled keys → viewport
        panel.level                  = .normal    // don't float above other applications
        panel.hidesOnDeactivate  = false

        let cameraView = CameraPanel(
            state: viewport.cameraPanelState,
            clipboard: viewport.coordinateClipboard,
            onStampKeyframe: { [weak self, weak viewport] in
                viewport?.addCameraKeyframeFromPanel()
                self?.markDirty()
            },
            onRefresh: { [weak viewport] in viewport?.refreshCameraPanelState() }
        )
        panel.contentView = FirstClickHostingView(rootView: cameraView)
        viewport.refreshCameraPanelState()   // seed values so the panel shows them immediately

        if let win = window {
            let winFrame  = win.frame
            let panelSize = panel.frame.size
            let originX   = winFrame.maxX - panelSize.width - 20
            // Position below the other utility panels (lights ~720 + feedback ~280 + grade ~220).
            let originY   = winFrame.maxY - panelSize.height - 40 - 740 - 300 - 220
            panel.setFrameOrigin(NSPoint(x: originX, y: max(originY, 40)))
        } else {
            panel.center()
        }

        cameraPanel = panel

        // When the panel becomes key, switch the viewport to Camera mode (also
        // highlights the camera lane in the Timeline Editor via onControlModeChanged).
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object:  panel,
            queue:   .main
        ) { [weak viewport] _ in
            viewport?.setControlMode(.camera)
        }

        panel.makeKeyAndOrderFront(nil)
        print("[DEBUG] AppDelegate: camera panel opened")
    }

    // MARK: - Model Inspector

    @objc private func showModelInspector(_ sender: Any) {
        if let panel = modelInspectorPanel {
            panel.isVisible ? panel.orderOut(nil) : panel.makeKeyAndOrderFront(nil)
            return
        }

        guard let viewport = viewportView else { return }

        let state = ModelInspectorState()

        // World-space position provider — mirrors how SceneGeometryEncoder builds
        // the model matrix (group transform × object transform), so the Position
        // field tracks model/group animation, which lives in the group transform
        // rather than the object's own transform.
        state.worldPosition = { [weak viewport] obj in
            let world: matrix_float4x4
            if let sm = viewport?.sceneManager,
               let gid = obj.groupID, let gt = sm.groupTransforms[gid] {
                world = gt * obj.transform
            } else {
                world = obj.transform
            }
            let t = world.columns.3
            return SIMD3<Float>(t.x, t.y, t.z)
        }

        // Group write — translate the GROUP transform by the world-space delta
        // that lands the anchor at the requested position.  Lives in the
        // animation layer (groupTransforms[gid]) just like Model-mode drag, so
        // a slider edit at time t1 doesn't shift the rendered position at any
        // other keyframe time.  Without stamping, the edit is reset to the
        // keyframe-evaluated value the next time the playhead moves —
        // intentional, matching translateGroup's behavior.
        state.setGroupWorldPosition = { [weak viewport] anchor, desiredWorld in
            guard let sm = viewport?.sceneManager,
                  let gid = anchor.groupID else { return }
            var gt           = sm.groupTransforms[gid] ?? matrix_identity_float4x4
            let world4       = gt * anchor.transform.columns.3
            let currentWorld = SIMD3<Float>(world4.x, world4.y, world4.z)
            let worldDelta   = desiredWorld - currentWorld
            let tCol         = gt.columns.3
            let newT         = SIMD3<Float>(tCol.x + worldDelta.x,
                                            tCol.y + worldDelta.y,
                                            tCol.z + worldDelta.z)
            // Match translateGroup's ±positionBound clamp on the group translation.
            let clamped = simd_clamp(newT,
                                     SIMD3<Float>(repeating: -SceneLimits.positionBound),
                                     SIMD3<Float>(repeating:  SceneLimits.positionBound))
            if clamped != newT { LimitReporter.report("Model position") }
            gt.columns.3 = SIMD4<Float>(clamped.x, clamped.y, clamped.z, tCol.w)
            sm.groupTransforms[gid] = gt
        }

        // World rotation (YXZ Euler degrees) — mirrors worldPosition: include the
        // group transform if any, so the rotation field tracks group animation too.
        state.worldRotationMatrix = { [weak viewport] obj in
            if let sm = viewport?.sceneManager,
               let gid = obj.groupID, let gt = sm.groupTransforms[gid] {
                return gt * obj.transform
            }
            return obj.transform
        }

        // World-effective scale — mirrors worldPosition: decompose the combined
        // group × object matrix so grouped parts show the effective on-screen scale.
        state.worldScale = { [weak viewport] obj in
            let world: matrix_float4x4
            if let sm = viewport?.sceneManager,
               let gid = obj.groupID, let gt = sm.groupTransforms[gid] {
                world = gt * obj.transform
            } else {
                world = obj.transform
            }
            return TransformMath.scale(of: world)
        }

        // Conditional auto-stamp: after a Paste/Z on Position or Rotation, stamp
        // an object/group keyframe at the current playhead — but only if the
        // relevant track already has keyframes (so static setup never auto-keys).
        state.onAutoStamp = { [weak viewport] in
            guard let viewport,
                  let selected = viewport.sceneManager.selectedObject else { return }
            if let gid = selected.groupID {
                guard let track = viewport.sceneManager.groupKeyframeTracks[gid],
                      !track.keyframes.isEmpty else { return }
                viewport.addGroupKeyframeAtCurrentTime(for: gid)
            } else {
                guard let track = selected.keyframeTrack,
                      !track.keyframes.isEmpty else { return }
                viewport.addKeyframeAtCurrentTime(forObjectAt: viewport.sceneManager.selectedIndex)
            }
        }
        // Transform/opacity slider edit → auto-keyframe-on-edit (gated by its settings).
        state.onSliderEdited = { [weak viewport] in
            guard let viewport, let selected = viewport.sceneManager.selectedObject else { return }
            let ref: TrackRef = selected.groupID.map { .group($0) }
                              ?? .object(viewport.sceneManager.selectedIndex)
            viewport.autoKeyframeOnEdit(ref)
        }

        // Group rotate — pivot the GROUP transform about the anchor's current
        // world position so the model spins as a rigid body in place.  Lives
        // in the animation layer (groupTransforms[gid]), same as the group
        // position writer; stamp at the current time to record it.
        state.setGroupWorldRotation = { [weak viewport] anchor, desiredEuler in
            guard let sm = viewport?.sceneManager,
                  let gid = anchor.groupID else { return }
            let gt           = sm.groupTransforms[gid] ?? matrix_identity_float4x4
            let worldAnchor  = gt * anchor.transform
            let P4           = worldAnchor.columns.3
            let P            = SIMD3<Float>(P4.x, P4.y, P4.z)
            // Delta rotation in world space = R_new × R_old⁻¹  (pure rotations).
            let oldWorldR    = TransformMath.pureRotation(of: worldAnchor)
            let newWorldR    = TransformMath.matrixFromEuler(desiredEuler)
            let deltaR       = newWorldR * simd_inverse(oldWorldR)
            // gt_new = T(P) · ΔR · T(-P) · gt
            let pivotXform   = TransformMath.translation(P)
                             * deltaR
                             * TransformMath.translation(-P)
            sm.groupTransforms[gid] = pivotXform * gt
        }

        // Group scale — pivot-scale the GROUP transform about the anchor's
        // current world position by the per-axis delta (newScale / oldScale).
        // Same animation-layer semantics as group position/rotation.
        state.setGroupWorldScale = { [weak viewport] anchor, desiredWorldScale in
            guard let sm = viewport?.sceneManager,
                  let gid = anchor.groupID else { return }
            let gt           = sm.groupTransforms[gid] ?? matrix_identity_float4x4
            let worldAnchor  = gt * anchor.transform
            let P4           = worldAnchor.columns.3
            let P            = SIMD3<Float>(P4.x, P4.y, P4.z)
            // Per-axis delta scale.  Guard against div-by-zero (the slider's
            // 0.01 lower bound makes this almost impossible, but be safe).
            let oldWorldScale = TransformMath.scale(of: worldAnchor)
            let safeOld = SIMD3<Float>(
                abs(oldWorldScale.x) > 1e-6 ? oldWorldScale.x : 1,
                abs(oldWorldScale.y) > 1e-6 ? oldWorldScale.y : 1,
                abs(oldWorldScale.z) > 1e-6 ? oldWorldScale.z : 1
            )
            let deltaS = desiredWorldScale / safeOld
            var S = matrix_identity_float4x4
            S.columns.0.x = deltaS.x
            S.columns.1.y = deltaS.y
            S.columns.2.z = deltaS.z
            // gt_new = T(P) · S · T(-P) · gt
            let pivotXform   = TransformMath.translation(P)
                             * S
                             * TransformMath.translation(-P)
            sm.groupTransforms[gid] = pivotXform * gt
        }

        // Push current selection immediately.
        let selected = viewport.sceneManager.selectedObject
        let targets: [SceneObject]
        if let gid = selected?.groupID {
            targets = viewport.sceneManager.objects(inGroup: gid)
        } else if let obj = selected {
            targets = [obj]
        } else {
            targets = []
        }
        state.update(targets: targets, displayName: timelineDisplayName(for: targets))

        // Wire callbacks.
        state.onRedraw = { [weak viewport] in viewport?.needsDisplay = true }
        state.onDirty  = { [weak self] in self?.markDirty() }
        state.isPlaying = { [weak viewport] in viewport?.timeline.isPlaying ?? false }
        state.isExporting = { [weak self] in self?.exportState.isExporting ?? false }
        state.isLockedProvider = { [weak viewport] in
            viewport?.sceneManager.selectedObject?.isLocked ?? false
        }
        state.onRebuildNormals = { [weak viewport] mode, targets in
            viewport?.applyNormalMode(mode, toTargets: targets)
        }
        state.onRevealInFinder = { [weak viewport] in
            guard let url = viewport?.sceneManager.selectedObject?.sourceURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        state.favoritesEligible = { [weak self] targets in
            self?.favoritesEligibility(for: targets) ?? false
        }
        state.onAddToFavorites = { [weak self] in self?.addSelectedToFavorites() }

        let panel = KeyForwardingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 352, height: 440),
            styleMask:   [.titled, .closable, .miniaturizable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        panel.title              = "Model Inspector"
        panel.isFloatingPanel    = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.forwardTarget          = viewport   // unhandled keys → viewport
        panel.level                  = .normal    // don't float above other applications
        panel.hidesOnDeactivate  = false

        panel.contentView = FirstClickHostingView(rootView: ModelInspectorPanel(
            state: state, clipboard: viewport.coordinateClipboard))

        if let win = window {
            let winFrame  = win.frame
            let panelSize = panel.frame.size
            let originX   = winFrame.minX + 20
            let originY   = winFrame.maxY - panelSize.height - 40
            panel.setFrameOrigin(NSPoint(x: originX, y: originY))
        } else {
            panel.center()
        }

        modelInspectorState  = state
        modelInspectorPanel  = panel

        // When the panel becomes key, align the viewport's control mode with the
        // selection — group → Model, single non-grouped → Object.  setControlMode
        // also fires onControlModeChanged, which the Timeline Editor uses to
        // highlight the corresponding lane.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object:  panel,
            queue:   .main
        ) { [weak viewport] _ in
            guard let viewport,
                  let selected = viewport.sceneManager.selectedObject else { return }
            let mode: ControlMode = (selected.groupID != nil) ? .model : .object
            viewport.setControlMode(mode)
        }

        panel.makeKeyAndOrderFront(nil)
        print("[DEBUG] AppDelegate: model inspector panel opened")
    }

    // MARK: - Probe Inspector

    @objc private func showProbeInspector(_ sender: Any) {
        if let panel = probeInspectorPanel {
            if panel.isVisible {
                panel.orderOut(nil)
            } else {
                // Gizmo visibility is the saved, user-controlled state (panel toggle);
                // opening the panel no longer forces it on.
                panel.makeKeyAndOrderFront(nil)
            }
            return
        }

        guard let viewport = viewportView else { return }

        let panel = KeyForwardingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 296, height: 300),
            styleMask:   [.titled, .closable, .miniaturizable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        panel.title              = "Probe"
        panel.isFloatingPanel    = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.forwardTarget          = viewport   // unhandled keys → viewport
        panel.level                  = .normal    // don't float above other applications
        panel.hidesOnDeactivate  = false

        panel.contentView = FirstClickHostingView(rootView: ProbeInspectorPanel(
            probe: viewport.probeConfig, clipboard: viewport.coordinateClipboard,
            onMarkPosition: { [weak self] in self?.promptForMark() },
            onVisibilityChanged: { [weak self] in self?.markDirty() }))

        if let win = window {
            let winFrame  = win.frame
            let panelSize = panel.frame.size
            let originX   = winFrame.minX + 20
            let originY   = winFrame.maxY - panelSize.height - 40
            panel.setFrameOrigin(NSPoint(x: originX, y: originY))
        } else {
            panel.center()
        }

        probeInspectorPanel = panel
        panel.makeKeyAndOrderFront(nil)
        print("[DEBUG] AppDelegate: probe inspector panel opened")
    }

    // MARK: - Probe marks

    /// Prompts for a name + colour, then saves the current probe position as a mark.
    private func promptForMark() {
        guard let viewport = viewportView else { return }
        let probe = viewport.probeConfig

        let alert = NSAlert()
        alert.messageText     = "Mark Position"
        alert.informativeText = "Name this mark and choose a colour. It's saved at the probe's current position."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let accessory  = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 58))
        let nameLabel  = NSTextField(labelWithString: "Name:")
        nameLabel.frame = NSRect(x: 0, y: 32, width: 52, height: 20)
        let nameField  = NSTextField(frame: NSRect(x: 56, y: 30, width: 184, height: 24))
        nameField.stringValue = "Mark \(probe.marks.count + 1)"
        let colorLabel = NSTextField(labelWithString: "Colour:")
        colorLabel.frame = NSRect(x: 0, y: 2, width: 52, height: 20)
        let well       = NSColorWell(frame: NSRect(x: 56, y: 0, width: 48, height: 24))
        well.color     = lastMarkColor
        accessory.addSubview(nameLabel); accessory.addSubview(nameField)
        accessory.addSubview(colorLabel); accessory.addSubview(well)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = nameField

        let response = alert.runModal()
        well.deactivate()
        NSColorPanel.shared.orderOut(nil)
        guard response == .alertFirstButtonReturn else { return }

        let rgb   = well.color.usingColorSpace(.sRGB) ?? well.color
        let color = SIMD3<Float>(Float(rgb.redComponent), Float(rgb.greenComponent), Float(rgb.blueComponent))
        lastMarkColor = well.color
        let trimmed = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let name    = trimmed.isEmpty ? "Mark \(probe.marks.count + 1)" : trimmed

        probe.marks.append(ProbeMark(name: name, position: probe.position, color: color))
        probe.selectedMarkIndex = probe.marks.count - 1
        probe.marksVisible = true   // reveal so the new mark is visible immediately
        markDirty()
        print("[DEBUG] AppDelegate: added mark '\(name)' at \(probe.position)")
    }

    /// Toggles visibility of all marks (K key / menu).
    @objc private func toggleMarks(_ sender: Any) {
        guard let viewport = viewportView else { return }
        viewport.probeConfig.marksVisible.toggle()
        if !viewport.probeConfig.marksVisible { viewport.overlayState.markName = nil }
        markDirty()
    }

    // MARK: - Timeline In / Out marks

    @objc private func setTimelineInPoint(_ sender: Any) {
        guard let tl = viewportView?.timeline else { return }
        tl.setIn(at: tl.currentTime)
        timelineEditorWC?.editorView.needsDisplay = true
        markDirty()
    }

    @objc private func setTimelineOutPoint(_ sender: Any) {
        guard let tl = viewportView?.timeline else { return }
        tl.setOut(at: tl.currentTime)
        timelineEditorWC?.editorView.needsDisplay = true
        markDirty()
    }

    @objc private func clearTimelineInOut(_ sender: Any) {
        guard let tl = viewportView?.timeline else { return }
        tl.clearInOut()
        timelineEditorWC?.editorView.needsDisplay = true
        markDirty()
    }

    @objc private func toggleLoopInOut(_ sender: Any) {
        guard let tl = viewportView?.timeline else { return }
        tl.loopInOut.toggle()
        timelineEditorWC?.refreshLoopInOutButton()
        markDirty()
    }

    /// Cycles the selected mark by `step` (+1 next, −1 previous), moves the probe
    /// to it (recall), shows its name in the HUD, and ensures marks are visible.
    func cycleMark(by step: Int) {
        guard let viewport = viewportView else { return }
        let probe = viewport.probeConfig
        guard !probe.marks.isEmpty else { return }
        probe.marksVisible = true
        let n   = probe.marks.count
        let cur = probe.selectedMarkIndex ?? (step > 0 ? -1 : 0)
        let idx = ((cur + step) % n + n) % n
        probe.selectedMarkIndex = idx
        let mark = probe.marks[idx]
        probe.position = mark.position                 // recall: probe jumps to the mark
        viewport.overlayState.markName = mark.name
        markDirty()
    }

    /// Deletes the currently selected mark (Delete/Backspace, gated to when marks
    /// are visible and one is selected).
    func deleteSelectedMark() {
        guard let viewport = viewportView else { return }
        let probe = viewport.probeConfig
        guard probe.marksVisible, let idx = probe.selectedMarkIndex,
              probe.marks.indices.contains(idx) else { return }
        let removed = probe.marks.remove(at: idx)
        probe.selectedMarkIndex = probe.marks.isEmpty ? nil : min(idx, probe.marks.count - 1)
        viewport.overlayState.markName = nil
        markDirty()
        print("[DEBUG] AppDelegate: deleted mark '\(removed.name)'")
    }

    // MARK: - Marks menu actions

    @objc private func promptForMarkMenu(_ sender: Any) { promptForMark() }

    @objc private func setDirectorEyeToProbeMenu(_ sender: Any) {
        viewportView?.setDirectorEyeToProbe()
    }

    @objc private func setProbeToDirectorEyeMenu(_ sender: Any) {
        viewportView?.setProbeToDirectorEye()   // marks dirty via onProbeEdited
    }

    @objc private func toggleVectorPath(_ sender: Any) {
        viewportView?.toggleMotionVectors()
    }

    /// Selects mark `index` and recalls the probe to it (Marks ▸ Go To Mark).
    private func goToMark(index: Int) {
        guard let viewport = viewportView else { return }
        let probe = viewport.probeConfig
        guard probe.marks.indices.contains(index) else { return }
        probe.marksVisible      = true
        probe.selectedMarkIndex = index
        let mark = probe.marks[index]
        probe.position = mark.position
        viewport.overlayState.markName = mark.name
        markDirty()
    }

    /// Deletes mark `index` (Marks ▸ Delete Mark).
    private func deleteMark(index: Int) {
        guard let viewport = viewportView else { return }
        let probe = viewport.probeConfig
        guard probe.marks.indices.contains(index) else { return }
        let removed = probe.marks.remove(at: index)
        if let sel = probe.selectedMarkIndex {
            probe.selectedMarkIndex = probe.marks.isEmpty ? nil
                : (sel == index ? min(index, probe.marks.count - 1) : (sel > index ? sel - 1 : sel))
        }
        viewport.overlayState.markName = nil
        markDirty()
        print("[DEBUG] AppDelegate: deleted mark '\(removed.name)'")
    }

    @objc private func goToMarkMenuItem(_ sender: NSMenuItem)   { goToMark(index: sender.tag) }
    @objc private func deleteMarkMenuItem(_ sender: NSMenuItem) { deleteMark(index: sender.tag) }

    // MARK: - Linear Path Animator

    @objc private func showLinearPathAnimator(_ sender: Any) {
        guard let viewport = viewportView else { return }
        let state = viewport.linearPathState
        state.targets = pathAnimatorTargets(camera: true, lights: true, objects: true, groups: false)
        if state.startTime == nil { state.startTime = 0 }
        if state.endTime   == nil { state.endTime   = viewport.timeline.duration }
        if let ref = state.capturedRef, !state.targets.contains(where: { $0.ref == ref }) {
            state.capturedRef = nil   // previously-selected target no longer exists
        }
        // Default the Target to the current viewport/timeline selection when valid.
        if let sel = viewport.currentTrackRef, state.targets.contains(where: { $0.ref == sel }) {
            state.capturedRef = sel
        }

        if let panel = linearPathPanel {
            panel.isVisible ? panel.orderOut(nil) : panel.makeKeyAndOrderFront(nil)
            return
        }

        let panel = KeyForwardingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 460),
            styleMask:   [.titled, .closable, .miniaturizable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        panel.title                  = "Linear Path Animator"
        panel.isFloatingPanel        = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.forwardTarget          = viewport
        panel.level                  = .normal
        panel.hidesOnDeactivate      = false

        panel.contentView = FirstClickHostingView(rootView: LinearPathAnimatorPanel(
            state: state,
            clipboard: viewport.coordinateClipboard,
            captureStartPoint: { [weak viewport] in
                state.startPoint = viewport?.probeConfig.position
                state.status = "Captured start point."
            },
            captureEndPoint: { [weak viewport] in
                state.endPoint = viewport?.probeConfig.position
                state.status = "Captured end point."
            },
            captureStart: { [weak self] in self?.linearPathCaptureStart() },
            captureEnd:   { [weak self] in self?.linearPathCaptureEnd() },
            create:       { [weak self] in self?.linearPathCreate() }
        ))

        if let win = window {
            let f = win.frame
            panel.setFrameOrigin(NSPoint(x: f.minX + 20, y: f.maxY - panel.frame.height - 40))
        } else {
            panel.center()
        }

        linearPathPanel = panel
        panel.makeKeyAndOrderFront(nil)
        print("[DEBUG] AppDelegate: linear path animator panel opened")
    }

    private func linearPathCaptureStart() {
        guard let viewport = viewportView else { return }
        viewport.linearPathState.startTime = viewport.timeline.currentTime
        viewport.linearPathState.status    = "Captured start time."
    }

    private func linearPathCaptureEnd() {
        guard let viewport = viewportView else { return }
        let state = viewport.linearPathState
        state.endTime = viewport.timeline.currentTime
        state.status  = "Captured end time."
    }

    private func linearPathCreate() {
        guard let viewport = viewportView else { return }
        let state = viewport.linearPathState

        guard let a = state.startPoint, let b = state.endPoint else {
            state.validationAlert = "Capture both line points first."; return
        }
        guard let ref = state.capturedRef, let t0 = state.startTime, let t1 = state.endTime else {
            state.validationAlert = "Select a target from the dropdown first."; return
        }
        guard abs(t1 - t0) > 1e-4 else {
            state.validationAlert = "Start and end times must differ."; return
        }
        guard let count = Int(state.keyframes), count >= 2 else {
            state.validationAlert = "Keyframes must be a whole number ≥ 2."; return
        }

        let samples = PathGenerator.linearSamples(
            start: a, end: b, startTime: min(t0, t1), endTime: max(t0, t1), count: count)
        viewport.generateLinearPath(ref: ref, samples: samples, travelDir: b - a)

        timelineEditorWC?.editorView.needsDisplay = true
        markDirty()
        state.status = "Created \(samples.count) keyframes for \(pathAnimatorTrackLabel(ref))."
        print("[DEBUG] AppDelegate: linear path animator created \(samples.count) keyframes")
    }

    // MARK: - Curve Path Animator

    @objc private func showCurvePathAnimator(_ sender: Any) {
        guard let viewport = viewportView else { return }
        let state = viewport.curvePathState
        state.targets = pathAnimatorTargets(camera: true, lights: true, objects: true, groups: false)
        if state.startTime == nil { state.startTime = 0 }
        if state.endTime   == nil { state.endTime   = viewport.timeline.duration }
        if let ref = state.capturedRef, !state.targets.contains(where: { $0.ref == ref }) {
            state.capturedRef = nil   // previously-selected target no longer exists
        }
        // Default the Target to the current viewport/timeline selection when valid.
        if let sel = viewport.currentTrackRef, state.targets.contains(where: { $0.ref == sel }) {
            state.capturedRef = sel
        }

        if let panel = curvePathPanel {
            panel.isVisible ? panel.orderOut(nil) : panel.makeKeyAndOrderFront(nil)
            return
        }

        let panel = KeyForwardingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 520),
            styleMask:   [.titled, .closable, .miniaturizable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        panel.title                  = "Curve Path Animator"
        panel.isFloatingPanel        = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.forwardTarget          = viewport
        panel.level                  = .normal
        panel.hidesOnDeactivate      = false

        panel.contentView = FirstClickHostingView(rootView: CurvePathAnimatorPanel(
            state: state,
            clipboard: viewport.coordinateClipboard,
            captureStartPoint: { [weak viewport] in
                state.startPoint = viewport?.probeConfig.position
                state.status = "Captured start point."
            },
            captureEndPoint: { [weak viewport] in
                state.endPoint = viewport?.probeConfig.position
                state.status = "Captured end point."
            },
            captureAim: { [weak viewport] in
                state.aimPoint = viewport?.probeConfig.position
                state.status = "Captured aim point."
            },
            captureStart: { [weak self] in self?.curvePathCaptureStart() },
            captureEnd:   { [weak self] in self?.curvePathCaptureEnd() },
            create:       { [weak self] in self?.curvePathCreate() }
        ))

        if let win = window {
            let f = win.frame
            panel.setFrameOrigin(NSPoint(x: f.minX + 20, y: f.maxY - panel.frame.height - 40))
        } else {
            panel.center()
        }

        curvePathPanel = panel
        panel.makeKeyAndOrderFront(nil)
        print("[DEBUG] AppDelegate: curve path animator panel opened")
    }

    private func curvePathCaptureStart() {
        guard let viewport = viewportView else { return }
        viewport.curvePathState.startTime = viewport.timeline.currentTime
        viewport.curvePathState.status    = "Captured start time."
    }

    private func curvePathCaptureEnd() {
        guard let viewport = viewportView else { return }
        viewport.curvePathState.endTime = viewport.timeline.currentTime
        viewport.curvePathState.status  = "Captured end time."
    }

    private func curvePathCreate() {
        guard let viewport = viewportView else { return }
        let state = viewport.curvePathState

        guard let s = state.startPoint, let e = state.endPoint, let aim = state.aimPoint else {
            state.validationAlert = "Capture the start, end, and aim points first."; return
        }
        guard let ref = state.capturedRef, let t0 = state.startTime, let t1 = state.endTime else {
            state.validationAlert = "Select a target from the dropdown first."; return
        }
        guard abs(t1 - t0) > 1e-4 else {
            state.validationAlert = "Start and end times must differ."; return
        }
        guard let count = Int(state.keyframes), count >= 2 else {
            state.validationAlert = "Keyframes must be a whole number ≥ 2."; return
        }

        let samples = PathGenerator.curveSamples(
            start: s, end: e, target: aim, longArc: state.useLongArc,
            startTime: min(t0, t1), endTime: max(t0, t1), count: count)
        guard !samples.isEmpty else {
            state.validationAlert = "Start and End must each differ from the Aim point."; return
        }
        viewport.generatePath(ref: ref, samples: samples, fixedAim: aim)

        timelineEditorWC?.editorView.needsDisplay = true
        markDirty()
        state.status = "Created \(samples.count) keyframes for \(pathAnimatorTrackLabel(ref))."
        print("[DEBUG] AppDelegate: curve path animator created \(samples.count) keyframes")
    }

    // MARK: - Gait (Walk) Animator

    /// Resync the Gait panel's target list + marks to the CURRENT project.  Called on
    /// new/open project (so a panel left open from a previous project doesn't keep
    /// stale mark IDs → the spurious "select at least two marks" error) and on open.
    private func syncGaitPanelToProject() {
        guard let viewport = viewportView else { return }
        let state = viewport.gaitState
        // Only whole models (groups) can walk — they own the root path + limb parts.
        state.targets = pathAnimatorTargets(camera: false, lights: false, objects: false, groups: true)
        if let ref = state.capturedRef, !state.targets.contains(where: { $0.ref == ref }) {
            state.capturedRef = nil
        }
        if state.capturedRef == nil { state.capturedRef = state.targets.first?.ref }
        // Drop marks that no longer exist; default to all when nothing valid remains.
        let marks = viewport.probeConfig.marks
        state.markList = marks
        let valid = Set(marks.map { $0.id })
        state.selectedMarks = state.selectedMarks.intersection(valid)
        if state.selectedMarks.isEmpty { state.selectedMarks = valid }
    }

    @objc private func showGaitAnimator(_ sender: Any) {
        guard let viewport = viewportView else { return }
        let state = viewport.gaitState
        syncGaitPanelToProject()
        // Prefer the current viewport/timeline selection as the target when valid.
        if let sel = viewport.currentTrackRef, state.targets.contains(where: { $0.ref == sel }) {
            state.capturedRef = sel
        }

        if let panel = gaitPanel {
            panel.isVisible ? panel.orderOut(nil) : panel.makeKeyAndOrderFront(nil)
            return
        }

        let panel = KeyForwardingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 720),
            styleMask:   [.titled, .closable, .miniaturizable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        panel.title                  = "Gait Animator"
        panel.isFloatingPanel        = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.forwardTarget          = viewport
        panel.level                  = .normal
        panel.hidesOnDeactivate      = false

        panel.contentView = FirstClickHostingView(rootView: GaitAnimatorPanel(
            state: state,
            captureStart: { [weak viewport] in
                state.startTime = viewport?.timeline.currentTime ?? 0
                state.status = "Start time set to playhead."
            },
            create: { [weak self] in self?.gaitCreate() }
        ))

        if let win = window {
            let f = win.frame
            panel.setFrameOrigin(NSPoint(x: f.minX + 20, y: f.maxY - panel.frame.height - 40))
        } else {
            panel.center()
        }

        gaitPanel = panel
        panel.makeKeyAndOrderFront(nil)
        print("[DEBUG] AppDelegate: gait animator panel opened")
    }

    private func gaitCreate() {
        guard let viewport = viewportView else { return }
        let state = viewport.gaitState

        guard case .group(let gid)? = state.capturedRef else {
            state.validationAlert = "Pick a model (group) to walk."; return
        }
        // Selected marks, in their stored order, as the path waypoints.
        let positions = viewport.probeConfig.marks
            .filter { state.selectedMarks.contains($0.id) }
            .map { $0.position }
        guard positions.count >= 2 else {
            state.validationAlert = "Select at least two path marks."; return
        }
        guard let speed = Float(state.speed), speed > 0 else {
            state.validationAlert = "Speed must be a positive number."; return
        }
        guard let stride = Float(state.stride), stride > 0 else {
            state.validationAlert = "Stride must be a positive number."; return
        }
        let start = state.startTime ?? 0

        // Tuning multipliers (default 1.0 when a field is blank/invalid).
        func mul(_ s: String) -> Float { Float(s).map { $0 > 0 ? $0 : 1 } ?? 1 }
        let params = GaitParams.defaults(for: state.gait)
            .scaled(hip: mul(state.swingMul), knee: mul(state.kneeMul),
                    arm: mul(state.armMul),  bob: mul(state.bobMul))

        let missing = viewport.generateGait(
            groupID: gid, gait: state.gait, params: params, markPositions: positions,
            speed: speed, strideLength: stride, startTime: start, plantFeet: state.plantFeet)

        timelineEditorWC?.editorView.needsDisplay = true
        markDirty()
        if missing.isEmpty {
            state.status = "Created \(state.gait.label) along \(positions.count) marks."
        } else {
            state.status = "Created \(state.gait.label); missing joints skipped: \(missing.joined(separator: ", "))."
        }
        print("[DEBUG] AppDelegate: gait created (missing: \(missing))")
    }

    // MARK: - Orbit Path Animator

    @objc private func showOrbitPathAnimator(_ sender: Any) {
        guard let viewport = viewportView else { return }
        let state = viewport.orbitPathState
        state.targets = pathAnimatorTargets(camera: true, lights: true, objects: true,
                                            groups: false, groupParts: true)
        if let ref = state.capturedRef, !state.targets.contains(where: { $0.ref == ref }) {
            state.capturedRef = nil   // previously-selected target no longer exists
        }
        // Default the Target to the current viewport/timeline selection when valid.
        if let sel = viewport.currentTrackRef, state.targets.contains(where: { $0.ref == sel }) {
            state.capturedRef = sel
        }
        orbitReloadFromSchedule()

        if let panel = orbitPathPanel {
            panel.isVisible ? panel.orderOut(nil) : panel.makeKeyAndOrderFront(nil)
            return
        }

        let panel = KeyForwardingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 560),
            styleMask:   [.titled, .closable, .miniaturizable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        panel.title                  = "Orbit Path Animator"
        panel.isFloatingPanel        = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.forwardTarget          = viewport
        panel.level                  = .normal
        panel.hidesOnDeactivate      = false

        panel.contentView = FirstClickHostingView(rootView: OrbitPathAnimatorPanel(
            state: state,
            clipboard: viewport.coordinateClipboard,
            captureAxisStart: { [weak viewport] in
                state.axisStart = viewport?.probeConfig.position
                state.status = "Captured axis start."
            },
            captureAxisEnd: { [weak viewport] in
                state.axisEnd = viewport?.probeConfig.position
                state.status = "Captured axis end."
            },
            addMarker:     { [weak self] in self?.orbitAddMarker() },
            applyGeometry: { [weak self] in self?.orbitApplyGeometry() },
            deleteMarker:  { [weak self] in self?.orbitDeleteMarker($0) },
            clearMarkers:  { [weak self] in self?.orbitClearMarkers() },
            selectTarget:  { [weak self] in self?.orbitReloadFromSchedule() }
        ))

        if let win = window {
            let f = win.frame
            panel.setFrameOrigin(NSPoint(x: f.minX + 20, y: f.maxY - panel.frame.height - 40))
        } else {
            panel.center()
        }

        orbitPathPanel = panel
        panel.makeKeyAndOrderFront(nil)
        print("[DEBUG] AppDelegate: rotation path animator panel opened")
    }

    /// Human-readable label for a captured track.
    private func pathAnimatorTrackLabel(_ ref: TrackRef) -> String {
        switch ref {
        case .camera:        return "Camera"
        case .light(let i):
            if let lights = viewportView?.lightManager.lights, i >= 0, i < lights.count {
                return "Light \(i + 1) - \(lights[i].type.displayName)"
            }
            return "Light \(i + 1)"
        case .object(let i):
            if let objs = viewportView?.sceneManager.objects, i >= 0, i < objs.count {
                return objs[i].name
            }
            return "Object \(i + 1)"
        case .group(let gid):
            return viewportView?.sceneManager.groupName(for: gid) ?? "Model \(gid)"
        default:             return "Unsupported"
        }
    }

    /// Keeps any OPEN Spin / Orbit panel's Target in step with the viewport /
    /// timeline selection (the dropdown can still override until the next change).
    /// Setting `capturedRef` fires the panel's onChange, which reloads its markers.
    private func syncPathAnimatorPanelsToSelection(_ ref: TrackRef) {
        guard let viewport = viewportView else { return }

        // Spin targets objects + models (groups).
        if spinPanel?.isVisible == true {
            let s = viewport.spinAnimatorState
            s.targets = pathAnimatorTargets(camera: false, lights: false, objects: true,
                                            groups: true, groupParts: true)
            if s.targets.contains(where: { $0.ref == ref }), s.capturedRef != ref { s.capturedRef = ref }
        }

        // Orbit / Linear / Curve target camera + lights + objects (no groups).
        let cloTargets = pathAnimatorTargets(camera: true, lights: true, objects: true, groups: false)
        let valid      = cloTargets.contains(where: { $0.ref == ref })
        if orbitPathPanel?.isVisible == true {
            // Orbit also lists individual model parts (it bakes into each part's frame);
            // Linear/Curve don't, so keep their list parts-free.
            let s = viewport.orbitPathState
            s.targets = pathAnimatorTargets(camera: true, lights: true, objects: true,
                                            groups: false, groupParts: true)
            if s.targets.contains(where: { $0.ref == ref }), s.capturedRef != ref { s.capturedRef = ref }
        }
        if linearPathPanel?.isVisible == true {
            let s = viewport.linearPathState
            s.targets = cloTargets
            if valid, s.capturedRef != ref { s.capturedRef = ref }
        }
        if curvePathPanel?.isVisible == true {
            let s = viewport.curvePathState
            s.targets = cloTargets
            if valid, s.capturedRef != ref { s.capturedRef = ref }
        }
    }

    /// Builds the Path Animator "Target" dropdown list from the scene, restricted to
    /// the track kinds a given animator supports.  Alphabetical by label (GUI
    /// convention).  Grouped parts are represented by their group (when groups are
    /// included), standalone objects individually; an envelope (glued assembly) is
    /// a standalone-style target so the whole unit can be animated.
    /// `groupParts` (Spin only) additionally lists each member of a multi-part model
    /// as its own `.object` target, labelled "<model> ▸ <part>", so individual parts
    /// can be spun in place.  Not offered for Orbit, which writes a *world* pose that
    /// a hierarchical part (animated in local space) can't represent correctly.
    private func pathAnimatorTargets(camera: Bool, lights: Bool,
                                     objects: Bool, groups: Bool,
                                     groupParts: Bool = false) -> [PathTarget] {
        guard let viewport = viewportView else { return [] }
        let sm = viewport.sceneManager
        var result: [PathTarget] = []
        if camera { result.append(PathTarget(label: "Camera", ref: .camera)) }
        if lights {
            for (i, light) in viewport.lightManager.lights.enumerated() {
                result.append(PathTarget(label: "Light \(i + 1) - \(light.type.displayName)",
                                         ref: .light(i)))
            }
        }
        var seenGroups = Set<Int>()
        for (i, obj) in sm.objects.enumerated() {
            if let gid = obj.groupID {
                if groups, seenGroups.insert(gid).inserted {
                    result.append(PathTarget(label: sm.groupName(for: gid), ref: .group(gid)))
                }
                if groupParts {
                    result.append(PathTarget(label: "\(sm.groupName(for: gid)) ▸ \(sm.partName(for: obj))",
                                             ref: .object(i)))
                }
            } else if objects {
                result.append(PathTarget(label: sm.displayName(for: obj), ref: .object(i)))
            }
        }
        result.sort { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        return result
    }

    /// Loads the selected target's persisted orbit schedule into the panel fields
    /// (geometry + markers), or clears them when the target has none.
    private func orbitReloadFromSchedule() {
        guard let viewport = viewportView else { return }
        let state = viewport.orbitPathState
        guard let ref = state.capturedRef, let sched = viewport.orbitRateSchedules[ref] else {
            state.markers = []
            return
        }
        state.axisStart = sched.axisStart
        state.axisEnd   = sched.axisEnd
        state.radius    = String(sched.radius)
        state.markers   = sched.markers
    }

    /// Reads the panel's axis / radius / per-rev fields into a validated tuple.
    private func orbitGeometry() -> (axisStart: SIMD3<Float>, axisEnd: SIMD3<Float>,
                                     radius: Float, perRev: Float, ref: TrackRef)? {
        guard let viewport = viewportView else { return nil }
        let state = viewport.orbitPathState
        guard let ref = state.capturedRef else {
            state.validationAlert = "Select a target from the dropdown first."; return nil
        }
        guard let a = state.axisStart, let b = state.axisEnd else {
            state.validationAlert = "Capture both axis points first."; return nil
        }
        guard let radius = Float(state.radius), radius > 0 else {
            state.validationAlert = "Radius must be a positive number."; return nil
        }
        guard let perRev = Float(state.perRev), perRev >= 1 else {
            state.validationAlert = "Keyframes / rev must be ≥ 1."; return nil
        }
        return (a, b, radius, perRev, ref)
    }

    private func orbitApply(markers: [OrbitRateMarker]) {
        guard let viewport = viewportView, let g = orbitGeometry() else { return }
        let state = viewport.orbitPathState
        let sched = markers.isEmpty ? nil : OrbitRateSchedule(
            axisStart: g.axisStart, axisEnd: g.axisEnd, radius: g.radius, markers: markers)
        viewport.setOrbitSchedule(ref: g.ref, schedule: sched, keyframesPerRevolution: g.perRev)
        state.markers = markers
        timelineEditorWC?.editorView.needsDisplay = true
        markDirty()
    }

    private func orbitAddMarker() {
        guard let viewport = viewportView else { return }
        let state = viewport.orbitPathState
        guard let _ = orbitGeometry() else { return }
        guard let rate = Double(state.rate) else {
            state.validationAlert = "Rate must be a number (rev/s)."; return
        }
        // Every rate keyframe lands at the playhead — scrub to frame 0 first for a
        // whole-timeline orbit.  (Forcing the first one to frame 0 ignored a playhead
        // the user had deliberately positioned.)
        let t = viewport.timeline.currentTime
        var markers = state.markers.filter { abs($0.time - t) >= 1e-3 }
        markers.append(OrbitRateMarker(time: t, rate: rate))
        markers.sort { $0.time < $1.time }
        orbitApply(markers: markers)
        state.status = "Added rate keyframe at \(String(format: "%.3f", t)) s."
    }

    private func orbitApplyGeometry() {
        guard let viewport = viewportView else { return }
        orbitApply(markers: viewport.orbitPathState.markers)
        viewport.orbitPathState.status = "Updated radius / axis."
    }

    private func orbitDeleteMarker(_ id: UUID) {
        guard let viewport = viewportView else { return }
        orbitApply(markers: viewport.orbitPathState.markers.filter { $0.id != id })
    }

    private func orbitClearMarkers() {
        guard let viewport = viewportView, let ref = viewport.orbitPathState.capturedRef else { return }
        let perRev = Float(viewport.orbitPathState.perRev) ?? 12
        viewport.setOrbitSchedule(ref: ref, schedule: nil, keyframesPerRevolution: perRev)
        viewport.orbitPathState.markers = []
        timelineEditorWC?.editorView.needsDisplay = true
        markDirty()
    }

    // MARK: - Spin Animator

    @objc private func showSpinAnimator(_ sender: Any) {
        guard let viewport = viewportView else { return }
        let state = viewport.spinAnimatorState
        state.targets = pathAnimatorTargets(camera: false, lights: false, objects: true,
                                            groups: true, groupParts: true)
        if let ref = state.capturedRef, !state.targets.contains(where: { $0.ref == ref }) {
            state.capturedRef = nil   // previously-selected target no longer exists
        }
        // Default the Target to the current viewport/timeline selection when valid.
        if let sel = viewport.currentTrackRef, state.targets.contains(where: { $0.ref == sel }) {
            state.capturedRef = sel
        }
        spinReloadFromSchedule()

        if let panel = spinPanel {
            if panel.isVisible {
                panel.orderOut(nil)
            } else {
                panel.makeKeyAndOrderFront(nil)
            }
            return
        }

        let panel = KeyForwardingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 360),
            styleMask:   [.titled, .closable, .miniaturizable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        panel.title                  = "Spin Path Animator"
        panel.isFloatingPanel        = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.forwardTarget          = viewport
        panel.level                  = .normal
        panel.hidesOnDeactivate      = false

        panel.contentView = FirstClickHostingView(rootView: SpinAnimatorPanel(
            state: state,
            addMarker:    { [weak self] in self?.spinAddMarker() },
            deleteMarker: { [weak self] in self?.spinDeleteMarker($0) },
            clearMarkers: { [weak self] in self?.spinClearMarkers() },
            selectTarget: { [weak self] in self?.spinReloadFromSchedule() }
        ))

        if let win = window {
            let f = win.frame
            panel.setFrameOrigin(NSPoint(x: f.minX + 20, y: f.maxY - panel.frame.height - 40))
        } else {
            panel.center()
        }

        spinPanel = panel
        panel.makeKeyAndOrderFront(nil)
        print("[DEBUG] AppDelegate: spin animator panel opened")
    }

    /// Loads the selected target's persisted spin markers into the panel.
    private func spinReloadFromSchedule() {
        guard let viewport = viewportView else { return }
        let state = viewport.spinAnimatorState
        if let ref = state.capturedRef {
            state.markers = viewport.spinRateSchedules[ref] ?? []
        } else {
            state.markers = []
        }
    }

    private func spinAddMarker() {
        guard let viewport = viewportView else { return }
        let state = viewport.spinAnimatorState
        guard let ref = state.capturedRef else {
            state.validationAlert = "Select a target from the dropdown first."; return
        }
        guard let rate = Double(state.rate) else {
            state.validationAlert = "Rate must be a number (rev/s)."; return
        }
        guard let perRev = Float(state.perRev), perRev >= 3 else {
            state.validationAlert = "Keyframes / rev must be ≥ 3."; return
        }
        // Advanced tumble: optional second simultaneous spin axis.  Blank/0 → single-axis.
        guard let rate2 = Double(state.rate2.isEmpty ? "0" : state.rate2) else {
            state.validationAlert = "Rate 2 must be a number (rev/s)."; return
        }
        // Every rate keyframe lands at the playhead — scrub to frame 0 first for a
        // whole-timeline spin.  (Forcing the first one to frame 0 ignored a playhead
        // the user had deliberately positioned.)
        let t = viewport.timeline.currentTime
        var markers = (viewport.spinRateSchedules[ref] ?? []).filter { abs($0.time - t) >= 1e-3 }
        markers.append(SpinRateMarker(time: t, rate: rate, axisIndex: state.axisIndex,
                                      rate2: rate2, axisIndex2: state.axisIndex2))
        markers.sort { $0.time < $1.time }
        viewport.setSpinSchedule(ref: ref, markers: markers, keyframesPerRevolution: perRev)
        state.markers = markers
        timelineEditorWC?.editorView.needsDisplay = true
        markDirty()
        state.status = "Added rate keyframe at \(String(format: "%.3f", t)) s."
    }

    private func spinDeleteMarker(_ id: UUID) {
        guard let viewport = viewportView, let ref = viewport.spinAnimatorState.capturedRef else { return }
        let perRev = Float(viewport.spinAnimatorState.perRev) ?? 12
        let markers = (viewport.spinRateSchedules[ref] ?? []).filter { $0.id != id }
        viewport.setSpinSchedule(ref: ref, markers: markers, keyframesPerRevolution: perRev)
        viewport.spinAnimatorState.markers = markers
        timelineEditorWC?.editorView.needsDisplay = true
        markDirty()
    }

    private func spinClearMarkers() {
        guard let viewport = viewportView, let ref = viewport.spinAnimatorState.capturedRef else { return }
        let perRev = Float(viewport.spinAnimatorState.perRev) ?? 12
        viewport.setSpinSchedule(ref: ref, markers: [], keyframesPerRevolution: perRev)
        viewport.spinAnimatorState.markers = []
        timelineEditorWC?.editorView.needsDisplay = true
        markDirty()
    }

    // MARK: - Timeline Duration

    /// Applies a new timeline duration requested from the TimelinePanel.
    /// If keyframes exist, prompts whether to rescale them to fit; otherwise
    /// applies the change silently.
    private func changeTimelineDuration(to newDuration: Double) {
        guard let viewport = viewportView else { return }
        let old = viewport.timeline.duration
        guard abs(newDuration - old) > 1e-9 else { return }   // no actual change

        // No keyframes anywhere → nothing to rescale; just apply.
        guard viewport.hasAnyKeyframes else {
            viewport.setTimelineDuration(newDuration, rescaleKeyframes: false)
            markDirty()
            timelineEditorWC?.editorView.needsDisplay = true
            return
        }

        // Defer the modal so the SwiftUI duration popover can dismiss first.
        DispatchQueue.main.async { [weak self] in
            guard let self, let viewport = self.viewportView else { return }
            let alert = NSAlert()
            alert.messageText = String(format: "Change timeline duration to %.1f s?", newDuration)
            alert.informativeText =
                "Rescale Keyframes — existing keyframes are repositioned proportionally "
                + "(expanded or contracted) to fit the new duration.\n\n"
                + "Keep Times — the duration changes but keyframes stay at their current times. "
                + "Shortening the timeline may leave keyframes beyond the new end, where they "
                + "can't be reached or edited.\n\n"
                + "Cancel — make no change. (Tip: use File ▸ Save Project As… first if you want "
                + "a backup before a large change.)"
            alert.addButton(withTitle: "Rescale Keyframes")   // first = default (Return)
            alert.addButton(withTitle: "Keep Times")
            alert.addButton(withTitle: "Cancel")              // Esc

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                viewport.setTimelineDuration(newDuration, rescaleKeyframes: true)
                self.markDirty()
                self.timelineEditorWC?.editorView.needsDisplay = true
            case .alertSecondButtonReturn:
                viewport.setTimelineDuration(newDuration, rescaleKeyframes: false)
                self.markDirty()
                self.timelineEditorWC?.editorView.needsDisplay = true
            default:
                break   // Cancel — leave duration unchanged
            }
        }
    }

    // MARK: - Effects Grid

    @objc private func showEffectsGrid(_ sender: Any) {
        // Toggle: if open and visible, close it.
        if let wc = effectsGridWC {
            if wc.window?.isVisible == true {
                wc.window?.orderOut(nil)
            } else {
                wc.showWindow(nil)
            }
            return
        }

        guard let viewport = viewportView else { return }

        let state = EffectsGridState()
        state.onRedraw = { [weak viewport] in viewport?.needsDisplay = true }
        state.onDirty  = { [weak self] in self?.markDirty() }
        // Row click → select in the viewport (mirrors the Timeline lane click), so
        // inspector + timeline + 'O'/'M' cycling all stay in sync via the existing
        // onSelectionChanged / onControlModeChanged channels.
        state.onSelect = { [weak viewport] obj in
            guard let viewport,
                  let idx = viewport.sceneManager.objects.firstIndex(where: { $0 === obj })
            else { return }
            viewport.sceneManager.selectedIndex = idx
            viewport.setControlMode(obj.groupID != nil ? .model : .object)
            viewport.syncOverlayState()
        }
        state.bind(sceneManager: viewport.sceneManager)
        effectsGridState = state

        let wc = EffectsGridWindowController(state: state)
        effectsGridWC = wc
        wc.showWindow(nil)
        print("[DEBUG] AppDelegate: effects grid opened")
    }

    // MARK: - Timeline Editor

    @objc private func showTimelineEditor(_ sender: Any) {
        // Toggle: if the panel already exists and is visible, close it.
        if let wc = timelineEditorWC {
            if wc.window?.isVisible == true {
                wc.window?.orderOut(nil)
            } else {
                wc.showWindow(nil)
                positionTimelineEditor(wc)
                // Highlight the currently-selected lane right away on re-open.
                viewportView?.emitCurrentControlMode()
            }
            return
        }

        guard let viewport = viewportView else { return }

        let wc = TimelineEditorWindowController(
            timeline:       viewport.timeline,
            sceneManager:   viewport.sceneManager,
            camera:         viewport.camera,
            lightManager:   viewport.lightManager,
            fogSettings:     viewport.fogSettings,
            particleManager: viewport.particleManager,
            coordinateClipboard: viewport.coordinateClipboard
        )
        wc.editorView.onInsertObjectKeyframe = { [weak self, weak viewport] index in
            viewport?.addKeyframeAtCurrentTime(forObjectAt: index)
            self?.markDirty()
        }
        wc.editorView.onInsertCameraKeyframe = { [weak self, weak viewport] in
            viewport?.addCameraKeyframeAtCurrentTime()
            self?.markDirty()
        }
        wc.editorView.onInsertLightKeyframe = { [weak self, weak viewport] index in
            viewport?.addLightKeyframeAtCurrentTime(forLightAt: index)
            self?.markDirty()
        }
        wc.editorView.onInsertGroupKeyframe = { [weak self, weak viewport] gid in
            viewport?.addGroupKeyframeAtCurrentTime(for: gid)
            self?.markDirty()
        }
        wc.editorView.onInsertFogKeyframe = { [weak self, weak viewport] in
            viewport?.addFogKeyframeAtCurrentTime()
            self?.markDirty()
        }
        wc.editorView.onInsertParticleKeyframe = { [weak self, weak viewport] index in
            viewport?.addParticleKeyframeAtCurrentTime(forEmitterAt: index)
            self?.markDirty()
        }
        wc.editorView.onKeyframeDeleted = { [weak self, weak viewport] in
            self?.markDirty()
            // Refresh the Atmosphere panel's keyframe counts (harmless for other lanes).
            viewport?.fogSettings.objectWillChange.send()
            viewport?.particleManager.emitters.forEach { $0.objectWillChange.send() }
        }
        wc.editorView.onKeyframePasted = { [weak self, weak viewport] in
            self?.markDirty()
            viewport?.fogSettings.objectWillChange.send()
            viewport?.particleManager.emitters.forEach { $0.objectWillChange.send() }
            // Re-evaluate so a paste (whole keyframe via ⌘V, or a single channel via
            // right-click) shows in the viewport/panel immediately, not only on scrub.
            viewport?.renderer?.invalidateAnimationCache()
        }

        // ── Track edit locks ──────────────────────────────────────────────────
        wc.editorView.lockProvider = { [weak viewport] ref in viewport?.isLocked(ref) ?? false }
        wc.editorView.onSetLock = { [weak self, weak viewport] ref, locked in
            viewport?.setLocked(ref, locked)
            self?.markDirty()
        }
        wc.editorView.onLockAll = { [weak self, weak viewport] locked in
            viewport?.setAllLocked(locked)
            self?.markDirty()
            wc.editorView.needsDisplay = true
        }

        // ── Enter edit mode ───────────────────────────────────────────────────
        // Called when the user presses Return on a selected diamond.
        // Save the pose that the keyframe currently stores, seek to its time,
        // and switch the viewport to the appropriate control mode so the user
        // can adjust the pose live with normal mouse / keyboard controls.
        wc.editorView.onEnterEditMode = { [weak self, weak viewport] ref, kfTime in
            guard let self = self, let viewport = viewport else { return }

            // Mirror edit mode in the viewport HUD (second line).
            viewport.overlayState.isEditing = true

            // Make sure we're paused so the renderer won't keep advancing time.
            viewport.timeline.pause()

            // Seek to the keyframe time — triggers applyAnimation() on the next draw,
            // setting obj.transform / camera properties to the stored keyframe pose.
            viewport.timeline.seek(to: kfTime)

            switch ref {
            case .camera:
                // Evaluate the camera track at kfTime to get the exact saved values.
                // Also look up the RAW keyframe to preserve followTargetName —
                // evaluate() creates a new struct and drops follow metadata.
                let c = viewport.camera
                let rawFollowName = c.keyframeTrack?.keyframes
                    .first(where: { abs($0.time - kfTime) < 0.001 })?.followTargetName
                if let track = c.keyframeTrack,
                   let state = track.evaluate(at: kfTime) {
                    self.kfEditSnapshot = .camera(
                        yaw:             state.yaw,
                        pitch:           state.pitch,
                        distance:        state.distance,
                        target:          state.target,
                        followTargetName: rawFollowName,
                        kfTime:          kfTime
                    )
                } else {
                    // Fallback: save the current live state.
                    self.kfEditSnapshot = .camera(
                        yaw:             c.yaw,
                        pitch:           c.pitch,
                        distance:        c.distance,
                        target:          c.target,
                        followTargetName: rawFollowName,
                        kfTime:          kfTime
                    )
                }
                viewport.setControlMode(.camera)
                // Suspend the follow override so the user's adjustments to target /
                // yaw stick during edit instead of being overwritten each frame.
                // Reset on commit/cancel.  Free (non-follow) keyframes leave it false.
                viewport.camera.followSuspended = (rawFollowName != nil)
                print("[DEBUG] AppDelegate: entered camera keyframe edit at t="
                    + String(format: "%.3f", kfTime)
                    + (rawFollowName.map { " follow='\($0)'" } ?? " (free)"))

            case .object(let i):
                guard i < viewport.sceneManager.objects.count else { return }
                let obj = viewport.sceneManager.objects[i]
                // Evaluate the track at kfTime to get the saved transform.
                let savedTransform: matrix_float4x4
                if let track = obj.keyframeTrack,
                   let delta = track.evaluate(at: kfTime) {
                    savedTransform = obj.baseTransform * delta
                } else {
                    savedTransform = obj.transform
                }
                self.kfEditSnapshot = .object(
                    index:          i,
                    savedTransform: savedTransform,
                    kfTime:         kfTime
                )
                // Select this object and enter Object mode so viewport controls target it.
                viewport.sceneManager.selectedIndex = i
                viewport.setControlMode(.object)
                print("[DEBUG] AppDelegate: entered object keyframe edit index=\(i)"
                    + " t=" + String(format: "%.3f", kfTime))

            case .light(let i):
                guard i < viewport.lightManager.lights.count else { return }
                // Evaluate the light track at kfTime to get the saved values.
                let lm = viewport.lightManager
                let savedIntensity:  Float
                let savedColor:      SIMD3<Float>
                let savedTarget:     SIMD3<Float>
                let savedPosition:   SIMD3<Float>
                if i < lm.keyframeTracks.count,
                   let track = lm.keyframeTracks[i],
                   let state = track.evaluate(at: kfTime) {
                    savedIntensity  = state.intensity
                    savedColor      = state.color
                    savedTarget     = state.target
                    savedPosition   = state.position
                } else {
                    let light       = lm.lights[i]
                    savedIntensity  = light.intensity
                    savedColor      = light.color
                    savedTarget     = light.target
                    savedPosition   = light.position
                }
                self.kfEditSnapshot = .light(
                    index:          i,
                    savedIntensity: savedIntensity,
                    savedColor:     savedColor,
                    savedTarget:    savedTarget,
                    savedPosition:  savedPosition,
                    kfTime:         kfTime
                )
                // Select this light and enter Light mode.
                viewport.lightManager.selectedIndex = i
                viewport.setControlMode(.light)
                print("[DEBUG] AppDelegate: entered light keyframe edit index=\(i)"
                    + " t=" + String(format: "%.3f", kfTime))

            case .group(let gid):
                // Save the group transform that was baked into this keyframe so we
                // can restore it on cancel, then switch the viewport to Model mode.
                let savedGroupTransform: matrix_float4x4
                if let track = viewport.sceneManager.groupKeyframeTracks[gid],
                   let delta = track.evaluate(at: kfTime) {
                    savedGroupTransform = delta
                } else {
                    savedGroupTransform = viewport.sceneManager.groupTransforms[gid]
                        ?? matrix_identity_float4x4
                }
                self.kfEditSnapshot = .group(
                    gid:           gid,
                    savedTransform: savedGroupTransform,
                    kfTime:         kfTime
                )
                // Restore the group to the keyframed pose so the user edits from
                // the correct starting point.
                viewport.sceneManager.groupTransforms[gid] = savedGroupTransform
                // Select the first part of the group and enter Model mode.
                if let idx = viewport.sceneManager.objects.firstIndex(where: { $0.groupID == gid }) {
                    viewport.sceneManager.selectedIndex = idx
                }
                viewport.setControlMode(.model)
                viewport.syncOverlayState()
                print("[DEBUG] AppDelegate: entered group keyframe edit gid=\(gid)"
                    + " t=" + String(format: "%.3f", kfTime))

            case .fog:
                // No viewport control mode — fog is edited via the Atmosphere panel,
                // which follows the playhead (the seek above synced its sliders to this
                // keyframe).  Just record the time and make sure the panel is visible.
                if self.atmospherePanel == nil || self.atmospherePanel?.isVisible != true {
                    self.showAtmospherePanel(self)
                }
                self.kfEditSnapshot = .fog(kfTime: kfTime)
                print("[DEBUG] AppDelegate: entered fog keyframe edit t="
                    + String(format: "%.3f", kfTime))

            case .particles(let i):
                if self.atmospherePanel == nil || self.atmospherePanel?.isVisible != true {
                    self.showAtmospherePanel(self)
                }
                viewport.particleManager.selectedIndex = i   // show this emitter in the panel
                self.kfEditSnapshot = .particles(index: i, kfTime: kfTime)
                print("[DEBUG] AppDelegate: entered particle keyframe edit emitter=\(i) t="
                    + String(format: "%.3f", kfTime))
            case .importBundle:
                return   // display-only header — no track to edit
            }
        }

        // ── Commit edit ───────────────────────────────────────────────────────
        // The user pressed Return a second time.  The object/camera is already at
        // the new pose (the user moved it live).  Write a keyframe — addKeyframe
        // deduplicates within 1 ms, so this naturally overwrites the old one.
        wc.editorView.onCommitEdit = { [weak self, weak viewport] in
            viewport?.overlayState.isEditing = false   // clear HUD edit badge
            guard let self = self,
                  let snapshot = self.kfEditSnapshot,
                  let viewport = viewport else { return }

            switch snapshot {
            case .object(let index, _, let kfTime):
                viewport.timeline.seek(to: kfTime)
                viewport.addKeyframeAtCurrentTime(forObjectAt: index)
                print("[DEBUG] AppDelegate: committed object keyframe edit index=\(index)"
                    + " t=" + String(format: "%.3f", kfTime))

            case .camera(_, _, _, _, let followTargetName, let kfTime):
                viewport.timeline.seek(to: kfTime)
                // Resume follow override before re-stamping so the new keyframe is
                // computed against the live anchor state, then applyCameraFollow
                // runs normally on subsequent frames.
                viewport.camera.followSuspended = false
                if let name = followTargetName {
                    // Preserve follow: re-add as a follow keyframe for the same target,
                    // recomputing the yaw offset from the new camera position.
                    viewport.addFollowCameraKeyframeAtCurrentTime(followingObjectNamed: name)
                } else {
                    viewport.addCameraKeyframeAtCurrentTime()
                }
                print("[DEBUG] AppDelegate: committed camera keyframe edit"
                    + " t=" + String(format: "%.3f", kfTime)
                    + (followTargetName.map { " follow='\($0)'" } ?? " (free)"))

            case .light(let index, _, _, _, _, let kfTime):
                viewport.timeline.seek(to: kfTime)
                viewport.addLightKeyframeAtCurrentTime(forLightAt: index)
                print("[DEBUG] AppDelegate: committed light keyframe edit index=\(index)"
                    + " t=" + String(format: "%.3f", kfTime))

            case .group(let gid, _, let kfTime):
                viewport.timeline.seek(to: kfTime)
                viewport.addGroupKeyframeAtCurrentTime(for: gid)
                print("[DEBUG] AppDelegate: committed group keyframe edit gid=\(gid)"
                    + " t=" + String(format: "%.3f", kfTime))

            case .fog(let kfTime):
                viewport.timeline.seek(to: kfTime)
                viewport.addFogKeyframeAtCurrentTime()   // re-stamp from edited panel fields
                print("[DEBUG] AppDelegate: committed fog keyframe edit t="
                    + String(format: "%.3f", kfTime))

            case .particles(let index, let kfTime):
                viewport.timeline.seek(to: kfTime)
                viewport.addParticleKeyframeAtCurrentTime(forEmitterAt: index)
                print("[DEBUG] AppDelegate: committed particle keyframe edit emitter=\(index) t="
                    + String(format: "%.3f", kfTime))
            }

            self.kfEditSnapshot = nil
            self.markDirty()
        }

        // ── Cancel edit ───────────────────────────────────────────────────────
        // The user pressed Escape.  Restore the saved pose so the keyframe's
        // original state is visible again.
        wc.editorView.onCancelEdit = { [weak self, weak viewport] in
            viewport?.overlayState.isEditing = false   // clear HUD edit badge
            guard let self = self,
                  let snapshot = self.kfEditSnapshot,
                  let viewport = viewport else { return }

            switch snapshot {
            case .object(let index, let savedTransform, let kfTime):
                guard index < viewport.sceneManager.objects.count else { return }
                viewport.sceneManager.objects[index].transform = savedTransform
                print("[DEBUG] AppDelegate: cancelled object keyframe edit index=\(index)"
                    + " t=" + String(format: "%.3f", kfTime))

            case .camera(let yaw, let pitch, let distance, let target, _, let kfTime):
                let c      = viewport.camera
                c.yaw      = yaw
                c.pitch    = pitch
                c.distance = distance
                c.target   = target
                // Resume follow override; on the next frame applyCameraFollow will
                // re-place the camera using the stored offsets — same as before edit.
                c.followSuspended = false
                print("[DEBUG] AppDelegate: cancelled camera keyframe edit"
                    + " t=" + String(format: "%.3f", kfTime))

            case .light(let index, let savedIntensity, let savedColor,
                        let savedTarget, let savedPosition, let kfTime):
                guard index < viewport.lightManager.lights.count else { return }
                viewport.lightManager.lights[index].intensity  = savedIntensity
                viewport.lightManager.lights[index].color      = savedColor
                viewport.lightManager.lights[index].position   = savedPosition
                viewport.lightManager.lights[index].target     = savedTarget
                print("[DEBUG] AppDelegate: cancelled light keyframe edit index=\(index)"
                    + " t=" + String(format: "%.3f", kfTime))

            case .group(let gid, let savedTransform, let kfTime):
                viewport.sceneManager.groupTransforms[gid] = savedTransform
                print("[DEBUG] AppDelegate: cancelled group keyframe edit gid=\(gid)"
                    + " t=" + String(format: "%.3f", kfTime))

            case .fog(let kfTime):
                // Discard unstamped slider edits by reloading the keyframe value.
                viewport.fogSettings.syncToPlayhead(at: kfTime)
                print("[DEBUG] AppDelegate: cancelled fog keyframe edit t="
                    + String(format: "%.3f", kfTime))

            case .particles(let index, let kfTime):
                if viewport.particleManager.emitters.indices.contains(index) {
                    viewport.particleManager.emitters[index].syncToPlayhead(at: kfTime)
                }
                print("[DEBUG] AppDelegate: cancelled particle keyframe edit emitter=\(index) t="
                    + String(format: "%.3f", kfTime))
            }

            self.kfEditSnapshot = nil
        }

        // Wire viewport Return key → commit any active keyframe edit.
        viewport.onEnterKey = { [weak wc] in
            wc?.editorView.commitEditIfActive()
        }

        // ── Timeline lane click → viewport control mode / selection ───────────
        // Clicking any row (or its label, or a diamond on that row) in the
        // timeline editor switches the viewport to the matching mode.
        wc.editorView.onLaneSelected = { [weak viewport] ref in
            guard let viewport = viewport else { return }
            switch ref {
            case .camera:
                viewport.setControlMode(.camera)
            case .object(let i):
                viewport.sceneManager.selectedIndex = i
                viewport.setControlMode(.object)
                viewport.syncOverlayState()
            case .light(let i):
                viewport.lightManager.selectedIndex = i
                viewport.setControlMode(.light)
            case .group(let gid):
                // Clicking a group header row selects the first part of the group
                // and switches the viewport to Model mode so the whole group moves together.
                if let idx = viewport.sceneManager.objects.firstIndex(where: { $0.groupID == gid }) {
                    viewport.sceneManager.selectedIndex = idx
                }
                viewport.setControlMode(.model)
                viewport.syncOverlayState()
            case .fog:
                // Fog has no viewport control mode; the lane just highlights in the
                // editor (edit values via the panel).
                break
            case .particles(let i):
                // Make the panel show the clicked emitter (no viewport control mode).
                viewport.particleManager.selectedIndex = i
            case .importBundle:
                // Display-only header — selecting it just highlights the lane; no
                // viewport control mode and no selection change.
                break
            }
        }

        // Right-click ▸ Delete on a grid row.
        wc.editorView.onDeleteRow = { [weak self] ref in self?.deleteTimelineRow(ref) }

        // Bundle header ▸ Extend Spin/Orbit to End.
        wc.editorView.onExtendBundleSpinOrbit = { [weak self] bid in self?.extendBundleSpinOrbit(bid) }

        // (Viewport mode / selection-change handling — including timeline lane
        // highlight + Path Animator Target sync — is wired centrally in setup, so
        // it works whether or not the timeline editor has been opened.)

        // ── Atmosphere panel emitter selection → timeline lane highlight ──────
        // Selecting an emitter in the panel (a Weather row, or adding one) highlights
        // its Weather lane.  dropFirst() avoids force-selecting a particle lane just
        // because the editor opened.  (The reverse — lane → panel — is onLaneSelected.)
        particleSelectionCancellable = viewport.particleManager.$selectedIndex
            .dropFirst()
            .sink { [weak wc] idx in wc?.editorView.selectTrack(.particles(idx)) }

        // ── Bidirectional key forwarding ───────────────────────────────────────
        // Timeline editor → viewport: unhandled keys reach the viewport.
        wc.editorView.keyForwardTarget = viewport
        // Viewport → timeline editor: unhandled keys reach the timeline editor.
        viewport.timelineKeyTarget = wc.editorView

        timelineEditorWC = wc
        wc.showWindow(nil)
        positionTimelineEditor(wc)
        // Highlight the currently-selected lane immediately, rather than waiting
        // for the next selection change.
        viewport.emitCurrentControlMode()
        print("[DEBUG] AppDelegate: timeline editor panel opened")
    }

    private func positionTimelineEditor(_ wc: TimelineEditorWindowController) {
        guard let win = window, let panel = wc.window else { return }
        let winFrame   = win.frame
        let panelFrame = panel.frame
        // Position below the main window, left-aligned.
        let originX = winFrame.minX
        let originY = winFrame.minY - panelFrame.height - 8
        panel.setFrameOrigin(NSPoint(x: originX, y: max(originY, 0)))
    }

    // MARK: - Export Video

    // MARK: - Favorite Models

    /// Resolves where a selection's favourite alias would live:
    /// `FavoriteModels/<model's parent-folder name>/<filename>`.  `target` is the
    /// real model file (a Finder alias in sourceURL is resolved).  Returns nil if
    /// the selection has no model file (e.g. an envelope null node).
    private func favoritesAliasContext(for targets: [SceneObject])
        -> (sourceURL: URL, target: URL, aliasURL: URL, favRoot: URL)? {
        guard let sourceURL = targets.first?.sourceURL else { return nil }
        let favRoot   = AppSettings.expand(AppSettings.shared.modelsPathPrimary).standardizedFileURL
        let target    = GLTFLoader.resolveAliasFile(sourceURL).standardizedFileURL
        let subfolder = target.deletingLastPathComponent().lastPathComponent
        let aliasURL  = favRoot.appendingPathComponent(subfolder, isDirectory: true)
                               .appendingPathComponent(target.lastPathComponent)
        return (sourceURL, target, aliasURL, favRoot)
    }

    /// Eligible when the model has a real sourceURL, that path is NOT already inside
    /// the Favorite Models folder, and no alias for it exists there yet.
    private func favoritesEligibility(for targets: [SceneObject]) -> Bool {
        guard let ctx = favoritesAliasContext(for: targets) else { return false }
        let favPath = ctx.favRoot.path
        let srcPath = ctx.sourceURL.standardizedFileURL.path
        if srcPath == favPath || srcPath.hasPrefix(favPath + "/") { return false }
        if FileManager.default.fileExists(atPath: ctx.aliasURL.path) { return false }
        return true
    }

    /// Creates a Finder alias to the selected model in the Favorite Models folder
    /// and repoints the project at it (saved on the next Save).
    private func addSelectedToFavorites() {
        guard let viewport = viewportView,
              let selected = viewport.sceneManager.selectedObject else { return }
        let group: [SceneObject] = selected.groupID
            .map { viewport.sceneManager.objects(inGroup: $0) } ?? [selected]
        guard let ctx = favoritesAliasContext(for: group),
              favoritesEligibility(for: group) else { return }

        do {
            try FileManager.default.createDirectory(
                at: ctx.aliasURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bookmark = try ctx.target.bookmarkData(
                options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
            try URL.writeBookmarkData(bookmark, to: ctx.aliasURL)
        } catch {
            showErrorAlert(message: "Couldn't add to Favorites", detail: error.localizedDescription)
            return
        }

        // Repoint every part sharing the old sourceURL at the new alias so the
        // project saves the alias path; load-time resolution reads the real model.
        let oldURL = ctx.sourceURL
        for obj in viewport.sceneManager.objects where obj.sourceURL == oldURL {
            obj.sourceURL = ctx.aliasURL
        }
        markDirty()
        // Recompute the inspector so the button disables now that it's a favourite.
        modelInspectorState?.update(targets: group, displayName: timelineDisplayName(for: group))
        print("[DEBUG] AppDelegate: added to favourites — " + ctx.aliasURL.path)
    }

    /// Pre-export gate: if the project has unsaved changes, prompt Save / Cancel.
    /// Returns true to proceed (saved or already clean), false to abort the export.
    private func confirmSaveIfDirtyForExport() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText     = "Save Before Exporting?"
        alert.informativeText = "The project has unsaved changes. Save before starting the export."
        alert.alertStyle      = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        saveProject(self)   // project already has a URL (export requires it)
        return true
    }

    /// Starts an export session: seeds the progress panel, shows it, and minimizes the
    /// main window (which hides all child panels via windowWillMiniaturize — so no edits
    /// can corrupt the in-progress scene).  `passCount` 1 = a single export.
    private func beginExportSession(projectName: String, passCount: Int) {
        exportState.projectName = projectName
        exportState.passCount   = passCount
        exportState.passIndex   = 1
        exportState.passName    = ""
        exportState.progress    = 0

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 150),
                            styleMask: [.titled, .nonactivatingPanel],   // no close button
                            backing: .buffered, defer: false)
        panel.title             = "Export Progress"
        panel.isFloatingPanel   = true
        panel.level             = .floating
        panel.hidesOnDeactivate = false
        panel.contentView       = NSHostingView(rootView: ExportProgressPanel(state: exportState))
        panel.center()
        panel.orderFront(nil)
        exportProgressPanel = panel

        window?.miniaturize(nil)   // hides child panels via windowWillMiniaturize
    }

    /// Ends an export session: closes the progress panel and restores the main window
    /// (which restores the hidden child panels via windowDidDeminiaturize).
    private func endExportSession() {
        exportProgressPanel?.orderOut(nil)
        exportProgressPanel = nil
        if let w = window, w.isMiniaturized { w.deminiaturize(nil) }
    }

    @objc private func exportAll(_ sender: Any) {
        guard let window = window else { return }
        guard viewportView?.sceneManager.primaryObject != nil else {
            let alert = NSAlert()
            alert.messageText     = "No Model Loaded"
            alert.informativeText = "Open a .glb or .gltf model before exporting."
            alert.alertStyle      = .warning
            alert.beginSheetModal(for: window)
            return
        }
        guard let projectURL = currentProjectURL else {
            let alert = NSAlert()
            alert.messageText     = "Save the Project First"
            alert.informativeText = "Export All files passes under Movies/<project name>/ \u{2014} save the project so it has a name."
            alert.alertStyle      = .warning
            alert.beginSheetModal(for: window)
            return
        }

        let projectName     = projectURL.deletingPathExtension().lastPathComponent
        let projectMovieDir = defaultDirectory(for: "Movies").appendingPathComponent(projectName)
        try? FileManager.default.createDirectory(at: projectMovieDir, withIntermediateDirectories: true)

        let (accessory, codecPopup, resPopup, fpsPopup, _) = makeExportAccessoryView()
        let alert = NSAlert()
        alert.messageText     = "Export All Passes"
        alert.informativeText = "Renders the full pass set (Scene; Actor / MacGuffin Solo + Matte; Background + Background Matte; FX Solo + Matte) into Movies/\(projectName)/ using one codec. The project is saved first and reloaded when the cycle finishes."
        alert.accessoryView   = accessory
        alert.addButton(withTitle: "Export All")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self else { return }

            let codec: ExportCodec = codecPopup.indexOfSelectedItem == 0 ? .proRes4444 : .proRes422HQ
            let res = ExportResolution.presets[max(0, resPopup.indexOfSelectedItem)]
            let fps = ExportFrameRate.presets[max(0, fpsPopup.indexOfSelectedItem)]

            AppSettings.shared.exportWidth   = res.width
            AppSettings.shared.exportHeight  = res.height
            AppSettings.shared.exportCodecID = (codec == .proRes422HQ) ? "proRes422HQ" : "proRes4444"
            AppSettings.shared.save()
            if let tl = self.viewportView?.timeline, abs(tl.frameRate - fps.value) > 1e-9 {
                tl.frameRate = fps.value
            }

            // Dirty gate: prompt Save / Cancel (Cancel aborts).  The saved file is the
            // checkpoint reloaded after the cycle; if clean, it already is.
            guard self.confirmSaveIfDirtyForExport() else { return }

            let cycle = self.nextCycleNumber(projectName: projectName, in: projectMovieDir)
            print("[DEBUG] AppDelegate: Export All cycle \(cycle) codec=\(codec.displayName)"
                + " res=\(res.width)x\(res.height) fps=\(fps.display)")

            // Progress panel up + main window minimized (no edits possible mid-export).
            let total = self.viewportView?.exportAllPassCount() ?? 0
            self.beginExportSession(projectName: projectName, passCount: total)

            self.viewportView?.startExportAll(
                folder: projectMovieDir, projectName: projectName, cycleNumber: cycle,
                codec: codec, fps: fps, exportState: self.exportState
            ) { [weak self] error in
                guard let self = self else { return }
                // Restore exact pre-cycle state by reloading the checkpoint project.
                self.loadProject(from: projectURL)
                // Hide progress + restore the main window (and its child panels) first.
                self.endExportSession()
                if let error = error {
                    self.showErrorAlert(message: "Export All failed", detail: error.localizedDescription)
                } else {
                    let done = NSAlert()
                    done.messageText     = "Export All Completed"
                    done.informativeText = "Saved \(projectName).\(String(format: "%02d", cycle)).<pass>.mov in Movies/\(projectName)/."
                    done.alertStyle      = .informational
                    done.runModal()
                }
            }
        }
    }

    @objc private func exportVideo(_ sender: Any) {
        showExportPanel()
    }

    private func showExportPanel() {
        guard let window = window else {
            print("[DEBUG] AppDelegate: showExportPanel — window is nil")
            return
        }
        guard !exportState.isExporting else {
            print("[DEBUG] AppDelegate: showExportPanel — export already in progress")
            return
        }
        guard viewportView?.sceneManager.primaryObject != nil else {
            let alert = NSAlert()
            alert.messageText     = "No Model Loaded"
            alert.informativeText = "Open a .glb or .gltf model before exporting."
            alert.alertStyle      = .warning
            alert.beginSheetModal(for: window)
            return
        }
        // Require a saved project so the export can be filed under a real
        // per-project folder.  Without this the auto-named export
        // (<projectName>.NN.mov) would have no project name to use.
        guard let projectURL = currentProjectURL else {
            let alert = NSAlert()
            alert.messageText     = "Save the Project First"
            alert.informativeText = "Exports are filed under Movies/<project name>/ — save the project so it has a name."
            alert.alertStyle      = .warning
            alert.beginSheetModal(for: window)
            return
        }

        // Dirty gate: prompt Save / Cancel before the filename panel (Cancel aborts).
        guard confirmSaveIfDirtyForExport() else { return }

        let projectName = projectURL.deletingPathExtension().lastPathComponent
        let projectMovieDir = defaultDirectory(for: "Movies")
            .appendingPathComponent(projectName)
        try? FileManager.default.createDirectory(at: projectMovieDir,
                                                 withIntermediateDirectories: true)
        let defaultName = nextMovieFilename(projectName: projectName, in: projectMovieDir)

        let (accessory, codecPopup, resPopup, fpsPopup, rangePopup) = makeExportAccessoryView(includeRange: true)

        let panel = NSSavePanel()
        panel.title                = "Export ProRes Video"
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        panel.directoryURL         = projectMovieDir
        panel.accessoryView        = accessory

        if let movType = UTType(filenameExtension: "mov") {
            panel.allowedContentTypes = [movType]
        }

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let rawURL = panel.url else {
                print("[DEBUG] AppDelegate: export panel cancelled")
                return
            }
            // Always enforce .mov extension regardless of what the user typed or
            // which file they clicked (e.g. clicking a .3dvp file should still
            // produce a .mov, not a .3dvp).
            let url = rawURL.deletingPathExtension().appendingPathExtension("mov")
            let codec: ExportCodec = codecPopup.indexOfSelectedItem == 0
                ? .proRes4444
                : .proRes422HQ
            let res = ExportResolution.presets[max(0, resPopup.indexOfSelectedItem)]
            let fps = ExportFrameRate.presets[max(0, fpsPopup.indexOfSelectedItem)]
            guard let self = self else { return }

            // Persist resolution + codec globally (AppSettings); the FPS is the
            // project's frame rate, so set it on the timeline (and mark dirty).
            AppSettings.shared.exportWidth   = res.width
            AppSettings.shared.exportHeight  = res.height
            AppSettings.shared.exportCodecID = (codec == .proRes422HQ) ? "proRes422HQ" : "proRes4444"
            AppSettings.shared.save()
            if let tl = self.viewportView?.timeline, abs(tl.frameRate - fps.value) > 1e-9 {
                tl.frameRate = fps.value
                self.markDirty()
            }

            // Range: "In → Out" (index 1) limits the export to the marked region.
            var rStart = 0.0
            var rEnd: Double? = nil
            if let rp = rangePopup, rp.indexOfSelectedItem == 1, let tl = self.viewportView?.timeline {
                rStart = tl.playStart
                rEnd   = tl.playEnd
            }

            print("[DEBUG] AppDelegate: export — " + url.lastPathComponent
                + " codec=" + codec.displayName
                + " res=\(res.width)×\(res.height) fps=" + fps.display
                + (rEnd != nil ? " range=\(rStart)…\(rEnd!)" : " range=full"))
            // Progress panel up + main window minimized (no edits possible mid-export).
            self.beginExportSession(projectName: projectName, passCount: 1)
            self.exportState.passName = url.lastPathComponent
            self.viewportView?.startExport(
                to: url, codec: codec, fps: fps, exportState: self.exportState,
                rangeStart: rStart, rangeEnd: rEnd
            ) { [weak self] error in
                // Hide progress + restore the main window (and child panels) first.
                self?.endExportSession()
                // Mirror the HDR export confirmation so the user gets explicit
                // acknowledgement at the end of a (often long) video export.
                if let error = error {
                    self?.showErrorAlert(message: "Video Export failed",
                                         detail: error.localizedDescription)
                } else {
                    let alert = NSAlert()
                    alert.messageText     = "Video Export Completed"
                    alert.informativeText = "Saved \u{201C}\(url.lastPathComponent)\u{201D}."
                    alert.alertStyle      = .informational
                    alert.runModal()
                }
            }
        }
    }

    private func makeExportAccessoryView(includeRange: Bool = false) -> (view: NSView,
                                               codec: NSPopUpButton,
                                               resolution: NSPopUpButton,
                                               fps: NSPopUpButton,
                                               range: NSPopUpButton?) {
        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font      = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            l.alignment = .right
            l.setContentHuggingPriority(.required, for: .horizontal)
            return l
        }
        func row(_ text: String, _ popup: NSPopUpButton) -> NSStackView {
            let s = NSStackView(views: [label(text), popup])
            s.orientation = .horizontal
            s.alignment   = .centerY
            s.spacing     = 8
            return s
        }

        // Format / codec
        let codecPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        codecPopup.addItem(withTitle: ExportCodec.proRes4444.displayName)
        codecPopup.addItem(withTitle: ExportCodec.proRes422HQ.displayName)
        codecPopup.selectItem(at: AppSettings.shared.exportCodecID == "proRes422HQ" ? 1 : 0)

        // Resolution
        let resPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for r in ExportResolution.presets { resPopup.addItem(withTitle: r.display) }
        let curRes = ExportResolution.matching(width: AppSettings.shared.exportWidth,
                                               height: AppSettings.shared.exportHeight)
        resPopup.selectItem(at: ExportResolution.presets.firstIndex(of: curRes) ?? 3)

        // FPS — defaults to the current project frame rate.
        let fpsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for f in ExportFrameRate.presets { fpsPopup.addItem(withTitle: f.display) }
        let curFps = ExportFrameRate.closest(to: viewportView?.timeline.frameRate ?? 30.0)
        fpsPopup.selectItem(at: ExportFrameRate.presets.firstIndex(of: curFps) ?? 4)

        // Range — only on the single-clip Export panel.  "In → Out" is selectable
        // only when both marks are set; otherwise it stays disabled on "Full".
        var rangePopup: NSPopUpButton? = nil
        var rows: [NSStackView] = [
            row("Format:",     codecPopup),
            row("Resolution:", resPopup),
            row("FPS:",        fpsPopup),
        ]
        if includeRange {
            let rp = NSPopUpButton(frame: .zero, pullsDown: false)
            rp.addItem(withTitle: "Full Timeline")
            let tl = viewportView?.timeline
            let bothMarks = (tl?.inPoint != nil) && (tl?.outPoint != nil)
            if bothMarks, let tl = tl {
                rp.addItem(withTitle: String(format: "In \u{2192} Out  (%.2f\u{2013}%.2f s)",
                                             tl.playStart, tl.playEnd))
                rp.selectItem(at: 1)   // default to the marked range when available
            }
            rangePopup = rp
            rows.append(row("Range:", rp))
        }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment   = .trailing
        stack.spacing     = 8
        stack.edgeInsets  = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.frame = NSRect(x: 0, y: 0, width: 460, height: includeRange ? 164 : 132)

        print("[DEBUG] AppDelegate: export accessory view created")
        return (stack, codecPopup, resPopup, fpsPopup, rangePopup)
    }

    // MARK: - Edit > Remove

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Marks ▸ Go To / Delete submenus — rebuilt from the current marks each open.
        if menu === goToMarkSubmenu || menu === deleteMarkSubmenu {
            menu.removeAllItems()
            let marks = viewportView?.probeConfig.marks ?? []
            if marks.isEmpty {
                let empty = NSMenuItem(title: "No Marks", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
                return
            }
            let isGoTo = (menu === goToMarkSubmenu)
            for (i, mark) in marks.enumerated() {
                let item = NSMenuItem(
                    title: mark.name,
                    action: isGoTo ? #selector(goToMarkMenuItem(_:)) : #selector(deleteMarkMenuItem(_:)),
                    keyEquivalent: "")
                item.target = self
                item.tag    = i
                menu.addItem(item)
            }
            return
        }

        guard menu === removeSubmenu else { return }
        menu.removeAllItems()
        guard let scene = viewportView?.sceneManager else { return }

        // Show only root objects (parentIndex == nil), sorted alphabetically.
        // Sub-objects belong to groups and are managed through the Timeline Editor.
        let parents = scene.rootObjectIndicesSorted   // already filtered + sorted

        // One entry per model: collapse a multi-part model's roots (a flat group whose
        // parts are all parentIndex == nil) to a single "Delete <model>" entry, since
        // removing any part deletes the whole model.  Single objects stay individual.
        var seenGroups = Set<Int>()
        var entries: [(name: String, idx: Int)] = []
        for idx in parents {
            let obj = scene.objects[idx]
            if let gid = obj.groupID, !seenGroups.insert(gid).inserted { continue }
            entries.append((scene.displayName(for: obj), idx))
        }
        entries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        if entries.isEmpty {
            let empty = NSMenuItem(title: "No Objects", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for e in entries {
                let item = NSMenuItem(
                    title: e.name,
                    action: #selector(confirmRemoveObject(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag    = e.idx   // a root object of the model/object
                menu.addItem(item)
            }
        }
    }

    /// Right-click ▸ Delete from the Timeline grid.  Confirms, then removes whatever
    /// the row represents and refreshes (mirrors confirmRemoveObject's app-level steps).
    private func deleteTimelineRow(_ ref: TrackRef) {
        guard let vp = viewportView else { return }
        let sm = vp.sceneManager

        // Locked track can't be deleted — both the Timeline right-click ▸ Delete and
        // Edit ▸ Remove route here.  Gentle beep, like a blocked viewport edit.
        if vp.isLocked(ref) { NSSound.beep(); return }

        let title: String
        let perform: () -> Void

        switch ref {
        case .group(let gid):
            title   = "Delete \"\(sm.groupName(for: gid))\"?"
            let set = Set(sm.objects.indices.filter { sm.objects[$0].groupID == gid })
            perform = { vp.deleteObjects(set) }

        case .object(let i):
            guard i >= 0, i < sm.objects.count else { return }
            let obj = sm.objects[i]
            if obj.isEnvelope {
                title   = "Delete glued model \"\(sm.displayName(for: obj))\" and its members?"
                perform = { vp.deleteObjects(self.envelopeDeleteSet(i, sm)) }
            } else if obj.parentIndex != nil {
                title = "Delete member \"\(sm.displayName(for: obj))\"?"
                var set: Set<Int> = [i]
                if let gid = obj.groupID {
                    set.formUnion(sm.objects.indices.filter { sm.objects[$0].groupID == gid })
                }
                perform = { vp.deleteObjects(set) }
            } else if let gid = obj.groupID {
                title   = "Delete \"\(sm.groupName(for: gid))\"?"
                let set = Set(sm.objects.indices.filter { sm.objects[$0].groupID == gid })
                perform = { vp.deleteObjects(set) }
            } else {
                title   = "Delete \"\(sm.displayName(for: obj))\"?"
                perform = { vp.deleteObjects([i]) }
            }

        case .light(let i):
            guard i >= 0, i < vp.lightManager.lights.count, vp.lightManager.lights.count > 1 else { return }
            title   = "Delete Light \(i + 1) - \(vp.lightManager.lights[i].type.displayName)?"
            perform = { vp.deleteLight(i) }

        case .particles(let i):
            guard i >= 0, i < vp.particleManager.emitters.count, vp.particleManager.emitters.count > 1 else { return }
            title   = "Delete this weather emitter?"
            perform = { vp.deleteParticleEmitter(i) }

        case .importBundle(let bid):
            title   = "Delete import \"\(sm.bundleName(for: bid))\" and all its content?"
            perform = {
                // Imported lights + emitters first (descending so indices stay valid),
                // then objects.
                for li in vp.lightManager.lights.indices
                    .filter({ vp.lightManager.lights[$0].importBundleID == bid }).sorted(by: >) {
                    vp.deleteLight(li)
                }
                for pi in vp.particleManager.emitters.indices
                    .filter({ vp.particleManager.emitters[$0].importBundleID == bid }).sorted(by: >) {
                    vp.deleteParticleEmitter(pi)
                }
                let set = Set(sm.objects.indices.filter { sm.objects[$0].importBundleID == bid })
                vp.deleteObjects(set)
            }

        case .fog, .camera:
            return
        }

        let alert = NSAlert()
        alert.messageText     = title
        alert.informativeText = "This removes it from the project."
        alert.alertStyle      = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        perform()
        markDirty()
        timelineEditorWC?.updateWindowHeight()
        refreshCameraFollowTargets()
        timelineEditorWC?.editorView.needsDisplay = true
        vp.syncOverlayState()
    }

    /// Bundle header ▸ "Extend Spin/Orbit to End" — re-reads the source project's spin
    /// and orbit rate markers and re-places them onto this bundle's imported objects
    /// (time-offset by the import's T, orbit geometry by its M).  Because rate markers
    /// always bake out to the host timeline's end, the motion now runs to the end of
    /// the big scene AND is editable (change rate, reverse, drop a rate-0 to stop).
    private func extendBundleSpinOrbit(_ bid: Int, silent: Bool = false) {
        guard let vp = viewportView else { return }
        let sm = vp.sceneManager
        guard let src = sm.importBundleSources[bid], !src.path.isEmpty else { return }

        guard FileManager.default.fileExists(atPath: src.path),
              let json = try? Data(contentsOf: URL(fileURLWithPath: src.path)),
              let data = try? JSONDecoder().decode(ProjectData.self, from: json) else {
            if silent { return }   // auto-run on import: skip quietly if the source moved
            showErrorAlert(message: "Can't extend spin/orbit",
                           detail: "The source project couldn't be opened:\n\n\(src.path)\n\n"
                                 + "Restore the file or re-import to refresh the link.")
            return
        }

        let T = src.insertOffset
        let M = src.transform
        func point(_ a: [Float]) -> SIMD3<Float> {
            guard a.count == 3 else { return .zero }
            let p = M * SIMD4<Float>(a[0], a[1], a[2], 1); return SIMD3<Float>(p.x, p.y, p.z)
        }
        let scaleMag = simd_length(SIMD3<Float>(M.columns.0.x, M.columns.0.y, M.columns.0.z))

        var applied = 0

        // Spin — kind 2 (object), kind 3 (group).  Axis is local, so only the time
        // markers need the import's offset.
        for sd in data.spinRateSchedules where !sd.markers.isEmpty {
            // Only re-apply a schedule the SOURCE actually has BAKED motion for.  A
            // schedule whose target track is static (≤1 keyframe) is orphaned/stale
            // (e.g. a group spin that was never baked into the source's group track) —
            // re-baking it would ADD motion that wasn't active in the source.
            let occ = max(0, sd.targetIndex)
            let sourceBaked: Int
            switch sd.targetKind {
            case 3:
                let key = "\(sd.targetName)#\(occ)"
                sourceBaked = data.groupKeyframeTracks
                    .first { "\($0.sourceFileName)#\($0.occurrence)" == key }?.keyframes.count ?? 0
            case 2:
                var c = 0; var found = 0
                for o in data.objects where o.name == sd.targetName {
                    if c == occ { found = o.keyframes.count; break }
                    c += 1
                }
                sourceBaked = found
            default:
                sourceBaked = 0
            }
            guard sourceBaked > 1 else { continue }   // orphaned schedule — skip

            let markers = sd.markers.map { SpinRateMarker(time: $0.time + T, rate: $0.rate, axisIndex: $0.axisIndex, rate2: $0.rate2 ?? 0, axisIndex2: $0.axisIndex2 ?? 0) }
            switch sd.targetKind {
            case 2:
                if let idx = bundleObjectIndex(bid, name: sd.targetName, occurrence: max(0, sd.targetIndex), sm: sm) {
                    vp.setSpinSchedule(ref: .object(idx), markers: markers, keyframesPerRevolution: 12)
                    applied += 1
                }
            case 3:
                if let gid = bundleGroupGid(bid, filename: sd.targetName, occurrence: max(0, sd.targetIndex), sm: sm) {
                    vp.setSpinSchedule(ref: .group(gid), markers: markers, keyframesPerRevolution: 12)
                    applied += 1
                }
            default: break
            }
        }

        // Orbit — kind 2 (object).  Centre/axis are world points → transform by M;
        // radius by M's scale.
        for od in data.orbitRateSchedules
        where !od.markers.isEmpty && od.targetKind == 2 && od.axisStart.count == 3 && od.axisEnd.count == 3 {
            guard let idx = bundleObjectIndex(bid, name: od.targetName, occurrence: max(0, od.targetIndex), sm: sm)
            else { continue }
            let markers = od.markers.map { OrbitRateMarker(time: $0.time + T, rate: $0.rate) }
            let sched = OrbitRateSchedule(axisStart: point(od.axisStart), axisEnd: point(od.axisEnd),
                                          radius: od.radius * scaleMag, markers: markers)
            vp.setOrbitSchedule(ref: .object(idx), schedule: sched, keyframesPerRevolution: 12)
            applied += 1
        }

        guard applied > 0 else {
            if silent { return }   // auto-run on import: nothing to extend is fine
            let a = NSAlert()
            a.messageText     = "No editable spin/orbit found"
            a.informativeText = "The source project \"\(sm.bundleName(for: bid))\" has no spin or orbit "
                              + "rate markers to extend."
            a.runModal()
            return
        }
        markDirty()
        timelineEditorWC?.editorView.needsDisplay = true
        vp.renderer?.invalidateAnimationCache()
        print("[DEBUG] AppDelegate: extended \(applied) spin/orbit track(s) for bundle \(bid)")
    }

    /// The `occurrence`-th object named `name` within a bundle (object order), or nil.
    private func bundleObjectIndex(_ bid: Int, name: String, occurrence: Int, sm: SceneManager) -> Int? {
        var count = 0
        for (i, o) in sm.objects.enumerated() where o.importBundleID == bid && o.name == name {
            if count == occurrence { return i }
            count += 1
        }
        return nil
    }

    /// The gid of the `occurrence`-th group in a bundle whose source file is `filename`.
    private func bundleGroupGid(_ bid: Int, filename: String, occurrence: Int, sm: SceneManager) -> Int? {
        var seen = Set<Int>(); var count = 0
        for o in sm.objects where o.importBundleID == bid {
            guard let gid = o.groupID, seen.insert(gid).inserted else { continue }
            if (o.sourceURL?.lastPathComponent ?? "") == filename {
                if count == occurrence { return gid }
                count += 1
            }
        }
        return nil
    }

    /// Object indices for a glued unit: the envelope, its direct members, and any
    /// member's group parts (one level — nested envelopes aren't exposed).
    private func envelopeDeleteSet(_ envIdx: Int, _ sm: SceneManager) -> Set<Int> {
        var set: Set<Int> = [envIdx]
        for (j, o) in sm.objects.enumerated() where o.parentIndex == envIdx {
            set.insert(j)
            if let gid = o.groupID {
                for (k, g) in sm.objects.enumerated() where g.groupID == gid { set.insert(k) }
            }
        }
        return set
    }

    @objc private func confirmRemoveObject(_ sender: NSMenuItem) {
        guard let scene = viewportView?.sceneManager else { return }
        let index = sender.tag
        guard index >= 0, index < scene.objects.count else { return }

        // Route through the same robust deletion the Timeline grid uses (parentIndex +
        // spin/orbit schedule cleanup), classifying the root the same way.
        let obj = scene.objects[index]
        let ref: TrackRef
        if obj.isEnvelope          { ref = .object(index) }   // glued unit (+ members)
        else if let gid = obj.groupID { ref = .group(gid) }   // whole multi-part model
        else                          { ref = .object(index) }
        deleteTimelineRow(ref)
    }

    // MARK: - Glue (envelopes)

    @objc private func glueObjects(_ sender: Any) { presentGlueDialog() }

    /// Opens the Glue Objects dialog.  When `preselectBundles` is non-empty, candidates
    /// belonging to those import bundles are pre-checked and `defaultName` seeds the
    /// envelope name field — used by Import Project's "Glue imported items" so the user
    /// just confirms the anchor + name.
    private func presentGlueDialog(preselectBundles: Set<Int> = [], defaultName: String? = nil) {
        guard let scene = viewportView?.sceneManager else { return }
        let roots = scene.rootObjectIndicesSorted.filter { !scene.objects[$0].isEnvelope }
        guard roots.count >= 2 else { return }

        // Build candidates: ONE entry per multi-part model (group), named for the model
        // (e.g. "2-buckys-cylinder"), plus one per ungrouped object.  Group candidates
        // glue the WHOLE model as a kept-intact group member (see
        // docs/Glue-Groups-Design.md) — never flattened.  `candidateGroup` maps a
        // candidate's id → its gid.
        var candidates: [GlueOptions.Candidate] = []
        var candidateGroup: [Int: Int] = [:]
        var seenGroups = Set<Int>()
        for r in roots {
            let o = scene.objects[r]
            if let gid = o.groupID {
                guard seenGroups.insert(gid).inserted else { continue }
                candidates.append(GlueOptions.Candidate(id: r, name: scene.groupName(for: gid)))
                candidateGroup[r] = gid
            } else {
                candidates.append(GlueOptions.Candidate(id: r, name: scene.glueListName(for: o)))
            }
        }
        candidates.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard candidates.count >= 2 else { return }

        var preselected = Set<Int>()
        if !preselectBundles.isEmpty {
            // Import flow: pre-check candidates belonging to the just-imported bundle(s).
            func bundleOf(_ c: GlueOptions.Candidate) -> Int? {
                if let gid = candidateGroup[c.id] {
                    return scene.objects.first { $0.groupID == gid }?.importBundleID
                }
                guard c.id >= 0, c.id < scene.objects.count else { return nil }
                return scene.objects[c.id].importBundleID
            }
            for c in candidates where bundleOf(c).map({ preselectBundles.contains($0) }) ?? false {
                preselected.insert(c.id)
            }
        } else {
            // Menu flow: pre-select the candidate that owns the current selection.
            let sel = scene.selectedIndex
            if sel >= 0, sel < scene.objects.count {
                let selGid = scene.objects[sel].groupID
                if let owner = candidates.first(where: { c in
                    if let gid = candidateGroup[c.id] { return gid == selGid }
                    return c.id == sel
                }) { preselected.insert(owner.id) }
            }
        }
        let anchor = preselected.first ?? candidates[0].id
        let envCount = scene.objects.filter { $0.isEnvelope }.count

        let options = GlueOptions(
            candidates: candidates,
            selected:   preselected,
            anchor:     anchor,
            name:       defaultName ?? "Envelope \(envCount + 1)"
        )

        let alert = NSAlert()
        alert.messageText     = "Glue Objects"
        alert.informativeText = "Bind two or more objects so they move and animate as one unit."
        alert.addButton(withTitle: "Glue")
        alert.addButton(withTitle: "Cancel")
        // NSAlert clips an accessory view that has no explicit frame, which both
        // shrinks the panel and stops its controls (e.g. the name field) from
        // receiving clicks/keystrokes.  Size the hosting view to its content.
        let hosting = NSHostingView(rootView: GlueSheetView(options: options))
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        alert.accessoryView = hosting
        alert.layout()
        // Make the alert's window key so the SwiftUI text field can become editable.
        alert.window.makeFirstResponder(hosting)

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard options.selected.count >= 2, options.selected.contains(options.anchor) else {
            let warn = NSAlert()
            warn.messageText = "Select at least two objects (including the anchor) to glue."
            warn.runModal()
            return
        }
        // Split selected candidates into object members and group members (kept intact).
        var objMembers: [Int] = []
        var grpMembers: [Int] = []
        for id in options.selected {
            if let gid = candidateGroup[id] { grpMembers.append(gid) } else { objMembers.append(id) }
        }
        // Anchor (envelope origin): the chosen candidate — a group's first part if it's
        // a group candidate, else the object itself.
        let anchorIndex: Int
        if let gid = candidateGroup[options.anchor] {
            anchorIndex = scene.objects.firstIndex { $0.groupID == gid } ?? (objMembers.first ?? options.anchor)
        } else {
            anchorIndex = options.anchor
        }
        let trimmed = options.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let envName = trimmed.isEmpty ? "Envelope \(envCount + 1)" : trimmed

        if let envIndex = scene.makeEnvelope(name: envName,
                                             anchorIndex: anchorIndex,
                                             memberIndices: objMembers,
                                             groupMembers: grpMembers) {
            scene.selectedIndex = envIndex
            // Select the new envelope as the active object so the Timeline highlights
            // its lane (and a stale member-lane selection — now collapsed — is replaced).
            viewportView?.setControlMode(.object)
            markDirty()
            timelineEditorWC?.updateWindowHeight()
            refreshCameraFollowTargets()
            // Re-parenting changed members from roots to hierarchical parts; force the
            // animation to re-evaluate so animated members show their keyframed pose
            // immediately (otherwise they snap to their rest pose until the next scrub).
            viewportView?.renderer?.invalidateAnimationCache()
            print("[DEBUG] AppDelegate: glued \(objMembers.count) objects + \(grpMembers.count) groups into '\(envName)'")
        }
    }

    @objc private func unglueSelected(_ sender: Any) {
        guard let scene = viewportView?.sceneManager,
              let obj = scene.selectedObject, obj.isEnvelope else { return }
        let index = scene.selectedIndex

        let alert = NSAlert()
        alert.messageText     = "Unglue \"\(obj.name)\"?"
        alert.informativeText = "Members become independent again, keeping their current positions."
        alert.addButton(withTitle: "Unglue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        scene.removeEnvelope(at: index)
        scene.selectedIndex = 0
        markDirty()
        timelineEditorWC?.updateWindowHeight()
        refreshCameraFollowTargets()
        // Re-rooting changed members back to roots — re-evaluate the animation so
        // animated members keep showing their keyframed pose, not their rest pose.
        viewportView?.renderer?.invalidateAnimationCache()
    }

    @objc private func editGlueMembers(_ sender: Any) {
        guard let scene = viewportView?.sceneManager,
              let env = scene.selectedObject, env.isEnvelope else { return }
        let envIndex = scene.selectedIndex

        // Candidates: the envelope's current members + any addable non-envelope roots.
        let current = scene.objects.indices.filter { scene.objects[$0].parentIndex == envIndex }
        let addable = scene.rootObjectIndicesSorted.filter { !scene.objects[$0].isEnvelope }
        let ids     = Array(Set(current).union(addable))
        let candidates: [GlueOptions.Candidate] = ids
            .map { GlueOptions.Candidate(id: $0, name: scene.glueListName(for: scene.objects[$0])) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let options = GlueOptions(
            candidates: candidates,
            selected:   Set(current),
            anchor:     current.first ?? -1,
            name:       env.name,
            isEditing:  true
        )

        let alert = NSAlert()
        alert.messageText     = "Edit Glue Members"
        alert.informativeText = "Add or remove objects in \"\(env.name)\" without ungluing."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        let hosting = NSHostingView(rootView: GlueSheetView(options: options))
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        alert.accessoryView = hosting
        alert.layout()
        alert.window.makeFirstResponder(hosting)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let selected = options.selected
        guard selected.count >= 2 else {
            let warn = NSAlert()
            warn.messageText     = "An envelope needs at least two members."
            warn.informativeText = "Use Unglue to dissolve the unit entirely."
            warn.runModal()
            return
        }

        let cur     = Set(current)
        let added   = Array(selected.subtracting(cur))
        let removed = Array(cur.subtracting(selected))
        // No-op apply still lets a rename through, below.
        scene.addEnvelopeMembers(envIndex: envIndex, memberIndices: added)
        scene.removeEnvelopeMembers(envIndex: envIndex, memberIndices: removed)

        let trimmed = options.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { env.name = trimmed }

        scene.selectedIndex = envIndex
        markDirty()
        timelineEditorWC?.updateWindowHeight()
        refreshCameraFollowTargets()
        viewportView?.renderer?.invalidateAnimationCache()
        print("[DEBUG] AppDelegate: edited '\(env.name)' — added \(added.count), removed \(removed.count)")
    }

    /// Exports the current selection as one reusable `.glb` model — a single object,
    /// a whole multi-part model (group), or a glued envelope's subtree — baking each
    /// mesh's rest transform relative to the selection's own frame (so it re-imports
    /// at the origin) along with material overrides, Brightness, and textures.
    @objc private func exportModel(_ sender: Any) {
        guard let window = window, let scene = viewportView?.sceneManager,
              let sel = scene.selectedObject else { return }
        let objects  = scene.objects
        let selIndex = scene.selectedIndex

        // Live displayed world of `i` at the current playhead.  obj.transform already
        // holds the keyframe-evaluated world (applyHierarchy composes the parent chain);
        // the group matrix adds a multi-part model's placement.  Baking THIS (not the
        // REST baseTransform) captures the pose you see — including a keyframed assembly
        // like a posed "cone head" — which the rest pose would lose.
        func liveWorld(_ i: Int) -> matrix_float4x4 {
            let o  = objects[i]
            let gt = o.groupID.flatMap { scene.groupTransforms[$0] } ?? matrix_identity_float4x4
            return gt * o.transform
        }
        // True when `i` equals `root` or sits under it in the parent chain.
        func isUnder(_ i: Int, _ root: Int) -> Bool {
            var cur: Int? = i
            var hops = 0
            while let c = cur, hops <= objects.count {
                if c == root { return true }
                cur = objects[c].parentIndex
                hops += 1
            }
            return false
        }

        // Choose the export set + the frame the meshes bake relative to (so the model
        // re-imports at the origin): an envelope's subtree, a whole multi-part model
        // (group), or a single object.
        let memberIndices: [Int]
        let frameIndex:    Int
        let assetName:     String
        if sel.isEnvelope {
            frameIndex    = selIndex
            memberIndices = objects.indices.filter {
                !objects[$0].isEnvelope && objects[$0].indexCount > 0 && isUnder($0, selIndex)
            }
            assetName = sel.name
        } else if let gid = sel.groupID {
            memberIndices = objects.indices.filter { objects[$0].groupID == gid && objects[$0].indexCount > 0 }
            frameIndex    = objects.indices.first { objects[$0].groupID == gid && objects[$0].parentIndex == nil }
                            ?? memberIndices.first ?? selIndex
            assetName = scene.groupName(for: gid)
        } else {
            memberIndices = [selIndex]
            frameIndex    = selIndex
            assetName = scene.displayName(for: sel)
        }
        let frameInv = simd_inverse(liveWorld(frameIndex))

        var meshes: [GLBExporter.Mesh] = []
        var droppedTextures = false
        for i in memberIndices {
            let obj = objects[i]
            guard !obj.cpuPositions.isEmpty, !obj.cpuIndices.isEmpty else { continue }
            let rel = frameInv * liveWorld(i)
            let mat = obj.material
            // A texture that's loaded but whose source bytes weren't retained can't
            // be embedded (rare — e.g. an external image that moved); flag those.
            if (mat.baseColorTexture != nil && mat.baseColorSource == nil)
                || (mat.metallicRoughnessTexture != nil && mat.metallicRoughnessSource == nil)
                || (mat.normalTexture != nil && mat.normalSource == nil)
                || (mat.emissiveTexture != nil && mat.emissiveSource == nil) {
                droppedTextures = true
            }
            let alpha = mat.baseColorFactor.w * mat.opacity
            meshes.append(GLBExporter.Mesh(
                name:      obj.name,
                positions: obj.cpuPositions,
                normals:   obj.originalNormals.isEmpty ? nil : obj.originalNormals,
                uvs:       obj.cpuUVs.isEmpty ? nil : obj.cpuUVs,
                indices:   obj.cpuIndices,
                transform: rel,
                baseColor: SIMD4<Float>(mat.baseColorFactor.x, mat.baseColorFactor.y,
                                        mat.baseColorFactor.z, alpha),
                metallic:  mat.metallicFactor,
                roughness: mat.roughnessFactor,
                // Bake the Brightness override (base-colour self-emission) into the
                // exported emissiveFactor, matching the renderer, so a reused model
                // keeps its glow.
                emissive:  mat.emissiveFactor + SIMD3<Float>(mat.baseColorFactor.x,
                                                             mat.baseColorFactor.y,
                                                             mat.baseColorFactor.z) * mat.emissiveStrength,
                baseColorTex:  mat.baseColorSource,
                metalRoughTex: mat.metallicRoughnessSource,
                normalTex:     mat.normalSource,
                emissiveTex:   mat.emissiveSource))
        }

        guard !meshes.isEmpty else {
            showErrorAlert(message: "Nothing to export",
                           detail: "The selected object has no geometry to export.")
            return
        }

        if droppedTextures {
            let a = NSAlert()
            a.alertStyle      = .warning
            a.messageText     = "Some textures can't be embedded"
            a.informativeText = "One or more textures have no retained source image (e.g. an "
                + "external file that moved) and will be dropped — their colour/metalness/"
                + "roughness factors are still exported. Continue?"
            a.addButton(withTitle: "Continue")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }

        guard let data = GLBExporter.build(meshes: meshes, assetName: assetName) else {
            showErrorAlert(message: "Export failed", detail: "Could not build the model.")
            return
        }

        let panel = NSSavePanel()
        panel.title                = "Export Model"
        panel.canCreateDirectories = true
        panel.directoryURL         = defaultDirectory(for: "ExportedModels")
        panel.nameFieldStringValue = assetName + ".glb"
        if let glb = UTType(filenameExtension: "glb") { panel.allowedContentTypes = [glb] }

        // For an ENVELOPE export, offer to also save the source project alongside the
        // .glb.  The .glb bakes (and loses) the glue, so this companion .3dvp is the
        // only way to re-open and Unglue later.  Default on; non-envelope exports
        // (single object / plain multi-part model) re-import losslessly, so no checkbox.
        let saveSourceCheckbox: NSButton? = sel.isEnvelope
            ? NSButton(checkboxWithTitle: "Also save source project (.3dvp) for re-gluing",
                       target: nil, action: nil)
            : nil
        if let cb = saveSourceCheckbox {
            cb.state = .on
            panel.accessoryView = cb
        }

        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, var url = panel.url else { return }
            if url.pathExtension.lowercased() != "glb" { url.appendPathExtension("glb") }
            do {
                try data.write(to: url)
                print("[DEBUG] AppDelegate: exported model → "
                    + url.lastPathComponent + " (\(meshes.count) meshes)")
            } catch {
                self?.showErrorAlert(message: "Could not write model",
                                     detail: error.localizedDescription)
                return
            }

            // Companion source project (envelope exports only, when opted in) — written
            // to the dedicated Exported Model Projects folder to keep the library tidy.
            if saveSourceCheckbox?.state == .on,
               let self, let viewport = self.viewportView {
                let base      = url.deletingPathExtension().lastPathComponent
                let companion = self.defaultDirectory(for: "ExportedModelProjects")
                    .appendingPathComponent(base + ".3dvp")
                do {
                    try ProjectFile.save(to: companion, viewport: viewport,
                                         windowLayout: self.currentWindowLayout())
                    print("[DEBUG] AppDelegate: saved companion source project → "
                        + companion.lastPathComponent)
                } catch {
                    self.showErrorAlert(
                        message: "Model exported, but its source project couldn't be saved",
                        detail: error.localizedDescription)
                }
            }
        }
    }

    /// Duplicates the selected object/model: re-adds another instance from the same
    /// file (the robust load path, so it persists like loading the file twice), then
    /// carries the original's material overrides + places the copy at the original's
    /// position plus a small offset.  Animation is intentionally not copied.
    @objc private func duplicateObject(_ sender: Any) {
        guard let viewport = viewportView else { return }
        let sm = viewport.sceneManager
        guard let sel = sm.selectedObject, let url = sel.sourceURL else { return }

        // Capture the source's state BEFORE the duplicate is appended.
        let sourceGid   = sel.groupID
        let sourceParts = sourceGid.map { sm.objects(inGroup: $0) } ?? [sel]
        let sourceGroupT = sourceGid.flatMap { sm.groupTransforms[$0] }
        // Use the REST pose (not the animated `transform`, which folds in the current
        // keyframe delta) so a copy of a spinning/orbiting object lands cleanly.
        let sourceXform  = (sel.keyframeTrack?.keyframes.isEmpty == false)
                           ? sel.baseTransform : sel.transform
        let before       = sm.objects.count

        guard viewport.addModelToScene(url: url) == .added else { return }

        let newObjects = Array(sm.objects[before...])
        guard !newObjects.isEmpty else { return }
        let newGid = newObjects.first(where: { $0.parentIndex == nil })?.groupID

        // 1. Carry the inspector material overrides (factors only — the duplicate
        //    loads its own textures from the same file).  Match parts by name for a
        //    multi-part model (part names are unique within a model).
        func carry(from src: PBRMaterial, to dst: inout PBRMaterial) {
            dst.baseColorFactor  = src.baseColorFactor
            dst.metallicFactor   = src.metallicFactor
            dst.roughnessFactor  = src.roughnessFactor
            dst.opacity          = src.opacity
            dst.emissiveFactor   = src.emissiveFactor
            dst.emissiveStrength = src.emissiveStrength
        }
        if sourceGid != nil {
            var srcByName: [String: SceneObject] = [:]
            for p in sourceParts { srcByName[p.name] = p }
            for n in newObjects where srcByName[n.name] != nil {
                carry(from: srcByName[n.name]!.material, to: &n.material)
            }
        } else if let n = newObjects.first {
            carry(from: sel.material, to: &n.material)
        }

        // 2. Place the copy at the original's position + a small offset.
        var offset = matrix_identity_float4x4
        offset.columns.3 = SIMD4<Float>(0.5, 0, 0.5, 1)
        if let newGid {
            sm.groupTransforms[newGid] = offset * (sourceGroupT ?? matrix_identity_float4x4)
        } else if let n = newObjects.first {
            n.transform     = offset * sourceXform
            n.baseTransform = n.transform
        }

        markDirty()
        viewport.syncOverlayState()
        refreshCameraFollowTargets()
        timelineEditorWC?.editorView.needsDisplay = true
        timelineEditorWC?.updateWindowHeight()
        viewport.renderer?.invalidateAnimationCache()
        print("[DEBUG] AppDelegate: duplicated '\(sel.name)' → \(newObjects.count) new object(s)")
    }

    @objc private func confirmRemoveAll(_ sender: Any) {
        guard let scene = viewportView?.sceneManager,
              !scene.objects.isEmpty else { return }

        // Don't wipe the scene while anything is locked — beep and bail.  The user
        // can Unlock All in the Timeline Editor first, then Remove All.
        if scene.objects.contains(where: { $0.isLocked }) { NSSound.beep(); return }

        let alert = NSAlert()
        alert.messageText     = "Remove All Objects?"
        alert.informativeText = "This will remove all \(scene.objects.count) object(s) from the scene."
        alert.alertStyle      = .warning
        alert.addButton(withTitle: "Remove All")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            scene.clear()
            markDirty()
            timelineEditorWC?.updateWindowHeight()
            refreshCameraFollowTargets()
            print("[DEBUG] AppDelegate: removed all objects")
        }
    }
}
