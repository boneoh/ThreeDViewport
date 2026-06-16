import SwiftUI
import AppKit
import simd

// MARK: - Color ↔ SIMD3<Float> helpers

private func simd3ToColor(_ v: SIMD3<Float>) -> Color {
    return Color(red: Double(v.x), green: Double(v.y), blue: Double(v.z))
}

private func colorToSIMD3(_ c: Color) -> SIMD3<Float> {
    let ns = NSColor(c).usingColorSpace(.sRGB) ?? NSColor(c)
    return SIMD3<Float>(Float(ns.redComponent),
                        Float(ns.greenComponent),
                        Float(ns.blueComponent))
}

// Binding bridge: SIMD3<Float> ↔ SwiftUI Color
private func colorBinding(get: @escaping () -> SIMD3<Float>,
                          set: @escaping (SIMD3<Float>) -> Void) -> Binding<Color> {
    Binding<Color>(
        get: { simd3ToColor(get()) },
        set: { set(colorToSIMD3($0)) }
    )
}

// MARK: - Panel

// Phase 7: Floating inspector for lights and background configuration.
// Observes LightManager and BackgroundConfig directly — bindings update the
// renderer on the next frame automatically.
struct LightsInspectorPanel: View {

    @ObservedObject var lightManager:     LightManager
    @ObservedObject var backgroundConfig: BackgroundConfig
    @ObservedObject var renderSettings:   RenderSettings
    @ObservedObject var clipboard:        CoordinateClipboard
    let camera: CameraController
    /// Fires after a Paste or Z click on a light's Position/Target.  AppDelegate
    /// wires it to conditionally stamp a light keyframe at the current playhead
    /// for the given light index (only if its track already has keyframes).
    var onAutoStampLight: (Int) -> Void = { _ in }
    /// Fires when a keyframeable light slider edit ends → auto-keyframe-on-edit.
    var onAutoKeyframeLight: (Int) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                renderingSection
                Divider().padding(.vertical, 8)
                backgroundSection
                Divider().padding(.vertical, 8)
                lightsSection
            }
            .padding(12)
        }
        .frame(width: 280)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Rendering section

    private var renderingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rendering")
                .font(.headline)
                .padding(.bottom, 2)

            Picker("Render mode", selection: $renderSettings.colorMode) {
                Text("Greyscale").tag(RenderColorMode.greyscale)
                Text("Color").tag(RenderColorMode.color)
                Text("B + W").tag(RenderColorMode.blackWhite)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // Phase C: image-based-lighting intensity.
            HStack {
                Text("IBL")
                TunableSlider(
                    value: Binding<Double>(
                        get: { Double(renderSettings.iblIntensity) },
                        set: { renderSettings.iblIntensity = Float($0) }),
                    range: 0.0...2.0,
                    step: 0.01)
                Text(String(format: "%.2f", renderSettings.iblIntensity))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }

    // MARK: - Background section

    private var backgroundSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Background")
                .font(.headline)
                .padding(.bottom, 2)

            // Mode picker
            Picker("", selection: $backgroundConfig.mode) {
                ForEach(BackgroundMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch backgroundConfig.mode {
            case .solid:
                LabeledColorRow(
                    label: "Color",
                    binding: colorBinding(
                        get: { self.backgroundConfig.solidColor },
                        set: { self.backgroundConfig.solidColor = $0 }
                    )
                )

            case .gradient:
                LabeledColorRow(
                    label: "Top",
                    binding: colorBinding(
                        get: { self.backgroundConfig.gradientTop },
                        set: { self.backgroundConfig.gradientTop = $0 }
                    )
                )
                LabeledColorRow(
                    label: "Bottom",
                    binding: colorBinding(
                        get: { self.backgroundConfig.gradientBottom },
                        set: { self.backgroundConfig.gradientBottom = $0 }
                    )
                )

            case .environment:
                SliderRow(label: "Intensity",
                          value: $backgroundConfig.environmentIntensity,
                          range: 0...4, format: "%.2f")
                SliderRow(label: "Horizon",
                          value: $backgroundConfig.environmentHorizon,
                          range: -1...1, format: "%.2f")
                Text("Uses the IBL environment as a backdrop. Horizon shifts it "
                    + "vertically (backdrop only, not the lighting).")
                    .font(.caption2).foregroundStyle(.secondary)

                Toggle(isOn: $backgroundConfig.excludeEnvironmentFromFeedback) {
                    Text("Exclude from feedback")
                        .font(.caption)
                        .foregroundColor(backgroundConfig.excludeEnvironmentFromFeedback ? .green : .primary)
                }
                .toggleStyle(.switch).tint(.green)
                .environment(\.controlActiveState, .active)
                .help("Keep the skybox crisp behind the trailing foreground when "
                    + "feedback is on, instead of letting it smear with camera motion.")
            }
        }
    }

    // MARK: - Lights section

    private var lightsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with add button
            HStack {
                Text("Lights")
                    .font(.headline)
                Spacer()
                Menu {
                    ForEach(LightType.allCases, id: \.self) { type in
                        Button(type.displayName) {
                            addLight(type: type)
                        }
                    }
                } label: {
                    Image(systemName: "plus.circle")
                        .foregroundColor(.accentColor)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(lightManager.lights.count >= LightManager.maxLights)
            }
            .padding(.bottom, 2)

            // Light selector — a dropdown scales to the many lights an Import Project
            // can bring in (a flat list would run off the panel).  Names match the
            // Timeline Editor's lane labels ("Light 1 - Directional").
            if !lightManager.lights.isEmpty {
                HStack(spacing: 6) {
                    Picker("", selection: Binding<Int>(
                        get: { min(lightManager.selectedIndex, lightManager.lights.count - 1) },
                        set: { lightManager.selectedIndex = $0 }
                    )) {
                        ForEach(lightManager.lights.indices, id: \.self) { i in
                            Label(lightName(at: i), systemImage: lightManager.lights[i].type.systemImage)
                                .tag(i)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)

                    // Remove the selected light (never remove the last one).
                    Button {
                        lightManager.removeLight(at: lightManager.selectedIndex)
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundColor(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .disabled(lightManager.lights.count <= 1
                              || lightManager.lights[min(lightManager.selectedIndex, lightManager.lights.count - 1)].isLocked)
                    .help("Remove the selected light")
                }
            }

            // Selected light detail editor
            if lightManager.selectedIndex < lightManager.lights.count {
                Divider().padding(.vertical, 4)
                // Editing controls freeze when the selected light is locked; the light
                // selector dropdown above stays enabled so you can still browse lights.
                lightDetailEditor(index: lightManager.selectedIndex)
                    .disabled(lightManager.lights[lightManager.selectedIndex].isLocked)
                    // Stable identity per selection: when a light is removed and the
                    // index clamps, SwiftUI replaces this subtree instead of diffing the
                    // old editor's bindings (which would index the removed light → crash).
                    .id(lightManager.selectedIndex)
            }
        }
    }

    /// "Light N - <Type>" — mirrors the Timeline Editor's light lane label.
    private func lightName(at i: Int) -> String {
        guard i >= 0, i < lightManager.lights.count else { return "Light \(i + 1)" }
        return "Light \(i + 1) - \(lightManager.lights[i].type.displayName)"
    }

    /// Bounds-safe two-way binding to a property of light `i`.  Rapid light deletion can
    /// leave a SwiftUI binding holding a stale index between the delete and the rebuild;
    /// the get clamps to a valid light (the view is being torn down anyway) and the set
    /// no-ops when out of range — so neither traps with an index-out-of-range.
    private func lightBinding<V>(_ i: Int, _ kp: WritableKeyPath<LightConfig, V>) -> Binding<V> {
        Binding(
            get: {
                let lights = lightManager.lights
                let idx = lights.isEmpty ? 0 : min(max(i, 0), lights.count - 1)
                return lights[idx][keyPath: kp]
            },
            set: { v in
                if i >= 0, i < lightManager.lights.count { lightManager.lights[i][keyPath: kp] = v }
            })
    }

    /// The light at `i`, or nil if the index is stale (post-delete).
    private func lightSafe(_ i: Int) -> LightConfig? {
        (i >= 0 && i < lightManager.lights.count) ? lightManager.lights[i] : nil
    }

    // MARK: - Light detail editor

    @ViewBuilder
    private func lightDetailEditor(index i: Int) -> some View {
        // Clamp for the read-only `light.type` branch checks below.  Every editable
        // control uses lightBinding/lightSafe, which are individually bounds-safe — so a
        // transient stale index during rapid deletes can't trap.
        let light = lightManager.lights[min(max(i, 0), max(0, lightManager.lights.count - 1))]

        VStack(alignment: .leading, spacing: 8) {

            // Enabled toggle — prominent at the top so you can solo/mute lights quickly
            HStack {
                Text(lightName(at: i))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Toggle("Enabled", isOn: lightBinding(i, \.isEnabled))
                .toggleStyle(.checkbox)
                .font(.subheadline)
                .environment(\.controlActiveState, .active)
            }

            // Type picker
            Picker("Type", selection: lightBinding(i, \.type)) {
                ForEach(LightType.allCases, id: \.self) { t in
                    Label(t.displayName, systemImage: t.systemImage).tag(t)
                }
            }
            .pickerStyle(.menu)

            // Color
            LabeledColorRow(
                label: "Color",
                binding: colorBinding(
                    get: { lightSafe(i)?.color ?? .zero },
                    set: { if i >= 0, i < lightManager.lights.count { lightManager.lights[i].color = $0 } }
                )
            )

            // Intensity
            SliderRow(label: "Intensity",
                      value: lightBinding(i, \.intensity),
                      range: 0...10,
                      format: "%.2f",
                      onEditEnded: { onAutoKeyframeLight(i) })

            // Position — every light except ambient (directional uses it as the
            // aim anchor: direction is derived from Position → Target).
            if light.type != .ambient {
                GroupBox {
                    VStack(spacing: 4) {
                        SliderRow(label: "X", value: lightBinding(i, \.position.x),
                                  range: -100...100, format: "%.2f",
                                  onEditEnded: { onAutoKeyframeLight(i) })
                        SliderRow(label: "Y", value: lightBinding(i, \.position.y),
                                  range: -100...100, format: "%.2f",
                                  onEditEnded: { onAutoKeyframeLight(i) })
                        SliderRow(label: "Z", value: lightBinding(i, \.position.z),
                                  range: -100...100, format: "%.2f",
                                  onEditEnded: { onAutoKeyframeLight(i) })
                    }
                } label: {
                    HStack {
                        Text("Position")
                        Spacer()
                        CoordCopyPasteButtons(
                            onCopy:   { if let l = lightSafe(i) { clipboard.position = l.position } },
                            onPaste:  { if let p = clipboard.position, i < lightManager.lights.count { lightManager.lights[i].position = p } },
                            canPaste: clipboard.position != nil,
                            onZero:   { if i < lightManager.lights.count { lightManager.lights[i].position = .zero } },
                            canZero:  true,
                            onAutoStamp: { onAutoStampLight(i) })
                    }
                }
            }

            // Target — directional / spot / laser (light aims from Position toward
            // Target; the world-space aim point uses the Position clipboard channel).
            if light.type == .directional || light.type == .spot || light.type == .laser {
                GroupBox {
                    VStack(spacing: 4) {
                        SliderRow(label: "X", value: lightBinding(i, \.target.x),
                                  range: -100...100, format: "%.2f",
                                  onEditEnded: { onAutoKeyframeLight(i) })
                        SliderRow(label: "Y", value: lightBinding(i, \.target.y),
                                  range: -100...100, format: "%.2f",
                                  onEditEnded: { onAutoKeyframeLight(i) })
                        SliderRow(label: "Z", value: lightBinding(i, \.target.z),
                                  range: -100...100, format: "%.2f",
                                  onEditEnded: { onAutoKeyframeLight(i) })
                    }
                } label: {
                    HStack {
                        Text("Target")
                        Spacer()
                        CoordCopyPasteButtons(
                            onCopy:   { if let l = lightSafe(i) { clipboard.position = l.target } },
                            onPaste:  { if let p = clipboard.position, i < lightManager.lights.count { lightManager.lights[i].target = p } },
                            canPaste: clipboard.position != nil,
                            onZero:   { if i < lightManager.lights.count { lightManager.lights[i].target = .zero } },
                            canZero:  true,
                            onAutoStamp: { onAutoStampLight(i) })
                    }
                }
            }

            // Cone angles — spot / laser
            if light.type == .spot || light.type == .laser {
                GroupBox("Cone (radians)") {
                    VStack(spacing: 4) {
                        SliderRow(label: "Inner", value: lightBinding(i, \.innerConeAngle),
                                  range: 0...Float.pi / 2, format: "%.3f")
                        SliderRow(label: "Outer", value: lightBinding(i, \.outerConeAngle),
                                  range: 0...Float.pi / 2, format: "%.3f")
                    }
                }
            }

            // Range — point / spot / laser
            if light.type == .point || light.type == .spot || light.type == .laser {
                SliderRow(label: "Range", value: lightBinding(i, \.range),
                          range: 0...50, format: "%.1f",
                          onEditEnded: { onAutoKeyframeLight(i) })
            }

            // Laser beam visuals
            if light.type == .laser {
                Divider()
                GroupBox("Beam") {
                    VStack(spacing: 6) {
                        SliderRow(label: "Thickness", value: lightBinding(i, \.beamThickness),
                                  range: 1...30, format: "%.0f",
                                  onEditEnded: { onAutoKeyframeLight(i) })
                        Toggle("Exclude from feedback", isOn: lightBinding(i, \.excludeBeamFromFeedback))
                            .font(.caption)
                            .toggleStyle(.checkbox)
                            .environment(\.controlActiveState, .active)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func addLight(type: LightType) {
        let base: LightConfig
        switch type {
        case .ambient:     base = .defaultAmbient
        case .directional: base = .defaultDirectional
        case .point:       base = .defaultPoint
        case .spot:        base = .defaultSpot
        case .laser:       base = .defaultLaser
        }
        lightManager.addLight(placedForCamera(base))
    }

    /// Positions a new light slightly above and to the right of the camera and
    /// aims it at the camera's current target (one-click scene-setup).
    /// • Ambient — returned unchanged (no position or target).
    /// • Directional — position + target set (aim derived; position is just the anchor).
    /// • Point — only position is set (no aim target).
    /// • Spot / Laser — both position and target are set.
    private func placedForCamera(_ light: LightConfig) -> LightConfig {
        var l = light
        let offset = camera.distance * 0.2
        let pos    = camera.eyePosition
                   + camera.rightVector * offset
                   + camera.upVector    * offset
        switch l.type {
        case .ambient:
            return l
        case .directional:
            l.position = pos
            l.target   = camera.target
        case .point:
            l.position = pos
        case .spot, .laser:
            l.position = pos
            l.target   = camera.target
        }
        return l
    }
}

// MARK: - Reusable sub-views

// A row with a fixed-width label and a ColorPicker.
struct LabeledColorRow: View {
    let label: String
    let binding: Binding<Color>

    var body: some View {
        HStack {
            Text(label)
                .frame(width: 56, alignment: .leading)
                .foregroundColor(.secondary)
                .font(.caption)
            ColorPicker("", selection: binding, supportsOpacity: false)
                .labelsHidden()
        }
    }
}

// A row with a label, a Slider, and a numeric readout.
struct SliderRow: View {
    let label: String
    let value: Binding<Float>
    let range: ClosedRange<Float>
    let format: String
    /// Optional: fires when an edit gesture ends (used to auto-keyframe).  Wire it only
    /// on KEYFRAMEABLE properties (transform/opacity/intensity/colour/etc.).
    var onEditEnded: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .frame(width: 46, alignment: .leading)
                .foregroundColor(.secondary)
                .font(.caption)
            TunableSlider(
                value: Binding<Double>(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Float($0) }),
                range: Double(range.lowerBound)...Double(range.upperBound),
                step: arrowStep(forFormat: format),
                onEditEnded: onEditEnded)
            Text(String(format: format, value.wrappedValue))
                .frame(width: 46, alignment: .trailing)
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
        }
    }
}
