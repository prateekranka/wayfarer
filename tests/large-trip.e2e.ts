import { test } from '@e2e-dev/mobile';
import { expect } from 'e2e';
import { revealControl, tapControl } from './controls.ts';

test('85 encoded source videos produce three playable 30-second edits and export', { timeout: 900_000 }, async ({ app, screen, device }) => {
  if (process.env.WAYFARER_USE_INSTALLED !== '1') await device.installApp();
  await app.open();
  await device.closeApp();
  await app.open();
  await expect(screen.getByTestId('create-montage')).toBeVisible();
  await screen.getByTestId('create-montage').tap();
  await screen.getByTestId('sample-85').tap();
  await expect(screen.getByTestId('clip-count')).toContainText('85 clips', { timeout: 480_000 });
  await expect(screen.getByTestId('sample-music')).toBeVisible();
  await screen.getByTestId('sample-music').tap();
  await expect(screen.getByTestId('make-reel')).toBeEnabled();
  await screen.getByTestId('make-reel').tap();
  await expect(screen.getByTestId('montage-player')).toBeVisible({ timeout: 90_000 });
  await expect(screen.getByTestId('playback-state')).toContainText('Ready to play');
  await expect(screen.getByTestId('playback-position')).toContainText(/^0:(?:0[1-9]|[1-5][0-9]) \/ /);
  await app.screenshot('85-source-preview');
  for (const name of ['Beat Sync', 'Beat Sync · Flow', 'Beat Sync · Lift']) {
    await tapControl(screen, screen.getByTestId('variant-' + name), 'down', 'export-montage');
    await revealControl(screen, screen.getByTestId('montage-player'), 'up', 'export-montage');
    await expect(screen.getByTestId('playback-state')).toContainText('Ready to play');
    await expect(screen.getByTestId('playback-position')).toContainText(/^0:(?:0[1-9]|[1-5][0-9]) \/ /);
  }
  await screen.getByTestId('export-montage').tap();
  await expect(screen.getByTestId('save-photos')).toBeVisible({ timeout: 180_000 });
  await app.screenshot('85-source-export');
});
