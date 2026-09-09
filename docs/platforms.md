# Platforms

## macOS (launchd)

`rings install <name>` writes `~/Library/LaunchAgents/rings.<name>.plist` from your
`SCHEDULE` line and loads it. `rings uninstall` unloads and removes it.

Things that will cost you an afternoon if you don't know them:

- **launchd runs `/bin/bash`, which is 3.2** — from 2007, no associative arrays, no
  `${var^^}`, no `mapfile`. You test under bash 5 from Homebrew. A script that works
  in your terminal can die under the scheduler, and it dies *quietly*: the loop
  "ran", exited non-zero, and nothing looked wrong. `rings` parse-checks every hook
  under both before spending a call, and its own code is written for 3.2.
- **launchd inherits almost no environment.** No `PATH` beyond the system default,
  no `nvm`, no Homebrew. Set what you need explicitly in `hooks/pre.sh` or give
  `AGENT` an absolute path.
- **A missed trigger is a skipped trigger.** If the machine is asleep at `:17`, that
  run does not happen and is not made up. If a ring must run daily, give it several
  chances or check the ledger.
- **`StartCalendarInterval` is not cron.** `rings install` translates the common
  cases — minute lists, hour lists, weekdays. Day-of-month and month ranges are
  flagged in a comment rather than silently mistranslated; edit those by hand.

## Linux (systemd user timers)

`rings install` writes `~/.config/systemd/user/rings.<name>.{service,timer}` and
enables the timer. It needs `ONCALENDAR` in `ring.conf`, in systemd's own syntax
(`*:17,47`), because translating cron to `OnCalendar` correctly in every case is
not worth the bug it would eventually cause.

- `Persistent=true` is set, so a trigger missed while the machine was off runs at
  the next boot. This is the opposite of launchd's behaviour — decide which you want.
- User timers stop when the user logs out unless lingering is enabled:
  `loginctl enable-linger $USER`.
- `journalctl --user -u rings.<name>` for the systemd side; `rings logs <name>` for
  the ring's own log.

## Anything else (cron)

`rings install` prints the crontab line and lets you add it:

```
17,47 * * * * /path/to/rings/bin/rings run <name> >> /path/to/ring/cron.log 2>&1
```

cron's environment is as sparse as launchd's, with the same consequences. Redirect
output, or cron will try to mail it to you.

## Containers

Nothing here needs a scheduler at all: `rings run <name>` is a single idempotent
command with its own locking. Point Kubernetes CronJob, ECS Scheduled Tasks, or a
GitHub Actions `schedule:` at it and mount the ring directory somewhere persistent
so `ledger.jsonl` and the previous deliverable survive. Without persistence you lose
memory and the budget, and a ring without memory repeats itself forever.
