# Verification

Wayfarer is a working native V1. This report separates compilation, planner checks, app behavior, and exported media. It does not claim App Store release readiness.

## Environment

- Xcode 27.0, Swift 6.4, iOS 27 simulator. Deployment target: iOS/iPadOS 26.
- Release and Debug simulator builds, strict Swift concurrency, warnings as errors.
- Simulator: `087CF025-E3C7-48D6-B2B8-292DDDC39B50`.
- Bundle: `com.prateek.wayfarer`.
- Durable evidence: `work/evidence/travel-montage/20261002T155206Z.r3Acmc`.
- App behavior framework: TesterArmy e2e 0.15.2, mobile engine 0.9.0.
- Final tested Release binary SHA-256: `5f178e40479e40df765dd128f980b15d35dcb968e17e628c5243b8f2b5c5e02f`.

The installed binary matched this hash before the final checks. See `current-release-bundle.json` and `installed-build-audit.json`.

## Confirmed checks

| Check | Result | Evidence |
| --- | --- | --- |
| Final Release simulator build | Passed | `build-finalization41.txt` |
| Final Debug simulator build | Passed | `build-debug42.txt` |
| Pure Swift planner and refinement checks | 14 passed | `core-final.txt` |
| Complete native workflow | Passed with strict elapsed playback assertions | `e2e-final-workflows45/report.json` |
| Final 85-source workflow | Passed in 67.20 seconds | `e2e-final54/report.json`, `scale-final-metrics.json` |
| Final settings and persistence workflow | Passed in 61.39 seconds | `e2e-final54/report.json`, `settings-final-metrics.json` |
| Focused export timing regression | Passed | `e2e-timing53/report.json` |
| Files picker opening and cancellation | Passed | `e2e-settings-files48/report.json` |
| Final 15-second export | 1080 × 1350, 450 video frames; video and audio start at zero and end at 15 seconds | `verified-final-settings-probe.json` |
| Final 30-second export | 1080 × 1920; movie and audio last 30 seconds; video ends one output frame earlier | `verified-final-scale-probe.json` |
| Full decode of both final exports | Passed without decoder errors | `verified-final-settings-decode.err`, `verified-final-scale-decode.err` |
| Original fixture validation | 85 unique H.264 files, all decoded | `work/fixture-generation/full/verification-rerun.log` |

The complete workflow created a project from 12 encoded videos, analyzed 24 candidate moments, analyzed music, and generated three variants. It verified playback for each variant, replaced a moment, locked two moments, regenerated, exported, saved to Photos, restarted, reopened, and confirmed both locks. Create also remained usable after returning to the library. This complete check ran on Release31 before the final rendering changes. The final Release41 checks cover rendering, settings, and the 85-source workflow.

The montage scenario passed in `e2e-final-workflows45`. That older report's overall status is `error` because its separate settings scenario failed during a driver timeout. The final settings check in `e2e-final54` supersedes that failure; the older report is retained unchanged.

Playback assertions match the elapsed value at the start of the label. The total-duration value cannot satisfy them. The earlier broad matcher was corrected. The complete workflow and final scale workflow passed with the corrected matcher.

The final scale workflow analyzed all 85 encoded sources, totaling 510 seconds, into 170 candidate moments. It generated three 30-second variants with 26, 35, and 22 segments. e2e verified an advancing playback clock for all three and exported the selected version. This run used a verified preinstalled app. Its duration includes navigation, analysis, planning, previews, and export. It is specific to short, low-resolution illustrated footage on this simulator.

The settings workflow changed duration and energy, restarted, reopened, confirmed the energy value, selected 4:5, regenerated, verified playback, and exported. Changes to creative direction prevent export of an obsolete plan. The settings form now uses a navigation page.

The final media contains H.264 video and AAC audio. Both exports decode completely. The 15-second 4:5 file has exact track endpoints. The final 30-second vertical file has 899 video frames and a video endpoint of 29.966667 seconds. Its audio and movie duration are exactly 30 seconds. The exporter permits at most one output frame of endpoint rounding. The earlier 30-second complete-workflow artifact has 900 frames and exact 30-second endpoints (`verified-native-montage.mp4`). These measurements do not prove every input format or editorial quality on real travel footage.

## Fixes verified during development

The native workflow exposed a Swift 6 isolation crash in the Photos change callback. The callback is now explicitly `@Sendable` and captures only the exported URL. UI updates occur after the awaited operation. The complete Photos save and restart workflow passed. [Apple documents PhotoKit's change-block execution queue](https://developer.apple.com/documentation/photos/phphotolibrary/performchanges(_:completionhandler:)).

A 15-second native export initially ended its video track two frames early. Explicit export ranges, alternating tracks, and additional source context alone did not fix it. The shared preview/export path now detects a short output, makes one bounded recovery attempt, and trims the encoded context with the native passthrough preset. It validates track timing before committing the file. The focused regression and final settings workflow both passed. File inspection confirmed 450 frames and exact 15-second video/audio endpoints. [Apple describes native export presets and output time ranges](https://developer.apple.com/documentation/avfoundation/avassetexportsession).

Previews pause under other screens, while the app is inactive, and when Reduce Motion disables automatic playback. Compilation and the active playback workflows passed. Separate accessibility and lifecycle scenarios remain in release validation.

## Import testing limitation

Photos opening and cancellation passed during the initial loading state. After loading, the screenshot showed the generated video and picker controls, but e2e returned only the root and app container. Selection could not be tested through this mobile engine. See the loaded screenshot and failure screen in `e2e-settings-photos43`. The diagnostic remains in `tests/photos.e2e.ts` with an explicit default skip and an opt-in environment flag.

Read-only Photos database inspection confirmed the generated video. This proves storage, not selection. Files opening and cancellation passed; actual audio/video file selection is not yet verified. No alternate app-testing driver was used. An explicit exception request remains pending under the user's e2e-only rule.

## Release validation still required

- Real travel collections, including long 4K/HDR videos, variable frame rates, and large files.
- Physical iPhone thermal behavior, peak memory, battery use, and background interruptions.
- iPad layouts, rotation, large Dynamic Type, VoiceOver, and Reduce Motion.
- Photos imports from iCloud, inaccessible assets, and Files audio/video providers.
- External share destinations and permission-denied recovery.
- Human review of moment selection, pacing, crop placement, and music quality.

Synthetic footage exercises the real analysis and rendering services. It contains no precomputed candidate scores or fixed montage decisions. Core tests were not repeated after the final changes because those changes affect native rendering and presentation; the pure planner code did not change.
