import Combine
import simd

// Step 3: manages multiple simultaneous particle emitters (rain / snow / sleet /
// smoke).  Mirrors LightManager: an observable list with a selected index and
// add/remove, capped for performance.  Each ParticleEffect is a class that owns
// its own type, properties, and keyframe track, so (unlike LightManager's parallel
// track array) the tracks live inside the emitters.
final class ParticleManager: ObservableObject {

    static let maxEmitters = 8

    /// Active emitters.  Add/remove fire objectWillChange (array mutation); a
    /// per-emitter subscription handles each emitter's own property edits.
    @Published var emitters: [ParticleEffect] = [ParticleEffect()]

    /// Index of the emitter currently shown/edited in the Atmosphere panel.
    @Published var selectedIndex: Int = 0

    // MARK: - Selection

    var selected: ParticleEffect? {
        guard selectedIndex >= 0, selectedIndex < emitters.count else { return nil }
        return emitters[selectedIndex]
    }

    // MARK: - Add / remove

    @discardableResult
    func addEmitter() -> Int? {
        guard emitters.count < Self.maxEmitters else {
            print("[DEBUG] ParticleManager: addEmitter — max emitters reached")
            return nil
        }
        emitters.append(ParticleEffect())
        selectedIndex = emitters.count - 1
        print("[DEBUG] ParticleManager: added emitter total=" + String(emitters.count))
        return selectedIndex
    }

    func removeEmitter(at index: Int) {
        guard emitters.indices.contains(index), emitters.count > 1 else {
            print("[DEBUG] ParticleManager: removeEmitter — invalid index or last emitter")
            return
        }
        emitters.remove(at: index)
        if selectedIndex >= emitters.count { selectedIndex = emitters.count - 1 }
        print("[DEBUG] ParticleManager: removed emitter at index " + String(index))
    }
}
