# The five primitives

Every loop that survives contact with reality has the same five parts. Most
hand-rolled loops have three of them and discover the other two the hard way.

## 1. Trigger — when it wakes

`SCHEDULE` in `ring.conf`, in cron syntax. `rings install` translates it: a launchd
agent on macOS, a systemd user timer on Linux (which also needs `ONCALENDAR`, since
the two syntaxes are not interchangeable), a crontab line you paste anywhere else.

Two rules worth stating:

- **Odd minutes.** `17,47 * * * *` rather than `0,30 * * * *`. Everything else on
  the machine fires on the hour and the half hour; you do not want your agent
  competing with backups, indexers and every other cron job for the same CPU.
- **The schedule is not the kill switch.** Never stop a ring by editing its
  schedule — you will forget, and the ring will look scheduled and be dead. Use
  `rings halt`.

## 2. Goal — what it is for

`RUNBOOK.md` is the whole prompt. The runner appends a short generated block giving
the ring's name, the current time, and the previous deliverable, and passes the
result to `AGENT`.

Keeping the contract in markdown and the mechanism in bash is the single most
useful separation here. You will change what the ring does weekly. You will change
how it runs almost never. If those live in the same file, every edit to the goal
risks the machinery, and the machinery is what you were trying to stop rewriting.

A runbook that is working usually has these sections: what this is for, what to
read, what to do, what to write, what *not* to do, and when to stop. The template
ships them.

## 3. Verifier — how it proves it worked

The default: `DELIVERABLE` names a file. The runner **deletes it before the agent
starts**, so a stale file from last night can never be mistaken for tonight's work.
If it is missing or empty afterward, the verdict is `unverified`.

That deletion is the part people skip, and it is the part that matters. A verifier
that can pass on last run's output is not a verifier.

For anything stricter, write `hooks/verify.sh`. It gets `RING_DIR` and `RING_NAME`;
non-zero means the run did not count. Good verifiers are boring and specific:

- the deliverable is over N words (catches an agent that wrote only a header)
- it does not contain the string the agent emits when it gives up
- the row it was supposed to append to a file is actually there
- the file it was supposed to touch has a mtime from this run

A verifier you cannot state in one sentence is a sign the ring does two jobs.

## 4. Stop — the four rules

**Lock.** `mkdir` is atomic; a pid file is not. Two runs never overlap. A lock
older than `LOCK_STALE` belonged to a run killed before its trap fired, and is
reclaimed with a line in the log.

**Timeout.** `TIMEOUT` is a wall clock, enforced by `timeout(1)`. The agent is
killed, not asked. A killed run is recorded as `timeout` — the point of separating
it from `error` is that a ring which times out at exactly its limit every day is
telling you something different from one that crashes.

**Budget.** `MAX_RUNS_PER_DAY` counts today's lines in the ledger and refuses the
next run. Set it. A loop on a 30-minute trigger with an unbounded agent call is 48
calls a day, and the day you introduce a bug that makes each run take the long path
is the day you find out what that costs. `0` means unlimited, and typing the zero
should feel like a decision.

**Halt.** `rings halt <name>` writes `.halt` with a timestamp and your reason. The
ring skips every run until `rings resume`. The schedule is untouched, so the ring
stays visible in `rings list` — as `HALTED`, which is exactly what you want six
weeks later when you have forgotten it exists. `rings doctor` reports halted rings
for the same reason.

There is also a guard that runs before all four: every hook is parse-checked under
both your bash and `/bin/bash`. On macOS, launchd runs bash 3.2 while you test
under bash 5, so a script using `${var^^}` or an associative array parses fine in
your terminal and dies silently under the scheduler. That failure looks exactly
like "the loop ran and found nothing", which is why it can go unnoticed for days.

## 5. Memory — what it knows about last time

Two mechanisms, deliberately small.

**The previous deliverable** is quoted back into the prompt, with an instruction
not to repeat it. Without this, a ring on a 30-minute trigger will tell you the
same three things 48 times a day and you will stop reading it — at which point the
ring has negative value, because it costs money and you have trained yourself to
ignore it.

**`ledger.jsonl`** is one line per run, appended forever:

```json
{"ring": "digest", "started": "2026-04-02T09:17:03Z", "ended": "2026-04-02T09:29:44Z", "rc": 0, "verdict": "pass", "detail": ""}
```

It is what `rings doctor` reads, what the budget counts, and what tells you — six
months in — that a ring has not passed since March. Keep it. It is a few hundred
bytes a day and it is the only durable record that any of this worked.

Anything richer than that (what the ring learned, what it has already tried, what
it should stop doing) belongs in a file your runbook names and your agent writes.
That is application state, not loop state, and the loop should not know about it.
