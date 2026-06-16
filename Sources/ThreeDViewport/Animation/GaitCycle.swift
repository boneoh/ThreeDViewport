import simd
import Foundation

/// Procedural locomotion cycles for the canonical character rig (see
/// `generate_character.py` — `hips/upper_leg_L/knee_L/.../upper_arm_L/...`).
///
/// A gait is a function of a normalized stride phase φ ∈ [0,1): it returns a LOCAL
/// rotation (about each joint's own origin, which the rig places at the joint) to add
/// on top of the rest pose, a whole-body vertical bob, and an optional body
/// orientation (e.g. prone for swim).  The generator samples this along the path and
/// bakes it into the per-part keyframe tracks.
///
/// Front of the character is +Z, up is +Y, so fore/aft limb swing is a rotation about
/// local X.  Amplitudes live in `GaitParams` so they can be tuned from the panel.
enum GaitType: String, CaseIterable, Identifiable {
    case walk, run, hop, swim
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// Tunable amplitudes for a gait (radians for the swings, world units for bob).
struct GaitParams {
    var hipSwing: Float
    var kneeFlex: Float
    var armSwing: Float
    var elbowFlex: Float   // forearm raise (run / hop)
    var bob:      Float

    /// Per-gait defaults (degrees → radians).
    static func defaults(for gait: GaitType) -> GaitParams {
        func d(_ deg: Float) -> Float { deg * .pi / 180 }
        switch gait {
        case .walk: return GaitParams(hipSwing: d(24), kneeFlex: d(42), armSwing: d(18), elbowFlex: d(15), bob: 0.025)
        case .run:  return GaitParams(hipSwing: d(42), kneeFlex: d(75), armSwing: d(38), elbowFlex: d(50), bob: 0.10)
        case .hop:  return GaitParams(hipSwing: d(10), kneeFlex: d(60), armSwing: d(30), elbowFlex: d(50), bob: 0.18)
        case .swim: return GaitParams(hipSwing: d(14), kneeFlex: d(18), armSwing: d(80), elbowFlex: 0,     bob: 0.0)
        }
    }

    /// Scale each amplitude by a user multiplier (1.0 = the default).  Elbow rides the
    /// arm multiplier.
    func scaled(hip: Float, knee: Float, arm: Float, bob bobMul: Float) -> GaitParams {
        GaitParams(hipSwing: hipSwing * hip, kneeFlex: kneeFlex * knee,
                   armSwing: armSwing * arm, elbowFlex: elbowFlex * arm, bob: bob * bobMul)
    }
}

struct GaitCycle {

    private static func rotX(_ a: Float) -> simd_quatf { simd_quatf(angle: a, axis: SIMD3<Float>(1, 0, 0)) }

    /// Local joint rotations for one phase of `gait`, keyed by canonical part name.
    static func pose(_ gait: GaitType, phase: Float, _ p: GaitParams) -> [String: simd_quatf] {
        let w = 2 * Float.pi * phase
        switch gait {

        case .walk, .run:
            // Legs swing fore/aft 180° apart; knees flex (one direction) on the rear
            // swing; arms counter-swing.  Run also raises the forearms (elbowFlex),
            // each forearm rising as its arm comes forward.
            let legL  = -p.hipSwing * sin(w)
            let legR  = -p.hipSwing * sin(w + .pi)
            let kneeL =  p.kneeFlex * max(0, sin(w))
            let kneeR =  p.kneeFlex * max(0, sin(w + .pi))
            let armL  =  p.armSwing * sin(w)
            let armR  =  p.armSwing * sin(w + .pi)
            // Forearm raise (negative X = up/forward); 0…elbowFlex, phased per arm.
            let elbL  = -p.elbowFlex * (0.5 - 0.5 * cos(w))
            let elbR  = -p.elbowFlex * (0.5 - 0.5 * cos(w + .pi))
            return ["upper_leg_L": rotX(legL),  "upper_leg_R": rotX(legR),
                    "knee_L":      rotX(kneeL), "knee_R":      rotX(kneeR),
                    "upper_arm_L": rotX(armL),  "upper_arm_R": rotX(armR),
                    "elbow_L":     rotX(elbL),  "elbow_R":     rotX(elbR)]

        case .hop:
            // Both legs move TOGETHER: deep crouch at take-off/landing (phase 0/1),
            // extended at the apex (phase 0.5); arms + forearms pump up on take-off.
            let crouch = 0.5 + 0.5 * cos(w)            // 1 at 0/1, 0 at 0.5
            let knee   = p.kneeFlex * crouch
            let leg    = -p.hipSwing * crouch          // slight tuck while crouched
            let arm    =  p.armSwing * sin(w)          // pump up then down
            let elb    = -p.elbowFlex * (0.5 - 0.5 * cos(w))   // forearms raise on the up-pump
            return ["upper_leg_L": rotX(leg),  "upper_leg_R": rotX(leg),
                    "knee_L":      rotX(knee), "knee_R":      rotX(knee),
                    "upper_arm_L": rotX(arm),  "upper_arm_R": rotX(arm),
                    "elbow_L":     rotX(elb),  "elbow_R":     rotX(elb)]

        case .swim:
            // Prone body (see bodyOrientation): legs flutter fast + shallow, arms take
            // big alternating strokes, and the head tilts up ~45° to look forward out
            // of the water (constant; eases back to rest as the swimmer stands up).
            let legL  =  p.hipSwing * sin(2 * w)
            let legR  =  p.hipSwing * sin(2 * w + .pi)
            let kneeL =  p.kneeFlex * max(0, sin(2 * w))
            let kneeR =  p.kneeFlex * max(0, sin(2 * w + .pi))
            let armL  =  p.armSwing * sin(w)
            let armR  =  p.armSwing * sin(w + .pi)
            let headUp: Float = -45 * .pi / 180     // tilt head up out of the water
            return ["upper_leg_L": rotX(legL),  "upper_leg_R": rotX(legR),
                    "knee_L":      rotX(kneeL), "knee_R":      rotX(kneeR),
                    "upper_arm_L": rotX(armL),  "upper_arm_R": rotX(armR),
                    "neck":        rotX(headUp)]
        }
    }

    /// Whole-body vertical bob (world Y) for the phase.
    static func bob(_ gait: GaitType, phase: Float, _ p: GaitParams) -> Float {
        let w = 2 * Float.pi * phase
        switch gait {
        case .walk, .run: return -p.bob * (0.5 - 0.5 * cos(2 * w))   // dip at each foot-plant
        case .hop:        return  p.bob * sin(.pi * phase)           // one airborne arch per cycle
        case .swim:       return 0
        }
    }

    /// Extra body orientation added to the travel heading (e.g. swim lies prone).
    /// +90° about X tips the upright character face-DOWN with the head leading the
    /// direction of travel (+Z).
    static func bodyOrientation(_ gait: GaitType) -> simd_quatf {
        switch gait {
        case .swim: return simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))  // prone, head-first
        default:    return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
    }

    /// Canonical joint names a gait drives — for "missing joint" reporting.
    static func requiredJoints(for gait: GaitType) -> [String] {
        var j = ["upper_leg_L", "upper_leg_R", "knee_L", "knee_R", "upper_arm_L", "upper_arm_R"]
        if gait != .swim { j += ["elbow_L", "elbow_R"] }   // walk/run/hop swing the forearms
        else             { j += ["neck"] }                 // swim tilts the head up
        return j
    }
}
