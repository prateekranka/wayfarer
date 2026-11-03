import { test } from '@e2e-dev/mobile';
import { expect } from 'e2e';
import { revealControl, tapControl, tapVisibleControl } from './controls.ts';

test('a Travel edit gets a title that can be changed, exported, reopened and turned off', async ({ app, screen, device }) => {
  if (process.env.WAYFARER_USE_INSTALLED !== '1') await device.installApp();
  await app.open();
  await tapVisibleControl(screen.getByTestId('create-montage'));
  // The sheet is still sliding in when it first becomes visible.
  await expect(screen.getByTestId('sample-12')).toBeVisible();
  await new Promise((resolve) => setTimeout(resolve, 1_000));
  await tapVisibleControl(screen.getByTestId('sample-12'));
  await expect(screen.getByTestId('clip-count')).toContainText('12 clips', { timeout: 240_000 });
  await new Promise((resolve) => setTimeout(resolve, 1_000));
  await screen.getByTestId('sample-music').tap();
  await expect(screen.getByTestId('make-reel')).toBeEnabled({ timeout: 120_000 });
  await tapControl(screen, screen.getByLabel(/^More feelings,/), 'down', 'make-reel');
  // The menu repeats the style's name in its header.
  await tapVisibleControl(screen.getByText('Travel', { exact: true }).last());
  await screen.getByTestId('make-reel').tap();
  await expect(screen.getByTestId('playback-state')).toContainText('Ready to play', { timeout: 120_000 });

  // New projects start with the project's name as the title, in the style's text look.
  await revealControl(screen, screen.getByTestId('text-subtitle'), 'down', 'export-montage');
  await new Promise((resolve) => setTimeout(resolve, 1_000));
  await expect(screen.getByTestId('text-enabled')).toContainText('Typed postcard');
  await expect(screen.getByTestId('text-title')).toHaveValue('A little escape');
  await screen.getByTestId('text-title').fill('Lisbon');
  // A new simulator can show a one-time keyboard tour over the screen.
  const tour = screen.getByText('Continue', { exact: true });
  if (await tour.isVisible()) await tapVisibleControl(tour);
  // Tapping outside the keyboard could land on the export button above it.
  await tapVisibleControl(screen.getByTestId('close-title-keyboard').first());
  // The keyboard covered the second field, so bring it back into view.
  await revealControl(screen, screen.getByTestId('text-subtitle'), 'down', 'export-montage');
  await new Promise((resolve) => setTimeout(resolve, 1_000));
  await screen.getByTestId('text-subtitle').fill('June 2026');
  await tapVisibleControl(screen.getByTestId('close-title-keyboard').first());
  await revealControl(screen, screen.getByTestId('montage-player'), 'up', 'export-montage');
  await expect(screen.getByTestId('playback-state')).toContainText('Ready to play', { timeout: 120_000 });
  await app.screenshot('title-changed');

  // The words are saved when typing ends, so they survive reopening.
  // Reopening also leaves the keyboard session behind before the export tap.
  await device.closeApp();
  await app.open();
  await tapVisibleControl(screen.getByTestId(/^project-card-/).first());
  await expect(screen.getByTestId('playback-state')).toContainText('Ready to play', { timeout: 120_000 });
  await revealControl(screen, screen.getByTestId('text-subtitle'), 'down', 'export-montage');
  await new Promise((resolve) => setTimeout(resolve, 1_000));
  await expect(screen.getByTestId('text-title')).toHaveValue('Lisbon');
  await expect(screen.getByTestId('text-subtitle')).toHaveValue('June 2026');

  await tapVisibleControl(screen.getByTestId('export-montage'));
  await expect(screen.getByTestId('save-photos')).toBeVisible({ timeout: 180_000 });
  await tapVisibleControl(screen.getByTestId('close-export'));

  await revealControl(screen, screen.getByTestId('text-enabled'), 'down', 'export-montage');
  await new Promise((resolve) => setTimeout(resolve, 1_000));
  const row = await screen.getByTestId('text-enabled').boundingBox();
  if (!row) throw new Error('The title switch has no accessibility frame');
  // A native switch responds only on its own control, at the row's trailing edge.
  await screen.getByTestId('text-enabled').tap({ position: { x: row.width - 30, y: row.height / 2 } });
  await expect(screen.getByTestId('text-title')).not.toBeVisible();
  await expect(screen.getByTestId('new-edits-needed')).not.toBeVisible();
});
