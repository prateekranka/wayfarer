import type { E2EConfig, StepExecutor } from 'e2e';
import { mobile } from '@e2e-dev/mobile';

// The native multiline field has an internal scroll bar that the mobile
// engine's fill hit-test treats as an overlay. Use e2e's recorded keyboard
// action after the test has explicitly focused that field. No model or API.
const referenceKeyboard: StepExecutor = {
  name: 'reference-keyboard', version: '1', cache: 'off',
  async runStep(ctx) {
    const text = ctx.step.params?.text;
    if (ctx.step.kind !== 'act' || ctx.step.instruction !== 'Type into the focused reference note' || typeof text !== 'string') {
      return { status: 'blocked', errorCode: 'AUTOMATION_UNSUPPORTED', summary: 'Only explicit reference-note keyboard input is supported.' };
    }
    // Tests open a fresh, empty note field. Do not clear a focused field:
    // the mobile engine deliberately requires a node for that operation.
    await ctx.actions.typeText(text);
    return { status: 'passed', summary: 'Typed into the focused field. The test checks its value separately.' };
  },
};

export default {
  targets: [{
    name: 'iphone',
    engine: mobile({ platform: 'ios', device: process.env.WAYFARER_TEST_DEVICE ?? '087CF025-E3C7-48D6-B2B8-292DDDC39B50', session: process.env.WAYFARER_TEST_SESSION ?? 'wayfarer-native', settle: false, transition: 750 }),
    app: {
      bundleId: 'com.prateek.wayfarer',
      appPath: process.env.WAYFARER_USE_INSTALLED === '1' ? undefined : process.env.WAYFARER_APP_PATH ?? './work/DerivedData/Build/Products/Debug-iphonesimulator/Wayfarer.app',
    },
  }],
  tests: 'tests/**/*.e2e.ts',
  agents: { default: { executor: referenceKeyboard } },
  workers: 1,
  retries: 0,
  timeout: 600_000,
  assertionTimeout: 120_000,
  actionTimeout: 90_000,
  output: 'work/e2e',
  video: 'off',
} satisfies E2EConfig;
