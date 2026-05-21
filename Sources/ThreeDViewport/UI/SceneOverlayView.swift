import SwiftUI
import AppKit

// Observable state that drives the minimal scene HUD overlay.
// ViewportView updates this whenever the control mode or selection changes.
final class SceneOverlayState: ObservableObject {

    @Published var controlMode:     ControlMode = .camera
    /// Name of the currently selected item — object name, "Camera", or "Light N".
    @Published var selectedItemName: String     = "Camera"
    /// True while the Director's-POV view is active (Scene mode).  The HUD
    /// prepends a "SCENE" badge so it's visually obvious you're not looking
    /// through the recording camera.
    @Published var sceneModeActive:  Bool       = false

    init() {
        print("[DEBUG] SceneOverlayState: initialized")
    }
}

// MARK: - SwiftUI view

// Minimal HUD rendered in the top-left corner of the viewport.
// Shows only the active control mode and the name of the selected item.
struct SceneOverlayView: View {

    @ObservedObject var state: SceneOverlayState

    var body: some View {
        HStack(spacing: 6) {
            // SCENE badge — only when the Director's-POV view is active.
            if state.sceneModeActive {
                Text("SCENE")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.18))
                    .cornerRadius(4)
            }

            Image(systemName: modeIcon)
                .foregroundColor(modeColor)
                .font(.system(size: 11, weight: .semibold))

            Text(labelText)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(modeColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.55))
        .cornerRadius(7)
        .padding(12)
        // No maxWidth cap — let the HUD grow to fit any object name.  The
        // surrounding viewport (1920×1080 at MVP) bounds it naturally.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)  // clicks pass through to Metal
    }

    // MARK: - Helpers

    private var labelText: String {
        state.selectedItemName.isEmpty
            ? state.controlMode.displayName
            : state.controlMode.displayName + " — " + state.selectedItemName
    }

    private var modeIcon: String {
        switch state.controlMode {
        case .camera:   return "camera.fill"
        case .light:    return "lightbulb.fill"
        case .object:   return "cube.fill"
        case .model:    return "square.3.layers.3d"
        case .director: return "move.3d"
        }
    }

    private var modeColor: Color {
        switch state.controlMode {
        case .camera:   return Color(NSColor.systemBlue)
        case .light:    return Color(NSColor.systemYellow)
        case .object:   return Color(NSColor.systemGreen)
        case .model:    return Color(NSColor.systemOrange)
        case .director: return Color(NSColor.systemPurple)
        }
    }
}
