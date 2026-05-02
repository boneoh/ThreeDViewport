import SwiftUI
import AppKit

// Phase 2/3: Timeline transport bar rendered as a SwiftUI view embedded via NSHostingView.
// Binds to Timeline and ExportState ObservableObjects.
struct TimelinePanel: View {

    @ObservedObject var timeline:     Timeline
    @ObservedObject var exportState:  ExportState

    var onAddKeyframe: () -> Void
    var onExport:      () -> Void

    var body: some View {
        ZStack {
            Color(NSColor(calibratedWhite: 0.12, alpha: 1.0))

            HStack(spacing: 12) {

                // ── Transport buttons ─────────────────────────────────────────
                transportButton(label: "⏹", tooltip: "Stop") {
                    timeline.stop()
                }
                .disabled(exportState.isExporting)

                transportButton(
                    label:   timeline.isPlaying ? "⏸" : "▶",
                    tooltip: timeline.isPlaying ? "Pause" : "Play"
                ) {
                    timeline.togglePlayPause()
                }
                .disabled(exportState.isExporting)

                // ── Time display ──────────────────────────────────────────────
                Text(timeString(timeline.currentTime))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(NSColor.labelColor))
                    .frame(width: 70, alignment: .leading)

                // ── Scrubber ──────────────────────────────────────────────────
                Slider(
                    value: Binding(
                        get: { timeline.currentTime },
                        set: { timeline.seek(to: $0) }
                    ),
                    in: 0...max(timeline.duration, 0.001),
                    step: 1.0 / timeline.frameRate
                )
                .accentColor(Color(NSColor.controlAccentColor))
                .disabled(exportState.isExporting)

                // ── Duration display ──────────────────────────────────────────
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
                .help("Add a keyframe at the current playhead position")
                .disabled(exportState.isExporting)

                Divider()
                    .frame(height: 20)
                    .background(Color(NSColor.separatorColor))

                // ── Export button / progress ──────────────────────────────────
                if exportState.isExporting {
                    HStack(spacing: 6) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                        Text(String(format: "Exporting %.0f%%", exportState.progress * 100))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(Color(NSColor.secondaryLabelColor))
                            .frame(width: 100, alignment: .leading)
                    }
                } else {
                    Button(action: onExport) {
                        Label("Export .mov", systemImage: "film.fill")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Export animation to ProRes 4444 .mov at 1920×1080")

                    // Show last export result message if any
                    if !exportState.lastMessage.isEmpty {
                        Text(exportState.lastMessage)
                            .font(.system(size: 10))
                            .foregroundColor(
                                exportState.lastMessage.hasPrefix("Export failed")
                                    ? Color(NSColor.systemRed)
                                    : Color(NSColor.systemGreen)
                            )
                            .lineLimit(1)
                            .frame(maxWidth: 150, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func transportButton(label: String, tooltip: String,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.borderless)
        .help(tooltip)
    }

    // Converts seconds to MM:SS:FF (frames at timeline.frameRate).
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
