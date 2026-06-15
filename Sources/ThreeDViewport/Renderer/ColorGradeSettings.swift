import Combine

// Observable model for the color grade post-process.
// Owned by ViewportView; observed by Renderer and VideoExporter.
final class ColorGradeSettings: ObservableObject {

    /// Scene exposure — a linear multiplier applied PRE-tone-map in the main
    /// scene shader (not in the post-process grade pass like the fields below).
    /// Lives here so it shares the Color Grade panel + per-project persistence.
    /// 1 = no change (identity).
    @Published var exposure: Float = 1.0

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

    /// Edit lock — freezes the Color Grade panel's controls (persisted with the project).
    @Published var isLocked: Bool = false

    /// True when the POST-PROCESS parameters are at identity — lets the renderer
    /// skip the color-grade pass.  Exposure is excluded on purpose: it's applied
    /// in the main scene shader, not in that pass.
    var isIdentity: Bool {
        // Small epsilon (~1/2048 step) so JSON round-trip drift on default sliders
        // doesn't keep the post-pass active for an effectively no-op grade.
        let eps: Float = 0.001
        return abs(brightness)     < eps
            && abs(contrast - 1)   < eps
            && abs(gamma    - 1)   < eps
    }

    func reset() {
        exposure   = 1
        brightness = 0
        contrast   = 1
        gamma      = 1
    }
}
