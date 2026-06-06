import AppKit
import SwiftUI

// Floating panel hosting the SwiftUI EffectsGridPanel.  Opened via Window → Effects;
// can sit alongside the Timeline Editor.  Mirrors TimelineEditorWindowController's
// panel style (becomes key so it can take focus) but hosts SwiftUI rather than the
// custom timeline canvas — the grid is a plain table of checkboxes/menus.
final class EffectsGridWindowController: NSWindowController {

    let state: EffectsGridState

    init(state: EffectsGridState) {
        self.state = state

        let panelRect = NSRect(x: 0, y: 0, width: 500, height: 420)
        let hosting = NSHostingView(rootView: EffectsGridPanel(state: state))
        hosting.autoresizingMask = [.width, .height]

        let panel = NSPanel(
            contentRect: panelRect,
            styleMask:   [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing:     .buffered,
            defer:       false
        )
        panel.title                  = "Effects"
        panel.isFloatingPanel        = false
        panel.level                  = .normal
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate      = false
        panel.minSize                = NSSize(width: 380, height: 200)
        panel.contentView            = hosting

        super.init(window: panel)
        print("[DEBUG] EffectsGridWindowController: initialized")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        state.sync()
        print("[DEBUG] EffectsGridWindowController: panel shown")
    }
}
