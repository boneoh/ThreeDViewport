import AppKit
import simd

// Cross-instance keyframe clipboard (CI-2).  Serializes copied keyframes to the
// system pasteboard so a second app instance can paste them, reusing the project
// format's Codable DTOs (KeyframeData / CameraKeyframeData / LightKeyframeData /
// AtmosphereKeyframeData) for the payload.  Track identity travels as a NAME
// (object/group) or INDEX (light/emitter); camera/fog are singletons.  Time is
// stored as an OFFSET relative to the earliest copied diamond (paste lands at the
// destination playhead + offset, clamped to its duration) — so it works across
// projects with different timelines.

enum KFClipKind: String, Codable { case camera, object, light, group, fog, particles }

// One copied keyframe.  Exactly one payload field is non-nil, per `kind`.
struct KFClipEntry: Codable {
    var kind:       KFClipKind
    var timeOffset: Double
    var trackName:  String? = nil   // object / group identity
    var trackIndex: Int?    = nil   // light / emitter identity
    var transform:  KeyframeData?           = nil   // object, group
    var camera:     CameraKeyframeData?     = nil
    var light:      LightKeyframeData?      = nil
    var atmosphere: AtmosphereKeyframeData? = nil
}

struct KFClipPayload: Codable { var entries: [KFClipEntry] }

enum KeyframePasteboard {
    static let type = NSPasteboard.PasteboardType("com.threedviewport.keyframes")

    // MARK: - Pasteboard I/O

    static func write(_ entries: [KFClipEntry]) {
        guard !entries.isEmpty,
              let data = try? JSONEncoder().encode(KFClipPayload(entries: entries)) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: type)
    }

    static func read() -> [KFClipEntry]? {
        guard let data = NSPasteboard.general.data(forType: type),
              let payload = try? JSONDecoder().decode(KFClipPayload.self, from: data) else { return nil }
        return payload.entries
    }

    // MARK: - ClipboardKeyframe ↔ DTO payload
    // The caller fills timeOffset + identity; here we only map the pose payload.
    // Times in the reconstructed live structs are 0 — paste overrides with the
    // destination playhead + offset, so absolute time is intentionally not carried.

    static func entry(from clip: ClipboardKeyframe) -> KFClipEntry {
        switch clip {
        case .object(let kf):    return KFClipEntry(kind: .object,    timeOffset: 0, transform: transformDTO(kf))
        case .group(let kf):     return KFClipEntry(kind: .group,     timeOffset: 0, transform: transformDTO(kf))
        case .camera(let kf):    return KFClipEntry(kind: .camera,    timeOffset: 0, camera: cameraDTO(kf))
        case .light(let kf):     return KFClipEntry(kind: .light,     timeOffset: 0, light: lightDTO(kf))
        case .fog(let kf):       return KFClipEntry(kind: .fog,       timeOffset: 0, atmosphere: atmoDTO(kf))
        case .particles(let kf): return KFClipEntry(kind: .particles, timeOffset: 0, atmosphere: atmoDTO(kf))
        }
    }

    static func clip(from entry: KFClipEntry) -> ClipboardKeyframe? {
        switch entry.kind {
        case .object:    return entry.transform.map  { .object(transformKF($0)) }
        case .group:     return entry.transform.map  { .group(transformKF($0)) }
        case .camera:    return entry.camera.map     { .camera(cameraKF($0)) }
        case .light:     return entry.light.map      { .light(lightKF($0)) }
        case .fog:       return entry.atmosphere.map { .fog(atmoKF($0)) }
        case .particles: return entry.atmosphere.map { .particles(atmoKF($0)) }
        }
    }

    // MARK: - Per-type field mapping (mirrors ProjectFile's save/load)

    private static func transformDTO(_ kf: TransformKeyframe) -> KeyframeData {
        KeyframeData(time: 0,
                     tx: kf.translation.x, ty: kf.translation.y, tz: kf.translation.z,
                     rx: kf.rotation.imag.x, ry: kf.rotation.imag.y,
                     rz: kf.rotation.imag.z, rw: kf.rotation.real,
                     sx: kf.scale.x, sy: kf.scale.y, sz: kf.scale.z,
                     opacity: kf.opacity)
    }
    private static func transformKF(_ d: KeyframeData) -> TransformKeyframe {
        TransformKeyframe(time: 0,
                          translation: SIMD3<Float>(d.tx, d.ty, d.tz),
                          rotation: simd_quatf(ix: d.rx, iy: d.ry, iz: d.rz, r: d.rw),
                          scale: SIMD3<Float>(d.sx, d.sy, d.sz),
                          opacity: d.opacity)
    }

    private static func cameraDTO(_ kf: CameraKeyframe) -> CameraKeyframeData {
        CameraKeyframeData(time: 0, yaw: kf.yaw, pitch: kf.pitch, distance: kf.distance,
                           targetX: kf.target.x, targetY: kf.target.y, targetZ: kf.target.z,
                           fov: kf.fov,
                           followTarget: kf.followTargetName,
                           followYawOffset: kf.followYawOffset,
                           followPitchOffset: kf.followPitchOffset,
                           targetOffset: [kf.targetOffset.x, kf.targetOffset.y, kf.targetOffset.z],
                           followForwardLocal: kf.followForwardLocal.map { [$0.x, $0.y, $0.z] },
                           followUpLocal: kf.followUpLocal.map { [$0.x, $0.y, $0.z] })
    }
    private static func cameraKF(_ d: CameraKeyframeData) -> CameraKeyframe {
        let off = d.targetOffset.flatMap { $0.count >= 3 ? SIMD3<Float>($0[0], $0[1], $0[2]) : nil }
                  ?? SIMD3<Float>(0, 0, 0)
        let fwd = d.followForwardLocal.flatMap { $0.count >= 3 ? SIMD3<Float>($0[0], $0[1], $0[2]) : nil }
        let up  = d.followUpLocal.flatMap     { $0.count >= 3 ? SIMD3<Float>($0[0], $0[1], $0[2]) : nil }
        return CameraKeyframe(time: 0, yaw: d.yaw, pitch: d.pitch, distance: d.distance,
                              target: SIMD3<Float>(d.targetX, d.targetY, d.targetZ),
                              fov: d.fov ?? (Float.pi * 27.0 / 180.0),
                              followTargetName: d.followTarget,
                              followYawOffset: d.followYawOffset,
                              followPitchOffset: d.followPitchOffset,
                              targetOffset: off,
                              followForwardLocal: fwd,
                              followUpLocal: up)
    }

    private static func lightDTO(_ kf: LightKeyframe) -> LightKeyframeData {
        LightKeyframeData(time: 0, intensity: kf.intensity,
                          r: kf.color.x, g: kf.color.y, b: kf.color.z,
                          tx: kf.target.x, ty: kf.target.y, tz: kf.target.z,
                          px: kf.position.x, py: kf.position.y, pz: kf.position.z,
                          range: kf.range, beamThickness: kf.beamThickness)
    }
    private static func lightKF(_ d: LightKeyframeData) -> LightKeyframe {
        LightKeyframe(time: 0, intensity: d.intensity,
                      color: SIMD3<Float>(d.r, d.g, d.b),
                      target: SIMD3<Float>(d.tx, d.ty, d.tz),
                      position: SIMD3<Float>(d.px, d.py, d.pz),
                      range: d.range, beamThickness: d.beamThickness)
    }

    private static func atmoDTO(_ kf: AtmosphereKeyframe) -> AtmosphereKeyframeData {
        AtmosphereKeyframeData(time: 0,
                               px: kf.position.x, py: kf.position.y, pz: kf.position.z,
                               sx: kf.size.x, sy: kf.size.y, sz: kf.size.z,
                               density: kf.density, variance: kf.variance,
                               r: kf.color.x, g: kf.color.y, b: kf.color.z)
    }
    private static func atmoKF(_ d: AtmosphereKeyframeData) -> AtmosphereKeyframe {
        AtmosphereKeyframe(time: 0,
                           position: SIMD3<Float>(d.px, d.py, d.pz),
                           size: SIMD3<Float>(d.sx, d.sy, d.sz),
                           density: d.density, variance: d.variance,
                           color: SIMD3<Float>(d.r, d.g, d.b))
    }
}
