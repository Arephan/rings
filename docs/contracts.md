# Contracts

A chain says ring B reads ring A. A contract is that claim written down where it
can be checked, and then checked.

```bash
# scout/ring.conf
EMITS="leads:out/leads.jsonl:jsonl:72"

# bidder/ring.conf
CONSUMES="scout.leads:kind=lead"
```

```
$ rings contracts
CONTRACT                 CARRIER                          STATUS    CONSUMERS
scout.leads              scout/out/leads.jsonl            leaking   bidder[kind=lead],filer(unwired)

  [leaking]   scout.leads — 1 of 3 rows match no consumer filter
```

## The failure this exists for

A loop that breaks loudly gets fixed the same day. The one that costs you months
looks like this: every ring runs, every ring exits clean, every ledger says
`pass`, and the work still does not come out the other end — because one file in
the middle is written every hour and read by nobody.

Nothing in a per-ring view can see it. The producer is healthy: it wrote its
file. The consumer is healthy: it ran. The failure is in the gap between two
rings that are each individually fine, which is why it has to be checked at the
fleet level, and why `rings doctor` reports it alongside dead and runaway rings.

Two shapes of it, both common:

- **Orphan.** A ring writes a file every run and no ring reads it. Pure cost.
- **Leak.** A producer emits rows of several kinds and the consumers only claim
  some of them. The rest sit in the file forever. Nobody notices, because the
  file is not empty and both rings pass.

## Declaring

`EMITS` is `name:path:format:shelf-life`. The path is relative to the ring
directory; the shelf life is in hours, `0` for never expires.

```bash
EMITS="leads:out/leads.jsonl:jsonl:72"
EMITS="report:out/report.md:markdown:24 walls:out/walls.md:markdown:0"
```

Format is guessed from the extension when you leave it out. `jsonl` is the only
one that gets row-level checking — one JSON object per line, which is worth
preferring for anything a machine reads downstream.

`CONSUMES` is `producer.name`, with an optional row filter:

```bash
CONSUMES="scout.leads:kind=lead"
CONSUMES="scout.leads bigboard.tenders:kind=tender"
```

The filter is a single `key=value` against each row's top-level JSON keys. It is
deliberately not a query language: its job is to say which rows this ring is
claiming responsibility for, so that rows nobody claims can be counted.

`SERVES` names an outcome from `$RINGS_HOME/rings.conf`, and `rings goals`
prints every ring underneath the outcome it feeds — plus the ones underneath
nothing, which is the list worth reading.

## Wiring is checked, not declared

A `CONSUMES` line is a promise. The check is whether the consuming ring's own
files — its runbook, its scripts, its hooks — mention the carrier file by name.
If they never do, the ring cannot be reading it, whatever the declaration says,
and the contract is reported as `orphan` or the consumer as `(unwired)`.

The ring's own `CONSUMES=` lines are excluded from that search on purpose. A
claim is not evidence for itself.

This is a deliberately shallow check. It cannot prove a ring uses the file
correctly, only that the file is named somewhere it plausibly could. That is
enough to catch the thing that actually happens — the declaration written once,
the wiring never done — while staying a grep with no runtime instrumentation and
no agreement required from the agent doing the work.

## Statuses

| status | meaning |
|---|---|
| `flowing` | present, fresh, and every row claimed |
| `orphan` | nothing reads it, or every declared consumer is unwired |
| `partial` | some declared consumer never mentions it |
| `leaking` | rows in the file that no consumer's filter claims |
| `stale` | older than its declared shelf life |
| `missing` | the ring says it emits this and the file is not there |
| `dangling` | a `CONSUMES` naming an emit no ring declares |

## Building on it

`rings contracts --json` prints the whole verified graph — carriers, consumers,
row counts, stranded counts, statuses. That is the interface for anything you
want to put on top: a dashboard, a weekly digest, a check in CI.

Do not keep a second copy of the graph in that tool. The reason this is worth
having at all is that the declaration and the thing being described sit in the
same file, so they move together; a dashboard with its own registry of what
feeds what starts drifting on day two and then quietly lies to you.

## Try it

```bash
cp -r examples/contract-demo/* ~/.rings/
(cd ~/.rings/scout && bash agent.sh)
rings contracts
```

That fleet ships broken: one ring declares it consumes the scout's rows and then
never opens the file. Add the file to its runbook and run `rings contracts`
again to watch it go green.
