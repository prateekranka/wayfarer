# Wayfarer

Wayfarer is a native iPhone and iPad app that makes travel montages from raw clips, a song, and creative direction. The user chooses the feeling. The app chooses the moments, source ranges, sequence, and cuts.

The app targets iOS and iPadOS 26 or later. Production code uses Apple frameworks only. There is no account, network client, cloud upload, analytics SDK, or OpenAI API integration.

## Getting started

Requirements: macOS with Xcode 27 and Swift 6, XcodeGen 2.45 or later, and an iOS or iPadOS 26 simulator or device. Node.js and npm are needed for the end-to-end tests.

1. Clone the repository and enter its directory.

   ```sh
   git clone https://github.com/prateekranka/wayfarer.git
   cd wayfarer
   ```

2. Run `xcodegen generate` to generate the Xcode project from `project.yml`.
3. Open `Wayfarer.xcodeproj` in Xcode.
4. Select the `Wayfarer` scheme and an iPhone or iPad target, then run the app.

The Xcode project is included, and `project.yml` is the source for regenerating it. Regenerate it after changing the project configuration.

For a physical device, set your own signing team in Xcode. Simulator builds do not require a signing team.

The app includes two public sample trips: 12 clips and 85 clips. These are bundled illustrated H.264 movies, created with the developer fixture generator. They are clearly identified as sample footage. They go through the real video analysis, music analysis, planner, preview, refinement, and export pipeline. The original sample soundtrack is synthesized locally. No personal Photos library is required for development.

## Product flow

Create a Montage → choose videos from Photos or Files → automatic analysis → choose a song → choose length and feeling → Make My Reel → watch three edits → replace or lock moments → Try Another Edit → export → save to Photos or share.

Supported feelings are Beat Sync, Story, Cinematic, Highlights, People, Places, and Travel. Story/Highlights, Calm/Energetic, and Longer shots/Fast cuts controls change planner parameters. Output formats are 9:16, 1:1, 4:5, and 16:9. Original sound has a global level.

The app refuses a song that is too short and footage that cannot fill the requested length. It does not secretly loop music, freeze frames, or repeat overlapping source ranges to reach a duration.

Project options → Add more clips imports footage into the current journey. Existing edits and locks remain available. Generate another edit to include the new candidates.

## Structure

| Directory | Responsibility |
| --- | --- |
| `Core` | Codable domain types, scoring, constrained planning, refinement, validation |
| `CoreTests` | Pure Swift Testing tests and an analysis fixture from generated media |
| `Sources/Media` | Photos transfer, Files import, streaming fingerprints, bounded thumbnail cache |
| `Sources/Analysis` | Video and music analysis actors |
| `Sources/Persistence` | Atomic project manifests and local project packages |
| `Sources/Rendering` | AVFoundation composition, preview, playback observation, export |
| `Sources/Demo` | Encoded synthetic movies and original synthetic music |
| `Sources/App` | Observation state, workflow coordination, app entry, visual tokens |
| `Sources/Features` | Home, setup, results, source browser, moment refinement, export |
| `tests` | TesterArmy e2e tests for native application behavior |

`VideoAnalyzing`, `MusicAnalyzing`, and `MontagePlanning` separate intelligence from the UI. Video and music services exchange value types with the planner. A future remote intelligence provider can implement an async analysis boundary. Upload consent and transport would need an explicit future product design.

## Finding moments

The video analyzer decodes up to two frames per second, with a maximum of 600 samples per source. Frames have a maximum dimension of 384 pixels. It applies the source's display orientation before analysis.

Vision supplies face rectangles, human rectangles, saliency, image labels, and aesthetics scores where supported. Pixel measurements supply luminance, contrast, a Laplacian blur estimate, composition, and compact spatial/color descriptors. Temporal descriptor differences estimate stability, and motion where optical flow is unavailable. These are heuristics, not a trained camera-shake classifier.

Shot changes establish scene boundaries. Each scene is divided into useful regions that can support longer shots. A candidate stores its score components, semantic tags, subject bounds, capture date, representative frame, and strongest sampled time. The planner centers a shorter selection around that strongest time, within the candidate's bounds. Analysis sampling frequency does not force every shot to last half a second.

`ClipSignalAnalyzer` adds two signals to each moment. Apple's built-in sound model reports what is heard, such as laughter, traffic, or waves. Sounds of people raise a moment's score, and sounds of a place raise it for Travel, Places, and Story. Optical flow measures real speed and direction. It replaces the frame-difference motion estimate where it runs, makes Cinematic prefer calm shots, and penalizes a cut where clear movement reverses. Both are optional, so a clip keeps working if a model cannot run.

Decoded frames are released after each sample. Only compressed thumbnails and small descriptors remain in the analysis run. Thumbnails are written locally. Cross-clip descriptor distance groups probable duplicates. This comparison is deliberately conservative and approximate.

No smile, emotion, action, or location claim is fabricated when a classifier is unavailable. Low-confidence semantic labels are omitted.

## Understanding music

`MusicAnalysisService` streams mono audio into `MusicSignalAnalyzer` in `Core`, so a long song is never held in memory. Each 12 ms step is split into bass, mids, and highs. Sudden rises in those bands find hits, and each hit records which band carried it.

Beats come from a search across the whole song that favors strong hits and an even pace. The tempo estimate updates every two seconds, so beats can follow a song that speeds up or slows down. A preference near 120 BPM settles half-time and double-time, which can still be wrong for very slow or very fast songs.

Bars come from bass hits and chord changes at each beat. The analyzer tries four and three beats per bar, and the bar position may shift during a song. If the evidence is weak, it reports no downbeats rather than guessing, and the planner uses strong beats instead. This is the common case: on five real songs, only one reported bars.

It also finds builds, which are rises lasting at least three seconds. Drops are the song's biggest sustained jumps, and the bass must come in too. Pauses are short gaps in the sound. Sections start where the sound changes between groups of four bars. Sections are not named as verse or chorus. Vocals and lyrics are not analyzed. `TimedLyric` provides the future domain boundary for legitimately obtained timed text.

The planner prefers cutting on drops and then the start of a bar, starts the song so a drop lands about two-thirds into the edit, treats the drop as the payoff, and shortens shots near the top of a build in styles that allow it. Songs analyzed by older builds keep working, but only gain these results when analyzed again.

Tests in `CoreTests/MusicSignalAnalyzerTests.swift` score this against generated tracks with known beats, bars, builds, and drops. Generated tracks are cleaner than real music. Five real songs were used to tune drop, bass, and fade-in handling, but no hand-marked timings were available, so accuracy on real songs is not measured.

Music longer than 30 minutes is rejected. Protected content is rejected. Music must cover the selected montage duration.

## Planning an edit

The planner uses deterministic seeds and a bounded beam search. It combines individual quality and intent scores with sequence costs for repeated sources, similar scenes, chronology, and pacing. Story chronology is a soft score. Unknown capture dates can use import order.

The search retains a duration-progress path so quality ranking does not remove every feasible completion. Complete plans are evaluated against the desired shot count. This keeps Cinematic slower than Beat Sync when the source material allows it.

Planning uses a 600-tick-per-second grid. Neighboring unlocked segments can exchange a small amount of duration to align a cut with a music event. Every plan is validated before preview and export.

Three variants have different profiles, prior-choice penalties, seeds, and music starts. A diversity check requires different selections or substantial sequence changes. A fully locked edit cannot generate three new visual versions; the app asks the user to unlock a moment.

Each style has a recipe in `Core/Recipes/recipes.json`: its shortest and longest shot, beats per shot in loud and quiet parts of the song, the most moments from one clip, how far a cut may move to reach a musical event, and how it opens and ends. Recipes change sequence scores in `RecipePacing`. They also reward the strongest moment at the song's biggest build, and penalize two face shots, two still shots, or two shots of the same size in a row. After the search, `fitShotLimits` lengthens shots below the shortest length by taking time from the longest ones. Rules are soft, so a small trip or locked moments can still produce an edit. A shot stays short if its moment is shorter than the limit.

Shot size is a rough estimate from faces, subject size, and scene labels. Vision's models do not run in the iOS Simulator, so faces, labels, and subjects are all empty there. Rules that use them can only be checked on a device or with frames analyzed on a Mac.

`EditPlanner` writes each edit's decision list from the plan, the song, and the recipe: punch-ins (Z1), beat pulses (Z2), slow push-ins (Z4), and slow pull-outs (Z5). The IDs come from the short-form edit spec. The list is worked out when an edit is built, so changing a shot can never leave a stale zoom behind. A shot has one kind of zoom. Slow moves need at least 1.5 seconds, the song's biggest moment gets a punch-in where the style allows one, and the two beats before it stay quiet. Sources smaller than the output are limited to 120%. `LookCompositor` draws zooms around the subject and inside the picture, so they never spread into letterbox bars. Users cannot edit individual zooms yet.

Locks retain the exact source range and duration. The planner inserts them near their saved timeline position. Timing is approximate when surrounding pacing changes. Rejected sources and moments are excluded. The result retains decision reasons, alternatives, and quality metrics.

`PlanRefiner` changes a result without rerunning analysis. It validates source bounds, overlap, duration, and locks after replacement, resizing, movement, or removal.

## Preview and export

Preview first uses an AVPlayer composition at a 576-pixel render width. If the platform cannot play that composition, the app prepares a lower-resolution MP4 with the same decisions and audio mix. It caches up to four preview files per project. Switching back to a cached edit does not render it again. Preview preparation never requires a full-resolution export or another analysis pass.

Compatible composition tracks handle mixed source formats. Source orientation, crop placement, music placement, and audio levels use the same assembly path for preview and final export. Cumulative cut boundaries are rounded to one shared 600 Hz time grid. Native instruction validation prevents uncovered ranges before playback or export.

Video tracks alternate at cuts. The final source retains bounded decoding context, while playback stops at the planned duration. Preview files and final exports use the same output validation. If a native export ends more than one output frame early, the renderer makes one recovery attempt. It then trims the encoded file with AVFoundation's passthrough preset and validates the result before committing it. This step preserves the planner's decisions and avoids another video encode during trimming.

Subject bounds guide cropping. Wide footage uses fit placement when an important subject would be cropped or no reliable subject is available. V1 does not add blurred backgrounds or animated crop tracking.

## Color

A custom video compositor (`LookCompositor`) draws every frame with Core Image. Preview and export use it the same way. For each frame it places and crops the shot, corrects it, applies the style look, then adds grain and a vignette. Letterbox bars stay pure black.

Shot correction makes clips from different cameras and light look like one edit. When an edit is built, the builder reads three small frames from each shot and measures its average color, brightness, and brightest areas. `ShotCorrection.matched` then gives each shot a gentle exposure change and white-balance gains. The target brightness sits between a standard exposure and the edit's median shot, so a dark, moody trip stays a little darker. Night shots and shots with bright lights are brightened less. Strong color casts, such as sunsets, are mostly kept; only weak casts are fixed. Measurements are cached per source range. They use the whole frame, not only the cropped area.

Each edit style has its own look (`ColorLook.style(for:)`), applied automatically:

| Style | Look | Character |
| --- | --- | --- |
| Beat Sync | Punchy | Strong contrast and color, light vignette |
| Story | Warm memory | Warm, soft blacks, gentle highlights, light grain |
| Cinematic | Film | Cool shadows, warm highlights, soft highlights, grain, stronger vignette |
| Highlights | Clean pop | Clear contrast, extra color in muted areas |
| People | Soft skin | Gentle and warm, skin tones kept close to the original |
| Places | Rich color | Extra color in skies and greenery |
| Travel | Journey | Warm and clear, light grain, gentle vignette |

Looks run at 50–70% strength, so footage still looks like itself. The look's color is baked into a 33-point 3D LUT that Core Image applies in sRGB. Grain and vignette are added after the LUT. Every look keeps gray tones in order, stays in range, and keeps skin tones closer to the original. Pure tests in `CoreTests/ColorGradingTests.swift` check this.

HDR clips are converted to SDR before drawing, and the output is tagged as Rec. 709. Changing the look math or presets requires a new `ColorLook.version`, so cached previews render again.

The results screen has a Color look switch and a strength slider. They are saved per project and apply to every edit in it. Strength scales the look's color, grain, and vignette. Shot correction stays on, so clips still match when the look is off. Changing them refreshes the preview and clears a finished export, but does not require new edits.

Final export uses AVAssetExportSession's async API and state sequence. Vertical output is 1080 × 1920. The other ratios use 1080-class dimensions. The exporter writes a project-owned partial MP4 and commits it only after success. Cancellation or failure removes only that partial file and preserves the project.

The primary format is high-quality H.264 MP4. Native Photos saving and the system share sheet use the actual exported file. Playback readiness and elapsed time come from AVPlayer observations.

## Persistence, caching, and privacy

Projects live in Application Support under `Wayfarer/Projects/<UUID>`. Selected video and audio files are copied into the project package. Source fingerprints use streaming SHA-256. Duplicate selected content is skipped rather than analyzed again.

An atomic JSON manifest stores source references, moments, music analysis, creative settings, plans, locks, rejections, selected version, and output settings. Each completed source is checkpointed. Reopening an interrupted project analyzes only incomplete sources. Changing the video-analysis version deliberately invalidates cached moments and plans. Editing a result does not invalidate source analysis.

Project media and incoming transfer copies are excluded from device backup. The app sends no media or semantic content to a service. Photos may download selected iCloud assets through Apple's picker. Saving to Photos or using Share is an explicit user action; the destination's own synchronization settings apply.

The privacy manifest declares no tracking or collected data. It records required API reasons for storage checks, elapsed processing time, and metadata of app-owned or user-selected files, following [Apple's required reason API documentation](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api).

Expensive work runs in actors or a detached planning task. Analysis concurrency is one source at a time. The app pauses active work when it enters the background. Completed imports and analysis survive. Pending picker selections may need to be selected again after an interrupted import.

Planner cancellation propagates to the search task. Slider changes coalesce into one saved manifest after a short delay. Processing checkpoints and background saves write immediately. A damaged manifest is reported without hiding the other saved projects.

## Tests

Pure planner tests run with:

```sh
swift test
```

They cover quality selection, duplicate suppression, duration, soft chronology, intent pacing, determinism, locks, rejections, refinement, and a regression fixture from encoded sample footage.

All native app behavior tests use [TesterArmy e2e](https://github.com/tester-army/e2e). No agent steps or model provider are required for these deterministic tests.

```sh
npm ci
npx e2e run tests/montage.e2e.ts
```

Build the simulator app first. The configuration points to `work/DerivedData/Build/Products/Debug-iphonesimulator/Wayfarer.app` and names the current simulator explicitly. Set `WAYFARER_APP_PATH` to use a different build. Change the device entry when using another already-booted target. The `wayfarer-native` session name prevents a different project from sharing the same default session. Use an exclusive device for complete workflow runs. See the TesterArmy e2e documentation before adding or running app-flow tests. Generated test output is ignored by Git.

Screenshots are enabled in the tests. Automatic video recording is off by default. With multiple booted simulators, the current e2e mobile engine can start recording before the test binds its app session to the selected device. For a recording, use a preinstalled app and a configuration without `appPath`, then pass `--video on`. Keep the device entry explicit.

Set `WAYFARER_USE_INSTALLED=1` to test an already installed app without another installation. Verify its bundle ID and build identity first. This mode omits `appPath` and skips the tests’ install step. `WAYFARER_TEST_SESSION` can give a run its own session name. Readiness assertions remain active when the optional post-action settle wait is disabled.

The loaded Photos picker currently exposes no controls through this e2e mobile engine. Its diagnostic is explicitly skipped by default. Set `WAYFARER_TEST_PHOTOS_PICKER=1` to investigate it. Photos import selection remains unverified. The Files test proves picker opening and cancellation, not file selection. `export-timing.e2e.ts` is an optional focused retry against a saved project UUID supplied through `WAYFARER_TIMING_PROJECT_ID`. The self-contained settings test covers the same export path without that prerequisite.

Current build and runtime evidence is recorded in [VERIFICATION.md](docs/VERIFICATION.md). The 85-clip test uses encoded illustrated footage; it is a repeatable pipeline check, not a benchmark for 4K or HDR camera-roll media.

UI tests exercise real encoded sample media, all three previews, replacement, two locks, regeneration, export, Photos saving, and reopening. Build success proves compilation; it does not prove app behavior. Generated reports and videos belong under ignored `work/` evidence, never a product branch.

In Debug builds, Project options → Editing decisions shows processing times, source coverage, pacing, beat alignment, chronology, quality, and per-shot reasons.

## Limits and next intelligence upgrades

- Synthetic illustrated media proves the media workflow. It does not prove editorial quality on every real trip.
- Sparse sampling can miss brief moments in very long clips. Upgrade to hierarchical sampling around promising regions.
- Recipe scores were tuned on one 13-clip trip. They need the wider test set of real trips, and a check on a device.
- Motion, blur, exposure, and duplicate detection use practical heuristics. Add calibrated feature-print or model embeddings behind the analysis boundary.
- Cropping uses a representative subject anchor. Add time-varying anchors for subject tracking.
- Each style has one fixed look, with one strength per project. Shot correction is one setting per shot, so light that changes during a shot is not followed. HDR output is not supported.
- Capture dates may be unavailable for selected media. Use imported order as a fallback and keep chronology soft.
- Vocals, smiles, and lyric matching remain future features. Downbeats are estimates, and accuracy on commercial songs has not been measured.
- Original sound uses a global level. Future audio-event analysis can raise laughter, waves, or speech selectively.
- Hardware performance, large HDR collections, and iPad layouts require device-specific release validation.

## Collaborating

- Create a branch for each change and open a pull request for review.
- Keep real user media, signing credentials, local tool configuration, build output, and generated test evidence out of the repository. The sample media in `Resources` is synthetic.
- Document device, simulator, and test limitations when reporting a change. See [VERIFICATION.md](docs/VERIFICATION.md) for existing evidence; it is historical and does not guarantee a new build passes.
- The repository does not require API keys for the app as currently documented.

## Visual redesign

The Screening Room redesign uses adaptive colors, trip imagery, simpler setup, and horizontally paged edits. See [REDESIGN_VERIFICATION.md](docs/REDESIGN_VERIFICATION.md) for the build, native e2e results, screenshots, and review limits. Set `WAYFARER_TEST_DEVICE` to target a specific already-booted simulator without changing the default configuration.
