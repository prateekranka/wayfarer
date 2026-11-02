# Wayfarer screen and motion plan

This plan comes from the current source. It is not evidence of rendered app behavior. Each state must receive an e2e screenshot before inclusion in the final Pen document.

## Screen states

| Surface | Distinct states to capture | Shared editable components |
| --- | --- | --- |
| Home | First use; paused draft; generated project; exported project; multiple projects; long names; missing thumbnails; empty, one and large libraries | Wordmark, expanded heading, trip artwork, project card, thumbnail, status label, primary action, My Style action |
| Add clips | New project import sheet; append clips sheet; Photos picker; Files picker; cancellation; import failure | Sheet header, explanatory copy, Photos action, Files action, sample actions, native picker controls |
| Processing | Preparing files; analyzing clips; paused and resumed work; music analysis; generating edits; export progress; cancellation | Preview strip, progress heading, completed/total numbers, progress track, pause action |
| Setup | No song; song selected; preset length; custom length; all six feelings; format menu; creative controls collapsed and expanded; warnings; project name keyboard | Preview strip, editable name, count labels, soundtrack row, length button, stepper, feeling button, menu, slider, disclosure, pinned primary action |
| Results | Each of three variants; playing; paused; muted; sound on; scrubbed; playback failure; explanation sheet; settings changed; generated and exported actions | Pager, video frame, poster image, play/pause action, sound action, scrubber, time label, variant selector, edit caption, information action, refinement action |
| Refinement | No locks; one lock; multiple locks; actions menu; resized/reordered moment; alternatives with preference off/on; no alternatives; source preview | Moment row, thumbnail, lock action, range labels, replace action, overflow menu, learning toggle, alternative card, source player |
| Source browser | Filter menu; populated filters; empty filter; source thumbnail fallback | Category menu, count, moment card, duration and semantic labels, empty message |
| My Style | Preferences first use and learned; disabled learning; intent menu; reset confirmation; empty/populated References; empty/populated Compare; comparison preview; recorded choice; approved example; delete confirmation | Segmented control, status row, form section, preference slider, toggle, reference row, comparison selector, reason menu, example row, confirmation controls |
| Reference detail | Playing/paused reference; empty note; keyboard; populated note; saved note; estimated pacing; no pacing estimate; apply pacing; delete confirmation | File player, time label, note editor, note action, annotation row, pacing metrics, intent menu |
| Export | Render complete; saving; saved; Photos permission failure; share sheet; reading reference; reference saved; reference failure | File player, format label, primary save action, share action, reference action, alert |
| Editing decisions | Processing metrics; sequence metrics; moment reasons | Debug list section, metric row, reason text |

Use the fixture switch for data boundaries. Use a real generated project for editing, playback, save and reference behavior. Keep before-fix and after-fix captures in separate run directories.

## Motion represented in Pen

| Motion | Current source behavior | Editable representation |
| --- | --- | --- |
| Primary action press | Scale 1 to 0.985 and opacity 1 to 0.82. SwiftUI smooth animation takes 0.18 seconds. Disabled opacity is 0.45. Reduce Motion removes scale and animation. | Rest, pressed, disabled and Reduce Motion component states. Add the source timing beside the transition. |
| Progress number | The completed count uses `numericText`. Reduce Motion selects the identity transition. | Adjacent progress states with editable digits and the same progress track. Do not assign an invented duration. |
| Edit pager | Native page-style `TabView`. Selecting a variant changes the selected plan and its active player. | Three editable page frames, selected selector states and directional arrows. Link the e2e recording when available. |
| Navigation | Native `NavigationStack` pushes settings, refinement, reference and approved-example detail. | Source and destination frames, back-action links and a push transition annotation. Record native timing only if measured. |
| Sheets and menus | Native sheets present import, source browsing, alternatives, previews, style and export. Native menus and confirmation dialogs present choices. | Editable dim layer, sheet/menu/dialog layers, open and closed states, and trigger links. |
| Disclosure and selection | Creative controls expand. Duration, feeling and variant selections produce selection haptics. | Collapsed and expanded frames plus selected control states. Annotate haptics as nonvisual behavior. |
| Playback and scrub | AVPlayer updates the displayed frame, position and playback controls. | Editable player chrome, separate paused/playing states, poster image nodes, and a linked video. Keep artwork separate from controls. |

The DEBUG fixture harness disables its own transitions for reproducible stress captures. It does not prove the app's motion. Capture motion from ordinary app flows.

## Editable document contract

- Extract light and dark color values from the current asset catalog. Use named variables for Ground, Raised, Ink, SecondaryInk, Rule, Accent, ActionFill and OnAccent.
- Use shared components for recurring controls and cards. Keep text, shapes, icons, images and overlays as separate layers.
- Use native capture dimensions and control positions. Mark any inaccessible visual details that require measurement from pixels.
- Put screenshot references beside editable screens. Give each screen its state name, e2e evidence path, appearance and viewport.
- Include a component page and a motion page. Include narrow, wide, large text and RTL screens only after they are captured.
- Validate the final document through pen.dev, save it, reopen it and inspect layer editability and render fidelity.
