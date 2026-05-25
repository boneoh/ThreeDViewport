import simd

// Generators for Scene-mode widget geometry.  Returned as flat arrays of
// SIMD3<Float> line endpoints — every consecutive pair defines one line segment.
// Drawn by `Renderer.drawSceneWidgets` with MTLPrimitiveType.line through the
// pipeline defined in WidgetShaders.metal.
//
// Each generator is pure: it consumes the live state of a camera/light and
// returns a fresh vertex array.  No caching — widgets are cheap (≤ a few dozen
// segments) and live state changes every frame in many cases.
enum SceneWidgets {

    /// Wireframe frustum for a camera-like object.  The apex sits at the
    /// camera's eye position, four "rails" project out along the forward axis
    /// for `depth` world-units, and a rectangle closes the far end.  The vertex
    /// list is 8 line segments × 2 endpoints = 16 vertices.
    ///
    /// `aspect` is the framing aspect ratio at the far plane (camera width ÷
    /// camera height).  `fovY` is the vertical FOV in radians.  `depth` is
    /// how far in front of the eye to draw the far plane — a small fraction of
    /// the scene scale so the frustum reads as a marker, not a solid shape.
    static func cameraFrustum(eye:     SIMD3<Float>,
                              forward: SIMD3<Float>,
                              right:   SIMD3<Float>,
                              up:      SIMD3<Float>,
                              fovY:    Float,
                              aspect:  Float,
                              depth:   Float) -> [SIMD3<Float>] {
        let halfH = tan(fovY * 0.5) * depth
        let halfW = halfH * aspect

        // Centre of the far plane and its four corner offsets.
        let c  = eye + forward * depth
        let r  = right * halfW
        let u  = up    * halfH

        let tl = c + u - r   // top-left
        let tr = c + u + r   // top-right
        let br = c - u + r   // bottom-right
        let bl = c - u - r   // bottom-left

        return [
            // Apex to each corner (4 rails).
            eye, tl,
            eye, tr,
            eye, br,
            eye, bl,
            // Far-plane rectangle (4 edges).
            tl, tr,
            tr, br,
            br, bl,
            bl, tl,
        ]
    }

    /// Wireframe arrow representing a directional light.  Shaft from `anchor`
    /// to `anchor + direction * length`, with a 4-line "crosshair" arrowhead
    /// at the tip to make the direction unambiguous from any viewpoint.
    /// Returns 5 line segments (10 vertices).
    static func directionalArrow(anchor:    SIMD3<Float>,
                                 direction: SIMD3<Float>,
                                 length:    Float) -> [SIMD3<Float>] {
        let dir = simd_normalize(direction)
        let (perpA, perpB) = orthonormalBasis(for: dir)

        let tip      = anchor + dir * length
        let headLen  = length * 0.25
        let headRad  = length * 0.15
        let neck     = tip - dir * headLen

        let a1 = neck + perpA * headRad
        let a2 = neck - perpA * headRad
        let b1 = neck + perpB * headRad
        let b2 = neck - perpB * headRad

        return [
            anchor, tip,   // shaft
            tip, a1,       // arrowhead spoke +A
            tip, a2,       // arrowhead spoke −A
            tip, b1,       // arrowhead spoke +B
            tip, b2,       // arrowhead spoke −B
        ]
    }

    /// Wireframe sphere — three orthogonal great circles drawn as line segments.
    /// Returns `segments * 3 * 2` vertices (96 by default).
    static func sphereWireframe(center:   SIMD3<Float>,
                                radius:   Float,
                                segments: Int = 16) -> [SIMD3<Float>] {
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(segments * 6)
        let twoPi = 2 * Float.pi
        for axis in 0..<3 {
            for i in 0..<segments {
                let a = Float(i) / Float(segments) * twoPi
                let b = Float(i + 1) / Float(segments) * twoPi
                let pa = circlePoint(center: center, radius: radius, axis: axis, angle: a)
                let pb = circlePoint(center: center, radius: radius, axis: axis, angle: b)
                result.append(pa)
                result.append(pb)
            }
        }
        return result
    }

    /// Wireframe cone with apex at `apex`, axis along `direction`, the far rim
    /// at `length` units forward, and half-angle `halfAngle` (radians).  Drawn
    /// as `rays` apex-to-rim spokes plus a closed `rays`-segment rim circle.
    static func cone(apex:      SIMD3<Float>,
                     direction: SIMD3<Float>,
                     length:    Float,
                     halfAngle: Float,
                     rays:      Int = 8) -> [SIMD3<Float>] {
        let dir = simd_normalize(direction)
        let (perpA, perpB) = orthonormalBasis(for: dir)

        let rimCenter = apex + dir * length
        let rimRadius = tan(halfAngle) * length

        var rim: [SIMD3<Float>] = []
        rim.reserveCapacity(rays)
        let twoPi = 2 * Float.pi
        for i in 0..<rays {
            let a = Float(i) / Float(rays) * twoPi
            rim.append(rimCenter + perpA * (cos(a) * rimRadius) + perpB * (sin(a) * rimRadius))
        }

        var result: [SIMD3<Float>] = []
        result.reserveCapacity(rays * 4)
        for i in 0..<rays {
            result.append(apex)            // spoke from apex
            result.append(rim[i])
            result.append(rim[i])          // rim edge to next point
            result.append(rim[(i + 1) % rays])
        }
        return result
    }

    // MARK: - Internals

    /// A horizontal scale bar along world X at `center`, with vertical (+Y) tick
    /// marks every `unit` (taller every `majorEvery`).  Returns line-segment pairs
    /// for the widget pass.  Keep the span modest — the caller uploads this via
    /// setVertexBytes (≤ 4 KB ≈ 256 vertices).
    static func scaleRuler(center: SIMD3<Float>,
                           halfLength: Float,
                           unit: Float,
                           minorHeight: Float,
                           majorHeight: Float,
                           majorEvery: Int) -> [SIMD3<Float>] {
        var v: [SIMD3<Float>] = []
        let y = center.y, z = center.z
        v.append(SIMD3<Float>(center.x - halfLength, y, z))   // main bar
        v.append(SIMD3<Float>(center.x + halfLength, y, z))
        let n = unit > 0 ? Int(halfLength / unit) : 0
        if n > 0 {
            for i in -n...n {
                let x = center.x + Float(i) * unit
                let h = (i % majorEvery == 0) ? majorHeight : minorHeight
                v.append(SIMD3<Float>(x, y, z))
                v.append(SIMD3<Float>(x, y + h, z))
            }
        }
        return v
    }

    /// Returns two unit-length vectors mutually perpendicular to `dir` and to
    /// each other, chosen to be numerically stable even when `dir` is parallel
    /// to world-up.
    private static func orthonormalBasis(for dir: SIMD3<Float>)
        -> (SIMD3<Float>, SIMD3<Float>) {
        let worldUp = SIMD3<Float>(0, 1, 0)
        let ref: SIMD3<Float> = abs(simd_dot(dir, worldUp)) > 0.99
            ? SIMD3<Float>(1, 0, 0)
            : worldUp
        let perpA = simd_normalize(simd_cross(dir, ref))
        let perpB = simd_normalize(simd_cross(dir, perpA))
        return (perpA, perpB)
    }

    /// Point on one of three great circles of a sphere.
    /// `axis` selects which plane: 0 = XY, 1 = XZ, 2 = YZ.
    private static func circlePoint(center: SIMD3<Float>,
                                    radius: Float,
                                    axis:   Int,
                                    angle:  Float) -> SIMD3<Float> {
        let c = cos(angle) * radius
        let s = sin(angle) * radius
        switch axis {
        case 0:  return center + SIMD3<Float>(c, s, 0)
        case 1:  return center + SIMD3<Float>(c, 0, s)
        default: return center + SIMD3<Float>(0, c, s)
        }
    }
}
