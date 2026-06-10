import SwiftUI
import simd

/// Options gathered in the File ▸ Import Project… dialog — where (in time + space)
/// to drop the imported project.  `transformMatrix()` bakes Position/Rotation/Scale
/// into a single TRS world placement.
final class ImportProjectOptions: ObservableObject {
    @Published var insertTime: String
    @Published var posX: String
    @Published var posY: String
    @Published var posZ: String
    @Published var rotX: String = "0"
    @Published var rotY: String = "0"
    @Published var rotZ: String = "0"
    @Published var scale: String = "1"
    @Published var includeLights: Bool = false
    /// When the source has both In/Out marks, import only that slice (remapped so
    /// the source In lands at `insertTime`).  Defaults on when a range is available.
    @Published var useSourceInOut: Bool

    let probe: SIMD3<Float>
    /// The source project's saved In/Out range (seconds), or nil when it isn't a
    /// clean both-marks-set state (no marks, or only one mark — slicing unavailable).
    let sourceInOut: (in: Double, out: Double)?
    /// True when the source has exactly one mark (or an inverted pair) — slicing is
    /// unavailable, so the dialog warns the stray mark is ignored and the whole
    /// project is imported.
    let sourceHalfMarked: Bool

    init(insertTime: Double, probe: SIMD3<Float>,
         sourceInOut: (in: Double, out: Double)? = nil,
         sourceHalfMarked: Bool = false) {
        self.insertTime = String(format: "%.3f", insertTime)
        self.probe = probe
        self.posX  = String(format: "%.3f", probe.x)
        self.posY  = String(format: "%.3f", probe.y)
        self.posZ  = String(format: "%.3f", probe.z)
        self.sourceInOut      = sourceInOut
        self.sourceHalfMarked = sourceHalfMarked
        self.useSourceInOut   = (sourceInOut != nil)
    }

    /// The slice to import, or nil when the user opted out (or none is available).
    var effectiveSlice: (in: Double, out: Double)? {
        (useSourceInOut ? sourceInOut : nil)
    }

    func usingProbe() {
        posX = String(format: "%.3f", probe.x)
        posY = String(format: "%.3f", probe.y)
        posZ = String(format: "%.3f", probe.z)
    }

    var insertTimeValue: Double { Double(insertTime) ?? 0 }

    /// M = translate(P) · rotate(YXZ) · scale(S), matching the Inspector's rotation order.
    func transformMatrix() -> matrix_float4x4 {
        func f(_ s: String) -> Float { Float(s) ?? 0 }
        let pos = SIMD3<Float>(f(posX), f(posY), f(posZ))
        let s   = Float(scale).map { $0 == 0 ? 1 : $0 } ?? 1
        let d2r = Float.pi / 180
        let qx = simd_quatf(angle: f(rotX) * d2r, axis: SIMD3<Float>(1, 0, 0))
        let qy = simd_quatf(angle: f(rotY) * d2r, axis: SIMD3<Float>(0, 1, 0))
        let qz = simd_quatf(angle: f(rotZ) * d2r, axis: SIMD3<Float>(0, 0, 1))
        let q  = qy * qx * qz
        return PathGenerator.makeTransform(translation: pos, rotation: q,
                                           scale: SIMD3<Float>(repeating: s))
    }
}

struct ImportProjectSheet: View {
    @ObservedObject var options: ImportProjectOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Insert at (s)").frame(width: 100, alignment: .leading)
                TextField("", text: $options.insertTime).frame(width: 90)
                Spacer()
            }

            HStack {
                Text("Position").frame(width: 100, alignment: .leading)
                TextField("X", text: $options.posX).frame(width: 60)
                TextField("Y", text: $options.posY).frame(width: 60)
                TextField("Z", text: $options.posZ).frame(width: 60)
                Button("Probe") { options.usingProbe() }
            }
            HStack {
                Text("Rotation (°)").frame(width: 100, alignment: .leading)
                TextField("X", text: $options.rotX).frame(width: 60)
                TextField("Y", text: $options.rotY).frame(width: 60)
                TextField("Z", text: $options.rotZ).frame(width: 60)
            }
            HStack {
                Text("Scale").frame(width: 100, alignment: .leading)
                TextField("", text: $options.scale).frame(width: 90)
                Spacer()
            }

            Toggle("Include lights", isOn: $options.includeLights)

            if let r = options.sourceInOut {
                Toggle("Use source In/Out range", isOn: $options.useSourceInOut)
                Text(String(format: "source: %.2f\u{2013}%.2f s  (%.2f s)\u{2002}\u{2014}\u{2002}"
                            + "imports only this slice, with its In at the insert time.",
                            r.in, r.out, r.out - r.in))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if options.sourceHalfMarked {
                Label("The source has only one timeline mark (needs both In and Out to "
                    + "slice). It will be ignored and the whole project imported.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Models, animation, materials, and glued units are appended to the "
               + "current scene at the chosen time + placement. Camera and scene-wide "
               + "effects (fog, particles, grade, background) are not imported.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textFieldStyle(.roundedBorder)
        .padding(16)
        .frame(width: 440)
    }
}
