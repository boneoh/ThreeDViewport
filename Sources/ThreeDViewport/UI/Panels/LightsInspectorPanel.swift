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
    let camera: CameraController

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
                Slider(value: $renderSettings.iblIntensity, in: 0.0...2.0)
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

            // Light list
            ForEach(lightManager.lights.indices, id: \.self) { i in
                lightRow(at: i)
            }

            // Selected light detail editor
            if lightManager.selectedIndex < lightManager.lights.count {
                Divider().padding(.vertical, 4)
                lightDetailEditor(index: lightManager.selectedIndex)
            }
        }
    }

    // MARK: - Light row (list item)

    private func lightRow(at i: Int) -> some View {
        let light = lightManager.lights[i]
        let isSelected = i == lightManager.selectedIndex

        return HStack(spacing: 6) {
            Image(systemName: light.type.systemImage)
                .frame(width: 16)
                .foregroundColor(isSelected ? .accentColor : .secondary)

            Text(light.type.displayName)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundColor(isSelected ? .primary : .secondary)

            Spacer()

            // Enabled toggle
            Toggle("", isOn: Binding<Bool>(
                get: { lightManager.lights[i].isEnabled },
                set: { lightManager.lights[i].isEnabled = $0 }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            // Remove button (never remove last light)
            Button {
                lightManager.removeLight(at: i)
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundColor(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .disabled(lightManager.lights.count <= 1)
        }
        .padding(6)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture {
            lightManager.selectedIndex = i
        }
    }

    // MARK: - Light detail editor

    @ViewBuilder
    private func lightDetailEditor(index i: Int) -> some View {
        let light = lightManager.lights[i]

        VStack(alignment: .leading, spacing: 8) {

            // Enabled toggle — prominent at the top so you can solo/mute lights quickly
            HStack {
                Text(light.type.displayName + " Light")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Toggle("Enabled", isOn: Binding<Bool>(
                    get: { lightManager.lights[i].isEnabled },
                    set: { lightManager.lights[i].isEnabled = $0 }
                ))
                .toggleStyle(.checkbox)
                .font(.subheadline)
            }

            // Type picker
            Picker("Type", selection: Binding<LightType>(
                get: { lightManager.lights[i].type },
                set: { lightManager.lights[i].type = $0 }
            )) {
                ForEach(LightType.allCases, id: \.self) { t in
                    Label(t.displayName, systemImage: t.systemImage).tag(t)
                }
            }
            .pickerStyle(.menu)

            // Color
            LabeledColorRow(
                label: "Color",
                binding: colorBinding(
                    get: { lightManager.lights[i].color },
                    set: { lightManager.lights[i].color = $0 }
                )
            )

            // Intensity
            SliderRow(label: "Intensity",
                      value: Binding<Float>(
                          get: { lightManager.lights[i].intensity },
                          set: { lightManager.lights[i].intensity = $0 }),
                      range: 0...10,
                      format: "%.2f")

            // Position — point / spot / laser
            if light.type == .point || light.type == .spot || light.type == .laser {
                GroupBox("Position") {
                    VStack(spacing: 4) {
                        SliderRow(label: "X",
                                  value: Binding<Float>(
                                      get: { lightManager.lights[i].position.x },
                                      set: { lightManager.lights[i].position.x = $0 }),
                                  range: -10...10, format: "%.2f")
                        SliderRow(label: "Y",
                                  value: Binding<Float>(
                                      get: { lightManager.lights[i].position.y },
                                      set: { lightManager.lights[i].position.y = $0 }),
                                  range: -10...10, format: "%.2f")
                        SliderRow(label: "Z",
                                  value: Binding<Float>(
                                      get: { lightManager.lights[i].position.z },
                                      set: { lightManager.lights[i].position.z = $0 }),
                                  range: -10...10, format: "%.2f")
                    }
                }
            }

            // Direction — directional / spot / laser
            if light.type == .directional || light.type == .spot || light.type == .laser {
                GroupBox("Direction") {
                    VStack(spacing: 4) {
                        SliderRow(label: "X",
                                  value: Binding<Float>(
                                      get: { lightManager.lights[i].direction.x },
                                      set: { lightManager.lights[i].direction.x = $0; normalizeDirection(at: i) }),
                                  range: -1...1, format: "%.3f")
                        SliderRow(label: "Y",
                                  value: Binding<Float>(
                                      get: { lightManager.lights[i].direction.y },
                                      set: { lightManager.lights[i].direction.y = $0; normalizeDirection(at: i) }),
                                  range: -1...1, format: "%.3f")
                        SliderRow(label: "Z",
                                  value: Binding<Float>(
                                      get: { lightManager.lights[i].direction.z },
                                      set: { lightManager.lights[i].direction.z = $0; normalizeDirection(at: i) }),
                                  range: -1...1, format: "%.3f")
                    }
                }
            }

            // Cone angles — spot / laser
            if light.type == .spot || light.type == .laser {
                GroupBox("Cone (radians)") {
                    VStack(spacing: 4) {
                        SliderRow(label: "Inner",
                                  value: Binding<Float>(
                                      get: { lightManager.lights[i].innerConeAngle },
                                      set: { lightManager.lights[i].innerConeAngle = $0 }),
                                  range: 0...Float.pi / 2, format: "%.3f")
                        SliderRow(label: "Outer",
                                  value: Binding<Float>(
                                      get: { lightManager.lights[i].outerConeAngle },
                                      set: { lightManager.lights[i].outerConeAngle = $0 }),
                                  range: 0...Float.pi / 2, format: "%.3f")
                    }
                }
            }

            // Range — point / spot / laser
            if light.type == .point || light.type == .spot || light.type == .laser {
                SliderRow(label: "Range",
                          value: Binding<Float>(
                              get: { lightManager.lights[i].range },
                              set: { lightManager.lights[i].range = $0 }),
                          range: 0...50, format: "%.1f")
            }

            // Laser beam visuals
            if light.type == .laser {
                Divider()
                GroupBox("Beam") {
                    VStack(spacing: 6) {
                        SliderRow(label: "Thickness",
                                  value: Binding<Float>(
                                      get: { lightManager.lights[i].beamThickness },
                                      set: { lightManager.lights[i].beamThickness = $0 }),
                                  range: 1...30, format: "%.0f")
                        Toggle("Exclude from feedback",
                               isOn: Binding<Bool>(
                                   get: { lightManager.lights[i].excludeBeamFromFeedback },
                                   set: { lightManager.lights[i].excludeBeamFromFeedback = $0 }))
                            .font(.caption)
                            .toggleStyle(.checkbox)
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
    /// • Ambient — returned unchanged (no position or direction).
    /// • Directional — only direction is set (it has no position).
    /// • Point — only position is set (it has no direction).
    /// • Spot / Laser — both position and direction are set.
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
            l.direction = simd_normalize(camera.target - pos)
        case .point:
            l.position = pos
        case .spot, .laser:
            l.position  = pos
            l.direction = simd_normalize(camera.target - pos)
        }
        return l
    }

    private func normalizeDirection(at i: Int) {
        let d = lightManager.lights[i].direction
        let len = sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
        if len > 0.0001 {
            lightManager.lights[i].direction = d / len
        }
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

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .frame(width: 46, alignment: .leading)
                .foregroundColor(.secondary)
                .font(.caption)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue))
                .frame(width: 46, alignment: .trailing)
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
        }
    }
}
