import { test } from '@e2e-dev/mobile';
import { expect } from 'e2e';
import { revealControl, tapControl, tapVisibleControl } from './controls.ts';

test('creative changes survive restart and produce a new 15-second portrait export', async ({ app, screen, device }) => {
  if (process.env.WAYFARER_USE_INSTALLED !== '1') await device.installApp();
  await app.open();
  await device.closeApp();
  await app.open();
  await screen.getByTestId('create-montage').tap();
  await screen.getByTestId('sample-12').tap();
  await expect(screen.getByTestId('clip-count')).toContainText('12 clips');
  await screen.getByTestId('sample-music').tap();
  await expect(screen.getByTestId('make-reel')).toBeEnabled();
  await screen.getByTestId('make-reel').tap();
  await expect(screen.getByTestId('playback-state')).toContainText('Ready to play');
  await expect(screen.getByTestId('playback-position')).toContainText(/^0:(?:0[1-9]|[1-5][0-9]) \/ /);
  await screen.getByLabel('Project options').tap();
  await screen.getByText('Creative settings', { exact: true }).tap();
  await tapControl(screen, screen.getByTestId('duration-15'), 'down', 'make-reel');
  await tapControl(screen, screen.getByText('Creative controls', { exact: true }), 'down', 'make-reel');
  const energy = screen.getByRole('slider', 'Calm to Energetic');
  await revealControl(screen, energy, 'down', 'make-reel');
  const originalEnergy = await energy.inputValue();
  const frame = await energy.boundingBox();
  if (!frame) throw new Error('The energy slider has no accessibility frame');
  await screen.swipe({
    from: { x: frame.x + frame.width / 2, y: frame.y + frame.height / 2 },
    to: { x: frame.x + frame.width * 0.82, y: frame.y + frame.height / 2 },
  });
  await expect(energy).not.toHaveValue(originalEnergy);
  const changedEnergy = await energy.inputValue();
  await tapVisibleControl(screen.getByTestId('close-creative-settings'));
  await expect(screen.getByTestId('new-edits-needed')).toBeVisible();
  await expect(screen.getByTestId('export-montage')).toHaveText('Make New Edits');
  await device.closeApp();
  await app.open();
  await screen.getByTestId(/^project-card-/).first().tap();
  await expect(screen.getByTestId('new-edits-needed')).toBeVisible();
  await screen.getByLabel('Project options').tap();
  await screen.getByText('Creative settings', { exact: true }).tap();
  await tapControl(screen, screen.getByText('Creative controls', { exact: true }), 'down', 'make-reel');
  await revealControl(screen, energy, 'down', 'make-reel');
  await expect(energy).toHaveValue(changedEnergy);
  await tapControl(screen, screen.getByLabel(/^Format,/), 'down', 'make-reel');
  await screen.getByText('4:5', { exact: true }).tap();
  await tapVisibleControl(screen.getByTestId('close-creative-settings'));
  await screen.getByTestId('export-montage').tap();
  await expect(screen.getByTestId('playback-state')).toContainText('Ready to play');
  await expect(screen.getByTestId('playback-position')).toContainText('/ 0:15');
  await expect(screen.getByTestId('playback-position')).toContainText(/^0:0[1-9] \/ /);
  await app.screenshot('new-creative-direction');
  await screen.getByTestId('export-montage').tap();
  await expect(screen.getByTestId('save-photos')).toBeVisible();
  await expect(screen.getByText(/^1,?080 × 1,?350 · H\.264$/)).toBeVisible();
  await app.screenshot('portrait-export');
});
