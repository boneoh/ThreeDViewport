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

    // Camera keyframe inspector panel.
    private var cameraPanel: NSPanel?

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
                   savedDirection: SIMD3<Float>, savedPosition: SIMD3<Float>, kfTime: Double)
        case group(gid: Int, savedTransform: matrix_float4x4, kfTime: Double)
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

    // Combine subscriptions that set isDirty when any Observable setting changes.
    private var settingsCancellables = Set<AnyCancellable>()

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
                // No URL yet — show Save As; user must re-quit after saving.
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

        // ColorGradeSettings covers brightness and contrast.
        viewport.colorGradeSettings.objectWillChange
            .sink { [weak self] in self?.markDirty() }
            .store(in: &settingsCancellables)

        print("[DEBUG] AppDelegate: subscribed to settings changes for dirty tracking")
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

        // Greyscale Mode — checkmark driven by validateMenuItem
        let greyItem = NSMenuItem(
            title: "Greyscale Mode",
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

        // Floating inspector panels
        let lightsItem = NSMenuItem(
            title: "Lights & Background…",
            action: #selector(showLightsInspector(_:)),
            keyEquivalent: "l"
        )
        lightsItem.target = self
        windowMenu.addItem(lightsItem)

        let feedbackItem = NSMenuItem(
            title: "Feedback…",
            action: #selector(showFeedbackPanel(_:)),
            keyEquivalent: "f"
        )
        feedbackItem.target = self
        windowMenu.addItem(feedbackItem)

        let colorGradeItem = NSMenuItem(
            title: "Color Grade…",
            action: #selector(showColorGradePanel(_:)),
            keyEquivalent: "G"   // ⌘⇧G — uppercase encodes the shift modifier
        )
        colorGradeItem.target = self
        windowMenu.addItem(colorGradeItem)

        let cameraPanelItem = NSMenuItem(
            title: "Camera…",
            action: #selector(showCameraPanel(_:)),
            keyEquivalent: "k"
        )
        cameraPanelItem.target = self
        windowMenu.addItem(cameraPanelItem)

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

    /// Returns ~/Documents/ThreeDViewport/<subfolder>, creating it if needed.
    private func defaultDirectory(for subfolder: String) -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ThreeDViewport")
            .appendingPathComponent(subfolder)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Default starting folder for any "pick a model file" sheet.  If a
    /// `Models/Favorites/` subfolder exists, jumps straight to it; otherwise
    /// falls back to the Models root.  Favorites is never auto-created — the
    /// user opts in by making the folder themselves.
    private func defaultModelDirectory() -> URL {
        let models    = defaultDirectory(for: "Models")
        let favorites = models.appendingPathComponent("Favorites")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: favorites.path, isDirectory: &isDir),
           isDir.boolValue {
            return favorites
        }
        return models
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

    // MARK: - Template projects

    /// If `template.3dvp` exists in the Projects folder, load it as the starting
    /// scene for a fresh session, then detach so Save acts as Save-As and
    /// pre-fill the name with the next available "Project N".
    private func applyTemplateIfPresent() {
        let templateURL = defaultDirectory(for: "Projects")
            .appendingPathComponent("template.3dvp")
        guard FileManager.default.fileExists(atPath: templateURL.path) else { return }

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
        }
    }

    // MARK: - Add Model to Scene (Phase 6)

    @objc private func addModelToScene(_ sender: Any) {
        guard let window = window else {
            print("[DEBUG] AppDelegate: addModelToScene — window is nil")
            return
        }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories    = false
        panel.canChooseFiles          = true
        panel.title        = "Add Model to Scene"
        panel.directoryURL = defaultModelDirectory()

        let modelTypes = [UTType(filenameExtension: "glb"), UTType(filenameExtension: "gltf")]
            .compactMap { $0 }
        if !modelTypes.isEmpty {
            panel.allowedContentTypes = modelTypes
        }

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else {
                print("[DEBUG] AppDelegate: add-model panel cancelled")
                return
            }
            print("[DEBUG] AppDelegate: addModelToScene — " + url.lastPathComponent)
            self?.viewportView?.addModelToScene(url: url)
            self?.markDirty()
        }
    }

    // MARK: - Replace Selected Model

    @objc private func replaceSelectedModel(_ sender: Any) {
        guard let window = window else { return }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories    = false
        panel.canChooseFiles          = true
        panel.title                   = "Replace Selected Model"
        panel.prompt                  = "Replace"
        panel.message                 = "Choose a .glb file to replace the selected model's geometry."
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
            print("[DEBUG] AppDelegate: project loaded from " + url.lastPathComponent)
        } catch {
            showErrorAlert(message: "Could not open project", detail: error.localizedDescription)
        }
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
            guard response == .OK, var url = panel.url else { return }
            guard let self = self else { return }
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
            } catch {
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
        if panelsHiddenByMiniaturize.contains("camera")     { cameraPanel?.makeKeyAndOrderFront(nil) }
        if panelsHiddenByMiniaturize.contains("timeline")   { timelineEditorWC?.showWindow(nil) }
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
        viewportView?.renderSettings.isColorMode.toggle()
        print("[DEBUG] AppDelegate: colorMode toggled to "
            + String(viewportView?.renderSettings.isColorMode ?? false))
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
            // Checkmark when greyscale is active (isColorMode == false).
            let isGreyscale = !(viewportView?.renderSettings.isColorMode ?? true)
            menuItem.state = isGreyscale ? .on : .off
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

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 296, height: 720),
            styleMask:   [.titled, .closable, .miniaturizable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        panel.title         = "Lights & Background"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false

        let inspectorView = LightsInspectorPanel(
            lightManager:     viewport.lightManager,
            backgroundConfig: viewport.backgroundConfig,
            renderSettings:   viewport.renderSettings,
            camera:           viewport.camera
        )

        let hostingView = NSHostingView(rootView: inspectorView)
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

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 296, height: 280),
            styleMask:   [.titled, .closable, .miniaturizable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        panel.title              = "Feedback"
        panel.isFloatingPanel    = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate  = false

        let feedbackView = FeedbackPanelWrapper(
            settings:  viewport.feedbackSettings,
            processor: viewport.feedbackProcessor
        )
        panel.contentView = NSHostingView(rootView: feedbackView)

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

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 296, height: 200),
            styleMask:   [.titled, .closable, .miniaturizable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        panel.title              = "Color Grade"
        panel.isFloatingPanel    = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate  = false

        let gradeView = ColorGradePanel(settings: viewport.colorGradeSettings)
        panel.contentView = NSHostingView(rootView: gradeView)

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

    // MARK: - Camera Panel

    @objc private func showCameraPanel(_ sender: Any) {
        // Refresh the picker's object-name list every time the menu item is
        // invoked, so newly-loaded models appear without requiring a restart
        // of the panel.  Cheap enough to do unconditionally.
        if let viewport = viewportView {
            // Sort alphabetically (natural order so `head10` follows `head2`,
            // not `head1`).  "None — Free Camera" is rendered separately at
            // the top of the picker, so it isn't in this list.
            viewport.cameraPanelState.availableObjectNames =
                viewport.sceneManager.objects
                    .map { $0.name }
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            // If the previously-chosen follow target no longer exists in the
            // scene (e.g. the model was removed or replaced), reset to free
            // camera so the picker shows a valid selection.
            if let chosen = viewport.cameraPanelState.followTargetName,
               !viewport.cameraPanelState.availableObjectNames.contains(chosen) {
                viewport.cameraPanelState.followTargetName = nil
            }
        }

        if let panel = cameraPanel {
            panel.isVisible ? panel.orderOut(nil) : panel.makeKeyAndOrderFront(nil)
            return
        }

        guard let viewport = viewportView else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 296, height: 260),
            styleMask:   [.titled, .closable, .miniaturizable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        panel.title              = "Camera"
        panel.isFloatingPanel    = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate  = false

        let cameraView = CameraPanel(
            state: viewport.cameraPanelState,
            onStampKeyframe: { [weak self, weak viewport] in
                viewport?.addCameraKeyframeFromPanel()
                self?.markDirty()
            }
        )
        panel.contentView = NSHostingView(rootView: cameraView)

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
        panel.makeKeyAndOrderFront(nil)
        print("[DEBUG] AppDelegate: camera panel opened")
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
            }
            return
        }

        guard let viewport = viewportView else { return }

        let wc = TimelineEditorWindowController(
            timeline:     viewport.timeline,
            sceneManager: viewport.sceneManager,
            camera:       viewport.camera,
            lightManager: viewport.lightManager
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
        wc.editorView.onKeyframeDeleted = { [weak self] in
            self?.markDirty()
        }
        wc.editorView.onKeyframePasted = { [weak self] in
            self?.markDirty()
        }

        // ── Enter edit mode ───────────────────────────────────────────────────
        // Called when the user presses Return on a selected diamond.
        // Save the pose that the keyframe currently stores, seek to its time,
        // and switch the viewport to the appropriate control mode so the user
        // can adjust the pose live with normal mouse / keyboard controls.
        wc.editorView.onEnterEditMode = { [weak self, weak viewport] ref, kfTime in
            guard let self = self, let viewport = viewport else { return }

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
                let savedDirection:  SIMD3<Float>
                let savedPosition:   SIMD3<Float>
                if i < lm.keyframeTracks.count,
                   let track = lm.keyframeTracks[i],
                   let state = track.evaluate(at: kfTime) {
                    savedIntensity  = state.intensity
                    savedColor      = state.color
                    savedDirection  = state.direction
                    savedPosition   = state.position
                } else {
                    let light       = lm.lights[i]
                    savedIntensity  = light.intensity
                    savedColor      = light.color
                    savedDirection  = light.direction
                    savedPosition   = light.position
                }
                self.kfEditSnapshot = .light(
                    index:          i,
                    savedIntensity: savedIntensity,
                    savedColor:     savedColor,
                    savedDirection: savedDirection,
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
            }
        }

        // ── Commit edit ───────────────────────────────────────────────────────
        // The user pressed Return a second time.  The object/camera is already at
        // the new pose (the user moved it live).  Write a keyframe — addKeyframe
        // deduplicates within 1 ms, so this naturally overwrites the old one.
        wc.editorView.onCommitEdit = { [weak self, weak viewport] in
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
            }

            self.kfEditSnapshot = nil
            self.markDirty()
        }

        // ── Cancel edit ───────────────────────────────────────────────────────
        // The user pressed Escape.  Restore the saved pose so the keyframe's
        // original state is visible again.
        wc.editorView.onCancelEdit = { [weak self, weak viewport] in
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
                        let savedDirection, let savedPosition, let kfTime):
                guard index < viewport.lightManager.lights.count else { return }
                viewport.lightManager.lights[index].intensity  = savedIntensity
                viewport.lightManager.lights[index].color      = savedColor
                viewport.lightManager.lights[index].direction  = savedDirection
                viewport.lightManager.lights[index].position   = savedPosition
                print("[DEBUG] AppDelegate: cancelled light keyframe edit index=\(index)"
                    + " t=" + String(format: "%.3f", kfTime))

            case .group(let gid, let savedTransform, let kfTime):
                viewport.sceneManager.groupTransforms[gid] = savedTransform
                print("[DEBUG] AppDelegate: cancelled group keyframe edit gid=\(gid)"
                    + " t=" + String(format: "%.3f", kfTime))
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
            }
        }

        // ── Viewport mode / selection change → timeline lane highlight ─────────
        // Pressing C / L / O (or cycling with L / O) in the viewport updates
        // the highlighted row in the timeline editor.
        viewport.onControlModeChanged = { [weak wc] ref in
            wc?.editorView.selectTrack(ref)
        }

        // ── Bidirectional key forwarding ───────────────────────────────────────
        // Timeline editor → viewport: unhandled keys reach the viewport.
        wc.editorView.keyForwardTarget = viewport
        // Viewport → timeline editor: unhandled keys reach the timeline editor.
        viewport.timelineKeyTarget = wc.editorView

        timelineEditorWC = wc
        wc.showWindow(nil)
        positionTimelineEditor(wc)
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

        let (accessory, codecPopup) = makeCodecAccessoryView()

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
            print("[DEBUG] AppDelegate: export destination — " + url.lastPathComponent
                + " codec=" + codec.displayName)
            guard let self = self else { return }
            self.viewportView?.startExport(to: url, codec: codec, exportState: self.exportState)
        }
    }

    private func makeCodecAccessoryView() -> (view: NSView, popup: NSPopUpButton) {
        let label = NSTextField(labelWithString: "Format:")
        label.font            = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.alignment       = .right
        label.isEditable      = false
        label.isBezeled       = false
        label.drawsBackground = false

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItem(withTitle: ExportCodec.proRes4444.displayName)
        popup.addItem(withTitle: ExportCodec.proRes422HQ.displayName)
        popup.selectItem(at: 1)   // default: ProRes 422 HQ
        popup.sizeToFit()

        let stack = NSStackView(views: [label, popup])
        stack.orientation  = .horizontal
        stack.alignment    = .centerY
        stack.spacing      = 8
        stack.edgeInsets   = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.frame = NSRect(x: 0, y: 0, width: 420, height: 44)

        print("[DEBUG] AppDelegate: codec accessory view created")
        return (stack, popup)
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
            print("[DEBUG] AppDelegate: removed all objects")
        }
    }
}
