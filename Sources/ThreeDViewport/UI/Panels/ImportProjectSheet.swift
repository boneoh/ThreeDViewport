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

    let probe: SIMD3<Float>

    init(insertTime: Double, probe: SIMD3<Float>) {
        self.insertTime = String(format: "%.3f", insertTime)
        self.probe = probe
        self.posX  = String(format: "%.3f", probe.x)
        self.posY  = String(format: "%.3f", probe.y)
        self.posZ  = String(format: "%.3f", probe.z)
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
