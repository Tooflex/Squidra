import { defineConfig } from '@playwright/test';
export default defineConfig({ testDir: './tests', workers: 1, timeout: 30000, retries: 0,
  reporter: [['list'], ['json', { outputFile: 'test-results/report.json' }]],
  use: { baseURL: 'http://127.0.0.1:43127', browserName: 'chromium', trace: 'off' },
  webServer: { command: 'node serve.mjs', env: { SQUIDRA_WEB_PORT: '43127' }, url: 'http://127.0.0.1:43127', reuseExistingServer: false },
});
