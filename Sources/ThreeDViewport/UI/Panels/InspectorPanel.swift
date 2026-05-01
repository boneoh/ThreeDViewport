import SwiftUI

// Phase 2+ placeholder — SwiftUI inspector panel for object/light/camera properties.
// Will be embedded in the window using NSHostingView.
struct InspectorPanel: View {

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Inspector")
                .font(.headline)
                .padding(.bottom, 4)

            Text("(Phase 2)")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 220)
    }
}
