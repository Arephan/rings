# Contributing

The bar for anything added here is: **does it close a failure mode that has
actually bitten someone running agents unattended?**

If yes, it probably belongs. If it is a feature that would be nice, it probably
belongs in your ring's hooks instead — that is what they are for.

## Constraints that are not up for negotiation

- **bash 3.2.** macOS launchd runs it. No associative arrays, no `${var^^}`, no
  `mapfile`, no `&>>`. `test/smoke.sh` parse-checks every shipped script under
  `/bin/bash` and CI runs on macOS.
- **No dependencies.** bash, and optionally `curl` and `timeout`. Not jq, not
  Python, not Node. A loop that runs unattended for months should not be able to
  break because a package manager changed.
- **No daemon.** Nothing that has to be up for a ring to run. `rings run <name>` is
  a single idempotent command and it must stay that way.
- **Agent-agnostic.** `AGENT` is a shell command. Nothing in here should know which
  model or CLI is behind it.

## Before you open a PR

```bash
bash test/smoke.sh
shellcheck -s bash -e SC1090,SC1091,SC2034 bin/rings lib/ring.sh
```

New behaviour needs a case in `test/smoke.sh`, and the test has to fail without
your change. The suite runs with no API key and no network; keep it that way.
