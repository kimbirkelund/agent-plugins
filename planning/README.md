# planning

Plan-driven workflow. Eight commands and the scripts behind them:

| Command        | Does                                                                                                                                                                                                                                                                                      |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/pln`         | Captures what is being discussed as a plan in the plans repository, then holds planning mode. `/pln <letter\|name>` refines an existing plan instead. Writes nothing else.                                                                                                                |
| `/oimpl`       | Validates the plan, creates the worktree, writes it into the plan, and opens an interactive session there. Does not run the plan.                                                                                                                                                         |
| `/impl`        | Runs the plan unattended in that session with a delegated team, from the gate to `DONE`. Lands one commit per step and records any divergence from the plan under `## Divergences` in the plan. Creates the branch itself when run directly on a plan without one.                        |
| `/fnsh`        | Stays with a `DONE` plan's PR or MR until it is merged: fixes failures and required review comments the branch caused with pushed `fixup!` commits, reports the rest, rebases on a conflict with the default branch, and after the merge removes the worktree and runs the `finish` hook. |
| `/ipln`        | Same conversation as `/pln`, but the deliverable is issues in this repository's own tracker — drafted locally, shown for review, posted only on an explicit go-ahead.                                                                                                                     |
| `/migrate-pln` | Moves an old working-tree `PLAN.md` into the plans repository, in the current format. One-shot, per plan.                                                                                                                                                                                 |
| `/rewrt`       | Consumes `∫∫...∫∫` marker notes written into files.                                                                                                                                                                                                                                       |
| `/list-plns`   | Lists this repository's plans — unfinished by default, in flight last, each with the letter `/pln` and `/oimpl` accept as a selector. Read-only.                                                                                                                                          |

## Plans live in their own repository

```
<plans repo>/<repo name>/<YYYY-MM-DD>-<slug>.md
```

One directory per repository, one file per plan, named from the date and a slug
of the plan's title. Plans are wrapped at 80 columns on save, so each header
field (`- Status: PLANNING`) and each `## How to execute plan` field is a list
item, one per line; a plan in the old bare form is converted by the save. The
repository name comes from the origin remote where there is one, so every
worktree of a repository plans into the same directory.

`scripts/Get-PlanContext.ps1 -Plan <selector>` resolves a letter from
`/list-plns`, a plan's file name, or a substring of its name or title, to one of
these files.

Two consequences:

- **The repository you are working in stays clean.** No permanently modified
  `PLAN.md` in `git status`.
- **Every write is committed**, so the plan's history is the record of how the
  thinking moved, and several plans per repository cost nothing.

`scripts/Get-PlanContext.ps1` is the only thing that knows the layout — it
resolves the plans repository, decides which plan is current, and reads the
configuration below. `scripts/Save-Plan.ps1` commits the plans repository under
a standard message, holding a lock while it does and syncing with the remote
from time to time (see below). `scripts/Migrate-Plan.ps1` moves a plan written
under the old working-tree convention into that layout.
`scripts/Get-PlanList.ps1` lists a repository's plans, filtered and ordered,
with the per-plan counts `/list-plns` reports. `scripts/Resolve-PlanBranch.ps1`
decides whether a plan lands on its own recorded branch or a fresh one, and
refuses a branch another plan owns. The skills call them rather than deriving
paths, and every script has Pester tests beside it.

## `/fnsh` shepherds the request to merge

Run `/fnsh` in a plan's worktree once `/impl` has set `Status: DONE` and the
branch has a pull request (GitHub) or merge request (GitLab). It refuses a plan
that is not `DONE` and a checkout that is not the plan's `Branch:`. It does not
create the request; with none for the branch it says so and stops.

`scripts/Watch-PlanRequest.ps1` polls the request and prints one JSON event per
line: `pipeline-failed`, `comments`, `conflict`, and the three that end the
watch, `merged`, `closed` and `no-request`. `/fnsh` runs it with the `Monitor`
tool, restarts it when the monitor expires, and handles the events in order of
arrival. What was already emitted is kept in `fnsh-state.json` in the worktree's
git directory, so a restarted watch repeats nothing. On GitHub a re-run of
failed checks on the same head sha gives no new event.

- **A failed pipeline** is classified. A failure the branch's changes caused is
  fixed, verified with the plan's `Verify:` line, committed as a `fixup!` on the
  commit that introduced the code (or, when no branch commit did, the one that
  made the fix necessary), and pushed with a plain `git push`. An unrelated
  failure is reported with its evidence and not fixed.
- **Each review comment** gets a verdict with a reason: `required`,
  `correct-outside-plan`, `unclear` or `wrong`. Only `required` comments are
  fixed and pushed the same way. Every verdict goes to you in the session;
  nothing is posted on the request.
- **A conflict with the default branch** is rebased onto `origin/<default>`. A
  resolution that would break a plan decision or behaviour the plan specifies
  aborts the rebase and is reported. Otherwise the branch is verified; a
  verification that still fails after two fix rounds undoes the rebase. A
  verified branch is left for you to force-push; `/fnsh` never force-pushes, and
  fixes made until you do are committed locally and not pushed. A conflict with
  any other target is only reported; if the request is later retargeted and
  still conflicts, `/fnsh` handles the conflict again.
- **A merge** runs `scripts/Remove-PlanWorktree.ps1`: it pulls the target branch
  with `--ff-only` where it is checked out, removes the plan's worktree without
  `--force` (a dirty worktree is reported and left, the main worktree is never
  removed), and then deletes the local branch. The branch is deleted with
  `git branch -D` when its tip is the merged request's head commit or an
  ancestor of it, which covers squash and rebase merges; otherwise
  `git branch -d` decides, so a branch with local commits the merge does not
  contain is kept and reported as `branch-not-merged`. A branch whose worktree
  could not be removed, or that is checked out in the main worktree, is kept.
  Then the `finish` hook runs.

Each fix gets at most two rounds. `/fnsh` never writes to the plan, never
squashes the `fixup!` commits, and writes nothing to the forge except
`git push`. While the run is active, every turn ends with a numbered summary of
everything handled since it started, with the pushed sha and time for each fix.

`/fnsh` stops when the request is merged, closed or missing, or when you post a
prompt: it stops the watch, answers, and names any event it received but did not
finish. The summary stops with the run: the turn that ends it prints the summary
once more, marked final, and later turns print none. Run `/fnsh` again to resume
the watch, which starts a new run and a new summary.

## Issues go to the repository's own tracker

`/ipln` files into the tracker of the repository you are working in, so it has
to know which one that is. `scripts/Get-IssueContext.ps1` is the only thing that
decides, and it prints one JSON object with `Tracker`, the `Cli` that talks to
it, `CliAvailable`, and the repository facts and `surface` hook it gets from
`Get-PlanContext.ps1`. `/ipln` runs it once per invocation.

Detection is in order:

1. **The host part of the origin remote** — if it contains the word `github`
   (any casing) and not `gitlab`, the tracker is `github` and the CLI is `gh`;
   if it contains `gitlab` and not `github`, `gitlab` and `glab`. So
   `github.com`, `ssh.github.com` and an ssh alias such as `github-work` all
   give `github`. The host part is the authority of a URL (`<scheme>://...`,
   between `://` and the next `/`, so user and port count), or everything before
   the first `:` of `git@host:path` and any other scp-style `host:path`. A local
   path has no host part. The path is never checked, so
   `git@git.example.com:org/github-x.git` gives no match. A host part with both
   words, or neither, gives no match and falls through.
2. **The `issueTracker` key in the configuration below**, for a self-hosted
   instance whose host name gives nothing away.
3. **Otherwise `unknown`**, and `/ipln` asks you which tracker it is rather than
   guessing.

Drafts are files in the scratchpad, one per issue, put in front of you with the
`surface` hook. Nothing is written into the repository and nothing is written
into the plans repository — the issue is the durable record. Posting is a
separate act that needs an explicit go-ahead after the drafts have been shown.

## One writer at a time, and the remote

Two sessions planning at once would race on one git index, so every
`Save-Plan.ps1` run holds a lock for the whole of its git work:
`.claude-plan.lock`, a directory, created with `mkdir` — the one filesystem
operation that is atomic everywhere, because creating a directory that already
exists fails rather than succeeding twice. The directory is left **empty**,
which is also why it never reaches a commit: git does not track empty
directories, so the lock is invisible to `git add -A` and to `git status`.

A lock older than `-StaleLockSeconds` (default 300) is assumed to belong to a
session that died and is broken; the run reports `BrokeLock: true`. A live lock
is waited on for `-LockTimeoutSeconds` (default 30) and then reported as a
timeout.

When the repository has an upstream, the run also pulls and pushes, at most once
every `-SyncIntervalSeconds` (default 300). The last attempt is stamped in
`.git/claude-plan-last-sync`, so every session on the machine shares one clock.
Sync problems are **reported, never thrown** — a plan committed locally is
already safe, and an unreachable remote is not a reason to fail the write, so
the result carries `Sync.Problem` for the skill to relay. A pull that cannot be
rebased cleanly is aborted, so the repository is never left mid-rebase.
`-SyncNow` forces a sync, `-NoSync` skips the remote entirely, and no upstream
means no sync at all.

## Configuration

`$XDG_CONFIG_HOME/claude-planning/config.json`, falling back to
`~/.config/claude-planning/config.json`. Every key is optional; the file itself
is optional.

```json
{
  "plansRepo": "~/code/plans",
  "issueTracker": "gitlab",
  "surface": { "skill": "show-me" },
  "worktree": { "skill": "new-branch-or-worktree" },
  "session": { "command": "wezterm start --cwd {path}" },
  "finish": { "command": "notify-send 'Merged {branch}'" }
}
```

### `plansRepo`

Where plans live. Defaults to `plans` under the code root (`$__CODE_ROOT`, else
`~/code`). `$CLAUDE_PLANS_REPO` overrides both. A leading `~` is expanded. The
repository is created and `git init`-ed on first use.

### `issueTracker` — which tracker `/ipln` files into

`github` or `gitlab`. Only consulted when the origin remote's host settles
nothing: no match on the host part, or both words in it. In practice that is a
self-hosted instance: `git.example.com` is a GitLab to `glab` and a mystery to
everyone else, and this key is where you say so. Anything else, or no key at
all, leaves the tracker `unknown` and `/ipln` asks.

### `surface` — how a plan is put in front of you

Invoked when `/pln` **creates** a plan, when `/impl` is about to run one — at
the start of every call, resumes included — and whenever you ask to see one. Not
on every `/pln` revision. `/ipln` uses the same hook for its issue drafts, and
does surface those on every revision — they are the only copy there is.

### `worktree` — how the branch or worktree for the work gets made

Invoked by `/oimpl`, or by `/impl` when it is run directly on a plan that has no
branch yet. What it returns is recorded as the plan's `Branch:` line, which is
also how a later `/impl` finds the plan again. Two things are needed back: the
branch name, which goes in the plan, and the worktree's absolute path, which
goes to `session`. A command hook should print that path on stdout.

### `session` — how a new interactive session is opened

Invoked by `/oimpl`, last, with the absolute path of the worktree it just made.
Normally a terminal or multiplexer command, so it is expected to return
immediately. Unlike the other hooks, an absent `session` hook **is** reported:
`/oimpl` has set the work up but cannot open anything, so it prints the path and
tells you to open a session there yourself.

### `finish` — what runs after a request is merged

Invoked by `/fnsh` once the request is merged, after the target branch is pulled
and the plan's worktree is removed. Commands run from the repository root,
because the worktree is gone. A skill gets the plan's absolute path as its
argument. Use it for whatever your own wrap-up is: a notification, a ticket
update, a cleanup script. Absent means nothing is invoked and nothing is said.

### Hook forms

Every hook takes a skill or a command:

```json
  "surface":  { "skill": "show-me" }
  "surface":  { "command": "pwsh -NoProfile -Command \"...Open-InFloatingNvim -Path '{path}'\"" }
  "surface":  "pwsh ... -Path '{path}'"
```

- **`skill`** — the skill is invoked with the relevant argument. Right when the
  work needs judgment: `new-branch-or-worktree` decides between a branch and a
  worktree from how the repository is laid out, and owns the branch-name prefix.
- **`command`** — run as a shell command. Deterministic, with an exit code. A
  bare string is shorthand for this form.
- Both set: **`command` wins.**
- Neither set, or the hook absent: the step is skipped silently. Not configured
  is a preference, not a problem to report.

Placeholders:

| Hook       | Placeholders                                                                                    |
| ---------- | ----------------------------------------------------------------------------------------------- |
| `surface`  | `{path}` — the plan's absolute path                                                             |
| `worktree` | `{repo}` — repository root; `{name}` — kebab-case slug from the plan's title; `{plan}`          |
| `session`  | `{path}` — the worktree's absolute path; plus `{repo}`, `{branch}`, `{plan}`                    |
| `finish`   | `{plan}` — the plan's absolute path; `{repo}` — repository root; `{branch}` — the plan's branch |

## Report gate hook

`hooks/hooks.json` registers a `TeammateIdle` hook that runs
`scripts/Invoke-ReportGate.ps1`. It enforces `/impl`'s output contract: a
teammate must deliver its report by `SendMessage`, because a turn that ends in
prose reaches nobody.

When a teammate is about to go idle and has not sent a `SendMessage` since its
last assignment, the hook exits 2 and feeds back a reminder to deliver the
completion report to the lead. The hook gates every teammate, not only those
spawned by `/impl`.

- **Transcript** — the payload's `transcript_path` is the lead session's, not
  the teammate's. The hook derives the teammate's transcript from it:
  `<dir of transcript_path>/<session_id>/subagents/agent-<agent_id>.jsonl`.
  `agent_id` is required; without it the hook cannot locate the teammate's
  transcript and exits 0. The first entry of the derived file must carry an
  `agentId` equal to `agent_id`, otherwise the file is not trusted and the hook
  exits 0.
- **Cap** — at most 2 pushbacks per teammate per session. After the second, the
  hook gives up, prints `ReportGateHook: <key> idled without a delivered report`
  and lets the teammate idle. Later idles are silent.
- **State** — counters live in
  `$CLAUDE_PLUGIN_DATA/report-gate/<session_id>.json`, keyed by
  `<session_id>:<agent_id>`. When `CLAUDE_PLUGIN_DATA` is unset, the system temp
  directory is used.
- **Fail open** — a missing, unreadable or over-5 MB derived transcript, an
  `agentId` mismatch, bad input, a payload without `session_id` or `agent_id`,
  or a state-file error never blocks the teammate.
- **Scope** — `TeammateIdle` fires only in agent-teams sessions
  (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`). Elsewhere the hook never runs.

## Shipping a change

Bump `version` in `.claude-plugin/plugin.json` — `claude plugin update` compares
nothing else, so an unbumped edit leaves the installed snapshot stale with no
error. `../Update-ClaudePlugin.ps1 planning` does the bump and the update in one
step: on `main` it opens a pull request, waits for its checks, merges, then
updates (it needs `gh` and an up-to-date `main`); on a feature branch it commits
and pushes the bump there, and `../Update-ClaudePlugin.ps1 planning -UpdateOnly`
installs it once that branch has merged.
