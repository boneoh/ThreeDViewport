import SwiftUI

/// Options gathered in the "Glue Objects" dialog's accessory view.
/// `id` on each candidate is the object's index in `SceneManager.objects`.
final class GlueOptions: ObservableObject {
    struct Candidate: Identifiable { let id: Int; let name: String }

    let candidates: [Candidate]
    @Published var selected: Set<Int>
    @Published var anchor:   Int
    @Published var name:     String
    /// True when editing an existing envelope's membership: the origin/anchor is
    /// already set, so the anchor picker is hidden.
    let isEditing: Bool

    init(candidates: [Candidate], selected: Set<Int>, anchor: Int, name: String,
         isEditing: Bool = false) {
        self.candidates = candidates
        self.selected   = selected
        self.anchor     = anchor
        self.name       = name
        self.isEditing  = isEditing
    }

    /// Keeps the anchor valid as the selection changes — if the anchor is no longer
    /// selected, fall back to the lowest-indexed selected candidate.
    private func fixAnchorIfNeeded() {
        if !selected.contains(anchor) {
            anchor = selected.sorted().first ?? -1
        }
    }

    func setMembership(_ id: Int, _ on: Bool) {
        if on { selected.insert(id) } else { selected.remove(id) }
        fixAnchorIfNeeded()
    }
}

/// Accessory shown in the Glue dialog — pick members, the anchor (pivot), and a name.
struct GlueSheetView: View {
    @ObservedObject var options: GlueOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Name").frame(width: 100, alignment: .leading)
                TextField("Envelope", text: $options.name)
                    .textFieldStyle(.roundedBorder)
            }

            Text("Objects to glue")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(options.candidates) { c in
                        Toggle(isOn: Binding(
                            get: { options.selected.contains(c.id) },
                            set: { options.setMembership(c.id, $0) }
                        )) {
                            Text(c.name).lineLimit(1).truncationMode(.middle)
                        }
                        .environment(\.controlActiveState, .active)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
            .frame(height: 160)

            if !options.isEditing {
                HStack {
                    Text("Anchor (pivot)").frame(width: 100, alignment: .leading)
                    Picker("", selection: $options.anchor) {
                        ForEach(options.candidates.filter { options.selected.contains($0.id) }) { c in
                            Text(c.name).tag(c.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
            }

            Text(options.isEditing
                ? "Check objects to add to this unit, uncheck to remove. The envelope "
                    + "keeps its current pivot. An envelope needs at least two members."
                : "The envelope origin sits at the anchor's position. Select the "
                    + "envelope to move the whole unit; select a member to move it alone.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 460)
    }
}
