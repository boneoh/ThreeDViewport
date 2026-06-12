import SwiftUI
import simd

// Floating helper panel that drives a constant, wobble-free self-spin for the
// Timeline-selected object via rate markers.  Each marker sets a spin rate
// (revolutions / second, signed) about the object's own local X/Y/Z axis; the
// spin holds that rate until the next marker, and the last marker runs to the end
// of the timeline.  A marker with rate 0 stops the spin from that point.  The
// dense pose keyframes are regenerated from the markers, so adjusting a rate is
// just editing one marker.
//
// Workflow:
//   1. Pick a target (object or model) from the dropdown.
//   2. Set the rate + local axis, scrub the playhead, click "Create Keyframes".
//   3. Add more markers to change rate over time; rate 0 stops it.

/// Observable state, held on the ViewportView so field values survive panel hide/show.
final class SpinAnimatorState: ObservableObject {
    @Published var axisIndex:   Int    = 1        // 0 = X, 1 = Y, 2 = Z
    @Published var rate:        String = "0.5"    // revolutions / second, signed
    @Published var perRev:      String = "12"     // keyframe density
    // Advanced: optional second simultaneous spin (tumble).  rate2 = 0 → single-axis.
    @Published var axisIndex2:  Int    = 0        // 0 = X, 1 = Y, 2 = Z
    @Published var rate2:       String = "0"      // revolutions / second, signed

    @Published var status:          String = ""
    /// Blocking validation error → raised as an alert (see .validationAlert).
    @Published var validationAlert: String? = nil

    /// Selectable targets + the chosen one (driven by the panel's Target dropdown).
    @Published var targets: [PathTarget] = []
    @Published var capturedRef: TrackRef? = nil

    /// Rate markers for the currently-selected target (mirrors the persisted schedule).
    @Published var markers: [SpinRateMarker] = []
}

struct SpinAnimatorPanel: View {
    @ObservedObject var state: SpinAnimatorState

    let addMarker:    () -> Void
    let deleteMarker: (UUID) -> Void
    let clearMarkers: () -> Void
    let selectTarget: () -> Void

    private func axisLabel(_ i: Int) -> String { ["X", "Y", "Z"][max(0, min(2, i))] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // ── Target ────────────────────────────────────────────────────────
            GroupBox(label: Text("Target").font(.headline)) {
                TargetPicker(targets: state.targets, selection: $state.capturedRef)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                    .onChange(of: state.capturedRef) { _, _ in selectTarget() }
            }

            // ── Rate ──────────────────────────────────────────────────────────
            GroupBox(label: Text("Spin Rate").font(.headline)) {
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
                    field("Rate (rev/s)",    $state.rate)
                    field("Keyframes / rev", $state.perRev)
                    Text("Signed rate sets direction. Rate 0 stops the spin. "
                       + "Keyframes/rev ≥ 3.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    DisclosureGroup("Advanced — Tumble (second axis)") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Second axis").frame(width: 120, alignment: .leading)
                                Picker("", selection: $state.axisIndex2) {
                                    Text("X").tag(0)
                                    Text("Y").tag(1)
                                    Text("Z").tag(2)
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .frame(width: 120)
                            }
                            field("Rate 2 (rev/s)", $state.rate2)
                            Text("A non-zero Rate 2 spins about a second local axis at the "
                               + "same time, for a tumble. 0 = off (single-axis spin).")
                                .font(.caption).foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 4)
                    }
                    .font(.caption)

                    Button(action: addMarker) {
                        Text("Create Keyframes").frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(4)
            }

            // ── Markers ───────────────────────────────────────────────────────
            GroupBox(label: Text("Rate Keyframes").font(.headline)) {
                VStack(alignment: .leading, spacing: 4) {
                    if state.markers.isEmpty {
                        Text("No rate keyframes yet.")
                            .font(.caption).foregroundColor(.secondary)
                    } else {
                        ForEach(state.markers.sorted { $0.time < $1.time }) { m in
                            HStack {
                                Text(String(format: "%.3f s", m.time))
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(width: 70, alignment: .leading)
                                Text(String(format: "%+.3g rev/s", m.rate))
                                    .font(.system(.caption, design: .monospaced))
                                Text(axisLabel(m.axisIndex))
                                    .font(.caption).foregroundColor(.secondary)
                                Spacer()
                                Button {
                                    deleteMarker(m.id)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        Divider()
                        Button("Clear All", action: clearMarkers)
                            .buttonStyle(.borderless)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

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
