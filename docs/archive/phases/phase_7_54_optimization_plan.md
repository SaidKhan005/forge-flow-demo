# Phase 7.54 Optimization Plan

Updated: 2026-04-01
Owner: Codex planning / tracker truth
Purpose: define the no-visual-change optimization block that runs while Phase 8 remains blocked on vendor selection.

## Why 7.54 Exists

Phase 8 is still blocked on POS and labor vendor selection. That waiting period can be used for a narrow optimization block that does not broaden architecture, product scope, or UI design.

The user-reported concerns are:

- Barrio makes the phone hot while running
- Barrio and Flutter builds feel too large
- ForgeFlow customer builds must not accidentally carry Barrio-private payload where it is avoidable

Phase 7.54 exists to address those concerns without changing:

- the visual/UI contract
- the public/private product split
- target math, Baseline logic, or app-side data flow
- the Phase 8 adapter boundary

## Measured Current Context

The following observations were verified from the current repo and local build outputs before writing this plan.

### Runtime / Thermal Observations

- `lib/internal/barrio/widgets/barrio_bubble_hub.dart` is the hottest likely render path:
  - many always-on animation controllers
  - one merged `AnimatedBuilder` driving broad subtree rebuilds
  - multiple `BackdropFilter` glass nodes
  - custom painters and glow stacks on the home hub
- `lib/internal/barrio/widgets/barrio_ambient_leaves.dart` repaints a full-screen `CustomPaint` continuously
- `lib/internal/barrio/screens/barrio_home_screen.dart` animates a full-screen gradient scrim above a full-screen photo while also hosting ambient leaves and the bubble hub
- Learning surfaces still use entrance animation, carousel transforms, and celebration overlays, but the home shell is the clearest first-pass heat target

### Size / Packaging Observations

- Debug APKs are currently about `156 MB`, which overstates shipped size because debug builds include non-release overhead
- Verified split release Barrio APK sizes are:
  - `app-armeabi-v7a-barrio-release.apk` = `30.6 MB`
  - `app-arm64-v8a-barrio-release.apk` = `32.9 MB`
  - `app-x86_64-barrio-release.apk` = `34.1 MB`
- Top entries inside the arm64 release APK are:
  - `libflutter.so` = `10.53 MB`
  - `libapp.so` = `5.88 MB`
  - `interview_bg.png` = `2.36 MB`
  - `preston_lee_bg.png` = `2.25 MB`
  - `jim_taylor_bg.png` = `2.10 MB`
  - `handbook_bg.png` = `2.02 MB`
  - `handbook_icon.png` = `2.01 MB`
  - `MaterialIcons-Regular.otf` = `1.57 MB`
- Release icon tree shaking is currently blocked by dynamic `IconData(...)` construction in:
  - `lib/internal/barrio/widgets/handbook_chapter_rail.dart`
  - `lib/internal/barrio/widgets/learning_surface_card.dart`

### Local Workspace / Storage Observations

- `build/` is currently about `4311 MB`
- `.dart_tool/` is currently about `165 MB`
- `docs/` is currently about `96.6 MB`
- `assets/` is currently about `16.25 MB`

Local workspace size is not the same thing as shipped app size, but both matter to the user concern and should be handled explicitly.

## Non-Negotiable Rules

- Do not make visual or UI changes as part of 7.54
- Do not remove or redesign motion patterns unless the rendered result remains visually equivalent
- Do not touch target math, Baseline logic, connector boundaries, or Phase 8 data contracts
- Do not broaden into Phase 9 auth/persistence work
- Preserve the ForgeFlow vs Barrio dual-build identity split from 7.53
- Keep tracker truth honest: 7.54 is an interim optimization block, not a replacement for the blocked Phase 8 roadmap

## Prompt Breakdown

## 7.54a - Barrio Thermal / Render-Cost Pass

### Goal

Reduce runtime heat and unnecessary frame work in Barrio, especially on the home shell, without changing the visible presentation, interaction model, or motion language.

### Read First

- `PROJECT_TRACKER.md`
- `docs/phase_7_54_optimization_plan.md`
- `lib/internal/barrio/screens/barrio_home_screen.dart`
- `lib/internal/barrio/widgets/barrio_bubble_hub.dart`
- `lib/internal/barrio/widgets/barrio_ambient_leaves.dart`
- `lib/internal/barrio/widgets/learning_carousel.dart`

### In Scope

- repaint containment
- animation lifecycle cleanup
- ticker consolidation where visually safe
- pausing or muting animation work when not visible
- image decode sizing / precache work that does not alter visuals
- reducing full-subtree rebuild frequency

### Out of Scope

- changing layout, color, timing intent, copy, or interaction design
- removing the bubble hub, leaves, or glass look
- changing product identity or navigation structure

### Implementation Intent

1. Contain repaint cost on the Barrio home shell so animated islands do not trigger avoidable full-screen redraws.
2. Reduce always-on ticker pressure in `barrio_bubble_hub.dart` while keeping the same apparent motion.
3. Ensure ambient/background animation work stops when the route is covered or the app is backgrounded.
4. Keep `BackdropFilter` work as localized as possible without changing the glass appearance.
5. Precache and decode large background images at appropriate display sizes where safe.

### Acceptance Criteria

- No visible UI changes when comparing before vs after manually
- Barrio home shell still renders the same layered composition and motion style
- No removed destination bubbles, leaves, or glass layers
- Code shows narrower repaint scope and less broad frame-by-frame rebuild pressure
- Focused Barrio widget tests still pass

## 7.54b - Release-Size and Asset-Compression Pass

### Goal

Reduce release package size without changing visible output.

### Read First

- `PROJECT_TRACKER.md`
- `docs/phase_7_54_optimization_plan.md`
- `pubspec.yaml`
- `lib/internal/barrio/widgets/handbook_chapter_rail.dart`
- `lib/internal/barrio/widgets/learning_surface_card.dart`
- `assets/internal/barrio/`
- `assets/images/`

### In Scope

- enabling release icon tree shaking
- lossless or visually-lossless asset compression
- asset format improvements where output remains visually equivalent
- release build verification and size comparison

### Out of Scope

- changing icons or artwork design
- changing motion or UI layout
- removing required assets from Barrio

### Implementation Intent

1. Replace dynamic `IconData(...)` construction with constant/icon-tree-shake-friendly definitions.
2. Compress the heaviest Barrio media assets first:
   - `interview_bg.png`
   - `preston_lee_bg.png`
   - `jim_taylor_bg.png`
   - `handbook_bg.png`
   - `handbook_icon.png`
3. Re-run release builds using the normal tree-shaking path.
4. Compare final output against the current split-release baseline documented above.

### Acceptance Criteria

- `flutter build apk --flavor barrio -t lib/main_barrio.dart --release --split-per-abi` succeeds without `--no-tree-shake-icons`
- Release APK sizes decrease from the current baseline, or any non-improvement is explained with real evidence
- No visible art/UI regressions in Barrio

## 7.54c - Flavor Asset-Bundle Containment + Space Hygiene

### Goal

Reduce avoidable shipping and local-storage overhead by tightening flavor-private asset boundaries and documenting cleanup paths.

### Read First

- `PROJECT_TRACKER.md`
- `docs/phase_7_54_optimization_plan.md`
- `pubspec.yaml`
- `README.md`
- `android/app/build.gradle.kts`
- any asset-manifest outputs produced by local flavor builds

### In Scope

- separating shared vs Barrio-private asset packaging
- verifying whether ForgeFlow bundles Barrio-private media today
- the narrowest workable flavor-containment implementation
- local cleanup/build-output documentation

### Out of Scope

- merging the two brands back together
- removing Barrio private assets from the repo
- changing runtime product structure

### Implementation Intent

1. Audit the current Flutter asset declaration path and prove whether ForgeFlow builds carry Barrio-private media.
2. Implement the smallest reliable packaging boundary that prevents ForgeFlow customer builds from shipping Barrio-private media where possible.
3. Keep Barrio fully functional after the asset-boundary change.
4. Document workspace cleanup commands and the difference between:
   - local disk usage
   - debug build size
   - real release package size

### Acceptance Criteria

- ForgeFlow flavor verification shows Barrio-private media is no longer bundled, or the repo documents the exact technical limitation if a clean split is not practical without a larger restructure
- Barrio still loads all required private media correctly
- README or supporting docs clearly explain cleanup paths such as `flutter clean`
- Verification captures both flavor behavior and size implications

## Execution Order

1. Run `7.54a` first because thermal/runtime cost is the user's most immediate experience issue.
2. Run `7.54b` second because release-size reduction depends partly on code cleanup plus asset optimization.
3. Run `7.54c` third because asset-bundle containment should build on the cleaned and measured asset set from `7.54b`.

## Verification Expectations

- Prefer measured verification over guesses
- Capture release-size numbers with exact build commands
- Keep source references concrete in tracker updates
- If a proposed optimization changes visible output, stop and treat it as out of scope for 7.54
