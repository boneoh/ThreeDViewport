import SwiftUI
import AppKit
import Combine

// Thin ObservableObject that polls FeedbackProcessor.isFull once per second
// so the SwiftUI panel can show priming / active status without making
// FeedbackProcessor itself an ObservableObject (it's GPU-bound, not UI-bound).
final class FeedbackStatus: ObservableObject {
    @Published var isFull: Bool = false
    private weak var processor: FeedbackProcessor?
    private var timer: Timer?

    init(processor: FeedbackProcessor) {
        self.processor = processor
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self, let p = self.processor else { return }
            if self.isFull != p.isFull { self.isFull = p.isFull }
        }
    }
    deinit { timer?.invalidate() }
}

// Host view that owns the FeedbackStatus observer and passes isFull down.
struct FeedbackPanelWrapper: View {
    @ObservedObject var settings:  FeedbackSettings
    @StateObject    var status:    FeedbackStatus
    private let processor: FeedbackProcessor

    init(settings: FeedbackSettings, processor: FeedbackProcessor) {
        self.settings  = settings
        self.processor = processor
        _status = StateObject(wrappedValue: FeedbackStatus(processor: processor))
    }

    var body: some View {
        FeedbackPanel(
            settings: settings,
            onClear:  { processor.reset() },
            isFull:   status.isFull
        )
    }
}

// Floating inspector panel for the video feedback delay-line system.
// Controls: enable toggle, interval, decay, length sliders, and a Clear Queue button.
struct FeedbackPanel: View {

    @ObservedObject var settings: FeedbackSettings

    /// Called when the user taps "Clear Queue" — resets the ring buffer.
    var onClear: () -> Void

    /// Live status fed from FeedbackProcessor.isFull; shown below the sliders.
    var isFull: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // ── Header ────────────────────────────────────────────────────
                HStack {
                    Image(systemName: settings.isEnabled ? "waveform.path.ecg" : "waveform")
                        .foregroundColor(settings.isEnabled ? .accentColor : .secondary)
                    Text("Feedback")
                        .font(.headline)
                    Spacer()
                    Toggle("", isOn: $settings.isEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                .padding(.bottom, 10)

                Divider().padding(.bottom, 10)

                if settings.isEnabled {
                    // ── Parameters ────────────────────────────────────────────
                    VStack(alignment: .leading, spacing: 10) {

                        IntSliderRow(
                            label:  "Interval",
                            value:  $settings.interval,
                            range:  1...60,
                            suffix: "fr"
                        )

                        FloatSliderRow(
                            label:  "Decay",
                            value:  $settings.decay,
                            range:  0.0...1.0,
                            format: "%.2f"
                        )

                        IntSliderRow(
                            label:  "Length",
                            value:  $settings.length,
                            range:  1...60,
                            suffix: "fr"
                        )
                    }

                    Divider().padding(.vertical, 10)

                    // ── Status + clear ────────────────────────────────────────
                    HStack {
                        Circle()
                            .fill(isFull ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(isFull ? "Active" : "Priming…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Clear Queue") {
                            onClear()
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)
                        .controlSize(.small)
                    }

                    // Priming progress hint
                    if !isFull {
                        Text("Waiting for \(settings.length) intervals × \(settings.interval) frames")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                    }

                } else {
                    Text("Enable feedback to configure.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(14)
        }
        .frame(width: 280)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Reusable sub-views

/// Integer value slider with a fixed-width label and numeric readout.
private struct IntSliderRow: View {
    let label:  String
    @Binding var value: Int
    let range:  ClosedRange<Int>
    let suffix: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .frame(width: 52, alignment: .leading)
                .foregroundColor(.secondary)
                .font(.caption)
            Slider(
                value: Binding<Double>(
                    get: { Double(value) },
                    set: { value = Int($0.rounded()) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 1.0
            )
            Text("\(value) \(suffix)")
                .frame(width: 46, alignment: .trailing)
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
        }
    }
}

/// Float value slider with a fixed-width label and numeric readout.
private struct FloatSliderRow: View {
    let label:  String
    @Binding var value: Float
    let range:  ClosedRange<Float>
    let format: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .frame(width: 52, alignment: .leading)
                .foregroundColor(.secondary)
                .font(.caption)
            Slider(
                value: Binding<Double>(
                    get: { Double(value) },
                    set: { value = Float($0) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound)
            )
            Text(String(format: format, value))
                .frame(width: 46, alignment: .trailing)
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
        }
    }
}
