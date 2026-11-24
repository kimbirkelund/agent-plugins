---
name: fnsh
description:
  Stay with a finished plan's GitHub PR or GitLab MR until it is merged. Watches
  the request continuously, fixes pipeline failures and required review comments
  caused by the branch with pushed `fixup!` commits, reports everything else,
  rebases on a conflict with the default branch, and after the merge pulls the
  target, removes the plan's worktree, deletes the local branch and invokes the
  finish hook. Use when the user types /fnsh.
argument-hint:
  "[plan key, name or title fragment, or omit for this branch's plan]"
disable-model-invocation: true
---

# Finish

Shepherd the request — the branch's GitHub pull request or GitLab merge request
— of a plan that `/impl` has finished, until it is merged. One script watches
the request and streams events; you act on each one as it arrives.

```
find the plan ─> refuse unless DONE and on its Branch: ─> Monitor(Watch-PlanRequest) ─> per event, in order:
                                                                                         ├─ pipeline-failed ─> fixer classifies ─> caused by branch: fix, verify, fixup!, push
                                                                                         ├─ comments ───────> fixer judges each ─> required: fix, verify, fixup!, push
                                                                                         ├─ conflict ───────> default target: fetch, rebase, fixer resolves, verify, user force-pushes
                                                                                         ├─ merged ─────────> Remove-PlanWorktree ─> finish hook ─> end
                                                                                         └─ closed / no-request ─> report ─> end
user posts a prompt ─> TaskStop the monitor ─> answer ─> name unfinished events ─> do not restart
```

## You are the team lead

You hold the plan and the policy, staff each event, judge what comes back, run
git and talk to the user. **You read no source files, and run no builds, tests
or linters.** Failure logs, diffs and test output belong to the team, never to
this session.

Read `../pln/references/delegation.md` (relative to this skill's own directory)
before spawning anything. It governs choosing a member, writing its prompt and
capping what comes back.

The team is two named members, spawned when the first event needs them and
re-addressed by name after that:

- **fixer**, on `opus`. It classifies pipeline failures, judges review comments,
  makes fixes and resolves conflicts. Classifying a failure and judging a
  comment are root-cause work.
- **verifier**, on a cheap model. It runs the plan's `Verify:` line in the
  foreground, never with `run_in_background`, and returns pass or fail with the
  shortest line that identifies a failure, quoted exactly. It never fixes
  anything.

Every member prompt stands alone: the repository root, the plan's absolute path,
what the event is (quoted from the event JSON), what to return, that it must not
commit, stage or push, that it must not write to the forge or to the plan, and
how to reach you — report by `SendMessage` to your name — with its output
contract. Each member's initial prompt carries, near its start and before the
output contract, verbatim, this sentence:

> Time matters here: do not spend time that can be avoided, and the earlier a
> correct result is obtained, the better.

The fixer reports the paths it changed, one per line. You commit exactly those
paths.

## Procedure

### 1. Find the plan

Run `pwsh -File "${CLAUDE_PLUGIN_ROOT}/scripts/Get-PlanContext.ps1"`. When the
user passed an argument, add `-Plan <argument>`. Act on `PlanMatch`:

- **`branch`** or **`selected`** — proceed with `PlanPath`.
- **`ambiguous`** — list the candidates (`Matches` when an argument was passed,
  otherwise `Candidates`) with their titles, statuses and branches, and stop.
- **anything else** — say there is no plan for this branch, and stop.

Read the plan in full. Its `## Goal`, `## Decisions` and `## Divergences` are
what every fix, verdict and conflict resolution is judged against. Then refuse,
and stop, when:

- `Status:` is not `DONE`. On `PLANNING` or `IMPLEMENTING` point the user to
  `/impl`.
- `git branch --show-current` is not the plan's `Branch:`. Name both branches.

Say once which plan you are running, by title and path, and the branch.

### 2. Start the watch

Start the watch with the `Monitor` tool, with `command`:

```pwsh
pwsh -File "${CLAUDE_PLUGIN_ROOT}/scripts/Watch-PlanRequest.ps1" -Branch <the plan's Branch:>
```

- `description`: `request events for <branch>`
- `timeout_ms`: `1800000`, the effective maximum. Larger values are capped to
  it.

Each stdout line is one JSON event and arrives as a notification. Wait for them.
**Never poll**: do not read the monitor's output file, do not run the script
with `-Once`, and do not query the forge yourself to see whether something
changed. A failed poll goes to the script's stderr only and the loop keeps
going; it produces no event.

How the monitor ends decides what you do:

- **It times out** — start it again with the same arguments. This is the only
  case that restarts it. The state file in the worktree's git directory records
  what was already emitted, so a restart repeats nothing.
- **The script exits non-zero** — it threw at startup (unknown tracker, missing
  CLI, not a repository, and so on). Report its stderr and end. The run has
  ended, so this turn prints the final run summary as _End every turn of an
  active run with the run summary_ says.
- **The script exits after a terminal event** (`merged`, `closed`, `no-request`)
  — handle that event below. Never restart the monitor after it.

**When the user posts a prompt** — a message the user types, and only that.
Monitor notifications and members' `SendMessage` reports are not prompts and do
not stop anything. In this order:

1. Stop the monitor with `TaskStop` before anything else.
2. Answer the prompt.
3. Name every event you received but did not finish handling. Each was marked as
   emitted when it was printed and will not come again; a new `/fnsh` resumes
   the watch from the state file.
4. Do not start the monitor again. The run has ended: this turn ends with the
   final run summary, as _End every turn of an active run with the run summary_
   says, and no later turn prints a run summary.

### 3. Act on each event

Handle the events one at a time, in order of arrival. An event that arrives
while you handle another waits its turn. The watch keeps running meanwhile.

Every event carries `Event`, `Request` (`Number`, `Url`, `State`, `Target`,
`TargetIsDefault`, `HeadSha`), `Pipeline` (`State`, `Id`, `FailedJobs` with
`Name`, `Id`, `Url`), `Conflicted` and `Comments`. `Comments` is filled only on
the `comments` event; it is empty on every other.

#### `no-request`

Report that the branch has no request, and end. `/fnsh` does not create one. The
run has ended, so this turn prints the final run summary as _End every turn of
an active run with the run summary_ says.

#### `pipeline-failed`

Send the fixer the failed jobs (`Pipeline.FailedJobs`) and the target. It reads
the jobs' logs and classifies the failure as one of:

- **caused by the branch** — by the branch's changes, the diff from the merge
  base with `Request.Target`.
- **unrelated** — infrastructure, flaky, or failing on the target as well.

Unrelated: report the evidence the fixer gives, and fix nothing. Caused by the
branch: the fixer fixes, the verifier runs `Verify:`, you commit a `fixup!` and
push (see _Committing and pushing_).

On GitHub there is no pipeline id: `Pipeline.Id` is the head sha, and the event
fires once per head sha, after all checks finish. A manual re-run of the checks
that fails again on the same sha gives no new event. Say so when you report an
unrelated GitHub failure, since a re-run is the usual next move.

#### `comments`

Send the fixer every comment in `Comments`. It judges each one against the code
and the plan, and returns one verdict per comment with a one-line reason:

- **`required`** — correct, and needed for what `## Goal` and `## Decisions`
  intend.
- **`correct-outside-plan`** — correct, but not needed for the plan.
- **`unclear`** — cannot be judged as written.
- **`wrong`** — incorrect.

Only `required` comments are fixed: the fixer fixes, the verifier runs
`Verify:`, you commit a `fixup!` and push. The others are not fixed. The user
gets every verdict with its reason. Each comment is one item in the run summary.

#### `conflict`

**`Request.TargetIsDefault` false**: report the conflict and keep watching.
Nothing is rebased. When the request is later retargeted and still conflicts,
the conflict is handled again (see below).

**`Request.TargetIsDefault` true**, with `<default>` being `Request.Target`:

1. Record the pre-rebase sha: `git rev-parse HEAD`.
2. `git fetch origin <default>`, then `git rebase origin/<default>`. Plain,
   without `--autosquash`. When it completes with no conflicts, go straight to
   step 6.
3. Send the fixer the conflicted paths (`git diff --name-only --diff-filter=U`).
   It resolves each file and says, for each, whether the resolution keeps every
   plan decision and all behaviour the plan specifies.
4. If any does not: `git rebase --abort`, and report which decision or behaviour
   is at stake.
5. Otherwise stage exactly the paths the fixer reported and run
   `GIT_EDITOR=true git rebase --continue`. A later commit that conflicts goes
   back to step 3.
6. The verifier runs `Verify:`. When it fails, the fixer fixes under the
   two-round bound, and each fix that passes is committed as a `fixup!` (see
   _Committing and pushing_). When it still fails after the second round, the
   fixer reverts its uncommitted changes, you run
   `git reset --keep <pre-rebase sha>`, and you report that the rebase was
   undone, with the verifier's line.
7. Otherwise report that the branch is rebased and must be force-pushed by the
   user. You do not push.

Either way the watch keeps running. A `conflict` comes again for a new head sha,
which a force-push from the user produces, and also when the request's target
branch changes. You then handle it as a new event under the `TargetIsDefault` it
carries. Each occurrence is its own item in the run summary.

**While the rebased branch waits for the user's force-push**, a fix for
`pipeline-failed` or `comments` is committed locally and not pushed. Its summary
item says "not pushed: waiting for your force-push". Before each such commit,
check whether the window is still open: run `git fetch origin <branch>`, since
the user may force-push from another clone, then
`git rev-list --left-right --count 'origin/<branch>...HEAD'`. The window is
closed when the left count is zero. When `origin/<branch>` does not exist the
branch has no upstream, so there is no force-push window and the `-u` push in
_Committing and pushing_ applies.

#### `merged`

When an item is in progress as `merged` arrives, stop it first: the fixer
reverts its uncommitted changes, nothing for the item is committed or pushed,
and its summary item is marked "superseded by merge". Every event still queued
and not yet handled is not handled either; each gets a summary item marked
"superseded by merge". Then:

1. Run:

   ```pwsh
   pwsh -File "${CLAUDE_PLUGIN_ROOT}/scripts/Remove-PlanWorktree.ps1" -Branch <branch> -Target <Request.Target> -MergedSha <Request.HeadSha>
   ```

2. Report what it did: `TargetPath` and `Pulled`, `WorktreePath` and `Removed`,
   and `BranchDeleted`. Report any `Reason`, which can be a comma-joined list of
   `target-not-checked-out`, `pull-failed`, `dirty`, `remove-failed`,
   `main-worktree`, `no-worktree` and `branch-not-merged`, and `Message` when
   present, which carries git's error for a failed removal or a refused branch
   deletion.
3. Invoke the `Finish` hook from step 1's `Get-PlanContext.ps1` output:
   - **`Finish.Skill`** — invoke that skill with the plan's absolute path as its
     argument.
   - **`Finish.Command`** — run it with `{plan}` replaced by the plan's absolute
     path, `{repo}` by `RepoRoot` from `Remove-PlanWorktree.ps1`, and `{branch}`
     by the plan's branch.
   - **absent** — invoke nothing, and say nothing about it.
4. End. The run has ended, so this turn prints the final run summary as _End
   every turn of an active run with the run summary_ says.

The session's working directory may be gone after the removal. Start every
command after it with `cd` to `RepoRoot` from `Remove-PlanWorktree.ps1`.

#### `closed`

Report that the request was closed without a merge, and end. The run has ended,
so this turn prints the final run summary as _End every turn of an active run
with the run summary_ says.

### 4. End every turn of an active run with the run summary

The run is active from the first start of the monitor until it reaches an end
state. The end states are:

- the user posts a prompt, which stops the monitor;
- the script exits non-zero at startup;
- a `no-request` event;
- a `merged` event;
- a `closed` event.

A monitor timeout and restart does not end it, and neither does an item that
failed its two fix rounds: the watch keeps going.

Every turn while the run is active ends with the full run summary. It covers
everything since this `/fnsh` started, not only the turn just taken, and is
repeated in full each time. It is a numbered list with one item per thing
handled: a pipeline failure, a single review comment, a conflict. Each item
says:

- what it was;
- what was fixed and why, or why nothing was fixed (for a comment: its verdict
  and reason);
- when it was pushed, with the time from `date` and the pushed sha, or that it
  is not pushed.

An item keeps its number for the whole run and new items take the next number,
so the user can ask about "item 3". The list is session state: a new `/fnsh`
starts again at 1. An event still in progress is an item too, marked as in
progress.

The turn that ends the run prints the summary once more, marked final. After
that turn no turn prints a run summary, whatever it is about. The summaries
earlier in the conversation are history, not a pattern to continue. Printing
resumes only when a new `/fnsh` starts a new run.

## Committing and pushing

You do every commit, rebase and push; members never do.

- A fix attaches to the commit that introduced the code it changes:
  `git commit --fixup=<sha> -- <paths>`, with the paths the fixer reported. Ask
  the fixer which commit introduced the code when it is not obvious from its
  report. When no branch commit introduced it (a file the branch never touched,
  a lockfile), target the branch commit whose change made the fix necessary. It
  is always a `fixup!`; there is no plain commit. Never `git add -A`, never
  `git commit -a`.
- Commit only after the verifier reports pass.
- Push with a plain `git push`. Run `date` right after it and record the time
  and `git rev-parse HEAD` for the summary. When it fails with "no upstream
  branch", run `git push -u origin <branch>`, still not forced.
- Never pull, merge or rebase to get past a rejected push. Report the rejection
  and leave the commit local; its item says it is not pushed.
- Never squash. No `--autosquash`, no roll-up: the branch is published, and its
  history is not rewritten except by the conflict rebase above.

## Rules that bind the session

- **Lead doctrine.** You read no source and run no builds, tests or linters. The
  fixer and the verifier do that work, per `delegation.md`.
- **Two fix rounds per pipeline failure or comment.** A round is one send-back
  to the fixer that comes back still failing `Verify:`. After the second failed
  round, report the item as failed with the verifier's line and leave it alone:
  nothing for it is committed or pushed, the fixer reverts its uncommitted
  changes for it so the tree is clean for the next event, and the watch keeps
  running.
- **`fixup!` targeting.** Every fix is a `fixup!` on the commit that introduced
  the code, or, when no branch commit did, on the branch commit that made the
  fix necessary.
- **No forge writes.** Neither you nor a member posts, comments, replies,
  resolves, approves, merges or closes anything on the forge. The only write is
  `git push`. Verdicts on review comments go to the user in this session.
- **No force push.** Never `--force`, `--force-with-lease`, `-f` or a `+`
  refspec. After a conflict rebase the user pushes, and fixes made before that
  stay local.
- **No plan writes.** The plan is `DONE` and stays as it is. Nothing is written
  to it and `Save-Plan.ps1` is never run.
- **No squash.** `fixup!` commits stay as separate commits on the branch.
- **`/fnsh` does not create the request.**
- **Worktree removal is never forced**, and the local branch is deleted only
  when `Remove-PlanWorktree.ps1` finds nothing local would be lost. Do not work
  around a `Reason`: no manual `git branch -D`.
