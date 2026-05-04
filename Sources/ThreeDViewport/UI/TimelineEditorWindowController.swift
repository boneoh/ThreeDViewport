import AppKit

// Floating panel that hosts the TimelineEditorView.
// Open via Window → Timeline Editor; can be closed independently.
// The panel is NOT a non-activating panel so it becomes key on click,
// allowing the editor view to receive keyboard input (Delete, Insert, arrows).
final class TimelineEditorWindowController: NSWindowController, NSWindowDelegate {

    private(set) var editorView: TimelineEditorView

    // MARK: - Init

    init(timeline: Timeline, sceneManager: SceneManager,
         camera: CameraController, lightManager: LightManager) {

        let numTracks     = 1 + sceneManager.objects.count + lightManager.lights.count
        let contentH      = Self.contentHeight(for: numTracks)
        let contentRect   = NSRect(x: 0, y: 0, width: 1000, height: contentH)

        let editor = TimelineEditorView(frame: contentRect)
        editor.timeline      = timeline
        editor.sceneManager  = sceneManager
        editor.camera        = camera
        editor.lightManager  = lightManager
        editorView = editor

        let panel = NSPanel(
            contentRect: contentRect,
            styleMask:   [.titled, .closable, .resizable, .utilityWindow],
            backing:     .buffered,
            defer:       false
        )
        panel.title                  = "Timeline Editor"
        panel.isFloatingPanel        = true
        panel.becomesKeyOnlyIfNeeded = false   // must become key so arrow/delete/insert work
        panel.hidesOnDeactivate      = false
        panel.minSize                = NSSize(width: 520, height: 60)
        panel.contentView            = editor

        super.init(window: panel)
        panel.delegate = self

        print("[DEBUG] TimelineEditorWindowController: initialized")
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Show

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        editorView.startRefreshTimer()
        print("[DEBUG] TimelineEditorWindowController: panel shown")
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        editorView.stopRefreshTimer()
        print("[DEBUG] TimelineEditorWindowController: panel closed")
    }

    // MARK: - Helpers

    private static func contentHeight(for numTracks: Int) -> CGFloat {
        let rulerHeight: CGFloat = 24
        let laneHeight:  CGFloat = 28
        return rulerHeight + CGFloat(max(3, numTracks)) * laneHeight
    }
}
