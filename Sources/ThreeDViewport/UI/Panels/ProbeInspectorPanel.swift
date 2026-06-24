import SwiftUI
import simd

/// One selectable scene item (object / camera / light / effect) in the mark editor.
struct ProbeInstanceOption: Identifiable, Hashable {
    let id: UUID        // owning entity id
    let name: String
}

/// One existing mark of the selected instance.
struct ProbeMarkOption: Identifiable, Hashable {
    let id: UUID        // ProbeMark id
    let name: String
}

/// Drives the Probe Inspector's mark editor: which type / instance / mark is selected,
/// and the populated dropdown lists.  AppDelegate owns the data and repopulates these.
final class ProbeInspectorState: ObservableObject {
    @Published var selectedType:       MarkCategory = .object
    @Published var instances:          [ProbeInstanceOption] = []
    @Published var selectedInstanceID: UUID? = nil
    @Published var marks:              [ProbeMarkOption] = []
    @Published var selectedMarkID:     UUID? = nil   // nil = "＋ New" (add a fresh mark)

    /// True while AppDelegate is repopulating the lists, so the picker `onChange`
    /// handlers don't fire callbacks back into AppDelegate (avoids feedback loops).
    var isUpdating = false

    // Wired by AppDelegate:
    var onTypeChanged:     (() -> Void)?   // → repopulate instances + marks
    var onInstanceChanged: (() -> Void)?   // → repopulate marks
    var onMarkChanged:     (() -> Void)?   // → load the chosen mark's pose into the probe
    var onAddMark:         (() -> Void)?   // → new mark on the selected instance
    var onUpdateMark:      (() -> Void)?   // → overwrite the selected mark
}

/// Inspector for the bake probe and the scene's Position Marks.  Authors a mark by
/// type ▸ instance ▸ mark, with probe position (all types) and a target facing
/// rotation (Object marks — the direction the model holds at the mark during gait).
struct ProbeInspectorPanel: View {

    @ObservedObject var probe:     ProbeConfig
    @ObservedObject var state:     ProbeInspectorState
    @ObservedObject var clipboard: CoordinateClipboard
    /// Marked dirty + state persisted when the gizmo visibility toggle changes.
    var onVisibilityChanged: () -> Void = {}

    private let rotationRange: ClosedRange<Float> = -180...180

    /// True when a real (non-"New") mark is selected — enables Update.
    private var hasSelectedMark: Bool { state.selectedMarkID != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {

                HStack {
                    Image(systemName: "scope").foregroundColor(.accentColor)
                    Text("Probe").font(.headline)
                    Spacer()
                    PanelLockButton(isLocked: $probe.isLocked)
                }

                Toggle(isOn: $probe.isVisible) {
                    Text("Show gizmo in viewport").font(.caption)
                        .foregroundColor(probe.isVisible ? .green : .primary)
                }
                .toggleStyle(.switch).tint(.green)
                .environment(\.controlActiveState, .active)
                .onChange(of: probe.isVisible) { _, _ in onVisibilityChanged() }

                Divider()

                // ── Mark editor: type ▸ instance ▸ mark ───────────────────────
                Text("Edit Marks").font(.headline)

                Picker("Type", selection: $state.selectedType) {
                    ForEach(MarkCategory.allCases, id: \.self) { c in
                        Text(c.displayName).tag(c)
                    }
                }
                .onChange(of: state.selectedType) { _, _ in
                    if !state.isUpdating { state.onTypeChanged?() }
                }

                Picker("Item", selection: $state.selectedInstanceID) {
                    if state.instances.isEmpty { Text("—").tag(UUID?.none) }
                    ForEach(state.instances) { opt in Text(opt.name).tag(Optional(opt.id)) }
                }
                .disabled(state.instances.isEmpty)
                .onChange(of: state.selectedInstanceID) { _, _ in
                    if !state.isUpdating { state.onInstanceChanged?() }
                }

                Picker("Mark", selection: $state.selectedMarkID) {
                    Text("＋ New Mark").tag(UUID?.none)
                    ForEach(state.marks) { m in Text(m.name).tag(Optional(m.id)) }
                }
                .onChange(of: state.selectedMarkID) { _, _ in
                    if !state.isUpdating { state.onMarkChanged?() }
                }

                Divider()

                // ── Position (all types) ──────────────────────────────────────
                Group {
                    HStack {
                        Text("Position").font(.headline)
                        Spacer()
                        CoordCopyPasteButtons(
                            onCopy:   { clipboard.position = probe.position },
                            onPaste:  { if let p = clipboard.position { probe.position = p } },
                            canPaste: clipboard.position != nil && !probe.isLocked,
                            onZero:   { probe.position = .zero },
                            canZero:  !probe.isLocked)
                    }
                    SliderRow(label: "X", value: $probe.position.x, range: SceneLimits.positionRange, format: "%.2f")
                    SliderRow(label: "Y", value: $probe.position.y, range: SceneLimits.positionRange, format: "%.2f")
                    SliderRow(label: "Z", value: $probe.position.z, range: SceneLimits.positionRange, format: "%.2f")
                }
                .disabled(probe.isLocked)

                // ── Rotation / facing (Object marks only) ─────────────────────
                if state.selectedType == .object {
                    Group {
                        Text("Rotation (facing)").font(.headline)
                        SliderRow(label: "X", value: $probe.rotation.x, range: rotationRange, format: "%.0f°")
                        SliderRow(label: "Y", value: $probe.rotation.y, range: rotationRange, format: "%.0f°")
                        SliderRow(label: "Z", value: $probe.rotation.z, range: rotationRange, format: "%.0f°")
                        Text("The direction the model faces while standing at this mark during gait.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .disabled(probe.isLocked)
                }

                // ── Add / Update ──────────────────────────────────────────────
                HStack {
                    Button { state.onAddMark?() } label: {
                        Label("Add Mark", systemImage: "plus").frame(maxWidth: .infinity)
                    }
                    .disabled(probe.isLocked || state.selectedInstanceID == nil)
                    Button { state.onUpdateMark?() } label: {
                        Label("Update", systemImage: "checkmark").frame(maxWidth: .infinity)
                    }
                    .disabled(probe.isLocked || !hasSelectedMark)
                }

                Toggle(isOn: $probe.marksVisible) {
                    Text("Show marks (viewport + export)").font(.caption)
                        .foregroundColor(probe.marksVisible ? .green : .primary)
                }
                .toggleStyle(.switch).tint(.green)
                .environment(\.controlActiveState, .active)

                Text("K toggles marks · N / Shift+N cycles (probe + playhead jump to the mark) "
                    + "· Delete removes the selected mark.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Text("The probe marks where the scene is captured from when exporting an "
                    + "environment HDR.  It is never included in renders or exports.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
        .frame(width: 300)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
