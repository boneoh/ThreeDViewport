import SwiftUI
import simd

// Floating helper panel that generates a helix / arc / corkscrew of keyframes for
// the Timeline-selected camera, light, or object.
//
// Workflow:
//   1. Place the Probe at the axis start, click "Capture Axis Start"; repeat for end.
//      (Probe Inspector has the sliders; copy/paste/zero icons here mirror it.)
//   2. Select a track in the Timeline Editor, scrub to the start time, click
//      "Capture Start"; scrub to the end time, click "Capture End".
//   3. Enter radius, start/end angle, revolutions, keyframes-per-rev.
//   4. "Create Keyframes" replaces existing keyframes in [start, end] with the path.

/// Observable state, held on the ViewportView so captures + field values survive
/// panel hide/show.
final class RotationPathAnimatorState: ObservableObject {
    @Published var axisStart:  SIMD3<Float>? = nil
    @Published var axisEnd:    SIMD3<Float>? = nil
    @Published var trackLabel: String?       = nil
    @Published var startTime:  Double?        = nil
    @Published var endTime:    Double?        = nil

    @Published var radius:      String = "3"
    @Published var startAngle:  String = "0"
    @Published var endAngle:    String = "0"
    @Published var revolutions: String = "1"
    @Published var perRev:      String = "12"

    @Published var status: String = ""

    /// The captured track (not @Published — the label mirrors it for the UI).
    var capturedRef: TrackRef? = nil
}

struct RotationPathAnimatorPanel: View {
    @ObservedObject var state:     RotationPathAnimatorState
    @ObservedObject var clipboard: CoordinateClipboard

    let captureAxisStart: () -> Void
    let captureAxisEnd:   () -> Void
    let captureStart:     () -> Void
    let captureEnd:       () -> Void
    let create:           () -> Void

    private func vecText(_ v: SIMD3<Float>?) -> String {
        guard let v = v else { return "—" }
        return String(format: "%.2f, %.2f, %.2f", v.x, v.y, v.z)
    }
    private func timeText(_ t: Double?) -> String {
        guard let t = t else { return "—" }
        return String(format: "%.3f s", t)
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
            GroupBox(label: Text("Parameters").font(.headline)) {
                VStack(alignment: .leading, spacing: 6) {
                    field("Radius",          $state.radius)
                    field("Start angle (°)", $state.startAngle)
                    field("End angle (°)",   $state.endAngle)
                    field("Revolutions",     $state.revolutions)
                    field("Keyframes / rev", $state.perRev)
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
