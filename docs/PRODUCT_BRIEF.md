# Build a Production-Quality Automatic Travel Montage App

Build a polished native Apple application that automatically turns a user's raw travel videos into finished short-form montage videos suitable for Instagram Reels, Stories, TikTok, and general sharing.

Do **not** build a conventional video editor with an AI feature attached to it.

The product should feel like having a personal video editor:

**User provides raw clips + music + creative intent → app decides what moments to use, how long to use them, how to sequence them, and where to cut → user receives several finished edits.**

The fundamental problem is:

> People return from trips with dozens or hundreds of video clips, but making a good 20–60 second reel requires manually reviewing every clip, finding the best moments, trimming them, arranging them, synchronizing cuts with music, previewing, and repeatedly tweaking the edit.

This app should remove almost all of that work.

The central promise is:

> **Give me your clips. Pick a song. Tell me the vibe. Get a finished reel.**

---

# 1. Platform

Build this initially as a native iPhone/iPad application.

Use modern Apple technologies wherever appropriate:

- Swift
- SwiftUI
- AVFoundation
- Photos / PhotosUI
- Vision
- Core ML where useful
- Accelerate / vDSP for signal processing where useful
- Swift Concurrency
- modern Observation architecture
- native media APIs
- local persistence appropriate for project metadata

Target current-generation iOS/iPadOS rather than spending engineering effort on unnecessary legacy compatibility.

The architecture must be modular enough that individual intelligence components could later move to a server without requiring the UI or editing system to be rewritten.

Prioritize on-device analysis and processing.

Do not upload a user's personal videos anywhere by default.

---

# 2. Product Principle

This application is not primarily about manipulating timelines.

It is about **making editing decisions automatically**.

The single most important intelligence problem is:

> Given a 12-second source clip, determine which 0.5–4 seconds are actually worth using.

This matters more than transitions, filters, visual effects, stickers, or templates.

The editing engine must therefore reason about **moments inside clips**, not simply whole clips.

A 20-second video should potentially contribute only 1.2 seconds to the finished montage.

---

# 3. Core User Journey

The main flow should require very little effort.

## Screen 1 — Home

Clean, visual, premium interface.

Primary CTA:

**Create a Montage**

Also show previous projects once they exist.

A project thumbnail should show:

- preview frame
- project name
- number of source clips
- final duration
- creation date
- draft/export status

Avoid clutter.

---

# 4. Import Media

Allow the user to select multiple videos from Photos.

The experience must support:

- 5 clips
- 30 clips
- 100+ clips

without feeling like the product was designed only for tiny selections.

After importing, immediately begin analysing the media.

The user should not need to manually trim anything before proceeding.

Show meaningful progress instead of a generic spinner.

Examples:

**Analyzing 37 of 82 clips**

**Finding the best moments**

**Comparing similar shots**

**Analyzing movement**

Analysis should be cancellable and resilient to app lifecycle changes.

Where possible, cache analysis so reopening a project does not require starting again.

---

# 5. Video Analysis

Every imported video should be represented internally as a collection of candidate moments.

Conceptually:

Clip 038  
Duration: 14.8 sec  
Recorded: Oct 2, 5:31 PM

Candidate segment A  
0.0–2.6 sec

- walking
- substantial shake
- two people
- weak framing
- quality score 0.44

Candidate segment B  
2.6–5.1 sec

- restaurant exterior
- stable
- sign visible
- strong composition
- quality score 0.78

Candidate segment C  
5.1–8.4 sec

- person entering restaurant
- face visible
- moderate movement
- high visual interest
- quality score 0.83

Candidate segment D  
8.4–11.2 sec

- food close-up
- stable
- good light
- strong composition
- quality score 0.91

Candidate segment E  
11.2–14.8 sec

- camera pointed at table
- weak framing
- low visual interest
- quality score 0.24

Do not assume each clip contains a single useful moment.

Analyse useful signals such as:

- shot boundaries
- camera motion
- excessive shake
- blur
- focus quality
- exposure
- visual composition
- faces
- number of people
- prominent subjects
- landscapes
- architecture
- food
- vehicles
- streets
- indoors/outdoors
- close-up vs medium vs wide
- motion intensity
- visual novelty
- duplicate/near-duplicate shots
- orientation
- clip duration
- timestamp
- whether the beginning/end looks accidental
- whether a shot becomes stable only after the first second
- subject changes inside a single clip

Not every classifier needs to be sophisticated in V1.

Prefer a robust extensible pipeline to a giant brittle model.

---

# 6. Candidate Moments

Create a domain model similar to:

`CandidateMoment`

It should be able to represent:

- unique ID
- source asset ID
- source start time
- source end time
- duration
- quality score
- interest score
- motion score
- stability score
- face/person score
- scenery score
- food/detail score
- novelty score
- composition score
- brightness/exposure quality
- semantic tags
- capture timestamp
- confidence
- optional feature vector/embedding
- optional representative frame
- whether user explicitly likes/dislikes the moment
- whether the moment is locked in an edit

Keep individual component scores separate.

Do **not** collapse everything permanently into one universal "best clip" score.

The same clip should score differently depending on the creative intent.

For example:

A static mountain shot could be excellent for **Cinematic** but mediocre for **Energetic**.

A laughing group of friends could be excellent for **People** and less useful for **Places**.

---

# 7. Music Selection

After the clips are selected, the user chooses music.

For the initial version support legitimate user-provided audio such as:

- compatible local audio files
- Files imports
- other non-DRM audio available through supported APIs

Keep music ingestion abstract enough that additional licensed services could be integrated later.

Do not circumvent DRM or extract protected audio from third-party apps.

---

# 8. Music Analysis

Analyse the chosen audio independently from the videos.

Produce a structured music timeline containing useful concepts such as:

- estimated BPM
- beat positions
- strong beats
- downbeats if reliably detectable
- onset strength
- section boundaries
- energy curve
- quieter moments
- builds
- drops
- phrase boundaries
- likely intro/outro
- vocals vs instrumental where feasible

Conceptually:

00:00 — intro  
00:06 — vocals begin  
00:14 — groove establishes  
00:28 — energy increase  
00:42 — major section/drop  
00:58 — breakdown  
01:11 — final high-energy section

Create models such as:

`MusicAnalysis`

`MusicSection`

`MusicEvent`

The montage planner should consume this structured representation rather than directly reasoning from raw samples.

Audio analysis should be implemented as a replaceable service.

---

# 9. Target Duration

Before generation, ask:

**How long should it be?**

Quick options:

**15 sec**

**30 sec**

**45 sec**

**60 sec**

**Custom**

The editing engine must genuinely construct an edit for that requested duration.

Do not create a 60-second edit and simply truncate it to 30 seconds.

Choose an appropriate section of the music and build the visual arc specifically for the requested duration.

---

# 10. Edit Intent

This should be one of the defining parts of the product.

Instead of presenting hundreds of arbitrary templates, ask:

## How should this video feel?

Initial modes:

### Beat Sync

Fast, rhythm-driven editing.

Prioritize:

- strong movement
- visually impactful moments
- rhythmic cuts
- cuts on beats/downbeats
- shorter segments when music energy rises

Do not mechanically cut on every beat.

Musical phrasing should still influence pacing.

---

### Story

Prioritize the feeling of reliving the trip.

Use capture timestamps and semantic context.

Prefer a rough progression such as:

arrival → exploring → food → people → experiences → evening → ending

Chronology should influence this mode without becoming rigid.

The engine may reorder moments if doing so clearly produces a stronger sequence.

---

### Cinematic

Use fewer cuts and longer shots.

Prioritize:

- stable shots
- beautiful framing
- scenery
- subtle movement
- visual atmosphere
- slower musical phrases

Avoid hyperactive beat cutting.

---

### Highlights

Ignore strict chronology.

Select the strongest moments across the entire source collection.

Optimize for visual impact and diversity.

---

### People

Prioritize:

- faces
- friends
- laughter
- interactions
- candid moments
- human movement

Still include occasional environmental establishing shots so the montage has context.

---

### Places

Prioritize:

- streets
- architecture
- scenery
- details
- food
- transport
- interiors
- establishing shots

People can appear, but they should not dominate.

---

# 11. Creative Controls

After choosing an Edit Intent, expose three simple creative controls.

Do not expose professional editing terminology.

Use something similar to:

### Story ←→ Highlights

Left side:
more chronological and narrative.

Right side:
strongest moments regardless of chronological order.

### Calm ←→ Energetic

Controls:

- average shot duration
- amount of motion
- cut frequency
- sensitivity to beats
- music section selection

### Longer Shots ←→ Fast Cuts

Controls actual edit pacing.

These controls should feed parameters into the planner rather than merely changing labels.

Persist them as part of the project.

---

# 12. Generate Multiple Edits

Never generate only one result.

For the first generation, produce **three meaningfully different edits**.

Example:

### Edit A — Energetic

28 sec  
22 moments  
beat-focused

### Edit B — Memory Film

34 sec  
16 moments  
story-focused

### Edit C — Cinematic

38 sec  
12 moments  
slower pacing

The three versions should not simply be the same sequence with tiny timing differences.

Add diversity constraints.

Variants should differ in some combination of:

- selected moments
- opening shot
- pacing
- music subsection
- chronological strictness
- rhythm
- percentage of people/scenery
- shot duration

Users should immediately feel that they have genuine choices.

---

# 13. Montage Planner

Create a dedicated component such as:

`MontagePlanner`

Its input should include:

- candidate video moments
- music analysis
- target duration
- selected Edit Intent
- creative slider values
- locked user selections
- rejected moments
- prior edit if regenerating

Its output should be an **Edit Decision List**, not a rendered video.

Example conceptual output:

`MontagePlan`

Music:
start 00:41.8  
end 01:12.1

Timeline:

1. Asset 12 — 3.80 → 5.15
2. Asset 7 — 8.44 → 10.20
3. Asset 33 — 0.90 → 2.75
4. Asset 19 — 5.20 → 6.25
5. Asset 42 — 12.01 → 14.70

For every decision, retain metadata describing why it was chosen.

For example:

- high visual quality
- cut aligned with downbeat
- provides scenery diversity
- introduces people
- chronological transition
- strongest moment in source asset

These explanations are primarily useful for debugging initially but could enable user-facing intelligence later.

---

# 14. Planner Scoring

The montage selection algorithm should consider multiple objectives rather than greedily choosing the highest-scoring clips.

Think of the problem as constrained optimization.

A good final sequence needs:

- strong individual moments
- visual diversity
- pacing variation
- music synchronization
- continuity
- limited repetition
- sensible duration
- an effective opening
- an effective ending

Penalize:

- near-identical consecutive shots
- repeated shots of the same subject
- excessive visual similarity
- too many food clips together
- too many landscapes together
- excessive face shots
- very similar camera movements
- multiple clips from exactly the same scene unless deliberately constructing an action

Reward:

- semantic diversity
- alternating scales such as wide → medium → close
- natural visual progression
- movement continuity
- strong opening moments
- musical transitions
- increasingly exciting visuals when music energy rises

Do not create an edit by independently sorting clips by score.

Sequence quality matters.

---

# 15. Opening and Ending Logic

Treat the first and last few seconds as special.

## Opening

The first shot should establish attention immediately.

Depending on intent, good openings could include:

- striking establishing shot
- movement toward a destination
- person entering frame
- visually unusual detail
- transport/window shot
- energetic human moment

Avoid weak openings such as:

- camera being raised
- black frames
- accidental floor footage
- unfocused setup
- repetitive generic scenery

## Ending

Prefer something that feels conclusive:

- sunset
- walking away
- group moment
- final location
- vehicle leaving
- food/drink toast
- nighttime shot
- visually calm final frame

Allow the music structure to influence the ending.

---

# 16. Clip Duration

Clip duration should not be arbitrary.

For energetic edits, useful shots might be:

0.5–1.8 sec

For balanced edits:

1–3 sec

For cinematic edits:

2–5+ sec

But avoid rigid fixed values.

Use:

- music rhythm
- motion
- semantic importance
- shot stability
- selected intent
- source quality

to determine duration.

The planner should be capable of choosing the best sub-window from a longer candidate segment.

---

# 17. Beat Synchronization

Beat mode should feel musical rather than robotic.

Prefer major cuts on meaningful beats and phrase boundaries.

Not every beat requires a cut.

Use musical hierarchy.

For example:

- major scene change on a downbeat
- short inserts on intermediate beats
- longer shot through a quieter phrase
- rapid sequence during a musical build
- strong visual reveal on a drop

Build this logic into the planner.

---

# 18. Chronological Story Mode

Use capture timestamps as an important signal.

But chronology should be a **soft constraint**, not an absolute rule.

For example, if five nearly identical restaurant clips occur sequentially, use the best one rather than all five.

Try to preserve the user's sense of the trip unfolding over time.

If clips span multiple days, support subtle day progression internally even if no text appears on screen.

---

# 19. Duplicate Detection

Travel camera rolls contain many repeated takes.

Detect near-duplicate moments wherever practical.

Examples:

- four videos of the same building
- several takes of the same food
- repeated street shots
- multiple attempts to capture one friend

Group these into semantic/visual clusters.

By default, avoid using multiple highly similar shots unless it improves the sequence.

For a cluster of similar moments, choose the strongest representative.

---

# 20. Generated Results Screen

When processing is complete, show all generated edits as large preview cards.

The screen should feel exciting.

Each card should include:

- video preview
- edit name
- duration
- short description
- play button

Example:

**Energetic**  
28 sec  
Quick cuts synchronized to the strongest part of the track.

**Memory Film**  
34 sec  
A more chronological version focused on the journey.

**Cinematic**  
41 sec  
Longer shots and slower musical phrasing.

Allow instant switching between versions.

Do not require exporting just to preview them.

---

# 21. Editing the Result

Do not immediately expose a traditional professional editing timeline.

The editing experience should remain consistent with the product promise.

Present the montage as a row/list of visual cards representing selected moments.

Each card should show:

- thumbnail
- source clip
- duration
- locked state

Selecting a moment should offer actions like:

**Use another moment**

**Replace**

**Make shorter**

**Make longer**

**Move earlier**

**Move later**

**Lock**

**Remove**

**Never use this clip**

Potentially:

**Show me alternatives**

The goal is to let someone direct the edit without becoming a video editor.

---

# 22. Alternative Moments

For each selected timeline moment, retain alternative candidate segments.

When the user taps:

**Use another moment**

show 3–5 sensible substitutes.

Alternatives can come from:

- another portion of the same source clip
- another visually similar clip
- another semantically appropriate clip

The user should be able to swap one in instantly.

---

# 23. Locking

Users must be able to lock moments they love.

Once locked:

- regeneration must keep the moment
- timing may only shift slightly if necessary
- the planner should rebuild around locked moments

Show locked moments clearly but subtly.

---

# 24. Try Another Edit

Make this a major action.

**Try Another Edit**

Regenerate the montage while respecting:

- locked shots
- rejected shots
- chosen duration
- chosen song
- selected intent
- slider settings

The next version should intentionally explore a different valid sequence.

Do not simply randomize everything.

Track previous choices so regenerated versions have meaningful diversity.

This should create the feeling of telling a human editor:

> Keep these three shots, but give me another version.

---

# 25. Source Browser

Provide an optional source browser for users who want more control.

Organize imported material intelligently.

Potential sections:

- Best moments
- People
- Places
- Food
- Motion
- Low quality
- Unused

This should remain secondary.

A user must not have to browse source clips to get a good result.

---

# 26. Rendering

The planner creates decisions.

A dedicated rendering layer turns those decisions into media.

Create components such as:

`MontageRenderer`

`PreviewRenderer`

Use AVFoundation composition APIs.

Support:

- source trimming
- sequencing
- audio placement
- optional source audio
- aspect-ratio fitting
- transformations
- simple transitions
- final export

Keep rendering separate from planning.

Changing one selected clip should not require re-running every analysis step.

---

# 27. Preview Performance

Full-resolution rendering should not be required whenever a user changes something.

Create an efficient preview strategy.

Possible approaches:

- AVPlayer compositions
- proxy media
- cached intermediate renders
- lower-resolution previews

Interaction should remain responsive.

Only render high-quality final output when required.

---

# 28. Aspect Ratio

The primary format is:

**9:16 vertical**

because the initial use case is Instagram Reels and similar short-form video.

Also support:

- 1:1
- 4:5
- 16:9

The engine should intelligently crop/reposition shots where possible.

Use Vision information when available to keep important faces/subjects inside the crop.

Do not blindly center-crop every source.

---

# 29. Mixed Orientations

Travel footage frequently contains:

- vertical videos
- horizontal videos
- mixed resolutions

Handle this gracefully.

For horizontal footage in vertical output, intelligently choose among:

- subject-aware crop
- subtle background treatment
- letterboxing where composition demands it

Do not create ugly accidental crops.

---

# 30. Source Audio

Give the user a simple control:

**Original sound**

with a global level.

Potential presets:

- Off
- Subtle
- Balanced
- Prominent

The music should usually remain dominant.

A future version may automatically bring original audio up for meaningful moments such as laughter, waves, crowd noise, announcements, etc.

Architect audio mixing so this can be added later.

---

# 31. Transitions

Do not overuse flashy transitions.

V1 should primarily use:

- clean cuts
- very subtle dissolves where appropriate

Travel footage should feel editorial and modern, not template-heavy.

The rhythm and selected shots should create the edit—not transition gimmicks.

---

# 32. Export

Allow export in useful high-quality formats.

Primary:

- 1080 × 1920
- high-quality H.264 or HEVC where appropriate

Offer:

**Save to Photos**

**Share**

Preserve audio/video synchronization exactly.

Show useful render progress.

A failed export should be recoverable without losing the project.

---

# 33. Project Persistence

A user's work must survive app restarts.

Persist:

- imported asset references
- analysis results
- chosen song reference where possible
- music analysis
- intent
- sliders
- generated montage plans
- locks
- rejections
- user modifications
- output settings

Do not repeatedly reanalyse unchanged media.

Design cache invalidation deliberately.

---

# 34. Suggested Architecture

Use clean modular boundaries.

A reasonable high-level architecture could include:

### Media

`MediaImportService`

`AssetRepository`

`ThumbnailService`

### Analysis

`VideoAnalysisService`

`ShotSegmentationService`

`VisualQualityAnalyzer`

`MotionAnalyzer`

`SemanticAnalyzer`

`SimilarityAnalyzer`

`MusicAnalysisService`

### Domain

`SourceAsset`

`CandidateMoment`

`MomentFeatures`

`MusicAnalysis`

`MusicEvent`

`MusicSection`

`EditIntent`

`CreativeParameters`

`MontagePlan`

`MontageSegment`

`MontageVariant`

### Planning

`MomentScorer`

`SequenceScorer`

`MontagePlanner`

`VariantGenerator`

### Playback / Render

`PreviewCompositionBuilder`

`MontageRenderer`

`ExportService`

### Persistence

`ProjectRepository`

`AnalysisCache`

### UI

Feature-level SwiftUI screens rather than one massive view hierarchy.

Do not blindly implement these exact names if a cleaner architecture emerges, but preserve the separation of concerns.

---

# 35. Planner Implementation Strategy

Do not block V1 on solving video understanding perfectly.

Build a strong deterministic planner that can improve as richer analysis becomes available.

One reasonable strategy:

1. Segment source media.
2. Generate candidate moments.
3. Calculate feature scores.
4. Remove unusable moments.
5. Cluster near-duplicates.
6. Score candidates according to the selected intent.
7. Determine desired pacing from music and creative controls.
8. Construct a candidate sequence.
9. Score sequence-level characteristics.
10. Optimize swaps/reordering.
11. Align appropriate boundaries with music events.
12. Fill target duration precisely.
13. Validate diversity and continuity.
14. Generate alternative montage variants.

Keep randomization seeded/reproducible where possible for debugging.

---

# 36. Explainability During Development

During development, build a hidden/debug view where each montage decision can be inspected.

For example:

Clip 18  
9.1–10.7 sec

Selected because:

- quality 0.87
- people 0.92
- movement 0.73
- novelty 0.81
- matches energetic intent
- cut lands 38 ms from strong beat
- visually different from previous segment

This will be extremely useful for improving the planner.

Debug tools should not pollute the normal product UI.

---

# 37. Lyrics Mode — Architecture Now, Full Feature Later

The future product should support:

**Lyrics**

Example:

If a lyric says something about:

- night
- driving
- dancing
- food
- ocean
- friends
- city
- home

the application could favor semantically related footage around that lyric.

Do **not** make full lyric synchronization a blocker for the first stable build.

However, structure the system so a future component can provide:

`TimedLyric`

with:

- start time
- end time
- text
- semantic representation

and the planner can score visual candidate moments against those lyrics.

Do not scrape copyrighted lyrics from unauthorized sources.

The architecture is the requirement for now.

---

# 38. Visual Design

The app should feel like a premium consumer creative product.

Avoid:

- generic AI gradients
- excessive glass everywhere
- enormous glowing AI buttons
- cluttered editing timelines
- skeuomorphic video-editing interfaces
- dozens of tool icons
- template-store aesthetics

Aim for:

- editorial
- calm
- modern
- visual
- spacious
- tactile
- Apple-native interaction quality

The footage itself should dominate the UI.

Use large previews.

Use strong typography.

Use motion sparingly but beautifully.

Respect light/dark mode unless the chosen visual identity deliberately defines otherwise.

---

# 39. Onboarding

Keep onboarding short.

Do not create five pages explaining AI.

A concise first-run introduction could communicate:

**Your clips. Your music. Your story.**

**We find the moments worth keeping and turn them into a finished edit.**

Then:

**Create your first montage**

That is enough.

Explain permissions contextually when they are needed.

---

# 40. Empty States and Copy

Use human product language.

Prefer:

**Finding your best moments**

over:

**Running semantic video analysis**

Prefer:

**Making three different edits**

over:

**Executing montage generation algorithm**

Prefer:

**Try another edit**

over:

**Regenerate**

Technical language belongs in debug tooling, not consumer UI.

---

# 41. Privacy

Make privacy a genuine product property.

User video analysis should happen locally wherever practical.

Do not send media to third parties without explicit future product requirements and user permission.

Do not add analytics that expose user footage or personal media contents.

Keep logging free of sensitive filenames or media content.

---

# 42. Performance

Treat performance as part of the product.

The application must remain usable while processing large camera-roll selections.

Requirements:

- expensive analysis runs off the main actor
- UI stays responsive
- processing can report granular progress
- thumbnail generation is cached
- memory usage is bounded
- do not load entire videos into memory
- avoid unnecessary repeated decoding
- cancel obsolete tasks
- reuse analysis across generated variants
- generation after initial analysis should be much faster than the first pass

Test with a large synthetic project, not only three tiny clips.

---

# 43. Failure Handling

Handle:

- inaccessible Photos assets
- iCloud asset download
- corrupted video
- unsupported codec
- missing audio
- user removing Photos permission
- background interruption
- low disk space
- export failure
- analysis cancellation
- video with no useful moments
- song shorter than target duration
- too few clips
- extremely long clips
- duplicate assets

Errors should tell the user what happened and what action is possible.

Do not crash or silently drop assets.

---

# 44. Accessibility

Support:

- Dynamic Type where practical
- VoiceOver labels
- Reduce Motion
- sufficient contrast
- comfortable tap targets

Do not make important controls depend solely on color.

---

# 45. V1 Scope

A strong V1 should accomplish these things exceptionally well:

**Import raw travel footage**

**Analyse footage and identify useful moments**

**Analyse music rhythm/structure**

**Create a montage of a requested duration**

**Offer Beat Sync, Story, and Cinematic**

**Generate three different results**

**Preview instantly**

**Allow clip replacement / duration adjustments**

**Lock moments**

**Try Another Edit while respecting locks**

**Export a high-quality vertical video**

Additional modes such as People, Places, Highlights, and Lyrics can be included if the architecture and core quality remain strong.

Prioritize the core editing intelligence over feature count.

---

# 46. What Not to Build Yet

Do not spend V1 engineering time building:

- text animation systems
- stickers
- meme tools
- advanced color grading
- beauty filters
- AR effects
- hundreds of transitions
- template marketplace
- social network
- comments/followers
- cloud accounts unless technically necessary
- collaborative editing
- professional multi-track editor
- DRM audio extraction
- generative-video features

Those are distractions from the central product.

---

# 47. Demo / Development Assets

Do not depend on my personal Photos library to make development possible.

Provide a developer/demo mode capable of exercising the product pipeline.

If necessary, create small synthetic media fixtures or use generated placeholder clips that represent:

- walking
- landscape
- food
- people
- architecture
- shaky footage
- intentionally blurry footage

Also create predictable synthetic music/beat data for planner unit tests.

The automated test suite should not require access to my personal media.

---

# 48. Testing

Implement meaningful tests.

At minimum test:

### Moment selection

Higher-quality moments should generally win over obviously poor moments.

### Duplicate suppression

Several near-identical candidates should not dominate an edit.

### Duration

Generated montage duration should closely match the requested target.

### Chronology

Story mode should generally preserve temporal ordering.

### Intent behavior

Cinematic should produce longer average shots than Beat Sync.

### Locks

A locked moment survives regeneration.

### Rejections

A rejected source does not reappear.

### Diversity

Three generated variants should not be identical.

### Determinism

With a fixed seed/input, the planner should produce reproducible output where expected.

### Persistence

A project reopens with edits and analysis intact.

### Export

A composition can successfully render a playable output.

---

# 49. UI Testing

Create UI tests for the critical path:

Create Montage  
→ select/import test media  
→ choose music  
→ choose duration  
→ choose Edit Intent  
→ generate  
→ preview versions  
→ select one  
→ lock a shot  
→ Try Another Edit  
→ verify lock remains  
→ export

The critical workflow should not depend on debug-only actions.

---

# 50. Quality Bar

This should not look like an engineering prototype.

The first launch should already feel like a real consumer app.

Polish:

- spacing
- loading states
- transitions
- video thumbnails
- player controls
- typography
- empty states
- haptics where appropriate
- progress presentation
- error messages
- skeleton/loading UI
- navigation behavior

Do not leave obvious placeholder interfaces merely because the backend is functional.

At the same time, avoid cosmetic complexity that slows the core experience.

---

# 51. Build Iteratively

Implement in vertical slices.

A sensible order is:

**Phase 1**

Project setup, architecture, import flow, project persistence, video playback.

**Phase 2**

Video segmentation and candidate moment generation.

**Phase 3**

Basic visual quality/motion scoring.

**Phase 4**

Audio analysis and beat timeline.

**Phase 5**

Deterministic montage planner.

**Phase 6**

AVFoundation preview composition.

**Phase 7**

Three-variant generation.

**Phase 8**

Result editing, alternatives, locks, rejection, Try Another Edit.

**Phase 9**

Final export.

**Phase 10**

Product polish, accessibility, performance, testing.

Do not create ten unfinished subsystems simultaneously.

Get each vertical slice working.

---

# 52. Make Reasonable Engineering Decisions

Do not stop to ask me questions about every minor implementation choice.

Use the product intent in this brief to make sensible decisions.

If a sophisticated computer-vision feature is not practical with built-in Apple frameworks, implement a simpler heuristic-backed version behind a clean protocol and continue.

If a proposed framework is unavailable, choose the closest production-quality alternative.

Do not fake functionality.

Clearly distinguish real implemented analysis from placeholders or heuristics.

The architecture should allow the heuristic implementation to be replaced later.

---

# 53. Product Analytics Architecture

Do not introduce invasive analytics.

However, structure important internal editing metrics so they could later be collected in privacy-safe aggregate form, such as:

- generation time
- number of clips imported
- number of generated variants
- which edit the user selected
- number of manual replacements
- number of regenerations
- export success/failure

Do not record the semantic contents of personal videos.

No analytics service is required for V1.

---

# 54. Internal Quality Metrics

Create internal metrics that help us improve the editor.

For each generated montage, calculate things such as:

- total source clips
- used source clips
- average segment duration
- percentage cuts near beats
- duplicate similarity
- semantic diversity
- chronological consistency
- people/scenery balance
- visual quality mean
- motion mean

Expose these in debug mode.

This will make tuning much easier.

---

# 55. README

Create a useful project README containing:

- product purpose
- architecture overview
- module structure
- how media analysis works
- how music analysis works
- how montage planning works
- how rendering works
- caching strategy
- privacy principles
- testing instructions
- known limitations
- planned intelligence upgrades

Do not produce generic boilerplate documentation.

---

# 56. Code Quality

Use clean production-quality Swift.

Requirements:

- meaningful type names
- small focused components
- dependency injection where useful
- protocol boundaries around intelligence services
- minimal singleton/global state
- robust error handling
- structured concurrency
- no unnecessary force unwraps
- avoid giant view models
- keep UI and media algorithms separated
- document unusual algorithmic decisions

Do not over-engineer abstract layers that provide no real benefit.

---

# 57. Definition of Done

The initial product is complete only when I can perform this workflow:

1. Launch the app.
2. Create a new montage.
3. Select a large collection of travel videos.
4. Let the app analyse them.
5. Choose a music file.
6. Select a 30-second output.
7. Choose Beat Sync, Story, or Cinematic.
8. Adjust the creative controls.
9. Generate.
10. Receive three visibly different edits.
11. Preview each edit smoothly.
12. Pick one.
13. Replace one selected moment.
14. Lock two moments.
15. Ask for another edit.
16. Receive a new sequence that preserves those locked moments.
17. Export the finished video.
18. View the finished exported video successfully in Photos.

The result should feel like an application making editorial decisions for me—not like a timeline editor that still expects me to do all the work.

---

# 58. Acceptance Test for the Product Idea

Use this scenario as the benchmark:

A user returns from a week-long trip with **85 raw videos**.

They do not want to inspect all 85.

They select all of them.

They choose a song.

They choose:

**30 seconds**

**Beat Sync**

They tap:

**Make My Reel**

The application analyses the footage and song and returns three polished 30-second montages.

The user watches them and thinks:

> "It found the good parts of my videos for me."

That reaction is the primary success criterion.

Everything else is secondary.

---

# 59. Execution Instructions

Start by inspecting the repository/workspace and understanding what already exists.

If the repository is empty, establish the project cleanly.

If code already exists, preserve useful work and improve it rather than automatically replacing everything.

Then:

- create the architecture
- implement the product in working vertical slices
- run builds frequently
- fix compiler errors immediately
- run tests after meaningful changes
- inspect warnings
- validate actual video playback/export
- do not declare a feature complete merely because code exists
- keep temporary mocks isolated
- remove dead experiments
- leave the repository in a clean understandable state

Do not stop at scaffolding.

Do not return with only a design document or implementation plan.

Implement the application.

When a feature has to use a simpler V1 heuristic, implement the heuristic fully and leave an explicit upgrade boundary.

Continue until the main end-to-end workflow builds and runs successfully.

---

# 60. Final Product Principle

Whenever there is a tradeoff, optimize for this:

> **The user should make creative choices. The app should make editing decisions.**

The user chooses:

- the footage
- the music
- the duration
- the feeling

The app chooses:

- which moments matter
- where each moment begins
- where each moment ends
- what order works
- where cuts happen
- how the sequence interacts with the music

That separation is the product.