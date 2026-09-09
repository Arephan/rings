# closer

For every proposal in the inbox, look it up in the contract system. Signed:
`accept` it and `emit deal.signed@1` with `ref=` the contract's URL and `cause=`
the proposal's id. Still open: write nothing about it, so it comes back next run.
Declined: `reject` it with the reason.
