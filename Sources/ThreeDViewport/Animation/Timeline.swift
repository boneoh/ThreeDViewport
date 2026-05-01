import Foundation

// Phase 2 placeholder — drives playback time and notifies subscribers each tick.
final class Timeline {

    var duration: Double = 10.0     // seconds
    var currentTime: Double = 0.0
    var isPlaying: Bool = false
    var frameRate: Double = 30.0

    init() {
        print("[DEBUG] Timeline: initialized, duration=" + String(duration) + "s")
    }

    func play() {
        isPlaying = true
        print("[DEBUG] Timeline: play")
    }

    func pause() {
        isPlaying = false
        print("[DEBUG] Timeline: pause at t=" + String(currentTime))
    }

    func seek(to time: Double) {
        currentTime = max(0, min(duration, time))
        print("[DEBUG] Timeline: seek to t=" + String(currentTime))
    }
}
