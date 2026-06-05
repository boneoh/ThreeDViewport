# Export

ThreeDViewport exports Apple **ProRes** `.mov` files at the resolution set in
[Settings](Settings.md). Two flows: a single video, or a multi-pass "Export All"
for compositing.

## Single export

**File ▸ Export ProRes Video…  ·  ⌘E**

Choose a codec in the save panel:

| Codec | Use |
|-------|-----|
| **ProRes 4444** | 12-bit RGB + alpha. **Color passes** write **Straight-looking full RGB with alpha = Rec.709 luma**, tagged **Premultiplied** so the RGB displays at full brightness while the luma rides in the alpha as a key — ready for DaVinci Resolve / LZX Videomancer. **Matte** passes keep a geometry-coverage alpha. |
| **ProRes 422 HQ** | 10-bit 4:2:2, no alpha; pure black background. Standard for colour-grading pipelines. |

## Sync countdown

Every export is prepended with a **3-second 3-2-1 countdown** on black followed by a
single **white flash frame** (the frame-accurate alignment point), then the content.
This makes it easy to line up the separate passes on a Resolve timeline. The
countdown goes through the same writer, so its resolution / fps / codec / colour +
alpha tags match the rest of the file and are identical across every pass.

## Export All Passes

**File ▸ Export All Passes…  ·  ⌘⇧E**

Renders a cycle of passes from one codec choice, named
`<Project>.NN.<PassName>.mov` (NN is a per-cycle take number, auto-incremented):

| Pass | Contents |
|------|----------|
| **Scene** | Everything, with FX (fog/weather/lasers/sparks). |
| **Actor Solo / Matte** | Just the Actor-class objects (solo = lit; matte = white silhouette), others held out. |
| **Background** | Background-class objects only, over the real backdrop, no FX. |
| **Background Matte** | White silhouette of the Background-class objects on black. |
| **MacGuffin Solo / Matte** | Just the MacGuffin-class objects. |
| **FX Solo / Matte** | The effects layer on black. |

Object **class** (Actor / Background / MacGuffin) is set in the
[Model Inspector](Model-Inspector.md). On 4444, color passes use luma alpha and
matte passes use coverage alpha; "background-off" passes render on solid black.

## Marks in export

If **Show marks** is on in the [Probe Inspector](Probe-Inspector.md), the position
marks render into the exported video — useful while dialing in a final take. Turn it
off for a clean delivery.

## Notes

- Export advances its own deterministic frame clock (not wall-clock playback).
- Transport controls are disabled while exporting.
