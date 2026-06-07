import SwiftUI
import simd

// Floating helper panel that generates a flat spiral-arc move of keyframes for the
// selected camera / light / object.  The entity sweeps from a start point to an end
// point around an Aim point (the pivot it also looks at), in the plane of the three
// points, with the radius easing from |start−aim| to |end−aim| (so it spirals in or
// out).  A toggle picks the long way (>180°) or short way around the pivot.
//
// Workflow:
//   1. Place the Probe at each point; click Capture Start / End / Aim.
//   2. Pick the Target track; set the start/end time window (defaults 0…last).
//   3. Enter the number of keyframes (≥2) and the arc direction.
//   4. "Create Keyframes" replaces existing keyframes in [start, end] with the curve.

/// Observable state, held on the ViewportView so captures + field values survive
/// panel hide/show.
final class CurvePathAnimatorState: ObservableObject {
    @Published var startPoint: SIMD3<Float>? = nil
    @Published var endPoint:   SIMD3<Float>? = nil
    /// Pivot the path orbits and the camera/light aims at.
    @Published var aimPoint:   SIMD3<Float>? = nil
    @Published var startTime:  Double? = nil
    @Published var endTime:    Double? = nil

    @Published var keyframes:  String = "12"
    /// true = sweep the long way (>180°) around the aim; false = the short way.
    @Published var useLongArc: Bool = true

    @Published var status: String = ""
    /// Blocking validation error → raised as an alert (see .validationAlert).
    @Published var validationAlert: String? = nil

    /// Selectable targets + the chosen one (driven by the panel's Target dropdown).
    @Published var targets: [PathTarget] = []
    @Published var capturedRef: TrackRef? = nil
}

struct CurvePathAnimatorPanel: View {
    @ObservedObject var state:     CurvePathAnimatorState
    @ObservedObject var clipboard: CoordinateClipboard

    let captureStartPoint: () -> Void
    let captureEndPoint:   () -> Void
    let captureAim:        () -> Void
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

            // ── Points (Probe) ────────────────────────────────────────────────
            GroupBox(label: Text("Curve (Probe)").font(.headline)) {
                VStack(alignment: .leading, spacing: 8) {
                    pointRow("Capture Start Point", value: state.startPoint,
                             capture: captureStartPoint, set: { state.startPoint = $0 })
                    Divider()
                    pointRow("Capture End Point", value: state.endPoint,
                             capture: captureEndPoint, set: { state.endPoint = $0 })
                    Divider()
                    pointRow("Capture Aim", value: state.aimPoint,
                             capture: captureAim, set: { state.aimPoint = $0 })
                        .help("The pivot the path orbits and the camera/light aims at.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            // ── Target + time window ──────────────────────────────────────────
            GroupBox(label: Text("Target & Time").font(.headline)) {
                VStack(alignment: .leading, spacing: 6) {
                    TargetPicker(targets: state.targets, selection: $state.capturedRef)
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            // ── Parameters ────────────────────────────────────────────────────
            GroupBox(label: Text("Parameters").font(.headline)) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Keyframes").frame(width: 120, alignment: .leading)
                        TextField("", text: $state.keyframes)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                    }
                    Picker("Arc", selection: $state.useLongArc) {
                        Text("Short (≤180°)").tag(false)
                        Text("Long (>180°)").tag(true)
                    }
                    .pickerStyle(.segmented)
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

    /// One point row: capture button + value + copy/paste/zero icons.
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
