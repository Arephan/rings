# handoff-demo

Three rings, one fact, one outcome. Nothing here calls a model; the agents are
shell scripts so you can watch the mechanics for free.

    cp -r examples/handoff-demo/* ~/.rings/
    rings run scout      # emits prospect.qualified@1
    rings run bidder     # leases it, accepts it, emits proposal.sent@1 with cause=
    rings run closer     # leases that, accepts it, emits deal.signed@1 with ref=
    rings goals          # the funnel: 1 → 1 → 1
    rings feed           # what just happened, newest first
    rings handoffs       # per type: items, ready, accepted …
    rings trace <id>     # any id from the feed: source to outcome

Then break it. Delete `types/proposal.sent@1/accept.sh` and run `rings doctor`:
the type is `[ungated]`. Edit `bidder/agent.sh` to write nothing to
`out/handoffs`, run `bidder` three times, and the prospect is `[dead-letter]`.
`rings retry <id> bidder` brings it back.

`prospect.qualified@1` ships with no gate on purpose, so `rings doctor` has one
finding to show you on a fresh clone.
