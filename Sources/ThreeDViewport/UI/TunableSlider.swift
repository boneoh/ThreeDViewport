import SwiftUI

extension Color {
    /// Light blue used for enabled/active controls — the copy/paste icons and
    /// every slider's filled track/thumb.  Greys automatically when `.disabled`.
    static let editableBlue = Color(red: 0.42, green: 0.71, blue: 1.0)
}

/// Shared slider used by every panel's slider row.
///
/// Custom-drawn (track + fill + thumb) rather than a native `Slider` for two
/// reasons the native control can't satisfy here:
///   • The fill colour is driven by `@Environment(\.isEnabled)`, so it stays
///     light blue when enabled / grey when disabled *regardless of window focus*.
///     (A native `Slider`'s `.tint` only shows colour while its window is key,
///     and these inspectors are non-activating floating panels.)
///   • Left/Right arrow keys nudge the value by `step` for fine adjustment,
///     using our own increment instead of the native control's coarse one.
struct TunableSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step:  Double

    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Bool
    @State private var repeatTimer: Timer?

    private let trackHeight: CGFloat = 4
    private let thumbSize:   CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let usable  = max(geo.size.width - thumbSize, 1)
            let span    = range.upperBound - range.lowerBound
            let frac    = span > 0 ? (value - range.lowerBound) / span : 0
            let clamped = CGFloat(min(1, max(0, frac)))
            let thumbX  = usable * clamped
            let fill    = isEnabled ? Color.editableBlue : Color.gray.opacity(0.5)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.gray.opacity(0.25))
                    .frame(height: trackHeight)
                Capsule()
                    .fill(fill)
                    .frame(width: thumbX + thumbSize / 2, height: trackHeight)
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.gray.opacity(0.4), lineWidth: 0.5))
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(radius: focused ? 2.5 : 1)
                    .offset(x: thumbX)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard isEnabled else { return }
                        focused = true
                        let f = min(1, max(0, (g.location.x - thumbSize / 2) / usable))
                        value = range.lowerBound + Double(f) * span
                    }
            )
        }
        .frame(height: thumbSize)
        .focusable(isEnabled)
        .focused($focused)
        // SwiftUI's `.repeat` phase doesn't fire for held keys in this
        // NSPanel/NSHostingView setup, so drive the repeat ourselves: nudge once
        // on key-down, then run a timer until the key is released (`.up`), focus
        // is lost, or the view disappears.
        .onKeyPress(keys: [.leftArrow, .rightArrow], phases: [.down, .up]) { press in
            guard isEnabled else { return .ignored }
            let delta = press.key == .leftArrow ? -step : step
            switch press.phase {
            case .down: nudge(delta); startRepeating(delta); return .handled
            case .up:   stopRepeating();                     return .handled
            default:    return .ignored
            }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { stopRepeating() }
        }
        .onDisappear { stopRepeating() }
    }

    /// Holds the arrow key: a short initial delay (so a tap stays a single step),
    /// then steady repeats by `step` until the key is released.
    private func startRepeating(_ delta: Double) {
        stopRepeating()
        let delay = Timer(timeInterval: 0.3, repeats: false) { _ in
            let ticker = Timer(timeInterval: 0.04, repeats: true) { _ in nudge(delta) }
            RunLoop.main.add(ticker, forMode: .common)
            repeatTimer = ticker
        }
        RunLoop.main.add(delay, forMode: .common)
        repeatTimer = delay
    }

    private func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    @discardableResult
    private func nudge(_ delta: Double) -> KeyPress.Result {
        guard isEnabled else { return .ignored }
        value = min(range.upperBound, max(range.lowerBound, value + delta))
        return .handled
    }
}

/// Smallest increment implied by a "%.Nf" format ("%.2f" → 0.01, "%.0f" → 1),
/// used as the arrow-key step so one press nudges the last displayed digit.
func arrowStep(forFormat format: String) -> Double {
    guard let dot  = format.firstIndex(of: "."),
          let fIdx = format[dot...].firstIndex(of: "f") else { return 0.01 }
    let digits = format[format.index(after: dot)..<fIdx]
    return pow(10.0, Double(-(Int(digits) ?? 2)))
}
