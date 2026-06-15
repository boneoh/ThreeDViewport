import SwiftUI
import AppKit

/// Floating panel shown while an export (single or Export All) runs.  The main
/// window is minimized during export so no edits can corrupt the in-progress scene
/// state; this panel is the only visible UI.  Bound to the shared ExportState.
struct ExportProgressPanel: View {

    @ObservedObject var state: ExportState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "film")
                    .foregroundColor(.accentColor)
                Text(state.projectName.isEmpty ? "Exporting" : state.projectName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Pass x of y for Export All; a simple label for a single export.
            if state.passCount > 1 {
                Text("Pass \(state.passIndex) of \(state.passCount)"
                     + (state.passName.isEmpty ? "" : " — \(state.passName)"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text(state.passName.isEmpty ? "Exporting…" : state.passName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            ProgressView(value: Double(min(max(state.progress, 0), 1)))
                .progressViewStyle(.linear)

            Text(String(format: "%.0f%%", min(max(state.progress, 0), 1) * 100))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(20)
        .frame(width: 340)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
