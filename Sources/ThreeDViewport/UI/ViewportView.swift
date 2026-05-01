import AppKit
import MetalKit

// The main Metal viewport. Subclasses MTKView (which is NSView on macOS)
// so we get a managed drawable, display-link loop, and depth buffer for free.
final class ViewportView: MTKView {

    // Owned objects
    let sceneManager: SceneManager
    let camera: CameraController
    let lightManager: LightManager
    var renderer: Renderer?

    // Input state
    private var lastMouseLocation: NSPoint = .zero
    private var isSpaceDown: Bool = false

    // MARK: - Init

    init(frame: NSRect) {
        sceneManager = SceneManager()
        camera       = CameraController()
        lightManager = LightManager()

        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            // Hard stop — no Metal means nothing works
            fatalError("[DEBUG] ViewportView: MTLCreateSystemDefaultDevice returned nil — Metal not supported on this machine")
        }

        super.init(frame: frame, device: metalDevice)

        print("[DEBUG] ViewportView: using Metal device '" + metalDevice.name + "'")

        // Configure MTKView
        colorPixelFormat        = .bgra8Unorm
        depthStencilPixelFormat = .depth32Float
        clearColor              = MTLClearColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1.0)
        preferredFramesPerSecond = 30
        isPaused                = false
        enableSetNeedsDisplay   = false

        // Build renderer
        renderer = Renderer(
            device: metalDevice,
            sceneManager: sceneManager,
            camera: camera,
            lightManager: lightManager
        )

        if renderer == nil {
            print("[DEBUG] ViewportView: Renderer init returned nil")
        }

        delegate = renderer
    }

    required init(coder: NSCoder) {
        fatalError("ViewportView does not support NSCoder initialisation")
    }

    // MARK: - Model Loading

    func loadModel(url: URL) {
        guard let dev = device else {
            print("[DEBUG] ViewportView: loadModel — device is nil")
            return
        }

        print("[DEBUG] ViewportView: loadModel start — " + url.lastPathComponent)

        let loader = GLTFLoader(device: dev)

        if let obj = loader.load(url: url) {
            autoNormalize(obj)
            sceneManager.objects = [obj]
            camera.fitToScene(boundingRadius: obj.boundingRadius, center: obj.boundingCenter)
            print("[DEBUG] ViewportView: model loaded, objects count = " + String(sceneManager.objects.count))
        } else {
            print("[DEBUG] ViewportView: GLTFLoader returned nil for " + url.lastPathComponent)
        }
    }

    // MARK: - Auto-normalization

    // Scales the object uniformly so its world-space bounding radius equals targetRadius.
    // IMPORTANT: obj.boundingRadius and obj.boundingCenter are in LOCAL (mesh) space.
    // The node transform (obj.transform) may already contain a scale — e.g. a model
    // exported in centimetres will have scale=0.01 baked into its matrix.
    // We must convert to WORLD space first, otherwise we double-apply the existing scale.
    private func autoNormalize(_ obj: SceneObject) {
        let targetRadius: Float = 1.0
        let t = obj.transform
        let localCenter = obj.boundingCenter
        let localRadius = obj.boundingRadius

        // ── Step 1: world-space bounding center ──────────────────────────────
        // Multiply local center through the full node transform (column-major M * v).
        let lc4 = SIMD4<Float>(localCenter.x, localCenter.y, localCenter.z, 1.0)
        let wc4 = t * lc4
        let worldCenter = SIMD3<Float>(wc4.x, wc4.y, wc4.z)   // w is always 1 for affine

        // ── Step 2: world-space bounding radius ──────────────────────────────
        // Approximate by multiplying localRadius by the largest column-scale in the
        // upper-left 3x3. This correctly handles uniform and near-uniform scales.
        let sx = simd_length(SIMD3<Float>(t.columns.0.x, t.columns.0.y, t.columns.0.z))
        let sy = simd_length(SIMD3<Float>(t.columns.1.x, t.columns.1.y, t.columns.1.z))
        let sz = simd_length(SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z))
        let transformScale = max(sx, max(sy, sz))

        if transformScale < 0.0001 {
            print("[DEBUG] ViewportView: autoNormalize — transform scale is near zero, skipping")
            return
        }

        let worldRadius = localRadius * transformScale

        print("[DEBUG] ViewportView: autoNormalize localRadius=" + String(localRadius)
            + " transformScale=" + String(transformScale)
            + " worldRadius=" + String(worldRadius))

        guard worldRadius > 0.0001 else {
            print("[DEBUG] ViewportView: autoNormalize — worldRadius near zero, skipping")
            return
        }

        // Always promote bounding sphere to world space so fitToScene is correct,
        // even when no additional scaling is needed.
        obj.boundingCenter = worldCenter
        obj.boundingRadius = worldRadius

        // Only apply an extra scale if the model is more than 2 % off target size
        let scale = targetRadius / worldRadius
        guard abs(scale - 1.0) > 0.02 else {
            print("[DEBUG] ViewportView: autoNormalize — worldRadius " + String(worldRadius) + " already near 1.0, bounding sphere updated to world space")
            return
        }

        // ── Step 3: prepend a uniform scale to the node transform ─────────────
        var S = matrix_identity_float4x4
        S.columns.0.x = scale
        S.columns.1.y = scale
        S.columns.2.z = scale

        obj.transform      = S * t
        obj.boundingCenter = worldCenter * scale
        obj.boundingRadius = targetRadius

        print("[DEBUG] ViewportView: autoNormalize scale=" + String(scale)
            + " worldRadius=" + String(worldRadius) + " -> " + String(targetRadius)
            + " newCenter=(" + String(obj.boundingCenter.x)
            + "," + String(obj.boundingCenter.y)
            + "," + String(obj.boundingCenter.z) + ")")
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { return true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    // MARK: - Mouse Input

    override func mouseDown(with event: NSEvent) {
        lastMouseLocation = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let dx  = Float(loc.x - lastMouseLocation.x)
        let dy  = Float(loc.y - lastMouseLocation.y)
        lastMouseLocation = loc

        if isSpaceDown {
            camera.pan(deltaX: dx, deltaY: dy)
        } else {
            camera.orbit(deltaX: dx, deltaY: dy)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        camera.zoom(delta: Float(event.scrollingDeltaY))
    }

    // MARK: - Keyboard Input

    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat else { return }

        switch event.keyCode {
        case 49:   // Space — held for pan mode
            isSpaceDown = true
            print("[DEBUG] ViewportView: space key down — pan mode active")

        case 5:    // G — wireframe toggle
            if let r = renderer {
                r.isWireframe.toggle()
                print("[DEBUG] ViewportView: wireframe = " + String(r.isWireframe))
            } else {
                print("[DEBUG] ViewportView: G pressed but renderer is nil")
            }

        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        switch event.keyCode {
        case 49:   // Space
            isSpaceDown = false
        default:
            super.keyUp(with: event)
        }
    }

    // MARK: - Multi-select (Phase 3 placeholder)
    // Shift + click selection will be wired up in Phase 3.
}
