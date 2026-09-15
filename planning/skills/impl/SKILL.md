---
name: impl
description: Validate the plan in the plans repository and execute it, staffing the work according to the execution mode the plan names. Creates the branch or worktree the work lands on. The only exit from planning mode. Use when the user types /impl.
disable-model-invocation: true
---

# Implement

Execute the plan, staffed the way the plan says to staff it. This is the only exit from planning mode.

## You are the team lead

The plan is yours — you read it, you write to it, and every update to it goes through you. It is a page, and it is the only durable record of what was intended, so holding it is the job rather than a cost.

Everything else goes to the team. Implementation is where a session usually dies: file reads, edits, build logs and test output pile up until there is no room left for the conversation the user actually wanted to have. None of that has to land here. **You write no code, read no source files, and run no builds, tests, or linters.** You hold the plan and the policy, staff each step, judge what comes back, and talk to the user.

Two references govern how:

- `../pln/references/delegation.md` (paths relative to this skill's own directory) — choosing a member, writing its prompt, capping what comes back. Read it before spawning anything.
- `../pln/references/execution.md` — the four lines `## How to execute plan` must carry, the `Status:` values, and the rules the team binds you to.

They live with `pln` rather than here because the two commands are halves of one workflow and always ship together; wherever `pln` is installed, they sit beside its `SKILL.md`.

```
you find the plan ─> provenance ─> gate ─> branch ─> per group: implement ─> per step: verify ─> you commit ─> roll up ─> you record
                          │          │        │                                                                             │
                          │          │        └─ worktree hook, Branch: and Base: recorded before the first step             │
                          │          ├─ at seams: review ─> obvious fixes as `fixup!`, judgement calls to the user           │
                          │          └─ fails: refuse, name what is missing, send them to /pln                              │
                          └─ you planned it? warn, recommend a fresh session, user decides    every plan write ─> Save-Plan ─┘
```

## First: find the plan

Plans live in their own git repository, not in the working tree, so there is nothing beside the code to open. Run `pwsh -File "${CLAUDE_PLUGIN_ROOT}/scripts/Get-PlanContext.ps1"` and act on `PlanMatch`:

- **`branch`** — a plan's `Branch:` line is the checked-out branch. This is the resume case: you are in the worktree a previous run made.
- **`only-active`** — one plan is `PLANNING` or `IMPLEMENTING` and no branch matched. The normal first run, on the default branch.
- **`ambiguous`** — several plans could be meant. **Do not pick one and do not start.** List the candidates with their titles, statuses and branches, ask which, and stop.
- **`none`** — there is no plan for this repository. Say so and send the user to `/pln`. Do not write one.

Never derive a plan path yourself, and never fall back to looking for a file in the working tree. The script is the only thing that knows the layout.

## Then: is this the session that planned it?

`/impl` is meant to run in a fresh session, so check before the gate. If you can recall the planning conversation rather than only reading the plan — if you know why a step is worded the way it is because you were there — say so and stop.

Two things go wrong otherwise. The obvious one is room: a session that has already spent its window on design has little left for file edits and build output. The subtler one matters more — a plan's self-sufficiency is only ever proven by a reader who was not there. If you still remember the discussion you will fill the plan's gaps from memory without noticing, and those gaps stay in the file for whoever picks it up next.

So warn, recommend a fresh session, and let the user decide. This is advice, not the gate; they may have a good reason to continue here. If they do, hold one line: treat the plan as the only source. Every time you catch yourself supplying something the plan does not say, that is a gap in the plan — write it in first, then act on it.

## Gate: validate before anything else

Nothing changes on disk — no edits, no state-changing commands, no branch, no members spawned — until the plan passes. Read the plan and check:

1. **You have a plan**, unambiguously, from the step above.
2. **It carries a recognised `Status:`** from the table in `execution.md`, and which one it is decides what happens next, before any other check:
   - `PLANNING` — the normal case. Continue through the rest of the gate.
   - `IMPLEMENTING` — a previous run was interrupted. Do not restart from step one. Read the progress notes, identify the first step not recorded as landed, and tell the user what already landed, what is next, and whether any `fixup!` is still waiting to be rolled up. Then resume from there at the pacing `Checkpoints:` sets, on the branch the plan's `Branch:` line names. If the notes are too thin to say where the work stopped, that is the failure to report — stop and say so rather than guessing which steps are already committed.
   - `DONE` — the plan is spent. Refuse and say so. The plan and its history stay where they are; point the user at `/pln` for the next piece of work, and at `/archive-sessions` if they want this run's conversations filed into the vault. Re-running a finished plan re-does landed work.
3. **It has a `## How to execute plan` section.**
4. **It states `Team:`** — a list of member names carrying at least one implementer, a verifier and a reviewer. The floor is not negotiable and you may not staff below it: the verifier and the reviewer are the run's only independent judgement, and an agent grading its own work grades generously. A `Team:` short a role fails the gate; it is not something you make up for by being careful.
5. **It states `Parallel:`** — step groups that may run at once, every number of which exists in `## Steps`, or the literal `none`. This line is `/pln`'s call, not yours, because disjointness is a fact about code and you may not read code. You may narrow it during the run; you may never widen it.
6. **It states `Checkpoints:`** — when to stop for the user, counted in `Parallel:` groups.
7. **It states `Verify:`** — a command **and** the observable outcome that makes it a pass, or the literal `none`. Every commit here is taken after verification passes, and the plan is only spent when verification passes, so without this line those rules have nothing to mean and you would be inventing a standard the user never agreed to. Half a line fails too: you hand this line to a member who has nothing else to go on, so a command with no outcome leaves it inventing a standard and an outcome with no command leaves it with nothing to run. `none` is a legitimate answer for work with nothing runnable to check; it makes the absence a decision instead of an omission, and it changes two things — a step is done when its member reports `DONE`, and "verification passing" drops out of the plan-is-spent test.
8. **No unconsumed `∫∫...∫∫` markers** anywhere in the file. Marked text is the user's own input for `/pln` to handle, so one still sitting there means they asked something that was never answered — and you have no conversation in which to ask it.
9. **Nothing standing under `## Open questions`.** An entry there is a decision the user has not made, and the plan is only spent once the section is empty — so starting with one open means the run cannot finish. You have no conversation in which to settle it either. An empty section, or no section at all, passes.

On any failure: **stop.** Say which check failed and what is missing; on a `Team:` short a role, name the missing role; on a `Parallel:` group naming a step that does not exist, quote it; on a leftover marker or an open question, quote each one, since they are a line apiece and the user needs to see what is still open. Then send the user to `/pln`.

Do not draft the missing section, do not have a member draft it, and do not start work on the grounds that the plan is mostly there. The gate is the whole point of the two-command split: a plan that does not say how to execute it means the user has not decided yet, and guessing at their intent spends their time worse than asking does. Because `/pln` always writes all four lines, a gate failure means the plan was hand-edited or written by something else — one `/pln` fixes it.

## Gate passed: make the branch

`/pln` plans on the default branch and never creates anything, so the work needs somewhere to land before the first step and before `Base:`. Usually it already has one: `/oimpl` is the normal way this session was opened, and it made the worktree and wrote `Branch:` before starting you. This section is what happens when it did not — you were run directly.

1. **If the plan already has a `Branch:` line**, the work already has a home — `/oimpl` made it, or a previous run did. Create nothing. Confirm the checked-out branch matches that line; if it does not, say so and stop rather than landing the work somewhere the plan does not claim, and let the user either switch to it or tell you what happened.
2. **Otherwise invoke the user's worktree hook**, which `Get-PlanContext.ps1` returns as `Worktree`:
   - **`Worktree.Skill`** — invoke that skill. Hand it a short kebab-case slug derived from the plan's title and the repository root; it decides between a branch and a worktree, and it owns any prefix the user's convention wants. Do not second-guess either.
   - **`Worktree.Command`** — run it, with `{repo}` replaced by the repository root, `{name}` by the slug, and `{plan}` by the plan's absolute path.
   - **absent** — no hook is configured, so there is nothing to create. Say once that the work will land on the checked-out branch, and carry on there.
3. **Record what came back** as `Branch:` in the plan's header block, and commit that write. Then continue in that branch or worktree — if the hook made a worktree, the work happens there, so every path you hand a member is inside it.

The slug is yours to derive and it is not a decision worth deliberating: the plan's title, lowercased and hyphenated. The hook names the branch; you name the work.

## Execute

Branch in place:

1. Set `Status: IMPLEMENTING` in the plan, and record `Base: <sha>` from `git rev-parse HEAD` beside it, before the first commit. Both are yours, two lines, no member needed. `Base:` is what makes the fixup roll-up possible later: every `--fixup` target has to fall inside the rebase range, and your context dies with the session while the file does not.
2. **Follow `Checkpoints:` literally.** It outranks your instincts about pacing — if it says stop after each step, stop even when the next step looks trivial. The user wrote that line to control something, and stepping over it removes the control.
3. Spawn the members `Team:` names and run the steps at the concurrency `Parallel:` allows.
4. When the work is finished, set `Status: DONE` and record anything that diverged from the plan.

## Every plan write is committed

**After every write to the plan, run `pwsh -File "${CLAUDE_PLUGIN_ROOT}/scripts/Save-Plan.ps1"`.** Status changes, the `Branch:` and `Base:` lines, each progress note, the divergences you record at the end — all of them.

Two consequences worth being explicit about.

The first is that the plan's history is the run's narrative in the plans repository, in parallel with the code's history in the working repository. A progress note that is written but not committed is a note that does not survive the session, which defeats the reason for writing it.

The second is that the plan can no longer contaminate a code commit. It lives in a different repository, so the old rule about keeping it out of `git add` is now structural rather than something you maintain. What replaces it is the reverse discipline: `Save-Plan.ps1` commits the plans repository and nothing else, and your code commits name paths in the working repository and nothing else. Never mix the two, and never reach for `git add -A` in the repository you are working in.

## Staffing the team

`Team:` names who exists; `execution.md` has the rules that roster binds you to, and they are not optional — they hold even when a plan asks otherwise. Spawn the members the plan names, one implementer per subsystem, and re-address a warm implementer by name when a later step lands in the code it already knows.

Two directions are closed to you. You may not staff **below** the plan's roles: the verifier never implements, the reviewer never reviews its own code, and neither job folds into an implementer or into the other, however small the plan looks. And you may not staff **beyond** the work in hand — a three-step plan does not need a role per step, and extra members are context you pay for without buying independence.

### Handing off a step

Route the model by how much judgment the step still needs — not by how much code it involves:

- The plan pins down exactly what to change and where: `haiku` for a truly mechanical edit, `sonnet` for ordinary implementation.
- The step names an outcome but leaves the shape open, cuts across several modules, or depends on something the plan admits is uncertain: `opus`.
- The plan calls out `fable` for this step: use it. Nothing else licenses it. If a step looks like it needs more than `opus` and the plan is silent, that is a deviation — stop and take it back to the plan rather than upgrading on your own.

Each prompt must stand alone. Give it the repository root **as it now is** — the worktree, if the hook made one — the step **quoted in full** from the plan, the constraints that bind in this repository, the condition that makes the step done, and the plan's absolute path so it can read the plan itself for surrounding detail. That path is no longer guessable from the repository, so a member that is not given it cannot find it. Tell it not to commit — committing is yours, for the reasons below — so it leaves its work in the tree and reports the paths. Then the output contract from `delegation.md`: a single fenced `json` block, its final message stated to be the return value.

Members get autonomy over how they solve the step. They do not get autonomy over what the step is; work the plan does not call for is out of scope even when it looks obviously worth doing. If a member reports that kind of finding, it goes in the plan — not into the diff, and not into a branch or worktree of its own. A separate fix is separate work the user opens deliberately, not something this run spawns on the side.

### Tracking what is running

Members dispatch asynchronously: the call returns before the work is done. So keep a ledger — which member has which step, what you are waiting for — and never let "dispatched" read as "done". While anything is outstanding, say what is pending rather than closing the turn as if the step landed. The ledger is not belt-and-braces: there is no shared task list available here, so it is the only record of what is running.

Keep the fan-out inside the limit `delegation.md` sets. Outside a `Parallel:` group there is one implementer outstanding, which is the easy case; inside one there are as many as the group has steps, and the ledger is what keeps their reports attributable.

Because `Team:` names its members, they are teammates rather than one-shot subagents, and two things follow. Each one reports **every time it goes idle**, so a member you send a second step to, or hand a failed verification back to, reports again — hold it to the output contract on that reply too. And a member can **message you mid-step**, unprompted, to ask something the step did not settle. Answer it; a member that asks is doing the right thing, and the alternative is a member that guesses at a decision the plan should have made.

If a member goes quiet, `SendMessage` pokes it and `TaskStop` ends it so you can re-dispatch the step. `ListAgents` is not the tool for that — it lists other sessions, not your members. Do not go looking in a member's task output file for the report either — `delegation.md` explains why that one move undoes everything else here.

### One tree, one build at a time

`delegation.md` has the rule and why a second worktree is not the answer to contention.
What it means here: dispatch at most one build, test run or commit at a time, and none
while an implementer is still mid-step. `git add` and `git commit` snapshot the tree as it
stands at that instant, so a commit taken alongside another member's work captures a
half-written file and leaves a broken commit nobody meant to make.

This holds **inside** a `Parallel:` group as much as outside one. The group's implementers
run concurrently; its verifications and its commits do not. Wait for the whole group, then
verify and commit its steps one at a time.

The worktree this run created is not an exception to any of that. It is one tree; the fact
that it is a new one only means the contention is with this run's own members.

### Narrowing `Parallel:`, never widening it

The plan owns concurrency, and your licence runs one way only.

**You may serialise.** When a member in a group reports it touched a file another step in
that group needs — or two members in a group come back having edited the same path — drop
that group and run its steps in order. Say so and note it in the plan; the plan's
declaration was wrong and the next session should not repeat it.

**You may never parallelise steps the plan left sequential**, and never merge two groups.
Doing so asserts that the steps touch disjoint files, and you may not read source, so you
cannot know. Evidence only ever arrives in one direction here: a collision announces
itself, while the absence of one never does. If two sequential steps look obviously
independent and the wall-clock matters, that is a deviation — take it back to the plan.

### Verifying

Whatever the plan says to verify goes to its own member — a build log is exactly the payload that must never land here. Use a cheap model; running a command and reading its result is mechanical. Ask for pass or fail, and on failure the shortest line that identifies the cause, quoted exactly, plus the failing test or target name. Not the log.

The verifier is a role on the plan's `Team:`, and it never implements — not the step it is checking, not any other. An agent grading its own work grades generously, and a verifier that starts fixing things has stopped verifying.

When verification fails, send the failure back to the member that wrote the code — one exchange, no cold re-read. That is what naming members is for.

### Committing

Commit as the plan progresses, unless the plan says otherwise. The default is one commit per step — per step, not per `Parallel:` group — taken after that step's verification passes, so that reading the history one commit at a time retells the plan's narrative — the same reason the steps were put in order in the first place. Work that is committed as one lump at the end throws that away and leaves the user a diff to reverse-engineer.

Committing is yours, not a member's, for three reasons that all point the same way: you are the only one who knows verification passed, you hold the plan and therefore the _why_ that belongs in the message, and you are the single-threaded entity that makes serialization true without coordination.

You already have what you need. The output contract gives you the member's changed paths one per line, so commit those paths explicitly — never `git add -A`, never `git commit -a`.

Write the subject from the step, in one line, in the imperative. No trailers, no self-attribution, no body unless the step involved a decision the diff cannot show. And do not push — landing the branch is the user's move, not part of executing a plan.

Fixes that come out of review attach to the commit that introduced the code rather than trailing behind it:

- `git commit --fixup=<sha> -- <paths>` for a code correction.
- `git commit --fixup=amend:<sha> -- <paths>` when the original commit's message also needs to change.

Roll them up as part of finishing the step that produced them — once its verification and its review findings are settled, and before you record progress or hand control back at a checkpoint: `GIT_SEQUENCE_EDITOR=true git rebase --autosquash <Base>` — non-interactive, since an interactive rebase cannot run here, and against the `Base:` recorded at the start rather than a range you reconstruct. A step with a `fixup!` still standing is a step that is not finished.

Per step rather than once at the end, because that is what keeps the per-step commit's promise: the history reads as the plan's narrative at every moment, a checkpoint shows the user finished commits instead of a stack of `fixup!` lines to mentally apply, and an interrupted run resumes from a tree with nothing pending. Rebasing the same handful of commits again each step costs nothing worth saving.

Rolling up rewrites history, so ask first whenever that history is not yours alone: `git rev-parse @{upstream}` succeeding means the branch is published, and some repos commit straight to a shared branch where the rewrite would land on other people's commits. A branch this run created off the default branch is normally yours alone, which is one thing the worktree step buys — but check rather than assume, since the hook may have checked out an existing branch. Ask once, at the first roll-up of the run, and carry the answer forward — re-asking every step turns one decision into noise. Describe what the roll-up would rewrite and let the user decide; the fixups are already correct commits, so a decline costs a messier history and nothing else. If they decline, stop rolling up for the rest of the run and record in the plan which commits the standing fixups belong to.

### Reviewing

Review is not verification. Verification asks whether the code works; review asks whether it is right — whether it fits the codebase, whether the tests mean anything, whether the shape will hold. Both are needed and neither substitutes for the other.

**Review happens during the work, not after it.** Not necessarily after every step, but at each seam where a coherent slice is finished — and never deferred to the user at the end. The reason is timing, not thoroughness: a review of the first slice can still change how the rest is built, while a review of everything can only produce patches on a shape that is already set.

Send the slice to the plan's reviewer, which by construction wrote none of it — a reviewer reading its own code grades generously, exactly as a verifier would. Keeping the one reviewer across the run is deliberate: it accumulates a picture of the whole change that a fresh reader rebuilds from nothing every time. Give it the plan's intent for that slice, the commits or paths in scope, and a capped output contract: one line per finding, most consequential first.

Then triage what comes back, and the split matters more than the review itself:

- **A finding inside the range of choices the implementer could reasonably have made on its own — just make it.** A better name, a missing guard, a test that should have existed, code that does not match the local idiom. Ask yourself whether a careful implementer might plausibly have decided this without checking in; if the answer is yes, deciding it now is not a question, it is the work. Send it back to the member that wrote the code and commit the fix as a `fixup!`.
- **An actual judgement call — surface it.** It revisits something the plan settled, trades off a constraint the user chose, changes scope, or picks between two defensible designs. Say it plainly, say what it costs either way, and let the user decide.
- **A contradiction with the plan** is neither: it goes down the path below, as a deviation.

The point of the split is that the user's attention is the scarce thing. A review that forwards forty findings has moved the work to them rather than doing it.

### Recording progress

Progress notes are plan writes, so they are yours, and each one is followed by `Save-Plan.ps1`. Write them at the rhythm `Checkpoints:` sets: a step's outcome as it lands, and never batch past a checkpoint the plan demands. The plan should be readable at any moment as a true statement of where the work stands.

Keep it continuable, and test that at every write: if this session ended right now, could a fresh `/impl` pick the work up from this file alone? That means the next step is identifiable, finished steps say what landed, and anything decided mid-flight is written down rather than remembered — including any `fixup!` still waiting to be rolled up and the commit it belongs to. With the roll-up done per step there should normally be none; if there is one, it is because the user declined the rewrite or the run broke mid-step, and either way the next session only learns it from this file. Your roster and your context die with the session; the file is all that survives it.

The `Branch:` line is part of that. A fresh `/impl` started in the worktree finds this plan by that line, so a plan whose branch is recorded is a plan that can be resumed without the user explaining where the work went.

## When the plan meets reality

Plans go stale on contact. If a step turns out impossible, or the design is wrong, or a step reveals work nobody accounted for: stop, say what you hit, and update the plan — then ask whether to continue. Improvising past a broken step and reporting success defeats the purpose of having written the plan down.

Judging whether a deviation contradicts what was agreed is your call, not a member's. You are holding both the plan and the conversation that produced it, which is exactly what that judgment needs.

Anything done differently from the plan belongs in the plan before you finish, with the reason. The plan is the record of what was intended; a gap between it and what shipped should be visible there, not only in this conversation.

## When the plan has served its purpose

A plan is scaffolding with a known end. It carries a decision from the planning conversation into the work, and once that work has landed and been verified it is only a description of the past.

So say when you get there. Once no `fixup!` is left standing — each step rolled up its own, so this is a check rather than a chore — and `Status: DONE` is set and committed, tell the user you believe the plan is spent and what makes you believe it: every step done, verification passing, the reviews you ran at the seams done and their findings either made or surfaced, nothing left under `## Open questions`. If one of those does not hold, the plan is not spent — say which one, and stop there.

All four are things you did, so `DONE` is your own judgement about the work and never a wait on what happens next. Whatever follows your report is the user's move, not a precondition — so do not leave `Status: IMPLEMENTING` standing in anticipation of it. That status means a run was interrupted, and a fresh `/impl` reading it will try to resume work that already landed.

Then leave the plan where it is. It is not scaffolding to clear away any more — the plans repository keeps it, `DONE`, with the history of how the thinking moved, and that history is the thing worth having. Do not delete it and do not move it. If the user wants this run's conversations filed alongside their notes, `/archive-sessions` does that; mention it once and let them decide.

## Reporting back

Relaying is governed by `delegation.md`: the user sees none of the member reports, and whatever mattered in one, you say. What this half adds is that failure keeps its name. A step that came back BLOCKED is reported as blocked, with what it hit; a failing verification is reported as failing, with the line that proves it. Never let a delegated failure reach the user as progress.

Two things are worth saying once, early: which plan you are running, by title and path, since the user may have several; and the branch or worktree the work is landing in, since they did not create it and it is where they will look for the diff.
