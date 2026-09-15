---
name: oimpl
description: Open the implementation session for a finished plan — validate it, create the branch or worktree the work will land on, attach it to the plan, and open a new interactive session there for /impl to run in. Use when the user types /oimpl.
argument-hint: "[plan to open — omit to use this repository's active plan]"
disable-model-invocation: true
---

# Open implementation

Planning is done. Give the work a worktree, write it into the plan, and open a session there. **This skill does not run the plan** — `/impl` does, in the session this opens.

## Why this exists

`/impl` wants a fresh session: a plan's self-sufficiency is only proven by a reader who was not part of the planning conversation, and a session that has spent its window on design has little left for build output. It also wants a branch of its own, so the planning conversation can stay where it is.

Both of those are one move, and it is a move the user should not have to perform by hand. `/oimpl` is that move: the last thing you do in the planning session, after which the planning conversation is free to end.

It is deliberately not `/impl` with a flag. `/impl` may still create the branch itself when it finds a plan without one — running it directly in a worktree you made yourself has to keep working. `/oimpl` is the path for the normal case, and the two agree because both write the same `Branch:` line.

## Procedure

1. **Find the plan.** With an argument, pass it as `-Plan` to `pwsh -File "${CLAUDE_PLUGIN_ROOT}/scripts/Get-PlanContext.ps1"` from the repository root, never from this skill's directory; with none, run it bare. `selected` means the argument named the plan unambiguously — continue with it. `ambiguous` means several plans could be meant — list `Matches`' titles and statuses when an argument was passed, `Candidates`' otherwise, ask which, and stop. `no-match` means the argument matched no plan — say so, and stop. `none` means there is nothing to open; send the user to `/pln`.
2. **Pre-flight the plan** — see below. On any failure, **create nothing** and stop.
3. **Get the worktree**, either from the plan's existing `Branch:` line or from the worktree hook — see _Making the worktree_.
4. **Attach it to the plan**: write `Branch:` into the header block and commit with `pwsh -File "${CLAUDE_PLUGIN_ROOT}/scripts/Save-Plan.ps1" -Message "plan: branch for <title>"`. Nothing else in the plan changes — `Status:` stays `PLANNING` and `Base:` stays unwritten, because the run has not started.
5. **Open the session** — see _Opening the session_.
6. **Report** the branch, the absolute worktree path, and that `/impl` is what runs there. Two lines.

## Pre-flight

Creating a worktree for a plan `/impl` will refuse is pure waste, and the user finds out one session later. So run `/impl`'s gate here, before anything is created. It is defined in `../pln/references/execution.md` and carried in full by the `impl` skill; what this skill checks is the same list:

- a recognised `Status:`;
- a `## How to execute plan` section carrying all four of `Team:`, `Parallel:`, `Checkpoints:` and `Verify:`, each satisfying its rule;
- no unconsumed `∫∫...∫∫` markers;
- nothing standing under `## Open questions`.

On failure, say which check failed and what is missing — quoting each leftover marker and each open question, since they are a line apiece — and send the user to `/pln`. Do not draft the missing section and do not create the worktree anyway on the grounds that the plan is nearly there.

`Status:` decides more than pass or fail:

- **`PLANNING`** — the normal case. Continue.
- **`IMPLEMENTING`** — a run was interrupted. Do not create a second worktree: the plan's `Branch:` already names where the work is. Open a session there and say plainly that `/impl` will resume rather than start, and what the plan's progress notes say landed.
- **`DONE`** — the plan is spent. Refuse. Point at `/pln` for the next piece of work; nothing needs opening.

## Making the worktree

**If the plan already has a `Branch:` line**, the work already has a home. Do not create another. Resolve where it is with `git worktree list --porcelain` from the repository root, matching `branch refs/heads/<that branch>`; when nothing matches, the branch is checked out in place and the path is the repository root itself.

**Otherwise invoke the user's worktree hook**, returned by `Get-PlanContext.ps1` as `Worktree`. Derive a short kebab-case slug from the plan's title — lowercased and hyphenated, no deliberation — and pass it along with the repository root:

- **`Worktree.Skill`** — invoke that skill with the slug and the repository root. It decides between a branch and a worktree from how the repository is laid out, and it owns any prefix the user's naming convention wants. Do not second-guess either, and do not run `git worktree add` or `git switch -c` yourself.
- **`Worktree.Command`** — run it, with `{repo}` replaced by the repository root, `{name}` by the slug and `{plan}` by the plan's absolute path. It should print the absolute path of the new worktree on stdout; take the last non-empty line.
- **absent** — no hook, so nothing is created and there is no new directory. Say so, and that the work will land on the checked-out branch in the current tree. Continue to the session step with the repository root as the path; the user asked to open a session, and not having a worktree hook does not change that.

**You need two things back: the branch name and the absolute path.** They are not the same and both matter — the branch goes in the plan, the path goes to the session hook. A hook that made a branch in place gives you the repository root as the path. If you cannot determine the path, say so and stop before writing `Branch:`; a plan pointing at a branch nobody can find is worse than a plan with no branch.

## Opening the session

`Get-PlanContext.ps1` returns the user's hook as `Session`. It exists for exactly this: starting an interactive session in a directory.

- **`Session.Command`** — run it, with `{path}` replaced by the **absolute** worktree path, and `{repo}`, `{branch}` and `{plan}` available too. This is normally a terminal or multiplexer command, so expect it to return immediately and do not wait on it or read its output as a result.
- **`Session.Skill`** — invoke that skill with the absolute worktree path.
- **absent** — you cannot open anything, and this is the one hook whose absence is worth reporting. The worktree exists and the plan records it, so the work is set up; say that, print the absolute path, and tell the user to open a session there and run `/impl`. Do not fall back to opening a shell yourself.

The path must be absolute. A hook handed a relative path starts a session in the wrong place, and the failure looks like `/impl` finding the wrong repository.

## What this skill does not do

- **It does not run the plan.** No steps, no members, no commits in the repository being worked on. `/impl` does all of it, in the new session.
- **It does not set `Status: IMPLEMENTING`** and does not write `Base:`. Those mean a run has started, and if the session never opens, the plan must be exactly as it was.
- **It does not create a branch or worktree itself.** That is the hook's job, whatever the user configured it to be.
- **It does not end the planning session.** Whether to keep talking here is the user's call.
