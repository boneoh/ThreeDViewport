import SwiftUI

// Reference identity so SceneObjects can drive SwiftUI ForEach / selection.
extension SceneObject: Identifiable {
    public var id: ObjectIdentifier { ObjectIdentifier(self) }
}

// Observable state for the Effects grid window.  Builds a grouped row model from
// SceneManager.objects (envelopes hidden, parts bucketed by groupID) and writes
// per-object visible / holdout / class edits straight back to the SceneObjects.
//
// The SceneObject fields aren't @Published, so after a mutation we manually fire
// objectWillChange so the grid recomputes group tri-state.  AppDelegate wires the
// callbacks (live redraw, project-dirty, viewport selection) and calls sync() from
// SceneManager.onSelectionChanged — which fires on both selection and object-array
// changes, so the rows and the highlight both stay current.
final class EffectsGridState: ObservableObject {

    enum TriState { case on, off, mixed }

    // One grid row: a group (members share a groupID) or a single ungrouped object.
    struct Row: Identifiable {
        let id: String
        let groupID: Int?
        let name: String
        let members: [SceneObject]
        var isGroup: Bool { groupID != nil }
    }

    @Published var rows: [Row] = []
    @Published var expandedGroups: Set<Int> = []
    /// Identity of the currently selected object, for row highlight.
    @Published var selectedID: ObjectIdentifier?

    private weak var sceneManager: SceneManager?

    // Wired by AppDelegate.
    var onDirty:  (() -> Void)?
    var onRedraw: (() -> Void)?
    /// Select this object in the viewport (mirrors a Timeline lane click).
    var onSelect: ((SceneObject) -> Void)?

    func bind(sceneManager: SceneManager) {
        self.sceneManager = sceneManager
        sync()
    }

    /// Rebuild rows + refresh the selection highlight.  Cheap (a handful of
    /// objects); safe to call on every selection / object-array change.
    func sync() {
        guard let sm = sceneManager else { rows = []; selectedID = nil; return }
        var built: [Row] = []
        var seen = Set<Int>()
        for obj in sm.objects where !obj.isEnvelope {
            if let gid = obj.groupID {
                guard seen.insert(gid).inserted else { continue }
                let members = sm.objects
                    .filter { $0.groupID == gid && !$0.isEnvelope }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                built.append(Row(id: "g\(gid)", groupID: gid,
                                 name: sm.groupName(for: gid), members: members))
            } else {
                built.append(Row(id: "o\(ObjectIdentifier(obj))", groupID: nil,
                                 name: obj.name, members: [obj]))
            }
        }
        // Sort rows alphabetically (natural order, so "item2" < "item10").
        built.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        rows = built
        selectedID = sm.selectedObject.map { ObjectIdentifier($0) }
        // Groups start collapsed; the user expands them manually (the collapsed
        // group row still highlights when one of its members is selected).
    }

    func toggleExpanded(_ gid: Int) {
        if expandedGroups.contains(gid) { expandedGroups.remove(gid) }
        else { expandedGroups.insert(gid) }
    }

    // MARK: - Column state (group aggregate)

    func visibleState(_ row: Row) -> TriState { triState(row.members.map { $0.isVisible }) }
    func holdoutState(_ row: Row) -> TriState { triState(row.members.map { $0.occludeWhenHidden }) }
    func feedbackState(_ row: Row) -> TriState { triState(row.members.map { $0.feedbackEnabled }) }
    /// Single class shared by all members, or nil when they differ ("Mixed").
    func classSelection(_ row: Row) -> ObjectClass? {
        let classes = Set(row.members.map { $0.objectClass })
        return classes.count == 1 ? classes.first : nil
    }

    private func triState(_ flags: [Bool]) -> TriState {
        if flags.allSatisfy({ $0 })  { return .on }
        if flags.allSatisfy({ !$0 }) { return .off }
        return .mixed
    }

    // MARK: - Mutation (writes straight to the SceneObjects)

    func setVisible(_ members: [SceneObject], _ value: Bool) {
        members.forEach { $0.isVisible = value }
        onRedraw?(); onDirty?(); objectWillChange.send()
    }

    func setHoldout(_ members: [SceneObject], _ value: Bool) {
        members.forEach { $0.occludeWhenHidden = value }
        onRedraw?(); onDirty?(); objectWillChange.send()
    }

    func setFeedback(_ members: [SceneObject], _ value: Bool) {
        members.forEach { $0.feedbackEnabled = value }
        onRedraw?(); onDirty?(); objectWillChange.send()
    }

    // Class only drives the Export All cycle — no live redraw, just mark dirty.
    func setClass(_ members: [SceneObject], _ value: ObjectClass) {
        members.forEach { $0.objectClass = value }
        onDirty?(); objectWillChange.send()
    }

    func select(_ obj: SceneObject) { onSelect?(obj) }
}
