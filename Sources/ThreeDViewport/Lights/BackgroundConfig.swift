import Combine
import Metal
import simd

// Background display mode.
enum BackgroundMode: Int, CaseIterable {
    case solid       = 0
    case gradient    = 1
    case environment = 2   // skybox sampled from the IBL environment

    var displayName: String {
        switch self {
        case .solid:       return "Solid"
        case .gradient:    return "Gradient"
        case .environment: return "Environment"
        }
    }
}

// Phase 7: Observable background configuration.
// Renderer reads this each frame to choose clear colour or gradient draw.
final class BackgroundConfig: ObservableObject {

    @Published var mode:           BackgroundMode  = .solid
    @Published var solidColor:     SIMD3<Float>    = SIMD3<Float>(0, 0, 0)
    @Published var gradientTop:    SIMD3<Float>    = SIMD3<Float>(0.05, 0.06, 0.14)  // deep blue
    @Published var gradientBottom: SIMD3<Float>    = SIMD3<Float>(0, 0, 0)
    /// Brightness multiplier applied to the environment skybox backdrop.
    @Published var environmentIntensity: Float     = 1.0

    init() {
        print("[DEBUG] BackgroundConfig: initialized")
    }

    // MTLClearColor for the current mode.
    // Gradient mode uses the bottom colour so any gap below the quad is seamless.
    var clearColor: MTLClearColor {
        switch mode {
        case .solid:
            return MTLClearColor(red:   Double(solidColor.x),
                                 green: Double(solidColor.y),
                                 blue:  Double(solidColor.z),
                                 alpha: 1.0)
        case .gradient:
            return MTLClearColor(red:   Double(gradientBottom.x),
                                 green: Double(gradientBottom.y),
                                 blue:  Double(gradientBottom.z),
                                 alpha: 1.0)
        case .environment:
            // The skybox pass fills the frame; clear to black underneath.
            return MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1.0)
        }
    }

    // BackgroundUniforms struct passed to the gradient fragment shader.
    var backgroundUniforms: BackgroundUniforms {
        return BackgroundUniforms(
            colorTop:    SIMD4<Float>(gradientTop,    1),
            colorBottom: SIMD4<Float>(gradientBottom, 1)
        )
    }
}
