# Contributing

The bar for anything added here is: **does it close a failure mode that has
actually bitten someone running agents unattended?**

If yes, it probably belongs. If it is a feature that would be nice, it probably
belongs in your ring's hooks instead — that is what they are for.

## Constraints that are not up for negotiation

- **bash 3.2.** macOS launchd runs it. No associative arrays, no `${var^^}`, no
  `mapfile`, no `&>>`. `test/smoke.sh` parse-checks every shipped script under
  `/bin/bash` and CI runs on macOS.
- **No dependencies in the core.** `bin/` and `lib/` need bash, and optionally
  `curl`, `timeout`, and `shasum`/`sha256sum`. Not jq, not Python, not Node. The
  one exception is `board/`, which needs node 18+ and is optional: a fleet with
  no node has the same data through the `--json` flags.
- **No daemon.** Nothing that has to be up for a ring to run. `rings run <name>` is
  a single idempotent command and it must stay that way.
- **Agent-agnostic.** `AGENT` is a shell command. Nothing in here should know which
  model or CLI is behind it.

## Before you open a PR

```bash
bash test/smoke.sh
bash test/board.sh   # if you touched board/
shellcheck -s bash -e SC1090,SC1091,SC2034 bin/rings lib/*.sh test/smoke.sh \
  test/board.sh board/test/fixture.sh template/hooks/*.sh examples/*/agent.sh \
  examples/*/*/agent.sh examples/*/*/hooks/*.sh examples/*/types/*/accept.sh
```

That shellcheck line is the one CI runs, over every shell file the repo ships,
and `test/smoke.sh` parse-checks the same list under `/bin/bash`. Add a new
shell file to all three or to none.

New behaviour needs a case in `test/smoke.sh`, and the test has to fail without
your change. The suite runs with no API key and no network; keep it that way.
