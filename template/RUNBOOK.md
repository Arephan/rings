# __NAME__

This file is the contract. It is the entire prompt, minus a generated block
describing this particular run. Edit this; never edit the loop.

## What this ring is for

One sentence. If it takes a paragraph, this is two rings.

## What to read

List the exact sources — files, commands, APIs. A ring that has to guess where
its inputs are will spend its whole budget guessing.

## What to do

The work, in order. Be specific about what counts as done.

## What to write

Write your output to `out/last.md`. That file is the deliverable: if the run
ends without it, the run is recorded as a failure regardless of exit code.

## What not to do

- Do not repeat the previous deliverable. It is quoted back to you in the run
  context. Report what changed, or find something new.
- Do not report that you ran. Activity is not output.
- Do not spend money. If the task can only be finished by spending, stop and say
  so in the deliverable.

## When to stop

Name the condition that means this run is over — not "when done", something a
later reader can check. If nothing was found, say that in one line and stop; a
short honest deliverable beats a padded one.
