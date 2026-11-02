import { test } from '@e2e-dev/mobile';
import { expect } from 'e2e';
import { tapVisibleControl } from './controls.ts';

// Uses the reference produced by the playback workflow. This is a narrow
// regression for native multiline input and durable timestamp notes.
test('a reference note can be entered and saved through the native keyboard', async ({ app, screen, agent }) => {
  await app.open();
  await tapVisibleControl(screen.getByTestId('open-my-style'));
  await tapVisibleControl(screen.getByText('References', { exact: true }));
  await tapVisibleControl(screen.getByTestId(/^reference-[A-F0-9]/).first());
  await screen.scrollUntilVisible(screen.getByTestId('reference-note'), { direction: 'down' });
  await tapVisibleControl(screen.getByTestId('reference-note'));
  await agent.act('Type into the focused reference note', { params: { text: 'A steady opening makes this edit easier to watch.' } });
  await expect(screen.getByTestId('reference-note')).toHaveValue('A steady opening makes this edit easier to watch.', { timeout: 15_000 });
  await tapVisibleControl(screen.getByTestId('close-note-keyboard'));
  await tapVisibleControl(screen.getByTestId('save-reference-note'));
  await expect(screen.getByText('A steady opening makes this edit easier to watch.', { exact: true })).toBeVisible({ timeout: 15_000 });
  await app.screenshot('saved-native-reference-note');
});
