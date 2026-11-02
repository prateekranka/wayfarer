# Playback and taste verification — 2026-10-03

Source: `the local project folder` on `main`. Existing untracked project work was preserved. No commit or push was made.

Evidence directory: `work/evidence/wayfarer-playback-taste/20261003T062226Z.VwIMpv`.

## Completed checks

- Native iPhone Simulator build passed (`build-11.out`).
- All 22 pure Swift tests passed (`core-tests-02.out`). These cover neutral behavior, bounded preferences, repeated feedback, intent separation, old plan decoding, exact duration, locked ranges, and rejections.
- The focused native reference-note test passed (`e2e-note-04/report.json`). It typed through e2e's recorded keyboard action and verified the saved note on screen.
- The combined playback, comparison, export, reference, and restart workflow passed (`e2e-final-02/report.json`). It verified horizontal swiping; pause/mute preservation; style explanations; explicit feedback and duplicate suppression; separate approved examples; matching export selection; reference import; immediate note saving; and persistence after restart. The full scenario took 76.693 seconds.

## Behavior

- One foreground player owns the audio session. Results, export, source moments, and reference playback share it.
- Horizontal paging and direct selection choose the same plan used by refinement and export.
- Beat Sync variants are displayed as Balanced, Scenic, and Motion. Old Flow and Lift names are mapped when opening saved projects.
- Explicit edit and moment comparisons adjust bounded, intent-specific preferences. Each generated plan stores its applied profile snapshot.
- Imported references support estimated cut timing and timestamp notes. Approved examples preserve source ranges and project identity. Notes and examples remain reviewable evidence; comparisons and manual controls drive personalization.
- Corrupt profile recovery preserves the original file. An unreadable reference does not hide other valid references.

## Proof limits

- Simulator playback progress and mute state do not prove audible output from physical speakers. Silent Mode, headphones, Bluetooth, interruptions, and physical iPad behavior still require hardware verification.
- Reference ingestion was exercised using an actual finished MP4 through the same import service. Photos and Files picker selection remain outside the verified path because of the existing mobile-engine picker limitation.
- Imported reel cut estimates are heuristics. Editorial preference quality on real travel footage needs user examples and review.

All app-flow checks use TesterArmy e2e. The native multiline input path uses a model-free e2e executor after explicit field focus. It makes no model or OpenAI API call.

The signed device package uses build number 2. Its Swift source is the same as the tested simulator build; only build-number metadata changed. The source digest is recorded in `verification-summary.json`.

Signed development archive and Sqim upload passed (`sqim-build.out`, `build-receipt.json`). Install build 2: https://build.sqim.dev/sqim/install/j2Vd7SzSC36y .
