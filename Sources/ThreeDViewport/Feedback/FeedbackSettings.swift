import Combine

// All blend modes supported by the feedback compositor.
// Raw values are passed directly to the Metal shader as `uint blendMode`.
enum BlendMode: Int, CaseIterable, Identifiable {
    // Normal
    case normal       = 0

    // Darkening
    case multiply     = 1
    case darken       = 2
    case colorBurn    = 3
    case linearBurn   = 4

    // Lightening
    case screen       = 5
    case lighten      = 6
    case colorDodge   = 7
    case linearDodge  = 8   // Add

    // Contrast
    case overlay      = 9
    case softLight    = 10
    case hardLight    = 11
    case vividLight   = 12
    case linearLight  = 13
    case pinLight     = 14
    case hardMix      = 15

    // Difference
    case difference   = 16
    case exclusion    = 17
    case subtract     = 18
    case divide       = 19

    // Component (HSL)
    case hue          = 20
    case saturation   = 21
    case color        = 22
    case luminosity   = 23

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .normal:      return "Normal"
        case .multiply:    return "Multiply"
        case .darken:      return "Darken"
        case .colorBurn:   return "Color Burn"
        case .linearBurn:  return "Linear Burn"
        case .screen:      return "Screen"
        case .lighten:     return "Lighten"
        case .colorDodge:  return "Color Dodge"
        case .linearDodge: return "Linear Dodge"
        case .overlay:     return "Overlay"
        case .softLight:   return "Soft Light"
        case .hardLight:   return "Hard Light"
        case .vividLight:  return "Vivid Light"
        case .linearLight: return "Linear Light"
        case .pinLight:    return "Pin Light"
        case .hardMix:     return "Hard Mix"
        case .difference:  return "Difference"
        case .exclusion:   return "Exclusion"
        case .subtract:    return "Subtract"
        case .divide:      return "Divide"
        case .hue:         return "Hue"
        case .saturation:  return "Saturation"
        case .color:       return "Color"
        case .luminosity:  return "Luminosity"
        }
    }
}

// Observable settings for the feedback delay-line system.
// Shared between FeedbackPanel (UI), FeedbackProcessor (GPU), and VideoExporter.
final class FeedbackSettings: ObservableObject {

    // Master enable — when false the scene renders normally with no overhead.
    @Published var isEnabled:   Bool      = false

    // How many rendered frames between feedback ticks.
    @Published var interval:    Int       = 10

    // Blend weight: 0.0 = pure scene, 1.0 = full blend-mode result.
    @Published var decay:       Float     = 0.5

    // Queue depth: number of feedback frames held in the ring buffer.
    @Published var length:      Int       = 10

    // Blend mode applied when compositing scene against feedback buffer.
    @Published var blendMode:   BlendMode = .normal

    // When false: scene is foreground, feedback is background.
    // When true:  feedback is foreground, scene is background.
    @Published var swapLayers:  Bool      = false

    init() {
        print("[DEBUG] FeedbackSettings: initialized")
    }
}
