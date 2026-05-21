import AppKit

// Floating panel that hosts the TimelineEditorView inside a vertical scroll view.
// Open via Window → Timeline Editor; can be closed independently.
// The panel is NOT a non-activating panel so it becomes key on click,
// allowing the editor view to receive keyboard input (Delete, Insert, arrows).
final class TimelineEditorWindowController: NSWindowController, NSWindowDelegate {

    private(set) var editorView: TimelineEditorView
    private let scrollView: NSScrollView
    /// Observes clip-view scrolling so the editor fully repaints — required for
    /// the floating ruler header to track the visible-area top.
    private var scrollObserver: NSObjectProtocol?

    // The panel content height is clamped to this maximum so the timeline
    // doesn't grow taller than the screen; content beyond this scrolls.
    private static let maxPanelContentH: CGFloat = 420

    // MARK: - Init

    init(timeline: Timeline, sceneManager: SceneManager,
         camera: CameraController, lightManager: LightManager) {

        let panelWidth: CGFloat = 1000

        // Count only unique group IDs + ungrouped objects for the initial height.
        // This ensures a 32-part model appears as 1 header row, not 32 rows.
        var seenGIDs = Set<Int>()
        var visibleObjectRows = 0
        for obj in sceneManager.objects {
            if let gid = obj.groupID {
                if seenGIDs.insert(gid).inserted { visibleObjectRows += 1 }
            } else {
                visibleObjectRows += 1
            }
        }
        let numTracks     = 1 + visibleObjectRows + lightManager.lights.count
        let contentH      = Self.contentHeight(for: numTracks)
        let panelContentH = min(contentH, Self.maxPanelContentH)

        // Document view: full content height so everything is reachable by scrolling.
        let docRect   = NSRect(x: 0, y: 0, width: panelWidth, height: contentH)
        let panelRect = NSRect(x: 0, y: 0, width: panelWidth, height: panelContentH)

        let editor = TimelineEditorView(frame: docRect)
        editor.timeline      = timeline
        editor.sceneManager  = sceneManager
        editor.camera        = camera
        editor.lightManager  = lightManager
        // Width follows the scroll view when the panel is resized horizontally.
        editor.autoresizingMask = [.width]
        editorView = editor

        let sv = NSScrollView(frame: panelRect)
        sv.hasVerticalScroller   = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers    = true
        sv.drawsBackground       = false
        sv.documentView          = editor
        sv.autoresizingMask      = [.width, .height]
        // Emit bounds-change notifications during scroll so we can force a full
        // editor repaint — required for the floating ruler header to re-anchor to
        // the top of the visible area (NSClipView only repaints the exposed strip).
        sv.contentView.postsBoundsChangedNotifications = true
        scrollView = sv

        let panel = NSPanel(
            contentRect: panelRect,
            styleMask:   [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing:     .buffered,
            defer:       false
        )
        panel.title                  = "Timeline Editor"
        panel.isFloatingPanel        = true
        panel.becomesKeyOnlyIfNeeded = false   // must become key so arrow/delete/insert work
        panel.hidesOnDeactivate      = false
        panel.minSize                = NSSize(width: 520, height: 80)
        panel.contentView            = sv

        super.init(window: panel)
        panel.delegate = self

        // Keep document view height and panel size in sync whenever the user
        // expands or collapses a group in the timeline.
        editor.onLayoutChanged = { [weak self] in self?.updateWindowHeight() }

        // Redraw the editor as the lanes scroll so the floating ruler header
        // re-anchors to the top of the visible area.
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object:  sv.contentView,
            queue:   .main
        ) { [weak editor] _ in editor?.needsDisplay = true }

        print("[DEBUG] TimelineEditorWindowController: initialized")
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let obs = scrollObserver { NotificationCenter.default.removeObserver(obs) }
    }

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

    // MARK: - Resize

    /// Recalculates the required content height from the current visible track count
    /// (accounts for collapsed/expanded groups) and updates:
    ///   • the document view height so all rows are reachable by scrolling,
    ///   • the panel height up to maxPanelContentH (anchoring the top edge).
    func updateWindowHeight() {
        guard let panel = window else { return }

        let numTracks     = editorView.visibleTrackCount
        let newContentH   = Self.contentHeight(for: numTracks)

        // Update document view height.
        var docFrame = editorView.frame
        if abs(docFrame.height - newContentH) > 1 {
            docFrame.size.height = newContentH
            editorView.frame     = docFrame
        }

        // Resize panel up to maxPanelContentH, anchoring the top edge.
        // Never decrease the panel height — the user may have manually resized
        // the window taller and we don't want to undo that on collapse.
        let newPanelContentH = min(newContentH, Self.maxPanelContentH)
        let sampleRect  = NSRect(x: 0, y: 0, width: panel.frame.width, height: newPanelContentH)
        let newFrameH   = panel.frameRect(forContentRect: sampleRect).height
        let currentH    = panel.frame.height
        guard newFrameH > currentH + 1 else { return }   // grow only, never shrink

        var f  = panel.frame
        let dy = newFrameH - currentH
        f.origin.y    -= dy
        f.size.height += dy
        panel.setFrame(f, display: true)

        print("[DEBUG] TimelineEditorWindowController: resized — "
            + "tracks=\(numTracks) contentH=\(newContentH) panelH=\(newPanelContentH)")
    }

    // MARK: - Helpers

    private static func contentHeight(for numTracks: Int) -> CGFloat {
        let rulerHeight: CGFloat = 24
        let laneHeight:  CGFloat = 28
        return rulerHeight + CGFloat(max(3, numTracks)) * laneHeight
    }
}
