import SwiftUI
import simd

// Floating helper panel that generates a constant, wobble-free self-spin for the
// Timeline-selected object — evenly-spaced, single-axis rotation keyframes about
// the object's own local X/Y/Z axis.  Unlike the Orbit Path Animator (which
// orbits around an external Probe axis), this spins the object in place, so it
// composes under a glued envelope's orbit.
//
// Workflow:
//   1. Select an object track in the Timeline Editor.
//   2. Scrub to the start time, click "Capture Start"; scrub to the end, "Capture End".
//   3. Pick the local axis, revolutions (negative reverses), and keyframes/rev.
//   4. "Create Keyframes" replaces existing keyframes in [start, end] with the spin.

/// Observable state, held on the ViewportView so field values survive panel hide/show.
final class SpinAnimatorState: ObservableObject {
    @Published var axisIndex:  Int    = 1        // 0 = X, 1 = Y, 2 = Z
    @Published var revolutions: String = "1"
    @Published var perRev:      String = "4"

    @Published var trackLabel: String? = nil
    @Published var startTime:  Double? = nil
    @Published var endTime:    Double? = nil
    @Published var status:     String  = ""

    /// The captured track (not @Published — the label mirrors it for the UI).
    var capturedRef: TrackRef? = nil
}

struct SpinAnimatorPanel: View {
    @ObservedObject var state: SpinAnimatorState

    let captureStart: () -> Void
    let captureEnd:   () -> Void
    let create:       () -> Void

    private func timeText(_ t: Double?) -> String {
        guard let t = t else { return "—" }
        return String(format: "%.3f s", t)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // ── Track + time window (Timeline) ────────────────────────────────
            GroupBox(label: Text("Track & Time (Timeline)").font(.headline)) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button("Capture Start", action: captureStart)
                        Spacer()
                        Text(timeText(state.startTime)).font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Button("Capture End", action: captureEnd)
                        Spacer()
                        Text(timeText(state.endTime)).font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Track:").foregroundColor(.secondary)
                        Text(state.trackLabel ?? "—").bold()
                    }
                    .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            // ── Parameters ────────────────────────────────────────────────────
            GroupBox(label: Text("Spin").font(.headline)) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Local axis").frame(width: 120, alignment: .leading)
                        Picker("", selection: $state.axisIndex) {
                            Text("X").tag(0)
                            Text("Y").tag(1)
                            Text("Z").tag(2)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 120)
                    }
                    field("Revolutions",     $state.revolutions)
                    field("Keyframes / rev", $state.perRev)
                    Text("Negative revolutions reverse direction. Keyframes/rev ≥ 3.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
    }

    @ViewBuilder
    private func field(_ label: String, _ binding: Binding<String>) -> some View {
        HStack {
            Text(label).frame(width: 120, alignment: .leading)
            TextField("", text: binding)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
        }
    }
}
