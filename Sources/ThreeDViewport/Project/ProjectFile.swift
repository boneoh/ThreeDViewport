import Foundation

// Phase 4 placeholder — in-memory representation of a saved project.
// A project is a single .json file that references .glb paths
// and stores camera/light/object animation data.
// No inline binary data is stored in the project file.
final class ProjectFile {

    var name: String
    var modelPaths: [URL]
    var isDirty: Bool

    init(name: String = "Untitled") {
        self.name       = name
        self.modelPaths = []
        self.isDirty    = false
        print("[DEBUG] ProjectFile: created '" + name + "'")
    }

    // Phase 4: load(from url:) and save(to url:) will delegate to ProjectJSON
    func load(from url: URL) {
        print("[DEBUG] ProjectFile: load not yet implemented (Phase 4)")
    }

    func save(to url: URL) {
        print("[DEBUG] ProjectFile: save not yet implemented (Phase 4)")
    }
}
