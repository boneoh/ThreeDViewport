import SwiftUI
import simd

// Floating panel for atmosphere effects.  Phase 1 hosts Fog; later phases will
// add precipitation (rain / snow / sleet) and smoke beneath it.
struct AtmospherePanel: View {

    @ObservedObject var fog: FogSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // ── Header ────────────────────────────────────────────────────
                HStack {
                    Image(systemName: "cloud.fog.fill")
                        .foregroundColor(fog.isEnabled ? .green : .accentColor)
                    Text("Atmosphere")
                        .font(.headline)
                    Spacer()
                }
                .padding(.bottom, 10)

                Divider().padding(.bottom, 14)

                // ── Fog ───────────────────────────────────────────────────────
                Text("Fog")
                    .font(.subheadline.bold())
                    .padding(.bottom, 6)

                Toggle(isOn: $fog.isEnabled) {
                    Text("Enabled")
                        .font(.caption)
                        .foregroundColor(fog.isEnabled ? .green : .primary)
                }
                .toggleStyle(.switch)
                .tint(.green)
                .padding(.bottom, 10)

                ColorPicker("Color", selection: fogColorBinding, supportsOpacity: false)
                    .font(.caption)
                    .padding(.bottom, 10)

                FogSliderRow(label: "Density", value: $fog.density,
                             range: 0.0...1.0, format: "%.2f")

                Divider().padding(.vertical, 10)

                FogSliderRow(label: "Start", value: $fog.startDistance,
                             range: 0.0...20.0, format: "%.1f")

                Text(fog.isEnabled
                     ? "Fog applies in Color and Greyscale (Black + White matte stays solid white)."
                     : "Fog is off.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.top, 10)
            }
            .padding(14)
        }
        .frame(width: 280)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // Bridges the shader-side SIMD3 fog colour to SwiftUI's Color (sRGB).
    private var fogColorBinding: Binding<Color> {
        Binding<Color>(
            get: {
                Color(red:   Double(fog.color.x),
                      green: Double(fog.color.y),
                      blue:  Double(fog.color.z))
            },
            set: { newColor in
                let ns = NSColor(newColor).usingColorSpace(.sRGB) ?? NSColor(newColor)
                fog.color = SIMD3<Float>(Float(ns.redComponent),
                                         Float(ns.greenComponent),
                                         Float(ns.blueComponent))
            }
        )
    }
}

// MARK: - Slider row

private struct FogSliderRow: View {
    let label:  String
    @Binding var value: Float
    let range:  ClosedRange<Float>
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: format, value))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.primary)
                    .frame(width: 46, alignment: .trailing)
            }
            Slider(
                value: Binding<Double>(
                    get: { Double(value) },
                    set: { value = Float($0) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound)
            )
        }
    }
}
