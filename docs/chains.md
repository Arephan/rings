# Chains

A chain is two or more rings where one reads what another wrote.

The important claim: **a chain is data, not control flow.** No ring runs another
ring. There is no orchestrator, no queue, no supervisor. Each ring wakes on its own
trigger, and a downstream ring's first act is to look at its input and decide
whether it is fresh enough to use.

```
scout  ─writes→  out/findings.md  ─read by→  writer  ─writes→  out/report.md
 :05                                          :20
```

## Why not a DAG engine

A DAG engine is a process. It can crash, and when it does, every loop it owns stops
— usually quietly, because the loops themselves are fine and nothing is throwing
errors. You then have one thing to monitor that is more fragile than the nine
things it was monitoring.

Two rings and a file cannot fail that way. If `writer` runs while `scout` is broken,
`writer` sees a stale file, says so, and its own verifier decides what that is
worth. Nothing is orchestrating, so there is nothing to be down.

You give up real dependency scheduling for this. If you genuinely need "run B the
moment A finishes, and only if A succeeded", use a DAG engine and accept the
process. Most agent loops do not need it; they need B to run hourly on the freshest
A available, which is what this gives you for free.

## Declaring it

```bash
# downstream ring.conf
NEEDS="scout"
```

`NEEDS` is documentation. `rings chain` draws the graph from it, so that when a
report starts coming out wrong you can see in one command where its inputs came
from. It does not enforce anything.

## Enforcing it

The check that actually protects a downstream ring goes in `hooks/pre.sh`:

```bash
SRC="$RING_DIR/../scout/out/findings.md"
AGE=$(( $(date +%s) - $(stat -f %m "$SRC" 2>/dev/null || stat -c %Y "$SRC") ))
if [ "$AGE" -gt 7200 ]; then
  echo "pre: upstream findings are ${AGE}s old — proceeding, but say so in the report"
fi
```

Three ways to handle stale input, in increasing severity:

1. **Note it** and let the agent mention it in the deliverable. Right for most
   chains — a report that says "this is based on two-day-old data" is useful.
2. **Fail the run** by exiting non-zero from `hooks/verify.sh`. Right when acting on
   stale data is worse than not acting.
3. **Halt the ring** by writing `.halt` from `pre.sh`. Right when the upstream break
   needs a human, and you would rather have one alert than forty.

Picking wrong is not fatal, but pick on purpose. The default failure mode of a
chain is a downstream ring confidently reporting yesterday's world, which is worse
than an obvious outage because nobody investigates it.

## Ordering

Stagger the triggers. If `scout` runs at `:05` and takes four minutes, `writer` at
`:20` has plenty of room and neither cares about the other. Do not try to make them
adjacent — the gap is the whole reason this needs no coordination.

## Silence upstream

Set `NOTIFY="none"` on upstream rings. A five-ring chain that notifies at every hop
produces five messages for one piece of work, and the fastest way to make a loop
useless is to make its output something you scroll past.
