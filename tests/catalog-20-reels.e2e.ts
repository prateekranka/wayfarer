import { test } from './catalog.ts';
import { expect } from 'e2e';
import { revealControl, tapControl, tapVisibleControl } from './controls.ts';

// Separate saved projects exercise the public import/analyze/plan/export flow.
const cases = [
  { seconds: 15, intent: 'beatSync', title: 'Beat Sync', ratio: '9:16', name: 'Đà Nẵng · A quick escape', playerTime: '0:15', dimensions: /1,?080 × 1,?920/ },
  { seconds: 30, intent: 'story', title: 'Story', ratio: '1:1', name: 'Hội An · The journey home', playerTime: '0:30', dimensions: /1,?080 × 1,?080/ },
  { seconds: 45, intent: 'cinematic', title: 'Cinematic', ratio: '4:5', name: '山と海 — A slower afternoon', playerTime: '0:45', dimensions: /1,?080 × 1,?350/ },
  { seconds: 60, intent: 'highlights', title: 'Highlights', ratio: '16:9', name: 'The unforgettable parts 🌅', playerTime: '1:00', dimensions: /1,?920 × 1,?080/ },
  { seconds: 15, intent: 'people', title: 'People', ratio: '9:16', name: 'نور الهدى · The people who made the trip', playerTime: '0:15', dimensions: /1,?080 × 1,?920/ },
  { seconds: 30, intent: 'places', title: 'Places', ratio: '16:9', name: 'The coastal road & the old town', playerTime: '0:30', dimensions: /1,?920 × 1,?080/ },
] as const;

for (const [index, scenario] of cases.entries()) {
  test(`catalog: ${scenario.seconds}s ${scenario.title} ${scenario.ratio} reel`, async ({ app, screen, device, capture }) => {
    await device.installApp();
    await device.setPermission('photos', 'grant');
    await app.open();
    await expect(screen.getByTestId('create-montage')).toBeVisible();
    await tapVisibleControl(screen.getByTestId('create-montage'));
    const clips = scenario.seconds >= 45 ? 85 : 12;
    await tapVisibleControl(screen.getByTestId(`sample-${clips}`));
    await expect(screen.getByTestId('clip-count')).toContainText(`${clips} clips`, { timeout: 600_000 });
    await screen.getByLabel('Project name', { exact: true }).fill(scenario.name);
    await device.dismissKeyboard();
    await tapVisibleControl(screen.getByTestId('sample-music'));
    await expect(screen.getByTestId('make-reel')).toBeEnabled({ timeout: 120_000 });
    await capture(`reel-${index + 1}-setup-with-song`);
    await tapControl(screen, screen.getByTestId(`duration-${scenario.seconds}`), 'down', 'make-reel');
    if (['beatSync', 'story', 'cinematic'].includes(scenario.intent)) {
      await tapControl(screen, screen.getByTestId(`intent-${scenario.intent}`), 'down', 'make-reel');
    } else {
      await tapControl(screen, screen.getByLabel(/^More feelings,/), 'down', 'make-reel');
      await tapVisibleControl(screen.getByText(scenario.title, { exact: true }));
    }
    await tapControl(screen, screen.getByLabel(/^Format,/), 'down', 'make-reel');
    await capture(`reel-${index + 1}-format-menu`);
    await tapVisibleControl(screen.getByText(scenario.ratio, { exact: true }));
    await capture(`reel-${index + 1}-creative-direction`);
    await tapVisibleControl(screen.getByTestId('make-reel'));
    await expect(screen.getByTestId('playback-state')).toContainText('Ready to play', { timeout: 120_000 });
    await expect(screen.getByTestId('playback-position')).toContainText(`/ ${scenario.playerTime}`);
    await expect(screen.getByTestId('selected-edit-name')).toContainText(scenario.title);
    await capture(`reel-${index + 1}-preview-playing`);
    await tapVisibleControl(screen.getByTestId('preview-play-pause'));
    await expect(screen.getByLabel('Play video', { exact: true })).toBeVisible();
    await tapVisibleControl(screen.getByTestId('preview-mute'));
    await expect(screen.getByTestId('preview-mute')).toHaveValue('Muted');
    await capture(`reel-${index + 1}-preview-paused-muted`);
    await tapControl(screen, screen.getByTestId('edit-style-info'), 'down', 'export-montage');
    await expect(screen.getByTestId('close-edit-info')).toBeVisible();
    await capture(`reel-${index + 1}-style-explanation`);
    await tapVisibleControl(screen.getByTestId('close-edit-info'));
    await revealControl(screen, screen.getByTestId('selected-edit-name'), 'up', 'export-montage');
    await tapVisibleControl(screen.getByTestId('export-montage'));
    await expect(screen.getByTestId('save-photos')).toBeVisible({ timeout: 240_000 });
    await expect(screen.getByText(scenario.dimensions)).toBeVisible();
    await expect(screen.getByTestId('export-edit-name')).toContainText(scenario.title);
    await capture(`reel-${index + 1}-finished-export`);
    await tapVisibleControl(screen.getByTestId('save-photos'));
    await expect(screen.getByTestId('photos-saved')).toHaveText('Saved to Photos', { timeout: 120_000 });
    await capture(`reel-${index + 1}-saved-to-photos`);
    if (index === 0) {
      await screen.scrollUntilVisible(screen.getByTestId('keep-export-reference'), { direction: 'down' });
      await tapVisibleControl(screen.getByTestId('keep-export-reference'));
      await expect(screen.getByTestId('keep-export-reference')).toHaveText('Saved to My Style', { timeout: 120_000 });
      await capture('export-kept-as-reference');
    }
    await screen.scrollUntilVisible(screen.getByTestId('close-export'), { direction: 'up' });
    await tapVisibleControl(screen.getByTestId('close-export'));
    await app.back();
    await expect(screen.getByTestId('create-montage')).toBeVisible();
    await expect(screen.getByTestId(/^project-card-/).first()).toContainText(scenario.name);
    await capture(`reel-${index + 1}-home-exported-library`);
  });
}
