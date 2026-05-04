# ThreeDViewport — Enhancement Backlog

Items deferred during development, in rough priority order.

## Explicitly Deferred (came up during design discussions)

1. ~~**Light keyframes / lights lane in Timeline Editor**~~ ✅ DONE  
   Intensity, colour, direction, and position animated. One lane per light in Timeline Editor. Insert/edit/retime/delete work identically to object and camera lanes. Saved in project file (v6).

2. **Easing curves on keyframe interpolation**  
   Currently all interpolation is linear. Add per-keyframe or per-segment easing (ease-in, ease-out, ease-in-out, bezier handles).

3. ~~**In-place keyframe editing mode**~~ ✅ DONE  
   Select a diamond, press **Return** to enter edit mode (amber diamond + EDITING badge), move object/camera live in viewport, **Return** to commit or **Esc** to cancel.

4. **Multi-select objects** (Shift+click in HUD or viewport)  
   Select and transform multiple objects simultaneously.

## Natural Gaps / Quality of Life

5. ~~**Object scale keyframes**~~ ✅ DONE  
   Option+`=` scales the selected object up 5%; Option+`-` scales it down 5%. Scale is extracted from the transform matrix and stored in `TransformKeyframe.scale`, which the renderer already reconstructed as TRS — so scale keyframes work end-to-end with no additional changes.

6. **Copy / paste keyframes**  
   Select one or more diamonds and copy them to another time or another track.

7. ~~**Loop playback toggle**~~ ✅ DONE  
   `↺` button in the Timeline transport bar (after Play/Pause) toggles loop mode. When active it lights up in the accent colour. `Timeline.tick()` wraps `currentTime` back to 0 instead of stopping. Saved in project file (v7).

8. **Frame rate selection**  
   Currently hard-coded at 30 fps. Allow 24, 25, 60 fps options (affects export and timeline tick spacing).

9. **Clean up menu structure**  
   Review and reorganise the application menus — consolidate related items, check shortcut conflicts, ensure consistent ordering across File / View / Window menus.

10. **Alternate Feedback algorithms**  
    Currently the Feedback delay-line uses a simple weighted blend. Add selectable algorithms — e.g. additive accumulation, chromatic blur, hue-rotate-per-tap, or invert-on-blend — selectable from the Feedback panel.

11. ~~**UI Interaction — linked viewport / timeline editor controls**~~ ✅ DONE  
    - **O / C / L keys in viewport** → corresponding row in Timeline Editor is highlighted.  
    - **Click any row or label in Timeline Editor** → viewport switches to the matching mode (camera / object N / light N) and selection.  
    - **Double-click a diamond** → enters keyframe Edit mode immediately (no need to select then press Return).  
    - **Unrecognised keys in Timeline Editor** → forwarded to the viewport, so all viewport shortcuts (O, C, L, arrows, scale, etc.) work regardless of which panel has keyboard focus.
