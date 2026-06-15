import Foundation
import simd

// Owns the live scene graph.
// Phase 6: multi-object support with selectedIndex for keyboard/mouse routing.
final class SceneManager {

    // Fired whenever the selected object changes (index change or objects array change).
    // AppDelegate wires this to push the new selection into ModelInspectorState.
    var onSelectionChanged: (() -> Void)?

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
            // Fire even when selectedIndex didn't change numerically, because
            // the underlying object (filename, parts, materials) may have changed.
            onSelectionChanged?()
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
            onSelectionChanged?()
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

    // ── Import bundles (Phase 2 Part B — display-only) ───────────────────────
    // id → bundle name (the source project's filename at import time).  Objects /
    // lights from one File ▸ Import Project share a bundle ID so the Timeline Editor
    // can fold their lanes under one collapsible header.  No scene-graph meaning.
    var importBundles: [Int: String] = [:]
    private var nextImportBundleID: Int = 0

    // ── Import-bundle looping ("Repeat to Fill Timeline") ────────────────────
    // Per-bundle loop state.  An imported (or loaded) bundle gets an entry whose
    // `enabled` defaults false.  `cycleStart` = host time where the imported
    // frame-zero lands; `cycleLength` = the imported project's full timeline
    // duration (frame zero → last frame, NOT the keyframe span).  When enabled,
    // ViewportView.regenerateBundleLoop tiles copies of the source cycle by
    // k·cycleLength out to the timeline end.
    struct BundleLoop {
        var enabled:     Bool   = false
        var cycleStart:  Double = 0
        var cycleLength: Double = 0
    }
    var importBundleLoops: [Int: BundleLoop] = [:]

    // ── Import-bundle source provenance ("Extend Spin/Orbit to End") ─────────
    // The source `.3dvp` path + the time offset (T) and placement (M) applied at
    // import, so the source's rate markers can be re-read and re-placed onto the
    // imported objects later.
    struct BundleSource {
        var path:         String          = ""
        var insertOffset: Double          = 0
        var transform:    matrix_float4x4 = matrix_identity_float4x4
    }
    var importBundleSources: [Int: BundleSource] = [:]

    init() {
        print("[DEBUG] SceneManager: initialized, objects count = 0")
    }

    /// Returns a new unique group ID for a batch of parts loaded together.
    func makeGroupID() -> Int {
        let id = nextGroupID
        nextGroupID += 1
        return id
    }

    /// Allocates a fresh import-bundle ID and records its (source-file) name.
    func makeImportBundle(name: String) -> Int {
        let id = nextImportBundleID
        nextImportBundleID += 1
        importBundles[id] = name
        return id
    }

    /// After restoring bundles from a loaded project, bump the allocator so a later
    /// import can't reuse a loaded ID.
    func syncImportBundleCounter() {
        nextImportBundleID = max(nextImportBundleID, (importBundles.keys.max() ?? -1) + 1)
    }

    /// Display name for an import bundle — numbered ("scene 1", "scene 2") when more
    /// than one live bundle shares the same base name.  Display only (mirrors
    /// `groupName(for:)`); identity is the bundle ID.
    func bundleName(for id: Int) -> String {
        let base = importBundles[id] ?? "Import \(id)"
        var seen = Set<Int>()
        var total = 0
        var occurrence = 0
        for obj in objects {
            guard let bid = obj.importBundleID, seen.insert(bid).inserted,
                  (importBundles[bid] ?? "Import \(bid)") == base else { continue }
            total += 1
            if bid == id { occurrence = total }   // 1-based, by object order
        }
        return total > 1 ? "\(base) \(occurrence)" : base
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
    /// Display name for a group.  When the same model is loaded more than once, the
    /// instances are numbered ("hand 1", "hand 2") so they're distinguishable in the
    /// timeline / pickers; a single instance keeps its plain name ("hand").
    /// Display only — identity/persistence key on filename + occurrence, not this.
    /// Name for the Glue sheet's FLAT candidate list.  A multi-part model's parts are
    /// all roots with the same group name, so `displayName` makes them indistinguishable
    /// there; this prefixes the model name so each part reads as "Model - part" (the
    /// Timeline relies on indentation instead).  Other objects use `displayName`.
    func glueListName(for obj: SceneObject) -> String {
        if let gid = obj.groupID {
            // partName adds the "name N" suffix for duplicate part names within the
            // model (matching the Timeline Editor grid).
            return "\(groupName(for: gid)) - \(partName(for: obj))"
        }
        return displayName(for: obj)
    }

    func groupName(for groupID: Int) -> String {
        guard objects.contains(where: { $0.groupID == groupID }) else {
            return "Group \(groupID)"
        }
        func base(_ obj: SceneObject) -> String {
            obj.sourceURL?.deletingPathExtension().lastPathComponent ?? obj.name
        }
        guard let firstOfGroup = objects.first(where: { $0.groupID == groupID }) else {
            return "Group \(groupID)"
        }
        let name = base(firstOfGroup)

        // Count groups sharing this base name (object order) and find this one's spot.
        var seen = Set<Int>()
        var total = 0
        var occurrence = 0
        for obj in objects {
            guard let gid = obj.groupID, seen.insert(gid).inserted, base(obj) == name else { continue }
            total += 1
            if gid == groupID { occurrence = total }   // 1-based
        }
        return total > 1 ? "\(name) \(occurrence)" : name
    }

    /// The canonical display name used everywhere in the UI (Timeline first column,
    /// HUD, Inspector, Camera-Follow + Path-Animator pickers).  A grouped model's
    /// root resolves to the group name; a simple top-level object shows its own name,
    /// **numbered** ("cube 1", "cube 2") when more than one simple object shares it;
    /// group members keep their part name.
    func displayName(for obj: SceneObject) -> String {
        // A grouped model's root resolves to the group name (already suffixed).
        if obj.parentIndex == nil, let gid = obj.groupID { return groupName(for: gid) }
        // A multi-part model's part keeps its own glTF part name (heavy / hydrogen / …).
        if obj.groupID != nil { return obj.name }
        // An envelope keeps its given (unique) name.
        if obj.isEnvelope { return obj.name }
        // A single-mesh object — top-level OR a glued envelope member — is numbered
        // when more than one instance of the same name exists, so duplicates stay
        // distinguishable even after gluing (when they gain a parentIndex).
        let name = obj.name
        var total = 0
        var occurrence = 0
        for o in objects where o.groupID == nil && !o.isEnvelope && o.name == name {
            total += 1
            if o === obj { occurrence = total }   // 1-based, by object/load order
        }
        return total > 1 ? "\(name) \(occurrence)" : name
    }

    /// Display name for one PART of a multi-part model: its own name, numbered
    /// ("buckyball 1", "buckyball 2") when other parts in the SAME group share that
    /// name — e.g. a glued model exported to .glb and re-imported, whose flattened
    /// members carry identical mesh names.  Parts with distinct names (heavy /
    /// hydrogen / bonds) are returned unchanged.
    func partName(for obj: SceneObject) -> String {
        guard let gid = obj.groupID else { return obj.name }
        var total = 0
        var occurrence = 0
        for o in objects where o.groupID == gid && o.name == obj.name {
            total += 1
            if o === obj { occurrence = total }   // 1-based, by object/load order
        }
        return total > 1 ? "\(obj.name) \(occurrence)" : obj.name
    }

    func clear() {
        print("[DEBUG] SceneManager: clearing " + String(objects.count) + " object(s)")
        objects.removeAll()
        groupKeyframeTracks.removeAll()
        groupTransforms.removeAll()
        importBundles.removeAll()
        importBundleLoops.removeAll()
        importBundleSources.removeAll()
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

    /// Removes a set of objects by index and repairs the index-based references this
    /// class owns: every survivor's `parentIndex` is remapped (a survivor whose parent
    /// was deleted becomes a root), and `groupKeyframeTracks` / `groupTransforms` for
    /// any now-empty group are dropped.  Spin / Orbit schedules are keyed by object
    /// index on ViewportView and remapped there (see `ViewportView.deleteObjects`).
    func removeObjects(at indices: Set<Int>) {
        let del = indices.filter { $0 >= 0 && $0 < objects.count }
        guard !del.isEmpty else { return }
        let delSorted = del.sorted()
        let affectedGroups = Set(delSorted.compactMap { objects[$0].groupID })
        func shift(_ old: Int) -> Int { old - delSorted.filter { $0 < old }.count }

        for i in delSorted.reversed() { objects.remove(at: i) }

        for o in objects {
            guard let p = o.parentIndex else { continue }
            o.parentIndex = del.contains(p) ? nil : shift(p)
        }
        for gid in affectedGroups where !objects.contains(where: { $0.groupID == gid }) {
            groupKeyframeTracks.removeValue(forKey: gid)
            groupTransforms.removeValue(forKey: gid)
        }
        if selectedIndex >= objects.count { selectedIndex = max(0, objects.count - 1) }
        print("[DEBUG] SceneManager: removed \(del.count) object(s), remaining = \(objects.count)")
    }

    // MARK: - Glue (envelope) helpers

    /// Creates a geometryless "envelope" null node and parents the given member
    /// objects to it so they move and animate as one unit.  The envelope origin is
    /// placed at `anchorIndex`'s world position; each member freezes its current
    /// world pose as a localTransform relative to that origin (so nothing moves).
    /// Returns the new envelope's index in `objects`, or nil on bad input.
    @discardableResult
    func makeEnvelope(name: String, anchorIndex: Int, memberIndices: [Int]) -> Int? {
        guard anchorIndex >= 0, anchorIndex < objects.count else {
            print("[DEBUG] SceneManager: makeEnvelope — anchorIndex out of range")
            return nil
        }
        let members = memberIndices.filter { $0 >= 0 && $0 < objects.count }
        guard members.count >= 2 else {
            print("[DEBUG] SceneManager: makeEnvelope — need at least two members")
            return nil
        }

        // Freeze each member at its REST pose — the anchor of its keyframe deltas —
        // NOT its current animated transform.  Using `transform` (which already
        // includes the keyframe delta at the playhead) would bake that one frame
        // into the new baseTransform, and the unchanged keyframes would then re-apply
        // on top, shifting any existing spin/orbit.  An *animated* member's rest pose
        // is its `baseTransform`; a *static* (possibly dragged) member's is its
        // current `transform`.
        func restPose(_ o: SceneObject) -> matrix_float4x4 {
            (o.keyframeTrack?.keyframes.isEmpty == false) ? o.baseTransform : o.transform
        }

        // Envelope origin = anchor object's rest world origin (translation only).
        let aPos = restPose(objects[anchorIndex]).columns.3
        let envT = TransformMath.translation(SIMD3<Float>(aPos.x, aPos.y, aPos.z))

        let env            = SceneObject(name: name)
        env.isEnvelope     = true
        env.transform      = envT
        env.baseTransform  = envT
        env.localTransform = envT
        objects.append(env)
        let envIndex = objects.count - 1

        // Re-base each member's rest pose into the envelope's frame.
        let invEnv = simd_inverse(envT)
        for mi in members {
            let m = objects[mi]
            let local = invEnv * restPose(m)
            m.parentIndex    = envIndex
            m.localTransform = local
            m.baseTransform  = local   // hierarchical parts store base = LOCAL
        }

        print("[DEBUG] SceneManager: makeEnvelope '\(name)' idx=\(envIndex)"
            + " members=\(members) anchor=\(anchorIndex)")
        return envIndex
    }

    /// Removes the envelope at `index`, re-rooting its members in place (their
    /// current world transform is preserved, parentIndex cleared) so nothing jumps.
    func removeEnvelope(at index: Int) {
        guard index >= 0, index < objects.count, objects[index].isEnvelope else {
            print("[DEBUG] SceneManager: removeEnvelope — index \(index) is not an envelope")
            return
        }
        // Re-root each member at its REST world pose so animation replays cleanly
        // (see reRootMember — using the current `transform` would re-bake the playhead
        // delta and scatter animated parts).
        let envRest = restPose(objects[index])
        for m in objects where m.parentIndex == index { reRootMember(m, envRest: envRest) }
        objects.remove(at: index)
        // Removal shifts every later index down by one — fix up any parentIndex that
        // pointed past the removed slot so other hierarchies stay valid.
        for o in objects {
            if let p = o.parentIndex, p > index { o.parentIndex = p - 1 }
        }
        print("[DEBUG] SceneManager: removeEnvelope — removed idx=\(index), remaining=\(objects.count)")
    }

    /// Adds existing top-level roots to an EXISTING envelope, re-basing each into the
    /// envelope's rest frame exactly as makeEnvelope does.  The array is NOT mutated
    /// (only parent links change), so indices stay valid.  Re-anchoring isn't done —
    /// the envelope keeps its current origin.
    func addEnvelopeMembers(envIndex: Int, memberIndices: [Int]) {
        guard envIndex >= 0, envIndex < objects.count, objects[envIndex].isEnvelope else { return }
        let envT   = objects[envIndex].baseTransform   // envelope REST frame
        let invEnv = simd_inverse(envT)
        func restPose(_ o: SceneObject) -> matrix_float4x4 {
            (o.keyframeTrack?.keyframes.isEmpty == false) ? o.baseTransform : o.transform
        }
        for mi in memberIndices where mi >= 0 && mi < objects.count
            && !objects[mi].isEnvelope && objects[mi].parentIndex == nil && mi != envIndex {
            let m = objects[mi]
            let local = invEnv * restPose(m)
            m.parentIndex    = envIndex
            m.localTransform = local
            m.baseTransform  = local   // hierarchical parts store base = LOCAL
        }
    }

    /// Removes specific members from an envelope, re-rooting each at its rest world
    /// pose (animation preserved without scatter — see reRootMember).  The envelope and
    /// array are kept (use removeEnvelope to dissolve the whole unit).
    func removeEnvelopeMembers(envIndex: Int, memberIndices: [Int]) {
        guard envIndex >= 0, envIndex < objects.count else { return }
        let envRest = restPose(objects[envIndex])
        for mi in memberIndices where mi >= 0 && mi < objects.count && objects[mi].parentIndex == envIndex {
            reRootMember(objects[mi], envRest: envRest)
        }
    }

    /// A member's REST pose — its `baseTransform` when animated (the anchor of its
    /// keyframe deltas), else its current `transform` (covers a statically dragged one).
    private func restPose(_ o: SceneObject) -> matrix_float4x4 {
        (o.keyframeTrack?.keyframes.isEmpty == false) ? o.baseTransform : o.transform
    }

    /// Re-roots a member leaving an envelope.  An ANIMATED member is restored to its
    /// REST WORLD pose (envelope rest × member local rest) so its unchanged keyframes
    /// replay in world space WITHOUT re-baking the playhead's delta into the base
    /// (which scattered the parts).  A STATIC member keeps its current world transform.
    private func reRootMember(_ m: SceneObject, envRest: matrix_float4x4) {
        let worldRest: matrix_float4x4 =
            (m.keyframeTrack?.keyframes.isEmpty == false) ? (envRest * m.baseTransform) : m.transform
        m.parentIndex    = nil
        m.localTransform = worldRest
        m.baseTransform  = worldRest
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
        // Match by the canonical display name (handles grouped models "hand 1" and
        // duplicated simple objects "cube 2"), falling back to the raw object name
        // for older projects that stored a plain part name.
        guard let obj = objects.first(where: { displayName(for: $0) == name })
            ?? objects.first(where: { $0.name == name })
        else { return nil }

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
