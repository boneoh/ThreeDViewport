import SwiftUI

// Floating inspector panel for camera keyframe stamping.
//
// Decouples the follow-target choice from scene selection: pick the target
// once in the picker (sticky across stamps and panel hide/show), then click
// "Add Camera Keyframe" as many times as you want.  Picking the top option
// ("None — Free Camera") stamps a free camera keyframe instead.

/// Observable state for the Camera panel.  Held on the ViewportView so the
/// picker remembers its choice across panel hide/show cycles.
final class CameraPanelState: ObservableObject {
    /// nil = free camera; otherwise the name of the SceneObject to follow.
    @Published var followTargetName: String? = nil
    /// Snapshot of available object names — refreshed by AppDelegate each time
    /// the panel is shown.  Reactively drives the picker contents.
    @Published var availableObjectNames: [String] = []
}

struct CameraPanel: View {

    @ObservedObject var state: CameraPanelState
    /// Invoked when the user clicks the stamp button.  ViewportView dispatches
    /// to the free or follow path based on `state.followTargetName`.
    let onStampKeyframe: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // ── Header ────────────────────────────────────────────────────
                HStack {
                    Image(systemName: "camera.fill")
                        .foregroundColor(.accentColor)
                    Text("Camera")
                        .font(.headline)
                    Spacer()
                }
                .padding(.bottom, 10)

                Divider().padding(.bottom, 14)

                // ── Follow target picker ──────────────────────────────────────
                Text("Follow Target")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 4)

                Picker("", selection: $state.followTargetName) {
                    Text("None — Free Camera").tag(String?.none)
                    ForEach(state.availableObjectNames, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider().padding(.vertical, 14)

                // ── Stamp button ──────────────────────────────────────────────
                // .bordered (not .borderedProminent) so the button remains
                // visible while the panel is not the key window — prominent
                // buttons derive their fill from the window tint, which goes
                // transparent on non-key floating panels.
                Button(action: onStampKeyframe) {
                    Label(stampButtonLabel, systemImage: "diamond.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                // ── Status hint ───────────────────────────────────────────────
                Text(stampHint)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
            }
            .padding(14)
        }
        .frame(width: 280)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var stampButtonLabel: String {
        state.followTargetName == nil
            ? "Add Free Camera Keyframe"
            : "Add Follow Camera Keyframe"
    }

    private var stampHint: String {
        if let name = state.followTargetName {
            return "Stamps a keyframe that follows '\(name)' at the current playhead."
        } else {
            return "Stamps a free camera keyframe at the current playhead."
        }
    }
}
