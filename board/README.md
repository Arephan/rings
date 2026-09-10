# rings board

A read-only page over the spool. The spool is the database and the CLI is the query
layer: the server has exactly six endpoints, and each one runs a single
`rings … --json` command and returns its output unchanged.

| Endpoint | Command |
|---|---|
| `/api/fleet` | `rings list --json` |
| `/api/goals` | `rings goals --json` |
| `/api/handoffs` | `rings handoffs --json` |
| `/api/doctor` | `rings doctor --json` |
| `/api/feed?n=<n>` | `rings feed <n> --json` |
| `/api/trace/<id>` | `rings trace <id> --json` |

Nothing is stored, nothing is cached, and nothing is written. If a number on the page
ever differs from the same number in the terminal, the bug is in this directory. The
server and the page both know no ring names, no types and no paths — every name on
screen came out of the CLI.

## Run it

```
rings board          # http://127.0.0.1:7781, Ctrl-C stops it
rings board 8080     # any port
```

It needs node 18 or newer. Nothing else in rings does — without node, every number on
the page is still in the `--json` flags above.

## Develop it

The page is Vite + React + Tailwind + shadcn/ui, and it is committed built: `board/dist`
is what the server serves.

```
rings board                                   # the API, on 7781
cd board/ui && npm install && npm run dev     # the page, on 5173
```

The dev server proxies `/api` to `127.0.0.1:7781`, so run both and edit against live
data. `npm run build` writes `board/dist`; commit it with the source, or the checked-in
build and the sources drift apart.

## Test it

```
bash test/board.sh    # from the repo root
```

Server tests, the UI's own tests, typecheck, build, and a check that the committed
`board/dist` matches a fresh build.

## Screenshots

```
cd board/ui && npx playwright install chromium && npm run shoot
```

Four PNGs in `board/docs`: the page in both themes, the page with nothing in it, and
the page at phone width. `board/ui/scripts/shoot.mjs` builds its own fixture homes
under `/tmp/rings-fx` (`board/test/fixture.sh` builds one of `empty`, `demo`,
`stress`), serves each on a spare port, shoots, then kills every server and deletes
the homes. Playwright is a devDependency of `board/ui` and of nothing else — the
board ships without it, and the core has never needed node at all.

## shadcn/ui

Every component on the page is shadcn/ui as the registry ships it. `components.json`
records `base-nova` on a `neutral` base — written by:

```
npx shadcn@latest init -b base -p nova --yes --css-variables
npx shadcn@latest add table card badge tabs sheet tooltip scroll-area skeleton empty separator button --yes
```

The `--base-color` flag the older docs show is gone in shadcn 4; `-b` picks the
primitive library (`base` — Base UI, not Radix) and `-p` the preset (`nova`, not
`base-nova`, whatever the CLI's own `--defaults` help text says). Tailwind and the `@`
path alias have to be wired before `init` will run: it validates them and refuses
otherwise.

One thing to know if a component is ever re-added: `scroll-area.tsx` comes out of the
registry with an `import * as React from "react"` it never uses, and `tsc -b` rejects
it under `noUnusedLocals`. That one line is deleted here. `shadcn add scroll-area
--overwrite` brings it back.
