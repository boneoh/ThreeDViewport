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
| **Models (primary)** / **(fallback)** | Where models are resolved from; the fallback is searched if a model isn't found in the primary. |
| **HDRs** | `.hdr` environment files (lighting / background / bake output). |

## Export defaults

| Setting | Notes |
|---------|-------|
| **Export width / height** | Output resolution; the camera aspect is matched to it at export. |
| **Codec** | Default export codec (ProRes 4444 or 422 HQ). See [Export](Export.md). |

> The **HDR folder / lighting HDR** path is read at startup (IBL is precomputed
> once on launch), so changing it takes effect on the **next launch**. Other
> settings apply immediately on Save.

## Persistence

Settings are written to a JSON file in the app's support location, independent of
any project.
