import Foundation
import simd

// Owns the live scene graph.
// Phase 6: multi-object support with selectedIndex for keyboard/mouse routing.
final class SceneManager {

    var objects: [SceneObject] = [] {
        didSet {
            if objects.isEmpty {
                selectedIndex = 0
                print("[DEBUG] SceneManager: objects array is now empty")
            } else {
                // Keep selectedIndex in bounds after a remove/replace.
                if selectedIndex >= objects.count {
                    selectedIndex = objects.count - 1
                }
                print("[DEBUG] SceneManager: objects count = " + String(objects.count))
            }
        }
    }

    // Index of the object that currently receives keyboard/mouse input.
    // Always clamped to a valid index when objects is non-empty.
    var selectedIndex: Int = 0 {
        didSet {
            guard !objects.isEmpty else { return }
            selectedIndex = max(0, min(objects.count - 1, selectedIndex))
            print("[DEBUG] SceneManager: selectedIndex = " + String(selectedIndex)
                + " ('" + (selectedObject?.name ?? "none") + "')")
        }
    }

    // Monotonically increasing counter — each call returns a unique group ID.
    private var nextGroupID: Int = 0

    // ── Group-level animation (Phase 2) ──────────────────────────────────────
    // One KeyframeTrack per groupID.  Evaluated each frame and stored in
    // groupTransforms; the renderer pre-multiplies groupTransform × obj.transform
    // so the group layer sits on top of per-part animation.
    var groupKeyframeTracks: [Int: KeyframeTrack]   = [:]

    // Live evaluated (or manually positioned) group-level transform.
    // Identity = no group offset.  The renderer only reads this; the animation
    // system writes it by evaluating groupKeyframeTracks.
    var groupTransforms:     [Int: matrix_float4x4] = [:]

    init() {
        print("[DEBUG] SceneManager: initialized, objects count = 0")
    }

    /// Returns a new unique group ID for a batch of parts loaded together.
    func makeGroupID() -> Int {
        let id = nextGroupID
        nextGroupID += 1
        return id
    }

    /// All objects that share the given group ID.
    func objects(inGroup groupID: Int) -> [SceneObject] {
        return objects.filter { $0.groupID == groupID }
    }

    /// Group ID of the currently selected object, if any.
    var selectedGroupID: Int? {
        return selectedObject?.groupID
    }

    /// Display name for a group — uses the source-URL filename of the first part.
    func groupName(for groupID: Int) -> String {
        guard let first = objects.first(where: { $0.groupID == groupID }) else {
            return "Group \(groupID)"
        }
        if let url = first.sourceURL {
            return url.deletingPathExtension().lastPathComponent
        }
        return first.name
    }

    func clear() {
        print("[DEBUG] SceneManager: clearing " + String(objects.count) + " object(s)")
        objects.removeAll()
        groupKeyframeTracks.removeAll()
        groupTransforms.removeAll()
        selectedIndex = 0
    }

    // The currently selected object — receives keyboard/mouse rotation and keyframes.
    var selectedObject: SceneObject? {
        guard !objects.isEmpty, selectedIndex < objects.count else { return nil }
        return objects[selectedIndex]
    }

    // The first visible object — kept for backward-compatible call sites.
    var primaryObject: SceneObject? {
        let obj = objects.first(where: { $0.isVisible })
        if obj == nil {
            print("[DEBUG] SceneManager: primaryObject is nil (no visible objects)")
        }
        return obj
    }

    /// Indices of root objects (parentIndex == nil) sorted alphabetically by name.
    /// Used by cycleSelection() and by the Remove submenu.
    var rootObjectIndicesSorted: [Int] {
        return objects.indices
            .filter  { objects[$0].parentIndex == nil }
            .sorted  { objects[$0].name < objects[$1].name }
    }

    /// Advance selection to the next root object in alphabetical order, wrapping around.
    /// Sub-objects (parentIndex != nil) are skipped — they are selectable only via the
    /// Timeline Editor.
    func cycleSelection() {
        let roots = rootObjectIndicesSorted
        guard roots.count > 1 else {
            print("[DEBUG] SceneManager: cycleSelection — fewer than two root objects")
            return
        }
        // Find where the current selectedIndex falls in the sorted root list.
        let currentPos = roots.firstIndex(of: selectedIndex) ?? -1
        let nextPos    = (currentPos + 1) % roots.count
        selectedIndex  = roots[nextPos]
        print("[DEBUG] SceneManager: cycled selection to index " + String(selectedIndex)
            + " ('" + (selectedObject?.name ?? "none") + "')")
    }

    // Toggle visibility for the object at `index`.
    func toggleVisibility(at index: Int) {
        guard index >= 0, index < objects.count else {
            print("[DEBUG] SceneManager: toggleVisibility — index " + String(index) + " out of range")
            return
        }
        objects[index].isVisible.toggle()
        print("[DEBUG] SceneManager: object[" + String(index) + "] '"
            + objects[index].name + "' isVisible=" + String(objects[index].isVisible))
    }

    // Remove the object at `index` from the scene.
    func remove(at index: Int) {
        guard index >= 0, index < objects.count else {
            print("[DEBUG] SceneManager: remove — index " + String(index) + " out of range")
            return
        }
        let name = objects[index].name
        objects.remove(at: index)
        print("[DEBUG] SceneManager: removed object '" + name + "', remaining count = " + String(objects.count))
    }

    /// Removes the object at `objectIndex` and all other objects that share its
    /// groupID.  If the object has no groupID it is removed individually.
    /// Also cleans up groupKeyframeTracks and groupTransforms for the affected group.
    func removeGroup(containing objectIndex: Int) {
        guard objectIndex >= 0, objectIndex < objects.count else {
            print("[DEBUG] SceneManager: removeGroup — index " + String(objectIndex) + " out of range")
            return
        }
        if let gid = objects[objectIndex].groupID {
            let name = groupName(for: gid)
            objects.removeAll { $0.groupID == gid }
            groupKeyframeTracks.removeValue(forKey: gid)
            groupTransforms.removeValue(forKey: gid)
            print("[DEBUG] SceneManager: removed group gid=\(gid) '\(name)', remaining count = \(objects.count)")
        } else {
            remove(at: objectIndex)
        }
    }

    // MARK: - Camera follow helpers

    /// Returns the world-space follow state for the named object — the data needed
    /// for camera-follow keyframes (both at creation time and at runtime).
    ///
    /// `pos` — world position of the **named object itself** (the camera orbits /
    ///   looks at this point).  For a head bone the camera will follow the head,
    ///   for an ungrouped mesh it follows the mesh origin.
    ///
    /// `behindYaw` — camera yaw that places the camera directly *behind* the body,
    ///   derived from the **group root's** world orientation (not the sub-part).
    ///   This keeps the "behind" direction aligned with the whole character's facing
    ///   direction even when the selected sub-part (e.g. a head) has its own local
    ///   rotation.  Formula: atan2(columns.2.x, columns.2.z).
    ///
    /// Design note — two matrices, one per purpose:
    ///   • `posMat`  : always the named object's own world transform → correct height
    ///                 and lateral position (e.g. the head, not the feet).
    ///   • `yawMat`  : group-root (or group keyframe) transform → body facing direction.
    ///   When a group keyframe is present it drives both, because the group transform
    ///   already represents the whole model's world pose.
    func worldOrbitAnchor(ofObjectNamed name: String)
        -> (pos: SIMD3<Float>, behindYaw: Float)? {
        guard let obj = objects.first(where: { $0.name == name }) else { return nil }

        let posMat:  matrix_float4x4   // for extracting world position of the target
        let yawMat:  matrix_float4x4   // for extracting the body's facing direction

        if let gid = obj.groupID {
            if let groupMat = groupTransforms[gid] {
                // Group has a keyframe-animated transform.  The rendered position
                // of any part is `groupMat × obj.transform` — the group matrix is
                // a multiplier on top of each part's hierarchical transform, not
                // a complete pose by itself.  So compose them for `posMat` so that
                // following a sub-part (e.g. a head bone) tracks the sub-part's
                // actual rendered position when the group is also keyframed.
                // `yawMat` stays at groupMat because the body-facing direction
                // comes from the model as a whole, not the sub-part.
                posMat = groupMat * obj.transform
                yawMat = groupMat
            } else {
                // No group keyframe yet.
                //   pos  → the named object's own world transform (updated each frame
                //          by Renderer.applyHierarchy), so a head bone tracks the head.
                //   yaw  → the group root's transform so "behind" means "behind the
                //          whole character body", regardless of head rotation.
                let root = objects.first(where: { $0.groupID == gid && $0.parentIndex == nil })
                posMat = obj.transform
                yawMat = root?.transform ?? obj.transform
            }
        } else {
            // Ungrouped object — its own transform covers both needs.
            posMat = obj.transform
            yawMat = obj.transform
        }

        let pos = SIMD3<Float>(posMat.columns.3.x, posMat.columns.3.y, posMat.columns.3.z)
        // "Behind yaw": the camera yaw that places the orbit eye on the +Z (local)
        // side of the body.  In GLTF the -Z axis is forward, so +Z is behind.
        // atan2(columns.2.x, columns.2.z) gives the world-space angle of that axis.
        let behindYaw = atan2(yawMat.columns.2.x, yawMat.columns.2.z)

        return (pos: pos, behindYaw: behindYaw)
    }
}
