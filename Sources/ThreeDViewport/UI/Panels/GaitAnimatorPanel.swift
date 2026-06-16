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
    @Published var startTime: Double? = 0

    /// Marks available to walk, plus which are selected (in this stored order).
    @Published var markList:      [ProbeMark] = []
    @Published var selectedMarks: Set<UUID> = []

    @Published var status: String = ""
    @Published var validationAlert: String? = nil
}

struct GaitAnimatorPanel: View {
    @ObservedObject var state: GaitAnimatorState

    let captureStart: () -> Void
    let create:       () -> Void

    private func timeText(_ t: Double?) -> String {
        guard let t = t else { return "—" }
        return String(format: "%.3f s", t)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // ── Target + gait ─────────────────────────────────────────────────
            GroupBox(label: Text("Model & Gait").font(.headline)) {
                VStack(alignment: .leading, spacing: 8) {
                    TargetPicker(targets: state.targets, selection: $state.capturedRef)
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
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(state.markList) { mark in
                                    Toggle(isOn: Binding(
                                        get: { state.selectedMarks.contains(mark.id) },
                                        set: { on in
                                            if on { state.selectedMarks.insert(mark.id) }
                                            else  { state.selectedMarks.remove(mark.id) }
                                        })) {
                                        Text(mark.name).font(.caption)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 120)
                        HStack {
                            Button("All")  { state.selectedMarks = Set(state.markList.map { $0.id }) }
                            Button("None") { state.selectedMarks = [] }
                            Spacer()
                            Text("\(state.selectedMarks.count) of \(state.markList.count)")
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
                    HStack {
                        Text("Speed").frame(width: 110, alignment: .leading)
                        TextField("", text: $state.speed).textFieldStyle(.roundedBorder).frame(width: 80)
                        Text("units/s").font(.caption).foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Stride").frame(width: 110, alignment: .leading)
                        TextField("", text: $state.stride).textFieldStyle(.roundedBorder).frame(width: 80)
                        Text("units/cycle").font(.caption).foregroundColor(.secondary)
                    }
                    HStack {
                        Button("Start at Playhead", action: captureStart)
                        Spacer()
                        Text(timeText(state.startTime)).font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(4)
            }

            Button(action: create) {
                Text("Create Keyframes").frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)

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
