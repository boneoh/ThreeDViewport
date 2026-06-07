import Foundation
import simd

// Rate-marker schedules for the Spin and Orbit animators.
//
// Unlike the older windowed bakers (revolutions over a captured [start, end]),
// these describe motion as a *rate* (revolutions / second) that takes effect at a
// marker's time and continues until the next marker — or, for the last marker, to
// the end of the timeline.  A marker with rate 0 holds still from that point.
//
// The dense pose keyframes the renderer actually plays are regenerated from these
// markers (see ViewportView.regenerateSpinRate / regenerateOrbitRate); the markers
// are the editable source of truth and are persisted in the project file so rates
// stay adjustable across save / reload.

/// One spin rate change: spin at `rate` rev/s about the object's local `axisIndex`
/// (0 = X, 1 = Y, 2 = Z) starting at `time`.  Signed rate sets direction.
struct SpinRateMarker: Identifiable, Equatable {
    let id = UUID()
    var time:      Double
    var rate:      Double   // revolutions / second, signed
    var axisIndex: Int      // 0 = X, 1 = Y, 2 = Z
}

/// One orbit rate change: orbit at `rate` rev/s starting at `time`.  The orbit
/// geometry (centre / plane / radius) is shared across the track — see
/// `OrbitRateSchedule` — so adjacent segments stay positionally continuous.
struct OrbitRateMarker: Identifiable, Equatable {
    let id = UUID()
    var time: Double
    var rate: Double   // revolutions / second, signed
}

/// A whole track's orbit schedule: a planar circle of `radius` around `axisStart`,
/// tilted so its plane normal is `axisStart → axisEnd` (world-up when the two
/// coincide), swept at the rates in `markers`.  Constant height — no helix climb.
struct OrbitRateSchedule: Equatable {
    var axisStart: SIMD3<Float>
    var axisEnd:   SIMD3<Float>
    var radius:    Float
    var markers:   [OrbitRateMarker]
}
