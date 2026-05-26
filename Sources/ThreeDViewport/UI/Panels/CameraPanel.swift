import SwiftUI
import Combine
import simd

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

    /// Camera world position (eye), editable — writes back via `onPositionEdited`.
    @Published var position: SIMD3<Float> = .zero
    /// Camera look-at target in world space (editable).
    @Published var target:   SIMD3<Float> = .zero
    /// 35mm-full-frame equivalent focal length (mm).  Derived from fovYRadians via
    /// `fl = 12 / tan(fovY/2)`; editing writes back through `onFocalLengthEdited`.
    @Published var focalLength: Float    = 50

    /// Propagate Position / Target / FOV edits back to the active camera (wired by ViewportView).
    var onPositionEdited:    ((SIMD3<Float>) -> Void)?
    var onTargetEdited:      ((SIMD3<Float>) -> Void)?
    var onFocalLengthEdited: ((Float) -> Void)?
    /// Fires after a Paste or Z click on Position / Target.  AppDelegate wires it
    /// to conditionally stamp a camera keyframe at the current playhead (only
    /// when the camera track already has keyframes).
    var onAutoStamp:         (() -> Void)?

    private var isUpdating   = false
    private var cancellables = Set<AnyCancellable>()

    init() { setupSinks() }

    /// Pulls live camera position/target in, suppressing the write-back sink and
    /// skipping no-op updates so it can run on a timer without fighting edits.
    func refresh(position newPosition: SIMD3<Float>,
                 target   newTarget:   SIMD3<Float>,
                 focalLength newFocalLength: Float) {
        isUpdating = true
        defer { isUpdating = false }
        if newPosition != position { position = newPosition }
        if newTarget   != target   { target   = newTarget }
        if abs(newFocalLength - focalLength) > 1e-3 { focalLength = newFocalLength }
    }

    private func setupSinks() {
        $position.dropFirst()
            .sink { [weak self] v in
                guard let self, !isUpdating else { return }
                onPositionEdited?(v)
            }.store(in: &cancellables)
        $target.dropFirst()
            .sink { [weak self] v in
                guard let self, !isUpdating else { return }
                onTargetEdited?(v)
            }.store(in: &cancellables)
        $focalLength.dropFirst()
            .sink { [weak self] v in
                guard let self, !isUpdating else { return }
                onFocalLengthEdited?(v)
            }.store(in: &cancellables)
    }
}

struct CameraPanel: View {

    @ObservedObject var state: CameraPanelState
    @ObservedObject var clipboard: CoordinateClipboard
    /// Invoked when the user clicks the stamp button.  ViewportView dispatches
    /// to the free or follow path based on `state.followTargetName`.
    let onStampKeyframe: () -> Void
    /// Pulls live camera position/target into `state` — driven by a timer while
    /// the panel is visible so the fields track viewport orbit/pan/zoom.
    let onRefresh: () -> Void

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

                Divider().padding(.vertical, 14)

                // ── Position (editable) ───────────────────────────────────────
                HStack {
                    Text("Position").font(.headline)
                    Spacer()
                    CoordCopyPasteButtons(
                        onCopy:   { clipboard.position = state.position },
                        onPaste:  { if let p = clipboard.position { state.position = p } },
                        canPaste: clipboard.position != nil,
                        onZero:   { state.position = .zero },
                        canZero:  true,
                        onAutoStamp: { state.onAutoStamp?() })
                }
                .padding(.bottom, 4)
                SliderRow(label: "X", value: $state.position.x, range: -100...100, format: "%.2f")
                SliderRow(label: "Y", value: $state.position.y, range: -100...100, format: "%.2f")
                SliderRow(label: "Z", value: $state.position.z, range: -100...100, format: "%.2f")

                Divider().padding(.vertical, 14)

                // ── Target (editable) ─────────────────────────────────────────
                HStack {
                    Text("Target").font(.headline)
                    Spacer()
                    CoordCopyPasteButtons(
                        onCopy:   { clipboard.position = state.target },
                        onPaste:  { if let p = clipboard.position { state.target = p } },
                        canPaste: clipboard.position != nil,
                        onZero:   { state.target = .zero },
                        canZero:  true,
                        onAutoStamp: { state.onAutoStamp?() })
                }
                .padding(.bottom, 4)
                SliderRow(label: "X", value: $state.target.x, range: -100...100, format: "%.2f")
                SliderRow(label: "Y", value: $state.target.y, range: -100...100, format: "%.2f")
                SliderRow(label: "Z", value: $state.target.z, range: -100...100, format: "%.2f")

                Divider().padding(.vertical, 14)

                // ── Focal Length (35mm-full-frame equivalent) ────────────────
                Text("Focal Length").font(.headline)
                    .padding(.bottom, 4)
                SliderRow(label: "mm", value: $state.focalLength,
                          range: 12...140, format: "%.1f")
            }
            .padding(14)
        }
        .frame(width: 280)
        .background(Color(NSColor.windowBackgroundColor))
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            onRefresh()
        }
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
