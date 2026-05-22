import SwiftUI
import simd

// Floating panel for atmosphere effects.  Phase 1 hosts Fog; later phases will
// add precipitation (rain / snow / sleet) and smoke beneath it.
struct AtmospherePanel: View {

    @ObservedObject var fog: FogSettings
    @ObservedObject var particle: ParticleEffect

    // Stamp / clear actions wired by AppDelegate to ViewportView.
    var onStampFog:       () -> Void = {}
    var onClearFog:       () -> Void = {}
    var onStampParticles: () -> Void = {}
    var onClearParticles: () -> Void = {}

    private var fogKeyCount:      Int { fog.keyframeTrack?.keyframes.count ?? 0 }
    private var particleKeyCount: Int { particle.keyframeTrack?.keyframes.count ?? 0 }

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

                FogSliderRow(label: "Density",  value: $fog.density,  range: 0.0...1.0, format: "%.2f")
                Divider().padding(.vertical, 8)
                FogSliderRow(label: "Variance", value: $fog.variance, range: 0.0...1.0, format: "%.2f")

                Divider().padding(.vertical, 8)
                Text("Position").font(.caption2).foregroundColor(.secondary)
                FogSliderRow(label: "X", value: $fog.position.x, range: -20...20, format: "%.1f")
                FogSliderRow(label: "Y", value: $fog.position.y, range: -20...20, format: "%.1f")
                FogSliderRow(label: "Z", value: $fog.position.z, range: -20...20, format: "%.1f")

                Divider().padding(.vertical, 8)
                Text("Size").font(.caption2).foregroundColor(.secondary)
                FogSliderRow(label: "W", value: $fog.size.x, range: 0.5...40, format: "%.1f")
                FogSliderRow(label: "H", value: $fog.size.y, range: 0.5...40, format: "%.1f")
                FogSliderRow(label: "D", value: $fog.size.z, range: 0.5...40, format: "%.1f")

                Divider().padding(.vertical, 8)
                KeyframeRow(count: fogKeyCount, onAdd: onStampFog, onClear: onClearFog)

                Text(fog.isEnabled
                     ? "Fog volume applies in Color and Greyscale (Black + White matte stays solid white)."
                     : "Fog is off.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.top, 10)

                Divider().padding(.vertical, 14)

                // ── Weather particles ─────────────────────────────────────────
                Text("Weather")
                    .font(.subheadline.bold())
                    .padding(.bottom, 6)

                Toggle(isOn: $particle.isEnabled) {
                    Text("Enabled")
                        .font(.caption)
                        .foregroundColor(particle.isEnabled ? .green : .primary)
                }
                .toggleStyle(.switch)
                .tint(.green)
                .padding(.bottom, 10)

                Picker("Type", selection: $particle.type) {
                    ForEach(ParticleType.allCases, id: \.self) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.bottom, 10)

                ColorPicker("Color", selection: particleColorBinding, supportsOpacity: false)
                    .font(.caption)
                    .padding(.bottom, 10)

                FogSliderRow(label: "Density",  value: $particle.density,  range: 0.0...1.0, format: "%.2f")
                Divider().padding(.vertical, 8)
                FogSliderRow(label: "Variance", value: $particle.variance, range: 0.0...1.0, format: "%.2f")

                Divider().padding(.vertical, 8)
                Text("Position").font(.caption2).foregroundColor(.secondary)
                FogSliderRow(label: "X", value: $particle.position.x, range: -20...20, format: "%.1f")
                FogSliderRow(label: "Y", value: $particle.position.y, range: -20...20, format: "%.1f")
                FogSliderRow(label: "Z", value: $particle.position.z, range: -20...20, format: "%.1f")

                Divider().padding(.vertical, 8)
                Text("Size").font(.caption2).foregroundColor(.secondary)
                FogSliderRow(label: "W", value: $particle.size.x, range: 0.5...40, format: "%.1f")
                FogSliderRow(label: "H", value: $particle.size.y, range: 0.5...40, format: "%.1f")
                FogSliderRow(label: "D", value: $particle.size.z, range: 0.5...40, format: "%.1f")

                Divider().padding(.vertical, 8)
                KeyframeRow(count: particleKeyCount, onAdd: onStampParticles, onClear: onClearParticles)

                Text("Particles are depth-occluded by the scene and render white in Black + White matte.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.top, 10)
            }
            .padding(14)
        }
        .frame(width: 280)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var particleColorBinding: Binding<Color> {
        Binding<Color>(
            get: {
                Color(red:   Double(particle.color.x),
                      green: Double(particle.color.y),
                      blue:  Double(particle.color.z))
            },
            set: { newColor in
                let ns = NSColor(newColor).usingColorSpace(.sRGB) ?? NSColor(newColor)
                particle.color = SIMD3<Float>(Float(ns.redComponent),
                                              Float(ns.greenComponent),
                                              Float(ns.blueComponent))
            }
        )
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

// MARK: - Keyframe row

/// "Add Keyframe" + count + clear, shared by the Fog and Weather sections.
private struct KeyframeRow: View {
    let count:   Int
    let onAdd:   () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack {
            Button(action: onAdd) {
                Label("Add Keyframe", systemImage: "diamond.fill")
            }
            .font(.caption)
            Spacer()
            Text("\(count) key\(count == 1 ? "" : "s")")
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
            Button(action: onClear) {
                Image(systemName: "trash")
            }
            .font(.caption)
            .disabled(count == 0)
        }
    }
}
