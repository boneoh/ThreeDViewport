import SwiftUI
import simd

// A typed, session-only clipboard for copying xyz coordinate channels between
// lights, weather emitters, and the fog volume.  Each channel is held separately
// so a paste is always type-matched (Position↔Position, Size↔Size, Direction↔
// Direction) — preventing, say, a size from being dropped into a position.
// (Part A: panel value copy/paste.  Keyframe interop is a later phase.)
final class CoordinateClipboard: ObservableObject {
    @Published var position:  SIMD3<Float>? = nil
    @Published var size:      SIMD3<Float>? = nil
    @Published var direction: SIMD3<Float>? = nil
}

/// Compact copy + paste icon pair shown in a value-group header (Position / Size /
/// Direction).  Copy is always active (light blue); paste is light blue when a
/// matching value has been copied and grey (disabled) otherwise.
struct CoordCopyPasteButtons: View {
    let onCopy:   () -> Void
    let onPaste:  () -> Void
    let canPaste: Bool

    /// Light blue used to signal an active copy/paste action.
    private let activeBlue = Color(red: 0.42, green: 0.71, blue: 1.0)

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc").foregroundColor(activeBlue)
            }
            .buttonStyle(.borderless)
            .help("Copy these coordinates")

            Button(action: onPaste) {
                Image(systemName: "doc.on.clipboard")
                    .foregroundColor(canPaste ? activeBlue : .gray)
            }
            .buttonStyle(.borderless)
            .disabled(!canPaste)
            .help("Paste copied coordinates")
        }
        .font(.caption)
    }
}
