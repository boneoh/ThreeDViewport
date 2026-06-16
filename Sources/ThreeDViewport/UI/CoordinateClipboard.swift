import SwiftUI
import AppKit
import simd

// A typed clipboard for copying xyz coordinate channels between lights, weather
// emitters, the fog volume, the camera, and models.  Each channel is held
// separately so a paste is always type-matched (Position↔Position, Size↔Size).
// World-space aim points (camera/light Target) use the Position channel.
//
// Cross-instance (Option B): each channel keeps an in-memory slot (so all three
// remembered values work within one instance) AND mirrors the most-recent copy to
// the system pasteboard, so a second app instance can paste it.  The three
// properties stay source-compatible — the getter falls back to the system
// pasteboard when the in-memory slot is empty, the setter mirrors to it — so no
// call site changes.  Paste icons re-evaluate when the app reactivates (see
// `refreshFromPasteboard`, driven from AppDelegate.applicationDidBecomeActive).
final class CoordinateClipboard: ObservableObject {

    enum Channel: String, Codable { case position, size, rotation }
    private struct Payload: Codable { let channel: Channel; let value: [Float] }
    static let pasteboardType = NSPasteboard.PasteboardType("com.threedviewport.coordinate")

    // In-memory slots (this instance's own copies; all three persist independently).
    private var slotPosition: SIMD3<Float>?
    private var slotSize:     SIMD3<Float>?
    private var slotRotation: SIMD3<Float>?

    // Bumped on reactivation so SwiftUI re-evaluates canPaste against the pasteboard.
    @Published private var revision = 0

    // Cached decode of the system pasteboard, refreshed only when changeCount moves.
    private var cachedChangeCount = -1
    private var cachedChannel: Channel?
    private var cachedValue:   SIMD3<Float>?

    var position: SIMD3<Float>? {
        get { slotPosition ?? pasteboardValue(.position) }
        set { objectWillChange.send(); slotPosition = newValue; mirror(.position, newValue) }
    }
    var size: SIMD3<Float>? {
        get { slotSize ?? pasteboardValue(.size) }
        set { objectWillChange.send(); slotSize = newValue; mirror(.size, newValue) }
    }
    /// Euler rotation (degrees, YXZ intrinsic).  Distinct from Position so a paste
    /// can't accidentally write rotation into a translation field.
    var rotation: SIMD3<Float>? {
        get { slotRotation ?? pasteboardValue(.rotation) }
        set { objectWillChange.send(); slotRotation = newValue; mirror(.rotation, newValue) }
    }

    /// Re-check the system pasteboard (call when the app reactivates) so paste icons
    /// light up after another instance copied.  Cheap: the actual decode only runs
    /// when the pasteboard's changeCount has moved.
    func refreshFromPasteboard() { revision += 1 }

    // MARK: - System pasteboard bridge

    private func mirror(_ channel: Channel, _ value: SIMD3<Float>?) {
        guard let v = value,
              let data = try? JSONEncoder().encode(Payload(channel: channel, value: [v.x, v.y, v.z]))
        else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: Self.pasteboardType)
        cachedChangeCount = pb.changeCount      // our own write — keep the cache in sync
        cachedChannel = channel; cachedValue = v
    }

    private func pasteboardValue(_ channel: Channel) -> SIMD3<Float>? {
        let pb = NSPasteboard.general
        if pb.changeCount != cachedChangeCount {
            cachedChangeCount = pb.changeCount
            if let data = pb.data(forType: Self.pasteboardType),
               let p = try? JSONDecoder().decode(Payload.self, from: data), p.value.count == 3 {
                cachedChannel = p.channel
                cachedValue   = SIMD3<Float>(p.value[0], p.value[1], p.value[2])
            } else {
                cachedChannel = nil; cachedValue = nil
            }
        }
        return cachedChannel == channel ? cachedValue : nil
    }
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
    /// Optional callback fired AFTER Paste or Zero (never Copy).  Inspectors use
    /// it to auto-stamp a keyframe at the current playhead when the relevant track
    /// already has keyframes — the conditional check lives in AppDelegate.
    var onAutoStamp: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc").foregroundColor(.editableBlue)
            }
            .buttonStyle(.borderless)
            // Copy is read-only, so it stays usable even when a lock disables the
            // surrounding section.  A hard environment write overrides an ancestor
            // `.disabled(…)` (unlike `.disabled(false)`, which only ANDs).  Paste /
            // Zero deliberately inherit the lock (see each call site's canPaste).
            .environment(\.isEnabled, true)
            .help("Copy these coordinates")

            Button(action: { onPaste(); onAutoStamp?() }) {
                Image(systemName: "doc.on.clipboard")
                    .foregroundColor(canPaste ? .editableBlue : .gray)
            }
            .buttonStyle(.borderless)
            .disabled(!canPaste)
            .help("Paste copied coordinates")

            if let onZero {
                Button(action: { onZero(); onAutoStamp?() }) {
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
