import AppKit
import simd

// MARK: - Track reference
// Internal so AppDelegate can pattern-match in edit-mode callbacks.

enum TrackRef: Equatable {
    case camera
    case object(Int)   // index into sceneManager.objects
    case light(Int)    // index into LightManager.lights
}

// MARK: - Safe array subscript (file-private)

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}

// MARK: - TimelineEditorView

/// AppKit canvas that draws track lanes, keyframe diamonds, a time ruler,
/// and a playhead.  Handles all mouse and keyboard input for the Timeline Editor panel.
final class TimelineEditorView: NSView {

    // ── External references ───────────────────────────────────────────────────

    weak var timeline:     Timeline?
    weak var sceneManager: SceneManager?
    weak var camera:       CameraController?
    weak var lightManager: LightManager?

    // ── Insert callbacks (set by AppDelegate) ─────────────────────────────────

    /// Called when the user presses Insert with an object lane selected.
    /// The argument is the object's index in sceneManager.objects.
    var onInsertObjectKeyframe: ((Int) -> Void)?

    /// Called when the user presses Insert with the Camera lane selected.
    var onInsertCameraKeyframe: (() -> Void)?

    /// Called when the user presses Insert with a light lane selected.
    /// The argument is the light's index in LightManager.lights.
    var onInsertLightKeyframe: ((Int) -> Void)?

    // ── Edit-mode callbacks (set by AppDelegate) ──────────────────────────────

    /// Called when the user presses Return on a selected diamond to enter edit mode.
    /// Arguments: the TrackRef for the lane and the keyframe's exact time.
    var onEnterEditMode: ((TrackRef, Double) -> Void)?

    /// Called when the user presses Return while already in edit mode (commit the new pose).
    var onCommitEdit: (() -> Void)?

    /// Called when the user presses Escape while in edit mode (discard changes).
    var onCancelEdit: (() -> Void)?

    // ── Bidirectional sync callbacks (set by AppDelegate) ─────────────────────

    /// Called when a lane row or diamond is clicked, so AppDelegate can switch the
    /// viewport to the matching control mode / selection.
    var onLaneSelected: ((TrackRef) -> Void)?

    /// View that receives key events not handled by the timeline editor.
    /// Set to the ViewportView so viewport shortcuts work even when the
    /// Timeline Editor panel has keyboard focus.
    weak var keyForwardTarget: NSView?

    // ── Layout constants ──────────────────────────────────────────────────────

    private let labelWidth:      CGFloat = 120
    private let rulerHeight:     CGFloat = 24
    private let laneHeight:      CGFloat = 28
    private let diamondHalfSize: CGFloat = 5
    /// Extra space reserved on the right so keyframes at the last frame
    /// are never flush against the window edge and remain easy to click.
    private let rightPad:        CGFloat = 24

    /// Pixels per second — computed from view width and duration so the full
    /// timeline always fits without horizontal scrolling.
    private var pxPerSecond: CGFloat {
        let trackWidth = max(1, bounds.width - labelWidth - rightPad)
        let dur        = max(0.001, timeline?.duration ?? 10.0)
        return trackWidth / CGFloat(dur)
    }

    // ── Selection state ───────────────────────────────────────────────────────

    /// Index of the currently selected lane.  nil = nothing selected.
    private var selectedTrackIndex: Int? = nil

    /// Index of the selected diamond within its lane.
    /// nil = lane selected but no diamond; only valid when selectedTrackIndex != nil.
    private var selectedKFIndex: Int? = nil

    // ── Drag state ────────────────────────────────────────────────────────────

    private var isDragging:      Bool    = false
    private var dragTrackIndex:  Int     = 0
    private var dragCurrentTime: Double  = 0
    private var dragMouseStartX: CGFloat = 0
    private var dragTimeStart:   Double  = 0

    // ── Edit-mode state ───────────────────────────────────────────────────────

    /// True while the user is live-editing a selected keyframe's pose in the viewport.
    private(set) var isEditingKeyframe: Bool = false

    /// The time of the keyframe currently being edited (only valid when isEditingKeyframe).
    private var editKFTime: Double = 0

    // ── Refresh timer ─────────────────────────────────────────────────────────

    private var refreshTimer: Timer?

    // MARK: - Init

    override init(frame: NSRect) { super.init(frame: frame) }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    override var isFlipped: Bool { true }   // y=0 at top, natural for lane layout
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Timer management

    func startRefreshTimer() {
        refreshTimer?.invalidate()
        // Fire at ~30 fps; always mark dirty so the playhead and scene changes show up.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0,
                                            repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Track helpers

    private typealias TrackList = [(name: String, ref: TrackRef)]

    /// Ordered track list: Camera first, then scene objects, then lights.
    private func buildTracks() -> TrackList {
        var result: TrackList = [("Camera", .camera)]
        for (i, obj) in (sceneManager?.objects ?? []).enumerated() {
            result.append((obj.name, .object(i)))
        }
        for i in 0..<(lightManager?.lights.count ?? 0) {
            result.append(("Light \(i + 1)", .light(i)))
        }
        return result
    }

    /// Sorted keyframe times for a given track.
    private func keyframeTimes(for ref: TrackRef) -> [Double] {
        switch ref {
        case .camera:
            return camera?.keyframeTrack?.keyframes.map { $0.time } ?? []
        case .object(let i):
            return sceneManager?.objects[safe: i]?.keyframeTrack?.keyframes.map { $0.time } ?? []
        case .light(let i):
            guard let lm = lightManager, i < lm.keyframeTracks.count else { return [] }
            return lm.keyframeTracks[i]?.keyframes.map { $0.time } ?? []
        }
    }

    // MARK: - Geometry helpers

    private func timeToX(_ t: Double) -> CGFloat {
        labelWidth + CGFloat(t) * pxPerSecond
    }

    private func xToTime(_ x: CGFloat) -> Double {
        max(0, Double((x - labelWidth) / pxPerSecond))
    }

    private func laneTop(_ index: Int) -> CGFloat {
        rulerHeight + CGFloat(index) * laneHeight
    }

    private func laneCenter(_ index: Int) -> CGFloat {
        laneTop(index) + laneHeight / 2
    }

    /// Returns (trackIndex, kfIndex) if `point` is within the hit area of a diamond.
    private func hitTestDiamond(at point: NSPoint,
                                 tracks: TrackList) -> (trackIndex: Int, kfIndex: Int)? {
        let hitRadius: CGFloat = diamondHalfSize + 5
        for (ti, (_, ref)) in tracks.enumerated() {
            let cy = laneCenter(ti)
            for (ki, t) in keyframeTimes(for: ref).enumerated() {
                let cx = timeToX(t)
                if abs(point.x - cx) <= hitRadius && abs(point.y - cy) <= hitRadius {
                    return (ti, ki)
                }
            }
        }
        return nil
    }

    /// Returns the lane index if `point` is inside any lane row.
    private func hitTestLane(at point: NSPoint, tracks: TrackList) -> Int? {
        for i in 0..<tracks.count {
            if point.y >= laneTop(i) && point.y < laneTop(i) + laneHeight {
                return i
            }
        }
        return nil
    }

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
        let tracks   = buildTracks()
        let duration = timeline?.duration  ?? 10.0
        let curTime  = timeline?.currentTime ?? 0.0
        let w        = bounds.width
        let totalH   = rulerHeight + CGFloat(tracks.count) * laneHeight

        // ── Background ────────────────────────────────────────────────────────
        NSColor(white: 0.18, alpha: 1).setFill()
        NSBezierPath.fill(bounds)

        // ── Label column ──────────────────────────────────────────────────────
        NSColor(white: 0.22, alpha: 1).setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: labelWidth, height: totalH))

        // ── Ruler background ──────────────────────────────────────────────────
        NSColor(white: 0.14, alpha: 1).setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: w, height: rulerHeight))

        // ── Lane rows ─────────────────────────────────────────────────────────
        for i in 0..<tracks.count {
            let rowRect = NSRect(x: labelWidth, y: laneTop(i),
                                 width: w - labelWidth, height: laneHeight)
            if i == selectedTrackIndex {
                // Amber tint while editing, blue-grey otherwise
                let bg = isEditingKeyframe
                    ? NSColor(red: 0.30, green: 0.22, blue: 0.08, alpha: 1)
                    : NSColor(white: 0.27, alpha: 1)
                bg.setFill()
            } else {
                NSColor(white: i % 2 == 0 ? 0.18 : 0.21, alpha: 1).setFill()
            }
            NSBezierPath.fill(rowRect)

            // Row separator
            NSColor(white: 0.13, alpha: 1).setFill()
            NSBezierPath.fill(NSRect(x: 0, y: laneTop(i) + laneHeight - 1,
                                     width: w, height: 1))
        }

        // ── Label column separator ────────────────────────────────────────────
        NSColor(white: 0.12, alpha: 1).setFill()
        NSBezierPath.fill(NSRect(x: labelWidth - 1, y: 0, width: 1, height: totalH))

        // ── Track name labels ─────────────────────────────────────────────────
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font:            NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor(white: 0.80, alpha: 1)
        ]
        for (i, (name, _)) in tracks.enumerated() {
            let str  = name as NSString
            let size = str.size(withAttributes: nameAttrs)
            str.draw(at: NSPoint(x: 8, y: laneCenter(i) - size.height / 2),
                     withAttributes: nameAttrs)
        }

        // ── Ruler ticks + time labels ─────────────────────────────────────────
        let tickAttrs: [NSAttributedString.Key: Any] = [
            .font:            NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor(white: 0.55, alpha: 1)
        ]
        // Choose label density based on available pixel density
        let labelEvery: Int = duration > 60 ? 10 : (duration > 30 ? 5 : (duration > 15 ? 2 : 1))

        var t: Double = 0
        while t <= duration + 0.0001 {
            let x = timeToX(t)
            if x >= labelWidth - 1 && x <= w + 1 {
                let isFive = Int(round(t)) % 5 == 0
                let tickH: CGFloat = isFive ? 10 : 6
                let tick  = NSBezierPath()
                tick.move(to: NSPoint(x: x, y: rulerHeight - tickH))
                tick.line(to: NSPoint(x: x, y: rulerHeight))
                NSColor(white: 0.45, alpha: 1).setStroke()
                tick.lineWidth = isFive ? 1.5 : 0.8
                tick.stroke()

                if Int(round(t)) % labelEvery == 0 {
                    let label = String(format: "%.0fs", t) as NSString
                    let size  = label.size(withAttributes: tickAttrs)
                    label.draw(at: NSPoint(x: x - size.width / 2, y: 4),
                               withAttributes: tickAttrs)
                }
            }
            t += 1
        }

        // ── Duration end marker ───────────────────────────────────────────────
        let endX = timeToX(duration)
        if endX >= labelWidth && endX <= w {
            let endLine = NSBezierPath()
            endLine.move(to: NSPoint(x: endX, y: 0))
            endLine.line(to: NSPoint(x: endX, y: totalH))
            let dashes: [CGFloat] = [4, 3]
            endLine.setLineDash(dashes, count: 2, phase: 0)
            endLine.lineWidth = 1
            NSColor(white: 0.50, alpha: 0.5).setStroke()
            endLine.stroke()
        }

        // ── Keyframe diamonds ─────────────────────────────────────────────────
        let hs = diamondHalfSize
        for (ti, (_, ref)) in tracks.enumerated() {
            let cy = laneCenter(ti)
            for (ki, kfTime) in keyframeTimes(for: ref).enumerated() {
                let cx = timeToX(kfTime)
                guard cx >= labelWidth - hs && cx <= w + hs else { continue }

                let isSelected = (ti == selectedTrackIndex && ki == selectedKFIndex)

                // Colour: amber while actively editing this diamond, accent when selected, grey otherwise
                let fillColor: NSColor
                if isSelected && isEditingKeyframe {
                    // Pulsing amber to signal live-edit mode
                    fillColor = NSColor(red: 1.0, green: 0.65, blue: 0.15, alpha: 1)
                } else if isSelected {
                    fillColor = NSColor.controlAccentColor
                } else {
                    fillColor = NSColor(white: 0.72, alpha: 1)
                }

                let strokeColor: NSColor = isSelected
                    ? NSColor.white.withAlphaComponent(0.9)
                    : NSColor(white: 0.38, alpha: 1)

                let diamond = NSBezierPath()
                diamond.move(to: NSPoint(x: cx,      y: cy - hs))
                diamond.line(to: NSPoint(x: cx + hs, y: cy))
                diamond.line(to: NSPoint(x: cx,      y: cy + hs))
                diamond.line(to: NSPoint(x: cx - hs, y: cy))
                diamond.close()

                fillColor.setFill()
                diamond.fill()

                strokeColor.setStroke()
                diamond.lineWidth = isSelected ? 1.5 : 0.8
                diamond.stroke()
            }
        }

        // ── Playhead ──────────────────────────────────────────────────────────
        let phX = timeToX(curTime)
        if phX >= labelWidth - 1 && phX <= w + 1 {
            // Downward triangle in ruler
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: phX - 5, y: 0))
            tri.line(to: NSPoint(x: phX + 5, y: 0))
            tri.line(to: NSPoint(x: phX,     y: 9))
            tri.close()
            NSColor.systemRed.setFill()
            tri.fill()

            // Vertical line through all lanes
            let line = NSBezierPath()
            line.move(to: NSPoint(x: phX, y: 9))
            line.line(to: NSPoint(x: phX, y: totalH))
            NSColor.systemRed.withAlphaComponent(0.75).setStroke()
            line.lineWidth = 1.5
            line.stroke()
        }

        // ── Ruler bottom border ───────────────────────────────────────────────
        NSColor(white: 0.10, alpha: 1).setFill()
        NSBezierPath.fill(NSRect(x: 0, y: rulerHeight - 1, width: w, height: 1))

        // ── Edit-mode badge ───────────────────────────────────────────────────
        if isEditingKeyframe {
            let badge = "● EDITING — Return to commit  ·  Esc to cancel" as NSString
            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font:            NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor(red: 1.0, green: 0.75, blue: 0.20, alpha: 1)
            ]
            let badgeSize = badge.size(withAttributes: badgeAttrs)
            badge.draw(
                at: NSPoint(x: labelWidth + 8, y: (rulerHeight - badgeSize.height) / 2),
                withAttributes: badgeAttrs
            )
        }
    }

    // MARK: - Mouse input

    override func mouseDown(with event: NSEvent) {
        // Block all mouse interaction while a keyframe is being edited.
        guard !isEditingKeyframe else { return }

        window?.makeFirstResponder(self)
        let pt     = convert(event.locationInWindow, from: nil)
        let tracks = buildTracks()

        // Ruler click → scrub
        if pt.y < rulerHeight && pt.x >= labelWidth {
            scrubToX(pt.x)
            return
        }

        // Diamond hit → select diamond + scrub to its time.
        // Double-click immediately enters edit mode.
        if let hit = hitTestDiamond(at: pt, tracks: tracks) {
            select(trackIndex: hit.trackIndex, kfIndex: hit.kfIndex)
            let times = keyframeTimes(for: tracks[hit.trackIndex].ref)
            if hit.kfIndex < times.count {
                timeline?.seek(to: times[hit.kfIndex])
            }
            // Notify viewport so it switches to the matching control mode.
            onLaneSelected?(tracks[hit.trackIndex].ref)
            if event.clickCount == 2 {
                // Double-click: jump straight into edit mode (same as select + Return).
                handleReturnKey(tracks: tracks)
            }
            return
        }

        // Lane hit → select lane, deselect any diamond, notify viewport.
        if let lane = hitTestLane(at: pt, tracks: tracks) {
            select(trackIndex: lane, kfIndex: nil)
            onLaneSelected?(tracks[lane].ref)
            return
        }

        // Click outside all lanes → deselect
        select(trackIndex: nil, kfIndex: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isEditingKeyframe else { return }

        let pt     = convert(event.locationInWindow, from: nil)
        let tracks = buildTracks()

        // Ruler drag → scrub
        if !isDragging && pt.y < rulerHeight && pt.x >= labelWidth {
            scrubToX(pt.x)
            return
        }

        // Begin drag if a diamond is selected and the mouse has moved into the track area
        if !isDragging {
            guard let ti = selectedTrackIndex, let ki = selectedKFIndex else { return }
            let times = keyframeTimes(for: tracks[ti].ref)
            guard ki < times.count else { return }
            isDragging      = true
            dragTrackIndex  = ti
            dragCurrentTime = times[ki]
            dragMouseStartX = pt.x
            dragTimeStart   = times[ki]
        }

        guard isDragging else { return }

        let dx      = pt.x - dragMouseStartX
        let maxT    = timeline?.duration ?? Double.infinity
        let newTime = max(0, min(maxT, dragTimeStart + Double(dx / pxPerSecond)))

        let ref = tracks[dragTrackIndex].ref
        applyRetime(ref: ref, fromTime: dragCurrentTime, toTime: newTime)
        dragCurrentTime = newTime

        // Re-resolve diamond index after re-sort
        let updatedTimes = keyframeTimes(for: ref)
        selectedKFIndex  = updatedTimes.firstIndex { abs($0 - newTime) < 0.0005 }

        timeline?.seek(to: newTime)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }

    // MARK: - Keyboard input

    override func keyDown(with event: NSEvent) {
        let tracks = buildTracks()
        switch event.keyCode {

        case 36:        // Return / Enter
            handleReturnKey(tracks: tracks)

        case 53:        // Escape
            handleEscapeKey()

        case 51, 117:   // Backspace / Forward Delete → remove selected diamond
            guard !isEditingKeyframe else { return }
            deleteSelectedKeyframe(tracks: tracks)

        case 114:       // Insert / Help → stamp keyframe at current time in selected lane
            guard !isEditingKeyframe else { return }
            insertKeyframeInSelectedLane(tracks: tracks)

        case 123:       // Left arrow → nudge one frame earlier
            guard !isEditingKeyframe else { super.keyDown(with: event); return }
            nudgeSelected(by: -1.0 / 30.0, tracks: tracks)

        case 124:       // Right arrow → nudge one frame later
            guard !isEditingKeyframe else { super.keyDown(with: event); return }
            nudgeSelected(by:  1.0 / 30.0, tracks: tracks)

        default:
            // Forward unrecognised keys to the viewport so shortcuts like
            // O / C / L / arrows still work while the timeline editor has focus.
            if let target = keyForwardTarget {
                target.keyDown(with: event)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    // MARK: - Edit-mode key handlers

    /// Commits the active keyframe edit and exits edit mode.
    /// Called either by pressing Return in the Timeline Editor or by pressing
    /// Return in the main viewport (wired via AppDelegate).
    func commitEditIfActive() {
        guard isEditingKeyframe else { return }
        print("[DEBUG] TimelineEditorView: commitEditIfActive — committing at t="
            + String(format: "%.3f", editKFTime))
        onCommitEdit?()
        isEditingKeyframe  = false
        selectedTrackIndex = nil
        selectedKFIndex    = nil
        needsDisplay       = true
    }

    /// Selects the lane matching `ref`.
    /// If the lane is already selected (e.g. because the user just clicked a diamond
    /// on it and `onLaneSelected` triggered a viewport mode change that bounced back
    /// here) the call is a no-op so the existing `selectedKFIndex` is preserved —
    /// without this guard, the round-trip clears the diamond and breaks drag.
    func selectTrack(_ ref: TrackRef) {
        let tracks = buildTracks()
        guard let idx = tracks.firstIndex(where: { $0.ref == ref }) else { return }
        guard idx != selectedTrackIndex else { return }   // same lane — keep diamond selection
        selectedTrackIndex = idx
        selectedKFIndex    = nil
        needsDisplay       = true
    }

    private func handleReturnKey(tracks: TrackList) {
        if isEditingKeyframe {
            // ── Commit ─────────────────────────────────────────────────────────
            print("[DEBUG] TimelineEditorView: committing keyframe edit at t="
                + String(format: "%.3f", editKFTime))
            onCommitEdit?()
            isEditingKeyframe  = false
            selectedTrackIndex = nil
            selectedKFIndex    = nil
            needsDisplay       = true
        } else {
            // ── Enter edit mode ────────────────────────────────────────────────
            guard let ti = selectedTrackIndex, let ki = selectedKFIndex else { return }
            let ref   = tracks[ti].ref
            let times = keyframeTimes(for: ref)
            guard ki < times.count else { return }

            editKFTime        = times[ki]
            isEditingKeyframe = true
            needsDisplay      = true

            print("[DEBUG] TimelineEditorView: entering edit mode lane=\(ti)"
                + " kf=\(ki) t=" + String(format: "%.3f", editKFTime))

            onEnterEditMode?(ref, editKFTime)
        }
    }

    private func handleEscapeKey() {
        if isEditingKeyframe {
            // ── Cancel ─────────────────────────────────────────────────────────
            print("[DEBUG] TimelineEditorView: cancelling keyframe edit at t="
                + String(format: "%.3f", editKFTime))
            onCancelEdit?()
            isEditingKeyframe  = false
            selectedTrackIndex = nil
            selectedKFIndex    = nil
            needsDisplay       = true
        } else {
            // If not editing, Esc deselects everything
            select(trackIndex: nil, kfIndex: nil)
        }
    }

    // MARK: - Private action helpers

    private func select(trackIndex: Int?, kfIndex: Int?) {
        selectedTrackIndex = trackIndex
        selectedKFIndex    = kfIndex
        needsDisplay       = true
    }

    private func scrubToX(_ x: CGFloat) {
        let t = min(xToTime(x), timeline?.duration ?? Double.infinity)
        timeline?.seek(to: t)
        needsDisplay = true
    }

    private func applyRetime(ref: TrackRef, fromTime: Double, toTime: Double) {
        switch ref {
        case .camera:
            guard let track = camera?.keyframeTrack,
                  let idx   = track.keyframes.firstIndex(where: { abs($0.time - fromTime) < 0.0005 })
            else { return }
            track.retimeKeyframe(at: idx, to: toTime)

        case .object(let i):
            guard let obj   = sceneManager?.objects[safe: i],
                  let track = obj.keyframeTrack,
                  let idx   = track.keyframes.firstIndex(where: { abs($0.time - fromTime) < 0.0005 })
            else { return }
            track.retimeKeyframe(at: idx, to: toTime)

        case .light(let i):
            guard let lm    = lightManager,
                  i < lm.keyframeTracks.count,
                  let track = lm.keyframeTracks[i],
                  let idx   = track.keyframes.firstIndex(where: { abs($0.time - fromTime) < 0.0005 })
            else { return }
            track.retimeKeyframe(at: idx, to: toTime)
        }
    }

    private func deleteSelectedKeyframe(tracks: TrackList) {
        guard let ti = selectedTrackIndex, let ki = selectedKFIndex else { return }
        let ref = tracks[ti].ref
        switch ref {
        case .camera:
            camera?.keyframeTrack?.removeKeyframe(at: ki)
        case .object(let i):
            sceneManager?.objects[safe: i]?.keyframeTrack?.removeKeyframe(at: ki)
        case .light(let i):
            guard let lm = lightManager, i < lm.keyframeTracks.count else { break }
            lm.keyframeTracks[i]?.removeKeyframe(at: ki)
        }
        selectedKFIndex = nil
        needsDisplay    = true
        print("[DEBUG] TimelineEditorView: deleted keyframe lane=\(ti) kf=\(ki)")
    }

    private func insertKeyframeInSelectedLane(tracks: TrackList) {
        guard let ti = selectedTrackIndex else { return }
        let ref = tracks[ti].ref
        switch ref {
        case .camera:        onInsertCameraKeyframe?()
        case .object(let i): onInsertObjectKeyframe?(i)
        case .light(let i):  onInsertLightKeyframe?(i)
        }
        // Re-select the newly stamped diamond (callbacks are synchronous)
        let t            = timeline?.currentTime ?? 0
        let updatedTimes = keyframeTimes(for: ref)
        selectedKFIndex  = updatedTimes.firstIndex { abs($0 - t) < 0.001 }
        needsDisplay     = true
        print("[DEBUG] TimelineEditorView: inserted keyframe at t=\(String(format: "%.3f", t))"
            + " lane=\(ti)")
    }

    private func nudgeSelected(by delta: Double, tracks: TrackList) {
        guard let ti = selectedTrackIndex, let ki = selectedKFIndex else { return }
        let ref   = tracks[ti].ref
        let times = keyframeTimes(for: ref)
        guard ki < times.count else { return }

        let oldTime = times[ki]
        let maxT    = timeline?.duration ?? Double.infinity
        let newTime = max(0, min(maxT, oldTime + delta))

        applyRetime(ref: ref, fromTime: oldTime, toTime: newTime)

        let updatedTimes = keyframeTimes(for: ref)
        selectedKFIndex  = updatedTimes.firstIndex { abs($0 - newTime) < 0.0005 }

        timeline?.seek(to: newTime)
        needsDisplay = true
    }
}
