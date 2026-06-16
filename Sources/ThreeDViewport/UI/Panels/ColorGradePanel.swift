import SwiftUI

// Floating inspector panel for the brightness / contrast post-process pass.
struct ColorGradePanel: View {

    @ObservedObject var settings: ColorGradeSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // ── Header ────────────────────────────────────────────────────
                HStack {
                    Image(systemName: "circle.lefthalf.filled")
                        .foregroundColor(.accentColor)
                    Text("Color Grade")
                        .font(.headline)
                    Spacer()
                    if !settings.isIdentity || settings.exposure != 1.0 {
                        Button("Reset") { settings.reset() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .disabled(settings.isLocked)
                    }
                    PanelLockButton(isLocked: $settings.isLocked)
                }
                .padding(.bottom, 10)

                Divider().padding(.bottom, 14)

                // ── Exposure ──────────────────────────────────────────────────
                // Applied pre-tone-map in the main scene shader (not the
                // post-process pass), so it can tame HDR/IBL highlights.
                GradeSliderRow(
                    label:  "Exposure",
                    value:  $settings.exposure,
                    range:  SceneLimits.gradeExposureRange,
                    format: "%.2f"
                )
                .disabled(settings.isLocked)

                Divider().padding(.vertical, 10)

                // ── Brightness ────────────────────────────────────────────────
                GradeSliderRow(
                    label:  "Brightness",
                    value:  $settings.brightness,
                    range:  SceneLimits.gradeBrightnessRange,
                    format: "%+.2f"
                )
                .disabled(settings.isLocked)

                Divider().padding(.vertical, 10)

                // ── Contrast ──────────────────────────────────────────────────
                GradeSliderRow(
                    label:  "Contrast",
                    value:  $settings.contrast,
                    range:  SceneLimits.gradeContrastRange,
                    format: "%.2f"
                )
                .disabled(settings.isLocked)

                Divider().padding(.vertical, 10)

                // ── Gamma ─────────────────────────────────────────────────────
                GradeSliderRow(
                    label:  "Gamma",
                    value:  $settings.gamma,
                    range:  SceneLimits.gradeGammaRange,
                    format: "%.2f"
                )
                .disabled(settings.isLocked)

                Divider().padding(.vertical, 10)

                // ── Status hint ───────────────────────────────────────────────
                Text(settings.isIdentity
                     ? "No adjustment active."
                     : "Applied to final frame and export.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(14)
        }
        .frame(width: 280)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Slider row

private struct GradeSliderRow: View {
    let label:  String
    @Binding var value: Float
    let range:  ClosedRange<Float>
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: format, value))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.primary)
                    .frame(width: 46, alignment: .trailing)
            }
            TunableSlider(
                value: Binding<Double>(
                    get: { Double(value) },
                    set: { value = Float($0) }
                ),
                range: Double(range.lowerBound)...Double(range.upperBound),
                step: arrowStep(forFormat: format)
            )
        }
    }
}
