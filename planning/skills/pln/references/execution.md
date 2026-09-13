# Execution contract for `/impl`

Shared vocabulary for `/pln` and `/impl`. `/pln` decides these lines and writes them into
the plan; `/impl` reads them and staffs the work accordingly. They live here, next to
`delegation.md`, because both halves of the workflow need the same names and a name that
means two different things is worse than no name at all.

## The work is always staffed by a team

`/impl` never implements, verifies or reviews anything itself, and no single member ever
does two of those three. That is not a staffing preference a plan can opt out of, so the
plan does not choose _whether_ to field a team — it says how large a one, and how much of
it may be in flight at once.

There is no `solo` and no free prose. A plan that had to invent its own description of how
to execute made the gate fuzzy and made every plan author design a staffing strategy from
scratch; a line that is a list of names is checkable, and a plan either satisfies it or
does not.

Four lines, all four required, all four validated:

```
Team: parser, storage, verifier, reviewer
Parallel: 2+3, then 4, then 5+6
Checkpoints: after each step
Verify: ./run-tests.sh; the step is done when it exits 0
```

## `Team:` — how large

A comma-separated list of member names. Size is **read off the plan, not invented**:

- **One implementer per subsystem the steps touch.** This is what warm context buys: a
  member that already mapped the parser takes a second parser step in one exchange, where
  a fresh member re-reads everything. Partition the steps by subsystem, then name one
  member per part.
- **Plus a verifier and a reviewer. Always, and never fewer.** These two are the only
  independent signal in the whole run.
- **Capped by the fan-out limit in `delegation.md`** — three or four outstanding. If the
  partition wants more implementers than that, the plan has too many steps in flight, not
  too small a team.

So the floor is three members and the ceiling is the fan-out cap. A single-subsystem plan
gets one implementer, one verifier, one reviewer. Scale by adding implementers; never by
dropping a role.

**Why the three roles cannot collapse into fewer.** An agent grading its own work grades
generously — that is the entire reason the split exists, and it is a property of the
grader, not something care makes up for. A verifier that starts fixing what it found has
stopped verifying. A reviewer reading code it wrote is reading its own intentions.

**Why the verifier is not the reviewer.** They answer different questions — does it work
versus is it right — and neither substitutes for the other. They also have different
shapes: verification is mechanical and routes cheap, gets re-dispatched per step and holds
no state; review needs judgment, routes expensive, and is worth keeping alive because it
accumulates a picture of the whole change that a fresh reader rebuilds every time. One
member doing both would be routed wrong for one of them.

## `Parallel:` — how much at once

Step groups that may run concurrently, in order, or the literal `none`:

```
Parallel: 2+3, then 4, then 5+6
Parallel: none
```

Every number must be a step in `## Steps` — which is why steps are numbered.

**`/pln` declares this. `/impl` may narrow it and may never widen it.**

Parallelisable means _these steps touch disjoint files_, which is a fact about the code.
`/impl` is forbidden from reading source, so its only evidence is what members report
after they have already run — too late to schedule on. `/pln` is the half that scouted the
code, already names files per step, and has a human to ask. The information lives there,
so the declaration does too.

The permitted direction of change matters more than the declaration:

- **`/impl` may serialise a group** the plan declared parallel, when a member reports it
  touched a file another step in that group needs. Evidence arrived; the cost is
  wall-clock.
- **`/impl` may never parallelise steps the plan left sequential.** That asserts
  disjointness it cannot check without reading code.

Evidence only ever arrives in one direction: "these collided" shows up, "these would not
have collided" never does. So the safe move is always the narrowing one.

Two more reasons this is plan-time work. A wrong call here is **silent** rather than an
error — two members editing one file means one overwrites the other, or a commit captures
a half-written tree, and the symptom is a broken commit found much later. And concurrency
trades observability for wall-clock: several members in flight means coarser checkpoints
and harder failure attribution. Both belong in front of the user before the run, not
inside a decision `/impl` makes alone.

## `Checkpoints:` — when to stop for the user

- `after each step` — report and wait for a go-ahead before continuing. Right when the
  user wants to steer, or when a wrong step is expensive to unwind.
- `at end` — run the plan through, report once. Right for mechanical work the user has
  already fully specified.
- Anything specific: `after step 3, then at end`. `/impl` follows it literally.

**A `Parallel:` group is atomic for checkpointing.** There is no stopping after step 2
while step 3 is still in flight beside it, so with a `Parallel:` line "each step" means
each group: dispatch the group, wait for all of it, verify, commit, then stop. A plan that
genuinely wants a stop between two particular steps says so by not putting them in the
same group.

The lead never widens a checkpoint because the next step looks trivial. The user wrote the
pacing to control something; stepping over it removes the control.

## Where the plan lives, and what its header carries

Plans are not in the working tree. They live in a git repository of their own, one
directory per repository they are about, one file per plan:

```
<plans repo>/<repo name>/<YYYY-MM-DD>-<slug>.md
```

`scripts/Get-PlanContext.ps1` is the only thing that knows that layout, resolves which
plan is current, and reads the user's hooks. `scripts/Save-Plan.ps1` commits the plans
repository. Both commands call them rather than deriving paths, so that the layout has one
definition and changing it does not mean editing two skills.

Three consequences the two halves have to agree on:

- **A new plan is a new file.** Nothing is overwritten, so a `DONE` plan is not an
  obstacle and two pieces of work in one repository are two files.
- **Every write is committed.** The history of a plan is the record of how the thinking
  moved, and that record only exists if each state got a commit.
- **The plan is found, not located.** Neither command may fall back to looking for a file
  beside the code, and a member handed a step must also be handed the plan's absolute
  path.

The header block is small and each line has one owner:

| Line       | Written by                        | Meaning                                                          |
| ---------- | --------------------------------- | ---------------------------------------------------------------- |
| `Status:`  | both, per the table below         | Where the plan is in its life.                                   |
| `Updated:` | `/pln`, on every write            | Date of the last planning change, from `date +%F`.               |
| `Repo:`    | `/pln`, once at creation          | The repository the plan is about. The file no longer sits in it. |
| `Branch:`  | `/oimpl`, or `/impl` run directly | Where the work lands. Also how a fresh `/impl` finds this plan.  |
| `Base:`    | `/impl`, before the first commit  | The `git rebase --autosquash` target for rolled-up fixups.       |

`/pln` never writes `Branch:` or `Base:` and never drops them when revising a plan that is
already in flight. `/impl` and `/oimpl` never write `Repo:`, and `/oimpl` writes neither
`Base:` nor `Status:` — when it is done the run still has not started.

## `Status:` — where the plan is in its life

Not part of the staffing contract, but the other thing both commands have to agree on. One
of three values, written by whichever command owns that phase, and the only durable record
of whether work has started — so both commands read it before acting on the plan.

| Value          | Written by                    | What the other command does with it                                                                                                                            |
| -------------- | ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PLANNING`     | `/pln`, on every write        | `/impl` proceeds normally.                                                                                                                                     |
| `IMPLEMENTING` | `/impl`, once the gate passes | `/impl` treats it as an interrupted run and resumes rather than restarting. `/pln` may revise the plan mid-flight, but sets it back to `PLANNING` and says so. |
| `DONE`         | `/impl`, when the work lands  | `/impl` refuses — the plan is spent, and stays in the plans repository. `/pln` leaves it alone and writes new work to a new plan.                              |

Anything else, or no `Status:` line at all, fails the gate.

## How `/impl` validates this

The gate refuses to start unless the plan carries a recognised `Status:`, and unless
`## How to execute plan` exists and satisfies all four lines: `Team:` lists at least one
implementer plus a verifier and a reviewer; `Parallel:` gives step groups whose numbers all
exist in `## Steps`, or `none`; `Checkpoints:` says when to stop; `Verify:` gives a command
**and** its observable outcome, or the literal `none`. A `Team:` missing a role fails and
the refusal says which — a plan must never silently become "whatever the model felt like".

Two things also refuse on their own: an unconsumed `∫∫...∫∫` marker, which is the user's
own input waiting to be handled, and anything standing under `## Open questions`, which is
a decision the user has not made. `/impl` has no conversation in which to settle either.

`Status:` is the one check that is not simply pass-or-fail: `PLANNING` continues into the
rest of the gate, `IMPLEMENTING` resumes an interrupted run instead of restarting it, and
`DONE` refuses because the plan is spent. `/impl` carries the detail.

Because `/pln` always writes all four lines, a gate failure means the plan was hand-edited
or written by something else. A leftover marker means something different: the user wrote
input into the plan and has not run `/pln` since. Either way, failing loudly is correct and
costs one `/pln` to fix.

## Rules that bind the team

`/impl` enforces these regardless of what a plan says.

- **The verifier never implements, and the reviewer never reviews its own code.** An agent
  grading its own work grades generously. When teammate continuity and independence pull
  against each other, independence wins — staff a fresh grader rather than reusing an
  author.
- **The reviewer does not apply its own findings.** Those go back to the member that wrote
  the code. `/impl` owns the review cadence and the triage rule.
- **Reuse follows the subsystem, not the roster.** Send a step back to the member that
  already knows that code. When a step crosses into a different area, staff someone fresh
  instead of stretching a warm member — accumulated context is the benefit, accumulated
  assumptions are the price, and a stretched teammate has stopped being a cold reader
  without anyone noticing. This is also why `Team:` is partitioned by subsystem rather
  than sized by step count.
- **A failure goes back to its author.** The member that wrote the code fixes it; one
  exchange, no cold re-read. That is what naming members is for.
- **The roster is session state and nothing more.** Members die with the session. The plan
  is the only durable record, so who did what must be written there if it matters, never
  merely remembered.
- **Concurrency only inside a `Parallel:` group, in the one tree.** `delegation.md` has the
  rule and why a second working tree is not the answer to contention.
- **Builds, test runs, and commits are serialized by the lead.** The working tree and the
  index are shared mutable state, so none of these ever runs concurrently — not with each
  other, and not with an implementer mid-step. This holds inside a `Parallel:` group too:
  the members of a group implement concurrently, then verification and the commits happen
  one at a time. `/impl` carries the reasoning.
