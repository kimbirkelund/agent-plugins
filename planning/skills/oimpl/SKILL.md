---
name: oimpl
description:
  Open the implementation session for a finished plan — validate it, create the
  branch or worktree the work will land on, attach it to the plan, and open a
  new interactive session there for /impl to run in. Without an argument it
  opens the plan this session planned with /pln, or offers the plans /list-plns
  showed. Use when the user types /oimpl.
argument-hint:
  "[plan to open — omit to use the plan this session planned or listed]"
disable-model-invocation: true
---

# Open implementation

Planning is done. Give the work a worktree, write it into the plan, and open a
session there. **This skill does not run the plan** — `/impl` does, in the
session this opens.

## Why this exists

`/impl` wants a fresh session: a plan's self-sufficiency is only proven by a
reader who was not part of the planning conversation, and a session that has
spent its window on design has little left for build output. It also wants a
branch of its own, so the planning conversation can stay where it is.

Both of those are one move, and it is a move the user should not have to perform
by hand. `/oimpl` is that move: the last thing you do in the planning session,
after which the planning conversation is free to end.

It is deliberately not `/impl` with a flag. `/impl` may still create the branch
itself when it finds a plan without one — running it directly in a worktree you
made yourself has to keep working. `/oimpl` is the path for the normal case, and
the two agree because both write the same `Branch:` item.

## Procedure

1. **Find the plan** — see _Choosing the plan_. With an argument, pass it as
   `-Plan` to `pwsh -File "${CLAUDE_PLUGIN_ROOT}/scripts/Get-PlanContext.ps1"`
   from the session's working directory: `selected` means the argument named the
   plan unambiguously — continue with it. `ambiguous` means several plans could
   be meant — list `Matches`' titles and statuses, ask which, and stop.
   `no-match` means the argument matched no plan — say so, and stop. The
   argument only selects the plan: a request in it to use some other branch or
   worktree is not something this skill can honour, so say that and stop. With
   no argument, run the script bare to read `Candidates`, and choose by the
   session: the plans `/pln` planned here, else the ready plans `/list-plns`
   showed, else an error and stop. Say which plan you picked and why, then
   resolve it with `-Plan <file name>` and continue only on `selected`.
2. **Pre-flight the plan** — see below. On any failure, **create nothing** and
   stop.
3. **Get the worktree**, either from the plan's existing `Branch:` item or from
   the worktree hook — see _Making the worktree_.
4. **Attach it to the plan**: write `- Branch:` as a list item into the header
   list (bare `Branch:` when the plan is still in the bare form; the save
   converts it) and commit with:

   ```pwsh
   pwsh -File "${CLAUDE_PLUGIN_ROOT}/scripts/Save-Plan.ps1" -Message "plan: branch for <title>"
   ```

   Nothing else in the plan changes — `Status:` stays `PLANNING` and `Base:`
   stays unwritten, because the run has not started.

5. **Open the session** — see _Opening the session_.
6. **Report** the branch, the absolute worktree path, and that `/impl` is what
   runs there. Two lines.

## Choosing the plan

`/oimpl` runs in the session that planned, after `/pln` or `/list-plns`. So with
no argument the session is what says which plan, not the `PlanMatch` of the bare
call: ignore that value, whether it is `branch`, `only-active`, `ambiguous` or
`none`, and decide from `Candidates`. An argument is the user naming the plan,
so it needs no session evidence and is handled the same whether or not `/pln` or
`/list-plns` has run.

**Eligible** and **ready** mean the same thing: in `Candidates`, with
`Status: PLANNING` and no `Branch:`. A plan with a `Branch:` has already been
opened by `/oimpl` or started by `/impl`, and a `DONE` one is spent. That is
what makes a second bare `/oimpl` after a split open the next part. An argument
still reaches any plan.

A plan was **planned by `/pln` in this session** when a `/pln` call in this
conversation created or revised it. A plan the session only read does not count.
Nothing on disk records which session wrote a plan, so the conversation is the
only evidence.

With no argument, take the first case that holds:

1. **`/pln` has run in this session and planned eligible plans.**
   - Exactly one: use it.
   - Several, with a clear first plan: use that.
   - Otherwise: a selector over those plans.

   A session plan that is no longer eligible drops out; when none is left, fall
   through to the next case.

2. **`/list-plns` has run in this session.** A selector over the ready plans.
   When exactly one plan is ready, use it without a selector, which needs two
   options. When none is ready, say there is nothing ready to open, send the
   user to `/pln`, and stop; list nothing and ask nothing.
3. **Neither.** Report that `/oimpl` runs after `/pln` or `/list-plns` in the
   same session, or with a plan as its argument, and stop. List nothing and ask
   nothing.

**The clear first plan** is, in this order: the first eligible part in the order
`/pln` stated when it proposed a split or named a dependency between the plans;
failing any stated order, the one plan the most recent `/pln` call wrote, when
that call wrote exactly one. When neither holds there is no clear first plan. A
stated order is the user's own answer to "which first", and without one the most
recently planned is what "run it" means.

**The selector** is `AskUserQuestion`: one option per plan, labelled with its
title and described by its status and `Updated:`. When the plans outnumber the
tool's option limit, list them as text with their keys instead, ask which, and
stop.

**Say which plan you picked and why** — the only one planned here, the first of
a split, the one just planned, the user's choice — in one line before anything
is created. The pick is an inference, and that line lets the user stop a wrong
one.

**Then resolve it through the script**: run `Get-PlanContext.ps1` again with
`-Plan <file name>`, the chosen candidate's `Name`, and continue only on
`selected`. Anything else, report it and stop. The conversation decides which
plan; the script still turns it into a path, so the layout stays known to one
script.

## Pre-flight

Creating a worktree for a plan `/impl` will refuse is pure waste, and the user
finds out one session later. So run `/impl`'s gate here, before anything is
created. It is defined in `../pln/references/execution.md` and carried in full
by the `impl` skill; what this skill checks is the same list:

- a recognised `Status:`;
- a `## How to execute plan` section carrying all four of `Team:`, `Parallel:`,
  `Checkpoints:` and `Verify:`, each a list item (`- Team: ...`) or, in a plan
  not yet saved in the new form, a bare line, and each satisfying its rule;
- no unconsumed `∫∫...∫∫` markers;
- nothing standing under `## Open questions`.

On failure, say which check failed and what is missing — quoting each leftover
marker and each open question, since they are a line apiece — and send the user
to `/pln`. Do not draft the missing section and do not create the worktree
anyway on the grounds that the plan is nearly there.

`Status:` decides more than pass or fail:

- **`PLANNING`** — the normal case. Continue.
- **`IMPLEMENTING`** — a run was interrupted. Do not create a second worktree:
  the plan's `Branch:` already names where the work is. Open a session there and
  say plainly that `/impl` will resume rather than start, and what the plan's
  progress notes say landed.
- **`DONE`** — the plan is spent. Refuse. Point at `/pln` for the next piece of
  work; nothing needs opening.

## Making the worktree

Once the plan is chosen, whether the work lands on an existing branch or a new
one is decided by a script, never by your reading of the argument or the
conversation. The conversation may pick the plan (see _Choosing the plan_); it
never picks the branch. From the session's working directory, run:

```pwsh
pwsh -File "${CLAUDE_PLUGIN_ROOT}/scripts/Resolve-PlanBranch.ps1" -Plan <absolute plan path>
```

It prints one JSON object with `Mode`, `Branch` and `Path`.

**If the script throws**, report its message verbatim and stop. Remove nothing
the hook created — the user decides what to do with it. Never work around the
refusal by picking a branch yourself.

**`existing`** — the plan already has a `Branch:` item, so the work already has
a home. Use the script's `Branch` and `Path`. Create nothing.

**`new`** — invoke the user's worktree hook, returned by `Get-PlanContext.ps1`
as `Worktree`. Derive a short kebab-case slug from the plan's title — lowercased
and hyphenated, no deliberation — and pass it along with the repository root:

- **`Worktree.Skill`** — invoke that skill with the slug and the repository
  root. It decides between a branch and a worktree from how the repository is
  laid out, and it owns any prefix the user's naming convention wants. Do not
  second-guess either, and do not run `git worktree add` or `git switch -c`
  yourself.
- **`Worktree.Command`** — run it, with `{repo}` replaced by the repository
  root, `{name}` by the slug and `{plan}` by the plan's absolute path. It should
  print the absolute path of the new worktree on stdout; take the last non-empty
  line.
- **absent** — no hook, so nothing is created and there is no new directory. Say
  so, and that the work will land on the checked-out branch in the current tree.
  Continue to the session step with the repository root as the path; the user
  asked to open a session, and not having a worktree hook does not change that.

**You need two things back: the branch name and the absolute path.** They are
not the same and both matter — the branch goes in the plan, the path goes to the
session hook. A hook that made a branch in place gives you the repository root
as the path. If you cannot determine the path, say so and stop before writing
`Branch:`; a plan pointing at a branch nobody can find is worse than a plan with
no branch.

**Once the hook has returned a branch, validate it**: run the script again with
`-Branch <the branch the hook returned>`. With no hook, the branch is the
checked-out one (`git branch --show-current`) — validate that the same way.
Write `Branch:` only when it succeeds. If it throws, report its message verbatim
and stop.

## Opening the session

`Get-PlanContext.ps1` returns the user's hook as `Session`. It exists for
exactly this: starting an interactive session in a directory.

- **`Session.Command`** — run it, with `{path}` replaced by the **absolute**
  worktree path, and `{repo}`, `{branch}` and `{plan}` available too. This is
  normally a terminal or multiplexer command, so expect it to return immediately
  and do not wait on it or read its output as a result.
- **`Session.Skill`** — invoke that skill with the absolute worktree path.
- **absent** — you cannot open anything, and this is the one hook whose absence
  is worth reporting. The worktree exists and the plan records it, so the work
  is set up; say that, print the absolute path, and tell the user to open a
  session there and run `/impl`. Do not fall back to opening a shell yourself.

The path must be absolute. A hook handed a relative path starts a session in the
wrong place, and the failure looks like `/impl` finding the wrong repository.

## What this skill does not do

- **It does not run the plan.** No steps, no members, no commits in the
  repository being worked on. `/impl` does all of it, in the new session.
- **It does not set `Status: IMPLEMENTING`** and does not write `Base:`. Those
  mean a run has started, and if the session never opens, the plan must be
  exactly as it was.
- **It does not create a branch or worktree itself.** That is the hook's job,
  whatever the user configured it to be.
- **It does not end the planning session.** Whether to keep talking here is the
  user's call.
