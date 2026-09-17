# Splitting the work, for `/pln` and `/ipln`

Shared by both skills. `/pln` applies it and writes one plan per part; `/ipln` applies it
and files one issue per part. It lives beside `delegation.md` and `execution.md` because
the test is the same either way — only the deliverable differs — and a criterion that
means one thing in a plan and another in an issue is worse than no criterion at all.

## Why any of this exists

A conversation ranges wider than a unit of work. By the time someone says "write that
down" the discussion has usually picked up two or three things that arrived together but
do not have to ship together, and the default — one file, one issue — quietly welds them
into a single lump. That lump is what goes wrong later: it cannot be finished, only
abandoned halfway; it cannot be reviewed, because the reviewer has to hold two unrelated
changes at once; and its `Verify:` line has to pass for all of it before any of it counts.

Splitting is cheap and merging is not. A new plan is a new file and a new issue is a new
number, so two parts cost nothing structurally, while one lump costs on every turn it is
read.

So this is a test you run once, near the end — after scouting, before writing anything —
not a preference for small deliverables.

It fires on a merge as readily as on a new plan or a fresh set of issues. Splitting is
what keeps scope creep out of a single merge request, and a deliverable that grows by
merge is exactly how that creep arrives: nobody ever decided it should cover two things,
it just accreted one turn at a time. So run the test on the merged whole, not on the part
you are adding.

## When to split

Split when **either** of these is true.

- **The steps touch disjoint subsystems and each part is independently shippable and
  verifiable.** Two parts that share no files, where each one can land on its own and be
  proved correct on its own, are two pieces of work that happen to have been discussed
  together. Size does not enter into it — however small a part is, if it stands alone it
  is its own deliverable.
- **A single piece would run past roughly six steps, or past one subsystem.** Six is a
  smell, not a rule: it is the length at which the steps stop being a plan someone reads
  and start being a backlog someone loses their place in. A piece that spans two
  subsystems is already two jobs wearing one title.

## When not to split

**Tightly coupled work stays one issue or one plan, however large it gets.** Coupled means
the parts cannot be verified apart: part two's tests do not pass until part one has landed,
or the intermediate state is broken, or the change is one rename spread over forty files.
Cutting there does not produce two deliverables, it produces one deliverable and a
fragment, plus a dependency the user now has to track by hand.

When a long piece of work is genuinely coupled, say so in your proposal rather than
staying silent — that it is long and cannot be cut is itself a fact worth the user
hearing, and it stops them asking the same question a turn later.

## How to propose it

The split goes in **your reply, before you write anything**. Not into the file, not after
the issues exist.

Say it in four parts, and keep it short enough to answer with one word:

1. **That you are proposing a split, and which test fired** — disjoint and independently
   shippable, or past the length that reads as one piece.
2. **The parts, one line each.** A title and what it covers. One line is the point: if a
   part needs a paragraph to describe, you have not finished dividing it.
3. **What couples or decouples them.** Name the actual thing — "they share no files",
   "the second one needs the new column the first one adds, so it comes after". This is
   the sentence the user judges the split by, and leaving it out turns the proposal into
   an opinion they cannot check.
4. **The order**, when one part must precede another. A dependency between parts is fine;
   an unsaid dependency is not.

## The user decides

You propose; they choose. Ask, then stop and wait for the answer — do not write the parts
in the same turn on the assumption that the split is obviously right, and do not write one
combined deliverable "for now" intending to split it later.

Take the answer literally. They may accept the split, reject it, accept it with different
boundaries, or take one part and drop the rest — all four are ordinary answers. If they
redraw the lines, write what they drew rather than what you proposed. If they say keep it
as one, keep it as one and do not re-propose on the next turn; the question has been
answered.
