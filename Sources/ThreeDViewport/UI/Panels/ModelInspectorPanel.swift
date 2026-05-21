import SwiftUI
import AppKit

struct ModelInspectorPanel: View {

    @ObservedObject var state: ModelInspectorState

    var body: some View {
        Group {
            if state.hasSelection {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        identitySection
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

            Toggle(isOn: $state.occludeWhenHidden) {
                Text("Holdout (occlude while hidden)")
                    .font(.caption)
                    .foregroundColor(state.occludeWhenHidden ? .green : .primary)
            }
            .toggleStyle(.switch)
            .tint(.green)
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

            LabeledColorRow(label: "Base Color", binding: $state.baseColor)
        }
    }
}
