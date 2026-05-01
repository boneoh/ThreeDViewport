import SwiftUI
import AppKit

// Phase 2: Timeline transport bar rendered as a SwiftUI view embedded via NSHostingView.
// Binds directly to the Timeline ObservableObject and calls back to ViewportView
// for the "Add Keyframe" action (which needs access to the scene).
struct TimelinePanel: View {

    @ObservedObject var timeline: Timeline

    // Callback invoked when the user taps "Add Keyframe".
    // Supplied by AppDelegate, routes to ViewportView.addKeyframeAtCurrentTime().
    var onAddKeyframe: () -> Void

    var body: some View {
        ZStack {
            // Panel background
            Color(NSColor(calibratedWhite: 0.12, alpha: 1.0))

            HStack(spacing: 12) {

                // ── Transport buttons ─────────────────────────────────────────
                transportButton(label: "⏹", tooltip: "Stop") {
                    timeline.stop()
                }

                transportButton(label: timeline.isPlaying ? "⏸" : "▶", tooltip: timeline.isPlaying ? "Pause" : "Play") {
                    timeline.togglePlayPause()
                }

                // ── Time display ─────────────────────────────────────────────
                Text(timeString(timeline.currentTime))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(NSColor.labelColor))
                    .frame(width: 70, alignment: .leading)

                // ── Scrubber ──────────────────────────────────────────────────
                Slider(
                    value: Binding(
                        get: { timeline.currentTime },
                        set: { newValue in
                            timeline.seek(to: newValue)
                        }
                    ),
                    in: 0...max(timeline.duration, 0.001),
                    step: 1.0 / timeline.frameRate
                )
                .accentColor(Color(NSColor.controlAccentColor))

                // ── Duration display ─────────────────────────────────────────
                Text(timeString(timeline.duration))
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                    .frame(width: 70, alignment: .trailing)

                Divider()
                    .frame(height: 20)
                    .background(Color(NSColor.separatorColor))

                // ── Add Keyframe ──────────────────────────────────────────────
                Button(action: onAddKeyframe) {
                    Label("Add Key", systemImage: "diamond.fill")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Add a keyframe at the current playhead position (K)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func transportButton(label: String, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.borderless)
        .help(tooltip)
    }

    // Converts a time in seconds to MM:SS:FF (frames at 30 fps).
    // Uses String(format:) — no Swift string interpolation.
    private func timeString(_ t: Double) -> String {
        let totalFrames = Int(max(0, t) * timeline.frameRate)
        let frames      = totalFrames % Int(timeline.frameRate)
        let totalSecs   = totalFrames / Int(timeline.frameRate)
        let secs        = totalSecs % 60
        let mins        = totalSecs / 60
        return String(format: "%02d:%02d:%02d", mins, secs, frames)
    }
}
