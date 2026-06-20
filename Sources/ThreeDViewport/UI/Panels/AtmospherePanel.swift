import SwiftUI
import simd

/// Expand/collapse state of the Atmosphere panel's sections.  Lifted out of the
/// view's @State so it can be saved/restored with the window layout.
final class AtmospherePanelState: ObservableObject {
    @Published var fogExpanded      = true
    @Published var weatherExpanded  = true
    @Published var advancedExpanded = false
    /// True when the fog track is locked (Timeline padlock).  Fog lives on the
    /// viewport (ViewportView.fogLocked), which isn't observable, so a light timer
    /// poll keeps this in sync.  Weather emitters carry their own @Published isLocked.
    @Published var fogLocked = false
    var fogLockedProvider: (() -> Bool)?
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
    /// Fires when a keyframeable fog/particle slider edit ends → auto-keyframe-on-edit.
    var onAutoKeyframeFog:       () -> Void = {}
    var onAutoKeyframeParticles: () -> Void = {}
    /// Drops a Position Mark at the selected emitter's position at the current playhead.
    var onAddMark:               () -> Void = {}

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

                        FogSliderRow(label: "Density", value: $fog.density, range: SceneLimits.densityRange, format: "%.2f",
                                     onEditEnded: onAutoKeyframeFog)
                        KeyframeRow(count: fogKeyCount, onAdd: onStampFog, onClear: onClearFog)
                            .padding(.top, 6)

                        Divider().padding(.vertical, 8)
                        Text("Volume").font(.caption2).foregroundColor(.secondary)
                        AtmoDetailControls(source: fog, varianceKP: \.variance,
                                           positionKP: \.position, sizeKP: \.size, clipboard: clipboard,
                                           onAutoStampPosition: onAutoStampFog,
                                           onEditEnded: onAutoKeyframeFog,
                                           locked: sections.fogLocked)
                        FogSliderRow(label: "Quality", value: $fog.raymarchSteps, range: SceneLimits.fogQualityRange, format: "%.0f")
                    }
                    .padding(.top, 6)
                    .disabled(sections.fogLocked)   // freeze fog edits when the fog track is locked
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
                                .disabled(particleManager.emitters.count <= 1
                                          || (particleManager.selected?.isLocked ?? false))
                            Spacer()
                            Text("\(particleManager.emitters.count) / \(ParticleManager.maxEmitters)")
                                .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 6)

                        Divider().padding(.bottom, 6)

                        // Selected emitter's main + spatial/advanced controls.  Editing
                        // freezes when that emitter is locked; the emitter list above
                        // stays tappable so you can still select a locked emitter.
                        if let fx = particleManager.selected {
                            Group {
                                Button { onAddMark() } label: {
                                    Label("Add Mark", systemImage: "mappin.and.ellipse")
                                }
                                .controlSize(.small)
                                .help("Save a Position Mark at this emitter's position at the playhead")

                                EmitterMainControls(emitter: fx, onStamp: onStampParticles, onClear: onClearParticles,
                                                    onAutoKeyframe: onAutoKeyframeParticles)

                                Divider().padding(.vertical, 8)
                                Text("Shape").font(.caption2).foregroundColor(.secondary)
                                AtmoDetailControls(source: fx, varianceKP: \.variance,
                                                   positionKP: \.position, sizeKP: \.size, clipboard: clipboard,
                                                   onAutoStampPosition: onAutoStampParticles,
                                                   onEditEnded: onAutoKeyframeParticles,
                                                   locked: fx.isLocked)
                                EmitterAdvancedControls(emitter: fx)
                            }
                            .disabled(fx.isLocked)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Weather").font(.subheadline.bold())
                }
            }
            .padding(14)
        }
        .frame(width: 280)
        .background(Color(NSColor.windowBackgroundColor))
        // Keep the fog-lock state in sync with the Timeline padlock (fog lock lives on
        // the viewport, which isn't observable).  Cheap bool read.
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            let lk = sections.fogLockedProvider?() ?? false
            if lk != sections.fogLocked { sections.fogLocked = lk }
        }
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
    var onAutoKeyframe: () -> Void = {}

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

            FogSliderRow(label: "Density", value: $emitter.density, range: SceneLimits.densityRange, format: "%.2f",
                         onEditEnded: onAutoKeyframe)
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
    /// Fires when any of these (keyframeable) variance/position/size sliders settle.
    var onEditEnded: (() -> Void)? = nil
    /// When true, the fog/emitter track is locked: Paste / Zero grey out (Copy stays
    /// live).  The surrounding `.disabled(…)` already freezes the sliders.
    var locked: Bool = false

    private func fbind<V>(_ kp: ReferenceWritableKeyPath<Source, V>) -> Binding<V> {
        Binding(get: { source[keyPath: kp] }, set: { source[keyPath: kp] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FogSliderRow(label: "Variance", value: fbind(varianceKP), range: SceneLimits.varianceRange, format: "%.2f",
                         onEditEnded: onEditEnded)

            Divider().padding(.vertical, 8)
            HStack {
                Text("Position").font(.caption2).foregroundColor(.secondary)
                Spacer()
                CoordCopyPasteButtons(
                    onCopy:   { clipboard.position = source[keyPath: positionKP] },
                    onPaste:  { if let p = clipboard.position { source[keyPath: positionKP] = p } },
                    canPaste: clipboard.position != nil && !locked,
                    onZero:   { source[keyPath: positionKP] = .zero },
                    canZero:  !locked,
                    onAutoStamp: { onAutoStampPosition() })
            }
            FogSliderRow(label: "X", value: fbind(positionKP).x, range: SceneLimits.positionRange, format: "%.1f",
                         onEditEnded: onEditEnded)
            FogSliderRow(label: "Y", value: fbind(positionKP).y, range: SceneLimits.positionRange, format: "%.1f",
                         onEditEnded: onEditEnded)
            FogSliderRow(label: "Z", value: fbind(positionKP).z, range: SceneLimits.positionRange, format: "%.1f",
                         onEditEnded: onEditEnded)

            Divider().padding(.vertical, 8)
            HStack {
                Text("Size").font(.caption2).foregroundColor(.secondary)
                Spacer()
                CoordCopyPasteButtons(
                    onCopy:   { clipboard.size = source[keyPath: sizeKP] },
                    onPaste:  { if let s = clipboard.size { source[keyPath: sizeKP] = s } },
                    canPaste: clipboard.size != nil && !locked)
            }
            FogSliderRow(label: "W", value: fbind(sizeKP).x, range: SceneLimits.fogSizeRange, format: "%.1f",
                         onEditEnded: onEditEnded)
            FogSliderRow(label: "H", value: fbind(sizeKP).y, range: SceneLimits.fogSizeRange, format: "%.1f",
                         onEditEnded: onEditEnded)
            FogSliderRow(label: "D", value: fbind(sizeKP).z, range: SceneLimits.fogSizeRange, format: "%.1f",
                         onEditEnded: onEditEnded)
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
                         range: SceneLimits.emitterSizeRange, format: "%.3f")
            if emitter.type.isSmoke {
                FogSliderRow(label: "Lifetime", value: $emitter.lifetime, range: SceneLimits.emitterLifetimeRange, format: "%.1f")
                FogSliderRow(label: "Growth",   value: $emitter.growth,   range: SceneLimits.emitterGrowthRange,   format: "%.1f")
                FogSliderRow(label: "Opacity",  value: $emitter.baseAlpha, range: SceneLimits.emitterOpacityRange,  format: "%.2f")
            } else {
                FogSliderRow(label: "Fall Speed", value: $emitter.fallSpeed, range: SceneLimits.fallSpeedRange, format: "%.1f")
                FogSliderRow(label: "Streak",     value: $emitter.streak,    range: SceneLimits.streakRange,    format: "%.1f")
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
    /// Optional: fires when an edit gesture ends — wire only on KEYFRAMEABLE sliders.
    var onEditEnded: (() -> Void)? = nil

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
                step: arrowStep(forFormat: format),
                onEditEnded: onEditEnded
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
