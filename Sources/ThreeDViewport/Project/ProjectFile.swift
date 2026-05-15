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
    static func load(from url: URL, into viewport: ViewportView) throws -> ProjectData {
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

        applyData(data, to: viewport)
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
            targetZ:  cam.target.z
        )

        // ── Timeline ──────────────────────────────────────────────────────────
        let timelineData = TimelineData(
            duration:    tl.duration,
            currentTime: tl.currentTime
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
                    sx: kf.scale.x, sy: kf.scale.y, sz: kf.scale.z
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
            return ObjectData(name: obj.name,
                              keyframes: kfData,
                              baseTransformMatrix: encodeMatrix(matrixToSave),
                              easingMode: (obj.keyframeTrack?.easingMode ?? .linear).rawValue)
        }

        // ── Camera keyframes (Phase 5) ────────────────────────────────────────
        let cameraKfData: [CameraKeyframeData] = (cam.keyframeTrack?.keyframes ?? []).map { kf in
            CameraKeyframeData(
                time:            kf.time,
                yaw:             kf.yaw,
                pitch:           kf.pitch,
                distance:        kf.distance,
                targetX:         kf.target.x,
                targetY:         kf.target.y,
                targetZ:         kf.target.z,
                followTarget:    kf.followTargetName,
                followYawOffset: kf.followYawOffset,
                targetOffset:    [kf.targetOffset.x, kf.targetOffset.y, kf.targetOffset.z]
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
                    dx: kf.direction.x, dy: kf.direction.y, dz: kf.direction.z,
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
                dirX:                    l.direction.x,
                dirY:                    l.direction.y,
                dirZ:                    l.direction.z,
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
            gradBottomB: bg.gradientBottom.z
        )

        // ── Color grade (v12) ─────────────────────────────────────────────────
        let cg = vp.colorGradeSettings
        let colorGradeData = ColorGradeData(
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
                    sx: kf.scale.x, sy: kf.scale.y, sz: kf.scale.z
                )
            }
            groupTrackData.append(GroupTrackData(
                sourceFileName: fileName,
                easingMode:     track.easingMode.rawValue,
                keyframes:      kfData
            ))
        }

        return ProjectData(
            version:             14,
            modelPath:           nil,           // v3+ uses modelPaths instead
            modelPaths:          modelPaths,
            timeline:            timelineData,
            camera:              cameraData,
            objects:             objectsData,
            cameraKeyframes:     cameraKfData,
            isColorMode:         vp.renderSettings.isColorMode,
            feedback:            feedbackData,
            lightKeyframeTracks: lightKfData,
            isLooping:           vp.timeline.isLooping,
            background:          backgroundData,
            isWireframe:         vp.renderer?.isWireframe ?? false,
            showAxesGizmo:       vp.renderSettings.showAxesGizmo,
            lightConfigs:        lightConfigsData,
            windowLayout:        windowLayout,
            colorGrade:          colorGradeData,
            groupKeyframeTracks: groupTrackData
        )
    }

    // MARK: - Apply ProjectData → live state

    private static func applyData(_ data: ProjectData, to vp: ViewportView) {

        // ── Timeline ──────────────────────────────────────────────────────────
        vp.timeline.duration    = data.timeline.duration
        vp.timeline.currentTime = 0.0   // always start from the beginning on load
        vp.timeline.isPlaying   = false
        print("[DEBUG] ProjectFile: timeline duration=" + String(format: "%.2f", data.timeline.duration))

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
                camTrack.addKeyframe(CameraKeyframe(
                    time:             kfData.time,
                    yaw:              kfData.yaw,
                    pitch:            kfData.pitch,
                    distance:         kfData.distance,
                    target:           SIMD3<Float>(kfData.targetX, kfData.targetY, kfData.targetZ),
                    followTargetName: kfData.followTarget,
                    followYawOffset:  kfData.followYawOffset,
                    targetOffset:     targetOff
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

        var loadedCount = 0
        for pathStr in paths {
            if FileManager.default.fileExists(atPath: pathStr) {
                vp.addModelToScene(url: URL(fileURLWithPath: pathStr))
                loadedCount += 1
            } else {
                print("[DEBUG] ProjectFile: model file not found at " + pathStr)
            }
        }

        if loadedCount == 0 && paths.isEmpty {
            print("[DEBUG] ProjectFile: no model paths stored in project")
        }

        // ── Color mode ────────────────────────────────────────────────────────
        vp.renderSettings.isColorMode = data.isColorMode
        print("[DEBUG] ProjectFile: colorMode=" + (data.isColorMode ? "color" : "greyscale"))

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
                l.direction               = SIMD3<Float>(lcd.dirX, lcd.dirY, lcd.dirZ)
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
        vp.camera.yaw      = c.yaw
        vp.camera.pitch    = c.pitch
        vp.camera.distance = c.distance
        vp.camera.target   = SIMD3<Float>(c.targetX, c.targetY, c.targetZ)
        print("[DEBUG] ProjectFile: camera restored — yaw=" + String(format: "%.3f", c.yaw)
            + " pitch=" + String(format: "%.3f", c.pitch)
            + " dist="  + String(format: "%.3f", c.distance))

        // ── Light keyframe tracks (v6) ────────────────────────────────────────
        applyLightKeyframes(data.lightKeyframeTracks, to: vp)

        // ── Group keyframe tracks (v14 / Phase 2) ─────────────────────────────
        applyGroupKeyframes(data.groupKeyframeTracks, to: vp)

        // Sync HUD with restored scene.
        vp.syncOverlayState()

        // ── Color grade (v12) ─────────────────────────────────────────────────
        vp.colorGradeSettings.brightness = data.colorGrade.brightness
        vp.colorGradeSettings.contrast   = data.colorGrade.contrast
        vp.colorGradeSettings.gamma      = data.colorGrade.gamma
        print("[DEBUG] ProjectFile: colorGrade brightness=\(data.colorGrade.brightness)"
            + " contrast=\(data.colorGrade.contrast)"
            + " gamma=\(data.colorGrade.gamma)")

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
        for obj in vp.sceneManager.objects {
            guard let saved = objectsData.first(where: { $0.name == obj.name }) else {
                print("[DEBUG] ProjectFile: no saved data for object '" + obj.name + "'")
                continue
            }

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
                print("[DEBUG] ProjectFile: baseTransform restored for '" + obj.name + "'")
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
                    scale:       SIMD3<Float>(kf.sx, kf.sy, kf.sz)
                ))
            }
            obj.keyframeTrack = track

            print("[DEBUG] ProjectFile: restored " + String(saved.keyframes.count)
                + " keyframes for '" + obj.name + "'")
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
                    direction:     simd_normalize(SIMD3<Float>(kf.dx, kf.dy, kf.dz)),
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
    private static func applyGroupKeyframes(_ tracksData: [GroupTrackData],
                                             to vp: ViewportView) {
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
                    scale:       SIMD3<Float>(kf.sx, kf.sy, kf.sz)
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
