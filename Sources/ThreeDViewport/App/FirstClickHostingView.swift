import AppKit
import SwiftUI

/// `NSHostingView` that processes the click that brings its window to key.
///
/// Without this, an inactive NSPanel needs **two clicks** to interact with: the
/// first activates the window (consumed), the second reaches the SwiftUI content.
/// Inspector panels use this subclass so a single click both focuses the panel
/// and registers as a tap (e.g. selecting a different light in the Lights list).
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
