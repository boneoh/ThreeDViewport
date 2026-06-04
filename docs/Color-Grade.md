# Color Grade

A lightweight grading pass applied to the whole composited image — in the viewport
**and** in exports.

**Open:** Window ▸ Color Grade…  ·  **⌘⇧G**

## Controls

| Control | Range | Notes |
|---------|-------|-------|
| **Exposure** | 0.1…4.0 | Applied **pre-tone-map** in the scene shader, so it can tame HDR/IBL highlights (not part of the post pass). |
| **Brightness** | −1…+1 | Uniform add. |
| **Contrast** | 0…3 | Scales around the 0.5 midpoint. |
| **Gamma** | — | Midtone curve; >1 lifts, <1 darkens. |
| **Reset** | — | Returns all values to identity (shown only when non-identity). |

Brightness / Contrast / Gamma run as a final full-screen post-process; Exposure is
folded into the main shader. The grade is identity by default and adds no cost when
untouched.

## Persistence

All grade values are saved with the project and applied during export.
