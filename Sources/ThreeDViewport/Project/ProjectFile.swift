import Foundation
import simd

// Phase 4/5/6: Static save/load bridge between ProjectData (Codable JSON) and the
// live ViewportView state.  All methods throw on failure so callers can surface
// errors to the user via NSAlert.

enum ProjectFileError: LocalizedError {
    case modelNotFound(String)
    case encodingFailed(String)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let path):  return "Model file not found: " + path
        case .encodingFailed(let msg):  return "Could not save project: " + msg
        case .decodingFailed(let msg):  return "Could not open project: " + msg
        }
    }
}

final class ProjectFile {

    // MARK: - Save

    /// Serialises the current viewport state to a pretty-printed JSON file at `url`.
    static func save(to url: URL, viewport: ViewportView,
                     windowLayout: WindowLayoutData = WindowLayoutData()) throws {
        let data    = captureData(from: viewport, windowLayout: windowLayout)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let json: Data
        do {
            json = try encoder.encode(data)
        } catch {
            throw ProjectFileError.encodingFailed(error.localizedDescription)
        }

        try json.write(to: url, options: .atomic)

        print("[DEBUG] ProjectFile: saved v\(data.version) "
            + String(json.count) + " bytes → " + url.lastPathComponent
            + "  models=" + String(data.modelPaths.count)
            + "  objects=" + String(data.objects.count)
            + "  keyframes=" + String(data.objects.reduce(0) { $0 + $1.keyframes.count })
            + "  camKeyframes=" + String(data.cameraKeyframes.count)
            + "  groupTracks=" + String(data.groupKeyframeTracks.count)
            + "  looping=" + String(data.isLooping)
            + "  wireframe=" + String(data.isWireframe)
            + "  bgMode=" + String(data.background.mode))
    }

    // MARK: - Load

    /// Reads a .3dvp file at `url`, restores timeline, loads all models, restores
    /// keyframe tracks and camera state.  Camera is applied AFTER model loading so
    /// it overrides any fitToScene calls made during load.
    @discardableResult
    static func load(from url: URL, into viewport: ViewportView,
                     missingModelResolver: ((String) -> URL?)? = nil) throws -> ProjectData {
        let json: Data
        do {
            json = try Data(contentsOf: url)
        } catch {
            throw ProjectFileError.decodingFailed("Cannot read file: " + error.localizedDescription)
        }

        let data: ProjectData
        do {
            data = try JSONDecoder().decode(ProjectData.self, from: json)
        } catch {
            throw ProjectFileError.decodingFailed(error.localizedDescription)
        }

        print("[DEBUG] ProjectFile: loaded version=" + String(data.version)
            + " from " + url.lastPathComponent
            + "  models=" + String(data.modelPaths.count)
            + "  objects=" + String(data.objects.count))

        applyData(data, to: viewport, missingModelResolver: missingModelResolver)
        return data
    }

    // MARK: - Import another project into the current scene

    /// Placement + timing for a project import (Phase 1: bake-on-import).
    struct ImportOptions {
        var insertTime:    Double          = 0                          // host time the clip begins at
        var transform:     matrix_float4x4 = matrix_identity_float4x4    // TRS world placement (baked in)
        var includeLights: Bool            = false
        /// Append the source's particle emitters and adopt its fog (fog only when the
        /// host has none — it's a single global volume).
        var includeEffects: Bool           = false
        /// When set, import only the source's `[in, out]` slice — keyframes outside
        /// the range are dropped, the boundaries are resampled, and the slice is
        /// remapped so source `in` lands at `insertTime`.  nil = import the full clip.
        var sliceRange:    (in: Double, out: Double)? = nil
    }

    /// Imports another `.3dvp`'s models, animation, materials, and envelopes (and,
    /// optionally, its lights) INTO the current scene — appending, not replacing.
    /// Every imported keyframe time is shifted by `options.insertTime`, and the whole
    /// import is placed by `options.transform` (baked into base / group / envelope /
    /// light transforms).  Camera and global FX (fog / particles / grade / background
    /// / feedback) are ignored — the host keeps its own.  Returns false if unreadable.
    @discardableResult
    static func importProject(from url: URL, into vp: ViewportView,
                              options: ImportOptions) -> Bool {
        guard let json = try? Data(contentsOf: url),
              var data = try? JSONDecoder().decode(ProjectData.self, from: json) else {
            return false
        }
        let sm = vp.sceneManager
        let M  = options.transform

        // Per-object restore below is POSITIONAL (data.objects[i] ↔ imported[i]).  A
        // model file that fails to load would append fewer objects and shift every
        // later object's saved data (and envelope member indices) onto the wrong part,
        // and we can't know a missing model's part count to compensate.  So refuse the
        // whole import if any referenced file is absent — the caller surfaces which.
        let allPaths = data.modelPaths.isEmpty ? (data.modelPath.map { [$0] } ?? []) : data.modelPaths
        if allPaths.contains(where: { !FileManager.default.fileExists(atPath: $0) }) { return false }

        // Ranged import: keep only the source's [in, out] slice (boundary-sampled),
        // and remap so source `in` lands at insertTime.  After slicing every kept
        // keyframe still sits at its SOURCE time, so the rest of the import shifts
        // by T = insertTime − in (vs. T = insertTime for a full import).
        //
        // A full import is treated as the slice [0, source duration]: keyframes left
        // PAST the source's last frame (e.g. stale baked keyframes after the timeline
        // was shortened) are off the source timeline and must not be imported.
        let T: Double
        if let s = options.sliceRange {
            sliceProjectData(&data, in: s.in, out: s.out)
            T = options.insertTime - s.in
        } else {
            sliceProjectData(&data, in: 0, out: data.timeline.duration)
            T = options.insertTime
        }

        // 1. Append the import's models (reproduces its object order/structure).
        let modelStart = sm.objects.count
        let paths = data.modelPaths.isEmpty ? (data.modelPath.map { [$0] } ?? []) : data.modelPaths
        for p in paths where FileManager.default.fileExists(atPath: p) {
            vp.addModelToScene(url: URL(fileURLWithPath: p))
        }
        let imported = Array(sm.objects[modelStart...])
        guard !imported.isEmpty else { return true }

        // One display-only bundle for this import so the Timeline Editor can fold its
        // lanes under a single collapsible header (Part B).  Stamped onto every
        // imported object (after restoreObject, which would otherwise re-set the tag
        // from the source's own bundles), envelope node, and opt-in light.
        let bundleID = sm.makeImportBundle(name: url.deletingPathExtension().lastPathComponent)

        // 2. Restore per-object data positionally, shifting keyframe times by T.
        let n = min(imported.count, data.objects.count)
        for i in 0..<n { restoreObject(data.objects[i], into: imported[i], vp: vp, timeOffset: T) }
        for o in imported { o.importBundleID = bundleID }

        // 3. Group placement + group-level animation, composed with M.  Keyed by
        //    (filename, occurrence among imported groups), which matches the saved
        //    occurrence because the append reproduces the import's structure.
        let gmap = importedGroupMap(imported)
        var bGT: [String: matrix_float4x4] = [:]
        for e in data.groupBaseTransforms { if let m = decodeMatrix(e.matrix) { bGT["\(e.sourceFileName)#\(e.occurrence)"] = m } }
        for (key, gid) in gmap { sm.groupTransforms[gid] = M * (bGT[key] ?? matrix_identity_float4x4) }
        for td in data.groupKeyframeTracks where !td.keyframes.isEmpty {
            guard let gid = gmap["\(td.sourceFileName)#\(td.occurrence)"] else { continue }
            let track = KeyframeTrack()
            track.easingMode = EasingMode(rawValue: td.easingMode) ?? .linear
            for kf in transformedKeyframes(td.keyframes, by: M, timeOffset: T) { track.addKeyframe(kf) }
            sm.groupKeyframeTracks[gid] = track
        }

        // 4. Envelopes — re-created among the imported model objects (member indices
        //    are relative to the import's model array, so offset by modelStart), and
        //    placed by M·envelopeTransform.
        for env in data.envelopes {
            guard let envT = decodeMatrix(env.transform) else { continue }
            let node = SceneObject(name: env.name)
            node.isEnvelope = true
            node.transform = M * envT; node.baseTransform = node.transform; node.localTransform = node.transform
            node.importBundleID = bundleID
            if !env.keyframes.isEmpty {
                let track = KeyframeTrack()
                track.easingMode = EasingMode(rawValue: env.easingMode) ?? .linear
                for kf in transformedKeyframes(env.keyframes, by: M, timeOffset: T) { track.addKeyframe(kf) }
                node.keyframeTrack = track
            }
            sm.objects.append(node)
            let envIndex = sm.objects.count - 1
            for mi in env.memberIndices {
                let live = modelStart + mi
                guard live >= 0, live < sm.objects.count, !sm.objects[live].isEnvelope else { continue }
                sm.objects[live].parentIndex    = envIndex
                sm.objects[live].localTransform = sm.objects[live].baseTransform
            }
        }

        // 5. Place every imported SIMPLE top-level root by M (envelope members now
        //    carry a parentIndex → excluded; grouped roots use their group transform).
        for o in imported where o.parentIndex == nil && o.groupID == nil && !o.isEnvelope {
            o.baseTransform = M * o.baseTransform
            o.transform     = o.baseTransform
        }

        // 6. Lights (opt-in).
        if options.includeLights { appendImportedLights(data, by: M, timeOffset: T, bundleID: bundleID, vp: vp) }
        if options.includeEffects { appendImportedEffects(data, by: M, timeOffset: T, bundleID: bundleID, vp: vp) }

        // 7. Extend the timeline to fit the imported clip.  In HOST time the clip
        //    spans [insertTime, insertTime + length], where length is the slice span
        //    (out − in) or the full source duration.
        let clipLength = options.sliceRange.map { $0.out - $0.in } ?? data.timeline.duration
        vp.timeline.duration = max(vp.timeline.duration, options.insertTime + clipLength)

        // Capture the loop window for this bundle: the imported frame-zero lands at
        // insertTime, and the cycle spans the source's full timeline duration (or the
        // ranged slice).  Looping is off until the user enables it on the bundle header.
        sm.importBundleLoops[bundleID] = SceneManager.BundleLoop(
            enabled: false, cycleStart: options.insertTime, cycleLength: clipLength)
        // Provenance for "Extend Spin/Orbit to End": source path + the time offset (T)
        // and placement (M) applied here, so its rate markers can be re-read later.
        sm.importBundleSources[bundleID] = SceneManager.BundleSource(
            path: url.path, insertOffset: T, transform: M)

        print("[DEBUG] ProjectFile: imported \(imported.count) object(s) from "
            + url.lastPathComponent + " at t=\(T)")
        return true
    }

    /// "filename#occurrence" → gid for the imported groups (occurrence counted among
    /// imported groups only, in object order — matching the saved occurrence).
    private static func importedGroupMap(_ imported: [SceneObject]) -> [String: Int] {
        var occByFile: [String: Int] = [:]
        var map:       [String: Int] = [:]
        var seen = Set<Int>()
        for o in imported {
            guard let gid = o.groupID, seen.insert(gid).inserted else { continue }
            let file = o.sourceURL?.lastPathComponent ?? ""
            let occ  = occByFile[file, default: 0]
            occByFile[file] = occ + 1
            map["\(file)#\(occ)"] = gid
        }
        return map
    }

    /// Premultiplies M onto each saved keyframe's transform and shifts its time by T —
    /// used to bake an import's placement into group / envelope animation tracks.
    private static func transformedKeyframes(_ kfs: [KeyframeData],
                                             by M: matrix_float4x4,
                                             timeOffset: Double) -> [TransformKeyframe] {
        kfs.map { kf in
            let mat = PathGenerator.makeTransform(
                translation: SIMD3<Float>(kf.tx, kf.ty, kf.tz),
                rotation:    simd_quatf(ix: kf.rx, iy: kf.ry, iz: kf.rz, r: kf.rw),
                scale:       SIMD3<Float>(kf.sx, kf.sy, kf.sz))
            let (t, r, s) = PathGenerator.decompose(M * mat)
            return TransformKeyframe(time: kf.time + timeOffset, translation: t,
                                     rotation: r, scale: s, opacity: kf.opacity)
        }
    }

    // MARK: - Ranged import (slice the source's [in, out])

    /// Rewrites every keyframe array in `data` to the `[lo, hi]` slice, boundary-
    /// sampled at the endpoints.  Times stay in SOURCE coordinates (the caller shifts
    /// them by T = insertTime − lo afterward).  Static placement (base / group /
    /// envelope transforms) is untouched — slicing only affects animation timing.
    private static func sliceProjectData(_ data: inout ProjectData, in lo: Double, out hi: Double) {
        for i in data.objects.indices {
            data.objects[i].keyframes = sliceTransformKeyframes(data.objects[i].keyframes, in: lo, out: hi)
        }
        for i in data.groupKeyframeTracks.indices {
            data.groupKeyframeTracks[i].keyframes =
                sliceTransformKeyframes(data.groupKeyframeTracks[i].keyframes, in: lo, out: hi)
        }
        for i in data.envelopes.indices {
            data.envelopes[i].keyframes = sliceTransformKeyframes(data.envelopes[i].keyframes, in: lo, out: hi)
        }
        for i in data.lightKeyframeTracks.indices {
            data.lightKeyframeTracks[i] = sliceLightKeyframes(data.lightKeyframeTracks[i], in: lo, out: hi)
        }
        // Effects (fog + particle emitters; legacy single emitter) — opt-in import,
        // but slicing them here keeps a ranged/clamped import's effect timing correct.
        data.fogKeyframes      = sliceAtmosphereKeyframes(data.fogKeyframes,      in: lo, out: hi)
        data.particleKeyframes = sliceAtmosphereKeyframes(data.particleKeyframes, in: lo, out: hi)
        for i in data.particleEmitterKeyframes.indices {
            data.particleEmitterKeyframes[i] =
                sliceAtmosphereKeyframes(data.particleEmitterKeyframes[i], in: lo, out: hi)
        }
    }

    /// Atmosphere-track counterpart of `sliceTransformKeyframes` (fog / particles).
    private static func sliceAtmosphereKeyframes(_ kfs: [AtmosphereKeyframeData],
                                                 in lo: Double, out hi: Double) -> [AtmosphereKeyframeData] {
        guard !kfs.isEmpty else { return [] }
        let track = AtmosphereKeyframeTrack()
        for kf in kfs {
            track.addKeyframe(AtmosphereKeyframe(
                time:     kf.time,
                position: SIMD3<Float>(kf.px, kf.py, kf.pz),
                size:     SIMD3<Float>(kf.sx, kf.sy, kf.sz),
                density:  kf.density,
                variance: kf.variance,
                color:    SIMD3<Float>(kf.r, kf.g, kf.b)))
        }
        let tol = 1e-4
        var result: [AtmosphereKeyframeData] = []
        if !kfs.contains(where: { abs($0.time - lo) <= tol }), let s = sampleAtmosphere(track, at: lo) {
            result.append(s)
        }
        for kf in kfs where kf.time >= lo - tol && kf.time <= hi + tol { result.append(kf) }
        if !kfs.contains(where: { abs($0.time - hi) <= tol }), let s = sampleAtmosphere(track, at: hi) {
            result.append(s)
        }
        result.sort { $0.time < $1.time }
        return result
    }

    private static func sampleAtmosphere(_ track: AtmosphereKeyframeTrack, at t: Double) -> AtmosphereKeyframeData? {
        guard let k = track.evaluate(at: t) else { return nil }
        return AtmosphereKeyframeData(time: t,
                                      px: k.position.x, py: k.position.y, pz: k.position.z,
                                      sx: k.size.x, sy: k.size.y, sz: k.size.z,
                                      density: k.density, variance: k.variance,
                                      r: k.color.x, g: k.color.y, b: k.color.z)
    }

    /// Keeps the `[lo, hi]` slice of a transform track, resampling the endpoints so
    /// the slice starts / ends on the exact source pose (no jump at the cut).  An
    /// endpoint that coincides with a real keyframe (within tolerance) isn't
    /// duplicated.  Empty in → empty out.
    private static func sliceTransformKeyframes(_ kfs: [KeyframeData],
                                                in lo: Double, out hi: Double) -> [KeyframeData] {
        guard !kfs.isEmpty else { return [] }
        let track = KeyframeTrack()
        for kf in kfs {
            track.addKeyframe(TransformKeyframe(
                time:        kf.time,
                translation: SIMD3<Float>(kf.tx, kf.ty, kf.tz),
                rotation:    simd_quatf(ix: kf.rx, iy: kf.ry, iz: kf.rz, r: kf.rw),
                scale:       SIMD3<Float>(kf.sx, kf.sy, kf.sz),
                opacity:     kf.opacity))
        }
        let tol = 1e-4
        var result: [KeyframeData] = []
        if !kfs.contains(where: { abs($0.time - lo) <= tol }), let s = sampleTransform(track, at: lo) {
            result.append(s)
        }
        for kf in kfs where kf.time >= lo - tol && kf.time <= hi + tol { result.append(kf) }
        if !kfs.contains(where: { abs($0.time - hi) <= tol }), let s = sampleTransform(track, at: hi) {
            result.append(s)
        }
        result.sort { $0.time < $1.time }
        return result
    }

    private static func sampleTransform(_ track: KeyframeTrack, at t: Double) -> KeyframeData? {
        guard let m = track.evaluate(at: t) else { return nil }
        let (tr, r, s) = PathGenerator.decompose(m)
        let op = track.evaluateOpacity(at: t) ?? 1
        return KeyframeData(time: t,
                            tx: tr.x, ty: tr.y, tz: tr.z,
                            rx: r.imag.x, ry: r.imag.y, rz: r.imag.z, rw: r.real,
                            sx: s.x, sy: s.y, sz: s.z, opacity: op)
    }

    /// Light-track counterpart of `sliceTransformKeyframes`.
    private static func sliceLightKeyframes(_ kfs: [LightKeyframeData],
                                            in lo: Double, out hi: Double) -> [LightKeyframeData] {
        guard !kfs.isEmpty else { return [] }
        let track = LightKeyframeTrack()
        for kf in kfs {
            track.addKeyframe(LightKeyframe(
                time:          kf.time,
                intensity:     kf.intensity,
                color:         SIMD3<Float>(kf.r, kf.g, kf.b),
                target:        SIMD3<Float>(kf.tx, kf.ty, kf.tz),
                position:      SIMD3<Float>(kf.px, kf.py, kf.pz),
                range:         kf.range,
                beamThickness: kf.beamThickness))
        }
        let tol = 1e-4
        var result: [LightKeyframeData] = []
        if !kfs.contains(where: { abs($0.time - lo) <= tol }), let s = sampleLight(track, at: lo) {
            result.append(s)
        }
        for kf in kfs where kf.time >= lo - tol && kf.time <= hi + tol { result.append(kf) }
        if !kfs.contains(where: { abs($0.time - hi) <= tol }), let s = sampleLight(track, at: hi) {
            result.append(s)
        }
        result.sort { $0.time < $1.time }
        return result
    }

    private static func sampleLight(_ track: LightKeyframeTrack, at t: Double) -> LightKeyframeData? {
        guard let k = track.evaluate(at: t) else { return nil }
        return LightKeyframeData(time: t, intensity: k.intensity,
                                 r: k.color.x, g: k.color.y, b: k.color.z,
                                 tx: k.target.x, ty: k.target.y, tz: k.target.z,
                                 px: k.position.x, py: k.position.y, pz: k.position.z,
                                 range: k.range, beamThickness: k.beamThickness)
    }

    /// Appends the import's light fixtures + keyframe tracks, with positions/targets
    /// transformed by M and times shifted by T.
    private static func appendImportedLights(_ data: ProjectData,
                                             by M: matrix_float4x4,
                                             timeOffset: Double,
                                             bundleID: Int,
                                             vp: ViewportView) {
        let lm = vp.lightManager
        func point(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> {
            let v = M * SIMD4<Float>(x, y, z, 1)
            return SIMD3<Float>(v.x, v.y, v.z)
        }
        let lightStart = lm.lights.count
        for lcd in data.lightConfigs {
            guard let type = LightType(rawValue: lcd.type) else { continue }
            var l = LightConfig()
            l.type                    = type
            l.isEnabled               = lcd.isEnabled
            l.color                   = SIMD3<Float>(lcd.colorR, lcd.colorG, lcd.colorB)
            l.intensity               = lcd.intensity
            l.position                = point(lcd.posX, lcd.posY, lcd.posZ)
            l.target                  = point(lcd.targetX, lcd.targetY, lcd.targetZ)
            l.innerConeAngle          = lcd.innerConeAngle
            l.outerConeAngle          = lcd.outerConeAngle
            l.range                   = lcd.range
            l.beamThickness           = lcd.beamThickness
            l.excludeBeamFromFeedback = lcd.excludeBeamFromFeedback
            l.importBundleID          = bundleID
            lm.lights.append(l)
            lm.keyframeTracks.append(nil)
        }
        for (i, kfArray) in data.lightKeyframeTracks.enumerated() where !kfArray.isEmpty {
            let track = LightKeyframeTrack()
            let em = i < data.lightEasingModes.count ? data.lightEasingModes[i] : 0
            track.easingMode = EasingMode(rawValue: em) ?? .linear
            for kf in kfArray {
                track.addKeyframe(LightKeyframe(
                    time:          kf.time + timeOffset,
                    intensity:     kf.intensity,
                    color:         SIMD3<Float>(kf.r, kf.g, kf.b),
                    target:        point(kf.tx, kf.ty, kf.tz),
                    position:      point(kf.px, kf.py, kf.pz),
                    range:         kf.range,
                    beamThickness: kf.beamThickness))
            }
            let slot = lightStart + i
            while lm.keyframeTracks.count <= slot { lm.keyframeTracks.append(nil) }
            lm.keyframeTracks[slot] = track
        }
    }

    /// Appends the import's particle emitters (placed by M, times shifted by T) and,
    /// when the host has no fog, adopts the source's fog the same way.  Fog is a single
    /// global volume, so it's only adopted into an empty slot — never merged.
    private static func appendImportedEffects(_ data: ProjectData,
                                              by M: matrix_float4x4,
                                              timeOffset T: Double,
                                              bundleID: Int,
                                              vp: ViewportView) {
        func point(_ v: SIMD3<Float>) -> SIMD3<Float> {
            let p = M * SIMD4<Float>(v.x, v.y, v.z, 1); return SIMD3<Float>(p.x, p.y, p.z)
        }
        // Box spawn regions are axis-aligned: scale the size by M's (uniform) scale
        // magnitude and ignore rotation.
        let sclMag = simd_length(SIMD3<Float>(M.columns.0.x, M.columns.0.y, M.columns.0.z))
        func sized(_ v: SIMD3<Float>) -> SIMD3<Float> { v * sclMag }
        func placeTrack(_ track: AtmosphereKeyframeTrack?) {
            guard let track = track else { return }
            for j in track.keyframes.indices {
                track.keyframes[j].time    += T
                track.keyframes[j].position = point(track.keyframes[j].position)
                track.keyframes[j].size     = sized(track.keyframes[j].size)
            }
        }

        // ── Particle emitters — append (migrate a legacy single emitter like load) ──
        let mgr = vp.particleManager
        let emitterData: [ParticleEffectData]
        let emitterKfs:  [[AtmosphereKeyframeData]]
        if !data.particleEmitters.isEmpty {
            emitterData = data.particleEmitters
            emitterKfs  = data.particleEmitterKeyframes
        } else {
            emitterData = [data.particles]
            emitterKfs  = [data.particleKeyframes]
        }
        var dropped = 0
        for (i, pd) in emitterData.enumerated() where pd.isEnabled {
            guard mgr.emitters.count < ParticleManager.maxEmitters else { dropped += 1; continue }
            let fx  = ParticleEffect()
            let kfs = i < emitterKfs.count ? emitterKfs[i] : []
            let em  = i < data.particleEmitterEasingModes.count ? data.particleEmitterEasingModes[i] : 0
            applyParticleEmitter(pd, keyframes: kfs, easingMode: em, into: fx)
            fx.importBundleID = bundleID   // group under this import's bundle (override source tag)
            fx.position = point(fx.position)
            fx.size     = sized(fx.size)
            placeTrack(fx.keyframeTrack)
            mgr.emitters.append(fx)
        }
        if dropped > 0 {
            print("[DEBUG] ProjectFile: import dropped \(dropped) particle emitter(s) — "
                + "max \(ParticleManager.maxEmitters) reached")
        }

        // ── Fog — single global volume: adopt only when the host has none ───────────
        if data.fog.isEnabled {
            if vp.fogSettings.isEnabled {
                print("[DEBUG] ProjectFile: host already has fog — imported fog skipped")
            } else {
                let f = data.fog
                vp.fogSettings.isEnabled     = true
                vp.fogSettings.color         = SIMD3<Float>(f.r, f.g, f.b)
                vp.fogSettings.density       = f.density
                vp.fogSettings.position      = point(SIMD3<Float>(f.px, f.py, f.pz))
                vp.fogSettings.size          = sized(SIMD3<Float>(f.sx, f.sy, f.sz))
                vp.fogSettings.variance      = f.variance
                vp.fogSettings.raymarchSteps = f.steps
                let track = applyAtmosphereKeyframes(data.fogKeyframes, easingMode: data.fogEasingMode)
                placeTrack(track)
                vp.fogSettings.keyframeTrack = track
            }
        }
    }

    // MARK: - Capture live state → ProjectData

    private static func captureData(from vp: ViewportView,
                                    windowLayout: WindowLayoutData = WindowLayoutData()) -> ProjectData {
        let cam = vp.camera
        let tl  = vp.timeline

        // ── Camera static state ───────────────────────────────────────────────
        let cameraData = CameraData(
            yaw:      cam.yaw,
            pitch:    cam.pitch,
            distance: cam.distance,
            targetX:  cam.target.x,
            targetY:  cam.target.y,
            targetZ:  cam.target.z,
            fov:      cam.fovYRadians
        )

        // ── Timeline ──────────────────────────────────────────────────────────
        let timelineData = TimelineData(
            duration:    tl.duration,
            currentTime: tl.currentTime,
            frameRate:   tl.frameRate,
            inPoint:     tl.inPoint,
            outPoint:    tl.outPoint
        )

        // ── Objects — paths + keyframes ───────────────────────────────────────
        // Phase 6: each object carries its own sourceURL.
        // One path per loaded MODEL INSTANCE — so the reload re-creates exactly the
        // instances that were in the scene.  A multi-part model (many objects sharing
        // ONE groupID) emits a single path (it isn't reloaded once per part), while
        // each single-mesh object emits its own path.  This makes the *same file
        // loaded more than once* (Open Model again, or Duplicate Object) round-trip:
        // deduplicating by path alone would collapse the duplicates into one load.
        var _seenGids = Set<Int>()
        let modelPaths: [String] = vp.sceneManager.objects.compactMap { obj -> String? in
            guard !obj.isEnvelope, let path = obj.sourceURL?.path else { return nil }
            if let gid = obj.groupID {
                guard _seenGids.insert(gid).inserted else { return nil }   // one per group
            }
            return path   // single-mesh object → one instance each
        }

        // Exclude envelope null nodes — they have no geometry / sourceURL and are
        // restored separately via `envelopes`.  Keeping them out of objectsData
        // preserves the positional objectsData[i] ↔ scene.objects[i] match on load,
        // where the rebuilt array contains only model objects before envelopes are
        // re-created.
        let objectsData: [ObjectData] = vp.sceneManager.objects.filter { !$0.isEnvelope }.map { obj in
            let kfData: [KeyframeData] = (obj.keyframeTrack?.keyframes ?? []).map { kf in
                KeyframeData(
                    time: kf.time,
                    tx: kf.translation.x, ty: kf.translation.y, tz: kf.translation.z,
                    rx: kf.rotation.imag.x, ry: kf.rotation.imag.y,
                    rz: kf.rotation.imag.z, rw: kf.rotation.real,
                    sx: kf.scale.x, sy: kf.scale.y, sz: kf.scale.z,
                    opacity: kf.opacity
                )
            }
            // Objects with keyframes: save baseTransform so delta computation
            // (invBase * localTransform) stays valid after reload.
            // Objects without keyframes: save the current live position.
            //   • Hierarchical parts (parentIndex != nil): save localTransform so
            //     the local pose is preserved regardless of parent position.
            //   • Root / non-hierarchical: save transform (world) as before.
            let hasKeyframes = !kfData.isEmpty
            let matrixToSave: matrix_float4x4
            if hasKeyframes {
                matrixToSave = obj.baseTransform
            } else if obj.parentIndex != nil {
                matrixToSave = obj.localTransform
            } else {
                matrixToSave = obj.transform
            }
            let bcf = obj.material.baseColorFactor
            return ObjectData(
                name:                obj.name,
                keyframes:           kfData,
                baseTransformMatrix: encodeMatrix(matrixToSave),
                easingMode:          (obj.keyframeTrack?.easingMode ?? .linear).rawValue,
                isVisible:           obj.isVisible,
                occludeWhenHidden:   obj.occludeWhenHidden,
                objectClass:         obj.objectClass.rawValue,
                feedbackEnabled:     obj.feedbackEnabled,
                normalMode:          obj.normalMode.rawValue,
                metallicFactor:      obj.material.metallicFactor,
                roughnessFactor:     obj.material.roughnessFactor,
                baseColorFactor:     [bcf.x, bcf.y, bcf.z, bcf.w],
                opacity:             obj.material.opacity,
                emissiveStrength:    obj.material.emissiveStrength,
                importBundleID:      obj.importBundleID
            )
        }

        // ── Camera keyframes (Phase 5) ────────────────────────────────────────
        let cameraKfData: [CameraKeyframeData] = (cam.keyframeTrack?.keyframes ?? []).map { kf in
            CameraKeyframeData(
                time:               kf.time,
                yaw:                kf.yaw,
                pitch:              kf.pitch,
                distance:           kf.distance,
                targetX:            kf.target.x,
                targetY:            kf.target.y,
                targetZ:            kf.target.z,
                fov:                kf.fov,
                followTarget:       kf.followTargetName,
                followYawOffset:    kf.followYawOffset,
                followPitchOffset:  kf.followPitchOffset,
                targetOffset:       [kf.targetOffset.x, kf.targetOffset.y, kf.targetOffset.z],
                followForwardLocal: kf.followForwardLocal.map { [$0.x, $0.y, $0.z] },
                followUpLocal:      kf.followUpLocal     .map { [$0.x, $0.y, $0.z] }
            )
        }

        // ── Feedback settings (v5) ────────────────────────────────────────────
        let fs = vp.feedbackSettings
        let feedbackData = FeedbackData(
            isEnabled:  fs.isEnabled,
            interval:   fs.interval,
            decay:      fs.decay,
            length:     fs.length,
            blendMode:  fs.blendMode.rawValue,
            swapLayers: fs.swapLayers
        )

        // ── Light keyframe tracks (v6) ────────────────────────────────────────
        // Serialize only as many slots as exist; empty inner arrays are included
        // so index correspondence is preserved on reload.
        let lm = vp.lightManager
        let lightKfData: [[LightKeyframeData]] = lm.keyframeTracks.map { track in
            guard let track = track else { return [] }
            return track.keyframes.map { kf in
                LightKeyframeData(
                    time:          kf.time,
                    intensity:     kf.intensity,
                    r: kf.color.x, g: kf.color.y, b: kf.color.z,
                    tx: kf.target.x, ty: kf.target.y, tz: kf.target.z,
                    px: kf.position.x,  py: kf.position.y,  pz: kf.position.z,
                    range:         kf.range,
                    beamThickness: kf.beamThickness
                )
            }
        }

        // ── Per-light static config (v10) ─────────────────────────────────────
        let lightConfigsData: [LightConfigData] = lm.lights.map { l in
            LightConfigData(
                type:                    l.type.rawValue,
                isEnabled:               l.isEnabled,
                colorR:                  l.color.x,
                colorG:                  l.color.y,
                colorB:                  l.color.z,
                intensity:               l.intensity,
                posX:                    l.position.x,
                posY:                    l.position.y,
                posZ:                    l.position.z,
                targetX:                 l.target.x,
                targetY:                 l.target.y,
                targetZ:                 l.target.z,
                innerConeAngle:          l.innerConeAngle,
                outerConeAngle:          l.outerConeAngle,
                range:                   l.range,
                beamThickness:           l.beamThickness,
                excludeBeamFromFeedback: l.excludeBeamFromFeedback,
                importBundleID:          l.importBundleID
            )
        }

        // ── Background settings (v8) ──────────────────────────────────────────
        let bg = vp.backgroundConfig
        let backgroundData = BackgroundData(
            mode:        bg.mode.rawValue,
            solidR:      bg.solidColor.x,
            solidG:      bg.solidColor.y,
            solidB:      bg.solidColor.z,
            gradTopR:    bg.gradientTop.x,
            gradTopG:    bg.gradientTop.y,
            gradTopB:    bg.gradientTop.z,
            gradBottomR: bg.gradientBottom.x,
            gradBottomG: bg.gradientBottom.y,
            gradBottomB: bg.gradientBottom.z,
            environmentIntensity: bg.environmentIntensity,
            backgroundHDRPath:    bg.backgroundHDRPath,
            environmentHorizon:   bg.environmentHorizon,
            excludeEnvironmentFromFeedback: bg.excludeEnvironmentFromFeedback
        )

        // ── Color grade (v12; exposure v16) ───────────────────────────────────
        let cg = vp.colorGradeSettings
        let colorGradeData = ColorGradeData(
            exposure:   cg.exposure,
            brightness: cg.brightness,
            contrast:   cg.contrast,
            gamma:      cg.gamma
        )

        // ── Group keyframe tracks (v14 / Phase 2) ─────────────────────────────
        // Keyed by sourceFileName so group IDs (runtime ephemeral) can be
        // reconnected on load.  Only tracks with at least one keyframe are stored.
        let occByGid = groupOccurrences(vp.sceneManager.objects)
        var groupTrackData: [GroupTrackData] = []
        for (gid, track) in vp.sceneManager.groupKeyframeTracks {
            guard !track.keyframes.isEmpty else { continue }
            // Derive a stable key: the filename of any object in the group.
            guard let fileName = vp.sceneManager.objects
                .first(where: { $0.groupID == gid })?.sourceURL?
                .lastPathComponent
            else { continue }

            let kfData: [KeyframeData] = track.keyframes.map { kf in
                KeyframeData(
                    time: kf.time,
                    tx: kf.translation.x, ty: kf.translation.y, tz: kf.translation.z,
                    rx: kf.rotation.imag.x, ry: kf.rotation.imag.y,
                    rz: kf.rotation.imag.z, rw: kf.rotation.real,
                    sx: kf.scale.x, sy: kf.scale.y, sz: kf.scale.z,
                    opacity: kf.opacity
                )
            }
            groupTrackData.append(GroupTrackData(
                sourceFileName: fileName,
                occurrence:     occByGid[gid] ?? 0,
                easingMode:     track.easingMode.rawValue,
                keyframes:      kfData
            ))
        }

        // ── Glue envelopes (v34) ──────────────────────────────────────────────
        // Member objects are referenced by their index in the NON-envelope object
        // list (the order the loader rebuilds from modelPaths), so the references
        // stay valid even when envelopes are interleaved in the live array.
        let allObjects = vp.sceneManager.objects
        var nonEnvIndexOf = [Int: Int]()   // full array index → non-envelope index
        var nonEnvCounter = 0
        for (i, o) in allObjects.enumerated() {
            if o.isEnvelope { continue }
            nonEnvIndexOf[i] = nonEnvCounter
            nonEnvCounter += 1
        }
        let envelopeData: [EnvelopeData] = allObjects.enumerated().compactMap { (envIdx, env) in
            guard env.isEnvelope else { return nil }
            let members: [Int] = allObjects.indices
                .filter { allObjects[$0].parentIndex == envIdx }
                .compactMap { nonEnvIndexOf[$0] }
            guard !members.isEmpty else { return nil }
            let kfData: [KeyframeData] = (env.keyframeTrack?.keyframes ?? []).map { kf in
                KeyframeData(
                    time: kf.time,
                    tx: kf.translation.x, ty: kf.translation.y, tz: kf.translation.z,
                    rx: kf.rotation.imag.x, ry: kf.rotation.imag.y,
                    rz: kf.rotation.imag.z, rw: kf.rotation.real,
                    sx: kf.scale.x, sy: kf.scale.y, sz: kf.scale.z,
                    opacity: kf.opacity
                )
            }
            return EnvelopeData(
                name:          env.name,
                transform:     encodeMatrix(env.baseTransform),
                keyframes:     kfData,
                easingMode:    (env.keyframeTrack?.easingMode ?? .linear).rawValue,
                memberIndices: members,
                importBundleID: env.importBundleID
            )
        }

        // v35: rate-marker schedules (Spin / Orbit animators).
        var spinSchedData: [SpinRateScheduleData] = []
        for (ref, markers) in vp.spinRateSchedules where !markers.isEmpty {
            let md = markers.map { SpinRateMarkerData(time: $0.time, rate: $0.rate, axisIndex: $0.axisIndex) }
            switch ref {
            case .object(let i):
                guard i >= 0, i < vp.sceneManager.objects.count else { continue }
                // targetIndex carries the occurrence among same-named objects so a
                // duplicated single-mesh object reloads onto the RIGHT instance.
                spinSchedData.append(SpinRateScheduleData(
                    targetKind: 2, targetName: vp.sceneManager.objects[i].name,
                    targetIndex: objectOccurrence(vp.sceneManager.objects, at: i), markers: md))
            case .group(let gid):
                // Key by (filename, occurrence) so it survives reload + duplicates.
                let fn = vp.sceneManager.objects.first { $0.groupID == gid }?
                    .sourceURL?.lastPathComponent ?? ""
                spinSchedData.append(SpinRateScheduleData(
                    targetKind: 3, targetName: fn, targetIndex: occByGid[gid] ?? 0, markers: md))
            default:
                continue
            }
        }
        var orbitSchedData: [OrbitRateScheduleData] = []
        for (ref, sched) in vp.orbitRateSchedules where !sched.markers.isEmpty {
            let md = sched.markers.map { OrbitRateMarkerData(time: $0.time, rate: $0.rate) }
            let aS = [sched.axisStart.x, sched.axisStart.y, sched.axisStart.z]
            let aE = [sched.axisEnd.x,   sched.axisEnd.y,   sched.axisEnd.z]
            switch ref {
            case .camera:
                orbitSchedData.append(OrbitRateScheduleData(
                    targetKind: 0, targetName: "", targetIndex: -1,
                    axisStart: aS, axisEnd: aE, radius: sched.radius, markers: md))
            case .light(let i):
                orbitSchedData.append(OrbitRateScheduleData(
                    targetKind: 1, targetName: "", targetIndex: i,
                    axisStart: aS, axisEnd: aE, radius: sched.radius, markers: md))
            case .object(let i):
                guard i >= 0, i < vp.sceneManager.objects.count else { continue }
                // targetIndex carries the occurrence among same-named objects (see spin).
                orbitSchedData.append(OrbitRateScheduleData(
                    targetKind: 2, targetName: vp.sceneManager.objects[i].name,
                    targetIndex: objectOccurrence(vp.sceneManager.objects, at: i),
                    axisStart: aS, axisEnd: aE, radius: sched.radius, markers: md))
            default:
                continue
            }
        }

        return ProjectData(
            version:             35,   // v35: rate-marker schedules (Spin / Orbit)
            modelPath:           nil,           // v3+ uses modelPaths instead
            modelPaths:          modelPaths,
            timeline:            timelineData,
            camera:              cameraData,
            objects:             objectsData,
            cameraKeyframes:     cameraKfData,
            isColorMode:         vp.renderSettings.colorMode == .color,   // legacy compat
            colorMode:           vp.renderSettings.colorMode.rawValue,
            feedback:            feedbackData,
            lightKeyframeTracks: lightKfData,
            isLooping:           vp.timeline.isLooping,
            background:          backgroundData,
            isWireframe:         vp.renderer?.isWireframe ?? false,
            showAxesGizmo:       vp.renderSettings.showAxesGizmo,
            lightConfigs:        lightConfigsData,
            windowLayout:        windowLayout,
            colorGrade:          colorGradeData,
            groupKeyframeTracks: groupTrackData,
            iblIntensity:        vp.renderSettings.iblIntensity,
            lightingHDRPath:     vp.renderSettings.lightingHDRPath,
            fog:                 FogData(isEnabled: vp.fogSettings.isEnabled,
                                         r: vp.fogSettings.color.x,
                                         g: vp.fogSettings.color.y,
                                         b: vp.fogSettings.color.z,
                                         density: vp.fogSettings.density,
                                         px: vp.fogSettings.position.x,
                                         py: vp.fogSettings.position.y,
                                         pz: vp.fogSettings.position.z,
                                         sx: vp.fogSettings.size.x,
                                         sy: vp.fogSettings.size.y,
                                         sz: vp.fogSettings.size.z,
                                         variance: vp.fogSettings.variance,
                                         steps:    vp.fogSettings.raymarchSteps),
            fogKeyframes:             captureAtmosphereKeyframes(vp.fogSettings.keyframeTrack),
            particleEmitters:         vp.particleManager.emitters.map { captureParticleEmitter($0) },
            particleEmitterKeyframes: vp.particleManager.emitters.map { captureAtmosphereKeyframes($0.keyframeTrack) },
            probe:               ProbeData(px: vp.probeConfig.position.x,
                                           py: vp.probeConfig.position.y,
                                           pz: vp.probeConfig.position.z,
                                           marks: vp.probeConfig.marks.map {
                                               MarkData(name: $0.name,
                                                        px: $0.position.x, py: $0.position.y, pz: $0.position.z,
                                                        r: $0.color.x, g: $0.color.y, b: $0.color.z)
                                           },
                                           marksVisible: vp.probeConfig.marksVisible),
            groupBaseTransforms: captureGroupBaseTransforms(from: vp),
            cameraEasingMode:    (cam.keyframeTrack?.easingMode ?? .linear).rawValue,
            lightEasingModes:    lm.keyframeTracks.map { ($0?.easingMode ?? .linear).rawValue },
            fogEasingMode:       (vp.fogSettings.keyframeTrack?.easingMode ?? .linear).rawValue,
            particleEmitterEasingModes: vp.particleManager.emitters.map { ($0.keyframeTrack?.easingMode ?? .linear).rawValue },
            envelopes:           envelopeData,
            spinRateSchedules:   spinSchedData,
            orbitRateSchedules:  orbitSchedData,
            importBundles:       vp.sceneManager.importBundles.map { e in
                let lp = vp.sceneManager.importBundleLoops[e.key]
                let sp = vp.sceneManager.importBundleSources[e.key]
                return BundleData(id: e.key, name: e.value,
                                  loopEnabled: lp?.enabled     ?? false,
                                  cycleStart:  lp?.cycleStart  ?? 0,
                                  cycleLength: lp?.cycleLength ?? 0,
                                  sourcePath:   sp?.path         ?? "",
                                  insertOffset: sp?.insertOffset ?? 0,
                                  transform:    sp.map { encodeMatrix($0.transform) } ?? [])
            }
        )
    }

    /// Serialises one particle emitter's static config to Codable data.
    private static func captureParticleEmitter(_ fx: ParticleEffect) -> ParticleEffectData {
        ParticleEffectData(
            isEnabled: fx.isEnabled, type: fx.type.rawValue,
            px: fx.position.x, py: fx.position.y, pz: fx.position.z,
            sx: fx.size.x,     sy: fx.size.y,     sz: fx.size.z,
            density: fx.density, variance: fx.variance,
            r: fx.color.x, g: fx.color.y, b: fx.color.z,
            particleSize: fx.particleSize, fallSpeed: fx.fallSpeed, streak: fx.streak,
            lifetime: fx.lifetime, growth: fx.growth, baseAlpha: fx.baseAlpha,
            importBundleID: fx.importBundleID)
    }

    /// Serialises an atmosphere keyframe track (fog or particles) to Codable data.
    private static func captureAtmosphereKeyframes(_ track: AtmosphereKeyframeTrack?) -> [AtmosphereKeyframeData] {
        (track?.keyframes ?? []).map { kf in
            AtmosphereKeyframeData(
                time: kf.time,
                px: kf.position.x, py: kf.position.y, pz: kf.position.z,
                sx: kf.size.x,     sy: kf.size.y,     sz: kf.size.z,
                density: kf.density, variance: kf.variance,
                r: kf.color.x, g: kf.color.y, b: kf.color.z)
        }
    }

    /// Rebuilds an atmosphere keyframe track from Codable data, or nil if empty.
    private static func applyAtmosphereKeyframes(_ data: [AtmosphereKeyframeData],
                                                 easingMode: Int = 0) -> AtmosphereKeyframeTrack? {
        guard !data.isEmpty else { return nil }
        let track = AtmosphereKeyframeTrack()
        track.easingMode = EasingMode(rawValue: easingMode) ?? .linear
        for kf in data {
            track.addKeyframe(AtmosphereKeyframe(
                time:     kf.time,
                position: SIMD3<Float>(kf.px, kf.py, kf.pz),
                size:     SIMD3<Float>(kf.sx, kf.sy, kf.sz),
                density:  kf.density,
                variance: kf.variance,
                color:    SIMD3<Float>(kf.r, kf.g, kf.b)))
        }
        return track
    }

    /// Restores one particle emitter's static config + keyframe track into `fx`
    /// (mutated in place so existing references — e.g. an open panel — stay valid).
    private static func applyParticleEmitter(_ pd: ParticleEffectData,
                                             keyframes: [AtmosphereKeyframeData],
                                             easingMode: Int = 0,
                                             into fx: ParticleEffect) {
        fx.isEnabled = pd.isEnabled
        fx.type      = ParticleType(rawValue: pd.type) ?? .rain
        fx.position  = SIMD3<Float>(pd.px, pd.py, pd.pz)
        fx.size      = SIMD3<Float>(pd.sx, pd.sy, pd.sz)
        fx.density   = pd.density
        fx.variance  = pd.variance
        fx.color     = SIMD3<Float>(pd.r, pd.g, pd.b)
        // Advanced (v25): start from the type's defaults (covers in-place reuse and
        // older files), then override with any saved values.
        fx.applyTypeDefaults()
        if let v = pd.particleSize { fx.particleSize = v }
        if let v = pd.fallSpeed    { fx.fallSpeed = v }
        if let v = pd.streak       { fx.streak = v }
        if let v = pd.lifetime     { fx.lifetime = v }
        if let v = pd.growth       { fx.growth = v }
        if let v = pd.baseAlpha    { fx.baseAlpha = v }
        fx.importBundleID = pd.importBundleID
        fx.keyframeTrack = applyAtmosphereKeyframes(keyframes, easingMode: easingMode)
    }

    // MARK: - Apply ProjectData → live state

    private static func applyData(_ data: ProjectData, to vp: ViewportView,
                                   missingModelResolver: ((String) -> URL?)? = nil) {

        // ── Timeline ──────────────────────────────────────────────────────────
        vp.timeline.duration    = data.timeline.duration
        vp.timeline.frameRate   = data.timeline.frameRate   // v20: project frame rate
        vp.timeline.inPoint     = data.timeline.inPoint     // Timeline In / Out marks
        vp.timeline.outPoint    = data.timeline.outPoint
        vp.timeline.currentTime = 0.0   // always start from the beginning on load
        vp.timeline.isPlaying   = false
        print("[DEBUG] ProjectFile: timeline duration=" + String(format: "%.2f", data.timeline.duration))

        // Backfill FOV for older project files that predate focal-length persistence.
        // If the saved static camera has no `fov`, fall back to the codebase default
        // (27° — keep in sync with CameraController.swift's `fovYRadians` initializer).
        // Per-keyframe FOV is then backfilled to this same value, so older projects
        // play back at a constant, known FOV instead of leaving the camera at whatever
        // FOV was set before load.
        let defaultFovRadians: Float = 27.0 * Float.pi / 180.0
        let effectiveStaticFov: Float = data.camera.fov ?? defaultFovRadians

        // ── Camera keyframes (Phase 5) — restored before model load ───────────
        if data.cameraKeyframes.isEmpty {
            vp.camera.keyframeTrack = nil
            print("[DEBUG] ProjectFile: no camera keyframes in project")
        } else {
            let camTrack = CameraKeyframeTrack()
            for kfData in data.cameraKeyframes {
                let savedOffset = kfData.targetOffset ?? [0, 0, 0]
                let targetOff   = SIMD3<Float>(savedOffset.count >= 3 ? savedOffset[0] : 0,
                                               savedOffset.count >= 3 ? savedOffset[1] : 0,
                                               savedOffset.count >= 3 ? savedOffset[2] : 0)
                let fwdLocal: SIMD3<Float>? = kfData.followForwardLocal.flatMap {
                    $0.count >= 3 ? SIMD3<Float>($0[0], $0[1], $0[2]) : nil
                }
                let upLocal: SIMD3<Float>? = kfData.followUpLocal.flatMap {
                    $0.count >= 3 ? SIMD3<Float>($0[0], $0[1], $0[2]) : nil
                }
                camTrack.addKeyframe(CameraKeyframe(
                    time:               kfData.time,
                    yaw:                kfData.yaw,
                    pitch:              kfData.pitch,
                    distance:           kfData.distance,
                    target:             SIMD3<Float>(kfData.targetX, kfData.targetY, kfData.targetZ),
                    fov:                kfData.fov ?? effectiveStaticFov,
                    followTargetName:   kfData.followTarget,
                    followYawOffset:    kfData.followYawOffset,
                    followPitchOffset:  kfData.followPitchOffset,
                    targetOffset:       targetOff,
                    followForwardLocal: fwdLocal,
                    followUpLocal:      upLocal
                ))
            }
            camTrack.easingMode = EasingMode(rawValue: data.cameraEasingMode) ?? .linear
            vp.camera.keyframeTrack = camTrack
            print("[DEBUG] ProjectFile: restored " + String(data.cameraKeyframes.count)
                + " camera keyframes")
        }

        // ── Models ────────────────────────────────────────────────────────────
        // v3: modelPaths array.  v1/v2 fallback: single modelPath string.
        let paths: [String]
        if !data.modelPaths.isEmpty {
            paths = data.modelPaths
        } else if let p = data.modelPath, !p.isEmpty {
            paths = [p]
        } else {
            paths = []
        }

        // Clear scene, then add each model.  addModelToScene appends without
        // triggering fitToScene on the second+ object, and sets sourceURL.
        vp.sceneManager.clear()

        // Map from "saved-filename" → "loaded-filename" for any models the user
        // re-located via the missingModelResolver.  Used by applyGroupKeyframes
        // below so group tracks saved under the original filename still find
        // their now-renamed group on load.
        var substitutedFilenames: [String: String] = [:]

        var loadedCount = 0
        for pathStr in paths {
            let modelURL: URL
            if FileManager.default.fileExists(atPath: pathStr) {
                modelURL = URL(fileURLWithPath: pathStr)
            } else if let resolved = missingModelResolver?(pathStr) {
                print("[DEBUG] ProjectFile: missing model resolved by user — " + resolved.lastPathComponent)
                modelURL = resolved
                let savedFileName    = (pathStr as NSString).lastPathComponent
                let resolvedFileName = resolved.lastPathComponent
                if savedFileName != resolvedFileName {
                    substitutedFilenames[savedFileName] = resolvedFileName
                }
            } else {
                print("[DEBUG] ProjectFile: model file not found at " + pathStr)
                continue
            }
            vp.addModelToScene(url: modelURL)
            loadedCount += 1
        }

        if loadedCount == 0 && paths.isEmpty {
            print("[DEBUG] ProjectFile: no model paths stored in project")
        }

        // ── Import bundles (Part B) ───────────────────────────────────────────
        // Restore the id→name table (clear() emptied it); per-object / per-light
        // importBundleID tags are reattached by applyKeyframes / the light restore.
        for b in data.importBundles {
            vp.sceneManager.importBundles[b.id] = b.name
            vp.sceneManager.importBundleLoops[b.id] = SceneManager.BundleLoop(
                enabled: b.loopEnabled, cycleStart: b.cycleStart, cycleLength: b.cycleLength)
            if !b.sourcePath.isEmpty {
                vp.sceneManager.importBundleSources[b.id] = SceneManager.BundleSource(
                    path: b.sourcePath, insertOffset: b.insertOffset,
                    transform: decodeMatrix(b.transform) ?? matrix_identity_float4x4)
            }
        }
        vp.sceneManager.syncImportBundleCounter()

        // ── Color mode ────────────────────────────────────────────────────────
        vp.renderSettings.colorMode = RenderColorMode(rawValue: data.colorMode) ?? .color
        print("[DEBUG] ProjectFile: colorMode=" + vp.renderSettings.colorMode.displayName)

        // ── Feedback settings (v5) ────────────────────────────────────────────
        let fb = data.feedback
        vp.feedbackSettings.isEnabled  = fb.isEnabled
        vp.feedbackSettings.interval   = fb.interval
        vp.feedbackSettings.decay      = fb.decay
        vp.feedbackSettings.length     = fb.length
        vp.feedbackSettings.blendMode  = BlendMode(rawValue: fb.blendMode) ?? .normal
        vp.feedbackSettings.swapLayers = fb.swapLayers
        print("[DEBUG] ProjectFile: feedback enabled=\(fb.isEnabled)"
            + " interval=\(fb.interval) decay=\(fb.decay) length=\(fb.length)"
            + " blendMode=\(fb.blendMode) swapLayers=\(fb.swapLayers)")

        // ── Loop toggle (v7) ──────────────────────────────────────────────────
        vp.timeline.isLooping = data.isLooping
        print("[DEBUG] ProjectFile: isLooping=\(data.isLooping)")

        // ── Background settings (v8) ──────────────────────────────────────────
        let bd = data.background
        vp.backgroundConfig.mode         = BackgroundMode(rawValue: bd.mode) ?? .solid
        vp.backgroundConfig.solidColor   = SIMD3<Float>(bd.solidR,      bd.solidG,      bd.solidB)
        vp.backgroundConfig.gradientTop  = SIMD3<Float>(bd.gradTopR,    bd.gradTopG,    bd.gradTopB)
        vp.backgroundConfig.gradientBottom = SIMD3<Float>(bd.gradBottomR, bd.gradBottomG, bd.gradBottomB)
        vp.backgroundConfig.environmentIntensity = bd.environmentIntensity
        vp.backgroundConfig.environmentHorizon   = bd.environmentHorizon
        vp.backgroundConfig.excludeEnvironmentFromFeedback = bd.excludeEnvironmentFromFeedback
        // v28: dedicated Background HDR (empty = mirror lighting; missing → fall back).
        vp.backgroundConfig.backgroundHDRPath = bd.backgroundHDRPath
        let bgURL = bd.backgroundHDRPath.isEmpty ? nil : AppSettings.expand(bd.backgroundHDRPath)
        let bgOK  = bgURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? true
        vp.renderer?.setBackgroundHDR(bgOK ? bgURL : nil)
        print("[DEBUG] ProjectFile: background mode=\(vp.backgroundConfig.mode.displayName)"
            + " solid=(\(bd.solidR),\(bd.solidG),\(bd.solidB))")

        // ── Wireframe + axes gizmo (v8) ───────────────────────────────────────
        vp.renderer?.isWireframe          = data.isWireframe
        vp.renderSettings.showAxesGizmo   = data.showAxesGizmo
        print("[DEBUG] ProjectFile: isWireframe=\(data.isWireframe)"
            + " showAxesGizmo=\(data.showAxesGizmo)")

        // ── Per-light static config (v10) ─────────────────────────────────────
        if !data.lightConfigs.isEmpty {
            let lm = vp.lightManager
            // Replace existing lights with saved configs (preserving count)
            lm.lights = data.lightConfigs.compactMap { lcd -> LightConfig? in
                guard let lightType = LightType(rawValue: lcd.type) else { return nil }
                var l = LightConfig()
                l.type                    = lightType
                l.isEnabled               = lcd.isEnabled
                l.color                   = SIMD3<Float>(lcd.colorR, lcd.colorG, lcd.colorB)
                l.intensity               = lcd.intensity
                l.position                = SIMD3<Float>(lcd.posX, lcd.posY, lcd.posZ)
                l.target                  = SIMD3<Float>(lcd.targetX, lcd.targetY, lcd.targetZ)
                l.innerConeAngle          = lcd.innerConeAngle
                l.outerConeAngle          = lcd.outerConeAngle
                l.range                   = lcd.range
                l.beamThickness           = lcd.beamThickness
                l.excludeBeamFromFeedback = lcd.excludeBeamFromFeedback
                l.importBundleID          = lcd.importBundleID   // Part B
                return l
            }
            // Pad keyframe tracks array to match new light count
            while lm.keyframeTracks.count < lm.lights.count { lm.keyframeTracks.append(nil) }
            lm.selectedIndex = min(lm.selectedIndex, max(0, lm.lights.count - 1))
            print("[DEBUG] ProjectFile: restored \(lm.lights.count) light configs")
        }

        // Replace demo animations with saved keyframes; restore base transforms.
        applyKeyframes(data.objects, to: vp)

        // ── Glue envelopes (v34) ──────────────────────────────────────────────
        // Re-create null nodes and re-parent their members.  Done AFTER
        // applyKeyframes so each member's saved local matrix is already restored
        // into its baseTransform, and so the object array still contains only
        // model objects (matching the saved non-envelope member indices).
        applyEnvelopes(data.envelopes, to: vp)

        // ── Camera static state — applied LAST so it overrides any fitToScene ─
        let c = data.camera
        vp.camera.yaw         = c.yaw
        vp.camera.pitch       = c.pitch
        vp.camera.distance    = c.distance
        vp.camera.target      = SIMD3<Float>(c.targetX, c.targetY, c.targetZ)
        vp.camera.fovYRadians = effectiveStaticFov
        print("[DEBUG] ProjectFile: camera restored — yaw=" + String(format: "%.3f", c.yaw)
            + " pitch=" + String(format: "%.3f", c.pitch)
            + " dist="  + String(format: "%.3f", c.distance)
            + " fov="   + String(format: "%.3f", effectiveStaticFov))

        // ── Light keyframe tracks (v6) ────────────────────────────────────────
        applyLightKeyframes(data.lightKeyframeTracks, easingModes: data.lightEasingModes, to: vp)

        // ── Group keyframe tracks (v14 / Phase 2) ─────────────────────────────
        applyGroupKeyframes(data.groupKeyframeTracks, to: vp,
                            substitutedFilenames: substitutedFilenames)

        // ── Group base transforms (v31) ───────────────────────────────────────
        // Restores `gt` for groups that have slider/Model-mode edits but no
        // keyframes (otherwise their `gt` would be lost on save/load and the
        // model would snap back to auto-normalise size).  For groups WITH a
        // track, the next applyAnimation pass overwrites `gt` from the track,
        // so this restore is a no-op for them.
        applyGroupBaseTransforms(data.groupBaseTransforms, to: vp,
                                 substitutedFilenames: substitutedFilenames)

        // ── Rate-marker schedules (v35) ───────────────────────────────────────
        // Restore the editable Spin / Orbit markers.  The baked keyframes they
        // produced are already restored with the regular tracks above, so we only
        // rebuild the schedule dictionaries (no regeneration) for later editing.
        applyRateSchedules(data, to: vp)

        // Sync HUD with restored scene.
        vp.syncOverlayState()

        // ── Color grade (v12; exposure v16) ───────────────────────────────────
        vp.colorGradeSettings.exposure   = data.colorGrade.exposure
        vp.colorGradeSettings.brightness = data.colorGrade.brightness
        vp.colorGradeSettings.contrast   = data.colorGrade.contrast
        vp.colorGradeSettings.gamma      = data.colorGrade.gamma
        print("[DEBUG] ProjectFile: colorGrade exposure=\(data.colorGrade.exposure)"
            + " brightness=\(data.colorGrade.brightness)"
            + " contrast=\(data.colorGrade.contrast)"
            + " gamma=\(data.colorGrade.gamma)")

        // ── IBL intensity (v16) ───────────────────────────────────────────────
        vp.renderSettings.iblIntensity = data.iblIntensity
        print("[DEBUG] ProjectFile: iblIntensity=\(data.iblIntensity)")
        // v29: bake probe position (gizmo visibility is editor-only, not restored).
        vp.probeConfig.position = SIMD3<Float>(data.probe.px, data.probe.py, data.probe.pz)
        vp.probeConfig.marks = (data.probe.marks ?? []).map {
            ProbeMark(name: $0.name,
                      position: SIMD3<Float>($0.px, $0.py, $0.pz),
                      color:    SIMD3<Float>($0.r, $0.g, $0.b))
        }
        vp.probeConfig.marksVisible = data.probe.marksVisible ?? false
        vp.probeConfig.selectedMarkIndex = nil
        // v28: hot-reload the Lighting HDR from the saved path (bundled if missing).
        vp.renderSettings.lightingHDRPath = data.lightingHDRPath
        let lightURL = data.lightingHDRPath.isEmpty ? nil : AppSettings.expand(data.lightingHDRPath)
        let lightOK  = lightURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? true
        vp.renderer?.reloadLightingHDR(lightOK ? lightURL : nil)

        // ── Fog volume (v19 distance fog → v22 box volume) ────────────────────
        vp.fogSettings.isEnabled = data.fog.isEnabled
        vp.fogSettings.color     = SIMD3<Float>(data.fog.r, data.fog.g, data.fog.b)
        vp.fogSettings.density   = data.fog.density
        vp.fogSettings.position  = SIMD3<Float>(data.fog.px, data.fog.py, data.fog.pz)
        vp.fogSettings.size      = SIMD3<Float>(data.fog.sx, data.fog.sy, data.fog.sz)
        vp.fogSettings.variance  = data.fog.variance
        vp.fogSettings.raymarchSteps = data.fog.steps
        print("[DEBUG] ProjectFile: fog enabled=\(data.fog.isEnabled) density=\(data.fog.density)")

        // ── Fog keyframe track (v23) ──────────────────────────────────────────
        vp.fogSettings.keyframeTrack = applyAtmosphereKeyframes(data.fogKeyframes,
                                                                easingMode: data.fogEasingMode)

        // ── Weather particle emitters (v21 single → v24 multiple) ─────────────
        let emitterData: [ParticleEffectData]
        let emitterKfs:  [[AtmosphereKeyframeData]]
        if !data.particleEmitters.isEmpty {
            emitterData = data.particleEmitters
            emitterKfs  = data.particleEmitterKeyframes
        } else {
            emitterData = [data.particles]               // migrate legacy single emitter
            emitterKfs  = [data.particleKeyframes]
        }
        // Reuse existing emitter instances (mutate in place) so an open Atmosphere
        // panel keeps a valid reference; resize the list to match the saved count.
        let mgr = vp.particleManager
        let targetCount = max(1, emitterData.count)
        while mgr.emitters.count < targetCount { mgr.emitters.append(ParticleEffect()) }
        while mgr.emitters.count > targetCount { mgr.emitters.removeLast() }
        for i in 0..<targetCount {
            let pd  = i < emitterData.count ? emitterData[i] : ParticleEffectData()
            let kfs = i < emitterKfs.count  ? emitterKfs[i]  : []
            let em  = i < data.particleEmitterEasingModes.count ? data.particleEmitterEasingModes[i] : 0
            applyParticleEmitter(pd, keyframes: kfs, easingMode: em, into: mgr.emitters[i])
        }
        mgr.selectedIndex = 0
        print("[DEBUG] ProjectFile: particle emitters=\(mgr.emitters.count)"
            + " fogKeyframes=\(data.fogKeyframes.count)")

        // ── Import-bundle loops ("Repeat to Fill Timeline") ───────────────────
        // Re-tile any looped bundle out to the (now restored) timeline duration.
        // Idempotent: clears any persisted tiles and rebuilds from the source cycle.
        vp.regenerateAllBundleLoops()

        // Force the Renderer to re-evaluate keyframes on the next draw.
        // Without this, lastAnimatedTime == currentTime (both 0) so applyAnimation()
        // never fires and objects appear at their base transform instead of the t=0 pose.
        vp.renderer?.invalidateAnimationCache()
    }

    // MARK: - Apply keyframes + base transforms

    // Restores each object's baseTransform (v4) and keyframeTrack.
    //
    // Saved object data is paired to live scene parts **per model, by part name**:
    // each model loads as one contiguous block (shared sourceURL), and the loader
    // renames each model's root to its file basename, so saved blocks line up with
    // live blocks.  Matching by name *within* a block means a count/order drift in
    // one model can never push another model's (or its own) base transforms onto
    // the wrong parts — the load bug that made multi-part models "come apart."
    //
    // Falls back to the legacy position (index) matching whenever a confident
    // per-model partition can't be established — substitution renames a model's
    // root, a model is missing, etc. — so those paths behave exactly as before.
    private static func applyKeyframes(_ objectsData: [ObjectData], to vp: ViewportView) {
        let objects = vp.sceneManager.objects
        if applyKeyframesByModel(objectsData, objects: objects, vp: vp) { return }

        // ── Legacy fallback: position (index) matching ───────────────────────────
        let n = min(objects.count, objectsData.count)
        if objects.count != objectsData.count {
            print("[DEBUG] ProjectFile: object count mismatch on load —"
                + " saved=" + String(objectsData.count)
                + " loaded=" + String(objects.count)
                + " (extras get no keyframes)")
        }
        for i in 0..<n { restoreObject(objectsData[i], into: objects[i], vp: vp) }
    }

    /// Per-model, name-aware restore.  Returns false (caller falls back to index
    /// matching) if the saved/live blocks can't be confidently partitioned.
    private static func applyKeyframesByModel(_ savedObjs: [ObjectData],
                                              objects: [SceneObject],
                                              vp: ViewportView) -> Bool {
        guard !objects.isEmpty, !savedObjs.isEmpty else { return false }

        // 1. Live blocks: contiguous runs of objects that share a sourceURL.
        var liveBlocks: [[Int]] = []
        var lastKey: String? = nil
        for (i, o) in objects.enumerated() {
            guard let key = o.sourceURL?.path else { return false }   // unexpected → fallback
            if key != lastKey { liveBlocks.append([]); lastKey = key }
            liveBlocks[liveBlocks.count - 1].append(i)
        }

        // 2. Each live block's model basename (the loader renamed its root to this,
        //    so the matching saved block starts with an object of the same name).
        let baseNames: [String] = liveBlocks.map {
            objects[$0[0]].sourceURL?.deletingPathExtension().lastPathComponent ?? ""
        }

        // 3. Saved blocks: split at each expected basename, in order.
        var savedBlocks: [[Int]] = []
        var m = 0
        for (i, sd) in savedObjs.enumerated() {
            if m < baseNames.count, sd.name == baseNames[m] {
                savedBlocks.append([i]); m += 1
            } else if savedBlocks.isEmpty {
                return false                       // content before the first root → fallback
            } else {
                savedBlocks[savedBlocks.count - 1].append(i)
            }
        }
        guard savedBlocks.count == liveBlocks.count else { return false }

        // 4. Restore each model block independently.
        for (lb, sb) in zip(liveBlocks, savedBlocks) {
            restoreBlock(live: lb, saved: sb, objects: objects, savedObjs: savedObjs, vp: vp)
        }
        print("[DEBUG] ProjectFile: per-model restore — \(liveBlocks.count) model block(s)")
        return true
    }

    /// Restores one model's parts: by unique part name when the saved and live
    /// names correspond (same model), otherwise by within-block position (a
    /// substituted / renamed model, where names don't line up).
    private static func restoreBlock(live: [Int], saved: [Int],
                                     objects: [SceneObject], savedObjs: [ObjectData],
                                     vp: ViewportView) {
        var savedByName: [String: Int] = [:]
        var uniqueNames = true
        for s in saved {
            if savedByName.updateValue(s, forKey: savedObjs[s].name) != nil { uniqueNames = false }
        }
        let overlap = live.filter { savedByName[objects[$0].name] != nil }.count
        if uniqueNames, overlap * 2 >= live.count {
            // Same model → name match (immune to index drift within the block).
            for l in live {
                if let s = savedByName[objects[l].name] {
                    restoreObject(savedObjs[s], into: objects[l], vp: vp)
                }
                // No saved counterpart → keep the freshly-loaded GLB base transform.
            }
        } else {
            // Substituted / renamed model → position match within the block.
            let k = min(live.count, saved.count)
            for j in 0..<k { restoreObject(savedObjs[saved[j]], into: objects[live[j]], vp: vp) }
        }
    }

    /// Restores Inspector state, baseTransform, and the keyframe track for one part.
    /// `timeOffset` shifts every keyframe time (used by project IMPORT to drop the
    /// clip in at a chosen playhead).  Spatial placement of an import is applied by
    /// `importProject` in separate passes (after envelopes re-parent their members).
    private static func restoreObject(_ saved: ObjectData, into obj: SceneObject,
                                      vp: ViewportView,
                                      timeOffset: Double = 0) {
        // ── v15: restore Model Inspector state ───────────────────────────────────
        obj.isVisible = saved.isVisible
        obj.occludeWhenHidden = saved.occludeWhenHidden   // v17
        obj.objectClass = ObjectClass(rawValue: saved.objectClass) ?? .background
        obj.feedbackEnabled = saved.feedbackEnabled
        obj.importBundleID  = saved.importBundleID   // Part B (import overrides this later)
        if let mode = NormalMode(rawValue: saved.normalMode), mode != .auto {
            vp.applyNormalMode(mode, toTargets: [obj])
            obj.normalMode = mode
        }
        if saved.metallicFactor >= 0  { obj.material.metallicFactor  = saved.metallicFactor }
        if saved.roughnessFactor >= 0 { obj.material.roughnessFactor = saved.roughnessFactor }
        if saved.baseColorFactor.count == 4 {
            obj.material.baseColorFactor = SIMD4<Float>(
                saved.baseColorFactor[0], saved.baseColorFactor[1],
                saved.baseColorFactor[2], saved.baseColorFactor[3])
        }
        obj.material.opacity = saved.opacity
        obj.material.emissiveStrength = saved.emissiveStrength

        // ── v4: restore baseTransform so manual repositioning survives reload ─────
        if let m = decodeMatrix(saved.baseTransformMatrix) {
            obj.baseTransform = m
            if obj.parentIndex != nil {
                // Hierarchical part: m is a LOCAL transform.  Set localTransform;
                // applyHierarchy() computes the world transform next draw.
                obj.localTransform = m
                obj.transform      = m   // temporary; overwritten by applyHierarchy
            } else {
                obj.transform = m        // root: m is the world transform
            }
        }

        // ── Keyframe track ────────────────────────────────────────────────────────
        guard !saved.keyframes.isEmpty else { return }
        let track = KeyframeTrack()
        track.easingMode = EasingMode(rawValue: saved.easingMode) ?? .linear
        for kf in saved.keyframes {
            track.addKeyframe(TransformKeyframe(
                time:        kf.time + timeOffset,
                translation: SIMD3<Float>(kf.tx, kf.ty, kf.tz),
                rotation:    simd_quatf(ix: kf.rx, iy: kf.ry, iz: kf.rz, r: kf.rw),
                scale:       SIMD3<Float>(kf.sx, kf.sy, kf.sz),
                opacity:     kf.opacity
            ))
        }
        obj.keyframeTrack = track
    }

    // MARK: - Apply Glue envelopes (v34)

    /// Re-creates envelope null nodes and re-parents their members.  Must run after
    /// applyKeyframes (members' local matrices are restored into baseTransform) and
    /// before applyHierarchy runs in the renderer (which recomputes member world
    /// transforms from envelope × local on the next draw).
    private static func applyEnvelopes(_ data: [EnvelopeData], to vp: ViewportView) {
        guard !data.isEmpty else { return }
        let sm = vp.sceneManager
        // sm.objects currently holds only model objects, in the same order as the
        // saved non-envelope list — so memberIndices index directly into it.
        let modelCount = sm.objects.count

        for env in data {
            guard let m = decodeMatrix(env.transform) else {
                print("[DEBUG] ProjectFile: envelope '\(env.name)' missing transform — skipped")
                continue
            }
            let node            = SceneObject(name: env.name)
            node.isEnvelope     = true
            node.transform      = m
            node.baseTransform  = m
            node.localTransform = m
            node.importBundleID = env.importBundleID   // Part B: keep glued objects nested

            if !env.keyframes.isEmpty {
                let track = KeyframeTrack()
                track.easingMode = EasingMode(rawValue: env.easingMode) ?? .linear
                for kf in env.keyframes {
                    track.addKeyframe(TransformKeyframe(
                        time:        kf.time,
                        translation: SIMD3<Float>(kf.tx, kf.ty, kf.tz),
                        rotation:    simd_quatf(ix: kf.rx, iy: kf.ry, iz: kf.rz, r: kf.rw),
                        scale:       SIMD3<Float>(kf.sx, kf.sy, kf.sz),
                        opacity:     kf.opacity
                    ))
                }
                node.keyframeTrack = track
            }

            sm.objects.append(node)
            let envIndex = sm.objects.count - 1

            // Re-link members: their saved baseTransform already holds the local
            // pose relative to the envelope (a hierarchical part saves localTransform).
            for mi in env.memberIndices {
                guard mi >= 0, mi < modelCount else {
                    print("[DEBUG] ProjectFile: envelope '\(env.name)' member index \(mi) out of range")
                    continue
                }
                let member            = sm.objects[mi]
                member.parentIndex    = envIndex
                member.localTransform = member.baseTransform
            }
            print("[DEBUG] ProjectFile: restored envelope '\(env.name)' idx=\(envIndex)"
                + " members=\(env.memberIndices)")
        }
    }

    // MARK: - Apply light keyframe tracks (v6)

    private static func applyLightKeyframes(_ tracksData: [[LightKeyframeData]],
                                             easingModes: [Int] = [],
                                             to vp: ViewportView) {
        let lm = vp.lightManager

        // Ensure the keyframeTracks array is long enough to hold all slots.
        while lm.keyframeTracks.count < lm.lights.count {
            lm.keyframeTracks.append(nil)
        }

        // Clear existing tracks before restoring.
        for i in 0..<lm.keyframeTracks.count { lm.keyframeTracks[i] = nil }

        for (i, kfDataArray) in tracksData.enumerated() {
            guard !kfDataArray.isEmpty else { continue }
            // Only restore if the corresponding light slot still exists.
            guard i < lm.lights.count else { continue }

            let track = LightKeyframeTrack()
            track.easingMode = EasingMode(rawValue: i < easingModes.count ? easingModes[i] : 0) ?? .linear
            for kf in kfDataArray {
                track.addKeyframe(LightKeyframe(
                    time:          kf.time,
                    intensity:     kf.intensity,
                    color:         SIMD3<Float>(kf.r, kf.g, kf.b),
                    target:        SIMD3<Float>(kf.tx, kf.ty, kf.tz),
                    position:      SIMD3<Float>(kf.px, kf.py, kf.pz),
                    range:         kf.range,
                    beamThickness: kf.beamThickness
                ))
            }
            lm.keyframeTracks[i] = track
            print("[DEBUG] ProjectFile: restored \(kfDataArray.count)"
                + " light keyframes for slot \(i)")
        }
    }

    // MARK: - Apply rate-marker schedules (v35)

    /// Rebuilds the Spin / Orbit rate-marker schedule dictionaries from saved data,
    /// matching tracks by identity (object by name, group by groupID, light by
    /// index, camera singleton).  Does NOT regenerate keyframes — those were already
    /// restored with the regular tracks; this only re-enables rate editing.
    private static func applyRateSchedules(_ data: ProjectData, to vp: ViewportView) {
        vp.spinRateSchedules  = [:]
        vp.orbitRateSchedules = [:]
        let gidMap = groupGidMap(vp.sceneManager, substitutedFilenames: [:])

        for sd in data.spinRateSchedules {
            let markers = sd.markers.map { SpinRateMarker(time: $0.time, rate: $0.rate, axisIndex: $0.axisIndex) }
            guard !markers.isEmpty else { continue }
            switch sd.targetKind {
            case 2:
                // Match the occurrence-th object of that name (legacy files: targetIndex
                // 0/-1 → clamp to occurrence 0 = first instance, the old behavior).
                if let i = objectIndex(vp.sceneManager.objects, name: sd.targetName,
                                       occurrence: max(0, sd.targetIndex)) {
                    vp.spinRateSchedules[.object(i)] = markers
                }
            case 3:
                // New files key by (filename, occurrence); legacy files stored the gid
                // in targetIndex with an empty targetName.
                let gid = sd.targetName.isEmpty ? sd.targetIndex
                                                : gidMap["\(sd.targetName)#\(sd.targetIndex)"]
                if let gid = gid { vp.spinRateSchedules[.group(gid)] = markers }
            default:
                break
            }
        }

        for od in data.orbitRateSchedules {
            let markers = od.markers.map { OrbitRateMarker(time: $0.time, rate: $0.rate) }
            guard !markers.isEmpty, od.axisStart.count == 3, od.axisEnd.count == 3 else { continue }
            let sched = OrbitRateSchedule(
                axisStart: SIMD3<Float>(od.axisStart[0], od.axisStart[1], od.axisStart[2]),
                axisEnd:   SIMD3<Float>(od.axisEnd[0],   od.axisEnd[1],   od.axisEnd[2]),
                radius:    od.radius, markers: markers)
            switch od.targetKind {
            case 0:
                vp.orbitRateSchedules[.camera] = sched
            case 1:
                vp.orbitRateSchedules[.light(od.targetIndex)] = sched
            case 2:
                if let i = objectIndex(vp.sceneManager.objects, name: od.targetName,
                                       occurrence: max(0, od.targetIndex)) {
                    vp.orbitRateSchedules[.object(i)] = sched
                }
            default:
                break
            }
        }
    }

    /// 0-based occurrence of the object at `i` among objects sharing its name, in
    /// object-array order — the identity used to disambiguate duplicated single-mesh
    /// objects in persisted rate schedules.
    private static func objectOccurrence(_ objects: [SceneObject], at i: Int) -> Int {
        let name = objects[i].name
        var occ = 0
        for k in 0..<i where objects[k].name == name { occ += 1 }
        return occ
    }

    /// Index of the `occurrence`-th object named `name` (object-array order), or nil.
    private static func objectIndex(_ objects: [SceneObject], name: String, occurrence: Int) -> Int? {
        var count = 0
        for (k, o) in objects.enumerated() where o.name == name {
            if count == occurrence { return k }
            count += 1
        }
        return nil
    }

    // MARK: - Apply group keyframe tracks (v14 / Phase 2)

    /// Restores group-level animation tracks saved in v14+ project files.
    /// Tracks are keyed by source filename; we walk the live sceneManager to find
    /// the runtime groupID that corresponds to each saved filename.
    ///
    /// `substitutedFilenames` carries any renames the user did via the
    /// missing-model resolver — entries of `originalSavedName → loadedReplacementName`.
    /// We augment the file→gid map with alias entries so a group track saved as
    /// "robot 1.glb" still finds the group that loaded from "robot 2.glb".
    private static func applyGroupKeyframes(_ tracksData: [GroupTrackData],
                                             to vp: ViewportView,
                                             substitutedFilenames: [String: String] = [:]) {
        guard !tracksData.isEmpty else { return }
        let sm = vp.sceneManager

        // "<filename>#<occurrence>" → gid (handles the same model loaded > once).
        let gidMap = groupGidMap(sm, substitutedFilenames: substitutedFilenames)

        for trackData in tracksData {
            guard !trackData.keyframes.isEmpty else { continue }
            guard let gid = gidMap["\(trackData.sourceFileName)#\(trackData.occurrence)"] else {
                print("[DEBUG] ProjectFile: group track skipped — no loaded group"
                    + " matches '\(trackData.sourceFileName)#\(trackData.occurrence)'")
                continue
            }

            let track = KeyframeTrack()
            track.easingMode = EasingMode(rawValue: trackData.easingMode) ?? .linear
            for kf in trackData.keyframes {
                track.addKeyframe(TransformKeyframe(
                    time:        kf.time,
                    translation: SIMD3<Float>(kf.tx, kf.ty, kf.tz),
                    rotation:    simd_quatf(ix: kf.rx, iy: kf.ry, iz: kf.rz, r: kf.rw),
                    scale:       SIMD3<Float>(kf.sx, kf.sy, kf.sz),
                    opacity:     kf.opacity
                ))
            }
            sm.groupKeyframeTracks[gid] = track
            print("[DEBUG] ProjectFile: restored \(trackData.keyframes.count)"
                + " group keyframes for '\(trackData.sourceFileName)' → gid=\(gid)")
        }
    }

    /// v31 counterpart to `applyGroupKeyframes`: writes each saved group's
    /// matrix into `sceneManager.groupTransforms[gid]`.  Indexed by source
    /// filename (gids are runtime ephemeral).  For tracked groups the value
    /// is overwritten by the track evaluator on first frame; for untracked
    /// groups it persists, which is the whole point.
    private static func applyGroupBaseTransforms(_ entries: [GroupBaseTransformData],
                                                 to vp: ViewportView,
                                                 substitutedFilenames: [String: String] = [:]) {
        guard !entries.isEmpty else { return }
        let sm = vp.sceneManager

        let gidMap = groupGidMap(sm, substitutedFilenames: substitutedFilenames)

        for entry in entries {
            guard let gid = gidMap["\(entry.sourceFileName)#\(entry.occurrence)"] else {
                print("[DEBUG] ProjectFile: group base transform skipped — no loaded group"
                    + " matches '\(entry.sourceFileName)#\(entry.occurrence)'")
                continue
            }
            guard let m = decodeMatrix(entry.matrix) else { continue }
            sm.groupTransforms[gid] = m
            print("[DEBUG] ProjectFile: restored group base transform for"
                + " '\(entry.sourceFileName)' → gid=\(gid)")
        }
    }

    // MARK: - Matrix helpers

    /// Snapshot `sceneManager.groupTransforms[gid]` for every loaded group,
    /// keyed by the model's source filename.  Saving this means slider edits
    /// and Model-mode drags that wrote to `gt` (but were never recorded as a
    /// keyframe) survive save/load — e.g. setting a station's scale once for
    /// the whole project.  Tracked groups still emit an entry but the track
    /// evaluator overwrites `gt` on the first frame after load, so the saved
    /// matrix is effectively unused for those.
    private static func captureGroupBaseTransforms(from vp: ViewportView) -> [GroupBaseTransformData] {
        let occByGid = groupOccurrences(vp.sceneManager.objects)
        var seen: Set<Int> = []
        var out: [GroupBaseTransformData] = []
        for obj in vp.sceneManager.objects {
            guard let gid = obj.groupID, !seen.contains(gid),
                  let fileName = obj.sourceURL?.lastPathComponent
            else { continue }
            seen.insert(gid)
            let gt = vp.sceneManager.groupTransforms[gid] ?? matrix_identity_float4x4
            out.append(GroupBaseTransformData(
                sourceFileName: fileName,
                occurrence:     occByGid[gid] ?? 0,
                matrix:         encodeMatrix(gt)
            ))
        }
        return out
    }

    // MARK: - Group identity (supports the same model loaded multiple times)

    /// gid → occurrence index (0-based) among groups sharing the same source
    /// filename, in object-array order.  Object order == load order, so the index a
    /// group gets on save is the same one it gets on load.
    private static func groupOccurrences(_ objects: [SceneObject]) -> [Int: Int] {
        var occ: [Int: Int] = [:]
        var perFile: [String: Int] = [:]
        for obj in objects {
            guard let gid = obj.groupID, occ[gid] == nil,
                  let fn = obj.sourceURL?.lastPathComponent else { continue }
            let n = perFile[fn, default: 0]
            occ[gid] = n
            perFile[fn] = n + 1
        }
        return occ
    }

    /// Load-side counterpart: `"<filename>#<occurrence>"` → gid for the currently
    /// loaded groups (object order), plus aliases for substituted filenames.
    private static func groupGidMap(_ sm: SceneManager,
                                    substitutedFilenames: [String: String]) -> [String: Int] {
        var map: [String: Int] = [:]
        var perFile: [String: Int] = [:]
        var seen = Set<Int>()
        for obj in sm.objects {
            guard let gid = obj.groupID, !seen.contains(gid),
                  let fn = obj.sourceURL?.lastPathComponent else { continue }
            seen.insert(gid)
            let n = perFile[fn, default: 0]
            map["\(fn)#\(n)"] = gid
            perFile[fn] = n + 1
        }
        for (savedName, loadedName) in substitutedFilenames {
            for occ in 0..<(perFile[loadedName] ?? 0) {
                if let gid = map["\(loadedName)#\(occ)"] { map["\(savedName)#\(occ)"] = gid }
            }
        }
        return map
    }

    /// Encodes a column-major 4×4 matrix as 16 floats.
    private static func encodeMatrix(_ m: matrix_float4x4) -> [Float] {
        return [
            m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
            m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
            m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
            m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w,
        ]
    }

    /// Decodes 16 floats back to a column-major 4×4 matrix.  Returns nil if the
    /// array is empty (v1–v3 files) or malformed, so callers can skip gracefully.
    private static func decodeMatrix(_ a: [Float]) -> matrix_float4x4? {
        guard a.count == 16 else { return nil }
        return matrix_float4x4(columns: (
            SIMD4<Float>(a[0],  a[1],  a[2],  a[3]),
            SIMD4<Float>(a[4],  a[5],  a[6],  a[7]),
            SIMD4<Float>(a[8],  a[9],  a[10], a[11]),
            SIMD4<Float>(a[12], a[13], a[14], a[15])
        ))
    }
}
