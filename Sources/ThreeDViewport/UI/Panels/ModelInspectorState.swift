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
    // Visible / Holdout / Class moved to the Effects grid (Window ▸ Effects).
    @Published var normalMode:      NormalMode      = .auto
    @Published var metallicFactor:  Float           = 0
    @Published var roughnessFactor: Float           = 0.5
    @Published var opacity:         Float           = 1
    @Published var baseColor:       Color           = .white
    @Published var emissiveStrength: Float          = 0
    @Published var hasSelection:    Bool            = false
    /// True when the selection can be added to the Favorite Models folder (has a
    /// real sourceURL, not already inside favourites, and no alias exists yet).
    /// Computed by AppDelegate via `favoritesEligible` on each selection change.
    @Published var canAddToFavorites: Bool          = false
    /// World-space position of the selection's anchor (preferred-root) part.
    @Published var position:        SIMD3<Float>    = .zero
    /// World-space Euler rotation (degrees, YXZ) of the anchor — for the sliders.
    @Published var rotation:        SIMD3<Float>    = .zero
    /// Per-axis scale of the anchor (world-effective: group × object when grouped).
    @Published var scale:           SIMD3<Float>    = SIMD3<Float>(1, 1, 1)
    /// Editing is allowed only for a single root object; copy works for any selection.
    @Published var canEditPosition: Bool            = false
    /// Name is editable only for a standalone object (renaming a model root doesn't
    /// change its filename-derived timeline name).
    @Published var canEditName:     Bool            = false
    /// Rotation editing mirrors the same selection rule as position.
    @Published var canEditRotation: Bool            = false
    /// Scale editing is enabled for a single non-grouped root (writes
    /// obj.transform directly) and for a uniform-group selection (delegates
    /// to setGroupWorldScale so the whole model scales about its anchor).
    @Published var canEditScale:    Bool            = false
    /// True when the selected model is locked (Timeline padlock).  The panel disables
    /// its editing controls; the Reveal link + Add to Favorites stay enabled.
    @Published var isLocked:        Bool            = false

    // ── Callbacks wired by AppDelegate ───────────────────────────────────────
    var onRebuildNormals: ((NormalMode, [SceneObject]) -> Void)?
    var onRedraw:         (() -> Void)?
    /// Returns true while the timeline is playing.  When playing, the 10 Hz
    /// live-readout poll (`refresh()`) is skipped so an animating selection doesn't
    /// re-render this panel every tick and starve the render loop.
    var isPlaying:        (() -> Bool)?
    /// True while a video export is running.  The export evaluates animation on a
    /// background queue and mutates `sceneManager.groupTransforms`; refresh() reads
    /// the same dictionary, so polling during export is a data race — skip it.
    var isExporting:      (() -> Bool)?
    /// Returns whether the currently inspected model is locked (Timeline padlock).
    var isLockedProvider: (() -> Bool)?
    var onDirty:          (() -> Void)?
    var onRevealInFinder: (() -> Void)?
    /// Creates a Favorite Models alias for the current selection (wired by AppDelegate).
    var onAddToFavorites: (() -> Void)?
    /// Opens the Add Position Mark dialog at the current probe position (wired by AppDelegate).
    var onAddMark: (() -> Void)?
    /// Returns whether the given selection is eligible for "Add to Favorites".
    /// Wired by AppDelegate; consulted in update() to set `canAddToFavorites`.
    var favoritesEligible: (([SceneObject]) -> Bool)?
    /// Live world-space position of an object as the renderer draws it (group
    /// transform × object transform).  Wired by AppDelegate; without it the field
    /// would miss model/group animation, which lives in the group transform — not
    /// the object's own transform.
    var worldPosition:    ((SceneObject) -> SIMD3<Float>)?
    /// Moves a grouped selection (multi-part model) so its anchor part lands at the
    /// given world position — translates every root part of the group; FK children
    /// follow via the per-frame hierarchy pass.  Wired by AppDelegate.
    var setGroupWorldPosition: ((SceneObject, SIMD3<Float>) -> Void)?
    /// Live world-space rotation MATRIX of the anchor as drawn (incl. group
    /// transform when present).  Wired by AppDelegate.  Euler is derived from it
    /// here so the read-back can pick the representation continuous with the
    /// currently displayed angles (avoids gimbal-lock snapping).
    var worldRotationMatrix: ((SceneObject) -> matrix_float4x4)?
    /// Rotates a grouped selection so the anchor's world rotation becomes the given
    /// Euler — pivots every root around the anchor's world position.  Wired by AppDelegate.
    var setGroupWorldRotation: ((SceneObject, SIMD3<Float>) -> Void)?
    /// Scales a grouped selection so the anchor's world scale becomes the given
    /// per-axis scale — scales every root about the anchor's world position
    /// (so children move apart/closer AND grow/shrink in place).  Wired by AppDelegate.
    var setGroupWorldScale:    ((SceneObject, SIMD3<Float>) -> Void)?
    /// Live world-effective scale of the anchor (group × object when grouped).
    /// Wired by AppDelegate; falls back to decomposing the local transform.
    var worldScale:       ((SceneObject) -> SIMD3<Float>)?
    /// Fires after a Paste or Z click on Position/Rotation.  AppDelegate wires it
    /// to conditionally stamp an object/group keyframe at the current playhead
    /// (only if the relevant track already has keyframes).
    var onAutoStamp:           (() -> Void)?
    /// Fires when a transform/opacity slider edit ends.  AppDelegate wires it to the
    /// auto-keyframe-on-edit feature (gated by its two settings).
    var onSliderEdited:        (() -> Void)?

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
    func update(targets newTargets: [SceneObject], displayName: String) {
        isUpdating   = true
        defer { isUpdating = false }
        targets      = newTargets
        hasSelection = !newTargets.isEmpty
        guard let first = newTargets.first else { return }

        // Matches the Timeline Editor's first-column name (group display name with
        // any duplicate-instance suffix for models; object name for standalone).
        name            = displayName
        filename        = first.sourceURL?.deletingPathExtension().lastPathComponent ?? ""
        partCount       = newTargets.count
        normalMode      = first.normalMode
        metallicFactor  = first.material.metallicFactor
        roughnessFactor = first.material.roughnessFactor
        opacity         = first.material.opacity
        emissiveStrength = first.material.emissiveStrength
        let c = first.material.baseColorFactor
        baseColor = Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))

        // Prefer a group root (parentIndex == nil) as the position anchor so the
        // field shows the model's overall position, not an arbitrary child part.
        // For a lone child part, the anchor is that part (shown in its LOCAL frame).
        anchor   = newTargets.first(where: { $0.parentIndex == nil }) ?? first
        position = anchor.map { displayPos(of: $0) } ?? .zero
        // Fresh selection: canonical Euler (no continuity hint to bias toward).
        rotation = anchor.map { TransformMath.eulerFromMatrix(displayMatrix(of: $0)) } ?? .zero
        scale    = anchor.map { displayScl(of: $0) } ?? SIMD3<Float>(1, 1, 1)

        // Editing is allowed for a single non-grouped root (writes obj.transform),
        // any uniform-group selection (translates / rotates the roots), and a single
        // child part (poses it in its local frame).
        let allSameGroup        = first.groupID != nil
                               && newTargets.allSatisfy { $0.groupID == first.groupID }
        let singleNonGroupRoot  = newTargets.count == 1
                               && first.parentIndex == nil && first.groupID == nil
        canEditPosition = singleNonGroupRoot || allSameGroup || isSinglePart
        canEditRotation = canEditPosition
        canEditScale    = canEditPosition
        // The name is editable only for a standalone object (renaming a model's
        // root doesn't change its filename-derived timeline name, so it's read-only).
        canEditName     = singleNonGroupRoot

        canAddToFavorites = favoritesEligible?(newTargets) ?? false
    }

    /// True when exactly one hierarchical CHILD part is selected (`parentIndex != nil`).
    /// Such a part is posed in its LOCAL frame (relative to its parent) and keyframes its
    /// OWN track — not the group.  A whole-model selection (the root + its parts) and a
    /// standalone object both report false.
    var isSinglePart: Bool {
        targets.count == 1 && (targets.first?.parentIndex != nil)
    }

    /// Position shown in the fields: a child part's LOCAL translation, else world.
    private func displayPos(of obj: SceneObject) -> SIMD3<Float> {
        if isSinglePart {
            let t = obj.localTransform.columns.3
            return SIMD3<Float>(t.x, t.y, t.z)
        }
        return worldPos(of: obj)
    }

    /// Rotation matrix shown in the fields: a child part's LOCAL transform, else world.
    private func displayMatrix(of obj: SceneObject) -> matrix_float4x4 {
        isSinglePart ? obj.localTransform : worldMatrix(of: obj)
    }

    /// Scale shown in the fields: a child part's LOCAL scale, else world-effective.
    private func displayScl(of obj: SceneObject) -> SIMD3<Float> {
        isSinglePart ? TransformMath.scale(of: obj.localTransform) : worldScl(of: obj)
    }

    /// World position of `obj` as drawn (group transform × transform), via the
    /// provider wired by AppDelegate; falls back to the local translation.
    private func worldPos(of obj: SceneObject) -> SIMD3<Float> {
        if let wp = worldPosition { return wp(obj) }
        let t = obj.transform.columns.3
        return SIMD3<Float>(t.x, t.y, t.z)
    }

    /// World rotation matrix of `obj` as drawn, via the provider wired by
    /// AppDelegate; falls back to the local transform.
    private func worldMatrix(of obj: SceneObject) -> matrix_float4x4 {
        worldRotationMatrix?(obj) ?? obj.transform
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
        // Poll the lock first (cheap bool) so controls disable/enable promptly when the
        // Timeline padlock is toggled — even while playing/exporting.
        let lk = isLockedProvider?() ?? false
        if lk != isLocked { isLocked = lk }
        guard !(isPlaying?() ?? false) else { return }
        guard !(isExporting?() ?? false) else { return }   // avoid racing the export thread
        guard hasSelection, let obj = anchor else { return }
        let p = displayPos(of: obj)
        if p != position {
            isUpdating = true; position = p; isUpdating = false
        }
        // Continuity read-back: pick the Euler representation nearest the current
        // displayed angles so X = ±90° doesn't snap Y/Z to an equivalent triple.
        let r = TransformMath.eulerFromMatrix(displayMatrix(of: obj), near: rotation)
        if r != rotation {
            isUpdating = true; rotation = r; isUpdating = false
        }
        let s = displayScl(of: obj)
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

        $emissiveStrength.dropFirst()
            .sink { [weak self] v in
                guard let self, !isUpdating else { return }
                targets.forEach { $0.material.emissiveStrength = v }
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

        // Position — a whole-model (group root) selection delegates to AppDelegate; a
        // single child part edits its LOCAL translation (relative to its parent); a
        // standalone object edits obj.transform directly.
        $position.dropFirst()
            .sink { [weak self] v in
                guard let self, !isUpdating, canEditPosition, let obj = anchor else { return }
                if obj.parentIndex == nil, obj.groupID != nil {
                    setGroupWorldPosition?(obj, v)
                } else if obj.parentIndex != nil {
                    obj.localTransform.columns.3 = SIMD4<Float>(v.x, v.y, v.z, 1)
                } else {
                    obj.transform.columns.3 = SIMD4<Float>(v.x, v.y, v.z, 1)
                }
                onRedraw?(); onDirty?()
            }.store(in: &cancellables)

        // Rotation — whole model delegates to AppDelegate (rotates around the anchor);
        // a single child part rebuilds its LOCAL rotation (preserving local scale +
        // translation) so it poses like an FK joint; a standalone object edits world.
        $rotation.dropFirst()
            .sink { [weak self] euler in
                guard let self, !isUpdating, canEditRotation, let obj = anchor else { return }
                if obj.parentIndex == nil, obj.groupID != nil {
                    setGroupWorldRotation?(obj, euler)
                } else if obj.parentIndex != nil {
                    let s = TransformMath.scale(of: obj.localTransform)
                    let R = TransformMath.matrixFromEuler(euler)
                    obj.localTransform = TransformMath.applying(rotation: R, scale: s, to: obj.localTransform)
                } else {
                    let s = TransformMath.scale(of: obj.transform)
                    let R = TransformMath.matrixFromEuler(euler)
                    obj.transform = TransformMath.applying(rotation: R, scale: s, to: obj.transform)
                }
                onRedraw?(); onDirty?()
            }.store(in: &cancellables)

        // Scale — whole model delegates to AppDelegate (scales about the anchor); a
        // single child part rebuilds its LOCAL scale (preserving local rotation +
        // translation); a standalone object edits world.
        $scale.dropFirst()
            .sink { [weak self] s in
                guard let self, !isUpdating, canEditScale, let obj = anchor else { return }
                if obj.parentIndex == nil, obj.groupID != nil {
                    setGroupWorldScale?(obj, s)
                } else if obj.parentIndex != nil {
                    let R = TransformMath.pureRotation(of: obj.localTransform)
                    obj.localTransform = TransformMath.applying(rotation: R, scale: s, to: obj.localTransform)
                } else {
                    let R = TransformMath.pureRotation(of: obj.transform)
                    obj.transform = TransformMath.applying(rotation: R, scale: s, to: obj.transform)
                }
                onRedraw?(); onDirty?()
            }.store(in: &cancellables)
    }
}
