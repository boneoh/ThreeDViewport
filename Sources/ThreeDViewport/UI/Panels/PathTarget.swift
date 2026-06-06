import SwiftUI

// One selectable target in a Path Animator's "Target" dropdown — a Timeline track
// (camera / light / object / group) the generated path will be written to.  Lets
// the panels pick a target directly instead of requiring a Timeline selection.
struct PathTarget: Identifiable, Hashable {
    let label: String
    let ref:   TrackRef
    var id: TrackRef { ref }
}

// Shared "Target" dropdown used by all three Path Animator panels.
struct TargetPicker: View {
    let targets: [PathTarget]
    @Binding var selection: TrackRef?

    var body: some View {
        HStack {
            Text("Target").foregroundColor(.secondary)
            Picker("", selection: $selection) {
                Text("—").tag(TrackRef?.none)
                ForEach(targets) { t in
                    Text(t.label).tag(TrackRef?.some(t.ref))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .font(.caption)
    }
}
