import SwiftUI
import simd

/// Inspector for the bake probe — toggles its viewport gizmo and sets its
/// world position (sliders with arrow-key fine adjustment + Position copy/paste).
struct ProbeInspectorPanel: View {

    @ObservedObject var probe:     ProbeConfig
    @ObservedObject var clipboard: CoordinateClipboard
    /// Prompts for a name + colour and saves the current probe position as a mark.
    var onMarkPosition: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {

                HStack {
                    Image(systemName: "scope").foregroundColor(.accentColor)
                    Text("Probe").font(.headline)
                    Spacer()
                }

                Toggle(isOn: $probe.isVisible) {
                    Text("Show gizmo in viewport")
                        .font(.caption)
                        .foregroundColor(probe.isVisible ? .green : .primary)
                }
                .toggleStyle(.switch)
                .tint(.green)
                .environment(\.controlActiveState, .active)

                Divider()

                HStack {
                    Text("Position").font(.headline)
                    Spacer()
                    CoordCopyPasteButtons(
                        onCopy:   { clipboard.position = probe.position },
                        onPaste:  { if let p = clipboard.position { probe.position = p } },
                        canPaste: clipboard.position != nil,
                        onZero:   { probe.position = .zero },
                        canZero:  true)
                }
                SliderRow(label: "X", value: $probe.position.x, range: -100...100, format: "%.2f")
                SliderRow(label: "Y", value: $probe.position.y, range: -100...100, format: "%.2f")
                SliderRow(label: "Z", value: $probe.position.z, range: -100...100, format: "%.2f")

                Divider()

                HStack {
                    Text("Marks").font(.headline)
                    Spacer()
                    Text("\(probe.marks.count)").font(.caption).foregroundStyle(.secondary)
                }
                Button(action: onMarkPosition) {
                    Label("Mark Position", systemImage: "mappin.and.ellipse")
                        .frame(maxWidth: .infinity)
                }
                Toggle(isOn: $probe.marksVisible) {
                    Text("Show marks (viewport + export)")
                        .font(.caption)
                        .foregroundColor(probe.marksVisible ? .green : .primary)
                }
                .toggleStyle(.switch)
                .tint(.green)
                .environment(\.controlActiveState, .active)
                Text("K toggles marks · N / Shift+N cycles (moves the probe to the mark) "
                    + "· Delete removes the selected mark.")
                    .font(.caption2).foregroundStyle(.secondary)

                Divider()

                Text("The probe marks where the scene is captured from when exporting "
                    + "an environment HDR.  It is never included in renders or exports.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(14)
        }
        .frame(width: 280)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
