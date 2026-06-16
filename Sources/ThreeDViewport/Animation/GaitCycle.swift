import simd
import Foundation

/// Procedural locomotion cycles for the canonical character rig (see
/// `generate_character.py` — `hips/upper_leg_L/knee_L/.../upper_arm_L/...`).
///
/// A gait is a function of a normalized stride phase φ ∈ [0,1): it returns a LOCAL
/// rotation (about each joint's own origin, which the rig places at the joint) to add
/// on top of the rest pose, plus a small whole-body vertical bob.  The generator
/// samples this along the path and bakes it into the per-part keyframe tracks.
///
/// Front of the character is +Z, up is +Y, so fore/aft limb swing is a rotation about
/// local X.  L/R are driven 180° out of phase.  Amplitudes are deliberately tunable —
/// the mechanism is exact; the *look* is dialed in visually.
enum GaitType: String, CaseIterable, Identifiable {
    case walk
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct GaitCycle {

    // MARK: - Tunable walk amplitudes (Phase 1)
    static let hipSwing:  Float = 24 * .pi / 180   // upper-leg fore/aft
    static let kneeFlex:  Float = 42 * .pi / 180   // knee bend (flex only)
    static let armSwing:  Float = 18 * .pi / 180   // upper-arm counter-swing
    static let bobHeight: Float = 0.025            // world-unit vertical bob

    /// Local joint rotations for one phase of a walk, keyed by canonical part name.
    /// Right side is the left side shifted half a cycle.
    static func walkPose(phase: Float) -> [String: simd_quatf] {
        let w = 2 * Float.pi * phase
        func rotX(_ a: Float) -> simd_quatf { simd_quatf(angle: a, axis: SIMD3<Float>(1, 0, 0)) }

        // Hip swing: -sin so the forward half of the cycle swings the foot to +Z (front).
        let legL = -hipSwing * sin(w)
        let legR = -hipSwing * sin(w + .pi)

        // Knee flexes (one direction only) while its leg swings rearward and lifts.
        // max(0, …) clamps to flex; +X bend tucks the shin back.
        let kneeL =  kneeFlex * max(0, sin(w))
        let kneeR =  kneeFlex * max(0, sin(w + .pi))

        // Arms counter-swing (opposite their same-side leg).
        let armL =  armSwing * sin(w)
        let armR =  armSwing * sin(w + .pi)

        return [
            "upper_leg_L": rotX(legL),  "upper_leg_R": rotX(legR),
            "knee_L":      rotX(kneeL), "knee_R":      rotX(kneeR),
            "upper_arm_L": rotX(armL),  "upper_arm_R": rotX(armR),
        ]
    }

    /// Whole-body vertical bob (world Y) — dips twice per stride (one per foot-plant).
    static func bob(phase: Float) -> Float {
        let w = 2 * Float.pi * phase
        return -bobHeight * (0.5 - 0.5 * cos(2 * w))   // 0 at mid-step, −bob at plants
    }

    /// Canonical joint names a gait drives — for "missing joint" reporting.
    static func requiredJoints(for gait: GaitType) -> [String] {
        ["upper_leg_L", "upper_leg_R", "knee_L", "knee_R", "upper_arm_L", "upper_arm_R"]
    }
}
