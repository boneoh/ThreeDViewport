import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {

    var window: NSWindow?
    var viewportView: ViewportView?
    let exportState = ExportState()

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

        let openItem = NSMenuItem(
            title: "Open Model...",
            action: #selector(openModel(_:)),
            keyEquivalent: "o"
        )
        openItem.target = self
        fileMenu.addItem(openItem)

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
