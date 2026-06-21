import SwiftUI

// Effects grid: one row per object (envelopes hidden), grouped by groupID with
// group-level tri-state toggles.  Columns: Visible / Holdout / Trail / Import / Class.
// "Import" (default on) excludes an object when this project is imported into another —
// like a hidden object, but without having to hide it.  These are the per-object controls
// removed from the Model Inspector — edited here in one place without disturbing the timeline.
struct EffectsGridPanel: View {

    @ObservedObject var state: EffectsGridState

    private let visW:    CGFloat = 52
    private let holdW:   CGFloat = 60
    private let feedW:   CGFloat = 64
    private let importW: CGFloat = 56
    private let classW:  CGFloat = 124
    private let indent:  CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(state.rows) { row in
                        if row.isGroup {
                            groupRow(row)
                            if state.expandedGroups.contains(row.groupID!) {
                                ForEach(row.members) { member in
                                    memberRow(member, indented: true)
                                }
                            }
                        } else {
                            memberRow(row.members[0], indented: false)
                        }
                    }
                }
            }
            if state.rows.isEmpty {
                Spacer()
                Text("No objects in the scene.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
            }
        }
        .frame(minWidth: 380, minHeight: 200)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 0) {
            Text("Object")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Visible").frame(width: visW)
            Text("Holdout").frame(width: holdW)
            Text("Trail").frame(width: feedW)
            Text("Import").frame(width: importW)
            Text("Class").frame(width: classW)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Group row

    private func groupRow(_ row: Row) -> some View {
        let gid = row.groupID!
        let expanded = state.expandedGroups.contains(gid)
        return HStack(spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    state.toggleExpanded(gid)
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                Text(row.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .onTapGesture { if let first = row.members.first { state.select(first) } }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            TriBox(state: state.visibleState(row)) { v in state.setVisible(row.members, v) }
                .frame(width: visW)
            TriBox(state: state.holdoutState(row)) { v in state.setHoldout(row.members, v) }
                .frame(width: holdW)
            TriBox(state: state.feedbackState(row)) { v in state.setFeedback(row.members, v) }
                .frame(width: feedW)
            TriBox(state: state.importState(row)) { v in state.setImport(row.members, v) }
                .frame(width: importW)
            classMenu(current: state.classSelection(row)) { state.setClass(row.members, $0) }
                .frame(width: classW)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(rowHighlight(for: row.members))
    }

    // MARK: - Member / ungrouped row

    private func memberRow(_ obj: SceneObject, indented: Bool) -> some View {
        HStack(spacing: 0) {
            Text(state.displayName(for: obj))
                .lineLimit(1)
                .padding(.leading, indented ? indent : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { state.select(obj) }

            TriBox(state: obj.isVisible ? .on : .off) { v in state.setVisible([obj], v) }
                .frame(width: visW)
            TriBox(state: obj.occludeWhenHidden ? .on : .off) { v in state.setHoldout([obj], v) }
                .frame(width: holdW)
            TriBox(state: obj.feedbackEnabled ? .on : .off) { v in state.setFeedback([obj], v) }
                .frame(width: feedW)
            TriBox(state: obj.includeInImport ? .on : .off) { v in state.setImport([obj], v) }
                .frame(width: importW)
            classMenu(current: obj.objectClass) { state.setClass([obj], $0) }
                .frame(width: classW)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(rowHighlight(for: [obj]))
    }

    // MARK: - Helpers

    @ViewBuilder
    private func rowHighlight(for members: [SceneObject]) -> some View {
        let selected = state.selectedID.map { id in members.contains { ObjectIdentifier($0) == id } } ?? false
        if selected { Color.accentColor.opacity(0.18) } else { Color.clear }
    }

    private func classMenu(current: ObjectClass?,
                           set: @escaping (ObjectClass) -> Void) -> some View {
        Menu {
            ForEach(ObjectClass.allCases, id: \.self) { cls in
                Button(cls.displayName) { set(cls) }
            }
        } label: {
            Text(current?.displayName ?? "Mixed")
                .font(.caption)
                .foregroundStyle(current == nil ? .secondary : .primary)
                .frame(maxWidth: .infinity)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// On / off / mixed checkbox.  Click drives all backing objects to a single value:
// on → off, off/mixed → on.
private struct TriBox: View {
    let state: EffectsGridState.TriState
    let action: (Bool) -> Void

    var body: some View {
        Button {
            action(state != .on)
        } label: {
            Image(systemName: symbol)
                .foregroundColor(state == .off ? .secondary : .green)
                .imageScale(.large)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private var symbol: String {
        switch state {
        case .on:    return "checkmark.square.fill"
        case .off:   return "square"
        case .mixed: return "minus.square.fill"
        }
    }
}

private typealias Row = EffectsGridState.Row
