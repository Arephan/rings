# Stop rules

The rules that decide when a ring does *not* run, or stops running. They are the
difference between an agent loop and a runaway bill, and they are the part of a
hand-rolled loop that is always added after the incident rather than before.

Order of evaluation, all before a single token is spent:

## 1. Halt

`.halt` exists → skip, log, exit 0.

```bash
rings halt price-watch "vendor changed their API, revisit Monday"
rings resume price-watch
```

The reason is stored with a timestamp, and `rings doctor` surfaces halted rings so
a temporary pause does not become a silent permanent one.

Why a file rather than unloading the schedule: an emergency stop must be one
command, must work from a script, and must leave evidence. Unloading a launchd
agent is three steps and leaves nothing behind but your memory of doing it.

## 2. Budget

`MAX_RUNS_PER_DAY` counts today's ledger lines and refuses the next run.

The arithmetic that makes this non-optional: a ring on a 30-minute trigger is 48
runs a day. At a couple of thousand tokens of context each, that is fine. The day
you add a source that makes each run read ten files and think for four minutes, it
is not, and you will find out at the end of the billing period.

Set it to a number slightly above what the ring actually needs. When it starts
tripping, that is information — something changed.

## 3. Lock

`mkdir` is atomic on every filesystem worth having; a pid file is not, and `pgrep`
races. If the lock exists and is younger than `LOCK_STALE`, the new run skips.
Older than that, it belonged to a run killed before its trap fired, and is
reclaimed with a line in the log.

Set `LOCK_STALE` above `TIMEOUT`. The default is `TIMEOUT + 300`. Below it, a run
that is legitimately still working gets its lock stolen and you get two agents
writing the same file.

## 4. Guard

Every `hooks/*.sh` is parse-checked under your bash *and* `/bin/bash` before the
agent is called. Failure exits 3 and notifies.

This exists because of a specific, common, expensive outage: an edit introduces a
bash-5-only construct, the terminal test passes, the scheduler's bash 3.2 chokes,
and the loop spends a day "running" and producing nothing. Nothing throws. Nothing
alerts. You notice when you go looking for output that was never there.

## 5. Timeout

`TIMEOUT` is a hard wall clock via `timeout(1)`. Exit 124 is recorded as `timeout`,
distinct from `error`, because they mean different things: `error` is a crash,
`timeout` is a ring that has outgrown its budget or is waiting on something that
will never answer.

Without a timeout, a hung agent holds the lock, and every subsequent run skips —
so the ring is dead but its log fills with cheerful "previous run still active"
lines. That is the worst failure shape here: silent, self-concealing, and it looks
like the locking is working correctly.

## And one that is not a stop rule

**Nothing here stops on cost, only on count.** `MAX_RUNS_PER_DAY` is a proxy: it
bounds calls, not dollars, and a single call with a large context can cost more
than fifty small ones. If your agent exposes a real spend number, capture it in
`hooks/post.sh` and enforce against it — the ledger is a JSONL file, add a field.

Do not pretend a run count is a budget. It is a fuse, not a meter.
