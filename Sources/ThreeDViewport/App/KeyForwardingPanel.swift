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
        if let target = forwardTarget {
            target.keyDown(with: event)
        } else {
            super.keyDown(with: event)
        }
    }
}
