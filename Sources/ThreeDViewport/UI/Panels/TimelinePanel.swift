import SwiftUI
import AppKit

// Phase 2/3/5: Timeline transport bar rendered as a SwiftUI view embedded via NSHostingView.
// Binds to Timeline and ExportState ObservableObjects.
struct TimelinePanel: View {

    @ObservedObject var timeline:     Timeline
    @ObservedObject var exportState:  ExportState

    var onAddKeyframe:       () -> Void
    var onExport:            () -> Void
    /// Requests a duration change.  The host (AppDelegate) decides whether to
    /// rescale existing keyframes (via a prompt) and then applies the new value.
    var onSetDuration:       (Double) -> Void

    @State private var showDurationPopover: Bool   = false
    @State private var durationInput:       String = ""

    var body: some View {
        ZStack {
            Color(NSColor(calibratedWhite: 0.22, alpha: 1.0))

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

                // ── Loop toggle ───────────────────────────────────────────────
                transportButton(label: "↺", tooltip: "Loop playback",
                                isActive: timeline.isLooping) {
                    timeline.isLooping.toggle()
                }
                .disabled(exportState.isExporting)

                // ── Time display ──────────────────────────────────────────────
                Text(timeString(timeline.currentTime))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(white: 0.90))
                    .frame(width: 70, alignment: .leading)

                // ── Scrubber ──────────────────────────────────────────────────
                // Frame-snap manually in the setter rather than via Slider's
                // `step:`.  The step-quantizer left a dead zone narrower than
                // one frame just above 0, so dragging left would stick at
                // frame 1 instead of reaching the first frame.  Explicit
                // round + clamp-to-zero makes frame 0 reachable.
                Slider(
                    value: Binding(
                        get: { timeline.currentTime },
                        set: { v in
                            let fps = timeline.frameRate
                            let snapped = max(0, (v * fps).rounded() / fps)
                            timeline.seek(to: snapped)
                        }
                    ),
                    in: 0...max(timeline.duration, 0.001)
                )
                .accentColor(Color(NSColor.controlAccentColor))
                .disabled(exportState.isExporting)

                // ── Duration (tappable — opens edit popover) ──────────────────
                Button {
                    durationInput = String(format: "%.1f", timeline.duration)
                    showDurationPopover = true
                } label: {
                    Text(timeString(timeline.duration))
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundColor(Color(white: 0.65))
                        .frame(width: 70, alignment: .trailing)
                        .help("Click to set timeline duration")
                }
                .buttonStyle(.plain)
                .disabled(exportState.isExporting)
                .popover(isPresented: $showDurationPopover, arrowEdge: .top) {
                    durationPopover
                }

                Divider()
                    .frame(height: 20)
                    .background(Color(NSColor.separatorColor))

                // ── Add Object Keyframe ───────────────────────────────────────
                Button(action: onAddKeyframe) {
                    Label("Add Key", systemImage: "diamond.fill")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Add an object keyframe at the current playhead position")
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
                            .foregroundColor(.white)
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
        .environment(\.colorScheme, .dark)  // ensure all child controls resolve in dark mode
    }

    // MARK: - Duration popover

    private var durationPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Timeline Duration")
                .font(.headline)

            HStack(spacing: 6) {
                TextField("seconds", text: $durationInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .onSubmit { applyDuration() }
                Text("sec")
                    .foregroundColor(.secondary)
                    .font(.callout)
            }

            // Common presets
            HStack(spacing: 6) {
                ForEach([5, 10, 15, 30, 60, 120], id: \.self) { secs in
                    Button("\(secs)s") {
                        durationInput = String(secs)
                        applyDuration()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    showDurationPopover = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Set") {
                    applyDuration()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 320)
        // Paint an opaque backing so the (translucent) popover material doesn't
        // let a bright viewport object behind it wash out the controls.
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func applyDuration() {
        // Accept plain seconds ("30") or decimal ("12.5").
        // Clamp to a sensible range: 1 s – 3600 s (1 hour).
        // The host applies the value (and may prompt to rescale keyframes).
        if let secs = Double(durationInput.trimmingCharacters(in: .whitespaces)) {
            let clamped = max(1.0, min(3600.0, secs))
            onSetDuration(clamped)
        }
        showDurationPopover = false
    }

    // MARK: - Helpers

    @ViewBuilder
    private func transportButton(label: String, tooltip: String,
                                  isActive: Bool = false,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14))
                .frame(width: 28, height: 28)
                .foregroundColor(isActive
                    ? Color(NSColor.controlAccentColor)
                    : Color(white: 0.90))
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
