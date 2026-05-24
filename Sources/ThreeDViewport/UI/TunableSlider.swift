import SwiftUI

extension Color {
    /// Light blue used for enabled/active controls — the copy/paste icons and
    /// every slider's filled track/thumb.  Greys automatically when `.disabled`.
    static let editableBlue = Color(red: 0.42, green: 0.71, blue: 1.0)
}

/// Shared slider used by every panel's slider row.  Tints light blue when enabled
/// (greys when disabled, so on/off state is obvious), and — once focused (Tab to
/// it) — Left/Right arrow keys nudge the value by `step` for fine adjustment.
struct TunableSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step:  Double

    var body: some View {
        Slider(value: $value, in: range)
            .tint(.editableBlue)
            .focusable()
            .onKeyPress(.leftArrow)  { nudge(-step) }
            .onKeyPress(.rightArrow) { nudge(step) }
    }

    private func nudge(_ delta: Double) -> KeyPress.Result {
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
