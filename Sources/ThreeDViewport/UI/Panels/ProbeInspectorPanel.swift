import SwiftUI
import simd

/// Inspector for the bake probe — toggles its viewport gizmo and sets its
/// world position (sliders with arrow-key fine adjustment + Position copy/paste).
struct ProbeInspectorPanel: View {

    @ObservedObject var probe:     ProbeConfig
    @ObservedObject var clipboard: CoordinateClipboard
    /// Adds a new mark (no selection) or updates the selected mark (commits the probe's
    /// position and lets the name/colour be edited).  AppDelegate branches on selection.
    var onMarkPosition: () -> Void = {}
    /// Called when the gizmo's visibility toggle changes, so the project can be
    /// marked dirty and the state persisted.
    var onVisibilityChanged: () -> Void = {}

    /// True when a valid mark is currently selected (drives the button's mode).
    private var hasSelectedMark: Bool {
        probe.selectedMarkIndex.map { probe.marks.indices.contains($0) } ?? false
    }

    /// Name of the selected mark, or "" when none is selected.
    private var selectedMarkName: String {
        guard let i = probe.selectedMarkIndex, probe.marks.indices.contains(i) else { return "" }
        return probe.marks[i].name
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {

                HStack {
                    Image(systemName: "scope").foregroundColor(.accentColor)
                    Text("Probe").font(.headline)
                    Spacer()
                    PanelLockButton(isLocked: $probe.isLocked)
                }

                Toggle(isOn: $probe.isVisible) {
                    Text("Show gizmo in viewport")
                        .font(.caption)
                        .foregroundColor(probe.isVisible ? .green : .primary)
                }
                .toggleStyle(.switch)
                .tint(.green)
                .environment(\.controlActiveState, .active)
                .onChange(of: probe.isVisible) { _, _ in onVisibilityChanged() }

                Divider()

                Group {
                    HStack {
                        Text("Position").font(.headline)
                        Spacer()
                        CoordCopyPasteButtons(
                            onCopy:   { clipboard.position = probe.position },
                            onPaste:  { if let p = clipboard.position { probe.position = p } },
                            canPaste: clipboard.position != nil && !probe.isLocked,
                            onZero:   { probe.position = .zero },
                            canZero:  !probe.isLocked)
                    }
                    SliderRow(label: "X", value: $probe.position.x, range: SceneLimits.positionRange, format: "%.2f")
                    SliderRow(label: "Y", value: $probe.position.y, range: SceneLimits.positionRange, format: "%.2f")
                    SliderRow(label: "Z", value: $probe.position.z, range: SceneLimits.positionRange, format: "%.2f")
                }
                .disabled(probe.isLocked)   // freeze probe position when locked

                Divider()

                HStack {
                    Text("Marks").font(.headline)
                    Spacer()
                    Text("\(probe.marks.count)").font(.caption).foregroundStyle(.secondary)
                }
                // Selected mark name (blank when none selected).
                HStack {
                    Text("Selected").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(selectedMarkName).font(.caption)
                }
                // Morphing button: adds a new mark, or updates the selected one in place
                // (commits the probe position, keeps category/time, lets you edit name/colour).
                Button(action: onMarkPosition) {
                    Label(hasSelectedMark ? "Update Mark…" : "Mark Position",
                          systemImage: hasSelectedMark ? "mappin.circle" : "mappin.and.ellipse")
                        .frame(maxWidth: .infinity)
                }
                .disabled(probe.isLocked)   // no mark edits while locked
                Toggle(isOn: $probe.marksVisible) {
                    Text("Show marks (viewport + export)")
                        .font(.caption)
                        .foregroundColor(probe.marksVisible ? .green : .primary)
                }
                .toggleStyle(.switch)
                .tint(.green)
                .environment(\.controlActiveState, .active)
                Text("K toggles marks · N / Shift+N cycles (probe + playhead jump to the mark) "
                    + "· Delete removes the selected mark. “Update Mark…” saves the probe’s "
                    + "position into the selected mark and edits its name/colour.")
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
