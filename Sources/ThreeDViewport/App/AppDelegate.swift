import AppKit
import SwiftUI
import UniformTypeIdentifiers
import simd

final class AppDelegate: NSObject, NSApplicationDelegate {

    var window: NSWindow?
    var viewportView: ViewportView?
    let exportState = ExportState()

    // Phase 7: Floating lights & background inspector panel.
    private var lightsPanel: NSPanel?

    // Feedback delay-line panel.
    private var feedbackPanel: NSPanel?

    // Timeline editor (AppKit canvas panel).
    private var timelineEditorWC: TimelineEditorWindowController?

    // ── Keyframe edit-mode snapshot ───────────────────────────────────────────
    // Stores the state that existed when the user entered edit mode, so we can
    // restore it on Escape / cancel.
    private enum KFEditSnapshot {
        case object(index: Int, savedTransform: matrix_float4x4, kfTime: Double)
        case camera(yaw: Float, pitch: Float, distance: Float,
                    target: SIMD3<Float>, kfTime: Double)
        case light(index: Int, savedIntensity: Float, savedColor: SIMD3<Float>,
                   savedDirection: SIMD3<Float>, savedPosition: SIMD3<Float>, kfTime: Double)
    }
    private var kfEditSnapshot: KFEditSnapshot? = nil

    // Tracks the last saved/opened project URL for ⌘S "save in place".
    private var currentProjectURL: URL?

    private let timelinePanelHeight: CGFloat = 80

    // Height reserved for the scene HUD overlay in the top-left of the viewport.
    // Tall enough for ~8 objects in the list before it clips.
    private let overlayHeight: CGFloat = 270
    private let overlayWidth:  CGFloat = 230

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
        w.title = "ThreeDViewport"
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
            onAddCameraKeyframe: { [weak viewport] in
                viewport?.addCameraKeyframeAtCurrentTime()
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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK: - Menu

    private func setupMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(
            title: "Quit ThreeDViewport",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu

        // Open Model — replaces entire scene (⌘O)
        let openModelItem = NSMenuItem(
            title: "Open Model...",
            action: #selector(openModel(_:)),
            keyEquivalent: "o"
        )
        openModelItem.target = self
        fileMenu.addItem(openModelItem)

        // Add Model to Scene — appends without clearing (⌘⇧O)
        let addModelItem = NSMenuItem(
            title: "Add Model to Scene...",
            action: #selector(addModelToScene(_:)),
            keyEquivalent: "O"   // uppercase letter → ⌘⇧O
        )
        addModelItem.target = self
        fileMenu.addItem(addModelItem)

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

        // ── View menu — rendering toggles only ───────────────────────────────
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu

        // Greyscale Mode — checkmark driven by validateMenuItem
        let greyItem = NSMenuItem(
            title: "Greyscale Mode",
            action: #selector(toggleColorMode(_:)),
            keyEquivalent: "t"
        )
        greyItem.target = self
        viewMenu.addItem(greyItem)

        // Wireframe — keyboard shortcut G; checkmark driven by validateMenuItem
        let wireItem = NSMenuItem(
            title: "Wireframe",
            action: #selector(toggleWireframe(_:)),
            keyEquivalent: ""
        )
        wireItem.target = self
        viewMenu.addItem(wireItem)

        // ── Window menu — panels + macOS-standard items ────────────────────────
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu

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
        currentProjectURL = nil
        window?.title = "ThreeDViewport"
        print("[DEBUG] AppDelegate: new project")
    }

    // MARK: - Open Model (replaces scene)

    @objc private func openModel(_ sender: Any) {
        guard let window = window else {
            print("[DEBUG] AppDelegate: openModel — window is nil")
            return
        }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories    = false
        panel.canChooseFiles          = true
        panel.title = "Open Model (replaces scene)"

        if let glbType = UTType(filenameExtension: "glb") {
            panel.allowedContentTypes = [glbType]
        } else {
            print("[DEBUG] AppDelegate: UTType for glb not found, showing all files")
        }

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else {
                print("[DEBUG] AppDelegate: open panel cancelled or url is nil")
                return
            }
            print("[DEBUG] AppDelegate: openModel — " + url.lastPathComponent)
            self?.viewportView?.loadModel(url: url)
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
        panel.title = "Add Model to Scene"

        if let glbType = UTType(filenameExtension: "glb") {
            panel.allowedContentTypes = [glbType]
        }

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else {
                print("[DEBUG] AppDelegate: add-model panel cancelled")
                return
            }
            print("[DEBUG] AppDelegate: addModelToScene — " + url.lastPathComponent)
            self?.viewportView?.addModelToScene(url: url)
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

        if let projType = UTType(filenameExtension: "3dvp") {
            panel.allowedContentTypes = [projType]
        }

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.loadProject(from: url)
        }
    }

    private func loadProject(from url: URL) {
        guard let viewport = viewportView else { return }
        do {
            try ProjectFile.load(from: url, into: viewport)
            currentProjectURL = url
            window?.title = "ThreeDViewport — " + url.deletingPathExtension().lastPathComponent
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
                try ProjectFile.save(to: url, viewport: viewport)
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
        panel.nameFieldStringValue = "project.3dvp"
        panel.canCreateDirectories = true

        // Suggest the first loaded model's name as a project name default.
        if let firstURL = viewport.sceneManager.objects.first?.sourceURL {
            panel.nameFieldStringValue = firstURL.deletingPathExtension().lastPathComponent + ".3dvp"
        }

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            guard let self = self else { return }
            do {
                try ProjectFile.save(to: url, viewport: viewport)
                self.currentProjectURL = url
                self.window?.title = "ThreeDViewport — "
                    + url.deletingPathExtension().lastPathComponent
                print("[DEBUG] AppDelegate: project saved as " + url.lastPathComponent)
            } catch {
                self.showErrorAlert(message: "Could not save project",
                                    detail: error.localizedDescription)
            }
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
        print("[DEBUG] AppDelegate: wireframe toggled to "
            + String(viewportView?.renderer?.isWireframe ?? false))
    }

    // Keep menu item checkmarks in sync with current rendering state.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleColorMode(_:)) {
            // Checkmark when greyscale is active (isColorMode == false).
            let isGreyscale = !(viewportView?.renderSettings.isColorMode ?? true)
            menuItem.state = isGreyscale ? .on : .off
        }
        if menuItem.action == #selector(toggleWireframe(_:)) {
            let isWireframe = viewportView?.renderer?.isWireframe ?? false
            menuItem.state = isWireframe ? .on : .off
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
            styleMask:   [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
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
            renderSettings:   viewport.renderSettings
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
            styleMask:   [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
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
        wc.editorView.onInsertObjectKeyframe = { [weak viewport] index in
            viewport?.addKeyframeAtCurrentTime(forObjectAt: index)
        }
        wc.editorView.onInsertCameraKeyframe = { [weak viewport] in
            viewport?.addCameraKeyframeAtCurrentTime()
        }
        wc.editorView.onInsertLightKeyframe = { [weak viewport] index in
            viewport?.addLightKeyframeAtCurrentTime(forLightAt: index)
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
                let c = viewport.camera
                if let track = c.keyframeTrack,
                   let state = track.evaluate(at: kfTime) {
                    self.kfEditSnapshot = .camera(
                        yaw:      state.yaw,
                        pitch:    state.pitch,
                        distance: state.distance,
                        target:   state.target,
                        kfTime:   kfTime
                    )
                } else {
                    // Fallback: save the current live state.
                    self.kfEditSnapshot = .camera(
                        yaw:      c.yaw,
                        pitch:    c.pitch,
                        distance: c.distance,
                        target:   c.target,
                        kfTime:   kfTime
                    )
                }
                viewport.setControlMode(.camera)
                print("[DEBUG] AppDelegate: entered camera keyframe edit at t="
                    + String(format: "%.3f", kfTime))

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

            case .camera(_, _, _, _, let kfTime):
                viewport.timeline.seek(to: kfTime)
                viewport.addCameraKeyframeAtCurrentTime()
                print("[DEBUG] AppDelegate: committed camera keyframe edit"
                    + " t=" + String(format: "%.3f", kfTime))

            case .light(let index, _, _, _, _, let kfTime):
                viewport.timeline.seek(to: kfTime)
                viewport.addLightKeyframeAtCurrentTime(forLightAt: index)
                print("[DEBUG] AppDelegate: committed light keyframe edit index=\(index)"
                    + " t=" + String(format: "%.3f", kfTime))
            }

            self.kfEditSnapshot = nil
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

            case .camera(let yaw, let pitch, let distance, let target, let kfTime):
                let c      = viewport.camera
                c.yaw      = yaw
                c.pitch    = pitch
                c.distance = distance
                c.target   = target
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
            }

            self.kfEditSnapshot = nil
        }

        // Wire viewport Return key → commit any active keyframe edit.
        viewport.onEnterKey = { [weak wc] in
            wc?.editorView.commitEditIfActive()
        }

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
            alert.informativeText = "Open a .glb model before exporting."
            alert.alertStyle      = .warning
            alert.beginSheetModal(for: window)
            return
        }

        let (accessory, codecPopup) = makeCodecAccessoryView()

        let panel = NSSavePanel()
        panel.title                = "Export ProRes Video"
        panel.nameFieldStringValue = "animation.mov"
        panel.canCreateDirectories = true
        panel.accessoryView        = accessory

        if let movType = UTType(filenameExtension: "mov") {
            panel.allowedContentTypes = [movType]
        }

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else {
                print("[DEBUG] AppDelegate: export panel cancelled")
                return
            }
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
        popup.selectItem(at: 0)
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
}
