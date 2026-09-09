#!/usr/bin/env node
// board/test/shoot.mjs — screenshot every tab of every fixture into board/docs/.
//
// Start the three fixture servers first (board/test/fixture.sh builds the homes):
//   RINGS_HOME=<demo> node board/server.mjs 7791   # and 7792 empty, 7793 stress
//   NODE_PATH=<dir holding playwright> node board/test/shoot.mjs
// NODE_PATH is only needed when playwright is not installed next to this repo.
import { createRequire } from 'node:module';
import { mkdir } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const { chromium } = createRequire(import.meta.url)('playwright');
const DOCS = join(dirname(fileURLToPath(import.meta.url)), '..', 'docs');
const FIXTURES = [['demo', 7791], ['empty', 7792], ['stress', 7793]];
const TABS = ['Fleet', 'Funnel', 'Handoffs', 'Feed', 'Doctor'];

// The CLI is the query layer, and on a big spool one command can take ten seconds:
// wait for the last skeleton to go rather than for a guessed number of milliseconds.
const settled = (page) => page
  .waitForFunction(() => document.querySelectorAll('[data-slot="skeleton"]').length === 0, null, { timeout: 60000 })
  .then(() => page.waitForTimeout(300));

await mkdir(DOCS, { recursive: true });
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
for (const [fixture, port] of FIXTURES) {
  await page.goto(`http://127.0.0.1:${port}`, { waitUntil: 'load' });
  await settled(page);
  for (const tab of TABS) {
    await page.getByRole('tab', { name: tab }).click();
    await settled(page);
    await page.screenshot({ path: join(DOCS, `board-${fixture}-${tab.toLowerCase()}.png`), fullPage: true });
  }
  if (fixture === 'stress') {
    await page.getByRole('tab', { name: 'Feed' }).click();
    await settled(page);
    await page.locator('button.font-mono').first().click();
    await settled(page);
    await page.screenshot({ path: join(DOCS, 'board-stress-trace.png') });
    await page.keyboard.press('Escape');
  }
}
await browser.close();
console.log(`${(FIXTURES.length * TABS.length) + 1} screenshots in board/docs`);
