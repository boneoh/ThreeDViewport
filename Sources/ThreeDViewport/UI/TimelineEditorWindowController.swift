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
    /// Height of the bottom footer bar that holds the zoom controls.
    private static let footerHeight: CGFloat = 34

    // MARK: - Init

    init(timeline: Timeline, sceneManager: SceneManager,
         camera: CameraController, lightManager: LightManager,
         fogSettings: FogSettings, particleManager: ParticleManager,
         coordinateClipboard: CoordinateClipboard) {

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
        // Camera + Fog are always shown (+2); plus one lane per particle emitter.
        let numTracks     = 2 + particleManager.emitters.count + visibleObjectRows + lightManager.lights.count
        let contentH      = Self.contentHeight(for: numTracks)
        let scrollH       = min(contentH, Self.maxPanelContentH)
        let panelContentH = scrollH + Self.footerHeight

        // Document view: full content height so everything is reachable by scrolling.
        let docRect   = NSRect(x: 0, y: 0, width: panelWidth, height: contentH)
        let panelRect = NSRect(x: 0, y: 0, width: panelWidth, height: panelContentH)

        let editor = TimelineEditorView(frame: docRect)
        editor.timeline       = timeline
        editor.sceneManager   = sceneManager
        editor.camera         = camera
        editor.lightManager   = lightManager
        editor.fogSettings         = fogSettings
        editor.particleManager     = particleManager
        editor.coordinateClipboard = coordinateClipboard
        // The document width is driven by the zoom level (updateDocumentWidth), not
        // by autoresizing — so it can be wider than the viewport and scroll.
        editor.autoresizingMask = []
        editorView = editor

        // Scroll view fills the area above the footer.
        let svRect = NSRect(x: 0, y: Self.footerHeight,
                            width: panelWidth, height: scrollH)
        let sv = NSScrollView(frame: svRect)
        sv.hasVerticalScroller   = true
        sv.hasHorizontalScroller = true
        sv.autohidesScrollers    = true
        sv.drawsBackground       = false
        sv.documentView          = editor
        sv.autoresizingMask      = [.width, .height]
        // Emit bounds-change notifications during scroll so we can force a full
        // editor repaint — required for the floating ruler header to re-anchor to
        // the top of the visible area (NSClipView only repaints the exposed strip).
        sv.contentView.postsBoundsChangedNotifications = true
        scrollView = sv

        super.init(window: NSPanel(
            contentRect: panelRect,
            styleMask:   [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing:     .buffered,
            defer:       false
        ))

        let footer = makeFooter(width: panelWidth)

        let container = NSView(frame: panelRect)
        container.autoresizesSubviews = true
        container.addSubview(sv)
        container.addSubview(footer)

        guard let panel = window as? NSPanel else { fatalError() }
        panel.title                  = "Timeline Editor"
        // Normal window level (not floating) so other applications can come on top
        // when they receive focus, instead of the editor always staying above them.
        panel.isFloatingPanel        = false
        panel.level                  = .normal
        panel.becomesKeyOnlyIfNeeded = false   // must become key so arrow/delete/insert work
        panel.hidesOnDeactivate      = false
        panel.minSize                = NSSize(width: 520, height: 80 + Self.footerHeight)
        panel.contentView            = container
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
        ) { [weak editor] _ in
            // On resize the viewport width changes → recompute the fit/zoom document
            // width; on scroll it's a no-op.  Always repaint for the floating header.
            editor?.updateDocumentWidth()
            editor?.needsDisplay = true
        }

        print("[DEBUG] TimelineEditorWindowController: initialized")
    }

    // MARK: - Zoom actions (footer buttons)

    @objc private func zoomFitAction() { editorView.zoomToFit() }
    @objc private func zoomOutAction() { editorView.zoomOut() }
    @objc private func zoomInAction()  { editorView.zoomIn() }
    @objc private func zoomMaxAction() { editorView.zoomToMax() }

    // MARK: - In / Out actions (footer buttons)

    @objc private func setInAction() {
        let tl = editorView.timeline
        tl?.setIn(at: tl?.currentTime ?? 0)
        editorView.needsDisplay = true
        NSApp.sendAction(#selector(AppDelegate.markDirtyFromUI), to: nil, from: self)
    }

    @objc private func setOutAction() {
        let tl = editorView.timeline
        tl?.setOut(at: tl?.currentTime ?? 0)
        editorView.needsDisplay = true
        NSApp.sendAction(#selector(AppDelegate.markDirtyFromUI), to: nil, from: self)
    }

    @objc private func clearInOutAction() {
        editorView.timeline?.clearInOut()
        editorView.needsDisplay = true
        NSApp.sendAction(#selector(AppDelegate.markDirtyFromUI), to: nil, from: self)
    }

    @objc private func toggleLoopInOutAction(_ sender: NSButton) {
        editorView.timeline?.loopInOut = (sender.state == .on)
        NSApp.sendAction(#selector(AppDelegate.markDirtyFromUI), to: nil, from: self)
    }

    /// Syncs the footer Loop In/Out toggle to the timeline (e.g. after the menu
    /// item toggles it).  Called by the AppDelegate menu handler.
    func refreshLoopInOutButton() {
        loopInOutButton?.state = (editorView.timeline?.loopInOut ?? false) ? .on : .off
    }

    /// The footer Loop In/Out toggle, kept so the menu item can sync it.
    private weak var loopInOutButton: NSButton?

    /// Builds the bottom footer bar with the zoom + In/Out controls.
    private func makeFooter(width: CGFloat) -> NSView {
        let footer = NSView(frame: NSRect(x: 0, y: 0, width: width, height: Self.footerHeight))
        footer.autoresizingMask = [.width]
        footer.wantsLayer = true
        footer.layer?.backgroundColor = NSColor(white: 0.20, alpha: 1).cgColor
        // Render the buttons/label in dark mode so they don't disappear into the
        // dark footer (matches the easing dropdowns, which also force darkAqua).
        footer.appearance = NSAppearance(named: .darkAqua)

        func button(_ title: String, _ sel: Selector, _ tip: String) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.bezelStyle  = .rounded
            b.controlSize = .small
            b.font        = NSFont.systemFont(ofSize: 11)
            b.toolTip     = tip
            return b
        }

        let zoomLabel = NSTextField(labelWithString: "Zoom")
        zoomLabel.font      = NSFont.systemFont(ofSize: 11)
        zoomLabel.textColor = NSColor(white: 0.70, alpha: 1)

        let inOutLabel = NSTextField(labelWithString: "In/Out")
        inOutLabel.font      = NSFont.systemFont(ofSize: 11)
        inOutLabel.textColor = NSColor(white: 0.70, alpha: 1)

        let loopToggle = NSButton(checkboxWithTitle: "Loop In/Out",
                                  target: self,
                                  action: #selector(toggleLoopInOutAction(_:)))
        loopToggle.controlSize = .small
        loopToggle.font        = NSFont.systemFont(ofSize: 11)
        loopToggle.toolTip     = "Confine playback to the In…Out range"
        loopToggle.state       = (editorView.timeline?.loopInOut ?? false) ? .on : .off
        loopInOutButton = loopToggle

        let stack = NSStackView(views: [
            zoomLabel,
            button("Fit", #selector(zoomFitAction), "Fit the entire timeline"),
            button("+",        #selector(zoomInAction),  "Zoom in"),
            button("\u{2013}", #selector(zoomOutAction), "Zoom out"),
            button("1 s",      #selector(zoomMaxAction), "Zoom in to about one second"),
            NSBox.footerSeparator(),
            inOutLabel,
            button("Set In",  #selector(setInAction),     "Set the In point at the playhead"),
            button("Set Out", #selector(setOutAction),    "Set the Out point at the playhead"),
            button("Clear",   #selector(clearInOutAction), "Clear the In and Out points"),
            loopToggle
        ])
        stack.orientation = .horizontal
        stack.spacing     = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 10),
            stack.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])

        let divider = NSBox(frame: NSRect(x: 0, y: Self.footerHeight - 1, width: width, height: 1))
        divider.boxType          = .separator
        divider.autoresizingMask = [.width]
        footer.addSubview(divider)
        return footer
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
        // Now that the view is in the window, size the document to the viewport.
        DispatchQueue.main.async { [weak self] in self?.editorView.updateDocumentWidth() }
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

        // Keep the document width in step with the (possibly new) duration.
        editorView.updateDocumentWidth()

        // Resize panel up to maxPanelContentH (+ footer), anchoring the top edge.
        // Never decrease the panel height — the user may have manually resized
        // the window taller and we don't want to undo that on collapse.
        let newPanelContentH = min(newContentH, Self.maxPanelContentH) + Self.footerHeight
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

private extension NSBox {
    /// A short vertical separator for grouping controls in the footer stack.
    static func footerSeparator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return b
    }
}
