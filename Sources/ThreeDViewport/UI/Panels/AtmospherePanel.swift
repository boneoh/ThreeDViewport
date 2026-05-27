import SwiftUI
import simd

/// Expand/collapse state of the Atmosphere panel's sections.  Lifted out of the
/// view's @State so it can be saved/restored with the window layout.
final class AtmospherePanelState: ObservableObject {
    @Published var fogExpanded      = true
    @Published var weatherExpanded  = true
    @Published var advancedExpanded = false
}

// Floating panel for atmosphere effects.  Three collapsible sections:
//   • Fog      — single fog volume (Enabled / Color / Density + keyframes).
//   • Weather  — a list of particle emitters (+/− to add/remove, click to select)
//                with the selected emitter's main controls below.
//   • Advanced — the spatial detail (Position / Size / Variance) for the fog
//                volume and the selected emitter.
struct AtmospherePanel: View {

    @ObservedObject var fog: FogSettings
    @ObservedObject var particleManager: ParticleManager
    @ObservedObject var clipboard: CoordinateClipboard
    @ObservedObject var sections: AtmospherePanelState

    // Stamp / clear actions wired by AppDelegate to ViewportView.  The particle
    // ones target the manager's currently-selected emitter.
    var onStampFog:       () -> Void = {}
    var onClearFog:       () -> Void = {}
    var onStampParticles: () -> Void = {}
    var onClearParticles: () -> Void = {}
    /// Conditional auto-stamps for the Position groups (fired after Paste/Z).
    /// AppDelegate wires these to stamp only when the relevant track is non-empty.
    var onAutoStampFog:       () -> Void = {}
    var onAutoStampParticles: () -> Void = {}

    private var fogKeyCount: Int { fog.keyframeTrack?.keyframes.count ?? 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // ── Header ────────────────────────────────────────────────────
                HStack {
                    Image(systemName: "cloud.fog.fill")
                        .foregroundColor(fog.isEnabled ? .green : .accentColor)
                    Text("Atmosphere").font(.headline)
                    Spacer()
                }
                .padding(.bottom, 8)
                Divider().padding(.bottom, 6)

                // ── Fog ─────────────────────────────────────────────────────────
                DisclosureGroup(isExpanded: $sections.fogExpanded) {
                    VStack(alignment: .leading, spacing: 0) {
                        Toggle(isOn: $fog.isEnabled) {
                            Text("Enabled").font(.caption)
                                .foregroundColor(fog.isEnabled ? .green : .primary)
                        }
                        .toggleStyle(.switch).tint(.green)
                        .environment(\.controlActiveState, .active)
                        .padding(.bottom, 8)

                        ColorPicker("Color", selection: atmoColorBinding({ fog.color }, { fog.color = $0 }),
                                    supportsOpacity: false)
                            .font(.caption).padding(.bottom, 8)

                        FogSliderRow(label: "Density", value: $fog.density, range: 0.0...1.0, format: "%.2f")
                        KeyframeRow(count: fogKeyCount, onAdd: onStampFog, onClear: onClearFog)
                            .padding(.top, 6)
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Fog").font(.subheadline.bold())
                }

                Divider().padding(.vertical, 8)

                // ── Weather ─────────────────────────────────────────────────────
                DisclosureGroup(isExpanded: $sections.weatherExpanded) {
                    VStack(alignment: .leading, spacing: 0) {

                        // Emitter list
                        ForEach(Array(particleManager.emitters.enumerated()), id: \.offset) { idx, fx in
                            EmitterRow(emitter: fx,
                                       isSelected: idx == particleManager.selectedIndex,
                                       onSelect: { particleManager.selectedIndex = idx })
                        }

                        // Add / remove
                        HStack(spacing: 8) {
                            Button { particleManager.addEmitter() } label: { Image(systemName: "plus") }
                                .disabled(particleManager.emitters.count >= ParticleManager.maxEmitters)
                            Button { particleManager.removeEmitter(at: particleManager.selectedIndex) } label: { Image(systemName: "minus") }
                                .disabled(particleManager.emitters.count <= 1)
                            Spacer()
                            Text("\(particleManager.emitters.count) / \(ParticleManager.maxEmitters)")
                                .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 6)

                        Divider().padding(.bottom, 6)

                        // Selected emitter's main controls
                        if let fx = particleManager.selected {
                            EmitterMainControls(emitter: fx, onStamp: onStampParticles, onClear: onClearParticles)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Weather").font(.subheadline.bold())
                }

                Divider().padding(.vertical, 8)

                // ── Advanced (spatial detail) ────────────────────────────────────
                DisclosureGroup(isExpanded: $sections.advancedExpanded) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Fog Volume").font(.caption2).foregroundColor(.secondary).padding(.top, 6)
                        AtmoDetailControls(source: fog, varianceKP: \.variance,
                                           positionKP: \.position, sizeKP: \.size, clipboard: clipboard,
                                           onAutoStampPosition: onAutoStampFog)
                        FogSliderRow(label: "Quality", value: $fog.raymarchSteps, range: 8...96, format: "%.0f")

                        Divider().padding(.vertical, 8)

                        Text("Weather Emitter").font(.caption2).foregroundColor(.secondary)
                        if let fx = particleManager.selected {
                            AtmoDetailControls(source: fx, varianceKP: \.variance,
                                               positionKP: \.position, sizeKP: \.size, clipboard: clipboard,
                                               onAutoStampPosition: onAutoStampParticles)
                            EmitterAdvancedControls(emitter: fx)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Advanced").font(.subheadline.bold())
                }
            }
            .padding(14)
        }
        .frame(width: 280)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Emitter list row

private struct EmitterRow: View {
    @ObservedObject var emitter: ParticleEffect
    let isSelected: Bool
    let onSelect:   () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: emitter.isEnabled ? "circle.fill" : "circle")
                .font(.system(size: 8))
                .foregroundColor(emitter.isEnabled ? .green : .secondary)
            Text(emitter.type.displayName).font(.caption)
            Spacer()
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - Selected emitter — main controls

private struct EmitterMainControls: View {
    @ObservedObject var emitter: ParticleEffect
    let onStamp: () -> Void
    let onClear: () -> Void

    private var keyCount: Int { emitter.keyframeTrack?.keyframes.count ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: $emitter.isEnabled) {
                Text("Enabled").font(.caption)
                    .foregroundColor(emitter.isEnabled ? .green : .primary)
            }
            .toggleStyle(.switch).tint(.green)
            .environment(\.controlActiveState, .active)
            .padding(.bottom, 8)

            Picker("Type", selection: $emitter.type) {
                ForEach(ParticleType.allCases, id: \.self) { t in Text(t.displayName).tag(t) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(.bottom, 8)

            ColorPicker("Color", selection: atmoColorBinding({ emitter.color }, { emitter.color = $0 }),
                        supportsOpacity: false)
                .font(.caption).padding(.bottom, 8)

            FogSliderRow(label: "Density", value: $emitter.density, range: 0.0...1.0, format: "%.2f")
            KeyframeRow(count: keyCount, onAdd: onStamp, onClear: onClear).padding(.top, 6)
        }
    }
}

// MARK: - Shared detail controls (Variance + Position + Size)

// Generic over the source ObservableObject (FogSettings or ParticleEffect) so it
// re-renders whenever the source's values change — on paste, scrub-sync, etc.
private struct AtmoDetailControls<Source: ObservableObject>: View {
    @ObservedObject var source: Source
    let varianceKP: ReferenceWritableKeyPath<Source, Float>
    let positionKP: ReferenceWritableKeyPath<Source, SIMD3<Float>>
    let sizeKP:     ReferenceWritableKeyPath<Source, SIMD3<Float>>
    @ObservedObject var clipboard: CoordinateClipboard
    /// Fires after a Paste or Z on this section's Position group.  Wired by
    /// AtmospherePanel to the source-appropriate conditional stamp callback.
    var onAutoStampPosition: () -> Void = {}

    private func fbind<V>(_ kp: ReferenceWritableKeyPath<Source, V>) -> Binding<V> {
        Binding(get: { source[keyPath: kp] }, set: { source[keyPath: kp] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FogSliderRow(label: "Variance", value: fbind(varianceKP), range: 0.0...1.0, format: "%.2f")

            Divider().padding(.vertical, 8)
            HStack {
                Text("Position").font(.caption2).foregroundColor(.secondary)
                Spacer()
                CoordCopyPasteButtons(
                    onCopy:   { clipboard.position = source[keyPath: positionKP] },
                    onPaste:  { if let p = clipboard.position { source[keyPath: positionKP] = p } },
                    canPaste: clipboard.position != nil,
                    onZero:   { source[keyPath: positionKP] = .zero },
                    canZero:  true,
                    onAutoStamp: { onAutoStampPosition() })
            }
            FogSliderRow(label: "X", value: fbind(positionKP).x, range: -100...100, format: "%.1f")
            FogSliderRow(label: "Y", value: fbind(positionKP).y, range: -100...100, format: "%.1f")
            FogSliderRow(label: "Z", value: fbind(positionKP).z, range: -100...100, format: "%.1f")

            Divider().padding(.vertical, 8)
            HStack {
                Text("Size").font(.caption2).foregroundColor(.secondary)
                Spacer()
                CoordCopyPasteButtons(
                    onCopy:   { clipboard.size = source[keyPath: sizeKP] },
                    onPaste:  { if let s = clipboard.size { source[keyPath: sizeKP] = s } },
                    canPaste: clipboard.size != nil)
            }
            FogSliderRow(label: "W", value: fbind(sizeKP).x, range: 0.5...40, format: "%.1f")
            FogSliderRow(label: "H", value: fbind(sizeKP).y, range: 0.5...40, format: "%.1f")
            FogSliderRow(label: "D", value: fbind(sizeKP).z, range: 0.5...40, format: "%.1f")
        }
    }
}

// MARK: - Selected emitter — advanced (type-specific) controls

private struct EmitterAdvancedControls: View {
    @ObservedObject var emitter: ParticleEffect

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.vertical, 8)
            FogSliderRow(label: "Particle Size", value: $emitter.particleSize,
                         range: 0.005...0.5, format: "%.3f")
            if emitter.type.isSmoke {
                FogSliderRow(label: "Lifetime", value: $emitter.lifetime, range: 0.5...12,  format: "%.1f")
                FogSliderRow(label: "Growth",   value: $emitter.growth,   range: 0.0...12,  format: "%.1f")
                FogSliderRow(label: "Opacity",  value: $emitter.baseAlpha, range: 0.02...1.0, format: "%.2f")
            } else {
                FogSliderRow(label: "Fall Speed", value: $emitter.fallSpeed, range: 0.0...20, format: "%.1f")
                FogSliderRow(label: "Streak",     value: $emitter.streak,    range: 1.0...16, format: "%.1f")
            }
        }
    }
}

// MARK: - Bindings

/// Bridges a SIMD3 display-space colour to SwiftUI's Color (sRGB).
private func atmoColorBinding(_ get: @escaping () -> SIMD3<Float>,
                             _ set: @escaping (SIMD3<Float>) -> Void) -> Binding<Color> {
    Binding<Color>(
        get: { let c = get(); return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z)) },
        set: { newColor in
            let ns = NSColor(newColor).usingColorSpace(.sRGB) ?? NSColor(newColor)
            set(SIMD3<Float>(Float(ns.redComponent), Float(ns.greenComponent), Float(ns.blueComponent)))
        })
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
                Text(label).font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(String(format: format, value))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.primary)
                    .frame(width: 46, alignment: .trailing)
            }
            TunableSlider(
                value: Binding<Double>(get: { Double(value) }, set: { value = Float($0) }),
                range: Double(range.lowerBound)...Double(range.upperBound),
                step: arrowStep(forFormat: format)
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
            Button(action: onAdd) { Label("Add Keyframe", systemImage: "diamond.fill") }
                .font(.caption)
            Spacer()
            Text("\(count) key\(count == 1 ? "" : "s")")
                .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
            Button(action: onClear) { Image(systemName: "trash") }
                .font(.caption).disabled(count == 0)
        }
    }
}
