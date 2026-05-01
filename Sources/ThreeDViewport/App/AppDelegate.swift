import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {

    var window: NSWindow?
    var viewportView: ViewportView?

    // Heights of the two zones
    private let timelinePanelHeight: CGFloat = 80

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[DEBUG] AppDelegate: applicationDidFinishLaunching")

        let windowWidth:  CGFloat = 1920
        let viewportHeight: CGFloat = 1080                          // recordable Metal area
        let windowHeight: CGFloat = viewportHeight + timelinePanelHeight
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

        // ── Container view (fills the window) ────────────────────────────────
        let container = NSView(frame: rect)
        container.autoresizingMask = [.width, .height]

        // ── ViewportView (top zone, exactly 1920×1080 — the recordable area) ──
        let viewportFrame  = NSRect(x: 0,
                                    y: timelinePanelHeight,
                                    width: windowWidth,
                                    height: viewportHeight)
        let viewport = ViewportView(frame: viewportFrame)
        viewport.autoresizingMask = [.width, .height]
        viewportView = viewport

        if viewport.device == nil {
            print("[DEBUG] AppDelegate: ViewportView MTLDevice is nil — Metal not available on this machine")
        }

        // ── Timeline panel (bottom zone, fixed height) ────────────────────────
        let panelFrame = NSRect(x: 0,
                                y: 0,
                                width: windowWidth,
                                height: timelinePanelHeight)

        let timelineView = TimelinePanel(
            timeline: viewport.timeline,
            onAddKeyframe: { [weak viewport] in
                viewport?.addKeyframeAtCurrentTime()
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

        print("[DEBUG] AppDelegate: window created at "
            + String(Int(windowWidth)) + "x" + String(Int(windowHeight))
            + " viewport=" + String(Int(windowWidth)) + "x" + String(Int(viewportHeight))
            + " timeline=" + String(Int(windowWidth)) + "x" + String(Int(timelinePanelHeight)))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK: - Menu

    private func setupMenu() {
        let mainMenu = NSMenu()

        // App menu (macOS requires first item to be the app menu)
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(
            title: "Quit ThreeDViewport",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        // File menu
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

        NSApplication.shared.mainMenu = mainMenu
        print("[DEBUG] AppDelegate: menu setup complete")
    }

    @objc private func openModel(_ sender: Any) {
        guard let window = window else {
            print("[DEBUG] AppDelegate: openModel called but window is nil")
            return
        }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories    = false
        panel.canChooseFiles          = true
        panel.title = "Select a .glb Model"

        // Attempt to restrict to .glb; UTType may not be registered on all systems
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
}
