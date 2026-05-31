import Foundation
import Combine

// Drives playback time for the animation system.
// ObservableObject so SwiftUI panels can bind directly to currentTime and isPlaying.
// tick() is called once per render frame (main thread, via MTKView display link).
final class Timeline: ObservableObject {

    /// Precise playhead the *renderer* reads every frame.  During playback this
    /// advances each tick; `currentTime` below is only a throttled UI mirror so
    /// SwiftUI panels (transport bar, inspectors) don't re-render every single
    /// frame and starve the MTKView's display-link callback.  `private(set)` so
    /// only the timeline (tick / seek sync) writes it.
    private(set) var renderTime: Double = 0.0

    /// UI-facing playhead bound by SwiftUI.  Mirrors `renderTime`, but throttled
    /// to ~`uiUpdateInterval` during playback.  When the user scrubs/seeks or
    /// playback is paused it stays exactly in sync with `renderTime`.
    @Published var currentTime: Double = 0.0 {
        didSet {
            // A change from the UI/seek (not our own throttled mirror) snaps the
            // render clock to it so scrubbing is immediate.
            if !mirroringToUI { renderTime = currentTime }
        }
    }

    /// How often `currentTime` is refreshed for the UI during playback (~15 Hz).
    private let uiUpdateInterval: Double = 1.0 / 15.0
    private var lastUIMirror: Double = 0.0
    private var mirroringToUI = false

    @Published var isPlaying: Bool = false
    @Published var duration: Double = 10.0
    @Published var isLooping: Bool = false
    /// Increments each time the timeline wraps around in loop mode.
    /// ViewportView subscribes to this to clear the feedback buffer on each loop.
    @Published var loopRevolution: Int = 0

    /// Project frame rate — drives playback advance, F/B nudge, frame snapping,
    /// the keyframe replace tolerance, and export.  Settable via the Export panel's
    /// FPS dropdown and persisted with the project (default 30).
    @Published var frameRate: Double = 30.0

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
    // Advances renderTime by the real wall-clock time `dt` (seconds) elapsed since
    // the previous frame, so playback runs at real-time speed regardless of the
    // draw rate (e.g. a 100 Hz display drawing at 50 fps still plays 1× speed).
    // `dt` is clamped by the caller to avoid a large jump after a hitch.
    // Returns true when time actually advanced (caller re-evaluates keyframes).
    // NOTE: export does NOT use this — it steps its own deterministic frame clock.
    @discardableResult
    func tick(dt: Double) -> Bool {
        guard isPlaying else { return false }

        renderTime += dt

        var landUI = false   // force a UI mirror this tick (end / loop wrap)
        if renderTime >= duration {
            if isLooping {
                renderTime = 0.0
                loopRevolution += 1
                landUI = true
                print("[DEBUG] Timeline: looped back to t=0 (revolution=\(loopRevolution))")
            } else {
                renderTime = duration
                isPlaying = false
                landUI = true
                print("[DEBUG] Timeline: reached end at t=" + String(format: "%.3f", renderTime))
            }
        }

        // Throttle the UI mirror so SwiftUI panels re-render ~15×/s, not every
        // frame.  Always mirror on the end/loop frame so the scrubber lands exactly.
        if landUI || abs(renderTime - lastUIMirror) >= uiUpdateInterval {
            lastUIMirror = renderTime
            mirroringToUI = true          // suppress didSet → renderTime feedback
            currentTime = renderTime
            mirroringToUI = false
        }

        return true
    }
}
