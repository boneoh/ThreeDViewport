import SwiftUI
import simd

// A typed, session-only clipboard for copying xyz coordinate channels between
// lights, weather emitters, the fog volume, the camera, and models.  Each channel
// is held separately so a paste is always type-matched (Position↔Position,
// Size↔Size) — preventing, say, a size from being dropped into a position.
// World-space aim points (camera/light Target) use the Position channel, since a
// target is itself a position.
final class CoordinateClipboard: ObservableObject {
    @Published var position:  SIMD3<Float>? = nil
    @Published var size:      SIMD3<Float>? = nil
    /// Euler rotation (degrees, YXZ intrinsic).  Distinct from Position so a paste
    /// can't accidentally write rotation into a translation field.
    @Published var rotation:  SIMD3<Float>? = nil
}

/// Compact copy + paste icon pair shown in a value-group header (Position / Size /
/// Direction).  Copy is always active (light blue); paste is light blue when a
/// matching value has been copied and grey (disabled) otherwise.
struct CoordCopyPasteButtons: View {
    let onCopy:   () -> Void
    let onPaste:  () -> Void
    let canPaste: Bool
    /// Optional "Z" zero button shown to the right of Paste.  When provided, sets
    /// the associated coordinates to zero.
    var onZero:   (() -> Void)? = nil
    var canZero:  Bool          = false   // ignored when onZero == nil

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc").foregroundColor(.editableBlue)
            }
            .buttonStyle(.borderless)
            .help("Copy these coordinates")

            Button(action: onPaste) {
                Image(systemName: "doc.on.clipboard")
                    .foregroundColor(canPaste ? .editableBlue : .gray)
            }
            .buttonStyle(.borderless)
            .disabled(!canPaste)
            .help("Paste copied coordinates")

            if let onZero {
                Button(action: onZero) {
                    Text("Z")
                        .fontWeight(.semibold)
                        .foregroundColor(canZero ? .editableBlue : .gray)
                }
                .buttonStyle(.borderless)
                .disabled(!canZero)
                .help("Set these values to zero")
            }
        }
        .font(.caption)
    }
}
