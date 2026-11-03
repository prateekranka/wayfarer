# Canonical implementation plan

Source: independent PLAN_DRAFT v1, reviewed by the root. The user explicitly approved proceeding when the configured Advisor was unavailable. That fallback applies to this task only.

The implementation targets iOS/iPadOS 26, uses Swift 6 strict concurrency, and keeps media ingestion, video analysis, audio analysis, pure planning, composition, persistence, and feature screens separate. Only Apple frameworks ship in the app, plus the bundled Beat This! bar model (MIT license) run through Core ML. TesterArmy e2e drives all app behavior tests.

Work proceeds as a connected vertical slice: real encoded media → analysis → structured music → exact-duration plan → native preview → distinct variants → refinement/locks/rejections → MP4 export → Photos/share → persistence recovery.

Acceptance requires compilation, focused pure tests, native UI workflow proof, actual encoded output validation, and an 85-source synthetic run. No stage is complete merely because its source exists.

Root review findings and decisions:

- Use integer ticks for planning while retaining seconds in Codable media contracts.
- Preserve candidate peak time separately from a candidate's available range.
- Keep an explicitly feasible duration-progress path in the bounded search.
- Score completed sequences against intended pacing.
- Keep chronology soft and reserve locked source ranges.
- Reject infeasible duration and diversity instead of inventing frames or looping music.
- Observe export through AVFoundation's Sendable state sequence.
- Publish completed compositions as read-only values; create AVPlayerItem on the main actor.
- Retain compressed thumbnails instead of every decoded frame.
- Use native primary button styling and bound image-card hit regions to their visible layout.
- Match music energy to the selected intent and creative controls.
- Keep navigation and export presentation stable while processing screens change.
- Treat source inspection, build, pure tests, UI tests, output probes, and physical-device proof as separate evidence.
- Quantize cumulative rendering boundaries and validate native instruction coverage.
- Fall back to cached, lower-resolution native previews when composition playback fails.
- Use a project-specific e2e session to prevent another project's default session from changing the observed app.
