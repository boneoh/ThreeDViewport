import SwiftUI
import simd

// Floating helper that generates a locomotion (walk) along the chosen position marks:
// the model follows a smooth path through the marks at the set speed, turning to face
// the direction of travel, while its legs/arms cycle in step.  Phase 1 = walk only.
//
// Workflow:
//   1. Drop position marks along the route (N / Add Position Mark).
//   2. Open this panel, pick the target model + the marks to use.
//   3. Set Speed (units/sec) and Stride (distance per full cycle).
//   4. "Create Keyframes" bakes the root path + limb cycle into the tracks.

/// Observable state, held on the ViewportView so field values survive hide/show.
final class GaitAnimatorState: ObservableObject {
    @Published var targets:     [PathTarget] = []
    @Published var capturedRef: TrackRef? = nil
    @Published var gait:        GaitType = .walk

    @Published var speed:  String = "1.5"
    @Published var stride: String = "1.6"
    /// Derive stride from the model's legs + swing so the feet don't skate; disables the
    /// manual Stride field.  On by default.
    @Published var autoStride: Bool = true

    // Tuning multipliers (1.0 = the gait's default amplitude).
    @Published var swingMul: String = "1.0"
    @Published var kneeMul:  String = "1.0"
    @Published var armMul:   String = "1.0"
    @Published var bobMul:   String = "1.0"
    /// Drop the model so its feet meet the marks (vs. its origin at the hips).
    @Published var plantFeet: Bool = true
    /// Foot-IK: plant each foot on the ground and solve the legs so it doesn't skate
    /// (the body rolls over the planted foot).  On by default; needs leg joints.
    @Published var footLock: Bool = true

    /// All marks available to walk (scene order), and the ordered subset forming the
    /// path — `pathMarks` is the walk sequence (membership = inclusion, order = order walked).
    @Published var markList:  [ProbeMark] = []
    @Published var pathMarks: [UUID] = []

    @Published var status: String = ""
    @Published var validationAlert: String? = nil

    /// True while the probe is replaying the timed pace (the "Rehearse Pace" preview).
    /// Set by ViewportView so the button can toggle to "Stop Rehearsal".
    @Published var isRehearsing: Bool = false
}

struct GaitAnimatorPanel: View {
    @ObservedObject var state: GaitAnimatorState
    /// Live timeline (kept for transport context; paced timing derives mark times).
    @ObservedObject var timeline: Timeline

    let create: () -> Void
    /// Starts (or stops) the probe pace rehearsal — previews mark timing/speed.
    let rehearse: () -> Void
    /// True when the chosen target's Timeline track is locked → Create is disabled.
    let isTargetLocked: (TrackRef?) -> Bool
    /// Fires when the Target changes so the marks picker can re-filter to that model.
    let onTargetChanged: () -> Void

    /// Keeps keyboard focus on the Rehearse button after a click (instead of the Speed
    /// field), so Space/Enter re-toggles it and other keys forward to the viewport.
    @FocusState private var rehearseFocused: Bool

    /// Marks not yet in the path, in scene order (for the "Add" menu).
    private var unusedMarks: [ProbeMark] {
        state.markList.filter { m in !state.pathMarks.contains(m.id) }
    }

    private func markName(_ id: UUID) -> String {
        state.markList.first { $0.id == id }?.name ?? "—"
    }

    private func moveUp(_ i: Int) {
        guard i > 0, i < state.pathMarks.count else { return }
        state.pathMarks.swapAt(i, i - 1)
    }

    private func moveDown(_ i: Int) {
        guard i >= 0, i + 1 < state.pathMarks.count else { return }
        state.pathMarks.swapAt(i, i + 1)
    }

    @ViewBuilder
    private func tuneRow(_ label: String, _ binding: Binding<String>) -> some View {
        HStack {
            Text(label).frame(width: 70, alignment: .leading)
            TextField("", text: binding).textFieldStyle(.roundedBorder).frame(width: 70)
            Text("×").font(.caption).foregroundColor(.secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // ── Target + gait ─────────────────────────────────────────────────
            GroupBox(label: Text("Model & Gait").font(.headline)) {
                VStack(alignment: .leading, spacing: 8) {
                    TargetPicker(targets: state.targets, selection: $state.capturedRef)
                        .onChange(of: state.capturedRef) { _, _ in onTargetChanged() }
                    Picker("Gait", selection: $state.gait) {
                        ForEach(GaitType.allCases) { g in Text(g.label).tag(g) }
                    }
                    .pickerStyle(.segmented)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            // ── Path marks ────────────────────────────────────────────────────
            GroupBox(label: Text("Path Marks").font(.headline)) {
                VStack(alignment: .leading, spacing: 4) {
                    if state.markList.isEmpty {
                        Text("No position marks. Drop marks along the route first.")
                            .font(.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        if state.pathMarks.isEmpty {
                            Text("No marks in the path. Add marks below.")
                                .font(.caption).foregroundColor(.secondary)
                        } else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(Array(state.pathMarks.enumerated()), id: \.element) { idx, id in
                                        HStack(spacing: 4) {
                                            Text("\(idx + 1).").font(.caption).foregroundColor(.secondary)
                                                .frame(width: 22, alignment: .trailing)
                                            Text(markName(id)).font(.caption)
                                            Spacer()
                                            Button { moveUp(idx) } label: { Image(systemName: "chevron.up") }
                                                .buttonStyle(.borderless).disabled(idx == 0)
                                            Button { moveDown(idx) } label: { Image(systemName: "chevron.down") }
                                                .buttonStyle(.borderless).disabled(idx == state.pathMarks.count - 1)
                                            Button { state.pathMarks.remove(at: idx) } label: { Image(systemName: "xmark") }
                                                .buttonStyle(.borderless)
                                        }
                                    }
                                }
                            }
                            .frame(maxHeight: 140)
                        }
                        HStack {
                            Menu("Add") {
                                ForEach(unusedMarks) { m in
                                    Button(m.name) { state.pathMarks.append(m.id) }
                                }
                            }
                            .frame(width: 70)
                            .disabled(unusedMarks.isEmpty)
                            Button("All")  { state.pathMarks = state.markList.map { $0.id } }
                            Button("None") { state.pathMarks = [] }
                            Spacer()
                            Text("\(state.pathMarks.count) of \(state.markList.count)")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            // ── Parameters ────────────────────────────────────────────────────
            GroupBox(label: Text("Parameters").font(.headline)) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Walks at Speed and holds each mark's Pause (set per mark in the Probe "
                        + "Inspector).  Mark times are derived from the first mark + speed + pauses.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Rehearse = ranged playback A→B.  Grab focus on click so the Speed field
                    // stops eating keystrokes and Return re-toggles.
                    Button(action: { rehearse(); rehearseFocused = true }) {
                        Text(state.isRehearsing ? "Stop Rehearsal" : "Rehearse Pace")
                            .frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut(.defaultAction)   // Return toggles, regardless of focus
                    .focusable()
                    .focused($rehearseFocused)
                    Text("Plays from the first to the last mark (objects animate, playhead scrubs) "
                        + "then stops — no keyframes changed.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text("Speed").frame(width: 110, alignment: .leading)
                        TextField("", text: $state.speed).textFieldStyle(.roundedBorder).frame(width: 80)
                        Text("units/s").font(.caption).foregroundColor(.secondary)
                    }
                    Toggle("Auto stride (reduce foot slip)", isOn: $state.autoStride)
                    HStack {
                        Text("Stride").frame(width: 110, alignment: .leading)
                        TextField("", text: $state.stride).textFieldStyle(.roundedBorder).frame(width: 80)
                            .disabled(state.autoStride)
                        Text("units/cycle").font(.caption).foregroundColor(.secondary)
                    }
                    .opacity(state.autoStride ? 0.5 : 1)
                }
                .padding(4)
            }

            // ── Tuning ────────────────────────────────────────────────────────
            GroupBox(label: Text("Tuning (× default)").font(.headline)) {
                VStack(alignment: .leading, spacing: 6) {
                    tuneRow("Swing", $state.swingMul)
                    tuneRow("Knee",  $state.kneeMul)
                    tuneRow("Arm",   $state.armMul)
                    tuneRow("Bob",   $state.bobMul)
                    Toggle("Plant feet on marks", isOn: $state.plantFeet)
                    Toggle("Foot lock (IK)", isOn: $state.footLock)
                }
                .padding(4)
            }

            // Click-only (no Return default): Create Keyframes is destructive (it rebakes,
            // wiping keyframes from the gait start onward), so Return drives Rehearse instead.
            Button(action: create) {
                Text("Create Keyframes").frame(maxWidth: .infinity)
            }
            .disabled(isTargetLocked(state.capturedRef))

            if !state.status.isEmpty {
                Text(state.status).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 300)
        .validationAlert($state.validationAlert)
    }
}
