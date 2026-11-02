import { test } from '@e2e-dev/mobile';
import { expect } from 'e2e';
import { tapVisibleControl } from './controls.ts';

test('Photos selection opens and cancellation returns to the library', async ({ app, screen, device }) => {
  if (process.env.WAYFARER_TEST_PHOTOS_PICKER !== '1') {
    test.skip('The current e2e mobile engine omits the loaded Photos controls. Set WAYFARER_TEST_PHOTOS_PICKER=1 to rerun the diagnostic.');
  }
  if (process.env.WAYFARER_USE_INSTALLED !== '1') await device.installApp();
  await app.open();
  await device.closeApp();
  await app.open();
  await screen.getByTestId('create-montage').tap();
  await screen.getByTestId('choose-photos').tap();
  const cancel = screen.getByRole('button', 'Cancel');
  await expect(cancel).toBeVisible();
  await expect(screen.getByText('Loading…', { exact: true }).first()).not.toBeVisible({ timeout: 120_000 });
  await app.screenshot('photos-picker-ready');
  for (const role of ['button', 'listitem', 'image'] as const) {
    const videos = await screen.getByRole(role).allTextContents();
    console.log('Photos video accessibility labels', role, videos.slice(0, 12));
  }
  console.log('Photos picker text', await screen.getByRole('text').allTextContents());
  await tapVisibleControl(cancel);
  await expect(screen.getByTestId('create-montage')).toBeVisible();
});
