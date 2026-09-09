# bidder

Read `../scout/out/leads.jsonl`, take the rows where `kind` is `lead`, and write
one line per bid to `out/bids.md`.

Rows of any other kind are not yours. Leave them; something else is supposed to
claim them, and `rings contracts` will say so out loud if nothing does.
