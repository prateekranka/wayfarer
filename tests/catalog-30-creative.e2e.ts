import { expect } from 'e2e';
import { test } from './catalog.ts';
import { revealControl, tapControl, tapVisibleControl } from './controls.ts';

test('catalog: custom duration, creative controls, changed direction and regenerated export', async ({ app, screen, device, capture }) => {
  await device.installApp();
  await app.open();
  await tapVisibleControl(screen.getByTestId(/^project-card-/).first());
  await expect(screen.getByTestId('playback-state')).toContainText('Ready to play');
  await tapVisibleControl(screen.getByLabel('Project options', { exact: true }));
  await tapVisibleControl(screen.getByText('Creative settings', { exact: true }));
  await capture('creative-settings-before-changes');
  await tapControl(screen, screen.getByTestId('duration-30'), 'down', 'make-reel');
  await tapControl(screen, screen.getByTestId('custom-duration'), 'up', 'make-reel');
  await capture('creative-custom-duration-stepper');
  const increment = screen.getByRole('button', /^(Increment|Increase Value)$/i);
  await revealControl(screen, increment, 'down', 'make-reel');
  for (let step = 0; step < 4; step++) await tapVisibleControl(increment);
  await expect(screen.getByText('32.0 seconds', { exact: true })).toBeVisible();
  await capture('creative-custom-32-seconds');
  await tapControl(screen, screen.getByTestId('creative-controls'), 'down', 'make-reel');
  const energy = screen.getByRole('slider', 'Calm to Energetic');
  await revealControl(screen, energy, 'down', 'make-reel');
  await capture('creative-controls-expanded');
  const original = await energy.inputValue();
  const frame = await energy.boundingBox();
  if (!frame) throw new Error('Missing native energy slider frame');
  await screen.swipe({ from: { x: frame.x + frame.width / 2, y: frame.y + frame.height / 2 }, to: { x: frame.x + frame.width * 0.82, y: frame.y + frame.height / 2 } });
  await expect(energy).not.toHaveValue(original);
  await capture('creative-energy-adjusted');
  await tapVisibleControl(screen.getByTestId('close-creative-settings'));
  await expect(screen.getByTestId('new-edits-needed')).toBeVisible();
  await expect(screen.getByTestId('export-montage')).toHaveText('Make New Edits');
  await capture('results-new-edits-required');
  await tapVisibleControl(screen.getByTestId('export-montage'));
  await expect(screen.getByTestId('playback-state')).toContainText('Ready to play', { timeout: 240_000 });
  await expect(screen.getByTestId('playback-position')).toContainText('/ 0:32');
  await capture('results-custom-32-second-edit');
  await tapVisibleControl(screen.getByTestId('export-montage'));
  await expect(screen.getByTestId('save-photos')).toBeVisible({ timeout: 240_000 });
  await capture('export-custom-32-second-edit');
});

test('catalog: Photos save denied and native share alternatives', async ({ app, screen, device, capture }) => {
  await device.installApp();
  await device.setPermission('photos', 'deny');
  try {
    await app.open();
    await tapVisibleControl(screen.getByTestId(/^project-card-/).first());
    await expect(screen.getByTestId('playback-state')).toContainText('Ready to play');
    await tapVisibleControl(screen.getByTestId('export-montage'));
    await expect(screen.getByTestId('save-photos')).toBeVisible({ timeout: 240_000 });
    await tapVisibleControl(screen.getByTestId('save-photos'));
    await expect(screen.getByText(/Photos access is disabled/)).toBeVisible();
    await capture('export-photos-permission-denied');
    await tapVisibleControl(screen.getByText('OK', { exact: true }));
    await screen.scrollUntilVisible(screen.getByText('Share your montage', { exact: true }), { direction: 'down' });
    await tapVisibleControl(screen.getByText('Share your montage', { exact: true }));
    await capture('export-native-share-sheet');
  } finally {
    await device.setPermission('photos', 'grant');
  }
});
