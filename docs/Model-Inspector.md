# Model Inspector

Shows and edits the selected object's transform and material. Reflects the live
selection (click in the viewport, cycle with **O**, or select a Timeline lane).

**Open:** Window ▸ Model Inspector…  ·  **⌘I**

## Controls

| Section | Controls |
|---------|----------|
| **Identity** | Name, source filename, part count, **Visible**, **Occlude when hidden** (holdout), **Object class** (Actor / Background / MacGuffin — drives Export All passes), normal mode. |
| **Material** | Metallic, Roughness, Opacity, Base colour. |
| **Position** | World X / Y / Z (copy / paste / zero). |
| **Rotation** | World Euler degrees, **YXZ** order (copy / paste / zero). |
| **Scale** | World per-axis scale (copy / paste / zero). |

Editing the transform is enabled for a **single ungrouped object** or a **uniform
multi-part group** (the whole model rotates/scales about its anchor).

## Rotation & gimbal lock

Rotation uses **YXZ Euler** — the middle axis **X (pitch)** is the singular one,
limited to ±90°. Y and Z cover the full ±180° cleanly. Near X = ±90° the editor
uses a **continuity read-back**: it picks the Euler representation closest to the
current values and holds Y/Z steady at the pole, so the displayed numbers don't
jump to an equivalent triple while you edit. The underlying orientation is always
correct; this only keeps the *displayed* angles continuous.

## Animating

Stamp a keyframe with **I** (Object or Model mode). The delta is stored relative to
the object's base transform. Per-track easing is set in the
[Timeline Editor](Timeline-Editor.md). The Path Animators can generate object
keyframes (they preserve the object's current scale).

## Persistence

Transform, material, class, visibility/holdout, and keyframes are saved with the project.
