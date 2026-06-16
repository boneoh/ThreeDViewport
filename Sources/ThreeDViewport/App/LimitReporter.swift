import Foundation
import AppKit

/// Surfaces a movement/limit clamp instead of failing silently: a throttled beep
/// (so holding a key against a limit doesn't machine-gun) plus an `AppLog` line that
/// names what was limited.  Call only when a clamp ACTUALLY reduced the requested
/// move — not on every frame an entity merely rests at a bound.
enum LimitReporter {

    private static var lastBeep: TimeInterval = 0
    private static let beepInterval: TimeInterval = 0.6

    /// `what` should read as the thing that hit its limit, e.g. "Object position",
    /// "Depth dolly (near)", "Lens FOV".
    static func report(_ what: String) {
        AppLog.log("[LIMIT] \(what) hit its limit")
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastBeep > beepInterval {
            NSSound.beep()
            lastBeep = now
        }
    }
}
