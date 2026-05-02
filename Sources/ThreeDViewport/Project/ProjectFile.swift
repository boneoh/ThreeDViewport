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
    static func save(to url: URL, viewport: ViewportView) throws {
        let data    = captureData(from: viewport)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let json: Data
        do {
            json = try encoder.encode(data)
        } catch {
            throw ProjectFileError.encodingFailed(error.localizedDescription)
        }

        try json.write(to: url, options: .atomic)

        print("[DEBUG] ProjectFile: saved "
            + String(json.count) + " bytes → " + url.lastPathComponent
            + "  models=" + String(data.modelPaths.count)
            + "  objects=" + String(data.objects.count)
            + "  keyframes=" + String(data.objects.reduce(0) { $0 + $1.keyframes.count })
            + "  camKeyframes=" + String(data.cameraKeyframes.count))
    }

    // MARK: - Load

    /// Reads a .3dvp file at `url`, restores timeline, loads all models, restores
    /// keyframe tracks and camera state.  Camera is applied AFTER model loading so
    /// it overrides any fitToScene calls made during load.
    static func load(from url: URL, into viewport: ViewportView) throws {
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
    }

    // MARK: - Capture live state → ProjectData

    private static func captureData(from vp: ViewportView) -> ProjectData {
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
        let modelPaths: [String] = vp.sceneManager.objects.compactMap { $0.sourceURL?.path }

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
            return ObjectData(name: obj.name, keyframes: kfData)
        }

        // ── Camera keyframes (Phase 5) ────────────────────────────────────────
        let cameraKfData: [CameraKeyframeData] = (cam.keyframeTrack?.keyframes ?? []).map { kf in
            CameraKeyframeData(
                time:     kf.time,
                yaw:      kf.yaw,
                pitch:    kf.pitch,
                distance: kf.distance,
                targetX:  kf.target.x,
                targetY:  kf.target.y,
                targetZ:  kf.target.z
            )
        }

        return ProjectData(
            version:         3,
            modelPath:       nil,           // v3 uses modelPaths instead
            modelPaths:      modelPaths,
            timeline:        timelineData,
            camera:          cameraData,
            objects:         objectsData,
            cameraKeyframes: cameraKfData
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
            for kf in data.cameraKeyframes {
                camTrack.addKeyframe(CameraKeyframe(
                    time:     kf.time,
                    yaw:      kf.yaw,
                    pitch:    kf.pitch,
                    distance: kf.distance,
                    target:   SIMD3<Float>(kf.targetX, kf.targetY, kf.targetZ)
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

        // Replace demo animations with saved keyframes.
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

        // Sync HUD with restored scene.
        vp.syncOverlayState()
    }

    // MARK: - Apply keyframes

    // Replaces each object's keyframeTrack with the saved keyframes.
    // Matches objects by name; logs a warning for any unmatched names.
    private static func applyKeyframes(_ objectsData: [ObjectData], to vp: ViewportView) {
        for obj in vp.sceneManager.objects {
            guard let saved = objectsData.first(where: { $0.name == obj.name }) else {
                print("[DEBUG] ProjectFile: no saved keyframes for object '" + obj.name + "'")
                continue
            }
            guard !saved.keyframes.isEmpty else {
                print("[DEBUG] ProjectFile: saved keyframe array empty for '" + obj.name + "'")
                continue
            }

            let track = KeyframeTrack()
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
}
