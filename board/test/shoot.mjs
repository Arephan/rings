#!/usr/bin/env node
// board/test/shoot.mjs — the four screenshots in board/docs, from nothing, in one command.
//
//   node board/test/shoot.mjs
//
// It builds its own fixture homes under /tmp/rings-fx, serves each one on a spare
// port, shoots, then kills every server and deletes the homes. Nothing is left
// running and nothing outside /tmp/rings-fx and board/docs is touched. The homes
// live under /tmp on purpose: the trace sheet prints receipt paths verbatim, so a
// fixture home must not sit under a path that names a person.
//
// Playwright is not a dependency of this repo and must not become one — the board
// ships without it. Node resolves a bare import from the first node_modules above
// this file, so install one copy where this file can see it and delete it after:
//
//   npm i -D playwright && npx playwright install chromium   # from the repo root
//
// (NODE_PATH does not help: node's ESM resolver ignores it.)
import { chromium } from 'playwright';
import { execFile, spawn } from 'node:child_process';
import { mkdir, rm } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const run = promisify(execFile);
const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const DOCS = join(HERE, '..', 'docs');
const FX = '/tmp/rings-fx';
const PORTS = { demo: 7791, empty: 7792, stress: 7793 };

// board/docs holds these four and nothing else: the page in both themes, the page
// with nothing in it, and the page on a phone with the widest fleet behind it.
const SHOTS = [
  { name: 'light', fixture: 'demo', width: 1280, height: 900, fullPage: true },
  { name: 'dark', fixture: 'demo', width: 1280, height: 900, fullPage: true, colorScheme: 'dark' },
  { name: 'empty', fixture: 'empty', width: 1280, height: 900 },
  { name: 'narrow', fixture: 'stress', width: 390, height: 844 },
];

// The CLI is the query layer, and on a big spool one command takes ten seconds. Wait
// for the reading to be over rather than for a guessed number of milliseconds: no
// skeleton left anywhere, and a header that no longer says it is reading.
async function settled(page) {
  await page.waitForFunction(
    () => document.querySelectorAll('[data-slot="skeleton"]').length === 0,
    null,
    { timeout: 120000 },
  );
  await page.getByText(/reading…/).first().waitFor({ state: 'hidden', timeout: 120000 });
  await page.waitForTimeout(300);
}

async function fixture(kind) {
  const home = join(FX, kind);
  process.stdout.write(`  building ${kind} fixture\n`);
  await run('bash', [join(HERE, 'fixture.sh'), kind, home], { maxBuffer: 16 * 1024 * 1024 });
  return home;
}

function serve(home, port) {
  const child = spawn(process.execPath, [join(ROOT, 'board', 'server.mjs'), String(port)], {
    env: { ...process.env, RINGS_HOME: home },
    stdio: ['ignore', 'pipe', 'inherit'],
  });
  return new Promise((ok, fail) => {
    const timer = setTimeout(() => fail(new Error(`server on ${port} never said it was listening`)), 20000);
    child.stdout.on('data', (b) => {
      if (String(b).includes('listening')) { clearTimeout(timer); ok(child); }
    });
    child.on('exit', (code) => { clearTimeout(timer); fail(new Error(`server on ${port} exited ${code}`)); });
  });
}

const servers = [];
let browser;
try {
  await mkdir(DOCS, { recursive: true });
  for (const kind of Object.keys(PORTS)) {
    servers.push(await serve(await fixture(kind), PORTS[kind]));
  }
  browser = await chromium.launch();
  for (const shot of SHOTS) {
    const page = await browser.newPage({
      viewport: { width: shot.width, height: shot.height },
      colorScheme: shot.colorScheme ?? 'light',
    });
    await page.goto(`http://127.0.0.1:${PORTS[shot.fixture]}`, { waitUntil: 'load' });
    await settled(page);
    await page.screenshot({ path: join(DOCS, `board-${shot.name}.png`), fullPage: !!shot.fullPage });
    await page.close();
    process.stdout.write(`  board-${shot.name}.png  ${shot.fixture} ${shot.width}x${shot.height}\n`);
  }
} finally {
  if (browser) await browser.close().catch(() => {});
  for (const child of servers) child.kill('SIGTERM');
  await rm(FX, { recursive: true, force: true });
}
process.stdout.write(`${SHOTS.length} screenshots in board/docs\n`);
