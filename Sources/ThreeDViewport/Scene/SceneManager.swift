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
    /// `pos` — world position of the followed object's **visual centre** (its
    ///   `boundingCenter` transformed through the full posMat chain).  Using
    ///   the visual centre rather than the raw pivot fixes the common case of
    ///   a rigged part whose pivot sits at a joint rather than at the mesh.
    ///
    /// `behindYaw` / `behindPitch` — the yaw and pitch angles of the followed
    ///   object's local +Z axis (its "behind" direction) expressed in world
    ///   space.  Camera-follow logic adds the keyframe's captured offsets to
    ///   these so the camera stays at a fixed bearing AND elevation relative
    ///   to the object — head rotation (yaw) AND head tilt (pitch) both rotate
    ///   the camera around the followed point.
    ///
    /// `basis` — the object's normalised 3×3 world-space rotation (columns are
    ///   the object's local +X/+Y/+Z axes in world space).  Used by the
    ///   camera-follow logic to transform a target offset between the followed
    ///   object's local frame and world space, so the offset rotates with the
    ///   object the same way yaw/pitch do.  For clean (uniform-scale +
    ///   rotation) transforms this is orthonormal and `.transpose` is its
    ///   inverse — which is the form the follow code uses for world→local.
    func worldOrbitAnchor(ofObjectNamed name: String)
        -> (pos: SIMD3<Float>, behindYaw: Float, behindPitch: Float, basis: matrix_float3x3)? {
        guard let obj = objects.first(where: { $0.name == name }) else { return nil }

        // Rendered world transform of the followed object.  When the model has
        // a group-level keyframe, the group matrix is a multiplier on top of
        // each part's hierarchical transform (not a complete pose by itself),
        // so the two must be composed.  Otherwise the object's own transform
        // is already its world transform.
        let posMat: matrix_float4x4
        if let gid = obj.groupID, let groupMat = groupTransforms[gid] {
            posMat = groupMat * obj.transform
        } else {
            posMat = obj.transform
        }
        // Both position AND facing direction come from the followed object's
        // own world transform.  So if you're following a head bone and the
        // head rotates relative to the body, the camera rotates with the head.
        // If you instead want the camera to track the body's facing, follow
        // the body's root part — the same code path produces the right answer
        // because `behindYaw` is then derived from the body's transform.
        let yawMat = posMat

        // The followed point is the object's **visual centre** (mid-point of its
        // mesh bounding box) transformed through the same matrix chain as the
        // object itself.  Using boundingCenter instead of the raw pivot fixes
        // the common case where a rigged part's pivot sits at its joint (e.g.
        // the bottom of the head, at the neck) rather than where the mesh
        // visually appears.  Without this, snap-on-stamp would tilt the camera
        // down to aim at the joint instead of at the head you can see.
        let centreLocal4 = SIMD4<Float>(obj.boundingCenter, 1)
        let centreWorld4 = posMat * centreLocal4
        let pos = SIMD3<Float>(centreWorld4.x, centreWorld4.y, centreWorld4.z)

        // Normalise each column of the upper-left 3×3 to strip non-unit scale
        // (Project 2's robot has a 0.168 uniform scale, for instance) so the
        // resulting basis is orthonormal for clean transforms.  Used both for
        // pitch (asin of the y-component below) and for the world↔local
        // rotation of camera-follow target offsets.
        let col0 = SIMD3<Float>(yawMat.columns.0.x, yawMat.columns.0.y, yawMat.columns.0.z)
        let col1 = SIMD3<Float>(yawMat.columns.1.x, yawMat.columns.1.y, yawMat.columns.1.z)
        let col2 = SIMD3<Float>(yawMat.columns.2.x, yawMat.columns.2.y, yawMat.columns.2.z)
        let len0 = simd_length(col0)
        let len1 = simd_length(col1)
        let len2 = simd_length(col2)
        let axisX = len0 > 0.0001 ? col0 / len0 : SIMD3<Float>(1, 0, 0)
        let axisY = len1 > 0.0001 ? col1 / len1 : SIMD3<Float>(0, 1, 0)
        let axisZ = len2 > 0.0001 ? col2 / len2 : SIMD3<Float>(0, 0, 1)
        let basis = matrix_float3x3(columns: (axisX, axisY, axisZ))

        // "Behind" direction = followed object's local +Z axis in world space.
        // In GLTF, -Z is forward, so +Z is behind.
        let behindYaw   = atan2(axisZ.x, axisZ.z)
        let behindPitch = asin(max(-1.0, min(1.0, axisZ.y)))

        return (pos: pos, behindYaw: behindYaw, behindPitch: behindPitch, basis: basis)
    }
}
