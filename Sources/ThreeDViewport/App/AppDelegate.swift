import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {

    var window: NSWindow?
    var viewportView: ViewportView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[DEBUG] AppDelegate: applicationDidFinishLaunching")

        let rect = NSRect(x: 0, y: 0, width: 1920, height: 1080)

        let w = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window = w

        w.title = "ThreeDViewport"
        w.center()

        let viewport = ViewportView(frame: rect)
        viewportView = viewport

        if viewport.device == nil {
            print("[DEBUG] AppDelegate: ViewportView MTLDevice is nil - Metal not available on this machine")
        }

        w.contentView = viewport
        w.makeKeyAndOrderFront(nil)

        setupMenu()

        print("[DEBUG] AppDelegate: window created at 1280x720")
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
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
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
