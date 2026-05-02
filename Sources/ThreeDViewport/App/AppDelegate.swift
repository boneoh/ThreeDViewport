import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {

    var window: NSWindow?
    var viewportView: ViewportView?
    let exportState = ExportState()

    // Tracks the last saved/opened project URL for ⌘S "save in place".
    private var currentProjectURL: URL?

    private let timelinePanelHeight: CGFloat = 80

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[DEBUG] AppDelegate: applicationDidFinishLaunching")

        let windowWidth:   CGFloat = 1920
        let viewportHeight: CGFloat = 1080                          // recordable Metal area
        let windowHeight:  CGFloat = viewportHeight + timelinePanelHeight

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

        // ── Assemble ──────────────────────────────────────────────────────────
        container.addSubview(viewport)
        container.addSubview(hostingView)
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

        let openModelItem = NSMenuItem(
            title: "Open Model...",
            action: #selector(openModel(_:)),
            keyEquivalent: "o"
        )
        openModelItem.target = self
        fileMenu.addItem(openModelItem)

        fileMenu.addItem(.separator())

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
            keyEquivalent: "S"     // ⌘⇧S
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

        NSApplication.shared.mainMenu = mainMenu
        print("[DEBUG] AppDelegate: menu setup complete")
    }

    // MARK: - Open Model

    @objc private func openModel(_ sender: Any) {
        guard let window = window else {
            print("[DEBUG] AppDelegate: openModel — window is nil")
            return
        }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories    = false
        panel.canChooseFiles          = true
        panel.title = "Select a .glb Model"

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
            print("[DEBUG] AppDelegate: user selected " + url.lastPathComponent)
            self?.viewportView?.loadModel(url: url)
        }
    }

    // MARK: - Open Project

    @objc private func openProject(_ sender: Any) {
        guard let window = window else { return }

        let panel = NSOpenPanel()
        panel.title                  = "Open Project"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories   = false
        panel.canChooseFiles         = true

        // .3dvp is a custom extension; UTType may not be registered system-wide,
        // but UTType(filenameExtension:) still creates a dynamic type we can pass.
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
            // Save in place
            guard let viewport = viewportView else { return }
            do {
                try ProjectFile.save(to: url, viewport: viewport)
                print("[DEBUG] AppDelegate: project saved to " + url.lastPathComponent)
            } catch {
                showErrorAlert(message: "Could not save project", detail: error.localizedDescription)
            }
        } else {
            // No current URL — show the save-as panel
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

        // Suggest the model filename as the project name if one is loaded
        if let modelURL = viewport.currentModelURL {
            let stem = modelURL.deletingPathExtension().lastPathComponent
            panel.nameFieldStringValue = stem + ".3dvp"
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

        // ── Codec picker accessory view ───────────────────────────────────────
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

    // Builds the NSView that appears as the accessory in the NSSavePanel.
    // Returns the container view and a reference to the popup for reading the selection.
    private func makeCodecAccessoryView() -> (view: NSView, popup: NSPopUpButton) {
        let label = NSTextField(labelWithString: "Format:")
        label.font        = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.alignment   = .right
        label.isEditable  = false
        label.isBezeled   = false
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

        // Give the stack a fixed height so the panel lays it out correctly
        stack.frame = NSRect(x: 0, y: 0, width: 420, height: 44)

        print("[DEBUG] AppDelegate: codec accessory view created")
        return (stack, popup)
    }
}
