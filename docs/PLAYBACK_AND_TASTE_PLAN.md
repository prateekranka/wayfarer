# Playback and taste improvements

Approved by the user on 2026-10-03 after a read-only plan. The existing task permits root review while the configured Advisor is unavailable.

## Scope

- Configure shared foreground media playback for previews, finished exports, reference reels, and source moments.
- Give the results preview horizontal paging, direct selection controls, and one active player.
- Explain Beat Sync and use factual Balanced, Scenic, and Motion names, including legacy saved edits.
- Add local, intent-specific preferences, explicit edit and moment comparisons, reference files with timestamped notes, and approved source-range examples.
- Keep all videos and feedback on device. No OpenAI API or server integration is added.

## Constraints

- Navigation is not feedback. Source replacement affects global preferences only when the user enables learning.
- Preferences have bounded effects. Locks, rejections, source ranges, quality checks, and target duration stay authoritative.
- Existing edits remain stable. The next generation uses a snapshot of the current profile.
- Reference cut detection is approximate. Notes and approved examples are saved evidence, not an automatic training claim.
- Pure planner tests and native build checks are distinct from app-flow proof. All app-flow checks use TesterArmy e2e.
- A playback clock cannot prove audible output. Physical speaker, Silent Mode, headphones, and interruptions require hardware evidence.
