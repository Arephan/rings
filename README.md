# rings

A template for running agents on a loop, unattended, without lying to yourself about whether they worked.

One **ring** is one loop. Rings compose into **chains**. That is the whole model.

```
trigger  →  goal  →  act  →  verify  →  stop
   ↑                                      │
   └──────────────  memory  ──────────────┘
```

Nothing here is a framework. It is bash, it has no dependencies, and it runs the
agent you already use — `claude -p`, `codex exec`, `llm`, a Python script, whatever
takes a prompt and does work.

## Why this exists

Everyone who runs agents on a schedule writes the same 200 lines of bash, badly,
twice. Then they discover the same five failures in the same order:

1. Two runs overlap and corrupt each other's output.
2. A run hangs and holds the lock until the machine reboots.
3. A syntax error makes the loop exit 0 without doing anything, and nobody notices for eight hours.
4. The loop runs every 30 minutes for a week and produces nothing, at full token price.
5. The loop reports that it ran. Nobody can tell whether it *worked*.

`rings` is those 200 lines, written once, with those five failures closed. The
part you should be writing — what the agent is actually for — stays in a markdown
file you own.

## Five minutes

```bash
git clone https://github.com/Arephan/rings.git ~/rings
export PATH="$HOME/rings/bin:$PATH"
rings demo      # three rings hand one fact to an outcome, in ~/.rings
rings board     # watch it at http://127.0.0.1:7781 (needs node 18+)
```

`rings demo` copies three rings — scout, bidder, closer — into `~/.rings`, runs
each once, and prints the funnel and the feed. Nothing calls a model; the agents
are shell scripts. `rings board` shows the same data as a page and re-reads it
every five seconds. Add that `export` line to your shell's rc file to keep
`rings` on your PATH. Then:

```bash
rings new nightly-digest                     # your first real ring
$EDITOR ~/.rings/nightly-digest/RUNBOOK.md   # what it is for
$EDITOR ~/.rings/nightly-digest/ring.conf    # when, with what, how you will know
rings run nightly-digest                     # by hand, watch it
rings install nightly-digest                 # only now give it a schedule
```

`rings install` writes a launchd agent on macOS and a systemd user timer on Linux,
from the `SCHEDULE` line in `ring.conf`. You never write a plist.

Requirements: bash, `timeout` (or `gtimeout` from coreutils on macOS) to enforce
the wall clock, `curl` for notifications. `rings board` alone needs node 18+.
Run `bash test/smoke.sh` before you trust any of it with a schedule; it needs no
API key and no network.

Or skip the demo and run a shipped example directly, with nothing installed at all:

```bash
rings run examples/hello-ring
```

That example ships a fake agent — a shell script — so you can watch a full cycle
(lock, guard, budget, run, verify, ledger, notify) without spending a cent.

## The five primitives

Everything in `ring.conf` is one of these. There is nothing else.

| primitive | what it is | where it lives |
|---|---|---|
| **trigger** | when the ring wakes | `SCHEDULE`, a cron line |
| **goal** | the contract the agent runs against | `RUNBOOK.md` |
| **verifier** | how the run proves it did something | `DELIVERABLE`, or `hooks/verify.sh` |
| **stop** | the four rules that keep it from becoming a bill | `TIMEOUT`, `LOCK_STALE`, `MAX_RUNS_PER_DAY`, `.halt` |
| **memory** | what the run knows about the last one | `ledger.jsonl`, and the previous deliverable |

Full detail in [docs/primitives.md](docs/primitives.md).

## The one opinion

**An exit code of zero is not evidence of work.**

Every ring declares a `DELIVERABLE`. The runner deletes it *before* the agent
starts, so last run's output can never be mistaken for this run's. If the file is
missing or empty afterward, the run is recorded as `unverified` — no matter how
cleanly the agent exited — and you get told.

If a file is too weak a test, write `hooks/verify.sh`. Non-zero means the run
didn't count.

This is the difference between a loop you trust and a loop you *hope* about, and
it is why the notifier reports a ring's **output** or its **failure**, and never
reports that it ran. "I woke up" is not news.

## Stop rules

Four, all in `ring.conf`, all on by default:

- **Lock** — `mkdir` is atomic, unlike a pid file. Two runs never overlap. A lock older than `LOCK_STALE` belonged to a run that was killed before its trap fired, and gets reclaimed.
- **Timeout** — `TIMEOUT` is a hard wall clock. The agent is killed, not asked. Recorded as `timeout`, not silently as success.
- **Budget** — `MAX_RUNS_PER_DAY` counts today's runs in the ledger and refuses the next one. `0` means unlimited, and you should have to type the zero.
- **Halt** — `rings halt <name>` writes a `.halt` file. The ring skips every run until `rings resume`, and the schedule is never touched. Kill switches that require editing a schedule don't get used in an emergency.

Plus a guard that runs before any of it: every hook is parse-checked under both
your bash and `/bin/bash` before the agent is called. macOS launchd runs bash 3.2
while you almost certainly test under bash 5, and that gap is the single most
common cause of a loop that "runs" for a day and does nothing.

## doctor

The thing you actually need six months in, when you have nine rings and no idea
which ones are still alive:

```console
$ rings doctor
[dead]       inbox-sweep is scheduled (5 * * * *) but has never recorded a run — is the trigger installed?
[silent]     price-watch has not passed once in its last 20 runs — it is burning calls for nothing
[stale]      weekly-roundup last ran 71h ago but is scheduled 0 9 * * 1
[unbounded]  scraper ring.log is 88431KB — rotate it or write less
[unbudgeted] digest has no MAX_RUNS_PER_DAY and a live schedule — one hang loop and it runs all day
[unverified] notes declares no DELIVERABLE and has no hooks/verify.sh — nothing can tell you it worked
[stuck]      crawler holds a lock 41203s old (stale after 1800s) — next run will reclaim it
[halted]     old-thing is halted: 2026-04-02T11:04:19Z paused while the API changed
[orphan]     price-watch.prices — written every run, and no ring consumes it
[leaking]    inbox-sweep.mail — 34 of 51 rows match no consumer filter

8 ring(s), 10 finding(s).
```

Every one of those is a real failure mode with a real cost. `rings doctor` is
worth more than everything else here combined.

## Chains

A chain is **data, not control flow**. An upstream ring writes its deliverable; a
downstream ring reads it and decides for itself whether it is fresh enough to use.
Nothing orchestrates anything. There is no scheduler process and nothing to be
down; handoffs (below) add delivery and receipts, still as files, still with no
process.

```bash
# in the downstream ring.conf
NEEDS="scout"
```

`NEEDS` is documentation — `rings chain` draws the graph from it. The check that
actually protects the ring goes in `hooks/pre.sh`, where it can look at the
upstream file's age and say so. See [examples/chain-demo](examples/chain-demo) and
[docs/chains.md](docs/chains.md).

This is deliberately less than a DAG engine. A DAG engine is a process that can
crash, taking every loop with it. Two rings and a file cannot.

## Contracts

`NEEDS` draws an arrow. A contract is the same handoff written where it can be
checked — and then checked:

```bash
# scout/ring.conf
EMITS="leads:out/leads.jsonl:jsonl:72"    # name:path:format:shelf life in hours

# bidder/ring.conf
CONSUMES="scout.leads:kind=lead"          # and the rows it takes
```

```console
$ rings contracts
CONTRACT                 CARRIER                          STATUS    CONSUMERS
scout.leads              scout/out/leads.jsonl            leaking   bidder[kind=lead],filer(unwired)
digest.summary           digest/out/summary.md            orphan    -

  [leaking]   scout.leads — 1 of 3 rows match no consumer filter
  [orphan]    digest.summary — written every run, and no ring consumes it
```

Both of those are the same failure: a fleet where every ring passes and the work
still does not come out. One file is written hourly and read by nobody; one kind
of row is produced and claimed by nobody. Neither ring involved can see it —
each is individually healthy — so it has to be checked across the fleet.

A declaration does not count as wiring. A consumer only counts if that ring's own
runbook, scripts or hooks name the file; otherwise it is reported `(unwired)`.
Its own `CONSUMES=` line is excluded, because a claim is not evidence for itself.

`RUNBOOK.md` is a ring's contract with you. `EMITS`/`CONSUMES` is its contract
with the rest of the fleet, and `SERVES` says which outcome in
`$RINGS_HOME/rings.conf` it is ultimately for:

```console
$ rings goals
apex: signed work, and nothing that does not lead to it

  revenue  — Money in
      scout            leads:out/leads.jsonl:jsonl:72
      bidder           (emits nothing)

  serving no stated outcome: filer
```

`rings contracts --json` prints the verified graph for anything you want to build
on top. Keep no second copy of it — a dashboard with its own registry of what
feeds what starts lying to you on day two.

See [docs/contracts.md](docs/contracts.md) and
[examples/contract-demo](examples/contract-demo), which ships deliberately broken.

## Handoffs

A contract checks that a consumer names the carrier. A handoff has the runner
carry the work:

```bash
# rings.conf
CHAIN_revenue="tender.discovered@1 bid.submitted@1 contract.signed@1"
# scout/ring.conf
EMITS="tender.discovered@1"
# bidder/ring.conf
CONSUMES="tender.discovered@1"
EMITS="bid.submitted@1"
```

The runner leases each item into the consumer's `in/`, tells the agent about it
in the prompt, and reads its decisions back from `out/handoffs` — `accept <id>`,
`reject <id> <reason>`, or `emit <type> key=… cause=… file=…` to hand work on.
Every item is typed, checksummed, and refused if it fails the type's `accept.sh`.
Every step leaves a receipt. `rings trace <id>` walks one item from source to
outcome; `rings goals` shows the funnel; `rings feed` shows what just happened.

Runner-verified, not tamper-proof — and that is said out loud in
[docs/handoffs.md](docs/handoffs.md). Try [examples/handoff-demo](examples/handoff-demo).

## Commands

```
rings new <name>            scaffold a ring in $RINGS_HOME
rings run <name>            run a ring once, right now
rings list [--json]         every ring, its schedule, its last verdict
rings status [name]         detail for one ring, or all of them
rings doctor [--json]       find dead, silent, runaway and unbounded rings
rings halt <name> [reason]  stop a ring without touching its schedule
rings resume <name>         let it run again
rings install <name>        register its trigger (launchd / systemd / cron)
rings uninstall <name>      unregister the trigger, keep the ring
rings logs <name> [n]       tail the ring log
rings chain                 the dependency graph across rings
rings contracts [--json]    every declared handoff, and whether it is real
rings goals [--json]        every ring under the outcome it serves, and the funnel
rings emit <ring> <type> key=<k> [cause=<id>] [ref=<r>] --file <payload>
                            publish a work item from a script or by hand
rings retry <id> [<ring>]   dead → ready with attempts reset; or hand an item to a ring
rings inbox <ring>          what has been handed to a ring, and its state
rings handoffs [--json]     per type: items, ready, leased, accepted, rejected, dead
rings trace <id> [--json]   one item's whole life, source to outcome
rings feed [n] [--json]     the newest n events across the fleet (default 50)
rings board [port]          serve the read-only board on localhost (default 7781)
rings demo                  three rings, one fact, one outcome — in an empty RINGS_HOME
rings version
```

## Notifications

`NOTIFY` in `ring.conf`:

- `stdout` — default, and correct while you're building
- `none` — for upstream rings in a chain, which should be silent
- `slack` — needs `RINGS_SLACK_TOKEN` (or `~/.rings_slack_token`) and `RINGS_SLACK_CHANNEL`
- `webhook` — needs `RINGS_WEBHOOK_URL`
- anything else is treated as a shell command the message is piped into

## Layout

```
~/.rings/
├── rings.conf           what the fleet is for: APEX, SINKS, and each CHAIN_<sink>
├── types/
│   └── <type>/accept.sh the gate for one handoff type, if it has one
├── spool/               every handoff item and its delivery records — written by
│                         the runner, readable and repairable by hand; rings
│                         inbox / handoffs / trace / feed are the easy way in
└── <name>/
    ├── ring.conf        the five primitives, plus EMITS / CONSUMES / SERVES
    ├── RUNBOOK.md       the contract — this is the prompt
    ├── hooks/
    │   ├── pre.sh       runs before the agent (check inputs, fetch state)
    │   ├── verify.sh    decides whether the run counted
    │   └── post.sh      runs after the verdict, gets $RING_VERDICT
    ├── in/              items leased to this ring for the current run
    ├── out/             the deliverable lands here; out/emit and out/handoffs
    │                     are how a run publishes and decides handoff items
    ├── runs/            one receipt per run, when handoffs are in play
    ├── ledger.jsonl     one line per run, forever
    └── ring.log         what happened
```

`RUNBOOK.md` is the whole prompt, plus a short generated block naming the ring, the
time, and the previous deliverable. You edit the runbook. You never edit the loop.

## What this is not

- Not a framework. There is no runtime, no daemon, no server, nothing to keep up.
- Not an orchestrator. Rings do not call rings. If you need a DAG, you need a DAG engine, and you should know that you're taking on a process that can fail.
- Not agent-specific. `AGENT` is a shell command. It has been run against Claude Code, Codex, and plain Python scripts; nothing in here knows or cares which.
- Not a prompt library. What your agent should do is your problem, and it is the only part that should be custom.

## License

MIT.
