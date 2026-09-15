---
name: pln
description: Create or update the plan for whatever is being discussed in the plans repository, then hold planning mode until /impl is run.
argument-hint: "[what to plan, or a plan letter/name from /list-plns to refine — omit to plan what we've been discussing]"
disable-model-invocation: true
---

# Plan

Capture what we have been discussing as a durable plan in the plans repository, then hold planning mode until the user runs `/impl`.

## Procedure

1. **Is there something to plan?** With no argument and a conversation that settled nothing, ask what to plan and stop there.
2. **Locate the plan.** Run `pwsh -File "${CLAUDE_PLUGIN_ROOT}/scripts/Get-PlanContext.ps1"` from the repository root, never from this skill's directory — always, not only when you suspect the session started below the repository root. An argument with no whitespace is passed as `-Plan` first — `selected` means refine that plan — while one containing whitespace is always what to plan, and is never matched. See _Where the plan lives_ below for what it returns and how to act on each case. Read the plan in full if there is one.
3. **Branch on `Status:`** — see _Write or merge_ below.
4. **Harvest every `∫∫...∫∫` marker**, before folding in anything from the conversation.
5. **Scout**, but only for questions the conversation genuinely left open.
6. **Decide `Team:`, `Parallel:`, `Checkpoints:` and `Verify:`**, then write or merge. Set `Status: PLANNING` and take `Updated:` from `date +%F` — run it, never write the date from memory.
7. **Commit the plan** with `pwsh -File "${CLAUDE_PLUGIN_ROOT}/scripts/Save-Plan.ps1"`. Every write, without exception — see _Committing the plan_.
8. **Surface it** if this call created the plan, or if the user asked to see it — see _Surfacing the plan_.
9. **Report** — what changed in the plan, what is still open, and which execution choices you made and why. Your answer to a `∫∫...?∫∫` question belongs here in full.

The rest of this file is why, and what each step involves.

## Why this exists

The user wants a problem thought all the way through before any code moves. The failure mode this prevents is hearing "we should add X" and immediately editing files — which throws away the design conversation and forces the user to review a diff when they wanted to review an idea. Planning mode makes the plan the artifact under discussion.

Which means there has to be something to plan. Inventing a goal from thin air produces a plan the user then has to argue with, which is strictly worse than one question.

## Where the plan lives

Plans live in their own git repository, one directory per repository they are about:

```
<plans repo>/<repo name>/<YYYY-MM-DD>-<slug>.md
```

`Get-PlanContext.ps1` is the only thing that knows this layout — never derive a path yourself, and never guess at the plans repository's location. It prints one JSON object:

- **`PlanPath`** — the current plan, or `null`. **`PlanMatch`** says how it was decided:
  - `selected` — the argument named this plan, unambiguously; refine it, and the "Write or merge" rules apply by its `Status:`.
  - `branch` — a plan's `Branch:` line is the checked-out branch. Exact; this is the normal case once `/impl` has made a branch.
  - `only-active` — no `Branch:` matched, and exactly one plan is `PLANNING` or `IMPLEMENTING`. The normal case while planning on the default branch.
  - `ambiguous` — several plans could be meant. **Do not pick one.** List the candidates with their titles and statuses, ask which, and stop.
  - `none` — this repository has no plan yet, so you are writing the first one.
  - `no-match` — the argument matched no plan; it is what to plan, exactly as today.
- **`NewPlanPath`** — where a new plan goes. Only present when you pass `-Title "<the plan's title>"`, so pass it once you know the title and use what comes back verbatim. It is today's date plus a slug of the title, suffixed if that name is taken.
- **`PlanDir`**, **`PlansRepo`**, **`RepoRoot`**, **`RepoName`**, **`Branch`** — the surrounding facts.
- **`Surface`** and **`Worktree`** — the user's hooks, or absent. See _Surfacing the plan_; `Worktree` belongs to `/impl`.

A new plan is a new file, always. Nothing is ever overwritten to make room for different work, so `Status: DONE` is not an obstacle and two pieces of work in one repository are two files rather than a conflict.

## Committing the plan

**Every write to the plan is followed by `Save-Plan.ps1`.** It commits everything in the plans repository under a standard message, says so when there was nothing to commit, and never touches the repository being planned for.

This is what the plans repository buys, so it only works if it is unconditional. The history of a plan is the record of how the thinking moved — which decision came before which, what was reversed and when — and that record only exists if each state got its own commit. An uncommitted edit is a state that never happened, and batching several turns into one commit collapses exactly the sequence worth keeping.

It also means the repository the user is working in stays clean. The plan is no longer a permanently modified file in `git status`, which is what made the old convention wear on them.

Pass `-Message` when the default reads badly for what you just did — creating a plan, say, is worth `-Message "plan: <title>"`. Otherwise take the default and move on; the message is not the record here, the sequence is.

## Surfacing the plan

The user may configure a hook that puts the plan in front of them — their editor, a pane, whatever they use. `Get-PlanContext.ps1` returns it as `Surface`:

- **`Surface.Skill`** — invoke that skill with the plan's absolute path as its argument.
- **`Surface.Command`** — run it, with `{path}` replaced by the plan's absolute path.
- **absent** — surface nothing, and say nothing about it. Not configured is a preference, not a problem to report.

Surface at two moments only: when this call **created** the plan, and when the user **asks** to see it ("show me the plan"). Not on every revision — during a long planning conversation the user is reading your replies, and re-opening the file on each turn interrupts rather than helps.

## You are the team lead, and the plan is yours

The plan is your deliverable. You read it and write it yourself, in this session, never through an agent — it is a page, it is the thing the user is discussing with you, and a lead who does not hold it cannot answer "change step 3". What you delegate is everything that would bury the conversation: reading the codebase, running commands, and — once `/impl` takes over — the implementation itself. Read `../pln/references/delegation.md` before spawning anything; it governs here without exception.

Planning is serial and convergent — you need each answer before you know the next question — so there is nothing here for a team to parallelize and no artifact to hand off. **No standing team while planning, no roles.** When a factual question arises that the conversation cannot answer, send a scout.

That is about _this_ half. The work itself is always staffed by a team — but that team belongs to `/impl`, and sizing it is the one thing you do about it.

## Investigate only when there is a real question

A plan built on guesses about the codebase is worthless, but most `/pln` calls arrive at the end of a conversation that already established the facts, and re-deriving them spends the user's time to learn what you both already know. So investigation is conditional, not a phase: scout a specific open question — does this function exist, what calls it, how does this subsystem hang together — and skip it entirely when there isn't one.

`delegation.md` covers naming, model routing and fan-out. What is specific to planning:

- **One question per `Explore` agent.** An agent asked four things answers all four shallowly.
- **Ask for a verdict and `path:line` references, capped at a handful of lines.** Never ask for the code itself — if you want to see a file, ask a better question.
- **Reuse a scout when the follow-ups will keep coming.** If a subsystem is unfamiliar enough that you will ask five questions about it, re-address the one that mapped it with `SendMessage` instead of spawning a second.

## Write or merge

Read any existing plan completely before touching it — merging means preserving what is still true. Then branch on what you found:

- **No plan for this repository** — write it from the template below, at `NewPlanPath`.
- **`Status: PLANNING`, same work** — revise in place. Rewrite only what actually moved, and when a decision is superseded say so rather than deleting it silently. Never regenerate the file from scratch: the wording already in there is deliberate, often the user's own.
- **`Status: PLANNING`, different work** — this is a second plan, not a merge. Say that the existing plan is about something else, and write the new work to a new `NewPlanPath` rather than folding two pieces of work into one incoherent plan. Both stay `PLANNING`, so say in your reply which one you just wrote and that `/impl` will ask which to run.
- **`Status: IMPLEMENTING`** — work is in flight. Revising is legitimate — it is what `/impl` does when a step meets reality — but set `Status:` back to `PLANNING`, **preserve the `Base:` and `Branch:` lines `/impl` wrote beside it** (that sha is its `git rebase --autosquash` target, that branch is where the work is, and rewriting the header block is exactly how they get lost), and tell the user plainly that `/impl` will resume against a changed plan.
- **`Status: DONE`** — that plan is spent and stays spent. New work gets a new file; an amendment to work that already landed is new work too. Ask which it is only when the distinction changes what you write, not as a formality — nothing is at risk of being overwritten.

## Human input in the file: `∫∫...∫∫`

The user can write straight into the plan, wrapping anything they want handled in `∫∫` on both sides — `∫∫why not reuse the existing parser here?∫∫`, `∫∫split this into two steps∫∫`. It is the same conversation moved into the margin, usually because pointing at the exact line is easier than describing where they mean.

So read for those first, before folding in anything from the conversation. They are the most specific thing the user has said, and where they sit in the file is part of the message.

Treat each one as a prompt — not a special kind of input with its own protocol, just the message the user would have typed in the chat, written where they were looking. Respond as you would to any prompt: do what is asked, push back when you think it is wrong, ask when it is unclear, and answer a question **in your reply** rather than quietly editing the plan to reflect a conclusion the user never read.

What the file adds is bookkeeping. A marker is input, not plan content, so once you have dealt with it, it comes out. One still sitting there after you have written means it was not handled — never carry one forward silently, and never leave one for `/impl`, which has no conversation in which to ask and refuses to start while one stands.

A question that turns out to be genuinely unsettled goes to `## Open questions`, in your own words. That section blocks `/impl` too, so say in your reply that the plan is not runnable until it is settled rather than leaving the user to find out at the gate.

## The plan must stand on its own, and it must stay a page

Write for a reader who was not here. `/impl` is meant to run in a fresh session — and now usually in a fresh worktree — so by the time the plan is executed everything said in this conversation is gone: the constraint mentioned in passing, the approach rejected, the file a scout found. The test is concrete: read each step as though you had just opened the repository and knew nothing else. Does it say what to change, where, and what "done" looks like? "Apply the same treatment to the other call sites" fails — which sites, and what treatment. Naming them costs a line and saves a round trip through the user.

That pulls against length, and the resolution is that standing on its own means complete in its **conclusions**, not exhaustive in its reasoning: every constraint and decision the work depends on is written down, the argument that produced it is not, and a `path:line` pointer stands in for a paragraph of context. It matters because you rewrite this file on every turn of the conversation.

- `## Context` holds conclusions and `path:line` pointers. Never pasted code, never a scout's report verbatim.
- A settled decision is one line plus its reason.
- When a section stops earning its space, cut it.

A plan is still scaffolding with a known end — a working document, not documentation someone reads next year. What changed is where it ends: it is not deleted when the work lands, it is left `DONE` in the plans repository, where its history says how the thinking got there. That is a reason to keep it a page, not a reason to write it for posterity.

## Template

```markdown
# Plan: <short title>

Status: PLANNING
Updated: <YYYY-MM-DD, from `date +%F`>
Repo: <absolute path, from Get-PlanContext's RepoRoot>

## Goal

What we are trying to achieve, and what "done" means.

## Context

What already exists that matters here — files, constraints, prior decisions.
Conclusions and `path:line` pointers only.

## Decisions

Choices already settled, each with the reason. This is what stops the plan
being re-litigated later.

## Steps

The work, as a numbered list, in order. `/impl` addresses steps by their
number — `Parallel:`, a checkpoint rule, and an interrupted run's resume
point all depend on it. Each step names the files it touches, which is
what makes `Parallel:` decidable.

## How to execute plan

Team: <one member per subsystem, plus a verifier and a reviewer>
Parallel: <step groups that may run at once, or `none`>
Checkpoints: <when to stop for the user, counted in groups>
Verify: <command and observable outcome, or `none`>

## Open questions

What is still undecided, and who or what resolves it. `/impl` refuses while
anything stands here, so an entry is a blocker, not a note.
```

## The header block

`Status:` and `Updated:` are yours on every write. `Repo:` is yours once, when you create the plan — the plan no longer sits inside the repository it is about, so the file has to say which one that is; take it from `RepoRoot`.

Two more lines appear later and are **not yours to write, only to preserve**: `Branch:`, the branch or worktree the work lands on, written by `/oimpl` or by `/impl` when it finds a plan without one; and `Base:`, the sha `/impl`'s fixup roll-up rebases against. Never write either yourself — you are planning on the default branch and there is no branch yet — and never drop them when revising a plan that is already in flight.

## The `## How to execute plan` section

This section is the contract with `/impl`, which refuses to start without it. It says how to move through the plan, never what the work is — that is `## Steps`. Read `../pln/references/execution.md`: it defines all four lines and the rules they bind `/impl` to. Four are required, and the gate validates all four:

- **`Team:`** — a list of member names. The work is always staffed by a team, so this is not a choice about _whether_, only about how large. One implementer per subsystem the steps touch, plus a verifier and a reviewer, capped by `delegation.md`'s fan-out limit. Floor of three, and the three roles never collapse into fewer — that independence is the only unbiased signal the run has.
- **`Parallel:`** — step groups that may run at once, or `none`. Yours to declare; see below.
- **`Checkpoints:`** — when to stop for the user. `after each step`, `at end`, or a specific rule ("after step 3, then at end"). A `Parallel:` group is atomic, so "each step" means each group.
- **`Verify:`** — a command **and** the observable outcome that makes it a pass, or the literal `none`. `/impl` hangs its commit rhythm and its plan-is-spent test on this line, and hands it to a member with nothing else to go on: a command with no outcome leaves that member inventing a standard, an outcome with no command leaves it nothing to run. "Run the Pester suite; the step is done when it passes" converts straight into a delegated check; "make sure it's solid" does not. Write `none` when the work genuinely has nothing runnable to check — that makes the absence a decision the user can see and correct, where a missing line is just an oversight.

These are decisions, not fields to fill; satisfying the gate is never itself a reason for what you wrote. Read all four off the work where you can — `Team:` by partitioning the steps by subsystem, `Parallel:` from which steps touch disjoint files, `Checkpoints:` from how reversible a group is, `Verify:` from whatever this repository already runs to prove a change — and ask the human when you genuinely cannot tell: whether the work is checkable at all, or whether concurrency is worth the coarser checkpoints it forces. Either way, say in your reply what you chose and why, or what answer you got.

### `Parallel:` is yours, and `/impl` can only narrow it

Parallelisable means two steps touch disjoint files — a fact about the code. You scouted it, your steps already name the files they touch, and you have a human to ask. `/impl` has none of that: it may not read source, so its only evidence is what a member reports after it has already run, which is too late to schedule on. So you declare the groups and `/impl` is bound in one direction: it may **serialise** a group you declared parallel when a member reports a collision, and it may **never** parallelise steps you left sequential.

Err toward too much concurrency and nothing errors — one member's edit overwrites another's, or a commit captures a half-written tree, surfacing later as a broken commit nobody meant to make. That is why the call belongs in the file where the user can argue with it, and why `none` is a good answer whenever the steps genuinely share files.

Three `/impl` defaults need no line in the plan: one commit per step after that step's verification, review at natural seams during the work, and stop-and-report when a step fails. Write a `Commits:`, `Review:` or `On failure:` line **only** to override one ("retry once, then stop"), with the reason — an override without a reason reads later as an accident, and a restated default is noise. Two things go the other way: `/impl` reaches for neither `fable` nor `isolation: "worktree"` on a silent plan, so name either on the step that needs it — and `fable` only with the user's agreement.

## Planning mode

Once `/pln` has run, the session is in planning mode, recorded in the file as `Status: PLANNING`. While it holds:

- **Every user message is about the plan** — a clarification, a correction, or a question. Answer questions directly; fold clarifications into the plan.
- **Do not change the world.** The plan file and its commits in the plans repository are the only writes you make. No code edits, no new or modified files in the repository being planned for, no commands that mutate its state, and no branch or worktree — that is `/impl`'s first act, not yours. This binds your agents too: `Explore` is read-only by construction, and any other agent you spawn while planning must be told explicitly that it may not write. Delegating autonomy is autonomy over _method_, never over _scope_.
- **A clarification often sounds like an order.** "Just add the flag to the parser" is the user telling you what the plan should say, not asking you to edit the parser. Write it down.
- **If the user plainly wants work to start**, say the plan looks ready and point at `/oimpl` rather than starting. It is the normal way out: it validates the plan, makes the worktree, writes it into the plan and opens a session there for `/impl` to run in — so the work gets a fresh reader and its own branch without this conversation having to end first. (`/impl` run directly still works, and makes the branch itself; `/oimpl` is the path that does not require the user to set anything up.) One keystroke from them is cheaper than undoing edits they did not ask for.
- **Trust the file over your memory.** Context drifts across a long session and this instruction fades with it. The plan survives a restart; your context and any named scout do not. When unsure whether planning mode still holds, read the `Status:` line.

Only `/impl` leaves planning mode.

## Reporting back

Step 9, and it has a shape. In a couple of lines, in your own words:

- **what changed in the plan** — the user should not have to diff the file to learn what you did;
- **where it is**, on the call that created it: the plan's path, once. Not on every revision.
- **what is still open** — anything under `## Open questions`, said plainly as a blocker on `/impl`;
- **the execution choices** — the `Team:`, `Parallel:`, `Checkpoints:` and `Verify:` you settled on, with the reason for the team's size and for any concurrency you declared;
- **your answer to any `∫∫...?∫∫` question, in full.** It does not get compressed into "handled your question" — it is the thing they were waiting for.

Relaying rules from `delegation.md` apply: a scout's report never reaches the user verbatim, and whatever mattered in it, you say.
