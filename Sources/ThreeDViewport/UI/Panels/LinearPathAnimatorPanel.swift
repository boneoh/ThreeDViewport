import SwiftUI
import simd

// Floating helper panel that generates a straight-line move of keyframes for the
// Timeline-selected camera, light, or object.
//
// Workflow:
//   1. Place the Probe at the line start, click "Capture Start Point"; repeat for end.
//      (Probe Inspector has the sliders; copy/paste/zero icons here mirror it.)
//   2. Select a track in the Timeline Editor, scrub to the start time, click
//      "Capture Start"; scrub to the end time, click "Capture End".
//   3. Enter the number of keyframes (≥2).
//   4. "Create Keyframes" replaces existing keyframes in [start, end] with the line.
//
// Camera/lights keep their current orientation (parallel dolly); objects face the
// direction of travel.

/// Observable state, held on the ViewportView so captures + field values survive
/// panel hide/show.
final class LinearPathAnimatorState: ObservableObject {
    @Published var startPoint: SIMD3<Float>? = nil
    @Published var endPoint:   SIMD3<Float>? = nil
    @Published var trackLabel: String?       = nil
    @Published var startTime:  Double?        = nil
    @Published var endTime:    Double?        = nil

    @Published var keyframes: String = "2"

    @Published var status: String = ""

    /// The captured track (not @Published — the label mirrors it for the UI).
    var capturedRef: TrackRef? = nil
}

struct LinearPathAnimatorPanel: View {
    @ObservedObject var state:     LinearPathAnimatorState
    @ObservedObject var clipboard: CoordinateClipboard

    let captureStartPoint: () -> Void
    let captureEndPoint:   () -> Void
    let captureStart:      () -> Void
    let captureEnd:        () -> Void
    let create:            () -> Void

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

            // ── Endpoints (Probe) ─────────────────────────────────────────────
            GroupBox(label: Text("Line (Probe)").font(.headline)) {
                VStack(alignment: .leading, spacing: 8) {
                    pointRow("Capture Start Point",
                             value: state.startPoint,
                             capture: captureStartPoint,
                             set: { state.startPoint = $0 })
                    Divider()
                    pointRow("Capture End Point",
                             value: state.endPoint,
                             capture: captureEndPoint,
                             set: { state.endPoint = $0 })
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
                HStack {
                    Text("Keyframes").frame(width: 120, alignment: .leading)
                    TextField("", text: $state.keyframes)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
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

    /// One endpoint row: capture button + value + copy/paste/zero icons.
    @ViewBuilder
    private func pointRow(_ title: String,
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
}
