import AppKit
import Combine
import simd

// MARK: - Clipboard

/// Pose data copied from a keyframe diamond via Cmd+C.
/// Time is excluded — paste always uses the current playhead position.
enum ClipboardKeyframe {
    case object(TransformKeyframe)
    case camera(CameraKeyframe)
    case light(LightKeyframe)
    case group(TransformKeyframe)

    /// Human-readable description shown in debug logs.
    var typeName: String {
        switch self {
        case .object: return "object"
        case .camera: return "camera"
        case .light:  return "light"
        case .group:  return "group"
        }
    }
}

// MARK: - Track reference
// Internal so AppDelegate can pattern-match in edit-mode callbacks.

enum TrackRef: Equatable {
    case camera
    case object(Int)   // index into sceneManager.objects
    case light(Int)    // index into LightManager.lights
    case group(Int)    // groupID — multi-part model header row
}

// One row in the timeline label/track area.
// Replaces the old (name: String, ref: TrackRef) tuple.
struct TrackRow {
    var name:          String
    var ref:           TrackRef
    /// True for collapsed/expanded group-header rows.
    var isGroupHeader: Bool  = false
    /// True for part rows shown when a group is expanded (indented name, no easing popup).
    var isIndented:    Bool  = false
    /// Set on group-header rows — the groupID that owns this header.
    var groupID:       Int?  = nil
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

    /// Set by TimelineEditorWindowController.  A Combine subscription is
    /// installed on didSet so the playhead redraws immediately whenever
    /// Timeline.currentTime changes — even during event-tracking (slider drag).
    weak var timeline: Timeline? {
        didSet {
            timeSubscription?.cancel()
            timeSubscription = timeline?.$currentTime
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.needsDisplay = true }
        }
    }
    /// Cancellable for the currentTime subscription; lives as long as the view.
    private var timeSubscription: AnyCancellable?

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

    /// Called when the user presses Insert with a group-header lane selected.
    /// The argument is the groupID that should receive a group-level keyframe.
    var onInsertGroupKeyframe: ((Int) -> Void)?

    // ── Edit-mode callbacks (set by AppDelegate) ──────────────────────────────

    /// Called when the user presses Return on a selected diamond to enter edit mode.
    /// Arguments: the TrackRef for the lane and the keyframe's exact time.
    var onEnterEditMode: ((TrackRef, Double) -> Void)?

    /// Called when the user presses Return while already in edit mode (commit the new pose).
    var onCommitEdit: (() -> Void)?

    /// Called when the user presses Escape while in edit mode (discard changes).
    var onCancelEdit: (() -> Void)?

    // ── Bidirectional sync callbacks (set by AppDelegate) ─────────────────────

    /// Called when a keyframe is deleted (Delete key) so AppDelegate can mark the project dirty.
    var onKeyframeDeleted: (() -> Void)?

    /// Called when a keyframe is pasted (Cmd+V) so AppDelegate can mark the project dirty.
    var onKeyframePasted: (() -> Void)?

    // ── Internal keyframe clipboard (Cmd+C / Cmd+V) ───────────────────────────

    /// Pose data from the last Cmd+C.  nil = nothing copied yet.
    /// Scoped to this view instance; does not use the system pasteboard.
    private var clipboardKeyframe: ClipboardKeyframe? = nil

    /// Called when a lane row or diamond is clicked, so AppDelegate can switch the
    /// viewport to the matching control mode / selection.
    var onLaneSelected: ((TrackRef) -> Void)?

    /// Called whenever group expansion state changes (rows added/removed).
    /// TimelineEditorWindowController wires this to updateWindowHeight() so the
    /// document view frame and panel height stay in sync with the visible row count.
    var onLayoutChanged: (() -> Void)?

    /// View that receives key events not handled by the timeline editor.
    /// Set to the ViewportView so viewport shortcuts work even when the
    /// Timeline Editor panel has keyboard focus.
    weak var keyForwardTarget: NSView?

    /// Set to true by the ViewportView before it calls keyDown on us so we
    /// know not to forward the event back (prevents a ping-pong loop).
    var isReceivingForwardedKey: Bool = false

    // ── Layout constants ──────────────────────────────────────────────────────

    private let labelWidth:      CGFloat = 240
    private let rulerHeight:     CGFloat = 24
    private let laneHeight:      CGFloat = 28
    private let diamondHalfSize: CGFloat = 5
    /// Extra space reserved on the right so keyframes at the last frame
    /// are never flush against the window edge and remain easy to click.
    private let rightPad:        CGFloat = 24
    /// Horizontal pixel range (from left edge) reserved for the disclosure triangle
    /// on group-header rows.  Clicking inside this zone toggles group expansion.
    /// Clicking elsewhere on the header row only selects the lane (no expand/collapse).
    private let triangleZone:    CGFloat = 22

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

    private var isDragging:        Bool    = false
    private var dragTrackIndex:    Int     = 0
    private var dragCurrentTime:   Double  = 0
    private var dragMouseStartX:   CGFloat = 0
    private var dragTimeStart:     Double  = 0
    /// True when the mouseDown that started the current drag gesture landed
    /// directly on a diamond.  Only in this case does a drag move the keyframe;
    /// otherwise the drag scrubs the timeline instead.
    private var mouseDownOnDiamond: Bool   = false

    // ── Multi-select state ────────────────────────────────────────────────────
    // A set of (trackIndex, kfIndex) pairs that form the multi-selection.
    // When empty the normal single-selection (selectedTrackIndex/selectedKFIndex)
    // is authoritative.  When ≥2 entries exist, delete / copy / drag operate on
    // every diamond in this set.
    private struct SelectedDiamond: Hashable {
        var trackIndex: Int
        var kfIndex:    Int
    }
    private var multiSelectedDiamonds: Set<SelectedDiamond> = []

    // ── Rubber-band selection ─────────────────────────────────────────────────
    private var isRubberBanding:   Bool    = false
    private var rubberBandStart:   NSPoint = .zero
    private var rubberBandCurrent: NSPoint = .zero

    // ── Multi-drag secondary entries ──────────────────────────────────────────
    // Populated at drag-start when ≥2 diamonds are selected and the dragged
    // diamond is among them.  The same time delta applied to the primary is
    // applied to each secondary on every mouseDragged event.
    private struct MultiDragEntry {
        var ref:         TrackRef
        var currentTime: Double
    }
    private var multiDragSecondary: [MultiDragEntry] = []

    // ── Multi-clipboard (Cmd+C / Cmd+V with multi-select) ─────────────────────
    // Each entry stores a pose snapshot, a time offset relative to the earliest
    // copied diamond, and the original track reference for paste-back.
    private struct MultiClipEntry {
        var clip:       ClipboardKeyframe
        var timeOffset: Double   // seconds relative to the earliest copied diamond
        var ref:        TrackRef
    }
    private var multiClipboard: [MultiClipEntry] = []

    // ── Edit-mode state ───────────────────────────────────────────────────────

    /// True while the user is live-editing a selected keyframe's pose in the viewport.
    private(set) var isEditingKeyframe: Bool = false

    /// The time of the keyframe currently being edited (only valid when isEditingKeyframe).
    private var editKFTime: Double = 0

    // ── Refresh timer ─────────────────────────────────────────────────────────

    private var refreshTimer: Timer?

    // ── Group expansion state ─────────────────────────────────────────────────
    // groupIDs that are currently expanded (showing per-part rows).
    // All groups start collapsed so complex models appear as a single row.

    private var expandedGroups:     Set<Int> = []
    private var lastExpandedGroups: Set<Int> = []

    // ── Easing popup buttons ──────────────────────────────────────────────────
    // One NSPopUpButton per object lane, positioned in the right half of the label
    // column.  Rebuilt whenever the object count, expansion state, or view bounds change.

    private var easingPopups:    [NSPopUpButton] = []
    private var lastObjectCount: Int             = -1
    private var lastBounds:      NSRect          = .zero

    // MARK: - Init

    override init(frame: NSRect) { super.init(frame: frame) }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    override var isFlipped: Bool { true }   // y=0 at top, natural for lane layout
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Public helpers

    /// Number of rows currently rendered (accounts for collapsed/expanded groups).
    /// Used by TimelineEditorWindowController to set the panel height.
    var visibleTrackCount: Int { buildTracks().count }

    // MARK: - Timer management

    func startRefreshTimer() {
        refreshTimer?.invalidate()
        // Fire at ~30 fps; syncs easing popups and marks the view dirty for
        // general scene changes (object names, keyframe edits, etc.).
        // Playhead position is additionally driven by the Combine subscription on
        // Timeline.currentTime, which updates even during event-tracking run loops.
        // Using .common mode so this timer also fires while the user drags a slider.
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.syncEasingPopupsIfNeeded()
            self?.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Track helpers

    private typealias TrackList = [TrackRow]

    /// Track list sorted alphabetically (natural order) by display name across
    /// every row type — Camera, standalone objects, multi-part model groups, and
    /// lights are all folded into one A→Z list.  Multi-part models appear as a
    /// single collapsible header row (sorted by group name); expanding it shows
    /// per-part rows sorted A→Z directly beneath the header.
    private func buildTracks() -> TrackList {
        let objects    = sceneManager?.objects ?? []
        let lightCount = lightManager?.lights.count ?? 0

        // Index group parts by groupID (preserving each part's global index).
        var groupOrder: [Int: [(idx: Int, obj: SceneObject)]] = [:]
        for (i, obj) in objects.enumerated() {
            if let gid = obj.groupID {
                groupOrder[gid, default: []].append((i, obj))
            }
        }

        // One top-level entry per row, tagged with the name used to sort it and a
        // monotonic `order` used only as a stable tiebreaker for equal names.
        enum RowEntry {
            case camera
            case standalone(idx: Int, obj: SceneObject)
            case group(gid: Int)
            case light(idx: Int)
        }
        var entries: [(sortName: String, order: Int, entry: RowEntry)] = []
        var order = 0
        func add(_ name: String, _ entry: RowEntry) {
            entries.append((name, order, entry)); order += 1
        }

        add("Camera", .camera)
        var seenGroups = Set<Int>()
        for (i, obj) in objects.enumerated() {
            if let gid = obj.groupID {
                guard seenGroups.insert(gid).inserted else { continue }
                add(sceneManager?.groupName(for: gid) ?? "Group", .group(gid: gid))
            } else {
                add(obj.name, .standalone(idx: i, obj: obj))
            }
        }
        for i in 0..<lightCount {
            add("Light \(i + 1)", .light(idx: i))
        }

        entries.sort {
            let c = $0.sortName.localizedStandardCompare($1.sortName)
            return c == .orderedSame ? ($0.order < $1.order) : (c == .orderedAscending)
        }

        var result: TrackList = []
        for (_, _, entry) in entries {
            switch entry {
            case .camera:
                result.append(TrackRow(name: "Camera", ref: .camera))
            case .standalone(let idx, let obj):
                result.append(TrackRow(name: obj.name, ref: .object(idx)))
            case .light(let idx):
                result.append(TrackRow(name: "Light \(idx + 1)", ref: .light(idx)))
            case .group(let gid):
                let gName = sceneManager?.groupName(for: gid) ?? "Group"
                let parts = groupOrder[gid] ?? []
                let label = "\(gName)  (\(parts.count) parts)"
                result.append(TrackRow(name: label, ref: .group(gid),
                                       isGroupHeader: true, groupID: gid))
                if expandedGroups.contains(gid) {
                    // Parts sorted alphabetically by name, beneath their header.
                    let sorted = parts.sorted { $0.obj.name.localizedStandardCompare($1.obj.name) == .orderedAscending }
                    for pair in sorted {
                        result.append(TrackRow(name: pair.obj.name,
                                               ref: .object(pair.idx),
                                               isIndented: true))
                    }
                }
            }
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
        case .group(let gid):
            return sceneManager?.groupKeyframeTracks[gid]?.keyframes.map { $0.time } ?? []
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
        for (ti, row) in tracks.enumerated() {
            let cy = laneCenter(ti)
            for (ki, t) in keyframeTimes(for: row.ref).enumerated() {
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

        // ── Lane rows ─────────────────────────────────────────────────────────
        for (i, row) in tracks.enumerated() {
            let isHeader   = row.isGroupHeader
            let isSelected = (i == selectedTrackIndex)
            // Group-header rows always span full width so they stand out as
            // structure.  Selected rows also span full width so the highlight
            // covers the name/label column, not just the empty lane area.
            let fullWidth  = isHeader || isSelected
            let rowRect    = NSRect(x: fullWidth ? 0 : labelWidth,
                                    y: laneTop(i),
                                    width: fullWidth ? w : w - labelWidth,
                                    height: laneHeight)

            if isSelected {
                let bg: NSColor
                if isEditingKeyframe {
                    bg = NSColor(red: 0.30, green: 0.22, blue: 0.08, alpha: 1)   // editing amber (any lane)
                } else if isHeader {
                    bg = NSColor(red: 0.22, green: 0.42, blue: 0.68, alpha: 1)   // selected group header — lighter blue
                } else {
                    bg = NSColor(red: 0.14, green: 0.30, blue: 0.52, alpha: 1)   // selected lane — bold blue
                }
                bg.setFill()
            } else if isHeader {
                NSColor(white: 0.26, alpha: 1).setFill()   // header: slightly lighter than default
            } else {
                NSColor(white: i % 2 == 0 ? 0.18 : 0.21, alpha: 1).setFill()
            }
            NSBezierPath.fill(rowRect)

            // Row separator
            NSColor(white: isHeader ? 0.11 : 0.13, alpha: 1).setFill()
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
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font:            NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor(white: 0.88, alpha: 1)
        ]
        // Object rows share the label column with the easing popup (right ~66 px).
        // Clip name drawing so it doesn't bleed into the popup area.
        let popupReserved: CGFloat = 64   // matches popup width (58) + right margin (3) + gap (3)

        for (i, row) in tracks.enumerated() {
            // ── Disclosure triangle for group headers ─────────────────────────
            if row.isGroupHeader, let gid = row.groupID {
                let isExpanded = expandedGroups.contains(gid)
                let triStr  = (isExpanded ? "▼" : "▶") as NSString
                let triAttrs: [NSAttributedString.Key: Any] = [
                    .font:            NSFont.systemFont(ofSize: 12, weight: .bold),
                    .foregroundColor: NSColor(white: 0.92, alpha: 1)
                ]
                let triSize = triStr.size(withAttributes: triAttrs)
                triStr.draw(at: NSPoint(x: 7, y: laneCenter(i) - triSize.height / 2),
                            withAttributes: triAttrs)
            }

            // ── Name label ────────────────────────────────────────────────────
            let attrs    = row.isGroupHeader ? headerAttrs : nameAttrs
            let nameX: CGFloat
            let maxNameW: CGFloat
            if row.isGroupHeader {
                nameX    = triangleZone
                maxNameW = labelWidth - triangleZone - 4
            } else if case .object = row.ref {
                // Object rows (standalone or indented part) share the label column
                // with an easing popup in the right portion.  Indented rows are
                // inset by an extra 12 px to show hierarchy visually.
                nameX    = row.isIndented ? 20 : 8
                // Subtract nameX so the name area ends a 3-px gap before the popup,
                // even for indented rows (otherwise the indent eats into the gap).
                maxNameW = labelWidth - popupReserved - nameX
            } else {
                nameX    = 8
                maxNameW = labelWidth - 12
            }

            let str  = row.name as NSString
            let size = str.size(withAttributes: attrs)
            let y    = laneCenter(i) - size.height / 2

            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath.clip(NSRect(x: nameX, y: laneTop(i),
                                     width: maxNameW, height: laneHeight))
            str.draw(at: NSPoint(x: nameX, y: y), withAttributes: attrs)
            NSGraphicsContext.current?.restoreGraphicsState()
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
        for (ti, row) in tracks.enumerated() {
            let cy = laneCenter(ti)
            for (ki, kfTime) in keyframeTimes(for: row.ref).enumerated() {
                let cx = timeToX(kfTime)
                guard cx >= labelWidth - hs && cx <= w + hs else { continue }

                let isSelected      = (ti == selectedTrackIndex && ki == selectedKFIndex)
                let isMultiSelected = multiSelectedDiamonds.count >= 2 &&
                                      multiSelectedDiamonds.contains(
                                          SelectedDiamond(trackIndex: ti, kfIndex: ki))

                // True when this camera-track keyframe is a follow keyframe.
                let isFollowKeyframe: Bool = {
                    guard case .camera = row.ref else { return false }
                    return camera?.keyframeTrack?.keyframes[safe: ki]?.followTargetName != nil
                }()

                // Colour: amber while editing, teal when multi-selected,
                // accent when single-selected, orange for follow keyframes, grey otherwise.
                let fillColor: NSColor
                if isSelected && isEditingKeyframe {
                    // Pulsing amber to signal live-edit mode.
                    fillColor = NSColor(red: 1.0, green: 0.65, blue: 0.15, alpha: 1)
                } else if isMultiSelected {
                    fillColor = NSColor.systemTeal
                } else if isSelected {
                    fillColor = NSColor.controlAccentColor
                } else if isFollowKeyframe {
                    // Orange to distinguish follow keyframes from free-camera keyframes.
                    fillColor = NSColor(red: 1.0, green: 0.50, blue: 0.10, alpha: 1)
                } else {
                    fillColor = NSColor(white: 0.72, alpha: 1)
                }

                let strokeColor: NSColor = (isSelected || isMultiSelected)
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
                diamond.lineWidth = (isSelected || isMultiSelected) ? 1.5 : 0.8
                diamond.stroke()
            }
        }

        // ── Playhead line through the lanes ───────────────────────────────────
        // The ruler triangle is drawn by the floating header (drawRulerHeader) so
        // it stays visible when the lanes are scrolled.
        let phX = timeToX(curTime)
        if phX >= labelWidth - 1 && phX <= w + 1 {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: phX, y: rulerHeight))
            line.line(to: NSPoint(x: phX, y: totalH))
            NSColor.systemRed.withAlphaComponent(0.75).setStroke()
            line.lineWidth = 1.5
            line.stroke()
        }

        // ── Rubber-band selection rectangle ───────────────────────────────────
        if isRubberBanding {
            let bandRect = NSRect(
                x:      min(rubberBandStart.x, rubberBandCurrent.x),
                y:      min(rubberBandStart.y, rubberBandCurrent.y),
                width:  abs(rubberBandCurrent.x - rubberBandStart.x),
                height: abs(rubberBandCurrent.y - rubberBandStart.y)
            )
            // Translucent accent fill.
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
            NSBezierPath.fill(bandRect)
            // Dashed accent border.
            let bandPath = NSBezierPath(rect: bandRect)
            let dashes: [CGFloat] = [4, 3]
            bandPath.setLineDash(dashes, count: 2, phase: 0)
            bandPath.lineWidth = 1
            NSColor.controlAccentColor.setStroke()
            bandPath.stroke()
        }

        // ── Floating ruler header ─────────────────────────────────────────────
        // Drawn last, offset to the top of the scroll view's visible area, so the
        // ruler (ticks, time labels, playhead marker, EDITING badge) stays pinned
        // at the top while the lanes scroll beneath it.
        drawRulerHeader(originY: visibleRect.minY, duration: duration, curTime: curTime, w: w)

        // Easing dropdowns are real subviews and render above the drawn header,
        // so hide any that have scrolled up under it.
        updateEasingPopupOcclusion()
    }

    /// Hides easing popups whose row has scrolled under the floating ruler header
    /// (subviews always render above drawn content, so they'd poke through it).
    /// Re-shown when the row scrolls back below the header.
    private func updateEasingPopupOcclusion() {
        let band = NSRect(x: 0, y: visibleRect.minY, width: bounds.width, height: rulerHeight)
        for popup in easingPopups {
            popup.isHidden = popup.frame.intersects(band)
        }
    }

    /// Draws the ruler header band at vertical offset `originY` (= the scroll
    /// view's visible-rect top), so it floats above the scrolling lanes.
    private func drawRulerHeader(originY: CGFloat, duration: Double, curTime: Double, w: CGFloat) {
        // Background band (full width, including over the label column).
        NSColor(white: 0.14, alpha: 1).setFill()
        NSBezierPath.fill(NSRect(x: 0, y: originY, width: w, height: rulerHeight))

        // ── Ticks + time labels ───────────────────────────────────────────────
        let tickAttrs: [NSAttributedString.Key: Any] = [
            .font:            NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor(white: 0.55, alpha: 1)
        ]
        let labelEvery: Int = duration > 60 ? 10 : (duration > 30 ? 5 : (duration > 15 ? 2 : 1))
        var t: Double = 0
        while t <= duration + 0.0001 {
            let x = timeToX(t)
            if x >= labelWidth - 1 && x <= w + 1 {
                let isFive = Int(round(t)) % 5 == 0
                let tickH: CGFloat = isFive ? 10 : 6
                let tick  = NSBezierPath()
                tick.move(to: NSPoint(x: x, y: originY + rulerHeight - tickH))
                tick.line(to: NSPoint(x: x, y: originY + rulerHeight))
                NSColor(white: 0.45, alpha: 1).setStroke()
                tick.lineWidth = isFive ? 1.5 : 0.8
                tick.stroke()

                if Int(round(t)) % labelEvery == 0 {
                    let label = String(format: "%.0fs", t) as NSString
                    let size  = label.size(withAttributes: tickAttrs)
                    label.draw(at: NSPoint(x: x - size.width / 2, y: originY + 4),
                               withAttributes: tickAttrs)
                }
            }
            t += 1
        }

        // ── Playhead marker (triangle + connector within the ruler band) ──────
        let phX = timeToX(curTime)
        if phX >= labelWidth - 1 && phX <= w + 1 {
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: phX - 5, y: originY))
            tri.line(to: NSPoint(x: phX + 5, y: originY))
            tri.line(to: NSPoint(x: phX,     y: originY + 9))
            tri.close()
            NSColor.systemRed.setFill()
            tri.fill()

            let connector = NSBezierPath()
            connector.move(to: NSPoint(x: phX, y: originY + 9))
            connector.line(to: NSPoint(x: phX, y: originY + rulerHeight))
            NSColor.systemRed.withAlphaComponent(0.75).setStroke()
            connector.lineWidth = 1.5
            connector.stroke()
        }

        // ── Bottom border ─────────────────────────────────────────────────────
        NSColor(white: 0.10, alpha: 1).setFill()
        NSBezierPath.fill(NSRect(x: 0, y: originY + rulerHeight - 1, width: w, height: 1))

        // ── Edit-mode badge ───────────────────────────────────────────────────
        if isEditingKeyframe {
            let badge = "● EDITING — Return to commit  ·  Esc to cancel" as NSString
            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font:            NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor(red: 1.0, green: 0.75, blue: 0.20, alpha: 1)
            ]
            let badgeSize = badge.size(withAttributes: badgeAttrs)
            badge.draw(
                at: NSPoint(x: labelWidth + 8, y: originY + (rulerHeight - badgeSize.height) / 2),
                withAttributes: badgeAttrs
            )
        }
    }

    // MARK: - Mouse input

    override func mouseDown(with event: NSEvent) {
        // Block all mouse interaction while a keyframe is being edited.
        guard !isEditingKeyframe else { return }

        window?.makeFirstResponder(self)
        mouseDownOnDiamond = false   // reset each gesture
        let pt        = convert(event.locationInWindow, from: nil)
        let tracks    = buildTracks()
        let isOption  = event.modifierFlags.contains(.option)
        let isControl = event.modifierFlags.contains(.control)

        // ── Ctrl+click in track area → start rubber-band selection ────────────
        if isControl && pt.y >= rulerHeight && pt.x >= labelWidth {
            isRubberBanding   = true
            rubberBandStart   = pt
            rubberBandCurrent = pt
            return
        }

        // Ruler click → scrub.
        // Clear any selected diamond and multi-selection so a subsequent drag
        // into the track area never accidentally moves a keyframe instead of scrubbing.
        if pt.y < rulerHeight && pt.x >= labelWidth {
            multiSelectedDiamonds.removeAll()
            selectedKFIndex = nil
            scrubToX(pt.x)
            return
        }

        // Diamond hit.
        if let hit = hitTestDiamond(at: pt, tracks: tracks) {
            mouseDownOnDiamond = true
            let hitDiamond = SelectedDiamond(trackIndex: hit.trackIndex, kfIndex: hit.kfIndex)

            if isOption {
                // ── Alt+click: toggle diamond in/out of multi-selection ────────
                // Seed the set with the current single-select diamond the first
                // time the user adds a second diamond so both stay highlighted.
                if multiSelectedDiamonds.isEmpty,
                   let sti = selectedTrackIndex, let ski = selectedKFIndex {
                    multiSelectedDiamonds.insert(SelectedDiamond(trackIndex: sti, kfIndex: ski))
                }
                if multiSelectedDiamonds.contains(hitDiamond) {
                    multiSelectedDiamonds.remove(hitDiamond)
                } else {
                    multiSelectedDiamonds.insert(hitDiamond)
                }
            } else if multiSelectedDiamonds.contains(hitDiamond) {
                // ── Plain click on an already-selected diamond ─────────────────
                // Preserve the multi-selection so the drag that follows can move
                // all selected diamonds together.  Don't call removeAll() here.
                // (The set is cleared in mouseUp if no drag actually occurs, or
                //  rebuilt by the multi-drag path if it does.)
            } else {
                // ── Plain click on an unselected diamond ───────────────────────
                // Collapse the multi-selection; this diamond becomes the only one.
                multiSelectedDiamonds.removeAll()
                multiClipboard.removeAll()
            }

            // Always update single-select and seek so the playhead follows the click.
            select(trackIndex: hit.trackIndex, kfIndex: hit.kfIndex)
            let times = keyframeTimes(for: tracks[hit.trackIndex].ref)
            if hit.kfIndex < times.count { timeline?.seek(to: times[hit.kfIndex]) }
            onLaneSelected?(tracks[hit.trackIndex].ref)

            // Double-click enters edit mode only on plain clicks (no Alt).
            if !isOption && event.clickCount == 2 {
                handleReturnKey(tracks: tracks)
            }
            return
        }

        // Lane hit → select lane + notify viewport.
        // Group-header rows also toggle expansion, but ONLY when clicking the
        // disclosure triangle (leftmost triangleZone pixels) — not the whole row.
        // Any click in the track area (x ≥ labelWidth) also scrubs the playhead.
        if let lane = hitTestLane(at: pt, tracks: tracks) {
            let row = tracks[lane]

            // Plain lane click (no modifier) clears multi-selection.
            if !isOption {
                multiSelectedDiamonds.removeAll()
                multiClipboard.removeAll()
            }

            if row.isGroupHeader, let gid = row.groupID {
                // Toggle expansion only via the disclosure triangle.
                if pt.x < triangleZone {
                    if expandedGroups.contains(gid) {
                        expandedGroups.remove(gid)
                    } else {
                        expandedGroups.insert(gid)
                    }
                    rebuildEasingPopups()
                    onLayoutChanged?()   // resize document view / panel for new row count
                }
                select(trackIndex: lane, kfIndex: nil)
                onLaneSelected?(row.ref)
                if pt.x >= labelWidth { scrubToX(pt.x) }
                return
            }

            select(trackIndex: lane, kfIndex: nil)
            onLaneSelected?(row.ref)
            if pt.x >= labelWidth { scrubToX(pt.x) }
            return
        }

        // Click outside all lanes → deselect everything.
        multiSelectedDiamonds.removeAll()
        multiClipboard.removeAll()
        select(trackIndex: nil, kfIndex: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isEditingKeyframe else { return }

        let pt     = convert(event.locationInWindow, from: nil)
        let tracks = buildTracks()

        // ── Rubber-band in progress: just track the cursor and redraw ─────────
        if isRubberBanding {
            rubberBandCurrent = pt
            needsDisplay = true
            return
        }

        // Ruler drag → always scrub (highest priority).
        if !isDragging && pt.y < rulerHeight && pt.x >= labelWidth {
            scrubToX(pt.x)
            return
        }

        // If the gesture did NOT start on a diamond, scrub the playhead while dragging
        // in the track area — so the user can click-and-drag to position the playhead.
        if !mouseDownOnDiamond {
            if pt.x >= labelWidth { scrubToX(pt.x) }
            return
        }

        // Gesture started on a diamond: begin (or continue) moving it.
        if !isDragging {
            guard let ti = selectedTrackIndex, let ki = selectedKFIndex else { return }
            let times = keyframeTimes(for: tracks[ti].ref)
            guard ki < times.count else { return }
            isDragging      = true
            dragTrackIndex  = ti
            dragCurrentTime = times[ki]
            dragMouseStartX = pt.x
            dragTimeStart   = times[ki]

            // Populate secondary drag entries when ≥2 diamonds are selected and
            // the dragged diamond is among them.
            multiDragSecondary.removeAll()
            let primaryD = SelectedDiamond(trackIndex: ti, kfIndex: ki)
            if multiSelectedDiamonds.count >= 2 && multiSelectedDiamonds.contains(primaryD) {
                for d in multiSelectedDiamonds where d != primaryD {
                    guard d.trackIndex < tracks.count else { continue }
                    let dRef   = tracks[d.trackIndex].ref
                    let dTimes = keyframeTimes(for: dRef)
                    guard d.kfIndex < dTimes.count else { continue }
                    multiDragSecondary.append(MultiDragEntry(ref: dRef,
                                                             currentTime: dTimes[d.kfIndex]))
                }
            }
        }

        guard isDragging else { return }

        let dx      = pt.x - dragMouseStartX
        let maxT    = timeline?.duration ?? Double.infinity
        let newTime = max(0, min(maxT, dragTimeStart + Double(dx / pxPerSecond)))

        let ref = tracks[dragTrackIndex].ref
        let dt  = newTime - dragCurrentTime   // delta to apply to secondary diamonds

        applyRetime(ref: ref, fromTime: dragCurrentTime, toTime: newTime)
        dragCurrentTime = newTime

        // Apply the same time delta to every secondary diamond.
        for i in 0..<multiDragSecondary.count {
            let oldT = multiDragSecondary[i].currentTime
            let newT = max(0, min(maxT, oldT + dt))
            applyRetime(ref: multiDragSecondary[i].ref, fromTime: oldT, toTime: newT)
            multiDragSecondary[i].currentTime = newT
        }

        // Re-resolve primary diamond index after re-sort.
        let updatedTimes = keyframeTimes(for: ref)
        selectedKFIndex  = updatedTimes.firstIndex { abs($0 - newTime) < 0.0005 }

        timeline?.seek(to: newTime)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        // Finalise rubber-band: compute which diamonds fall inside the rect.
        if isRubberBanding {
            finalizeRubberBandSelection(tracks: buildTracks())
            isRubberBanding = false
            needsDisplay    = true
        }

        // After a multi-diamond drag, rebuild multiSelectedDiamonds with the
        // post-retime keyframe indices so they stay accurate for subsequent operations.
        if isDragging && !multiDragSecondary.isEmpty {
            let tracks = buildTracks()
            var updated = Set<SelectedDiamond>()
            // Primary — dragCurrentTime holds the final time of the primary diamond.
            if let ti = selectedTrackIndex {
                let times = keyframeTimes(for: tracks[ti].ref)
                if let newKi = times.firstIndex(where: { abs($0 - dragCurrentTime) < 0.0005 }) {
                    updated.insert(SelectedDiamond(trackIndex: ti, kfIndex: newKi))
                    selectedKFIndex = newKi
                }
            }
            // Secondaries — each entry tracks its own final time.
            for entry in multiDragSecondary {
                if let ti = tracks.firstIndex(where: { $0.ref == entry.ref }) {
                    let times = keyframeTimes(for: entry.ref)
                    if let ki = times.firstIndex(where: { abs($0 - entry.currentTime) < 0.0005 }) {
                        updated.insert(SelectedDiamond(trackIndex: ti, kfIndex: ki))
                    }
                }
            }
            multiSelectedDiamonds = updated
        }

        multiDragSecondary.removeAll()
        isDragging         = false
        mouseDownOnDiamond = false
    }

    // MARK: - Keyboard input

    override func keyDown(with event: NSEvent) {
        let tracks = buildTracks()

        // ── Cmd+C / Cmd+V — copy / paste keyframe ────────────────────────────
        // Handled before the main switch so these never fall through to the
        // viewport-forwarding default case and accidentally trigger mode changes.
        if event.modifierFlags.contains(.command), !event.isARepeat {
            switch event.keyCode {
            case 8:   // Cmd+C — copy selected diamond's pose to internal clipboard
                guard !isEditingKeyframe else { break }
                copySelectedKeyframe(tracks: tracks)
                return
            case 9:   // Cmd+V — paste clipboard pose at current playhead on selected lane
                guard !isEditingKeyframe else { break }
                pasteKeyframe(tracks: tracks)
                return
            default:
                break
            }
        }

        switch event.keyCode {

        case 36:        // Return / Enter
            handleReturnKey(tracks: tracks)

        case 53:        // Escape
            handleEscapeKey()

        case 2, 51, 117: // D / Backspace / Forward Delete → remove selected diamond
            guard !isEditingKeyframe else { return }
            deleteSelectedKeyframe(tracks: tracks)

        case 34, 114:   // I / Insert / Help → stamp keyframe at current time in selected lane
            guard !isEditingKeyframe else { return }
            insertKeyframeInSelectedLane(tracks: tracks)

        case 115:       // Home → seek to first frame
            guard !isEditingKeyframe else { super.keyDown(with: event); return }
            timeline?.seek(to: 0)
            needsDisplay = true

        case 119:       // End → seek to last frame
            guard !isEditingKeyframe else { super.keyDown(with: event); return }
            if let dur = timeline?.duration { timeline?.seek(to: dur) }
            needsDisplay = true

        case 48:        // Tab / Shift+Tab → jump to adjacent keyframe across visible rows
            guard !isEditingKeyframe else { super.keyDown(with: event); return }
            seekAdjacentVisibleKeyframe(backward: event.modifierFlags.contains(.shift))

        case 123:       // Left arrow → always forward to viewport (incl. edit mode).
            forwardToViewport(event)

        case 124:       // Right arrow → always forward to viewport (incl. edit mode).
            forwardToViewport(event)

        case 3:         // F → nudge selected keyframe(s) one frame forward.
            guard !isEditingKeyframe else { super.keyDown(with: event); return }
            nudgeSelectedKeyframe(by: 1.0 / 30.0)

        case 11:        // B → nudge selected keyframe(s) one frame backward.
            guard !isEditingKeyframe else { super.keyDown(with: event); return }
            nudgeSelectedKeyframe(by: -1.0 / 30.0)

        case 0:         // A → align multi-selected keyframes to the earliest selected.
            guard !isEditingKeyframe else { super.keyDown(with: event); return }
            alignSelectedKeyframes()

        default:
            // Forward unrecognised keys to the viewport so shortcuts like
            // O / C / L / arrows still work while the timeline editor has focus.
            forwardToViewport(event)
        }
    }

    /// Forwards a key event to the viewport, guarded against ping-pong loops.
    private func forwardToViewport(_ event: NSEvent) {
        if let target = keyForwardTarget, !isReceivingForwardedKey {
            if let vp = target as? ViewportView {
                vp.isReceivingForwardedKey = true
                vp.keyDown(with: event)
                vp.isReceivingForwardedKey = false
            } else {
                target.keyDown(with: event)
            }
        } else {
            super.keyDown(with: event)
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
        selectedKFIndex    = nil
        // Keep selectedTrackIndex so the lane stays highlighted to match the
        // current selection after the edit ends.
        needsDisplay       = true
    }

    /// Selects the lane matching `ref` and the diamond at `time` (within 1 ms).
    /// Used to auto-highlight a freshly-stamped keyframe so the user can
    /// immediately nudge it with F / B without having to click it first.
    /// No-op if `ref` or the matching time can't be found (e.g. the timeline
    /// editor hasn't built a lane for this track yet).
    func selectKeyframe(ref: TrackRef, atTime time: Double) {
        let tracks = buildTracks()
        guard let ti = tracks.firstIndex(where: { $0.ref == ref }) else { return }
        let times = keyframeTimes(for: ref)
        guard let ki = times.firstIndex(where: { abs($0 - time) < 0.001 }) else { return }
        selectedTrackIndex = ti
        selectedKFIndex    = ki
        multiSelectedDiamonds.removeAll()
        needsDisplay       = true
    }

    /// Selects the lane matching `ref`.
    /// If the lane is already selected (e.g. because the user just clicked a diamond
    /// on it and `onLaneSelected` triggered a viewport mode change that bounced back
    /// here) the call is a no-op so the existing `selectedKFIndex` is preserved —
    /// without this guard, the round-trip clears the diamond and breaks drag.
    func selectTrack(_ ref: TrackRef) {
        let tracks = buildTracks()
        // If an object's own row isn't visible because it lives inside a collapsed
        // group, highlight that group's header row instead — so cycling (O) onto a
        // grouped object still shows the blue highlight rather than leaving the
        // header grey.
        var targetRef = ref
        if case .object(let i) = ref,
           !tracks.contains(where: { $0.ref == ref }),
           let gid = sceneManager?.objects[safe: i]?.groupID {
            targetRef = .group(gid)
        }
        guard let idx = tracks.firstIndex(where: { $0.ref == targetRef }) else { return }
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
            selectedKFIndex    = nil
            // Keep selectedTrackIndex so the lane stays highlighted to match the
            // current selection after the edit ends.
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
            selectedKFIndex    = nil
            // Keep selectedTrackIndex so the lane stays highlighted to match the
            // current selection after the edit ends.
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

    /// Selects all diamonds whose centre falls inside the completed rubber-band rectangle.
    /// If exactly one diamond is caught it becomes a normal single-select.
    /// If zero diamonds are caught nothing changes.
    private func finalizeRubberBandSelection(tracks: TrackList) {
        let bandRect = NSRect(
            x:      min(rubberBandStart.x, rubberBandCurrent.x),
            y:      min(rubberBandStart.y, rubberBandCurrent.y),
            width:  abs(rubberBandCurrent.x - rubberBandStart.x),
            height: abs(rubberBandCurrent.y - rubberBandStart.y)
        )
        // Ignore negligibly small drags (accidental Ctrl+clicks).
        guard bandRect.width > 4 && bandRect.height > 4 else { return }

        var found = Set<SelectedDiamond>()
        for (ti, row) in tracks.enumerated() {
            let cy = laneCenter(ti)
            for (ki, t) in keyframeTimes(for: row.ref).enumerated() {
                let cx = timeToX(t)
                if bandRect.contains(NSPoint(x: cx, y: cy)) {
                    found.insert(SelectedDiamond(trackIndex: ti, kfIndex: ki))
                }
            }
        }
        guard !found.isEmpty else { return }

        if found.count == 1, let only = found.first {
            // Single hit → normal single-select (no multi-select overlay).
            multiSelectedDiamonds.removeAll()
            select(trackIndex: only.trackIndex, kfIndex: only.kfIndex)
        } else {
            // Multi-hit → multi-select mode.
            multiSelectedDiamonds = found
            // Point single-select at the top-left-most caught diamond for reference.
            let first = found.sorted {
                $0.trackIndex < $1.trackIndex ||
                ($0.trackIndex == $1.trackIndex && $0.kfIndex < $1.kfIndex)
            }.first!
            select(trackIndex: first.trackIndex, kfIndex: first.kfIndex)
        }
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

        case .group(let gid):
            guard let track = sceneManager?.groupKeyframeTracks[gid],
                  let idx   = track.keyframes.firstIndex(where: { abs($0.time - fromTime) < 0.0005 })
            else { return }
            track.retimeKeyframe(at: idx, to: toTime)
        }
    }

    /// Applies a batch of keyframe moves, overwriting any non-moving keyframe that
    /// a move lands on.  Groups moves by lane so each track pulls its moving
    /// keyframes out and re-adds them (addKeyframe's 1-ms dedupe removes victims).
    /// Used by the discrete moves (single/group nudge, align); the live drag still
    /// uses applyRetime so it doesn't delete keyframes mid-drag.
    private func applyMovesOverwriting(_ moves: [(ref: TrackRef, oldTime: Double, newTime: Double)]) {
        var refs: [TrackRef] = []
        for m in moves where !refs.contains(m.ref) { refs.append(m.ref) }
        for ref in refs {
            let group = moves.filter { $0.ref == ref }
            let from  = group.map { $0.oldTime }
            let to    = group.map { $0.newTime }
            switch ref {
            case .camera:
                camera?.keyframeTrack?.moveKeyframes(from: from, to: to)
            case .object(let i):
                sceneManager?.objects[safe: i]?.keyframeTrack?.moveKeyframes(from: from, to: to)
            case .light(let i):
                if let lm = lightManager, i < lm.keyframeTracks.count {
                    lm.keyframeTracks[i]?.moveKeyframes(from: from, to: to)
                }
            case .group(let gid):
                sceneManager?.groupKeyframeTracks[gid]?.moveKeyframes(from: from, to: to)
            }
        }
    }

    private func deleteSelectedKeyframe(tracks: TrackList) {
        // ── Multi-select path ─────────────────────────────────────────────────
        if multiSelectedDiamonds.count >= 2 {
            // Collect (ref, time) pairs before mutating so stale kfIndex values
            // from intermediate re-sorts don't cause wrong deletions.
            var toDelete: [(ref: TrackRef, time: Double)] = []
            for d in multiSelectedDiamonds {
                guard d.trackIndex < tracks.count else { continue }
                let ref   = tracks[d.trackIndex].ref
                let times = keyframeTimes(for: ref)
                guard d.kfIndex < times.count else { continue }
                toDelete.append((ref, times[d.kfIndex]))
            }
            for pair in toDelete { removeKeyframe(ref: pair.ref, atTime: pair.time) }
            multiSelectedDiamonds.removeAll()
            selectedKFIndex = nil
            needsDisplay    = true
            onKeyframeDeleted?()
            print("[DEBUG] TimelineEditorView: deleted \(toDelete.count) keyframes (multi-select)")
            return
        }

        // ── Single-select path ────────────────────────────────────────────────
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
        case .group(let gid):
            guard let track = sceneManager?.groupKeyframeTracks[gid] else { break }
            track.removeKeyframe(at: ki)
        }
        selectedKFIndex = nil
        needsDisplay    = true
        onKeyframeDeleted?()
        print("[DEBUG] TimelineEditorView: deleted keyframe lane=\(ti) kf=\(ki)")
    }

    /// Removes the keyframe nearest to `time` on the given track.
    /// Identified by time rather than index so it remains correct even after
    /// earlier deletions in the same batch have shifted indices.
    private func removeKeyframe(ref: TrackRef, atTime time: Double) {
        let eps: Double = 0.0005
        switch ref {
        case .camera:
            guard let track = camera?.keyframeTrack,
                  let idx   = track.keyframes.firstIndex(where: { abs($0.time - time) < eps })
            else { return }
            track.removeKeyframe(at: idx)
        case .object(let i):
            guard let track = sceneManager?.objects[safe: i]?.keyframeTrack,
                  let idx   = track.keyframes.firstIndex(where: { abs($0.time - time) < eps })
            else { return }
            track.removeKeyframe(at: idx)
        case .light(let i):
            guard let lm    = lightManager,
                  i < lm.keyframeTracks.count,
                  let track = lm.keyframeTracks[i],
                  let idx   = track.keyframes.firstIndex(where: { abs($0.time - time) < eps })
            else { return }
            track.removeKeyframe(at: idx)
        case .group(let gid):
            guard let track = sceneManager?.groupKeyframeTracks[gid],
                  let idx   = track.keyframes.firstIndex(where: { abs($0.time - time) < eps })
            else { return }
            track.removeKeyframe(at: idx)
        }
    }

    private func insertKeyframeInSelectedLane(tracks: TrackList) {
        guard let ti = selectedTrackIndex else { return }
        let ref = tracks[ti].ref
        switch ref {
        case .camera:        onInsertCameraKeyframe?()
        case .object(let i): onInsertObjectKeyframe?(i)
        case .light(let i):  onInsertLightKeyframe?(i)
        case .group(let gid): onInsertGroupKeyframe?(gid)
        }
        // The stamp call above triggers ViewportView.onKeyframeStamped, which
        // AppDelegate routes back to `selectKeyframe(ref:atTime:)` — so the new
        // diamond is highlighted automatically.  Subsequent F / B nudges target
        // it immediately.  Ruler clicks safely deselect via mouseDown, and
        // mouseDragged only drags diamonds when mouseDownOnDiamond is true,
        // so an auto-selected diamond won't get attached to a ruler-scrub drag.
        needsDisplay = true
        let t = timeline?.currentTime ?? 0
        print("[DEBUG] TimelineEditorView: inserted keyframe at t=\(String(format: "%.3f", t))"
            + " lane=\(ti)")
    }

    /// Seeks the playhead to the keyframe before or after the current time on the
    /// selected lane.  Used by Tab / Shift+Tab in keyDown.
    /// Seeks the playhead to the next / previous keyframe across every row that is
    /// currently visible on screen — disclosed (collapsed-group parts are absent
    /// from buildTracks()) and within the scroll viewport, below the floating
    /// ruler header.  Public so the viewport's Tab can share this behaviour.
    func seekAdjacentVisibleKeyframe(backward: Bool) {
        let tracks = buildTracks()
        // Visible content area = the scroll viewport minus the floating header band.
        let vis        = visibleRect
        let contentTop = vis.minY + rulerHeight
        var times: [Double] = []
        for (i, row) in tracks.enumerated() {
            let top = laneTop(i)
            let bot = top + laneHeight
            guard bot > contentTop && top < vis.maxY else { continue }   // on-screen rows only
            times.append(contentsOf: keyframeTimes(for: row.ref))
        }
        guard !times.isEmpty else { return }
        times.sort()
        let cur = timeline?.currentTime ?? 0
        let eps = 1.0 / (timeline?.frameRate ?? 30.0) / 2
        if backward {
            if let t = times.last(where: { $0 < cur - eps }) {
                timeline?.seek(to: t)
                needsDisplay = true
            }
        } else {
            if let t = times.first(where: { $0 > cur + eps }) {
                timeline?.seek(to: t)
                needsDisplay = true
            }
        }
    }

    /// Called by ViewportView when F or B is pressed while the viewport has focus.
    func nudgeSelectedKeyframe(by delta: Double) {
        let tracks = buildTracks()
        if multiSelectedDiamonds.count >= 2 {
            nudgeMultiSelected(by: delta, tracks: tracks)
        } else {
            nudgeSelected(by: delta, tracks: tracks)
        }
    }

    /// Moves every keyframe in the multi-selection by `delta` (one frame per F/B
    /// press), clamped to [0, duration], keeping their relative spacing.  Mirrors
    /// the multi-diamond drag: snapshot times first, retime, then rebuild the set.
    private func nudgeMultiSelected(by delta: Double, tracks: TrackList) {
        let maxT = timeline?.duration ?? Double.infinity
        var entries: [(ref: TrackRef, oldTime: Double)] = []
        for d in multiSelectedDiamonds {
            guard d.trackIndex < tracks.count else { continue }
            let ref   = tracks[d.trackIndex].ref
            let times = keyframeTimes(for: ref)
            guard d.kfIndex < times.count else { continue }
            entries.append((ref, times[d.kfIndex]))
        }
        guard !entries.isEmpty else { return }

        let moves = entries.map { (ref: $0.ref, oldTime: $0.oldTime,
                                   newTime: max(0, min(maxT, $0.oldTime + delta))) }
        applyMovesOverwriting(moves)

        // Rebuild selection with post-move indices.
        var updated = Set<SelectedDiamond>()
        for m in moves {
            if let ti = tracks.firstIndex(where: { $0.ref == m.ref }) {
                let times = keyframeTimes(for: m.ref)
                if let ki = times.firstIndex(where: { abs($0 - m.newTime) < 0.0005 }) {
                    updated.insert(SelectedDiamond(trackIndex: ti, kfIndex: ki))
                }
            }
        }
        multiSelectedDiamonds = updated
        needsDisplay = true
    }

    /// Aligns the multi-selection to a common time (the earliest selected), so
    /// keyframes across lanes line up vertically.  Aborts (with a beep) if any
    /// single lane has more than one selected keyframe.
    private func alignSelectedKeyframes() {
        guard multiSelectedDiamonds.count >= 2 else { return }
        let tracks = buildTracks()

        var seenTracks = Set<Int>()
        var entries: [(ref: TrackRef, oldTime: Double)] = []
        for d in multiSelectedDiamonds {
            guard d.trackIndex < tracks.count else { continue }
            guard seenTracks.insert(d.trackIndex).inserted else {
                NSSound.beep()
                print("[DEBUG] TimelineEditorView: align aborted — a lane has >1 selected keyframe")
                return
            }
            let ref   = tracks[d.trackIndex].ref
            let times = keyframeTimes(for: ref)
            guard d.kfIndex < times.count else { continue }
            entries.append((ref, times[d.kfIndex]))
        }
        guard entries.count >= 2 else { return }

        // Snap to the earliest selected time.
        let target = entries.map { $0.oldTime }.min() ?? 0
        let moves  = entries.filter { abs($0.oldTime - target) > 0.0005 }
                            .map { (ref: $0.ref, oldTime: $0.oldTime, newTime: target) }
        applyMovesOverwriting(moves)

        var updated = Set<SelectedDiamond>()
        for e in entries {
            if let ti = tracks.firstIndex(where: { $0.ref == e.ref }) {
                let times = keyframeTimes(for: e.ref)
                if let ki = times.firstIndex(where: { abs($0 - target) < 0.0005 }) {
                    updated.insert(SelectedDiamond(trackIndex: ti, kfIndex: ki))
                }
            }
        }
        multiSelectedDiamonds = updated
        timeline?.seek(to: target)
        needsDisplay = true
        print("[DEBUG] TimelineEditorView: aligned \(entries.count) keyframes to t="
            + String(format: "%.3f", target))
    }

    private func nudgeSelected(by delta: Double, tracks: TrackList) {
        guard let ti = selectedTrackIndex, let ki = selectedKFIndex else { return }
        let ref   = tracks[ti].ref
        let times = keyframeTimes(for: ref)
        guard ki < times.count else { return }

        let oldTime = times[ki]
        let maxT    = timeline?.duration ?? Double.infinity
        let newTime = max(0, min(maxT, oldTime + delta))

        applyMovesOverwriting([(ref, oldTime, newTime)])

        let updatedTimes = keyframeTimes(for: ref)
        selectedKFIndex  = updatedTimes.firstIndex { abs($0 - newTime) < 0.0005 }

        timeline?.seek(to: newTime)
        needsDisplay = true
    }

    // MARK: - Copy / Paste

    /// Copies the selected diamond(s) to the appropriate clipboard.
    /// With ≥2 diamonds in multiSelectedDiamonds, fills multiClipboard with
    /// pose + relative-time-offset entries.  Otherwise copies the single
    /// selected diamond's pose to clipboardKeyframe.
    private func copySelectedKeyframe(tracks: TrackList) {
        // ── Multi-select path ─────────────────────────────────────────────────
        if multiSelectedDiamonds.count >= 2 {
            var entries: [(clip: ClipboardKeyframe, time: Double, ref: TrackRef)] = []
            for d in multiSelectedDiamonds {
                guard d.trackIndex < tracks.count else { continue }
                let ref   = tracks[d.trackIndex].ref
                let times = keyframeTimes(for: ref)
                guard d.kfIndex < times.count else { continue }
                let t = times[d.kfIndex]
                switch ref {
                case .camera:
                    guard let kf = camera?.keyframeTrack?.keyframes[safe: d.kfIndex] else { continue }
                    entries.append((.camera(kf), t, ref))
                case .object(let i):
                    guard let kf = sceneManager?.objects[safe: i]?
                                      .keyframeTrack?.keyframes[safe: d.kfIndex] else { continue }
                    entries.append((.object(kf), t, ref))
                case .light(let i):
                    guard let lm = lightManager, i < lm.keyframeTracks.count,
                          let kf = lm.keyframeTracks[i]?.keyframes[safe: d.kfIndex] else { continue }
                    entries.append((.light(kf), t, ref))
                case .group(let gid):
                    guard let kf = sceneManager?.groupKeyframeTracks[gid]?
                                      .keyframes[safe: d.kfIndex] else { continue }
                    entries.append((.group(kf), t, ref))
                }
            }
            guard !entries.isEmpty else { return }
            let minTime = entries.map { $0.time }.min()!
            multiClipboard    = entries.map {
                MultiClipEntry(clip: $0.clip, timeOffset: $0.time - minTime, ref: $0.ref)
            }
            clipboardKeyframe = nil   // single clipboard is stale after a multi-copy
            print("[DEBUG] TimelineEditorView: Cmd+C — copied \(multiClipboard.count)"
                + " diamonds (multi-select)")
            return
        }

        // ── Single-select path ────────────────────────────────────────────────
        multiClipboard.removeAll()
        guard let ti = selectedTrackIndex, let ki = selectedKFIndex else {
            print("[DEBUG] TimelineEditorView: Cmd+C — no diamond selected")
            return
        }
        let ref = tracks[ti].ref
        switch ref {
        case .camera:
            guard let kf = camera?.keyframeTrack?.keyframes[safe: ki] else { return }
            clipboardKeyframe = .camera(kf)
        case .object(let i):
            guard let kf = sceneManager?.objects[safe: i]?
                              .keyframeTrack?.keyframes[safe: ki] else { return }
            clipboardKeyframe = .object(kf)
        case .light(let i):
            guard let lm = lightManager,
                  i < lm.keyframeTracks.count,
                  let kf = lm.keyframeTracks[i]?.keyframes[safe: ki] else { return }
            clipboardKeyframe = .light(kf)
        case .group(let gid):
            guard let kf = sceneManager?.groupKeyframeTracks[gid]?
                              .keyframes[safe: ki] else { return }
            clipboardKeyframe = .group(kf)
        }
        print("[DEBUG] TimelineEditorView: Cmd+C — copied \(clipboardKeyframe!.typeName)"
            + " keyframe from lane=\(ti) kf=\(ki)")
    }

    /// Pastes the clipboard pose(s) at the current playhead.
    /// With a non-empty multiClipboard, stamps all entries back to their
    /// original tracks at currentTime + each entry's time offset.
    /// Otherwise pastes the single clipboardKeyframe onto the selected lane.
    private func pasteKeyframe(tracks: TrackList) {
        // ── Multi-clipboard path ───────────────────────────────────────────────
        if !multiClipboard.isEmpty {
            let baseT = timeline?.currentTime ?? 0
            let maxT  = timeline?.duration ?? Double.infinity
            for entry in multiClipboard {
                let t = max(0, min(maxT, baseT + entry.timeOffset))
                pasteClip(entry.clip, to: entry.ref, at: t)
            }
            selectedKFIndex = nil
            needsDisplay    = true
            onKeyframePasted?()
            print("[DEBUG] TimelineEditorView: Cmd+V — pasted \(multiClipboard.count)"
                + " diamonds (multi-clipboard)")
            return
        }

        // ── Single-clipboard path ─────────────────────────────────────────────
        guard let clip = clipboardKeyframe else {
            print("[DEBUG] TimelineEditorView: Cmd+V — clipboard empty")
            return
        }
        guard let ti = selectedTrackIndex else {
            print("[DEBUG] TimelineEditorView: Cmd+V — no lane selected")
            return
        }
        let t   = timeline?.currentTime ?? 0
        let ref = tracks[ti].ref

        switch (clip, ref) {

        // ── Camera ────────────────────────────────────────────────────────────
        case (.camera(let src), .camera):
            if camera?.keyframeTrack == nil { camera?.keyframeTrack = CameraKeyframeTrack() }
            // Preserve follow metadata so a copied follow keyframe pastes as a
            // follow keyframe, not a free camera keyframe.
            camera?.keyframeTrack?.addKeyframe(CameraKeyframe(
                time:               t,
                yaw:                src.yaw,
                pitch:              src.pitch,
                distance:           src.distance,
                target:             src.target,
                fov:                src.fov,
                followTargetName:   src.followTargetName,
                followYawOffset:    src.followYawOffset,
                followPitchOffset:  src.followPitchOffset,
                targetOffset:       src.targetOffset,
                followForwardLocal: src.followForwardLocal))

        // ── Object (any object lane accepts an object clipboard) ──────────────
        case (.object(let src), .object(let i)):
            guard let obj = sceneManager?.objects[safe: i] else { return }
            if obj.keyframeTrack == nil { obj.keyframeTrack = KeyframeTrack() }
            obj.keyframeTrack?.addKeyframe(TransformKeyframe(
                time:        t,
                translation: src.translation,
                rotation:    src.rotation,
                scale:       src.scale))

        // ── Light (any light lane accepts a light clipboard) ──────────────────
        case (.light(let src), .light(let i)):
            guard let lm = lightManager, i < lm.keyframeTracks.count else { return }
            if lm.keyframeTracks[i] == nil { lm.keyframeTracks[i] = LightKeyframeTrack() }
            lm.keyframeTracks[i]?.addKeyframe(LightKeyframe(
                time:          t,
                intensity:     src.intensity,
                color:         src.color,
                direction:     src.direction,
                position:      src.position,
                range:         src.range,
                beamThickness: src.beamThickness))

        // ── Group (any group lane accepts a group clipboard) ──────────────────
        case (.group(let src), .group(let gid)):
            if sceneManager?.groupKeyframeTracks[gid] == nil {
                sceneManager?.groupKeyframeTracks[gid] = KeyframeTrack()
            }
            sceneManager?.groupKeyframeTracks[gid]?.addKeyframe(TransformKeyframe(
                time:        t,
                translation: src.translation,
                rotation:    src.rotation,
                scale:       src.scale))

        default:
            print("[DEBUG] TimelineEditorView: Cmd+V — type mismatch"
                + " (clipboard=\(clip.typeName) lane=\(ref))")
            return
        }

        // Don't auto-select the pasted diamond (consistent with insert behaviour).
        selectedKFIndex = nil
        needsDisplay    = true
        onKeyframePasted?()
        print("[DEBUG] TimelineEditorView: Cmd+V — pasted \(clip.typeName)"
            + " keyframe at t=\(String(format: "%.3f", t)) lane=\(ti)")
    }

    /// Stamps a single ClipboardKeyframe onto the given track at the given time.
    /// Used by the multi-clipboard paste path to avoid duplicating the switch logic.
    private func pasteClip(_ clip: ClipboardKeyframe, to ref: TrackRef, at t: Double) {
        switch (clip, ref) {
        case (.camera(let src), .camera):
            if camera?.keyframeTrack == nil { camera?.keyframeTrack = CameraKeyframeTrack() }
            // Preserve follow metadata so a copied follow keyframe pastes as a
            // follow keyframe, not a free camera keyframe.
            camera?.keyframeTrack?.addKeyframe(CameraKeyframe(
                time:               t,
                yaw:                src.yaw,
                pitch:              src.pitch,
                distance:           src.distance,
                target:             src.target,
                fov:                src.fov,
                followTargetName:   src.followTargetName,
                followYawOffset:    src.followYawOffset,
                followPitchOffset:  src.followPitchOffset,
                targetOffset:       src.targetOffset,
                followForwardLocal: src.followForwardLocal))
        case (.object(let src), .object(let i)):
            guard let obj = sceneManager?.objects[safe: i] else { return }
            if obj.keyframeTrack == nil { obj.keyframeTrack = KeyframeTrack() }
            obj.keyframeTrack?.addKeyframe(TransformKeyframe(
                time:        t,
                translation: src.translation,
                rotation:    src.rotation,
                scale:       src.scale))
        case (.light(let src), .light(let i)):
            guard let lm = lightManager, i < lm.keyframeTracks.count else { return }
            if lm.keyframeTracks[i] == nil { lm.keyframeTracks[i] = LightKeyframeTrack() }
            lm.keyframeTracks[i]?.addKeyframe(LightKeyframe(
                time:          t,
                intensity:     src.intensity,
                color:         src.color,
                direction:     src.direction,
                position:      src.position,
                range:         src.range,
                beamThickness: src.beamThickness))
        case (.group(let src), .group(let gid)):
            if sceneManager?.groupKeyframeTracks[gid] == nil {
                sceneManager?.groupKeyframeTracks[gid] = KeyframeTrack()
            }
            sceneManager?.groupKeyframeTracks[gid]?.addKeyframe(TransformKeyframe(
                time:        t,
                translation: src.translation,
                rotation:    src.rotation,
                scale:       src.scale))
        default:
            print("[DEBUG] TimelineEditorView: pasteClip — type mismatch for ref=\(ref)")
        }
    }

    // MARK: - Easing popups

    /// Creates or refreshes per-object easing popup buttons in the label column.
    /// Called from the refresh timer; only rebuilds subviews when needed.
    private func syncEasingPopupsIfNeeded() {
        guard let sm = sceneManager else { return }
        let objCount     = sm.objects.count
        let needsRebuild = objCount != lastObjectCount
                        || bounds   != lastBounds
                        || expandedGroups != lastExpandedGroups
        lastObjectCount     = objCount
        lastBounds          = bounds
        lastExpandedGroups  = expandedGroups

        if needsRebuild {
            rebuildEasingPopups()
        } else {
            // Lightweight pass: just keep selected item in sync with the track.
            for popup in easingPopups {
                let i = popup.tag
                guard i < sm.objects.count else { continue }
                let mode = sm.objects[i].keyframeTrack?.easingMode ?? .linear
                if popup.selectedItem?.tag != mode.rawValue {
                    popup.selectItem(withTag: mode.rawValue)
                }
            }
        }
    }

    private func rebuildEasingPopups() {
        easingPopups.forEach { $0.removeFromSuperview() }
        easingPopups.removeAll()

        guard let sm = sceneManager else { return }

        // Layout constants — popup sits in the right portion of the label column.
        let popupW: CGFloat = 58   // slightly narrower than before to fit wider labelWidth
        let popupH: CGFloat = 18
        let popupX: CGFloat = labelWidth - popupW - 3

        // Walk the current track list so each popup lands on the correct lane,
        // regardless of group expansion state.  All object rows (standalone or
        // expanded part) get a popup so the user can set easing per part.
        let tracks = buildTracks()
        for (trackIndex, row) in tracks.enumerated() {
            // Easing popups appear on all object rows (standalone and indented parts).
            guard case .object(let i) = row.ref else { continue }
            guard i < sm.objects.count else { continue }
            let obj    = sm.objects[i]
            let popupY = laneTop(trackIndex) + (laneHeight - popupH) / 2

            let popup = NSPopUpButton(frame: NSRect(x: popupX, y: popupY,
                                                    width: popupW, height: popupH),
                                      pullsDown: false)
            // Use darkAqua appearance so the button renders with light text on a
            // dark background, matching the label column's colour scheme.
            popup.appearance  = NSAppearance(named: .darkAqua)
            popup.bezelStyle  = .inline
            popup.font        = NSFont.systemFont(ofSize: 9, weight: .regular)
            popup.isBordered  = false
            popup.tag         = i   // encodes object index for the action handler

            for mode in EasingMode.allCases {
                popup.addItem(withTitle: mode.displayName)
                popup.lastItem?.tag = mode.rawValue
            }
            let current = obj.keyframeTrack?.easingMode ?? .linear
            popup.selectItem(withTag: current.rawValue)

            popup.target = self
            popup.action = #selector(easingPopupChanged(_:))

            addSubview(popup)
            easingPopups.append(popup)
        }
    }

    @objc private func easingPopupChanged(_ sender: NSPopUpButton) {
        let objectIndex = sender.tag
        guard let mode = EasingMode(rawValue: sender.selectedItem?.tag ?? 0),
              let obj  = sceneManager?.objects[safe: objectIndex] else { return }
        obj.keyframeTrack?.easingMode = mode
        print("[DEBUG] TimelineEditorView: object \(objectIndex) easing → \(mode.displayName)")
    }
}
