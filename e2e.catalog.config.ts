import type { E2EConfig, StepExecutor } from 'e2e';
import { mobile } from '@e2e-dev/mobile';
import base from './e2e.config.ts';

const catalogRecorder: StepExecutor = {
  name: 'catalog-recorder', version: '1', cache: 'off',
  async runStep(ctx) {
    if (ctx.step.kind === 'act' && ctx.step.instruction === 'Record the screen catalog layout') {
      const observation = await ctx.observe({ tree: true });
      ctx.attachTranscript(JSON.stringify({
        label: ctx.step.params?.label,
        screenshot: ctx.step.params?.screenshot,
        capturedAt: new Date().toISOString(),
        target: ctx.target.name,
        platform: ctx.target.platform,
        ...observation,
      }, null, 2));
      return { status: 'passed', summary: 'Recorded native text, control geometry, and screenshot identity for the editable screen catalog.' };
    }
    return base.agents.default.executor.runStep(ctx);
  },
};

// A disposable QA identity preserves the installed consumer app and its data.
export default {
  ...base,
  targets: [{
    name: 'catalog-iphone-18-pro-max',
    engine: mobile({ platform: 'ios', device: '8374D63E-FE43-43D4-B05A-9926E3D96D68', session: 'wayfarer-catalog', settle: false, transition: 750 }),
    app: {
      bundleId: 'com.prateek.wayfarer.breakui',
      appPath: './work/evidence/wayfarer-break-ui/20261006T201845Z.JjND42/DerivedData/Build/Products/Debug-iphonesimulator/Wayfarer.app',
    },
  }],
  tests: ['tests/catalog*.e2e.ts'],
  agents: { default: { executor: catalogRecorder } },
  workers: 1,
  timeout: 900_000,
  output: 'work/evidence/wayfarer-break-ui/20261006T201845Z.JjND42/catalog',
} satisfies E2EConfig;
