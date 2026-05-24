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
    @Published var baseColor:       Color           = .white
    @Published var hasSelection:    Bool            = false
    /// World-space position of the selection's first object.
    @Published var position:        SIMD3<Float>    = .zero
    /// Editing is allowed only for a single root object; copy works for any selection.
    @Published var canEditPosition: Bool            = false

    // ── Callbacks wired by AppDelegate ───────────────────────────────────────
    var onRebuildNormals: ((NormalMode, [SceneObject]) -> Void)?
    var onRedraw:         (() -> Void)?
    var onDirty:          (() -> Void)?
    var onRevealInFinder: (() -> Void)?

    // ── Private ───────────────────────────────────────────────────────────────
    private var targets:    [SceneObject] = []
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
        let c = first.material.baseColorFactor
        baseColor = Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))

        let t = first.transform.columns.3
        position        = SIMD3<Float>(t.x, t.y, t.z)
        canEditPosition = (newTargets.count == 1 && first.parentIndex == nil)
    }

    /// Re-reads the selected object's live world position so the field tracks
    /// viewport moves.  Suppresses the write-back sink and skips no-op updates.
    func refreshPosition() {
        guard hasSelection, let obj = targets.first else { return }
        let t = obj.transform.columns.3
        let p = SIMD3<Float>(t.x, t.y, t.z)
        if p != position {
            isUpdating = true
            position   = p
            isUpdating = false
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

        $baseColor.dropFirst()
            .sink { [weak self] color in
                guard let self, !isUpdating else { return }
                let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
                let v  = SIMD4<Float>(Float(ns.redComponent), Float(ns.greenComponent),
                                      Float(ns.blueComponent), 1)
                targets.forEach { $0.material.baseColorFactor = v }
                onRedraw?(); onDirty?()
            }.store(in: &cancellables)

        // Position — write back only for a single root object (canEditPosition).
        // Matches viewport object moves (set the transform's translation column).
        $position.dropFirst()
            .sink { [weak self] v in
                guard let self, !isUpdating, canEditPosition, let obj = targets.first else { return }
                obj.transform.columns.3 = SIMD4<Float>(v.x, v.y, v.z, 1)
                onRedraw?(); onDirty?()
            }.store(in: &cancellables)
    }
}
