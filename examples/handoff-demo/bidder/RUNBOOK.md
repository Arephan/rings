# bidder

For every prospect in the inbox: decide it. `accept` it if a proposal went out
(write the proposal payload under `out/emit/` and an `emit proposal.sent@1 …`
line with `cause=` set to the prospect's id), or `reject` it with a reason the
scout can learn from. Never leave an item undecided; silence costs it an attempt.
