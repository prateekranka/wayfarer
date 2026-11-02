import { test } from '@e2e-dev/mobile';
import { expect } from 'e2e';
import { tapVisibleControl } from './controls.ts';

test('the music file picker opens and can be cancelled', async ({ app, screen, device }) => {
  if (process.env.WAYFARER_USE_INSTALLED !== '1') await device.installApp();
  await app.open();
  await device.closeApp();
  await app.open();
  await screen.getByTestId('create-montage').tap();
  await screen.getByTestId('sample-12').tap();
  await expect(screen.getByTestId('clip-count')).toContainText('12 clips');
  await screen.getByTestId('choose-music').tap();
  const cancel = screen.getByLabel('Cancel');
  await expect(cancel).toBeVisible();
  await app.screenshot('audio-file-picker');
  console.log('File picker controls', await screen.getByRole('button').allTextContents());
  await tapVisibleControl(cancel);
  await expect(screen.getByTestId('choose-music')).toBeVisible();
});
