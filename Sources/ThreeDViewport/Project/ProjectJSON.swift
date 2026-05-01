import Foundation

// Phase 4 placeholder — Codable structs that serialise a ProjectFile to JSON.
// One .json file per project; no inline binary data.

struct ProjectJSON: Codable {
    var version: Int
    var modelPaths: [String]      // relative paths to .glb files
    var camera: CameraJSON?
    var lights: [LightJSON]

    init() {
        self.version    = 1
        self.modelPaths = []
        self.lights     = []
    }
}

struct CameraJSON: Codable {
    var yaw: Float
    var pitch: Float
    var distance: Float
    var targetX: Float
    var targetY: Float
    var targetZ: Float
}

struct LightJSON: Codable {
    var dirX: Float
    var dirY: Float
    var dirZ: Float
    var colorR: Float
    var colorG: Float
    var colorB: Float
    var intensity: Float
}

// Phase 4 will implement encode() and decode() here using JSONEncoder/JSONDecoder.
