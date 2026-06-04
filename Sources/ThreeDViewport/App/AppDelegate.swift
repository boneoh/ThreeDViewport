import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import simd

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {

    var window: NSWindow?
    var viewportView: ViewportView?
    let exportState = ExportState()

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

    // Bake probe inspector panel.
    private var probeInspectorPanel: NSPanel?

    // Last colour chosen in the Mark Position prompt — defaults the next mark's
    // colour so a run of related marks can share one colour.
    private var lastMarkColor: NSColor = .systemYellow

    // Rotation Path Animator helper panel.
    private var rotationPathPanel: NSPanel?

    // Linear Path Animator helper panel.
    private var linearPathPanel: NSPanel?

    // Global settings panel.
    private var settingsPanel: NSPanel?

    // Edit > Remove submenu — repopulated dynamically by NSMenuDelegate.
    private var removeSubmenu: NSMenu?

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
            self.modelInspectorState?.update(targets: targets)
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

        applyTemplateIfPresent()
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
    }

    // MARK: - Dirty tracking

    private func markDirty() { isDirty = true }

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

        fileMenu.addItem(.separator())

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

        viewMenu.addItem(.separator())

        // Loop Playback — when on, animation restarts instead of stopping at the end
        let loopItem = NSMenuItem(
            title: "Loop Playback",
            action: #selector(toggleLoopPlayback(_:)),
            keyEquivalent: ""
        )
        loopItem.target = self
        viewMenu.addItem(loopItem)

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

        // Floating inspector panels — alphabetical order
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

        let showMarksItem = NSMenuItem(
            title: "Show Marks",
            action: #selector(toggleMarks(_:)),
            keyEquivalent: ""
        )
        showMarksItem.target = self
        windowMenu.addItem(showMarksItem)

        let pathAnimatorItem = NSMenuItem(title: "Path Animator", action: nil, keyEquivalent: "")
        let pathSubmenu = NSMenu(title: "Path Animator")
        let rotationPathItem = NSMenuItem(
            title: "Rotation…",
            action: #selector(showRotationPathAnimator(_:)),
            keyEquivalent: ""
        )
        rotationPathItem.target = self
        pathSubmenu.addItem(rotationPathItem)
        let linearPathItem = NSMenuItem(
            title: "Linear…",
            action: #selector(showLinearPathAnimator(_:)),
            keyEquivalent: ""
        )
        linearPathItem.target = self
        pathSubmenu.addItem(linearPathItem)
        pathAnimatorItem.submenu = pathSubmenu
        windowMenu.addItem(pathAnimatorItem)

        let timelineEditorItem = NSMenuItem(
            title: "Timeline Editor",
            action: #selector(showTimelineEditor(_:)),
            keyEquivalent: "j"
        )
        timelineEditorItem.target = self
        windowMenu.addItem(timelineEditorItem)

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
            self?.viewportView?.addModelToScene(url: url)
            self?.markDirty()
            self?.timelineEditorWC?.updateWindowHeight()
            self?.refreshCameraFollowTargets()
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
            print("[DEBUG] AppDelegate: offset-migration — gid=\(gid) root='\(root.name)'"
                + " offset=(\(t.x), \(t.y), \(t.z)) len=\(len)")
            if len > 1e-4 {
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
            saveProjectAs(sender)
        }
    }

    @objc private func saveProjectAs(_ sender: Any) {
        guard let window = window else { return }
        guard let viewport = viewportView else { return }

        let panel = NSSavePanel()
        panel.title                = "Save Project"
        panel.canCreateDirectories = true
        let projectsDir = defaultDirectory(for: "Projects")
        panel.directoryURL         = projectsDir

        // Default filename:
        //   • Saved project → append the next "rev <letter>" suffix, e.g.
        //     `Project 1` → `Project 1 rev A`, `Project 1 rev A` → `Project 1 rev B`.
        //   • Unsaved project with a template-derived name → use it as-is.
        //   • Unsaved project with a loaded model → name from the first model's filename.
        //   • Empty fallback → "project.3dvp".
        if let current = currentProjectURL {
            let base = current.deletingPathExtension().lastPathComponent
            panel.nameFieldStringValue = nextProjectRevisionName(baseName: base,
                                                                  in: projectsDir) + ".3dvp"
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
        if let wc = timelineEditorWC, wc.window?.isVisible == true {
            wc.window?.orderOut(nil)
            panelsHiddenByMiniaturize.insert("timeline")
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
        if panelsHiddenByMiniaturize.contains("timeline")       { timelineEditorWC?.showWindow(nil) }
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
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(replaceSelectedModel(_:)) {
            // Disabled when no object is selected.
            return viewportView?.sceneManager.selectedObject != nil
        }
        if menuItem.action == #selector(addFollowCameraKeyframe(_:)) {
            // Disabled when no model is in the scene (need something to follow).
            return viewportView?.sceneManager.primaryObject != nil
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
        return true
    }

    // MARK: - Settings

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
            }
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
    private func refreshCameraFollowTargets() {
        guard let viewport = viewportView else { return }
        // Sort alphabetically (natural order so `head10` follows `head2`,
        // not `head1`).  "None — Free Camera" is rendered separately at
        // the top of the picker, so it isn't in this list.
        // Dedupe — two robots both export "head" / "ankle_L" / etc.; SwiftUI
        // Picker's id:\.self crashes warnings on duplicate strings, and a
        // picker with two identical tags can't represent a stable selection.
        var seen = Set<String>()
        viewport.cameraPanelState.availableObjectNames =
            viewport.sceneManager.objects
                .map { $0.name }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .filter { seen.insert($0).inserted }
        // If the previously-chosen follow target no longer exists in the
        // scene (e.g. the model was removed or replaced), reset to free
        // camera so the picker shows a valid selection.
        if let chosen = viewport.cameraPanelState.followTargetName,
           !viewport.cameraPanelState.availableObjectNames.contains(chosen) {
            viewport.cameraPanelState.followTargetName = nil
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
            // Match translateGroup's ±100 clamp on the group translation.
            let clamped = simd_clamp(newT,
                                     SIMD3<Float>(repeating: -100),
                                     SIMD3<Float>(repeating:  100))
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
        state.update(targets: targets)

        // Wire callbacks.
        state.onRedraw = { [weak viewport] in viewport?.needsDisplay = true }
        state.onDirty  = { [weak self] in self?.markDirty() }
        state.isPlaying = { [weak viewport] in viewport?.timeline.isPlaying ?? false }
        state.onRebuildNormals = { [weak viewport] mode, targets in
            viewport?.applyNormalMode(mode, toTargets: targets)
        }
        state.onRevealInFinder = { [weak viewport] in
            guard let url = viewport?.sceneManager.selectedObject?.sourceURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }

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
                viewportView?.probeConfig.isVisible = true   // re-show the gizmo
                panel.makeKeyAndOrderFront(nil)
            }
            return
        }

        guard let viewport = viewportView else { return }
        viewport.probeConfig.isVisible = true   // show the gizmo when the panel first opens

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
            onMarkPosition: { [weak self] in self?.promptForMark() }))

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

    // MARK: - Linear Path Animator

    @objc private func showLinearPathAnimator(_ sender: Any) {
        if let panel = linearPathPanel {
            panel.isVisible ? panel.orderOut(nil) : panel.makeKeyAndOrderFront(nil)
            return
        }
        guard let viewport = viewportView else { return }
        let state = viewport.linearPathState

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
        guard let viewport = viewportView,
              let editor = timelineEditorWC?.editorView else { return }
        let state = viewport.linearPathState
        guard let ref = editor.selectedTrackRef else {
            state.status = "Select a camera, light, or object track in the Timeline first."
            return
        }
        switch ref {
        case .camera, .light, .object:
            state.capturedRef = ref
            state.trackLabel  = pathAnimatorTrackLabel(ref)
            state.startTime   = viewport.timeline.currentTime
            state.status      = "Captured start time."
        default:
            state.status = "Path Animator supports camera, light, and object tracks only."
        }
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
            state.status = "Capture both line points first."; return
        }
        guard let ref = state.capturedRef, let t0 = state.startTime, let t1 = state.endTime else {
            state.status = "Capture the track and start/end times first."; return
        }
        guard abs(t1 - t0) > 1e-4 else {
            state.status = "Start and end times must differ."; return
        }
        guard let count = Int(state.keyframes), count >= 2 else {
            state.status = "Keyframes must be a whole number ≥ 2."; return
        }

        let samples = PathGenerator.linearSamples(
            start: a, end: b, startTime: min(t0, t1), endTime: max(t0, t1), count: count)
        viewport.generateLinearPath(ref: ref, samples: samples, travelDir: b - a)

        timelineEditorWC?.editorView.needsDisplay = true
        markDirty()
        state.status = "Created \(samples.count) keyframes for \(pathAnimatorTrackLabel(ref))."
        print("[DEBUG] AppDelegate: linear path animator created \(samples.count) keyframes")
    }

    // MARK: - Rotation Path Animator

    @objc private func showRotationPathAnimator(_ sender: Any) {
        if let panel = rotationPathPanel {
            panel.isVisible ? panel.orderOut(nil) : panel.makeKeyAndOrderFront(nil)
            return
        }
        guard let viewport = viewportView else { return }
        let state = viewport.rotationPathState

        let panel = KeyForwardingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 560),
            styleMask:   [.titled, .closable, .miniaturizable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        panel.title                  = "Rotation Path Animator"
        panel.isFloatingPanel        = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.forwardTarget          = viewport
        panel.level                  = .normal
        panel.hidesOnDeactivate      = false

        panel.contentView = FirstClickHostingView(rootView: RotationPathAnimatorPanel(
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
            captureStart: { [weak self] in self?.rotationPathCaptureStart() },
            captureEnd:   { [weak self] in self?.rotationPathCaptureEnd() },
            create:       { [weak self] in self?.rotationPathCreate() }
        ))

        if let win = window {
            let f = win.frame
            panel.setFrameOrigin(NSPoint(x: f.minX + 20, y: f.maxY - panel.frame.height - 40))
        } else {
            panel.center()
        }

        rotationPathPanel = panel
        panel.makeKeyAndOrderFront(nil)
        print("[DEBUG] AppDelegate: rotation path animator panel opened")
    }

    /// Human-readable label for a captured track.
    private func pathAnimatorTrackLabel(_ ref: TrackRef) -> String {
        switch ref {
        case .camera:        return "Camera"
        case .light(let i):  return "Light \(i + 1)"
        case .object(let i):
            if let objs = viewportView?.sceneManager.objects, i >= 0, i < objs.count {
                return objs[i].name
            }
            return "Object \(i + 1)"
        default:             return "Unsupported"
        }
    }

    private func rotationPathCaptureStart() {
        guard let viewport = viewportView,
              let editor = timelineEditorWC?.editorView else { return }
        let state = viewport.rotationPathState
        guard let ref = editor.selectedTrackRef else {
            state.status = "Select a camera, light, or object track in the Timeline first."
            return
        }
        switch ref {
        case .camera, .light, .object:
            state.capturedRef = ref
            state.trackLabel  = pathAnimatorTrackLabel(ref)
            state.startTime   = viewport.timeline.currentTime
            state.status      = "Captured start time."
        default:
            state.status = "Path Animator supports camera, light, and object tracks only."
        }
    }

    private func rotationPathCaptureEnd() {
        guard let viewport = viewportView else { return }
        let state = viewport.rotationPathState
        state.endTime = viewport.timeline.currentTime
        state.status  = "Captured end time."
    }

    private func rotationPathCreate() {
        guard let viewport = viewportView else { return }
        let state = viewport.rotationPathState

        guard let a = state.axisStart, let b = state.axisEnd else {
            state.status = "Capture both axis points first."; return
        }
        guard let ref = state.capturedRef, let t0 = state.startTime, let t1 = state.endTime else {
            state.status = "Capture the track and start/end times first."; return
        }
        guard abs(t1 - t0) > 1e-4 else {
            state.status = "Start and end times must differ."; return
        }
        guard let radius = Float(state.radius),
              let startA = Float(state.startAngle),
              let endA   = Float(state.endAngle),
              let revs   = Float(state.revolutions),
              let perRev = Float(state.perRev), perRev >= 1 else {
            state.status = "Check the numeric fields (keyframes/rev ≥ 1)."; return
        }

        let samples = PathGenerator.samples(
            axisStart: a, axisEnd: b, radius: radius,
            startAngleDeg: startA, endAngleDeg: endA, revolutions: revs,
            startTime: min(t0, t1), endTime: max(t0, t1),
            keyframesPerRevolution: perRev)

        let fixedAim = (a + b) * 0.5
        viewport.generatePath(ref: ref, samples: samples, fixedAim: fixedAim)

        timelineEditorWC?.editorView.needsDisplay = true
        markDirty()
        state.status = "Created \(samples.count) keyframes for \(pathAnimatorTrackLabel(ref))."
        print("[DEBUG] AppDelegate: path animator created \(samples.count) keyframes")
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
            }
        }

        // ── Viewport mode / selection change → timeline lane highlight ─────────
        // Pressing C / L / O (or cycling with L / O) in the viewport updates
        // the highlighted row in the timeline editor.
        viewport.onControlModeChanged = { [weak wc] ref in
            wc?.editorView.selectTrack(ref)
        }

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

        let (accessory, codecPopup, resPopup, fpsPopup) = makeExportAccessoryView()
        let alert = NSAlert()
        alert.messageText     = "Export All Passes"
        alert.informativeText = "Renders the full pass set (Full, Actor/MacGuffin Solo + Matte, Scene) into Movies/\(projectName)/ using one codec. The project is saved first and reloaded when the cycle finishes."
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

            // Checkpoint: save current state so the cycle can reload it afterward.
            self.saveProject(sender)

            let cycle = self.nextCycleNumber(projectName: projectName, in: projectMovieDir)
            print("[DEBUG] AppDelegate: Export All cycle \(cycle) codec=\(codec.displayName)"
                + " res=\(res.width)x\(res.height) fps=\(fps.display)")

            self.viewportView?.startExportAll(
                folder: projectMovieDir, projectName: projectName, cycleNumber: cycle,
                codec: codec, fps: fps, exportState: self.exportState
            ) { [weak self] error in
                guard let self = self else { return }
                // Restore exact pre-cycle state by reloading the checkpoint project.
                self.loadProject(from: projectURL)
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

        let projectName = projectURL.deletingPathExtension().lastPathComponent
        let projectMovieDir = defaultDirectory(for: "Movies")
            .appendingPathComponent(projectName)
        try? FileManager.default.createDirectory(at: projectMovieDir,
                                                 withIntermediateDirectories: true)
        let defaultName = nextMovieFilename(projectName: projectName, in: projectMovieDir)

        let (accessory, codecPopup, resPopup, fpsPopup) = makeExportAccessoryView()

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

            print("[DEBUG] AppDelegate: export — " + url.lastPathComponent
                + " codec=" + codec.displayName
                + " res=\(res.width)×\(res.height) fps=" + fps.display)
            self.viewportView?.startExport(
                to: url, codec: codec, fps: fps, exportState: self.exportState
            ) { [weak self] error in
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

    private func makeExportAccessoryView() -> (view: NSView,
                                               codec: NSPopUpButton,
                                               resolution: NSPopUpButton,
                                               fps: NSPopUpButton) {
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

        let stack = NSStackView(views: [
            row("Format:",     codecPopup),
            row("Resolution:", resPopup),
            row("FPS:",        fpsPopup),
        ])
        stack.orientation = .vertical
        stack.alignment   = .trailing
        stack.spacing     = 8
        stack.edgeInsets  = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.frame = NSRect(x: 0, y: 0, width: 460, height: 132)

        print("[DEBUG] AppDelegate: export accessory view created")
        return (stack, codecPopup, resPopup, fpsPopup)
    }

    // MARK: - Edit > Remove

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === removeSubmenu else { return }
        menu.removeAllItems()
        guard let scene = viewportView?.sceneManager else { return }

        // Show only root objects (parentIndex == nil), sorted alphabetically.
        // Sub-objects belong to groups and are managed through the Timeline Editor.
        let parents = scene.rootObjectIndicesSorted   // already filtered + sorted

        if parents.isEmpty {
            let empty = NSMenuItem(title: "No Objects", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for idx in parents {
                let obj  = scene.objects[idx]
                // Display the group name (e.g. filename) for grouped models,
                // or the object name for standalone objects.
                let displayName: String
                if let gid = obj.groupID {
                    displayName = scene.groupName(for: gid)
                } else {
                    displayName = obj.name
                }
                let item = NSMenuItem(
                    title: displayName,
                    action: #selector(confirmRemoveObject(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag    = idx   // index of the root object in sceneManager.objects
                menu.addItem(item)
            }
        }
    }

    @objc private func confirmRemoveObject(_ sender: NSMenuItem) {
        guard let scene = viewportView?.sceneManager else { return }
        let index = sender.tag
        guard index >= 0, index < scene.objects.count else { return }

        let obj = scene.objects[index]
        let displayName: String
        if let gid = obj.groupID {
            displayName = scene.groupName(for: gid)
        } else {
            displayName = obj.name
        }

        let alert = NSAlert()
        alert.messageText     = "Remove \"\(displayName)\"?"
        alert.informativeText = "Are you sure you want to remove \(displayName) from the project?"
        alert.alertStyle      = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Removes the root and all sub-objects that share its groupID.
            scene.removeGroup(containing: index)
            markDirty()
            timelineEditorWC?.updateWindowHeight()
            refreshCameraFollowTargets()
        }
    }

    @objc private func confirmRemoveAll(_ sender: Any) {
        guard let scene = viewportView?.sceneManager,
              !scene.objects.isEmpty else { return }

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
