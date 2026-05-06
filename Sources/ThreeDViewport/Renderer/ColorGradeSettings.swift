import Combine

// Observable model for the color grade post-process.
// Owned by ViewportView; observed by Renderer and VideoExporter.
final class ColorGradeSettings: ObservableObject {

    /// Additive brightness offset applied before contrast.  Range −1…+1.
    /// 0 = no change (identity).
    @Published var brightness: Float = 0.0

    /// Contrast multiplier scaled around the 0.5 midpoint.  Range 0…3.
    /// 1 = no change (identity).
    @Published var contrast: Float = 1.0

    /// Gamma correction (intuitive: higher lifts midtones, lower darkens them).
    /// Applied as pow(rgb, 1/gamma) so γ>1 brightens, γ<1 darkens.  Range 0.2…3.
    /// 1 = no change (identity).
    @Published var gamma: Float = 1.0

    /// True when all parameters are at their identity values — lets the
    /// renderer skip the pass entirely.
    var isIdentity: Bool { brightness == 0 && contrast == 1 && gamma == 1 }

    func reset() {
        brightness = 0
        contrast   = 1
        gamma      = 1
    }
}
