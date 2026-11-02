import { test } from '@e2e-dev/mobile';
import { expect } from 'e2e';

test('the full Create button opens source selection', async ({ app, screen, device }) => {
  if (process.env.WAYFARER_USE_INSTALLED !== '1') await device.installApp();
  await app.open();
  await device.closeApp();
  await app.open();
  await expect(screen.getByTestId('create-montage')).toBeVisible();
  const create = screen.getByTestId('create-montage');
  const frame = await create.boundingBox();
  if (!frame) throw new Error('Create has no accessibility frame');
  await create.tap({ position: { x: frame.width / 2, y: frame.height / 2 } });
  await expect(screen.getByTestId('sample-12')).toBeVisible({ timeout: 10_000 });
  await app.screenshot('source-selection');
});
