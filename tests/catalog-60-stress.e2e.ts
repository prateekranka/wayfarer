import { test } from './catalog.ts';
import { expect } from 'e2e';
import { tapVisibleControl } from './controls.ts';

test('catalog: realistic fixtures, wide and narrow layouts, large text and RTL', async ({ app, screen, device, capture }) => {
  await device.installApp();
  await device.openApp('com.prateek.wayfarer.breakui', { relaunch: true, launchArguments: ['--break-ui'] });
  await expect(screen.getByTestId('break-ui-data')).toBeVisible();
  await capture('stress-demo');
  await tapVisibleControl(screen.getByText('Worst case', { exact: true }));
  await expect(screen.getByTestId(/^project-card-/).first()).toContainText('Đà Nẵng, Hội An');
  await capture('stress-long-unicode-missing-image-and-300-clips');
  await device.setOrientation('landscape-left');
  try {
    await expect(screen.getByTestId('create-montage')).toBeVisible();
    await capture('stress-wide-landscape-worst-case');
  } finally {
    await device.setOrientation('portrait');
  }
  await tapVisibleControl(screen.getByTestId('break-ui-narrow'));
  const button = await screen.getByTestId('create-montage').boundingBox();
  if (!button || button.width > 320 || button.height < 44) throw new Error('The narrow primary action is clipped or too small');
  await capture('stress-320pt');
  await tapVisibleControl(screen.getByTestId('break-ui-large-text'));
  await expect(screen.getByTestId('create-montage')).toBeVisible();
  await capture('stress-320pt-accessibility-xxxl');
  await tapVisibleControl(screen.getByTestId('break-ui-rtl'));
  await capture('stress-320pt-xxxl-rtl');
  await device.setAppearance('light');
  await capture('stress-320pt-xxxl-rtl-light');
  await tapVisibleControl(screen.getByTestId('break-ui-rtl'));
  await tapVisibleControl(screen.getByTestId('break-ui-large-text'));
  await tapVisibleControl(screen.getByTestId('break-ui-narrow'));
  await tapVisibleControl(screen.getByText('Empty', { exact: true }));
  await expect(screen.getByTestId(/^project-card-/)).toHaveCount(0);
  await capture('stress-empty-light');
  await tapVisibleControl(screen.getByText('One', { exact: true }));
  await expect(screen.getByTestId(/^project-card-/)).toHaveCount(1);
  await capture('stress-one-clip-draft');
  // This assertion is a focused regression for the skill's singular-count case.
  await expect(screen.getByTestId(/^project-card-/).first()).toContainText(/\b1 clip\b/);
  await tapVisibleControl(screen.getByTestId(/^project-card-/).first());
  await expect(screen.getByTestId('clip-count')).toHaveText('1 clip');
  await expect(screen.getByTestId('moment-count')).toHaveText('1 moment found');
  await capture('stress-one-clip-one-moment-setup');
  await app.back();
  await tapVisibleControl(screen.getByText('1,000', { exact: true }));
  await expect(screen.getByTestId('create-montage')).toBeVisible();
  await capture('stress-1000-projects-lazy-library');
  await tapVisibleControl(screen.getByText('Demo data', { exact: true }));
  await device.setAppearance('dark');
  await capture('stress-demo-restored');
});
