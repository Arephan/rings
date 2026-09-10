#!/usr/bin/env bash
# The board's checks. Skips cleanly when node is absent — the core never needs it.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if ! command -v node >/dev/null 2>&1; then
  echo "  skip  board tests (no node on this machine)"
  exit 0
fi
cd "$ROOT/board" || exit 1
echo "board: server tests"
node --test test/server.test.mjs || exit 1
cd ui || exit 1
echo "board: ui install"
if [ -f package-lock.json ]; then npm ci --silent || exit 1; else npm install --silent || exit 1; fi
echo "board: helper tests"
npm test --silent || exit 1
echo "board: typecheck + build"
npm run build --silent || exit 1
cd "$ROOT" || exit 1
# git diff sees a changed asset; it does not see a new one. A build that renames
# a hashed chunk leaves the old file committed and the new file untracked, and
# only the second check catches that.
if ! git diff --quiet -- board/dist || [ -n "$(git status --porcelain -- board/dist)" ]; then
  echo "board: committed board/dist does not match a fresh build. Commit the build output."
  git --no-pager diff --stat -- board/dist
  git status --short -- board/dist
  exit 1
fi
echo "board: ok"
