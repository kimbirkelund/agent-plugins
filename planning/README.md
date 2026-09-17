# planning

Plan-driven workflow. Eight commands and five scripts:

| Command             | Does                                                                                                                                                                       |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/pln`              | Captures what is being discussed as a plan in the plans repository, then holds planning mode. `/pln <letter\|name>` refines an existing plan instead. Writes nothing else. |
| `/oimpl`            | Validates the plan, creates the worktree, writes it into the plan, and opens an interactive session there. Does not run the plan.                                          |
| `/impl`             | Runs the plan in that session with a delegated team. Creates the branch itself when run directly on a plan without one.                                                    |
| `/ipln`             | Same conversation as `/pln`, but the deliverable is issues in this repository's own tracker — drafted locally, shown for review, posted only on an explicit go-ahead.      |
| `/migrate-pln`      | Moves an old working-tree `PLAN.md` into the plans repository, in the current format. One-shot, per plan.                                                                  |
| `/rewrt`            | Consumes `∫∫...∫∫` marker notes written into files.                                                                                                                        |
| `/list-plns`        | Lists this repository's plans — unfinished by default, in flight last, each with the letter `/pln` and `/oimpl` accept as a selector. Read-only.                           |
| `/archive-sessions` | Files the Claude Code conversations that produced a piece of work into the vault. Optional; never touches the plan.                                                        |

## Plans live in their own repository

```
<plans repo>/<repo name>/<YYYY-MM-DD>-<slug>.md
```

One directory per repository, one file per plan, named from the date and a slug of the
plan's title. The repository name comes from the origin remote where there is one, so
every worktree of a repository plans into the same directory.

`scripts/Get-PlanContext.ps1 -Plan <selector>` resolves a letter from `/list-plns`, a
plan's file name, or a substring of its name or title, to one of these files.

Two consequences:

- **The repository you are working in stays clean.** No permanently modified `PLAN.md` in
  `git status`.
- **Every write is committed**, so the plan's history is the record of how the thinking
  moved, and several plans per repository cost nothing.

`scripts/Get-PlanContext.ps1` is the only thing that knows the layout — it resolves the
plans repository, decides which plan is current, and reads the configuration below.
`scripts/Save-Plan.ps1` commits the plans repository under a standard message, holding a
lock while it does and syncing with the remote from time to time (see below).
`scripts/Migrate-Plan.ps1` moves a plan written under the old working-tree convention into
that layout. `scripts/Get-PlanList.ps1` lists a repository's plans, filtered and ordered,
with the per-plan counts `/list-plns` reports. The skills call them rather than deriving paths, and every script has Pester
tests beside it.

## Issues go to the repository's own tracker

`/ipln` files into the tracker of the repository you are working in, so it has to know
which one that is. `scripts/Get-IssueContext.ps1` is the only thing that decides, and it
prints one JSON object with `Tracker`, the `Cli` that talks to it, `CliAvailable`, and the
repository facts and `surface` hook it gets from `Get-PlanContext.ps1`. `/ipln` runs it
once per invocation.

Detection is in order:

1. **The host of the origin remote** — `github.com` (including hosts under it, such as
   `ssh.github.com`) gives `github` and the `gh` CLI; `gitlab.com` gives `gitlab` and
   `glab`.
2. **The `issueTracker` key in the configuration below**, for a self-hosted instance whose
   host name gives nothing away.
3. **Otherwise `unknown`**, and `/ipln` asks you which tracker it is rather than guessing.

Drafts are files in the scratchpad, one per issue, put in front of you with the `surface`
hook. Nothing is written into the repository and nothing is written into the plans
repository — the issue is the durable record. Posting is a separate act that needs an
explicit go-ahead after the drafts have been shown.

## One writer at a time, and the remote

Two sessions planning at once would race on one git index, so every `Save-Plan.ps1` run
holds a lock for the whole of its git work: `.claude-plan.lock`, a directory, created with
`mkdir` — the one filesystem operation that is atomic everywhere, because creating a
directory that already exists fails rather than succeeding twice. The directory is left
**empty**, which is also why it never reaches a commit: git does not track empty
directories, so the lock is invisible to `git add -A` and to `git status`.

A lock older than `-StaleLockSeconds` (default 300) is assumed to belong to a session that
died and is broken; the run reports `BrokeLock: true`. A live lock is waited on for
`-LockTimeoutSeconds` (default 30) and then reported as a timeout.

When the repository has an upstream, the run also pulls and pushes, at most once every
`-SyncIntervalSeconds` (default 300). The last attempt is stamped in
`.git/claude-plan-last-sync`, so every session on the machine shares one clock. Sync
problems are **reported, never thrown** — a plan committed locally is already safe, and an
unreachable remote is not a reason to fail the write, so the result carries
`Sync.Problem` for the skill to relay. A pull that cannot be rebased cleanly is aborted, so
the repository is never left mid-rebase. `-SyncNow` forces a sync, `-NoSync` skips the
remote entirely, and no upstream means no sync at all.

## Configuration

`$XDG_CONFIG_HOME/claude-planning/config.json`, falling back to
`~/.config/claude-planning/config.json`. Every key is optional; the file itself is
optional.

```json
{
  "plansRepo": "~/code/plans",
  "issueTracker": "gitlab",
  "surface": { "skill": "show-me" },
  "worktree": { "skill": "new-branch-or-worktree" },
  "session": { "command": "wezterm start --cwd {path}" }
}
```

### `plansRepo`

Where plans live. Defaults to `plans` under the code root (`$__CODE_ROOT`, else `~/code`).
`$CLAUDE_PLANS_REPO` overrides both. A leading `~` is expanded. The repository is created
and `git init`-ed on first use.

### `issueTracker` — which tracker `/ipln` files into

`github` or `gitlab`. Only consulted when the origin remote's host settles nothing, which
in practice means a self-hosted instance: `git.example.com` is a GitLab to `glab` and a
mystery to everyone else, and this key is where you say so. Anything else, or no key at
all, leaves the tracker `unknown` and `/ipln` asks.

### `surface` — how a plan is put in front of you

Invoked when `/pln` **creates** a plan, and whenever you ask to see one. Not on every
revision. `/ipln` uses the same hook for its issue drafts, and does surface those on every
revision — they are the only copy there is.

### `worktree` — how the branch or worktree for the work gets made

Invoked by `/oimpl`, or by `/impl` when it is run directly on a plan that has no branch
yet. What it returns is recorded as the plan's `Branch:` line, which is also how a later
`/impl` finds the plan again. Two things are needed back: the branch name, which goes in
the plan, and the worktree's absolute path, which goes to `session`. A command hook should
print that path on stdout.

### `session` — how a new interactive session is opened

Invoked by `/oimpl`, last, with the absolute path of the worktree it just made. Normally a
terminal or multiplexer command, so it is expected to return immediately. Unlike the other
two, an absent `session` hook **is** reported: `/oimpl` has set the work up but cannot open
anything, so it prints the path and tells you to open a session there yourself.

### Hook forms

Either hook takes a skill or a command:

```json
  "surface":  { "skill": "show-me" }
  "surface":  { "command": "pwsh -NoProfile -Command \"...Open-InFloatingNvim -Path '{path}'\"" }
  "surface":  "pwsh ... -Path '{path}'"
```

- **`skill`** — the skill is invoked with the relevant argument. Right when the work needs
  judgment: `new-branch-or-worktree` decides between a branch and a worktree from how the
  repository is laid out, and owns the branch-name prefix.
- **`command`** — run as a shell command. Deterministic, with an exit code. A bare string
  is shorthand for this form.
- Both set: **`command` wins.**
- Neither set, or the hook absent: the step is skipped silently. Not configured is a
  preference, not a problem to report.

Placeholders:

| Hook       | Placeholders                                                                           |
| ---------- | -------------------------------------------------------------------------------------- |
| `surface`  | `{path}` — the plan's absolute path                                                    |
| `worktree` | `{repo}` — repository root; `{name}` — kebab-case slug from the plan's title; `{plan}` |
| `session`  | `{path}` — the worktree's absolute path; plus `{repo}`, `{branch}`, `{plan}`           |

## Shipping a change

Bump `version` in `.claude-plugin/plugin.json` — `claude plugin update` compares nothing
else, so an unbumped edit leaves the installed snapshot stale with no error.
`../Update-ClaudePlugin.ps1 planning` does the bump, the commit and the update in one step.
