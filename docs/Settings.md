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
