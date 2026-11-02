import { test as mobileTest } from '@e2e-dev/mobile';

/** Save pixels and the native control tree through the same e2e test. Run with --debug. */
export const test = mobileTest.extend<{ capture: (label: string) => Promise<void> }>({
  capture: async ({ app, agent }, use) => {
    await use(async (label) => {
      const screenshot = await app.screenshot(label);
      await agent.act('Record the screen catalog layout', { params: { label, screenshot } });
    });
  },
});
