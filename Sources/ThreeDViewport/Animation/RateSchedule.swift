import Foundation
import simd

/// Stable key for a rate schedule's target (identity refactor P3).  Objects, lights and
/// cameras key by their stable entity id (survives delete/reorder without re-indexing);
/// multi-part model groups key by their gid (stable within a session, persisted by
/// source filename + occurrence).
enum ScheduleKey: Hashable {
    case entity(UUID)   // object / light / camera
    case group(Int)     // multi-part model group id
}

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
    // Optional second simultaneous spin (advanced "tumble").  rate2 = 0 → single-axis.
    var rate2:      Double = 0
    var axisIndex2: Int    = 0
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
