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
            frameRate:   tl.frameRate
        )

        // ── Objects — paths + keyframes ───────────────────────────────────────
        // Phase 6: each object carries its own sourceURL.
        // Deduplicate: save one path per unique model file so multi-part models
        // (32 SceneObjects all sharing the same sourceURL) are not loaded 32 times
        // when the project is reopened.
        var _seenPaths = Set<String>()
        let modelPaths: [String] = vp.sceneManager.objects.compactMap { obj -> String? in
            guard let path = obj.sourceURL?.path else { return nil }
            guard _seenPaths.insert(path).inserted else { return nil }
            return path
        }

        let objectsData: [ObjectData] = vp.sceneManager.objects.map { obj in
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
                normalMode:          obj.normalMode.rawValue,
                metallicFactor:      obj.material.metallicFactor,
                roughnessFactor:     obj.material.roughnessFactor,
                baseColorFactor:     [bcf.x, bcf.y, bcf.z, bcf.w],
                opacity:             obj.material.opacity
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
                followForwardLocal: kf.followForwardLocal.map { [$0.x, $0.y, $0.z] }
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
                excludeBeamFromFeedback: l.excludeBeamFromFeedback
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
            environmentHorizon:   bg.environmentHorizon
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
                easingMode:     track.easingMode.rawValue,
                keyframes:      kfData
            ))
        }

        return ProjectData(
            version:             30,   // v30: environment horizon (backdrop vertical shift)
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
                                           pz: vp.probeConfig.position.z)
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
            lifetime: fx.lifetime, growth: fx.growth, baseAlpha: fx.baseAlpha)
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
    private static func applyAtmosphereKeyframes(_ data: [AtmosphereKeyframeData]) -> AtmosphereKeyframeTrack? {
        guard !data.isEmpty else { return nil }
        let track = AtmosphereKeyframeTrack()
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
        fx.keyframeTrack = applyAtmosphereKeyframes(keyframes)
    }

    // MARK: - Apply ProjectData → live state

    private static func applyData(_ data: ProjectData, to vp: ViewportView,
                                   missingModelResolver: ((String) -> URL?)? = nil) {

        // ── Timeline ──────────────────────────────────────────────────────────
        vp.timeline.duration    = data.timeline.duration
        vp.timeline.frameRate   = data.timeline.frameRate   // v20: project frame rate
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
                    followForwardLocal: fwdLocal
                ))
            }
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
                return l
            }
            // Pad keyframe tracks array to match new light count
            while lm.keyframeTracks.count < lm.lights.count { lm.keyframeTracks.append(nil) }
            lm.selectedIndex = min(lm.selectedIndex, max(0, lm.lights.count - 1))
            print("[DEBUG] ProjectFile: restored \(lm.lights.count) light configs")
        }

        // Replace demo animations with saved keyframes; restore base transforms.
        applyKeyframes(data.objects, to: vp)

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
        applyLightKeyframes(data.lightKeyframeTracks, to: vp)

        // ── Group keyframe tracks (v14 / Phase 2) ─────────────────────────────
        applyGroupKeyframes(data.groupKeyframeTracks, to: vp,
                            substitutedFilenames: substitutedFilenames)

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
        vp.fogSettings.keyframeTrack = applyAtmosphereKeyframes(data.fogKeyframes)

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
            applyParticleEmitter(pd, keyframes: kfs, into: mgr.emitters[i])
        }
        mgr.selectedIndex = 0
        print("[DEBUG] ProjectFile: particle emitters=\(mgr.emitters.count)"
            + " fogKeyframes=\(data.fogKeyframes.count)")

        // Force the Renderer to re-evaluate keyframes on the next draw.
        // Without this, lastAnimatedTime == currentTime (both 0) so applyAnimation()
        // never fires and objects appear at their base transform instead of the t=0 pose.
        vp.renderer?.invalidateAnimationCache()
    }

    // MARK: - Apply keyframes + base transforms

    // Restores each object's baseTransform (v4) and keyframeTrack.
    // Matches objects by name.  Both are handled in one pass so baseTransform
    // is always set before the renderer evaluates the first animation delta.
    private static func applyKeyframes(_ objectsData: [ObjectData], to vp: ViewportView) {
        // Match saved object data to live scene objects by **position**, not by name.
        // The save format writes objects in scene order, and on load addModelToScene
        // appends in file order — so objectsData[i] corresponds to scene.objects[i]
        // by construction.  Position-based matching preserves keyframes through
        // missing-model substitution (user picks robot2.glb to replace robot1.glb)
        // and through replaceSelectedModel + save + reload, neither of which can
        // rely on name equality because the live names come from the new file.
        let objects = vp.sceneManager.objects
        let n = min(objects.count, objectsData.count)
        if objects.count != objectsData.count {
            print("[DEBUG] ProjectFile: object count mismatch on load —"
                + " saved=" + String(objectsData.count)
                + " loaded=" + String(objects.count)
                + " (extras get no keyframes)")
        }

        for i in 0..<n {
            let obj   = objects[i]
            let saved = objectsData[i]

            // ── v15: restore Model Inspector state ───────────────────────────────
            obj.isVisible = saved.isVisible
            obj.occludeWhenHidden = saved.occludeWhenHidden   // v17
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

            // ── v4: restore baseTransform so manual repositioning survives reload ──
            if let m = decodeMatrix(saved.baseTransformMatrix) {
                obj.baseTransform = m
                if obj.parentIndex != nil {
                    // Hierarchical part: m is a LOCAL transform.
                    // Set localTransform; applyHierarchy() will compute world transform.
                    obj.localTransform = m
                    obj.transform      = m   // temporary; overwritten by applyHierarchy next draw
                } else {
                    obj.transform = m   // root: m is the world transform
                }
                print("[DEBUG] ProjectFile: baseTransform restored for '" + obj.name
                    + "' (saved as '" + saved.name + "')")
            }

            // ── Keyframe track ────────────────────────────────────────────────────
            guard !saved.keyframes.isEmpty else {
                print("[DEBUG] ProjectFile: no keyframes for '" + obj.name + "'")
                continue
            }

            let track = KeyframeTrack()
            track.easingMode = EasingMode(rawValue: saved.easingMode) ?? .linear
            for kf in saved.keyframes {
                track.addKeyframe(TransformKeyframe(
                    time:        kf.time,
                    translation: SIMD3<Float>(kf.tx, kf.ty, kf.tz),
                    rotation:    simd_quatf(ix: kf.rx, iy: kf.ry, iz: kf.rz, r: kf.rw),
                    scale:       SIMD3<Float>(kf.sx, kf.sy, kf.sz),
                    opacity:     kf.opacity
                ))
            }
            obj.keyframeTrack = track

            print("[DEBUG] ProjectFile: restored " + String(saved.keyframes.count)
                + " keyframes for '" + obj.name + "'"
                + (obj.name == saved.name ? "" : " (saved as '" + saved.name + "')"))
        }
    }

    // MARK: - Apply light keyframe tracks (v6)

    private static func applyLightKeyframes(_ tracksData: [[LightKeyframeData]],
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

        // Build a map: sourceFileName → groupID from the currently loaded objects.
        var fileToGID: [String: Int] = [:]
        for obj in sm.objects {
            guard let gid = obj.groupID,
                  let fileName = obj.sourceURL?.lastPathComponent
            else { continue }
            fileToGID[fileName] = gid
        }
        // Alias substituted filenames: original saved name → gid of the file the
        // user picked as a replacement.  This is what preserves group-level
        // keyframes through the missing-model resolver flow.
        for (savedName, loadedName) in substitutedFilenames {
            if let gid = fileToGID[loadedName] {
                fileToGID[savedName] = gid
            }
        }

        for trackData in tracksData {
            guard !trackData.keyframes.isEmpty else { continue }
            guard let gid = fileToGID[trackData.sourceFileName] else {
                print("[DEBUG] ProjectFile: group track skipped — no loaded group"
                    + " matches '\(trackData.sourceFileName)'")
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

    // MARK: - Matrix helpers

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
