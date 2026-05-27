import SwiftUI
import AppKit

struct ModelInspectorPanel: View {

    @ObservedObject var state: ModelInspectorState
    @ObservedObject var clipboard: CoordinateClipboard

    var body: some View {
        Group {
            if state.hasSelection {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        identitySection
                        Divider().padding(.vertical, 8)
                        positionSection
                        Divider().padding(.vertical, 8)
                        rotationSection
                        Divider().padding(.vertical, 8)
                        scaleSection
                        Divider().padding(.vertical, 8)
                        displaySection
                        Divider().padding(.vertical, 8)
                        materialSection
                    }
                    .padding(12)
                }
            } else {
                VStack {
                    Spacer()
                    Text("No model selected")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(width: 280)
        .background(Color(NSColor.windowBackgroundColor))
        // Keep Position + Rotation fields tracking viewport moves of the selection.
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            state.refresh()
        }
    }

    // MARK: - Position

    private var positionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Position").font(.headline)
                Spacer()
                CoordCopyPasteButtons(
                    onCopy:   { clipboard.position = state.position },
                    onPaste:  { if let p = clipboard.position { state.position = p } },
                    canPaste: state.canEditPosition && clipboard.position != nil,
                    onZero:   { state.position = .zero },
                    canZero:  state.canEditPosition,
                    onAutoStamp: { state.onAutoStamp?() })
            }
            SliderRow(label: "X", value: $state.position.x, range: -100...100, format: "%.2f")
                .disabled(!state.canEditPosition)
            SliderRow(label: "Y", value: $state.position.y, range: -100...100, format: "%.2f")
                .disabled(!state.canEditPosition)
            SliderRow(label: "Z", value: $state.position.z, range: -100...100, format: "%.2f")
                .disabled(!state.canEditPosition)
        }
    }

    // MARK: - Rotation

    private var rotationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Rotation").font(.headline)
                Spacer()
                CoordCopyPasteButtons(
                    onCopy:   { clipboard.rotation = state.rotation },
                    onPaste:  { if let r = clipboard.rotation { state.rotation = r } },
                    canPaste: state.canEditRotation && clipboard.rotation != nil,
                    onZero:   { state.rotation = .zero },
                    canZero:  state.canEditRotation,
                    onAutoStamp: { state.onAutoStamp?() })
            }
            SliderRow(label: "X", value: $state.rotation.x, range: -180...180, format: "%.1f")
                .disabled(!state.canEditRotation)
            SliderRow(label: "Y", value: $state.rotation.y, range: -180...180, format: "%.1f")
                .disabled(!state.canEditRotation)
            SliderRow(label: "Z", value: $state.rotation.z, range: -180...180, format: "%.1f")
                .disabled(!state.canEditRotation)
        }
    }

    // MARK: - Scale

    // Per-axis scale.  Enabled only for a single non-grouped root; grouped
    // selections display the effective world scale but the sliders are greyed
    // (group scale would need to scale every part — deferred).
    private var scaleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scale").font(.headline)
            SliderRow(label: "X", value: $state.scale.x, range: 0.01...10, format: "%.2f")
                .disabled(!state.canEditScale)
            SliderRow(label: "Y", value: $state.scale.y, range: 0.01...10, format: "%.2f")
                .disabled(!state.canEditScale)
            SliderRow(label: "Z", value: $state.scale.z, range: 0.01...10, format: "%.2f")
                .disabled(!state.canEditScale)
        }
    }

    // MARK: - Identity

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Identity")
                .font(.headline)
                .padding(.bottom, 2)

            HStack(spacing: 6) {
                Text("Name")
                    .frame(width: 64, alignment: .leading)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("", text: $state.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }

            HStack(spacing: 6) {
                Text("File")
                    .frame(width: 64, alignment: .leading)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text(state.filename)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Reveal") { state.onRevealInFinder?() }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundColor(.accentColor)
            }

            if state.partCount > 1 {
                HStack(spacing: 6) {
                    Text("Parts")
                        .frame(width: 64, alignment: .leading)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text("\(state.partCount)")
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - Visibility & Display

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Visibility & Display")
                .font(.headline)
                .padding(.bottom, 2)

            Toggle(isOn: $state.isVisible) {
                Text("Visible")
                    .font(.caption)
                    .foregroundColor(state.isVisible ? .green : .primary)
            }
            .toggleStyle(.switch)
            .tint(.green)
            .environment(\.controlActiveState, .active)

            Toggle(isOn: $state.occludeWhenHidden) {
                Text("Holdout (occlude while hidden)")
                    .font(.caption)
                    .foregroundColor(state.occludeWhenHidden ? .green : .primary)
            }
            .toggleStyle(.switch)
            .tint(.green)
            .environment(\.controlActiveState, .active)
            .help("When hidden, this object still blocks objects behind it — cutting "
                + "a hole in the matte without drawing itself. Only takes effect while hidden.")

            HStack(spacing: 6) {
                Text("Normals")
                    .frame(width: 64, alignment: .leading)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Picker("", selection: $state.normalMode) {
                    ForEach(NormalMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    // MARK: - Material Overrides

    private var materialSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Material Overrides")
                .font(.headline)
                .padding(.bottom, 2)

            SliderRow(label: "Metallic",
                      value: $state.metallicFactor,
                      range: 0...1,
                      format: "%.2f")

            SliderRow(label: "Roughness",
                      value: $state.roughnessFactor,
                      range: 0...1,
                      format: "%.2f")

            SliderRow(label: "Opacity",
                      value: $state.opacity,
                      range: 0...1,
                      format: "%.2f")

            LabeledColorRow(label: "Base Color", binding: $state.baseColor)
        }
    }
}
