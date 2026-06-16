import Foundation

/// Single source of truth for every user-facing limit in the app.
///
/// Two kinds live here:
///  • **World-space movement clamps** — enforced in the viewport / camera / lights
///    when you move things with the keys, drag, or scroll.  Hitting one is NOT a
///    silent failure: it beeps and logs (see `ViewportView.reportLimit(_:)`).
///  • **Inspector slider ranges** — the min…max each panel slider allows.  These
///    stop visibly at the slider handle, so they don't beep.
///
/// Keeping them in one place makes it easy to see — and tune — what the app allows.
/// Slider ranges are typed to match their slider: `Float` for `SliderRow` /
/// `FogSliderRow` / `GradeSliderRow`, `Double` for `TunableSlider`.
enum SceneLimits {

    // MARK: - World-space movement clamps (viewport keys / drag / scroll)

    /// Max |x|,|y|,|z| for any movable entity (object, light, probe, camera target).
    /// Also the range of every position slider (`positionRange`).
    static let positionBound: Float = 100

    /// Closest a depth-dolly (+/−, scroll) pulls an entity toward the eye.
    static let dollyNearMin: Float = 0.5

    /// Camera / Director orbit + scroll-zoom distance range.
    static let orbitDistanceMin: Float = 0.05
    static let orbitDistanceMax: Float = 5000

    /// Floor for the Director's auto-fit / snap distance.
    static let directorDistanceFloor: Float = 0.1

    /// Lens field-of-view (zoom) limits, radians.  10° (narrow) … 90° (wide).
    static let fovMinRadians: Float = .pi / 18
    static let fovMaxRadians: Float = .pi / 2

    // MARK: - Shared transform slider ranges (Model / Camera / Lights / Atmosphere)

    /// Position X/Y/Z — the same bound the viewport clamp enforces.
    static let positionRange: ClosedRange<Float> = -positionBound...positionBound
    /// Euler rotation, degrees.
    static let rotationRange: ClosedRange<Float> = -180...180
    /// Per-axis scale.
    static let scaleRange: ClosedRange<Float> = 0.01...10

    // MARK: - Camera panel
    static let focalLengthRange:  ClosedRange<Float> = 12...140       // mm, 35mm-equivalent
    static let povDistanceRange:  ClosedRange<Float> = 0.05...5
    static let povAzimuthRange:   ClosedRange<Float> = -180...180
    static let povElevationRange: ClosedRange<Float> = -90...90

    // MARK: - Lights panel
    static let lightIntensityRange: ClosedRange<Float>  = 0...10
    static let lightAttenRange:     ClosedRange<Float>  = 0...50      // point/spot/laser "Range"
    static let coneAngleRange:      ClosedRange<Float>  = 0...(.pi / 2)
    static let beamThicknessRange:  ClosedRange<Float>  = 1...30
    static let envIntensityRange:   ClosedRange<Float>  = 0...4       // HDRI backdrop intensity
    static let envHorizonRange:     ClosedRange<Float>  = -1...1
    static let iblIntensityRange:   ClosedRange<Double> = 0...2       // TunableSlider

    // MARK: - Atmosphere panel (fog + emitters)
    static let densityRange:    ClosedRange<Float> = 0...1            // fog + emitter density
    static let varianceRange:   ClosedRange<Float> = 0...1
    static let fogQualityRange: ClosedRange<Float> = 8...96           // raymarch steps
    static let fogSizeRange:    ClosedRange<Float> = 0.5...40
    static let emitterSizeRange:     ClosedRange<Float> = 0.005...0.5
    static let emitterLifetimeRange: ClosedRange<Float> = 0.5...12
    static let emitterGrowthRange:   ClosedRange<Float> = 0...12
    static let emitterOpacityRange:  ClosedRange<Float> = 0.02...1
    static let fallSpeedRange:       ClosedRange<Float> = 0...20
    static let streakRange:          ClosedRange<Float> = 1...16

    // MARK: - Model material overrides
    /// Metallic / Roughness / Opacity / Brightness — all normalized 0…1.
    static let materialRange: ClosedRange<Float> = 0...1

    // MARK: - Feedback panel
    static let feedbackDecayRange: ClosedRange<Float> = 0...1
    static let feedbackFrameRange: ClosedRange<Int>   = 1...60   // Interval / Length, frames

    // MARK: - Color Grade panel
    static let gradeExposureRange:   ClosedRange<Float> = 0.1...4
    static let gradeBrightnessRange: ClosedRange<Float> = -1...1
    static let gradeContrastRange:   ClosedRange<Float> = 0...3
    static let gradeGammaRange:      ClosedRange<Float> = 0.2...3

    // MARK: - Settings
    static let sensitivityRange: ClosedRange<Double> = 0.1...10       // drag / arrow multipliers
}
