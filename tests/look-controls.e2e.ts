import { test } from '@e2e-dev/mobile';
import { expect } from 'e2e';
import { revealControl, tapControl, tapVisibleControl } from './controls.ts';

test('turning the color look off keeps the edit, refreshes export and survives reopening', async ({ app, screen, device }) => {
  if (process.env.WAYFARER_USE_INSTALLED !== '1') await device.installApp();
  await app.open();
  await tapVisibleControl(screen.getByTestId('create-montage'));
  await tapVisibleControl(screen.getByTestId('sample-12'));
  await expect(screen.getByTestId('clip-count')).toContainText('12 clips', { timeout: 240_000 });
  await screen.getByTestId('sample-music').tap();
  await expect(screen.getByTestId('make-reel')).toBeEnabled({ timeout: 120_000 });
  await tapControl(screen, screen.getByTestId('intent-cinematic'), 'down', 'make-reel');
  await screen.getByTestId('make-reel').tap();
  await expect(screen.getByTestId('playback-state')).toContainText('Ready to play', { timeout: 120_000 });
  const edit = await screen.getByTestId('selected-edit-name').textContent();

  await revealControl(screen, screen.getByTestId('look-enabled'), 'down', 'export-montage');
  const row = await screen.getByTestId('look-enabled').boundingBox();
  if (!row) throw new Error('The color look switch has no accessibility frame');
  // A native switch responds only on its own control, at the row's trailing edge.
  await screen.getByTestId('look-enabled').tap({ position: { x: row.width - 30, y: row.height / 2 } });
  await expect(screen.getByTestId('look-strength')).not.toBeVisible();
  await expect(screen.getByTestId('new-edits-needed')).not.toBeVisible();
  await expect(screen.getByTestId('selected-edit-name')).toHaveText(edit ?? '');
  await app.screenshot('look-off');

  await screen.getByTestId('export-montage').tap();
  await expect(screen.getByTestId('save-photos')).toBeVisible({ timeout: 180_000 });
  await device.closeApp();
  await app.open();
  await tapVisibleControl(screen.getByTestId(/^project-card-/).first());
  await expect(screen.getByTestId('playback-state')).toContainText('Ready to play', { timeout: 120_000 });
  await expect(screen.getByTestId('look-strength')).not.toBeVisible();
  await app.screenshot('look-off-reopened');
});
