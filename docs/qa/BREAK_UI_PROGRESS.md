# Wayfarer screen catalog and break-ui work

Goal: use TesterArmy e2e to cover first use and multiple reels of different durations and types, capture every distinct screen and state, fix observed issues, then create an editable pen.dev document with motion represented.

Evidence root: `work/evidence/wayfarer-break-ui/20261006T201845Z.JjND42`.

## Current baseline

- Canonical checkout: `the local project folder`, branch `main`, no commits. All existing product files are untracked and preserved.
- Baseline: 54 source, test, and configuration files copied before changes; SHA-256 manifest saved.
- E2E target after ContentHelper finishes: iPhone 18 Pro Max, iOS 27.0, UDID `8374D63E-FE43-43D4-B05A-9926E3D96D68`. `e2e.catalog.config.ts` is pinned to this device and target name. It is currently shut down; the booted iPhone Duo remains reserved by ContentHelper.
- QA identity: `com.prateek.wayfarer.breakui`. The consumer identity is `com.prateek.wayfarer`.
- The current app's first-use entry is its empty home screen. It has no separate onboarding wizard.
- User approved removal of the previous audio review's downloaded model folder. The source videos and prior review reports remain.
- Disk and Xcode proof preflights passed after that removal. Baseline, fixture and fixture-layout QA builds succeeded. The latest fixture environment covers navigation destinations. App behavior remains unverified until e2e passes.
- The `One` and `1,000` break-ui states now construct one-clip, one-moment model rows instead of copying an existing project. The latest generic iOS Simulator SDK compile passed in `FixtureCountsBuild.xcresult`, including the moment-count locator; the app was not installed or launched.
- Source review found hard-coded plural labels for single clips, moments, edits, notes, ranges and cuts. A shared count formatter now covers the visible counts and import progress; `CountCopyBuild.xcresult` passed. The one-clip, one-moment and one-lock e2e assertions remain pending visual verification.
- The first e2e attempt stopped before running tests: shared agent-device daemon 0.21.20 versus the mobile engine's pinned client 0.21.18. Task-specific `AGENT_DEVICE_STATE_DIR` passed that check and exposed a live foreign simulator lease. A separate 0.21.20 dependency did not change the engine's pin and was removed. Preserve the shared daemon.
- User selected "Wait for ContentHelper to finish". Do not boot another simulator or reclaim its live lease. The ContentHelper task is still active and has also reported waiting for simulator access.
- Catalog captures now save a screenshot and a redacted native control tree through e2e. Use `--debug` so the layout transcript is retained. Captures remain pending. The stress case includes a landscape-left capture for wide-layout review.
- All 13 catalog cases pass the e2e collection check across seven files, including six reel scenarios. The stress case covers one-clip and one-moment labels, 320-point and landscape widths, large text and RTL. The style flow asserts and captures a one-note reference row. The import case covers Photos and Files pickers from home and while appending clips. No catalog case has run against the app. Build identity, source hashes and bundle hashes are in `pre-test-build.json`. Asset color values and button motion values are in `design-tokens.json`.
- Numeric test filenames set the collection order: fresh first use, fresh import pickers, six saved reels, then the dependent creative, detail and style cases, followed by break-ui stress. `catalog-selection-ordered-r1.json` confirms that order; the import case already reinstalls its QA app state.
- The temporary direct driver dependency and its lockfile changes have been removed. Both dependency files match the saved baseline.
- Codex's model selector now shows GPT-6 Luna, Max effort, with Fast mode enabled for this task. The selection was verified in this task's UI. `model-settings.json` records that evidence. The earlier delegation question is no longer needed. e2e uses its recorded deterministic executor; no e2e model calls are claimed.
- Pen now has an open setup document from another task. Its canvas skill, schema, execute API, component guide and script guide have been read. No Wayfarer document has been created. Defer final document creation until fixes are verified.
- `scripts/qa/pen-components.js` defines source-based themed variables and reusable primary actions, duration buttons and status labels. Its syntax check passed. It has not been executed on a canvas. Native font, icon and geometry comparison remains pending.

## Rendered value map

| Surface | Values and source | Type and limit | Optional |
| --- | --- | --- | --- |
| Home | `MontageProject.name`, `createdAt`, assets count, plans count, target duration, stage, needsGeneration, thumbnail filename | name unbounded; date; nonnegative collection counts; duration 5–180 in UI; defined enum; local image | thumbnail optional |
| Setup | project name, clip count, moments count, notice, warnings; soundtrack title, duration and BPM; target duration; intent title/subtitle; output ratio; creative values and original sound | name/title/warning unbounded; finite number; six intents; four ratios; sliders 0–1 | music, BPM, notice, thumbnail optional |
| Processing | progress title/detail, completed, total, export progress, thumbnail list | strings unbounded; counts; progress 0–1 | media can be absent |
| Results | plan name/summary, seconds, moment count, page count/position, selected plan, new edits flag, playback state/time, sound state and errors | names unbounded; finite seconds; counts; booleans; error strings unbounded | errors and exports optional |
| Refinement | locked count, segment/source indices, source start and duration, semantic tags, thumbnail, lock status, alternatives list | counts; finite numbers; tags unbounded; list unbounded | thumbnail/tags can be absent |
| Source browser | selected category, filtered moments count, semantic tags, duration, thumbnail | seven filters; counts; tags unbounded | zero results and absent media valid |
| Export | plan name, pixel dimensions, format, saving/saved state, reference state, video path | four output dimensions; booleans; local file | export file optional until complete |
| My Style | feedback count/save status; enabled flag; intent; dimension values/labels; feedback message; reference list/title/duration/note count; example list/project name/plan name/ranges | strings unbounded; six intents; values -1–1; reference max 180 sec/1 GB; notes max 100, text max 1000 on save | references/examples may be empty |
| Reference detail | title, player/time, note input and saved notes, note timestamp, cut count, average duration, confidence, intent, pacing message | title unbounded; note input unbounded, saved text 1000 characters; max 100 notes; finite numbers | pacing estimate and message optional |
| Approved example | project and plan names, original clip/range indices and times | names unbounded; source ranges list unbounded; finite times | source file can be unavailable |

## Remaining work

1. Wait for ContentHelper to finish, verify the simulator lease is free, and run the first-use catalog test.
2. Create separate reels covering 15, 30, 45 and 60 seconds, custom lengths, all six intents, and all four output ratios.
3. Capture import, processing, paused, draft, setup, preview, settings changed, refinement, source/alternatives, style, reference, export, save and error states.
4. Run the compiled DEBUG-only Demo data / Worst case fixture switch. It includes empty, one, long Unicode names, missing images, 300 clips and 1,000 projects. Fixture behavior remains unverified.
5. Run applicable break-ui checks at narrow and wide native layouts, large text, light/dark appearance, and RTL. Record observed findings before applying fixes already authorized by the user.
6. Rebuild, reinstall and rerun affected e2e scenarios. Record build identity and reel duration/format evidence.
7. Create a new pen.dev file. Give each captured state editable text, vector and component layers. Add screenshot references and motion states/specifications.
8. Validate the document through pen.dev tools, reopen it, inspect editable layers and compare renders against native captures. Keep the goal active until this evidence exists.
