import Foundation

// Owns the live scene graph.
// Phase 1: single object only.
// Phase 3: will hold multiple objects with per-object selection state.
final class SceneManager {

    var objects: [SceneObject] = [] {
        didSet {
            if objects.isEmpty {
                print("[DEBUG] SceneManager: objects array is now empty")
            } else {
                print("[DEBUG] SceneManager: objects count = " + String(objects.count))
            }
        }
    }

    init() {
        print("[DEBUG] SceneManager: initialized, objects count = 0")
    }

    func clear() {
        print("[DEBUG] SceneManager: clearing " + String(objects.count) + " object(s)")
        objects.removeAll()
    }

    // Returns the first visible object, or nil
    var primaryObject: SceneObject? {
        let obj = objects.first(where: { $0.isVisible })
        if obj == nil {
            print("[DEBUG] SceneManager: primaryObject is nil (no visible objects)")
        }
        return obj
    }
}
