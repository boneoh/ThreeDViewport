import SwiftUI

/// Small padlock toggle for inspector panels that are NOT Timeline tracks
/// (Probe / Feedback / Color Grade), so they have no per-row lock in the Timeline.
/// Yellow when locked, matching the Timeline row toggles.  The panel disables its
/// editing controls while locked; this button stays enabled so you can unlock.
struct PanelLockButton: View {
    @Binding var isLocked: Bool

    var body: some View {
        Button {
            isLocked.toggle()
        } label: {
            Image(systemName: isLocked ? "lock.fill" : "lock.open")
                .foregroundColor(isLocked ? .yellow : .secondary)
        }
        .buttonStyle(.plain)
        .help(isLocked ? "Unlock — allow edits" : "Lock — freeze edits")
    }
}
