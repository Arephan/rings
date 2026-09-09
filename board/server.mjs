#!/usr/bin/env node
// rings board — a read-only page over the spool.
//
// The spool is the database and the CLI is the query layer: every endpoint here
// runs one `rings … --json` command and returns its output unchanged. This file
// knows no ring names, no types, no paths. If a number on the page ever differs
// from the terminal, the bug is here and nowhere else.
//
// node 18+, no dependencies. Binds 127.0.0.1 only.

import { createServer } from 'node:http';
import { execFile } from 'node:child_process';
import { readFile, stat } from 'node:fs/promises';
import { join, dirname, extname, normalize, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const DIST = join(HERE, 'dist');
const RINGS = process.env.RINGS_BIN || join(HERE, '..', 'bin', 'rings');
const PORT = Number(process.argv[2] || process.env.PORT || 7781);

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
  '.json': 'application/json',
};

function rings(args) {
  return new Promise((done) => {
    execFile(RINGS, args, { env: process.env, maxBuffer: 64 * 1024 * 1024 }, (err, stdout, stderr) => {
      done({ code: err ? (err.code ?? 1) : 0, stdout, stderr });
    });
  });
}

function json(res, status, body) {
  res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  res.end(body);
}

// path → CLI args. Only these six exist; the page builds nothing else.
function route(url) {
  const p = url.pathname;
  if (p === '/api/fleet') return ['list', '--json'];
  if (p === '/api/goals') return ['goals', '--json'];
  if (p === '/api/handoffs') return ['handoffs', '--json'];
  if (p === '/api/doctor') return ['doctor', '--json'];
  if (p === '/api/feed') {
    const n = url.searchParams.get('n');
    return /^\d{1,4}$/.test(n ?? '') ? ['feed', n, '--json'] : ['feed', '--json'];
  }
  const m = p.match(/^\/api\/trace\/([A-Za-z0-9._@:+~-]{1,200})$/);
  if (m) return ['trace', m[1], '--json'];
  return null;
}

async function api(url, res) {
  const args = route(url);
  if (!args) return json(res, 404, JSON.stringify({ error: 'no such endpoint' }));
  const { code, stdout, stderr } = await rings(args);
  if (typeof code !== 'number') {
    return json(res, 500, JSON.stringify({ error: `cannot run rings: ${code}` }));
  }
  if (code !== 0) {
    return json(res, 404, JSON.stringify({ error: (stderr || stdout || `rings exited ${code}`).trim() }));
  }
  try { JSON.parse(stdout); } catch (e) {
    return json(res, 500, JSON.stringify({ error: `rings ${args.join(' ')} did not print JSON: ${e.message}` }));
  }
  json(res, 200, stdout);
}

async function file(url, res) {
  let rel;
  try {
    rel = normalize(decodeURIComponent(url.pathname));
  } catch {
    res.writeHead(400, { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' });
    res.end('bad path');
    return;
  }
  if (rel === '/' || !extname(rel)) rel = '/index.html';
  const abs = resolve(DIST, '.' + rel);
  if (!abs.startsWith(DIST)) { res.writeHead(403).end('forbidden'); return; }
  try {
    await stat(abs);
    const body = await readFile(abs);
    res.writeHead(200, { 'Content-Type': MIME[extname(abs)] || 'application/octet-stream', 'Cache-Control': 'no-store' });
    res.end(body);
  } catch {
    if (rel === '/index.html') {
      res.writeHead(503, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('board/dist is missing. Build it: cd board/ui && npm install && npm run build\n');
    } else {
      res.writeHead(404).end('not found');
    }
  }
}

createServer(async (req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  if (req.method !== 'GET') { res.writeHead(405).end(); return; }
  try {
    if (url.pathname.startsWith('/api/')) await api(url, res);
    else await file(url, res);
  } catch (e) {
    json(res, 500, JSON.stringify({ error: String(e && e.message || e) }));
  }
}).listen(PORT, '127.0.0.1', () => {
  console.log(`rings board listening on http://127.0.0.1:${PORT}  (RINGS_HOME=${process.env.RINGS_HOME || '~/.rings'})`);
});
