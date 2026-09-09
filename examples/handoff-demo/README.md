# handoff-demo

Three rings, one fact, one outcome. Nothing here calls a model; the agents are
shell scripts so you can watch the mechanics for free.

The demo must never touch a real fleet, so it runs in a throwaway home:

    export RINGS_HOME=$(mktemp -d) && cp -r examples/handoff-demo/. "$RINGS_HOME"/
    rings run scout      # emits prospect.qualified@1
    rings run bidder     # leases it, accepts it, emits proposal.sent@1 with cause=
    rings run closer     # leases that, accepts it, emits deal.signed@1 with ref=
    rings goals          # the funnel: 1 → 1 → 1
    rings feed           # what just happened, newest first
    rings handoffs       # per type: items, ready, accepted …
    rings trace <id>     # any id from the feed: source to outcome

Then break it. Delete `$RINGS_HOME/types/proposal.sent@1/accept.sh` and run
`rings doctor`: the type is `[ungated]`. Edit `$RINGS_HOME/bidder/agent.sh` to
write nothing to `out/handoffs`, run `bidder` three times, and the prospect is
`[dead-letter]`. `rings retry <id> bidder` brings it back.

Nothing above writes to `~/.rings`. When you are done, `rm -rf "$RINGS_HOME"`
and the whole demo is gone.

`prospect.qualified@1` ships with no gate on purpose, so `rings doctor` has one
finding to show you on a fresh clone.
