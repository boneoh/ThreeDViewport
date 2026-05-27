import SwiftUI
import Combine
import simd

// Observable state for the Model Inspector panel.
// Held on AppDelegate so the panel remembers its values across hide/show cycles.
// AppDelegate pushes a new selection in via update(targets:) and wires the callbacks
// to propagate changes back to the SceneObjects and the viewport.
final class ModelInspectorState: ObservableObject {

    // ── Displayed / editable properties ──────────────────────────────────────
    @Published var name:            String          = ""
    @Published var filename:        String          = ""
    @Published var partCount:       Int             = 0
    @Published var isVisible:       Bool            = true
    @Published var occludeWhenHidden: Bool          = false
    @Published var normalMode:      NormalMode      = .auto
    @Published var metallicFactor:  Float           = 0
    @Published var roughnessFactor: Float           = 0.5
    @Published var opacity:         Float           = 1
    @Published var baseColor:       Color           = .white
    @Published var hasSelection:    Bool            = false
    /// World-space position of the selection's anchor (preferred-root) part.
    @Published var position:        SIMD3<Float>    = .zero
    /// World-space Euler rotation (degrees, YXZ) of the anchor — for the sliders.
    @Published var rotation:        SIMD3<Float>    = .zero
    /// Per-axis scale of the anchor (world-effective: group × object when grouped).
    @Published var scale:           SIMD3<Float>    = SIMD3<Float>(1, 1, 1)
    /// Editing is allowed only for a single root object; copy works for any selection.
    @Published var canEditPosition: Bool            = false
    /// Rotation editing mirrors the same selection rule as position.
    @Published var canEditRotation: Bool            = false
    /// Scale editing is only enabled for a single non-grouped root.  Multi-part
    /// groups display the effective world scale but the sliders are greyed.
    @Published var canEditScale:    Bool            = false

    // ── Callbacks wired by AppDelegate ───────────────────────────────────────
    var onRebuildNormals: ((NormalMode, [SceneObject]) -> Void)?
    var onRedraw:         (() -> Void)?
    var onDirty:          (() -> Void)?
    var onRevealInFinder: (() -> Void)?
    /// Live world-space position of an object as the renderer draws it (group
    /// transform × object transform).  Wired by AppDelegate; without it the field
    /// would miss model/group animation, which lives in the group transform — not
    /// the object's own transform.
    var worldPosition:    ((SceneObject) -> SIMD3<Float>)?
    /// Moves a grouped selection (multi-part model) so its anchor part lands at the
    /// given world position — translates every root part of the group; FK children
    /// follow via the per-frame hierarchy pass.  Wired by AppDelegate.
    var setGroupWorldPosition: ((SceneObject, SIMD3<Float>) -> Void)?
    /// Live world-space Euler rotation (degrees, YXZ) of the anchor as drawn.
    /// Wired by AppDelegate; includes the group transform when present.
    var worldRotation:    ((SceneObject) -> SIMD3<Float>)?
    /// Rotates a grouped selection so the anchor's world rotation becomes the given
    /// Euler — pivots every root around the anchor's world position.  Wired by AppDelegate.
    var setGroupWorldRotation: ((SceneObject, SIMD3<Float>) -> Void)?
    /// Live world-effective scale of the anchor (group × object when grouped).
    /// Wired by AppDelegate; falls back to decomposing the local transform.
    var worldScale:       ((SceneObject) -> SIMD3<Float>)?
    /// Fires after a Paste or Z click on Position/Rotation.  AppDelegate wires it
    /// to conditionally stamp an object/group keyframe at the current playhead
    /// (only if the relevant track already has keyframes).
    var onAutoStamp:           (() -> Void)?

    // ── Private ───────────────────────────────────────────────────────────────
    private var targets:    [SceneObject] = []
    /// The part used to read/write Position — preferred-root within the selection
    /// (so the position shown is the model's overall position, not a child part's).
    private var anchor:     SceneObject?
    private var isUpdating: Bool          = false
    private var cancellables = Set<AnyCancellable>()

    init() { setupSinks() }

    // Push a new selection into state, suppressing the Combine sinks so that
    // reading from the objects doesn't immediately write back to them.
    func update(targets newTargets: [SceneObject]) {
        isUpdating   = true
        defer { isUpdating = false }
        targets      = newTargets
        hasSelection = !newTargets.isEmpty
        guard let first = newTargets.first else { return }

        name            = first.name
        filename        = first.sourceURL?.deletingPathExtension().lastPathComponent ?? ""
        partCount       = newTargets.count
        isVisible       = newTargets.allSatisfy { $0.isVisible }
        occludeWhenHidden = newTargets.allSatisfy { $0.occludeWhenHidden }
        normalMode      = first.normalMode
        metallicFactor  = first.material.metallicFactor
        roughnessFactor = first.material.roughnessFactor
        opacity         = first.material.opacity
        let c = first.material.baseColorFactor
        baseColor = Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))

        // Prefer a group root (parentIndex == nil) as the position anchor so the
        // field shows the model's overall position, not an arbitrary child part.
        anchor   = newTargets.first(where: { $0.parentIndex == nil }) ?? first
        position = anchor.map { worldPos(of: $0) } ?? .zero
        rotation = anchor.map { worldRot(of: $0) } ?? .zero
        scale    = anchor.map { worldScl(of: $0) } ?? SIMD3<Float>(1, 1, 1)

        // Editing is allowed for a single non-grouped root (writes obj.transform),
        // and for any uniform-group selection (translates / rotates the roots).
        let allSameGroup        = first.groupID != nil
                               && newTargets.allSatisfy { $0.groupID == first.groupID }
        let singleNonGroupRoot  = newTargets.count == 1
                               && first.parentIndex == nil && first.groupID == nil
        canEditPosition = singleNonGroupRoot || allSameGroup
        canEditRotation = canEditPosition
        // Scale edits write obj.transform's upper-3×3 directly, so only enable
        // for a single non-grouped root — groups would need to scale every part.
        canEditScale    = singleNonGroupRoot
    }

    /// World position of `obj` as drawn (group transform × transform), via the
    /// provider wired by AppDelegate; falls back to the local translation.
    private func worldPos(of obj: SceneObject) -> SIMD3<Float> {
        if let wp = worldPosition { return wp(obj) }
        let t = obj.transform.columns.3
        return SIMD3<Float>(t.x, t.y, t.z)
    }

    /// World rotation (YXZ Euler degrees) of `obj` as drawn, via the provider
    /// wired by AppDelegate; falls back to decomposing the local transform.
    private func worldRot(of obj: SceneObject) -> SIMD3<Float> {
        if let wr = worldRotation { return wr(obj) }
        return TransformMath.eulerFromMatrix(obj.transform)
    }

    /// World-effective scale of `obj` as drawn, via the provider wired by
    /// AppDelegate; falls back to decomposing the local transform.
    private func worldScl(of obj: SceneObject) -> SIMD3<Float> {
        if let ws = worldScale { return ws(obj) }
        return TransformMath.scale(of: obj.transform)
    }

    /// Re-reads the anchor's live world position + rotation + scale so the
    /// fields track viewport moves.  Suppresses the write-back sinks and skips
    /// no-op updates.  Opacity is also re-read because it is the only material
    /// value driven by the timeline today — without this, the slider would lag
    /// when the playhead moves through an opacity-bearing keyframe track.
    func refresh() {
        guard hasSelection, let obj = anchor else { return }
        let p = worldPos(of: obj)
        if p != position {
            isUpdating = true; position = p; isUpdating = false
        }
        let r = worldRot(of: obj)
        if r != rotation {
            isUpdating = true; rotation = r; isUpdating = false
        }
        let s = worldScl(of: obj)
        if s != scale {
            isUpdating = true; scale = s; isUpdating = false
        }
        let op = obj.material.opacity
        if op != opacity {
            isUpdating = true; opacity = op; isUpdating = false
        }
    }

    // MARK: - Combine sinks

    private func setupSinks() {
        $name.dropFirst()
            .sink { [weak self] v in
                guard let self, !isUpdating, let root = targets.first else { return }
                root.name = v
                onDirty?()
            }.store(in: &cancellables)

        $isVisible.dropFirst()
            .sink { [weak self] v in
                guard let self, !isUpdating else { return }
                targets.forEach { $0.isVisible = v }
                onRedraw?(); onDirty?()
            }.store(in: &cancellables)

        $occludeWhenHidden.dropFirst()
            .sink { [weak self] v in
                guard let self, !isUpdating else { return }
                targets.forEach { $0.occludeWhenHidden = v }
                onRedraw?(); onDirty?()
            }.store(in: &cancellables)

        $normalMode.dropFirst()
            .sink { [weak self] v in
                guard let self, !isUpdating else { return }
                onRebuildNormals?(v, targets)
                targets.forEach { $0.normalMode = v }
                onDirty?()
            }.store(in: &cancellables)

        $metallicFactor.dropFirst()
            .sink { [weak self] v in
                guard let self, !isUpdating else { return }
                targets.forEach { $0.material.metallicFactor = v }
                onRedraw?(); onDirty?()
            }.store(in: &cancellables)

        $roughnessFactor.dropFirst()
            .sink { [weak self] v in
                guard let self, !isUpdating else { return }
                targets.forEach { $0.material.roughnessFactor = v }
                onRedraw?(); onDirty?()
            }.store(in: &cancellables)

        $opacity.dropFirst()
            .sink { [weak self] v in
                guard let self, !isUpdating else { return }
                targets.forEach { $0.material.opacity = v }
                onRedraw?(); onDirty?()
            }.store(in: &cancellables)

        $baseColor.dropFirst()
            .sink { [weak self] color in
                guard let self, !isUpdating else { return }
                let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
                let v  = SIMD4<Float>(Float(ns.redComponent), Float(ns.greenComponent),
                                      Float(ns.blueComponent), 1)
                targets.forEach { $0.material.baseColorFactor = v }
                onRedraw?(); onDirty?()
            }.store(in: &cancellables)

        // Position — non-grouped objects edit obj.transform directly; grouped
        // selections delegate to AppDelegate (translates the group's root parts so
        // the change persists in obj.transform like single-object edits do).
        $position.dropFirst()
            .sink { [weak self] v in
                guard let self, !isUpdating, canEditPosition, let obj = anchor else { return }
                if obj.groupID != nil {
                    setGroupWorldPosition?(obj, v)
                } else {
                    obj.transform.columns.3 = SIMD4<Float>(v.x, v.y, v.z, 1)
                }
                onRedraw?(); onDirty?()
            }.store(in: &cancellables)

        // Rotation — non-grouped objects rebuild obj.transform's upper-3×3 from
        // the new Euler (preserving scale + translation); grouped selections
        // delegate to AppDelegate so the whole model rotates around the anchor.
        $rotation.dropFirst()
            .sink { [weak self] euler in
                guard let self, !isUpdating, canEditRotation, let obj = anchor else { return }
                if obj.groupID != nil {
                    setGroupWorldRotation?(obj, euler)
                } else {
                    let s = TransformMath.scale(of: obj.transform)
                    let R = TransformMath.matrixFromEuler(euler)
                    obj.transform = TransformMath.applying(rotation: R, scale: s, to: obj.transform)
                }
                onRedraw?(); onDirty?()
            }.store(in: &cancellables)

        // Scale — single non-grouped roots only.  Rebuilds obj.transform's
        // upper-3×3 from the existing pure rotation and the new per-axis scale,
        // preserving translation.  Grouped selections are greyed (canEditScale).
        $scale.dropFirst()
            .sink { [weak self] s in
                guard let self, !isUpdating, canEditScale, let obj = anchor else { return }
                let R = TransformMath.pureRotation(of: obj.transform)
                obj.transform = TransformMath.applying(rotation: R, scale: s, to: obj.transform)
                onRedraw?(); onDirty?()
            }.store(in: &cancellables)
    }
}
