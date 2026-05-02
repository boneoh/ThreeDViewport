import SwiftUI
import AppKit

// Phase 6: Observable state that drives the scene HUD overlay.
// ViewportView updates this whenever mode or scene composition changes;
// SceneOverlayView observes it and re-renders automatically.
final class SceneOverlayState: ObservableObject {

    @Published var controlMode:       ControlMode = .camera
    @Published var objectNames:       [String]    = []
    @Published var objectVisibility:  [Bool]      = []
    @Published var selectedIndex:     Int         = 0

    // Callback invoked when the user clicks an eye icon in the HUD.
    var onToggleVisibility: ((Int) -> Void)?

    init() {
        print("[DEBUG] SceneOverlayState: initialized")
    }
}

// MARK: - SwiftUI view

// Floating HUD rendered in the top-left corner of the viewport.
// Shows the active control mode and a per-object list with visibility toggles.
struct SceneOverlayView: View {

    @ObservedObject var state: SceneOverlayState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Mode indicator ────────────────────────────────────────────────
            HStack(spacing: 6) {
                Image(systemName: modeIcon)
                    .foregroundColor(modeColor)
                    .font(.system(size: 11, weight: .semibold))
                Text(state.controlMode.displayName + " Mode")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(modeColor)
            }

            // ── Object list ───────────────────────────────────────────────────
            if !state.objectNames.isEmpty {
                Divider()
                    .background(Color.white.opacity(0.15))
                    .padding(.vertical, 5)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(state.objectNames.indices, id: \.self) { i in
                        objectRow(index: i)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.58))
        .cornerRadius(8)
        .padding(12)
        .frame(maxWidth: 210, maxHeight: .infinity, alignment: .topLeading)
        // Clicks pass through the transparent background to Metal
        .allowsHitTesting(true)
    }

    // MARK: - Row builder

    @ViewBuilder
    private func objectRow(index i: Int) -> some View {
        let isSelected = (state.selectedIndex == i) && (state.controlMode == .object)
        let isVisible  = i < state.objectVisibility.count ? state.objectVisibility[i] : true

        HStack(spacing: 5) {
            // Selection dot
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected
                    ? Color(NSColor.systemGreen)
                    : Color(NSColor.tertiaryLabelColor))
                .font(.system(size: 9))

            // Visibility toggle
            Button(action: { state.onToggleVisibility?(i) }) {
                Image(systemName: isVisible ? "eye.fill" : "eye.slash.fill")
                    .foregroundColor(isVisible
                        ? Color(NSColor.secondaryLabelColor)
                        : Color(NSColor.tertiaryLabelColor))
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .help("Toggle visibility for '" + (i < state.objectNames.count ? state.objectNames[i] : "") + "'")

            // Name
            Text(i < state.objectNames.count ? state.objectNames[i] : "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(isSelected
                    ? Color(NSColor.labelColor)
                    : Color(NSColor.secondaryLabelColor))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Mode helpers

    private var modeIcon: String {
        switch state.controlMode {
        case .camera: return "camera.fill"
        case .light:  return "lightbulb.fill"
        case .object: return "cube.fill"
        }
    }

    private var modeColor: Color {
        switch state.controlMode {
        case .camera: return Color(NSColor.systemBlue)
        case .light:  return Color(NSColor.systemYellow)
        case .object: return Color(NSColor.systemGreen)
        }
    }
}
