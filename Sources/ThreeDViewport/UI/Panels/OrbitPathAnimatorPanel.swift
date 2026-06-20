import SwiftUI
import simd

// Floating helper panel that drives a constant planar orbit for the Timeline-
// selected camera, light, or object via rate markers.  The orbit geometry — a
// constant-height circle of `radius` around the Probe axis start, tilted so its
// plane normal is axisStart → axisEnd — is shared across the track.  Each marker
// sets an orbit rate (revolutions / second, signed) that holds until the next
// marker; the last marker runs to the end of the timeline, and a rate-0 marker
// stops the orbit.  The dense keyframes are regenerated from the markers.
//
// Workflow:
//   1. Place the Probe at the orbit centre, click "Capture Axis Start"; place it
//      along the desired tilt and click "Capture Axis End" (same point = level).
//   2. Pick a target, set radius + rate, scrub the playhead, "Create Keyframes".
//   3. Add more markers to change rate over time; rate 0 stops it.

/// Observable state, held on the ViewportView so captures + field values survive
/// panel hide/show.
final class OrbitPathAnimatorState: ObservableObject {
    @Published var axisStart:  SIMD3<Float>? = nil
    @Published var axisEnd:    SIMD3<Float>? = nil

    @Published var radius: String = "3"
    @Published var rate:   String = "0.25"   // revolutions / second, signed
    @Published var perRev: String = "12"     // keyframe density

    @Published var status: String = ""
    /// Blocking validation error → raised as an alert (see .validationAlert).
    @Published var validationAlert: String? = nil

    /// Selectable targets + the chosen one (driven by the panel's Target dropdown).
    @Published var targets: [PathTarget] = []
    @Published var capturedRef: TrackRef? = nil

    /// Rate markers for the currently-selected target (mirrors the persisted schedule).
    @Published var markers: [OrbitRateMarker] = []
}

struct OrbitPathAnimatorPanel: View {
    @ObservedObject var state:     OrbitPathAnimatorState
    @ObservedObject var clipboard: CoordinateClipboard

    let captureAxisStart: () -> Void
    let captureAxisEnd:   () -> Void
    let addMarker:        () -> Void
    let applyGeometry:    () -> Void
    let deleteMarker:     (UUID) -> Void
    let clearMarkers:     () -> Void
    let selectTarget:     () -> Void
    /// True when the chosen target's Timeline track is locked → Create is disabled.
    let isTargetLocked:   (TrackRef?) -> Bool

    private func vecText(_ v: SIMD3<Float>?) -> String {
        guard let v = v else { return "—" }
        return String(format: "%.2f, %.2f, %.2f", v.x, v.y, v.z)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // ── Axis (Probe) ──────────────────────────────────────────────────
            GroupBox(label: Text("Axis (Probe)").font(.headline)) {
                VStack(alignment: .leading, spacing: 8) {
                    axisRow("Capture Axis Start",
                            value: state.axisStart,
                            capture: captureAxisStart,
                            set: { state.axisStart = $0 })
                    Divider()
                    axisRow("Capture Axis End",
                            value: state.axisEnd,
                            capture: captureAxisEnd,
                            set: { state.axisEnd = $0 })
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            // ── Target ────────────────────────────────────────────────────────
            GroupBox(label: Text("Target").font(.headline)) {
                TargetPicker(targets: state.targets, selection: $state.capturedRef)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                    .onChange(of: state.capturedRef) { _, _ in selectTarget() }
            }

            // ── Rate ──────────────────────────────────────────────────────────
            GroupBox(label: Text("Orbit Rate").font(.headline)) {
                VStack(alignment: .leading, spacing: 6) {
                    field("Radius",          $state.radius)
                    field("Rate (rev/s)",    $state.rate)
                    field("Keyframes / rev", $state.perRev)
                    Text("Signed rate sets direction. Rate 0 stops the orbit. "
                       + "Keyframes/rev ≥ 1.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(action: addMarker) {
                        Text("Create Keyframes").frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isTargetLocked(state.capturedRef))
                    if !state.markers.isEmpty {
                        Button("Apply Radius / Axis", action: applyGeometry)
                            .frame(maxWidth: .infinity)
                            .disabled(isTargetLocked(state.capturedRef))
                    }
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
                                Spacer()
                                Button {
                                    deleteMarker(m.id)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                }
                                .buttonStyle(.borderless)
                                .disabled(isTargetLocked(state.capturedRef))
                            }
                        }
                        Divider()
                        Button("Clear All", action: clearMarkers)
                            .buttonStyle(.borderless)
                            .disabled(isTargetLocked(state.capturedRef))
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

    /// One axis-point row: capture button + value + copy/paste/zero icons.
    @ViewBuilder
    private func axisRow(_ title: String,
                         value: SIMD3<Float>?,
                         capture: @escaping () -> Void,
                         set: @escaping (SIMD3<Float>) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button(title, action: capture)
                Spacer()
                CoordCopyPasteButtons(
                    onCopy:   { if let v = value { clipboard.position = v } },
                    onPaste:  { if let p = clipboard.position { set(p) } },
                    canPaste: clipboard.position != nil,
                    onZero:   { set(.zero) },
                    canZero:  true)
            }
            Text(vecText(value)).font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
        }
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
