import SwiftUI
import simd

/// Inspector for the bake probe — toggles its viewport gizmo and sets its
/// world position (sliders with arrow-key fine adjustment + Position copy/paste).
struct ProbeInspectorPanel: View {

    @ObservedObject var probe:     ProbeConfig
    @ObservedObject var clipboard: CoordinateClipboard

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {

                HStack {
                    Image(systemName: "scope").foregroundColor(.accentColor)
                    Text("Bake Probe").font(.headline)
                    Spacer()
                }

                Toggle(isOn: $probe.isVisible) {
                    Text("Show gizmo in viewport").font(.caption)
                }
                .toggleStyle(.switch)

                Divider()

                HStack {
                    Text("Position").font(.headline)
                    Spacer()
                    CoordCopyPasteButtons(
                        onCopy:   { clipboard.position = probe.position },
                        onPaste:  { if let p = clipboard.position { probe.position = p } },
                        canPaste: clipboard.position != nil)
                }
                SliderRow(label: "X", value: $probe.position.x, range: -100...100, format: "%.2f")
                SliderRow(label: "Y", value: $probe.position.y, range: -100...100, format: "%.2f")
                SliderRow(label: "Z", value: $probe.position.z, range: -100...100, format: "%.2f")

                Text("The probe marks where the scene is captured from when baking "
                    + "an environment HDR.  It is never included in renders or exports.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(14)
        }
        .frame(width: 280)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
