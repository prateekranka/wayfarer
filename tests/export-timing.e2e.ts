import { test } from '@e2e-dev/mobile';
import { expect } from 'e2e';

// A focused retry against the project created by settings.e2e.ts.
// Pass its saved UUID when diagnosing an encoder regression.
test('a saved 15-second portrait plan exports successfully', async ({ app, screen, device }) => {
  const projectID = process.env.WAYFARER_TIMING_PROJECT_ID;
  if (!projectID) test.skip('Run settings.e2e.ts, then provide WAYFARER_TIMING_PROJECT_ID for a focused export retry.');
  if (process.env.WAYFARER_USE_INSTALLED !== '1') await device.installApp();
  await app.open();
  await device.closeApp();
  await app.open();
  await screen.getByTestId('project-card-' + projectID).tap();
  await expect(screen.getByTestId('playback-state')).toContainText('Ready to play');
  await screen.getByTestId('export-montage').tap();
  await expect(screen.getByTestId('save-photos')).toBeVisible({ timeout: 15_000 });
  await expect(screen.getByText(/^1,?080 × 1,?350 · H\.264$/)).toBeVisible();
  await app.screenshot('portrait-timing-regression');
});
