import Foundation
import Combine

// Drives playback time for the animation system.
// ObservableObject so SwiftUI panels can bind directly to currentTime and isPlaying.
// tick() is called once per render frame (main thread, via MTKView display link).
final class Timeline: ObservableObject {

    @Published var currentTime: Double = 0.0
    @Published var isPlaying: Bool = false
    @Published var duration: Double = 10.0
    @Published var isLooping: Bool = false

    let frameRate: Double = 30.0

    init() {
        print("[DEBUG] Timeline: initialized, duration=" + String(duration) + "s frameRate=30")
    }

    // MARK: - Transport

    func play() {
        guard !isPlaying else { return }
        if currentTime >= duration {
            currentTime = 0.0
            print("[DEBUG] Timeline: rewound to 0 before play")
        }
        isPlaying = true
        print("[DEBUG] Timeline: playing from t=" + String(format: "%.3f", currentTime))
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        print("[DEBUG] Timeline: paused at t=" + String(format: "%.3f", currentTime))
    }

    func stop() {
        isPlaying = false
        currentTime = 0.0
        print("[DEBUG] Timeline: stopped")
    }

    func seek(to time: Double) {
        currentTime = max(0, min(duration, time))
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    // MARK: - Frame tick

    // Called once per rendered frame from Renderer.draw(in:).
    // Advances currentTime by one frame interval; stops at duration.
    // Returns true when time actually advanced (caller should re-evaluate keyframes).
    @discardableResult
    func tick() -> Bool {
        guard isPlaying else { return false }

        let dt = 1.0 / frameRate
        currentTime += dt

        if currentTime >= duration {
            if isLooping {
                currentTime = 0.0
                print("[DEBUG] Timeline: looped back to t=0")
            } else {
                currentTime = duration
                isPlaying = false
                print("[DEBUG] Timeline: reached end at t=" + String(format: "%.3f", currentTime))
            }
        }

        return true
    }
}
