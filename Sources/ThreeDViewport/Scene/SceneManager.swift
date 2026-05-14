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

    // Advance selectedIndex by one, wrapping around the object list.
    func cycleSelection() {
        guard objects.count > 1 else {
            print("[DEBUG] SceneManager: cycleSelection — only one object")
            return
        }
        selectedIndex = (selectedIndex + 1) % objects.count
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

    // MARK: - Camera follow helpers

    /// Returns the world-space orbit anchor for the named object — the data needed
    /// for camera-follow.
    ///
    /// `pos` — world translation (camera orbits around this point).
    /// `behindYaw` — camera yaw that places the camera directly *behind* the object,
    ///   i.e. on the side opposite to the object's -Z (GLTF forward) direction.
    ///   Formula: atan2(columns.2.x, columns.2.z) of the object's world rotation.
    ///
    /// Uses the group transform for grouped objects (so the camera follows the whole
    /// group as one unit, not just an individual part), or the object's own transform
    /// for ungrouped objects.
    func worldOrbitAnchor(ofObjectNamed name: String)
        -> (pos: SIMD3<Float>, behindYaw: Float)? {
        guard let obj = objects.first(where: { $0.name == name }) else { return nil }

        // Determine which transform to use as the orbit anchor.
        //
        // Priority:
        //   1. Explicit group transform (driven by group keyframe animation) —
        //      represents the whole-model pose, so it's the correct pivot.
        //   2. Group root object's transform — used when no group keyframe has
        //      been applied yet.  Keeps the camera orbiting around the model's
        //      natural pivot regardless of which sub-part the user selected.
        //      Without this, selecting a sub-part (e.g. chest panel) would put
        //      the orbit anchor on the part's surface, pulling the camera inside
        //      the model and making that part appear displaced in the viewport.
        //   3. Object's own transform — for ungrouped root objects.
        let mat: matrix_float4x4
        if let gid = obj.groupID {
            if let groupMat = groupTransforms[gid] {
                // Group has an active keyframe-animated transform.
                mat = groupMat
            } else {
                // No group keyframe yet — use the root node of this group so the
                // camera orbits around the model's pivot, not the selected sub-part.
                let root = objects.first(where: { $0.groupID == gid && $0.parentIndex == nil })
                mat = root?.transform ?? obj.transform
            }
        } else {
            mat = obj.transform
        }

        let pos = SIMD3<Float>(mat.columns.3.x, mat.columns.3.y, mat.columns.3.z)
        // "Behind yaw": the camera yaw that places the orbit eye on the +Z (local)
        // side of the object.  In GLTF the -Z axis is forward, so +Z is behind.
        // atan2(columns.2.x, columns.2.z) gives the world-space angle of that axis.
        let behindYaw = atan2(mat.columns.2.x, mat.columns.2.z)

        return (pos: pos, behindYaw: behindYaw)
    }
}
