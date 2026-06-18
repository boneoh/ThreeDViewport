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

    // ── POV positioning sliders ────────────────────────────────────────────────
    // Camera-around-the-head sphere coordinates.  Dragging any of these in the
    // panel fires `onPOVLivePreview`, which moves the camera in the viewport so
    // the user can frame the shot.  Hitting the POV stamp button captures the
    // current configuration as a follow keyframe with `followUpLocal = (0,1,0)`.
    /// Sphere radius — distance from the followed object's bounding centre.
    @Published var povDistance:  Float = 1.0
    /// Rotation around the object's local +Y axis, in degrees.
    /// 0° = directly behind, ±180° = in front of the face, +90° = right, −90° = left.
    @Published var povAzimuth:   Float = 0
    /// Elevation above/below the object's local equator, in degrees.
    /// 0° = head height, +90° = directly above, −90° = below.
    @Published var povElevation: Float = 15
    /// True when the camera track is locked (Timeline padlock) — disables the panel's
    /// editing controls.
    @Published var isLocked: Bool = false

    // ── Cameras (Phase 1b) ──────────────────────────────────────────────────────
    /// Names of all scene cameras + which is active, mirrored from the ViewportView.
    @Published var cameraNames:       [String] = ["Camera 1"]
    @Published var activeCameraIndex: Int      = 0
    /// Management callbacks (wired by ViewportView): pick active / add / delete /
    /// set the active camera to the Director free-view's framing.
    var onSelectCamera:    ((Int) -> Void)?
    var onAddCamera:       (() -> Void)?
    var onDeleteCamera:    (() -> Void)?
    var onCaptureDirector: (() -> Void)?

    /// Propagate Position / Target / FOV edits back to the active camera (wired by ViewportView).
    var onPositionEdited:    ((SIMD3<Float>) -> Void)?
    var onTargetEdited:      ((SIMD3<Float>) -> Void)?
    var onFocalLengthEdited: ((Float) -> Void)?
    /// Live preview for the POV sliders — repositions the camera on the sphere
    /// each time `povDistance` / `povAzimuth` / `povElevation` changes.  Arguments
    /// are (target object name, distance, azimuth deg, elevation deg).
    var onPOVLivePreview: ((String, Float, Float, Float) -> Void)?
    /// Stamps a POV-flavoured follow keyframe at the current playhead.
    var onPOVStamp:       ((String, Float, Float, Float) -> Void)?
    /// Fires after a Paste or Z click on Position / Target.  AppDelegate wires it
    /// to conditionally stamp a camera keyframe at the current playhead (only
    /// when the camera track already has keyframes).
    var onAutoStamp:         (() -> Void)?
    /// Fires when a keyframeable camera slider edit ends → auto-keyframe-on-edit.
    var onSliderEdited:      (() -> Void)?

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

        // POV sliders → live preview.  All three fire the same callback so any
        // slider drag re-positions the camera on the sphere immediately.
        $povDistance.dropFirst()
            .sink { [weak self] _ in self?.firePOVLivePreview() }
            .store(in: &cancellables)
        $povAzimuth.dropFirst()
            .sink { [weak self] _ in self?.firePOVLivePreview() }
            .store(in: &cancellables)
        $povElevation.dropFirst()
            .sink { [weak self] _ in self?.firePOVLivePreview() }
            .store(in: &cancellables)
    }

    private func firePOVLivePreview() {
        guard !isUpdating, let name = followTargetName else { return }
        onPOVLivePreview?(name, povDistance, povAzimuth, povElevation)
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

                // ── Cameras (select active / add / delete / capture) ──────────
                HStack(spacing: 6) {
                    Picker("", selection: Binding(
                        get: { min(state.activeCameraIndex, max(0, state.cameraNames.count - 1)) },
                        set: { state.onSelectCamera?($0) })) {
                        ForEach(Array(state.cameraNames.enumerated()), id: \.offset) { idx, name in
                            Text(name).tag(idx)
                        }
                    }
                    .labelsHidden()
                    Button { state.onAddCamera?() } label: { Image(systemName: "plus") }
                        .help("Add a camera (starts from the current view)")
                    Button { state.onDeleteCamera?() } label: { Image(systemName: "minus") }
                        .help("Delete the selected camera")
                        .disabled(state.cameraNames.count <= 1)
                }
                .padding(.bottom, 6)
                Button { state.onCaptureDirector?() } label: {
                    Label("Set to Director View", systemImage: "scope")
                }
                .help("Aim this camera at the Director free-view's current framing")
                .padding(.bottom, 12)

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

                // ── Follow POV (sphere positioner) ────────────────────────────
                // Sliders move the camera around a sphere centred on the
                // followed object's bounding centre.  Disabled when the picker
                // is on "None — Free Camera" because there's no anchor to
                // orbit.  The POV stamp button records a follow keyframe that
                // rolls with the head (followUpLocal = local +Y).
                let povEnabled = state.followTargetName != nil
                Text("Follow POV").font(.headline).padding(.bottom, 4)
                SliderRow(label: "Distance",  value: $state.povDistance,
                          range: SceneLimits.povDistanceRange,  format: "%.2f")
                SliderRow(label: "Azimuth",   value: $state.povAzimuth,
                          range: SceneLimits.povAzimuthRange,   format: "%.1f")
                SliderRow(label: "Elevation", value: $state.povElevation,
                          range: SceneLimits.povElevationRange, format: "%.1f")
                Button(action: {
                    guard let name = state.followTargetName else { return }
                    state.onPOVStamp?(name, state.povDistance,
                                      state.povAzimuth, state.povElevation)
                }) {
                    Label("Add Follow POV Keyframe", systemImage: "diamond.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(!povEnabled)
                .padding(.top, 6)
                Text(povEnabled
                     ? "Sliders position the camera around '\(state.followTargetName ?? "")' — rolls with it on playback."
                     : "Pick a Follow Target above to enable POV positioning.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)

                Divider().padding(.vertical, 14)

                // ── Position (editable) ───────────────────────────────────────
                HStack {
                    Text("Position").font(.headline)
                    Spacer()
                    CoordCopyPasteButtons(
                        onCopy:   { clipboard.position = state.position },
                        onPaste:  { if let p = clipboard.position { state.position = p } },
                        canPaste: clipboard.position != nil && !state.isLocked,
                        onZero:   { state.position = .zero },
                        canZero:  !state.isLocked,
                        onAutoStamp: { state.onAutoStamp?() })
                }
                .padding(.bottom, 4)
                SliderRow(label: "X", value: $state.position.x, range: SceneLimits.positionRange, format: "%.2f",
                          onEditEnded: { state.onSliderEdited?() })
                SliderRow(label: "Y", value: $state.position.y, range: SceneLimits.positionRange, format: "%.2f",
                          onEditEnded: { state.onSliderEdited?() })
                SliderRow(label: "Z", value: $state.position.z, range: SceneLimits.positionRange, format: "%.2f",
                          onEditEnded: { state.onSliderEdited?() })

                Divider().padding(.vertical, 14)

                // ── Target (editable) ─────────────────────────────────────────
                HStack {
                    Text("Target").font(.headline)
                    Spacer()
                    CoordCopyPasteButtons(
                        onCopy:   { clipboard.position = state.target },
                        onPaste:  { if let p = clipboard.position { state.target = p } },
                        canPaste: clipboard.position != nil && !state.isLocked,
                        onZero:   { state.target = .zero },
                        canZero:  !state.isLocked,
                        onAutoStamp: { state.onAutoStamp?() })
                }
                .padding(.bottom, 4)
                SliderRow(label: "X", value: $state.target.x, range: SceneLimits.positionRange, format: "%.2f",
                          onEditEnded: { state.onSliderEdited?() })
                SliderRow(label: "Y", value: $state.target.y, range: SceneLimits.positionRange, format: "%.2f",
                          onEditEnded: { state.onSliderEdited?() })
                SliderRow(label: "Z", value: $state.target.z, range: SceneLimits.positionRange, format: "%.2f",
                          onEditEnded: { state.onSliderEdited?() })

                Divider().padding(.vertical, 14)

                // ── Focal Length (35mm-full-frame equivalent) ────────────────
                Text("Focal Length").font(.headline)
                    .padding(.bottom, 4)
                SliderRow(label: "mm", value: $state.focalLength,
                          range: SceneLimits.focalLengthRange, format: "%.1f",
                          onEditEnded: { state.onSliderEdited?() })
            }
            .padding(14)
            // Editing controls freeze when the camera track is locked.  Applied to the
            // inner VStack (not the ScrollView) so the panel still scrolls.
            .disabled(state.isLocked)
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
