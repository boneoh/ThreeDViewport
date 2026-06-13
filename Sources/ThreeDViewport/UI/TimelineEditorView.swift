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
    case fog(AtmosphereKeyframe)
    case particles(AtmosphereKeyframe)

    /// Human-readable description shown in debug logs.
    var typeName: String {
        switch self {
        case .object:    return "object"
        case .camera:    return "camera"
        case .light:     return "light"
        case .group:     return "group"
        case .fog:       return "fog"
        case .particles: return "particles"
        }
    }
}

// MARK: - Track reference
// Internal so AppDelegate can pattern-match in edit-mode callbacks.

enum TrackRef: Equatable, Hashable {
    case camera
    case object(Int)   // index into sceneManager.objects
    case light(Int)    // index into LightManager.lights
    case group(Int)    // groupID — multi-part model header row
    case fog            // the fog volume (single instance)
    case particles(Int) // index into ParticleManager.emitters
    case importBundle(Int) // import-bundle ID — display-only collapsible header (Part B)
}

// One row in the timeline label/track area.
// Replaces the old (name: String, ref: TrackRef) tuple.
struct TrackRow {
    var name:          String
    var ref:           TrackRef
    /// True for collapsed/expanded group-header rows (groups, envelopes, bundles).
    var isGroupHeader: Bool  = false
    /// Nesting depth for the label column (0 = top level).  1 = a group/envelope part
    /// or a bundle member; 2 = a part nested under a bundled group/envelope.
    var indentLevel:   Int   = 0
}

// MARK: - Coordinate channel paste (Part B2)

/// A spatial channel that can be pasted into a keyframe from the coordinate clipboard.
private enum CoordChannel {
    case position, size, target
    var menuTitle: String {
        switch self {
        case .position:  return "Paste Position"
        case .size:      return "Paste Size"
        case .target:    return "Paste Target"
        }
    }
}

/// Carried by a context-menu item so the action knows which keyframe + channel to write.
private final class ChannelPasteRequest {
    let ref: TrackRef
    let kfIndex: Int
    let channel: CoordChannel
    init(ref: TrackRef, kfIndex: Int, channel: CoordChannel) {
        self.ref = ref; self.kfIndex = kfIndex; self.channel = channel
    }
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
                .sink { [weak self] _ in self?.playheadTick() }
        }
    }
    /// Cancellable for the currentTime subscription; lives as long as the view.
    private var timeSubscription: AnyCancellable?

    // Redraw coalescing for the playhead.  Redrawing all lanes is the dominant
    // main-thread cost with a complex scene, so during PLAYBACK we cap the
    // timeline's redraw rate (the playhead still reads smooth at ~12 Hz).  While
    // paused/scrubbing every tick redraws so dragging the playhead stays crisp.
    private var lastPlaybackRedraw: CFTimeInterval = 0
    private let playbackRedrawInterval: CFTimeInterval = 1.0 / 12.0

    private func playheadTick() {
        if timeline?.isPlaying == true {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastPlaybackRedraw < playbackRedrawInterval { return }
            lastPlaybackRedraw = now
        }
        needsDisplay = true
    }

    // Cached lane model from buildTracks().  Rebuilt only when the scene STRUCTURE
    // changes (objects/lights/emitters added·removed·renamed, group/bundle nesting,
    // expand/collapse) — never when the playhead moves — so playback redraws skip
    // the expensive rebuild (sorting + per-row displayName/groupName lookups).
    private var cachedTrackList: TrackList?

    /// Drop the cached lane model so the next buildTracks() rebuilds it.  Called at
    /// every structural-change point (see updateWindowHeight, expand/collapse, rename).
    func invalidateTrackCache() { cachedTrackList = nil }

    weak var sceneManager: SceneManager?
    weak var camera:       CameraController?
    weak var lightManager: LightManager?
    weak var fogSettings:     FogSettings?
    weak var particleManager: ParticleManager?
    /// Coordinate clipboard (Part B1): copying a light/atmosphere keyframe also
    /// captures its spatial channels so they can be pasted into panel fields.
    weak var coordinateClipboard: CoordinateClipboard?

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

    /// Called when the user presses Insert with the Fog / a Weather lane selected.
    var onInsertFogKeyframe: (() -> Void)?
    var onInsertParticleKeyframe: ((Int) -> Void)?

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

    /// Called when the user picks Delete from a row's right-click menu.  AppDelegate
    /// confirms + performs the deletion and refreshes.
    var onDeleteRow: ((TrackRef) -> Void)?

    /// Called from a bundle header's "Extend Spin/Orbit to End" item with the bundle ID.
    var onExtendBundleSpinOrbit: ((Int) -> Void)?

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

    private let labelWidth:      CGFloat = 360
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
    /// Horizontal shift per nesting level in the label column (bundle ▸ group ▸ part).
    private let indentStep:      CGFloat = 12
    /// Width of each lane's easing-mode dropdown in the right of the label column.
    private let easingPopupW:    CGFloat = 58

    /// Zoom: pixels per second.  `nil` = fit the whole timeline into the visible
    /// width (no horizontal scrolling).  Non-nil = a fixed scale that can be wider
    /// than the viewport, in which case the horizontal scroller appears.
    private var userPixelsPerSecond: CGFloat? = nil

    /// True while a mouse button is held down inside the editor, so playhead-follow
    /// auto-scroll stays out of the way of drag-scrubbing / diamond drags.
    private var isMouseDownInView = false
    /// Last playhead time the auto-scroll acted on, so it only follows when the
    /// playhead actually moves (lets the user pan freely while paused).
    private var lastFollowTime: Double = .nan

    /// Width of the visible track viewport (the scroll view's clip view), not the
    /// document view — which can be wider than the viewport when zoomed in.
    private var viewportWidth: CGFloat {
        enclosingScrollView?.contentView.bounds.width ?? bounds.width
    }

    /// Fit-to-window scale: the whole timeline spans the visible track area.
    private var fitPxPerSecond: CGFloat {
        let trackWidth = max(1, viewportWidth - labelWidth - rightPad)
        let dur        = max(0.001, timeline?.duration ?? 10.0)
        return trackWidth / CGFloat(dur)
    }

    /// Tightest zoom: ~1 second fills the visible track area.
    private var maxPxPerSecond: CGFloat {
        max(fitPxPerSecond, max(1, viewportWidth - labelWidth - rightPad))
    }

    /// Effective pixels-per-second used by all time↔x mapping.
    private var pxPerSecond: CGFloat {
        if let pps = userPixelsPerSecond { return min(maxPxPerSecond, max(fitPxPerSecond, pps)) }
        return fitPxPerSecond
    }

    /// Left edge (in document coords) of the frozen label column — the scroll
    /// view's current horizontal offset, so the labels stay pinned while panning.
    private var labelOriginX: CGFloat { visibleRect.minX }
    /// Right edge of the frozen label column in document coords (label↔track boundary).
    private var labelRightX:  CGFloat { visibleRect.minX + labelWidth }

    // MARK: - Zoom

    private let zoomStep: CGFloat = 1.6

    /// Resizes the document view so its width matches the current zoom (label column
    /// + timeline at `pxPerSecond` + right pad), or the viewport width when that is
    /// larger (fit zoom).  Drives whether the horizontal scroller appears.
    func updateDocumentWidth() {
        let dur     = max(0.001, timeline?.duration ?? 10.0)
        let needed  = labelWidth + CGFloat(dur) * pxPerSecond + rightPad
        let target  = max(viewportWidth, needed)
        if abs(frame.width - target) > 0.5 {
            var f = frame; f.size.width = target; frame = f
        }
    }

    func zoomIn() {
        userPixelsPerSecond = min(maxPxPerSecond, pxPerSecond * zoomStep)
        applyZoom(centerPlayhead: true)
    }

    func zoomOut() {
        let next = pxPerSecond / zoomStep
        userPixelsPerSecond = next <= fitPxPerSecond ? nil : next   // snap back to fit
        applyZoom(centerPlayhead: true)
    }

    /// Zoom out until the whole timeline fits the viewport (no horizontal scroll).
    func zoomToFit() {
        userPixelsPerSecond = nil
        applyZoom(centerPlayhead: false)
        scrollToVisible(NSRect(x: 0, y: visibleRect.minY, width: 1, height: visibleRect.height))
    }

    /// Zoom in to the tightest level (~1 second across the track area).
    func zoomToMax() {
        userPixelsPerSecond = maxPxPerSecond
        applyZoom(centerPlayhead: true)
    }

    private func applyZoom(centerPlayhead: Bool) {
        updateDocumentWidth()
        if centerPlayhead { scrollPlayheadToCenter() }
        lastFollowTime = .nan        // re-arm follow after a zoom
        needsDisplay = true
    }

    /// Keeps the playhead on screen while it MOVES (playback or scrubbing from the
    /// transport bar), by scrolling the track area horizontally.  Skipped while the
    /// user is interacting inside the editor (so drag-scrubbing isn't fought) and
    /// while paused with a still playhead (so panning around stays put).
    func followPlayheadIfNeeded() {
        guard !isMouseDownInView, let t = timeline?.currentTime else { return }
        guard t != lastFollowTime else { return }       // only when the playhead moved
        lastFollowTime = t
        guard frame.width > viewportWidth + 1 else { return }   // only when scrollable

        let phX       = timeToX(t)
        let leftEdge  = visibleRect.minX + labelWidth
        let rightEdge = visibleRect.maxX
        let margin: CGFloat = 24
        guard phX < leftEdge + margin || phX > rightEdge - margin else { return }

        // Page the view so the playhead sits ~20% in from the left of the track area.
        let trackW   = max(1, viewportWidth - labelWidth)
        let maxOrigin = max(0, frame.width - viewportWidth)
        let originX  = min(maxOrigin, max(0, phX - labelWidth - trackW * 0.2))
        scrollHorizontally(to: originX)
    }

    private func scrollHorizontally(to originX: CGFloat) {
        guard let clip = enclosingScrollView?.contentView else { return }
        var o = clip.bounds.origin
        guard abs(o.x - originX) > 0.5 else { return }
        o.x = originX
        clip.scroll(to: o)
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    /// Scrolls horizontally so the playhead sits near the middle of the track area
    /// (clamped to the document), keeping the current vertical position.
    private func scrollPlayheadToCenter() {
        let phX     = timeToX(timeline?.currentTime ?? 0)
        let half    = max(0, (viewportWidth - labelWidth) / 2)
        let targetX = max(0, phX - labelWidth - half)
        scrollToVisible(NSRect(x: targetX + labelWidth, y: visibleRect.minY,
                               width: viewportWidth - labelWidth, height: visibleRect.height))
    }

    // ── Selection state ───────────────────────────────────────────────────────

    /// Index of the currently selected lane.  nil = nothing selected.
    private var selectedTrackIndex: Int? = nil

    /// Index of the selected diamond within its lane.
    /// nil = lane selected but no diamond; only valid when selectedTrackIndex != nil.
    private var selectedKFIndex: Int? = nil

    /// The `TrackRef` of the currently selected lane, or nil if nothing is selected.
    /// Used by the Path Animator helper to know which entity to animate.
    var selectedTrackRef: TrackRef? {
        guard let i = selectedTrackIndex else { return nil }
        let t = buildTracks()
        guard i >= 0, i < t.count else { return nil }
        return t[i].ref
    }

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

    // ── Bundle move-as-unit drag (Part B2) ────────────────────────────────────
    // Dragging an import-bundle header's span bar shifts every member track's
    // keyframes by the same (frame-snapped) dt.
    private var isBundleDragging:     Bool       = false
    private var bundleDragRefs:       [TrackRef] = []   // member tracks being shifted
    private var bundleDragMouseStartX: CGFloat   = 0
    private var bundleDragMinT:        Double    = 0    // span min at drag start (start clamp)
    private var bundleDragAppliedDt:   Double    = 0    // dt already applied to the tracks
    private var bundleDragBid:         Int?      = nil  // bundle being dragged (for loop update)

    // ── Multi-clipboard (Cmd+C / Cmd+V with multi-select) ─────────────────────
    // Each entry stores a pose snapshot, a time offset relative to the earliest
    // copied diamond, and the original track reference for paste-back.
    private struct MultiClipEntry {
        var clip:       ClipboardKeyframe
        var timeOffset: Double   // seconds relative to the earliest copied diamond
        var ref:        TrackRef
    }
    private var multiClipboard: [MultiClipEntry] = []

    // System-pasteboard changeCount captured at our last copy.  If the live
    // changeCount differs at paste time, another app instance copied more recently,
    // so we prefer the pasteboard over our own in-memory clipboard (CI-2).
    private var clipboardChangeCount: Int = -1

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

    // Expanded header rows, keyed by the header's own ref so multi-part model groups
    // (.group) and glued envelopes (.object) can both be collapsed/expanded.
    private var expandedHeaders:     Set<TrackRef> = []

    // Import-bundle IDs already shown once — a new bundle is expanded on first
    // appearance, then remembers the user's collapse/expand toggle (Part B).
    private var seenBundles:         Set<Int> = []
    private var lastExpandedHeaders: Set<TrackRef> = []

    // ── Easing popup buttons ──────────────────────────────────────────────────
    // One NSPopUpButton per object lane, positioned in the right half of the label
    // column.  Rebuilt whenever the object count, expansion state, or view bounds change.

    /// Each easing popup is bound to its row's `TrackRef` so we know whether to
    /// read/write `obj.keyframeTrack.easingMode` (`.object`) or
    /// `sceneManager.groupKeyframeTracks[gid].easingMode` (`.group`).
    private struct EasingPopupBinding {
        let popup: NSPopUpButton
        let ref:   TrackRef     // either .object(i) or .group(gid)
    }
    private var easingPopups:    [EasingPopupBinding] = []
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
            self?.updateDocumentWidth()   // tracks duration / viewport changes (guarded, cheap)
            self?.followPlayheadIfNeeded()
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

    /// Timeline label for a light lane: "Light N - <Type>" (mirrors the weather
    /// lanes showing their type); falls back to "Light N" if the type is unavailable.
    private func lightLaneName(_ i: Int) -> String {
        guard let type = lightManager?.lights[safe: i]?.type.displayName else { return "Light \(i + 1)" }
        return "Light \(i + 1) - \(type)"
    }

    /// Track list sorted alphabetically (natural order) by display name across
    /// every row type — Camera, standalone objects, multi-part model groups, and
    /// lights are all folded into one A→Z list.  Multi-part models appear as a
    /// single collapsible header row (sorted by group name); expanding it shows
    /// per-part rows sorted A→Z directly beneath the header.
    /// Returns the lane model, rebuilding it only when the cache was invalidated
    /// by a structural change.  Cheap on the hot path (playback / scrub redraws).
    private func buildTracks() -> TrackList {
        if let cached = cachedTrackList { return cached }
        let list = rebuildTrackList()
        cachedTrackList = list
        return list
    }

    private func rebuildTrackList() -> TrackList {
        let objects    = sceneManager?.objects ?? []
        let lightCount = lightManager?.lights.count ?? 0
        let emitters   = particleManager?.emitters ?? []

        // Index group parts by groupID (preserving each part's global index).
        var groupOrder: [Int: [(idx: Int, obj: SceneObject)]] = [:]
        for (i, obj) in objects.enumerated() {
            if let gid = obj.groupID {
                groupOrder[gid, default: []].append((i, obj))
            }
        }

        // Index a glued envelope's direct simple members (parentIndex → envelope,
        // no groupID) so they can nest under the envelope like group parts.
        var envelopeMembers: [Int: [(idx: Int, obj: SceneObject)]] = [:]
        for (i, obj) in objects.enumerated() {
            if obj.groupID == nil, let p = obj.parentIndex,
               p < objects.count, objects[p].isEnvelope {
                envelopeMembers[p, default: []].append((i, obj))
            }
        }

        // One top-level entry per row, tagged with the name used to sort it and a
        // monotonic `order` used only as a stable tiebreaker for equal names.
        enum RowEntry {
            case camera
            case standalone(idx: Int, obj: SceneObject)
            case group(gid: Int)
            case envelope(idx: Int)
            case light(idx: Int)
            case fog
            case particles(idx: Int, name: String)
        }
        var entries: [(sortName: String, order: Int, entry: RowEntry)] = []
        var order = 0
        func add(_ name: String, _ entry: RowEntry) {
            entries.append((name, order, entry)); order += 1
        }

        add("Camera", .camera)
        add("Fog", .fog)
        // One lane per emitter, named by type ("Rain", "Smoke", …).  Disambiguate
        // duplicate types with a trailing number ("Rain 1", "Rain 2").
        var typeTotals: [ParticleType: Int] = [:]
        for e in emitters { typeTotals[e.type, default: 0] += 1 }
        var typeSeen: [ParticleType: Int] = [:]
        for (i, e) in emitters.enumerated() {
            typeSeen[e.type, default: 0] += 1
            let base = e.type.displayName
            let name = (typeTotals[e.type] ?? 0) > 1 ? "\(base) \(typeSeen[e.type]!)" : base
            add(name, .particles(idx: i, name: name))
        }
        var seenGroups = Set<Int>()
        for (i, obj) in objects.enumerated() {
            if obj.isEnvelope {
                add(sceneManager?.displayName(for: obj) ?? obj.name, .envelope(idx: i))
            } else if let gid = obj.groupID {
                guard seenGroups.insert(gid).inserted else { continue }
                add(sceneManager?.groupName(for: gid) ?? "Group", .group(gid: gid))
            } else if let p = obj.parentIndex, p < objects.count, objects[p].isEnvelope {
                // Direct simple member of a glued envelope — nested under it, not top-level.
                continue
            } else {
                add(sceneManager?.displayName(for: obj) ?? obj.name, .standalone(idx: i, obj: obj))
            }
        }
        for i in 0..<lightCount {
            add(lightLaneName(i), .light(idx: i))
        }

        entries.sort {
            let c = $0.sortName.localizedStandardCompare($1.sortName)
            return c == .orderedSame ? ($0.order < $1.order) : (c == .orderedAscending)
        }

        var result: TrackList = []

        // Emits one top-level entry (and its nested parts) at the given indent level.
        func emit(_ entry: RowEntry, level: Int) {
            switch entry {
            case .camera:
                result.append(TrackRow(name: "Camera", ref: .camera, indentLevel: level))
            case .fog:
                result.append(TrackRow(name: "Fog", ref: .fog, indentLevel: level))
            case .particles(let idx, let name):
                result.append(TrackRow(name: name, ref: .particles(idx), indentLevel: level))
            case .standalone(let idx, let obj):
                result.append(TrackRow(name: sceneManager?.displayName(for: obj) ?? obj.name,
                                       ref: .object(idx), indentLevel: level))
            case .light(let idx):
                result.append(TrackRow(name: lightLaneName(idx), ref: .light(idx), indentLevel: level))
            case .group(let gid):
                let gName = sceneManager?.groupName(for: gid) ?? "Group"
                let parts = groupOrder[gid] ?? []
                result.append(TrackRow(name: gName, ref: .group(gid),
                                       isGroupHeader: true, indentLevel: level))
                if expandedHeaders.contains(.group(gid)) {
                    let sorted = parts.sorted { $0.obj.name.localizedStandardCompare($1.obj.name) == .orderedAscending }
                    for pair in sorted {
                        result.append(TrackRow(name: sceneManager?.partName(for: pair.obj) ?? pair.obj.name,
                                               ref: .object(pair.idx), indentLevel: level + 1))
                    }
                }
            case .envelope(let idx):
                // A glued envelope renders like a group: a collapsible header with its
                // simple members nested.  The header's own ref is .object(idx) (the
                // envelope is a real, keyframeable object); it only shows a disclosure
                // triangle when it actually has nestable members.
                let members = (envelopeMembers[idx] ?? [])
                    .sorted { $0.obj.name.localizedStandardCompare($1.obj.name) == .orderedAscending }
                let name = sceneManager?.displayName(for: objects[idx]) ?? objects[idx].name
                result.append(TrackRow(name: name, ref: .object(idx),
                                       isGroupHeader: !members.isEmpty, indentLevel: level))
                if !members.isEmpty, expandedHeaders.contains(.object(idx)) {
                    for m in members {
                        result.append(TrackRow(name: sceneManager?.displayName(for: m.obj) ?? m.obj.name,
                                               ref: .object(m.idx), indentLevel: level + 1))
                    }
                }
            }
        }

        // ── Import bundles (Part B) ───────────────────────────────────────────
        // Partition the alphabetical top-level entries into bundles (display-only
        // collapsible headers grouping one File ▸ Import Project) and loose lanes.
        func bundleID(of entry: RowEntry) -> Int? {
            switch entry {
            case .standalone(let idx, _): return objects[safe: idx]?.importBundleID
            case .group(let gid):         return objects.first(where: { $0.groupID == gid })?.importBundleID
            case .envelope(let idx):      return objects[safe: idx]?.importBundleID
            case .light(let idx):         return lightManager?.lights[safe: idx]?.importBundleID
            case .particles(let idx, _):  return particleManager?.emitters[safe: idx]?.importBundleID
            default:                      return nil
            }
        }

        var bundleMembers: [Int: [(sortName: String, order: Int, entry: RowEntry)]] = [:]
        var bundleFirstSeen: [Int] = []
        // Top-level emission list: loose entries + one synthetic header per bundle.
        var top: [(sortName: String, order: Int, bundleID: Int?, entry: RowEntry?)] = []
        for e in entries {
            if let bid = bundleID(of: e.entry) {
                if bundleMembers[bid] == nil { bundleFirstSeen.append(bid) }
                bundleMembers[bid, default: []].append((e.sortName, e.order, e.entry))
            } else {
                top.append((e.sortName, e.order, nil, e.entry))
            }
        }
        for bid in bundleFirstSeen {
            let members  = bundleMembers[bid] ?? []
            let minOrder = members.map { $0.order }.min() ?? 0
            top.append((sceneManager?.bundleName(for: bid) ?? "Import", minOrder, bid, nil))
        }
        top.sort {
            let c = $0.sortName.localizedStandardCompare($1.sortName)
            return c == .orderedSame ? ($0.order < $1.order) : (c == .orderedAscending)
        }

        for t in top {
            if let bid = t.bundleID {
                // A freshly imported bundle is shown expanded the first time it appears,
                // then remembers the user's collapse/expand toggle.
                if !seenBundles.contains(bid) {
                    seenBundles.insert(bid)
                    expandedHeaders.insert(.importBundle(bid))
                }
                result.append(TrackRow(name: t.sortName, ref: .importBundle(bid), isGroupHeader: true))
                if expandedHeaders.contains(.importBundle(bid)) {
                    for m in (bundleMembers[bid] ?? []) { emit(m.entry, level: 1) }
                }
            } else if let entry = t.entry {
                emit(entry, level: 0)
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
        case .fog:
            return fogSettings?.keyframeTrack?.keyframes.map { $0.time } ?? []
        case .particles(let i):
            return particleManager?.emitters[safe: i]?.keyframeTrack?.keyframes.map { $0.time } ?? []
        case .importBundle:
            return []   // display-only header — no track of its own
        }
    }

    // MARK: - Import-bundle move-as-unit (Part B2)

    /// Every keyframe-bearing member track of a bundle: each member object's own
    /// track (incl. envelopes + group parts), each group-level track, each imported
    /// emitter's track, and each
    /// imported light's track.  Empty tracks are skipped.
    private func bundleMemberRefs(_ bid: Int) -> [TrackRef] {
        var refs: [TrackRef] = []
        if let sm = sceneManager {
            var seenGroups = Set<Int>()
            for (i, obj) in sm.objects.enumerated() where obj.importBundleID == bid {
                if obj.keyframeTrack?.keyframes.isEmpty == false { refs.append(.object(i)) }
                if let gid = obj.groupID, seenGroups.insert(gid).inserted,
                   sm.groupKeyframeTracks[gid]?.keyframes.isEmpty == false {
                    refs.append(.group(gid))
                }
            }
        }
        if let lm = lightManager {
            for i in 0..<lm.lights.count
            where lm.lights[i].importBundleID == bid
               && (i < lm.keyframeTracks.count && lm.keyframeTracks[i]?.keyframes.isEmpty == false) {
                refs.append(.light(i))
            }
        }
        if let pm = particleManager {
            for i in 0..<pm.emitters.count
            where pm.emitters[i].importBundleID == bid
               && pm.emitters[i].keyframeTrack?.keyframes.isEmpty == false {
                refs.append(.particles(i))
            }
        }
        return refs
    }

    /// Earliest / latest keyframe time across a bundle's member tracks, or nil when
    /// it has no keyframes.  For a looped bundle this reports the SOURCE cycle window
    /// (so the move-as-unit grab bar represents one cycle, not the tiled repeats).
    private func bundleSpan(_ bid: Int) -> (min: Double, max: Double)? {
        if let info = sceneManager?.importBundleLoops[bid], info.enabled, info.cycleLength > 0 {
            return (info.cycleStart, info.cycleStart + info.cycleLength)
        }
        return bundleSpanRaw(bid)
    }

    /// Raw earliest / latest keyframe time across a bundle's member tracks (ignores
    /// looping), or nil when it has no keyframes.
    private func bundleSpanRaw(_ bid: Int) -> (min: Double, max: Double)? {
        var lo = Double.infinity, hi = -Double.infinity
        for ref in bundleMemberRefs(bid) {
            for t in keyframeTimes(for: ref) { lo = min(lo, t); hi = max(hi, t) }
        }
        return lo.isFinite ? (lo, hi) : nil
    }

    // MARK: - Import-bundle looping helpers

    /// The ViewportView (set as the key-forward target), used to drive loop re-tiling.
    private var viewport: ViewportView? { keyForwardTarget as? ViewportView }

    /// The import-bundle ID a track belongs to, or nil.
    private func bundleID(for ref: TrackRef) -> Int? {
        switch ref {
        case .object(let i): return sceneManager?.objects[safe: i]?.importBundleID
        case .group(let gid): return sceneManager?.objects.first { $0.groupID == gid }?.importBundleID
        case .light(let i):  return lightManager?.lights[safe: i]?.importBundleID
        default:             return nil
        }
    }

    /// The (start, length) loop window for `ref`'s bundle when looping is on, else nil.
    private func loopCycle(for ref: TrackRef) -> (start: Double, length: Double)? {
        guard let bid = bundleID(for: ref),
              let info = sceneManager?.importBundleLoops[bid], info.enabled, info.cycleLength > 0
        else { return nil }
        return (info.cycleStart, info.cycleLength)
    }

    /// True when this keyframe is a generated loop repeat (past the source cycle) —
    /// drawn dark green and non-interactive.
    private func isLoopTile(_ ref: TrackRef, time: Double) -> Bool {
        guard let c = loopCycle(for: ref) else { return false }
        return time > c.start + c.length + 1e-3
    }

    /// Removes a bundle's generated loop repeats (keyframes past the source cycle),
    /// leaving the bare editable first cycle.  Used at the start of a move-as-unit drag.
    private func stripBundleTiles(_ bid: Int) {
        guard let info = sceneManager?.importBundleLoops[bid], info.cycleLength > 0 else { return }
        let cutoff = info.cycleStart + info.cycleLength + 1e-3
        for ref in bundleMemberRefs(bid) {
            switch ref {
            case .object(let i):
                sceneManager?.objects[safe: i]?.keyframeTrack?.keyframes.removeAll { $0.time > cutoff }
            case .group(let gid):
                sceneManager?.groupKeyframeTracks[gid]?.keyframes.removeAll { $0.time > cutoff }
            case .light(let i):
                if let lm = lightManager, i < lm.keyframeTracks.count, let tr = lm.keyframeTracks[i] {
                    tr.keyframes.removeAll { $0.time > cutoff }
                }
            case .particles(let i):
                particleManager?.emitters[safe: i]?.keyframeTrack?.keyframes.removeAll { $0.time > cutoff }
            default: break
            }
        }
    }

    /// Shifts every keyframe on a track by `delta` seconds (uniform → order preserved).
    private func shiftTrack(_ ref: TrackRef, by delta: Double) {
        switch ref {
        case .object(let i):
            sceneManager?.objects[safe: i]?.keyframeTrack?.keyframes.indices.forEach {
                sceneManager?.objects[safe: i]?.keyframeTrack?.keyframes[$0].time += delta
            }
        case .group(let gid):
            sceneManager?.groupKeyframeTracks[gid]?.keyframes.indices.forEach {
                sceneManager?.groupKeyframeTracks[gid]?.keyframes[$0].time += delta
            }
        case .light(let i):
            if let track = lightManager?.keyframeTracks[safe: i] ?? nil {
                track.keyframes.indices.forEach { track.keyframes[$0].time += delta }
            }
        case .particles(let i):
            if let track = particleManager?.emitters[safe: i]?.keyframeTrack {
                track.keyframes.indices.forEach { track.keyframes[$0].time += delta }
            }
        default:
            break
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
                if isLoopTile(row.ref, time: t) { continue }   // generated repeats are locked
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

        // ── Lane rows (track area) ──────────────────────────────────────────────
        // The label column is drawn LAST (drawLabelColumn) so it stays frozen at the
        // left while the track area scrolls horizontally.
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

        // ── In / Out range (NLE working range) ────────────────────────────────
        // Tint the active [In, Out] band across the lanes and draw bracket lines.
        // Drawn over the lanes but under keyframes/playhead so markers read clearly.
        if let tl = timeline, tl.inPoint != nil || tl.outPoint != nil {
            let inX  = timeToX(tl.playStart)
            let outX = timeToX(tl.playEnd)
            let bandTop = rulerHeight
            let clampedIn  = max(inX,  labelWidth)
            let clampedOut = min(outX, w)
            if clampedOut > clampedIn {
                let band = NSRect(x: clampedIn, y: bandTop,
                                  width: clampedOut - clampedIn, height: totalH - bandTop)
                NSColor.systemYellow.withAlphaComponent(0.06).setFill()
                NSBezierPath.fill(band)
            }
            func bracket(at x: CGFloat, isIn: Bool, active: Bool) {
                guard x >= labelWidth - 1 && x <= w + 1 else { return }
                let col = active ? NSColor.systemYellow : NSColor(white: 0.55, alpha: 1)
                let line = NSBezierPath()
                line.move(to: NSPoint(x: x, y: bandTop))
                line.line(to: NSPoint(x: x, y: totalH))
                col.withAlphaComponent(0.85).setStroke()
                line.lineWidth = 1.5
                line.stroke()
                // Small bracket tab pointing into the range, at the top of the lanes.
                let dir: CGFloat = isIn ? 1 : -1
                let tab = NSBezierPath()
                tab.move(to: NSPoint(x: x, y: bandTop))
                tab.line(to: NSPoint(x: x + dir * 6, y: bandTop))
                tab.line(to: NSPoint(x: x, y: bandTop + 8))
                tab.close()
                col.setFill()
                tab.fill()
            }
            bracket(at: inX,  isIn: true,  active: tl.inPoint  != nil)
            bracket(at: outX, isIn: false, active: tl.outPoint != nil)
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

        // ── Import-bundle span bars (Part B2) ─────────────────────────────────
        // A grab handle on each bundle header spanning its earliest→latest keyframe.
        // Drag it to shift the whole import in time.
        for (ti, row) in tracks.enumerated() {
            guard case .importBundle(let bid) = row.ref, let span = bundleSpan(bid) else { continue }
            let x0 = max(timeToX(span.min), labelWidth)
            let x1 = timeToX(span.max)
            guard x1 > labelWidth else { continue }
            let barH: CGFloat = 8
            let rect = NSRect(x: x0, y: laneCenter(ti) - barH / 2,
                              width: max(barH, x1 - x0), height: barH)
            let path = NSBezierPath(roundedRect: rect, xRadius: barH / 2, yRadius: barH / 2)
            NSColor.systemTeal.withAlphaComponent(0.40).setFill()
            path.fill()
            NSColor.systemTeal.withAlphaComponent(0.85).setStroke()
            path.lineWidth = 1
            path.stroke()
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

                // Generated loop repeats (past the source cycle) are dark green and
                // non-interactive — they regenerate from the editable first cycle.
                let isLoopRepeat = isLoopTile(row.ref, time: kfTime)

                // Colour: dark green for loop repeats, amber while editing, teal when
                // multi-selected, accent when single-selected, orange for follow
                // keyframes, grey otherwise.
                let fillColor: NSColor
                if isLoopRepeat {
                    fillColor = NSColor(red: 0.13, green: 0.42, blue: 0.20, alpha: 1)
                } else if isSelected && isEditingKeyframe {
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

        // ── Frozen label column ───────────────────────────────────────────────
        // Drawn after the track content so the names/popups stay pinned at the left
        // while the track area scrolls horizontally (mirrors the floating ruler).
        drawLabelColumn(tracks: tracks, totalH: totalH)

        // ── Floating ruler header ─────────────────────────────────────────────
        // Drawn last, offset to the top of the scroll view's visible area, so the
        // ruler (ticks, time labels, playhead marker, EDITING badge) stays pinned
        // at the top while the lanes scroll beneath it.
        drawRulerHeader(originY: visibleRect.minY, duration: duration, curTime: curTime, w: w)

        // Easing dropdowns are real subviews and render above the drawn header,
        // so hide any that have scrolled up under it.
        updateEasingPopupOcclusion()
    }

    /// Per-lane background colour for the label column (matches the lane-row fill).
    private func laneBackgroundColor(index i: Int, isHeader: Bool, isSelected: Bool) -> NSColor {
        if isSelected {
            if isEditingKeyframe { return NSColor(red: 0.30, green: 0.22, blue: 0.08, alpha: 1) }
            if isHeader          { return NSColor(red: 0.22, green: 0.42, blue: 0.68, alpha: 1) }
            return NSColor(red: 0.14, green: 0.30, blue: 0.52, alpha: 1)
        }
        if isHeader { return NSColor(white: 0.26, alpha: 1) }
        return NSColor(white: i % 2 == 0 ? 0.18 : 0.21, alpha: 1)
    }

    /// Draws the frozen label column (backgrounds, separator, names, triangles) at
    /// the current horizontal scroll offset so track names stay visible while the
    /// timeline scrolls.  Also re-pins the easing popups to the column.
    private func drawLabelColumn(tracks: TrackList, totalH: CGFloat) {
        let lx = labelOriginX   // = visibleRect.minX

        // Per-row backgrounds + separators (so selection/header colour shows here).
        for (i, row) in tracks.enumerated() {
            laneBackgroundColor(index: i, isHeader: row.isGroupHeader,
                                isSelected: i == selectedTrackIndex).setFill()
            NSBezierPath.fill(NSRect(x: lx, y: laneTop(i), width: labelWidth, height: laneHeight))
            NSColor(white: row.isGroupHeader ? 0.11 : 0.13, alpha: 1).setFill()
            NSBezierPath.fill(NSRect(x: lx, y: laneTop(i) + laneHeight - 1,
                                     width: labelWidth, height: 1))
        }

        // Column right separator.
        NSColor(white: 0.12, alpha: 1).setFill()
        NSBezierPath.fill(NSRect(x: lx + labelWidth - 1, y: 0, width: 1, height: totalH))

        // ── Names + disclosure triangles ──────────────────────────────────────
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font:            NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor(white: 0.80, alpha: 1)
        ]
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font:            NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor(white: 0.88, alpha: 1)
        ]
        // Reserve the right portion of the column for the easing popup so a long
        // model / group name never overlaps the dropdown.
        let popupReserved: CGFloat = 64   // popup width (58) + right margin (3) + gap (3)

        for (i, row) in tracks.enumerated() {
            // Each nesting level shifts the disclosure triangle + name to the right.
            let indent = CGFloat(row.indentLevel) * indentStep
            if row.isGroupHeader {
                let triStr  = (expandedHeaders.contains(row.ref) ? "▼" : "▶") as NSString
                let triAttrs: [NSAttributedString.Key: Any] = [
                    .font:            NSFont.systemFont(ofSize: 12, weight: .bold),
                    .foregroundColor: NSColor(white: 0.92, alpha: 1)
                ]
                let triSize = triStr.size(withAttributes: triAttrs)
                triStr.draw(at: NSPoint(x: lx + 7 + indent, y: laneCenter(i) - triSize.height / 2),
                            withAttributes: triAttrs)
            }

            let attrs = row.isGroupHeader ? headerAttrs : nameAttrs
            let nameX: CGFloat
            let maxNameW: CGFloat
            // Rows that carry an easing popup (group headers, standalone objects,
            // camera/light/fog/particles) reserve the popup zone; indented child
            // part rows have no popup but still reserve it (harmless, keeps names short).
            if row.isGroupHeader {
                nameX    = triangleZone + indent
                maxNameW = labelWidth - popupReserved - nameX
            } else {
                nameX    = 8 + indent
                maxNameW = labelWidth - popupReserved - nameX
            }

            let str  = row.name as NSString
            let size = str.size(withAttributes: attrs)
            let y    = laneCenter(i) - size.height / 2

            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath.clip(NSRect(x: lx + nameX, y: laneTop(i),
                                     width: max(0, maxNameW), height: laneHeight))
            str.draw(at: NSPoint(x: lx + nameX, y: y), withAttributes: attrs)
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        // Re-pin the easing popups to the frozen column.
        layoutEasingPopups(offsetX: lx)
    }

    /// Positions each easing popup's x to follow the frozen label column.
    private func layoutEasingPopups(offsetX: CGFloat) {
        let baseX = labelWidth - easingPopupW - 3
        for b in easingPopups {
            var f = b.popup.frame
            let newX = offsetX + baseX
            if abs(f.origin.x - newX) > 0.5 { f.origin.x = newX; b.popup.frame = f }
        }
    }

    /// Hides easing popups whose row has scrolled under the floating ruler header
    /// (subviews always render above drawn content, so they'd poke through it).
    /// Re-shown when the row scrolls back below the header.
    private func updateEasingPopupOcclusion() {
        let band = NSRect(x: 0, y: visibleRect.minY, width: bounds.width, height: rulerHeight)
        for b in easingPopups {
            b.popup.isHidden = b.popup.frame.intersects(band)
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
            if x >= labelRightX - 1 && x <= w + 1 {
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
        if phX >= labelRightX - 1 && phX <= w + 1 {
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
                at: NSPoint(x: labelRightX + 8, y: originY + (rulerHeight - badgeSize.height) / 2),
                withAttributes: badgeAttrs
            )
        }
    }

    // MARK: - Mouse input

    override func mouseDown(with event: NSEvent) {
        // Block all mouse interaction while a keyframe is being edited.
        guard !isEditingKeyframe else { return }

        window?.makeFirstResponder(self)
        isMouseDownInView  = true
        mouseDownOnDiamond = false   // reset each gesture
        let pt        = convert(event.locationInWindow, from: nil)
        let tracks    = buildTracks()
        let isOption  = event.modifierFlags.contains(.option)
        let isControl = event.modifierFlags.contains(.control)

        // ── Ctrl+click in track area → start rubber-band selection ────────────
        if isControl && pt.y >= rulerHeight && pt.x >= labelRightX {
            isRubberBanding   = true
            rubberBandStart   = pt
            rubberBandCurrent = pt
            return
        }

        // Ruler click → scrub.
        // Clear any selected diamond and multi-selection so a subsequent drag
        // into the track area never accidentally moves a keyframe instead of scrubbing.
        if pt.y < rulerHeight && pt.x >= labelRightX {
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
                // NOTE: don't clear multiClipboard here — it's a copy buffer, not a
                // selection, so it must survive clicks (only a new copy resets it).
                multiSelectedDiamonds.removeAll()
            }

            // Always update single-select and seek so the playhead follows the click.
            select(trackIndex: hit.trackIndex, kfIndex: hit.kfIndex)
            let times = keyframeTimes(for: tracks[hit.trackIndex].ref)
            if hit.kfIndex < times.count { timeline?.seek(to: times[hit.kfIndex]) }
            onLaneSelected?(tracks[hit.trackIndex].ref)

            // Edit mode disabled (under evaluation for removal) — double-click no
            // longer enters it.  The I / Insert keyframe workflow is unaffected.
            // if !isOption && event.clickCount == 2 {
            //     handleReturnKey(tracks: tracks)
            // }
            return
        }

        // Lane hit → select lane + notify viewport.
        // Group-header rows also toggle expansion, but ONLY when clicking the
        // disclosure triangle (leftmost triangleZone pixels) — not the whole row.
        // Any click in the track area (x ≥ labelWidth) also scrubs the playhead.
        if let lane = hitTestLane(at: pt, tracks: tracks) {
            let row = tracks[lane]

            // Plain lane click (no modifier) clears multi-selection (but not the
            // copy buffer — multiClipboard persists until the next copy).
            if !isOption {
                multiSelectedDiamonds.removeAll()
            }

            if row.isGroupHeader {
                // Toggle expansion only via the disclosure triangle, which shifts
                // right with the row's nesting level (bundle ▸ group ▸ part).
                let indent  = CGFloat(row.indentLevel) * indentStep
                let localX  = pt.x - labelOriginX
                if localX >= indent && localX < triangleZone + indent {
                    if expandedHeaders.contains(row.ref) {
                        expandedHeaders.remove(row.ref)
                    } else {
                        expandedHeaders.insert(row.ref)
                    }
                    rebuildEasingPopups()
                    onLayoutChanged?()   // resize document view / panel for new row count
                }
                // Bundle header: grabbing the span bar starts a move-as-unit drag.
                if case .importBundle(let bid) = row.ref, pt.x >= labelRightX,
                   let span = bundleSpan(bid) {
                    let x0 = max(timeToX(span.min), labelWidth)
                    let x1 = timeToX(span.max)
                    if pt.x >= x0 - 4 && pt.x <= max(x0, x1) + 4 {
                        isBundleDragging      = true
                        bundleDragRefs        = bundleMemberRefs(bid)
                        bundleDragMinT        = span.min
                        bundleDragMouseStartX = pt.x
                        bundleDragAppliedDt   = 0
                        bundleDragBid         = bid
                        // For a looped bundle, strip the generated repeats first so the
                        // drag moves only the source cycle (repeats re-tile on release).
                        if sceneManager?.importBundleLoops[bid]?.enabled == true {
                            stripBundleTiles(bid)
                        }
                        select(trackIndex: lane, kfIndex: nil)
                        onLaneSelected?(row.ref)
                        return
                    }
                }
                select(trackIndex: lane, kfIndex: nil)
                onLaneSelected?(row.ref)
                if pt.x >= labelRightX { scrubToX(pt.x) }
                return
            }

            select(trackIndex: lane, kfIndex: nil)
            onLaneSelected?(row.ref)
            if pt.x >= labelRightX { scrubToX(pt.x) }
            return
        }

        // Click outside all lanes → deselect everything (keep the copy buffer).
        multiSelectedDiamonds.removeAll()
        select(trackIndex: nil, kfIndex: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isEditingKeyframe else { return }

        let pt     = convert(event.locationInWindow, from: nil)
        let tracks = buildTracks()

        // ── Bundle move-as-unit drag ──────────────────────────────────────────
        if isBundleDragging {
            let fr        = timeline?.frameRate ?? 30
            let rawDt      = Double((pt.x - bundleDragMouseStartX) / pxPerSecond)
            var snappedDt  = (rawDt * fr).rounded() / fr          // frame snap
            snappedDt      = max(snappedDt, -bundleDragMinT)      // can't move start below 0
            let delta      = snappedDt - bundleDragAppliedDt
            if delta != 0 {
                for ref in bundleDragRefs { shiftTrack(ref, by: delta) }
                bundleDragAppliedDt = snappedDt
                // Grow the timeline if the import now runs past the end.
                if let tl = timeline {
                    var maxT = 0.0
                    for ref in bundleDragRefs { for t in keyframeTimes(for: ref) { maxT = max(maxT, t) } }
                    if maxT > tl.duration { tl.duration = maxT }
                }
                needsDisplay = true
            }
            return
        }

        // ── Rubber-band in progress: just track the cursor and redraw ─────────
        if isRubberBanding {
            rubberBandCurrent = pt
            needsDisplay = true
            return
        }

        // Ruler drag → always scrub (highest priority).
        if !isDragging && pt.y < rulerHeight && pt.x >= labelRightX {
            scrubToX(pt.x)
            return
        }

        // If the gesture did NOT start on a diamond, scrub the playhead while dragging
        // in the track area — so the user can click-and-drag to position the playhead.
        if !mouseDownOnDiamond {
            if pt.x >= labelRightX { scrubToX(pt.x) }
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
        isMouseDownInView = false

        // Finalise a bundle move-as-unit drag.
        if isBundleDragging {
            isBundleDragging = false
            // Advance the bundle's stored source offset (T) so a later "Extend Spin/
            // Orbit to End" re-places the markers at the moved start, not the original.
            if let bid = bundleDragBid, bundleDragAppliedDt != 0,
               var src = sceneManager?.importBundleSources[bid] {
                src.insertOffset += bundleDragAppliedDt
                sceneManager?.importBundleSources[bid] = src
            }
            // For a looped bundle, advance its cycle window by the applied shift and
            // re-tile (also restores the repeats stripped at drag start, even on a
            // zero-distance click).
            if let bid = bundleDragBid, var info = sceneManager?.importBundleLoops[bid], info.enabled {
                info.cycleStart += bundleDragAppliedDt
                sceneManager?.importBundleLoops[bid] = info
                viewport?.regenerateBundleLoop(bid: bid)
            }
            if bundleDragAppliedDt != 0 {
                onKeyframePasted?()   // markDirty + invalidate animation cache + panel refresh
            }
            bundleDragRefs.removeAll()
            bundleDragBid = nil
            needsDisplay = true
            return
        }

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

        // A diamond drag edits the source cycle — re-tile any looped bundle it touched.
        if isDragging {
            let tracks = buildTracks()
            var refs: [TrackRef] = []
            if let ti = selectedTrackIndex, ti < tracks.count { refs.append(tracks[ti].ref) }
            refs.append(contentsOf: multiDragSecondary.map { $0.ref })
            var seen = Set<Int>()
            for ref in refs {
                if let bid = bundleID(for: ref), seen.insert(bid).inserted,
                   sceneManager?.importBundleLoops[bid]?.enabled == true {
                    viewport?.regenerateBundleLoop(bid: bid)
                }
            }
        }

        multiDragSecondary.removeAll()
        isDragging         = false
        mouseDownOnDiamond = false
    }

    // MARK: - Right-click: paste a coordinate channel into a keyframe (Part B2)

    /// AppKit calls this on right/Control-click.  If the click landed on a light
    /// or fog/weather keyframe diamond, offer to paste the matching coordinate
    /// channel(s) from the clipboard, replacing just that component of the keyframe.
    /// (Object/group/camera keyframes are excluded — deltas / no xyz.)
    override func menu(for event: NSEvent) -> NSMenu? {
        // Control is this view's rubber-band multi-select modifier (handled in
        // mouseDown).  macOS routes Control+left-click to the contextual menu first,
        // which would pop the Delete menu instead of starting a selection — so
        // suppress the menu when Control is down.  A plain right-click (no Control)
        // still shows the Delete / rename / paste menu.
        if event.modifierFlags.contains(.control) { return nil }

        let tracks = buildTracks()
        let pt     = convert(event.locationInWindow, from: nil)

        guard let lane = hitTestLane(at: pt, tracks: tracks) else { return nil }
        let ref = tracks[lane].ref

        let menu = NSMenu()
        menu.autoenablesItems = false   // honor our per-channel isEnabled below

        // Import-bundle header: rename + repeat-to-fill.
        if case .importBundle(let bid) = ref {
            let item = NSMenuItem(title: "Rename Import Bundle…",
                                  action: #selector(renameBundleMenuAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = bid
            menu.addItem(item)

            let loopItem = NSMenuItem(title: "Repeat to Fill Timeline",
                                      action: #selector(toggleBundleLoopMenuAction(_:)), keyEquivalent: "")
            loopItem.target = self; loopItem.representedObject = bid
            loopItem.state  = (sceneManager?.importBundleLoops[bid]?.enabled == true) ? .on : .off
            menu.addItem(loopItem)

            // Only when we know the source file (re-reads its spin/orbit rate markers).
            if sceneManager?.importBundleSources[bid]?.path.isEmpty == false {
                let extItem = NSMenuItem(title: "Extend Spin/Orbit to End",
                                         action: #selector(extendBundleSpinOrbitMenuAction(_:)), keyEquivalent: "")
                extItem.target = self; extItem.representedObject = bid
                menu.addItem(extItem)
            }
        }

        // Keyframe diamond under the cursor → coordinate-channel paste (light/fog/particles).
        if let hit = hitTestDiamond(at: pt, tracks: tracks), let clip = coordinateClipboard {
            let dref = tracks[hit.trackIndex].ref
            var channels: [CoordChannel] = []
            switch dref {
            case .light(let i):
                // Match the Lights panel: Position for point/spot/laser, Target for
                // directional/spot/laser, nothing for ambient.
                if let type = lightManager?.lights[safe: i]?.type {
                    if type == .point || type == .spot || type == .laser       { channels.append(.position) }
                    if type == .directional || type == .spot || type == .laser { channels.append(.target) }
                }
            case .fog, .particles:  channels = [.position, .size]
            default:                channels = []   // no channel paste for object/group/camera
            }
            for ch in channels {
                let item = NSMenuItem(title: ch.menuTitle,
                                      action: #selector(pasteChannelMenuAction(_:)), keyEquivalent: "")
                item.target           = self
                item.representedObject = ChannelPasteRequest(ref: dref, kfIndex: hit.kfIndex, channel: ch)
                item.isEnabled         = clipboardHasValue(clip, ch)   // grey when nothing copied
                menu.addItem(item)
            }
        }

        // Delete (per row type).
        if let title = deleteMenuTitle(for: ref) {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            let del = NSMenuItem(title: title, action: #selector(deleteRowMenuAction(_:)), keyEquivalent: "")
            del.target = self; del.representedObject = ref
            menu.addItem(del)
        }

        return menu.numberOfItems > 0 ? menu : nil
    }

    /// Label for the Delete item on a row, or nil when the row isn't deletable
    /// (fog/camera, or the last light/emitter which can't be removed).
    private func deleteMenuTitle(for ref: TrackRef) -> String? {
        switch ref {
        case .importBundle:  return "Delete Import"
        case .group:         return "Delete Model"
        case .object(let i):
            guard let obj = sceneManager?.objects[safe: i] else { return nil }
            if obj.isEnvelope         { return "Delete Glued Model" }
            if obj.parentIndex != nil { return "Delete Member" }
            if obj.groupID    != nil  { return "Delete Model" }
            return "Delete Object"
        case .light(let i):
            guard let lm = lightManager, i < lm.lights.count, lm.lights.count > 1 else { return nil }
            return "Delete Light"
        case .particles(let i):
            guard let pm = particleManager, i < pm.emitters.count, pm.emitters.count > 1 else { return nil }
            return "Delete Emitter"
        case .fog, .camera:  return nil
        }
    }

    @objc private func deleteRowMenuAction(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? TrackRef else { return }
        onDeleteRow?(ref)
    }

    @objc private func extendBundleSpinOrbitMenuAction(_ sender: NSMenuItem) {
        guard let bid = sender.representedObject as? Int else { return }
        onExtendBundleSpinOrbit?(bid)
    }

    @objc private func renameBundleMenuAction(_ sender: NSMenuItem) {
        guard let bid = sender.representedObject as? Int, let sm = sceneManager else { return }
        let alert = NSAlert()
        alert.messageText     = "Rename Import Bundle"
        alert.informativeText = "Enter a new name for this import bundle's Timeline header."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue     = sm.importBundles[bid] ?? sm.bundleName(for: bid)
        alert.accessoryView   = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return }
        sm.importBundles[bid] = newName
        NSApp.sendAction(#selector(AppDelegate.markDirtyFromUI), to: nil, from: self)
        rebuildEasingPopups()
        invalidateTrackCache()   // header name feeds the lane model + its sort order
        needsDisplay = true
    }

    /// Toggles "Repeat to Fill Timeline" for an import bundle and re-tiles it.
    @objc private func toggleBundleLoopMenuAction(_ sender: NSMenuItem) {
        guard let bid = sender.representedObject as? Int, let sm = sceneManager else { return }
        var info = sm.importBundleLoops[bid] ?? SceneManager.BundleLoop()
        info.enabled.toggle()
        // Backfill the cycle window for bundles imported before this feature (or with
        // no captured length): use the current keyframe span.
        if info.enabled, info.cycleLength <= 0, let span = bundleSpanRaw(bid) {
            info.cycleStart  = span.min
            info.cycleLength = max(0, span.max - span.min)
        }
        sm.importBundleLoops[bid] = info
        viewport?.regenerateBundleLoop(bid: bid)
        NSApp.sendAction(#selector(AppDelegate.markDirtyFromUI), to: nil, from: self)
        needsDisplay = true
    }

    private func clipboardHasValue(_ clip: CoordinateClipboard, _ ch: CoordChannel) -> Bool {
        switch ch {
        case .position:  return clip.position  != nil
        case .size:      return clip.size      != nil
        case .target:    return clip.position  != nil   // target is a world position
        }
    }

    @objc private func pasteChannelMenuAction(_ sender: NSMenuItem) {
        guard let req = sender.representedObject as? ChannelPasteRequest,
              let clip = coordinateClipboard else { return }
        applyChannelPaste(req, clipboard: clip)
    }

    /// Writes one clipboard channel into the target keyframe, leaving its other
    /// components untouched.
    private func applyChannelPaste(_ req: ChannelPasteRequest, clipboard clip: CoordinateClipboard) {
        switch (req.ref, req.channel) {
        case (.light(let i), .position):
            guard let v = clip.position, let lm = lightManager, i < lm.keyframeTracks.count,
                  let track = lm.keyframeTracks[i], req.kfIndex < track.keyframes.count else { return }
            track.keyframes[req.kfIndex].position = v
        case (.light(let i), .target):
            guard let v = clip.position, let lm = lightManager, i < lm.keyframeTracks.count,
                  let track = lm.keyframeTracks[i], req.kfIndex < track.keyframes.count else { return }
            track.keyframes[req.kfIndex].target = v
        case (.fog, .position):
            guard let v = clip.position, let track = fogSettings?.keyframeTrack,
                  req.kfIndex < track.keyframes.count else { return }
            track.keyframes[req.kfIndex].position = v
        case (.fog, .size):
            guard let v = clip.size, let track = fogSettings?.keyframeTrack,
                  req.kfIndex < track.keyframes.count else { return }
            track.keyframes[req.kfIndex].size = v
        case (.particles(let i), .position):
            guard let v = clip.position, let track = particleManager?.emitters[safe: i]?.keyframeTrack,
                  req.kfIndex < track.keyframes.count else { return }
            track.keyframes[req.kfIndex].position = v
        case (.particles(let i), .size):
            guard let v = clip.size, let track = particleManager?.emitters[safe: i]?.keyframeTrack,
                  req.kfIndex < track.keyframes.count else { return }
            track.keyframes[req.kfIndex].size = v
        default:
            return
        }
        needsDisplay = true
        onKeyframePasted?()   // mark dirty (+ refresh atmosphere panel)
        print("[DEBUG] TimelineEditorView: pasted \(req.channel) into keyframe kf=\(req.kfIndex)")
    }

    // MARK: - Keyboard input

    override func keyDown(with event: NSEvent) {
        let tracks = buildTracks()

        // The track list can shrink between events — e.g. gluing collapses the members
        // under a new envelope header — leaving `selectedTrackIndex` past the end.  Drop
        // a now-out-of-range selection so the handlers below never index past the array.
        if let ti = selectedTrackIndex, ti >= tracks.count {
            selectedTrackIndex = nil
            selectedKFIndex    = nil
        }

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

        case 51, 117: // Backspace / Forward Delete → remove selected diamond
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
        }
        // ── Enter edit mode (DISABLED — under evaluation for removal) ───────────
        // The benevolent I / Insert keyframe workflow replaces it; Return no longer
        // enters edit mode.  Restore this branch to bring edit mode back.
        // else {
        //     guard let ti = selectedTrackIndex, let ki = selectedKFIndex else { return }
        //     let ref   = tracks[ti].ref
        //     let times = keyframeTimes(for: ref)
        //     guard ki < times.count else { return }
        //
        //     editKFTime        = times[ki]
        //     isEditingKeyframe = true
        //     needsDisplay      = true
        //
        //     print("[DEBUG] TimelineEditorView: entering edit mode lane=\(ti)"
        //         + " kf=\(ki) t=" + String(format: "%.3f", editKFTime))
        //
        //     onEnterEditMode?(ref, editKFTime)
        // }
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
                if isLoopTile(row.ref, time: t) { continue }   // generated repeats are locked
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

        case .fog:
            guard let track = fogSettings?.keyframeTrack,
                  let idx   = track.keyframes.firstIndex(where: { abs($0.time - fromTime) < 0.0005 })
            else { return }
            track.retimeKeyframe(at: idx, to: toTime)

        case .particles(let i):
            guard let track = particleManager?.emitters[safe: i]?.keyframeTrack,
                  let idx   = track.keyframes.firstIndex(where: { abs($0.time - fromTime) < 0.0005 })
            else { return }
            track.retimeKeyframe(at: idx, to: toTime)

        case .importBundle:
            return   // display-only header — no track
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
            case .fog:
                fogSettings?.keyframeTrack?.moveKeyframes(from: from, to: to)
            case .particles(let i):
                particleManager?.emitters[safe: i]?.keyframeTrack?.moveKeyframes(from: from, to: to)
            case .importBundle:
                break   // display-only header — no track
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
        case .fog:
            fogSettings?.keyframeTrack?.removeKeyframe(at: ki)
        case .particles(let i):
            particleManager?.emitters[safe: i]?.keyframeTrack?.removeKeyframe(at: ki)
        case .importBundle:
            break   // display-only header — no track
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
        case .fog:
            guard let track = fogSettings?.keyframeTrack,
                  let idx   = track.keyframes.firstIndex(where: { abs($0.time - time) < eps })
            else { return }
            track.removeKeyframe(at: idx)
        case .particles(let i):
            guard let track = particleManager?.emitters[safe: i]?.keyframeTrack,
                  let idx   = track.keyframes.firstIndex(where: { abs($0.time - time) < eps })
            else { return }
            track.removeKeyframe(at: idx)
        case .importBundle:
            return   // display-only header — no track
        }
    }

    private func insertKeyframeInSelectedLane(tracks: TrackList) {
        guard let ti = selectedTrackIndex else { return }
        let ref = tracks[ti].ref
        switch ref {
        case .camera:         onInsertCameraKeyframe?()
        case .object(let i):  onInsertObjectKeyframe?(i)
        case .light(let i):   onInsertLightKeyframe?(i)
        case .group(let gid): onInsertGroupKeyframe?(gid)
        case .fog:            onInsertFogKeyframe?()
        case .particles(let i): onInsertParticleKeyframe?(i)
        case .importBundle:   return   // display-only header — no track
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

    // MARK: - Cross-instance keyframe clipboard (CI-2)

    /// Identity for cross-instance track matching: name for object/group, index for
    /// light/emitter; camera/fog are singletons.  (Reliable because Pete's projects
    /// are Save-As descendants and share names/indices.)
    private func keyframeDescriptor(for ref: TrackRef) -> (name: String?, index: Int?) {
        switch ref {
        case .camera, .fog:     return (nil, nil)
        case .object(let i):    return (sceneManager?.objects[safe: i]?.name, nil)
        case .group(let gid):   return (sceneManager?.groupName(for: gid), nil)
        case .light(let i):     return (nil, i)
        case .particles(let i): return (nil, i)
        case .importBundle:     return (nil, nil)   // display-only header — not copyable
        }
    }

    /// Maps a pasteboard entry's identity back to a local TrackRef, or nil if there's
    /// no matching track in this scene.
    private func resolveTrackRef(kind: KFClipKind, name: String?, index: Int?) -> TrackRef? {
        switch kind {
        case .camera: return .camera
        case .fog:    return .fog
        case .object:
            guard let name, let i = sceneManager?.objects.firstIndex(where: { $0.name == name }) else { return nil }
            return .object(i)
        case .group:
            guard let name, let sm = sceneManager,
                  let obj = sm.objects.first(where: { $0.groupID != nil && sm.groupName(for: $0.groupID!) == name }),
                  let gid = obj.groupID else { return nil }
            return .group(gid)
        case .light:
            guard let i = index, let lm = lightManager, i < lm.lights.count else { return nil }
            return .light(i)
        case .particles:
            guard let i = index, let pm = particleManager, i < pm.emitters.count else { return nil }
            return .particles(i)
        }
    }

    /// Mirrors copied keyframes to the system pasteboard so a second app instance
    /// can paste them (CI-2).
    private func writeKeyframePasteboard(_ items: [(clip: ClipboardKeyframe, timeOffset: Double, ref: TrackRef)]) {
        let entries: [KFClipEntry] = items.map { item in
            var e = KeyframePasteboard.entry(from: item.clip)
            e.timeOffset = item.timeOffset
            let d = keyframeDescriptor(for: item.ref)
            e.trackName  = d.name
            e.trackIndex = d.index
            return e
        }
        KeyframePasteboard.write(entries)
        clipboardChangeCount = NSPasteboard.general.changeCount   // our own copy
    }

    /// Decodes the system pasteboard into local entries (resolving track identity to
    /// this scene), or nil if it holds no keyframes / none map here.
    private func readKeyframePasteboard() -> [MultiClipEntry]? {
        guard let raw = KeyframePasteboard.read() else { return nil }
        var out: [MultiClipEntry] = []
        for e in raw {
            guard let clip = KeyframePasteboard.clip(from: e),
                  let ref  = resolveTrackRef(kind: e.kind, name: e.trackName, index: e.trackIndex)
            else { continue }
            out.append(MultiClipEntry(clip: clip, timeOffset: e.timeOffset, ref: ref))
        }
        return out.isEmpty ? nil : out
    }

    /// Stamps a set of clipboard entries at the playhead (+ each entry's offset,
    /// clamped to duration).  Same-source selections retarget to the selected lane;
    /// multi-track selections paste back to their own lanes.  Shared by the in-memory
    /// multi path and the cross-instance pasteboard path.
    private func pasteEntries(_ entries: [MultiClipEntry], tracks: TrackList) {
        guard !entries.isEmpty else { return }
        let baseT = timeline?.currentTime ?? 0
        let maxT  = timeline?.duration ?? Double.infinity
        let sameSource = entries.dropFirst().allSatisfy { $0.ref == entries[0].ref }
        let targetRef: TrackRef? = (sameSource ? selectedTrackIndex.map { tracks[$0].ref } : nil)
        for entry in entries {
            let t   = max(0, min(maxT, baseT + entry.timeOffset))
            let dst = targetRef ?? entry.ref
            pasteClip(entry.clip, to: dst, at: t)
        }
        selectedKFIndex = nil
        needsDisplay    = true
        onKeyframePasted?()
        print("[DEBUG] TimelineEditorView: pasted \(entries.count) keyframe(s)"
            + (targetRef != nil ? " → selected lane" : " → matched lanes"))
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
                case .fog:
                    guard let kf = fogSettings?.keyframeTrack?.keyframes[safe: d.kfIndex] else { continue }
                    entries.append((.fog(kf), t, ref))
                case .particles(let i):
                    guard let kf = particleManager?.emitters[safe: i]?.keyframeTrack?.keyframes[safe: d.kfIndex] else { continue }
                    entries.append((.particles(kf), t, ref))
                case .importBundle:
                    continue   // display-only header — no track
                }
            }
            guard !entries.isEmpty else { return }
            let minTime = entries.map { $0.time }.min()!
            multiClipboard    = entries.map {
                MultiClipEntry(clip: $0.clip, timeOffset: $0.time - minTime, ref: $0.ref)
            }
            clipboardKeyframe = nil   // single clipboard is stale after a multi-copy
            writeKeyframePasteboard(multiClipboard.map { ($0.clip, $0.timeOffset, $0.ref) })
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
            coordinateClipboard?.position  = kf.position
        case .group(let gid):
            guard let kf = sceneManager?.groupKeyframeTracks[gid]?
                              .keyframes[safe: ki] else { return }
            clipboardKeyframe = .group(kf)
        case .fog:
            guard let kf = fogSettings?.keyframeTrack?.keyframes[safe: ki] else { return }
            clipboardKeyframe = .fog(kf)
            coordinateClipboard?.position = kf.position
            coordinateClipboard?.size     = kf.size
        case .particles(let i):
            guard let kf = particleManager?.emitters[safe: i]?.keyframeTrack?.keyframes[safe: ki] else { return }
            clipboardKeyframe = .particles(kf)
            coordinateClipboard?.position = kf.position
            coordinateClipboard?.size     = kf.size
        case .importBundle:
            return   // display-only header — no track
        }
        if let clip = clipboardKeyframe {
            writeKeyframePasteboard([(clip, 0, ref)])   // mirror for cross-instance paste
        }
        print("[DEBUG] TimelineEditorView: Cmd+C — copied \(clipboardKeyframe!.typeName)"
            + " keyframe from lane=\(ti) kf=\(ki)")
    }

    /// Pastes the clipboard pose(s) at the current playhead.
    /// With a non-empty multiClipboard, stamps all entries back to their
    /// original tracks at currentTime + each entry's time offset.
    /// Otherwise pastes the single clipboardKeyframe onto the selected lane.
    private func pasteKeyframe(tracks: TrackList) {
        // ── Most-recent-copy-wins across instances ─────────────────────────────
        // If the system pasteboard changed since our own last copy, another app
        // instance copied more recently — prefer it over our in-memory clipboard.
        if NSPasteboard.general.changeCount != clipboardChangeCount,
           let entries = readKeyframePasteboard() {
            pasteEntries(entries, tracks: tracks)
            return
        }

        // ── In-memory multi-clipboard path (same-instance) ─────────────────────
        if !multiClipboard.isEmpty {
            pasteEntries(multiClipboard, tracks: tracks)
            return
        }

        // ── Single-clipboard path ─────────────────────────────────────────────
        guard let clip = clipboardKeyframe else {
            // Nothing in this instance's clipboard — fall back to the system
            // pasteboard, which may hold keyframes copied in another app instance
            // (CI-2).  Track identity is resolved to this scene by name/index.
            if let entries = readKeyframePasteboard() {
                pasteEntries(entries, tracks: tracks)
            } else {
                print("[DEBUG] TimelineEditorView: Cmd+V — clipboard empty")
            }
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
                scale:       src.scale,
                opacity:     src.opacity))

        // ── Light (any light lane accepts a light clipboard) ──────────────────
        case (.light(let src), .light(let i)):
            guard let lm = lightManager, i < lm.keyframeTracks.count else { return }
            if lm.keyframeTracks[i] == nil { lm.keyframeTracks[i] = LightKeyframeTrack() }
            lm.keyframeTracks[i]?.addKeyframe(LightKeyframe(
                time:          t,
                intensity:     src.intensity,
                color:         src.color,
                target:        src.target,
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
                scale:       src.scale,
                opacity:     src.opacity))

        // ── Atmosphere (fog / weather lanes accept matching clipboards) ───────
        case (.fog(let src), .fog):
            if fogSettings?.keyframeTrack == nil { fogSettings?.keyframeTrack = AtmosphereKeyframeTrack() }
            fogSettings?.keyframeTrack?.addKeyframe(AtmosphereKeyframe(
                time: t, position: src.position, size: src.size,
                density: src.density, variance: src.variance, color: src.color))

        case (.particles(let src), .particles(let i)):
            guard let fx = particleManager?.emitters[safe: i] else { return }
            if fx.keyframeTrack == nil { fx.keyframeTrack = AtmosphereKeyframeTrack() }
            fx.keyframeTrack?.addKeyframe(AtmosphereKeyframe(
                time: t, position: src.position, size: src.size,
                density: src.density, variance: src.variance, color: src.color))

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
                scale:       src.scale,
                opacity:     src.opacity))
        case (.light(let src), .light(let i)):
            guard let lm = lightManager, i < lm.keyframeTracks.count else { return }
            if lm.keyframeTracks[i] == nil { lm.keyframeTracks[i] = LightKeyframeTrack() }
            lm.keyframeTracks[i]?.addKeyframe(LightKeyframe(
                time:          t,
                intensity:     src.intensity,
                color:         src.color,
                target:        src.target,
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
                scale:       src.scale,
                opacity:     src.opacity))
        case (.fog(let src), .fog):
            if fogSettings?.keyframeTrack == nil { fogSettings?.keyframeTrack = AtmosphereKeyframeTrack() }
            fogSettings?.keyframeTrack?.addKeyframe(AtmosphereKeyframe(
                time: t, position: src.position, size: src.size,
                density: src.density, variance: src.variance, color: src.color))
        case (.particles(let src), .particles(let i)):
            guard let fx = particleManager?.emitters[safe: i] else { return }
            if fx.keyframeTrack == nil { fx.keyframeTrack = AtmosphereKeyframeTrack() }
            fx.keyframeTrack?.addKeyframe(AtmosphereKeyframe(
                time: t, position: src.position, size: src.size,
                density: src.density, variance: src.variance, color: src.color))
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
                        || expandedHeaders != lastExpandedHeaders
        lastObjectCount     = objCount
        lastBounds          = bounds
        lastExpandedHeaders = expandedHeaders

        if needsRebuild {
            rebuildEasingPopups()
        } else {
            // Lightweight pass: keep each popup's selection synced with its track.
            for b in easingPopups {
                let mode = easingMode(for: b.ref) ?? .linear
                if b.popup.selectedItem?.tag != mode.rawValue {
                    b.popup.selectItem(withTag: mode.rawValue)
                }
            }
        }
    }

    private func rebuildEasingPopups() {
        easingPopups.forEach { $0.popup.removeFromSuperview() }
        easingPopups.removeAll()

        guard let sm = sceneManager else { return }

        // Layout constants — popup sits in the right portion of the label column.
        // popupX is the un-scrolled base; layoutEasingPopups() offsets it by the
        // horizontal scroll so the dropdowns stay pinned to the frozen column.
        let popupW: CGFloat = easingPopupW
        let popupH: CGFloat = 18
        let popupX: CGFloat = labelOriginX + labelWidth - popupW - 3

        // Walk the current track list and attach a popup to:
        //   • single-mesh object rows (no groupID) — drives `obj.keyframeTrack`.
        //   • group-header rows — drives `groupKeyframeTracks[gid]` (one popup
        //     for the whole multi-part model).
        // Indented child-part rows are intentionally left out: they share the
        // group's track, so a per-part popup would be misleading (and was the
        // source of the "locked at Linear" confusion).
        let tracks = buildTracks()
        for (trackIndex, row) in tracks.enumerated() {
            let popupY = laneTop(trackIndex) + (laneHeight - popupH) / 2

            // Decide whether this row gets a popup, and what its initial easing is.
            // Object/group rows keep their dedicated handlers (tag encodes index/gid);
            // camera/light/fog/particle rows use the unified handler that resolves
            // the track from the binding's `ref`.  A row only gets a popup if its
            // track currently exists (has keyframes), matching the object behaviour.
            let action:    Selector
            let tag:       Int
            let current:   EasingMode
            switch row.ref {
            case .object(let i):
                guard i < sm.objects.count, sm.objects[i].groupID == nil else { continue }
                action  = #selector(easingPopupChanged(_:))
                tag     = i
                current = sm.objects[i].keyframeTrack?.easingMode ?? .linear
            case .group(let gid):
                action  = #selector(easingPopupGroupChanged(_:))
                tag     = gid
                current = sm.groupKeyframeTracks[gid]?.easingMode ?? .linear
            case .camera, .light, .fog, .particles:
                guard let mode = easingMode(for: row.ref) else { continue }
                action  = #selector(easingPopupTrackChanged(_:))
                tag     = 0
                current = mode
            case .importBundle:
                continue   // display-only header — no easing popup
            }

            let popup = NSPopUpButton(frame: NSRect(x: popupX, y: popupY,
                                                    width: popupW, height: popupH),
                                      pullsDown: false)
            // Use darkAqua appearance so the button renders with light text on a
            // dark background, matching the label column's colour scheme.
            popup.appearance  = NSAppearance(named: .darkAqua)
            popup.bezelStyle  = .inline
            popup.font        = NSFont.systemFont(ofSize: 9, weight: .regular)
            popup.isBordered  = false
            popup.tag         = tag   // encodes object index OR groupID

            for mode in EasingMode.allCases {
                popup.addItem(withTitle: mode.displayName)
                popup.lastItem?.tag = mode.rawValue
            }
            popup.selectItem(withTag: current.rawValue)

            popup.target = self
            popup.action = action

            addSubview(popup)
            easingPopups.append(EasingPopupBinding(popup: popup, ref: row.ref))
        }
    }

    @objc private func easingPopupGroupChanged(_ sender: NSPopUpButton) {
        let gid = sender.tag
        guard let mode  = EasingMode(rawValue: sender.selectedItem?.tag ?? 0),
              let track = sceneManager?.groupKeyframeTracks[gid] else { return }
        track.easingMode = mode
        print("[DEBUG] TimelineEditorView: group \(gid) easing → \(mode.displayName)")
        needsDisplay = true
    }

    @objc private func easingPopupChanged(_ sender: NSPopUpButton) {
        let objectIndex = sender.tag
        guard let mode = EasingMode(rawValue: sender.selectedItem?.tag ?? 0),
              let obj  = sceneManager?.objects[safe: objectIndex] else { return }
        obj.keyframeTrack?.easingMode = mode
        print("[DEBUG] TimelineEditorView: object \(objectIndex) easing → \(mode.displayName)")
    }

    /// Easing for the non-object tracks (camera / light / fog / particles).  The
    /// binding's `ref` is matched by popup identity so the index/gid travels with it.
    @objc private func easingPopupTrackChanged(_ sender: NSPopUpButton) {
        guard let mode = EasingMode(rawValue: sender.selectedItem?.tag ?? 0),
              let ref  = easingPopups.first(where: { $0.popup === sender })?.ref else { return }
        setEasing(mode, for: ref)
        print("[DEBUG] TimelineEditorView: \(ref) easing → \(mode.displayName)")
        needsDisplay = true
    }

    /// Reads the current easing mode for a track row (nil if the row has no track).
    private func easingMode(for ref: TrackRef) -> EasingMode? {
        switch ref {
        case .object(let i):    return sceneManager?.objects[safe: i]?.keyframeTrack?.easingMode
        case .group(let gid):   return sceneManager?.groupKeyframeTracks[gid]?.easingMode
        case .camera:           return camera?.keyframeTrack?.easingMode
        case .light(let i):     return lightManager?.keyframeTracks[safe: i]??.easingMode
        case .fog:              return fogSettings?.keyframeTrack?.easingMode
        case .particles(let i): return particleManager?.emitters[safe: i]?.keyframeTrack?.easingMode
        case .importBundle:     return nil   // display-only header — no track
        }
    }

    /// Writes the easing mode onto the track backing a row (no-op if no track yet).
    private func setEasing(_ mode: EasingMode, for ref: TrackRef) {
        switch ref {
        case .object(let i):    sceneManager?.objects[safe: i]?.keyframeTrack?.easingMode = mode
        case .group(let gid):   sceneManager?.groupKeyframeTracks[gid]?.easingMode = mode
        case .camera:           camera?.keyframeTrack?.easingMode = mode
        case .light(let i):     lightManager?.keyframeTracks[safe: i]??.easingMode = mode
        case .fog:              fogSettings?.keyframeTrack?.easingMode = mode
        case .particles(let i): particleManager?.emitters[safe: i]?.keyframeTrack?.easingMode = mode
        case .importBundle:     break   // display-only header — no track
        }
    }
}
