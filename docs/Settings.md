# Settings

Global application settings, stored outside any project and seeded into new
sessions. Edits apply on **Save**; **Cancel** discards.

**Open:** ThreeDViewport ▸ Settings…  ·  **⌘,**

## Folders

Default locations used by file pickers and Export:

| Folder | Used for |
|--------|----------|
| **Projects** | `.3dvp` project files. |
| **Movies** | Exported ProRes `.mov` files. |
| **Favorite Models** | Your curated favourites — typically macOS aliases (created by the Model Inspector's **Add to Favorites** button) pointing at files in the Model Library, organised into the same shape subfolders. Tried first when resolving a model. |
| **Model Library** | The full collection (generated, downloaded, etc.). Searched if a model isn't found in Favorite Models. |
| **HDRs** | `.hdr` environment files (lighting / background / bake output). |
| **Exported Models** | Where **File ▸ Export Model…** writes the baked `.glb` (the Export panel opens here). |
| **Exported Projects** | Where the companion **source project** (`.3dvp`) is saved when you export an **envelope**, so the glue can be recovered later — see [Glue](Glue.md#export-the-glued-unit-as-a-model). |

## Export defaults

| Setting | Notes |
|---------|-------|
| **Export width / height** | Output resolution; the camera aspect is matched to it at export. |
| **Codec** | Default export codec (ProRes 4444 or 422 HQ). See [Export](Export.md). |

## Auto-keyframe on edit

When you move or change an entity that is **already animated** (has keyframes) — via
the viewport (mouse drag, rotate, arrow keys, ± depth/scale) or a panel slider — these
two settings capture the change as a keyframe so a scrub or play doesn't discard it.
Objects with **no** keyframes are unaffected (their edit is the static base pose and
already persists).

| Setting | Effect |
|---------|--------|
| **Update the keyframe under the playhead** | If the playhead is on (within ~1.5 frames of) a keyframe, that keyframe is updated to the new pose. |
| **Insert a new keyframe when between keyframes** | If the playhead is between keyframes, a new one is added at the playhead. |

Both default off; enable either or both independently. Objects driven by a
[Spin / Orbit](Spin-Path-Animator.md) rate marker are skipped (their keyframes are
regenerated from the markers). The Paste/Zero coordinate auto-stamp is independent of
these settings.

> The **HDR folder / lighting HDR** path is read at startup (IBL is precomputed
> once on launch), so changing it takes effect on the **next launch**. Other
> settings apply immediately on Save.

## Persistence

Settings are written to a JSON file in the app's support location, independent of
any project.

## New Instance

Just below **Settings…** in the **ThreeDViewport** menu, **New Instance** launches a
second, independent copy of the app in its own window. Use it to copy coordinates or
keyframes between two projects — see
[Across two app instances](Coordinate-Clipboard.md#across-two-app-instances).
