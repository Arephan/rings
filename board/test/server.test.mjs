import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { mkdtempSync, cpSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const RINGS = join(ROOT, 'bin', 'rings');

function cli(home, args) {
  return execFileSync(RINGS, args, { env: { ...process.env, RINGS_HOME: home }, encoding: 'utf8' });
}

const children = [];

async function startServer(home, extraEnv = {}) {
  const port = 20000 + Math.floor(Math.random() * 20000);
  const child = spawn(process.execPath, [join(ROOT, 'board', 'server.mjs'), String(port)], {
    env: { ...process.env, RINGS_HOME: home, RINGS_BIN: RINGS, ...extraEnv },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  children.push(child);
  let stderr = '';
  await new Promise((resolve, reject) => {
    child.stdout.on('data', (d) => { if (String(d).includes('listening')) resolve(); });
    child.stderr.on('data', (d) => { stderr += String(d); });
    child.on('exit', (code) => reject(new Error(`server exited before listening (code ${code}): ${stderr}`)));
    setTimeout(() => reject(new Error(`server did not start: ${stderr}`)), 5000);
  });
  return { child, base: `http://127.0.0.1:${port}` };
}

let demo, empty, demoSrv, emptySrv, badBinSrv;

before(async () => {
  demo = mkdtempSync(join(tmpdir(), 'rings-demo-'));
  cpSync(join(ROOT, 'examples', 'handoff-demo'), demo, { recursive: true });
  for (const r of ['scout', 'bidder', 'closer']) cli(demo, ['run', r]);
  empty = mkdtempSync(join(tmpdir(), 'rings-empty-'));
  mkdirSync(empty, { recursive: true });
  demoSrv = await startServer(demo);
  emptySrv = await startServer(empty);
  badBinSrv = await startServer(empty, { RINGS_BIN: '/nonexistent/rings' });
});

after(() => { for (const c of children) c.kill(); });

const ENDPOINTS = [
  ['/api/fleet', ['list', '--json']],
  ['/api/goals', ['goals', '--json']],
  ['/api/handoffs', ['handoffs', '--json']],
  ['/api/feed?n=7', ['feed', '7', '--json']],
  ['/api/doctor', ['doctor', '--json']],
];

for (const [path, args] of ENDPOINTS) {
  test(`${path} returns the CLI's output byte for byte`, async () => {
    const res = await fetch(demoSrv.base + path);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('content-type'), 'application/json');
    assert.equal(res.headers.get('cache-control'), 'no-store');
    const body = await res.text();
    // "generated" differs by the second between two invocations; compare everything else
    const strip = (s) => s.replace(/"generated": "[^"]*"/, '"generated": "X"');
    assert.equal(strip(body), strip(cli(demo, args)));
  });
  test(`${path} on an empty fleet is valid JSON`, async () => {
    const res = await fetch(emptySrv.base + path);
    assert.equal(res.status, 200);
    const j = JSON.parse(await res.text());
    assert.ok(typeof j === 'object');
  });
}

test('/api/trace/<id> traces an item from the feed', async () => {
  const feed = JSON.parse(cli(demo, ['feed', '--json']));
  const published = feed.events.find((e) => e.kind === 'published');
  const res = await fetch(`${demoSrv.base}/api/trace/${published.id}`);
  assert.equal(res.status, 200);
  const j = JSON.parse(await res.text());
  assert.equal(j.item.id, published.id);
});

test('/api/trace/<unknown> is a 404 with an error body', async () => {
  const res = await fetch(`${demoSrv.base}/api/trace/not-an-id`);
  assert.equal(res.status, 404);
  const j = JSON.parse(await res.text());
  assert.match(j.error, /no item/);
});

test('an unknown api path is a 404', async () => {
  const res = await fetch(`${demoSrv.base}/api/nope`);
  assert.equal(res.status, 404);
});

test('the root serves the page or a clear message when dist is missing', async () => {
  const res = await fetch(demoSrv.base + '/');
  assert.ok(res.status === 200 || res.status === 503);
  const body = await res.text();
  assert.ok(body.includes('<') || body.includes('npm run build'));
});

test('a path outside dist is not served', async () => {
  const res = await fetch(demoSrv.base + '/../server.mjs');
  assert.notEqual(await res.text(), (await import('node:fs')).readFileSync(join(ROOT, 'board', 'server.mjs'), 'utf8'));
});

test('GET /%zz is a 400 with no path disclosure', async () => {
  const res = await fetch(demoSrv.base + '/%zz');
  assert.equal(res.status, 400);
  const body = await res.text();
  assert.equal(body, 'bad path');
  assert.ok(!body.includes('server.mjs'));
  assert.ok(!body.includes('/Users'));
});

test('/api/fleet with a broken RINGS_BIN is a 500', async () => {
  const res = await fetch(badBinSrv.base + '/api/fleet');
  assert.equal(res.status, 500);
  const j = JSON.parse(await res.text());
  assert.match(j.error, /cannot run rings/);
});
