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
    @Published var normalMode:      NormalMode      = .auto
    @Published var metallicFactor:  Float           = 0
    @Published var roughnessFactor: Float           = 0.5
    @Published var baseColor:       Color           = .white
    @Published var hasSelection:    Bool            = false

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
        normalMode      = first.normalMode
        metallicFactor  = first.material.metallicFactor
        roughnessFactor = first.material.roughnessFactor
        let c = first.material.baseColorFactor
        baseColor = Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
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
    }
}
