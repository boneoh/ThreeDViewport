import AppKit

/// NSPanel subclass that forwards unhandled key-downs to a designated view
/// (typically the Metal viewport).  Lets inspector panels stay key while still
/// letting C / O / L / M and other viewport shortcuts work without first
/// re-focusing the main window.
///
/// Keys consumed by the SwiftUI hierarchy (e.g. arrow keys on a focused
/// TunableSlider via `.onKeyPress`) are handled there first and never reach
/// `keyDown` — only the *unrecognized* ones get forwarded.
final class KeyForwardingPanel: NSPanel {
    weak var forwardTarget: NSView?

    override func keyDown(with event: NSEvent) {
        // Tab / Shift+Tab — move focus between controls within the panel itself
        // rather than forwarding to the viewport.  Without this, Tab in an
        // inspector ends up steering the viewport, which is never useful.
        if event.keyCode == 48 {   // 48 == kVK_Tab
            if event.modifierFlags.contains(.shift) {
                selectPreviousKeyView(nil)
            } else {
                selectNextKeyView(nil)
            }
            return
        }
        // Arrow keys belong to the focused control (e.g. a TunableSlider), not the
        // viewport.  SwiftUI's `.onKeyPress` consumes the initial key-down, but the
        // OS key-repeat events for held arrows are NOT delivered to it in this
        // NSPanel/NSHostingView setup — they fall through to here.  Forwarding those
        // to the viewport moved the selected model while a slider was being nudged,
        // so swallow all arrow keys instead of forwarding them.
        switch event.keyCode {
        case 123, 124, 125, 126:   // ←  →  ↓  ↑
            return
        default:
            break
        }
        if let target = forwardTarget {
            target.keyDown(with: event)
        } else {
            super.keyDown(with: event)
        }
    }
}
