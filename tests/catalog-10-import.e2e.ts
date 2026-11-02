import { expect } from 'e2e';
import { test } from './catalog.ts';
import { tapVisibleControl } from './controls.ts';

test('catalog: Photos and Files pickers from the empty home and appended clips', async ({ app, screen, device, capture }) => {
  await device.installApp(undefined, { reinstall: true });
  await device.setPermission('photos', 'grant');
  await app.open();
  await expect(screen.getByTestId('create-montage')).toBeVisible();
  await tapVisibleControl(screen.getByTestId('create-montage'));
  await capture('home-source-import-actions');

  await tapVisibleControl(screen.getByTestId('choose-photos'));
  await expect(screen.getByLabel('Cancel')).toBeVisible({ timeout: 30_000 });
  await capture('photos-picker-new-journey');
  await tapVisibleControl(screen.getByLabel('Cancel'));

  await tapVisibleControl(screen.getByTestId('create-montage'));
  await tapVisibleControl(screen.getByTestId('choose-files'));
  await expect(screen.getByLabel('Cancel')).toBeVisible({ timeout: 30_000 });
  await capture('files-picker-new-journey');
  await tapVisibleControl(screen.getByLabel('Cancel'));

  await tapVisibleControl(screen.getByTestId('create-montage'));
  await tapVisibleControl(screen.getByTestId('sample-12'));
  await expect(screen.getByTestId('processing-title')).toBeVisible({ timeout: 30_000 });
  await tapVisibleControl(screen.getByTestId('pause-processing'));
  await expect(screen.getByText('Continue finding moments', { exact: true })).toBeVisible();
  await tapVisibleControl(screen.getByLabel('Project options', { exact: true }));
  await tapVisibleControl(screen.getByText('Add more clips', { exact: true }));
  await capture('append-clips-actions');

  await tapVisibleControl(screen.getByText('Choose videos from Photos', { exact: true }));
  await expect(screen.getByLabel('Cancel')).toBeVisible({ timeout: 30_000 });
  await capture('photos-picker-append-journey');
  await tapVisibleControl(screen.getByLabel('Cancel'));

  await tapVisibleControl(screen.getByLabel('Project options', { exact: true }));
  await tapVisibleControl(screen.getByText('Add more clips', { exact: true }));
  await tapVisibleControl(screen.getByText('Import videos from Files', { exact: true }));
  await expect(screen.getByLabel('Cancel')).toBeVisible({ timeout: 30_000 });
  await capture('files-picker-append-journey');
  await tapVisibleControl(screen.getByLabel('Cancel'));
  await expect(screen.getByTestId('clip-count')).toContainText('12 clips');
  await app.back();
  await expect(screen.getByTestId(/^project-card-/)).toHaveCount(1);
  await capture('home-after-cancelled-imports-with-draft');
});
