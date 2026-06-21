import Foundation

/// Lightweight runtime-gated diagnostic logging.
///
/// `enabled` mirrors `AppSettings.loggingEnabled` (applied on launch and whenever the
/// Settings toggle changes — see `AppSettings.applyLoggingFlags()`), so the per-call
/// cost is a single bool check.  Flip it on from Settings to chase a bug without
/// relaunching.  Per-frame perf logging is SEPARATE (the `--perf-log` launch flag), so
/// turning diagnostics on for errors/warnings/[LIMIT] no longer floods the console.
enum AppLog {
    /// Fast mirror of the persisted setting.  Default off.
    static var enabled = false

    /// Print `message` only when logging is enabled.  The message is an autoclosure so
    /// string interpolation is skipped entirely when logging is off.
    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        print(message())
    }
}
