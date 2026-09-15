---
name: archive-sessions
description: File the Claude Code conversations that produced a piece of work into the Obsidian vault's plan-archive folder, referencing the plan without moving it. Use when the user types /archive-sessions, and offer it once /impl reports a plan is spent.
argument-hint: "[path to the plan to reference — omit to look it up for this repository]"
disable-model-invocation: true
---

# Archive sessions

Copy the transcripts of the sessions that did a piece of work into the vault, in one dated folder named after the repository and branch, so the conversation survives.

## Why this exists

The plan is already safe. It lives in the plans repository, committed after every edit, and its history is the record of how the thinking moved. Nothing needs rescuing there, and this skill will not touch it.

What that repository does not hold is the conversation. The transcripts under `~/.claude/projects/` do, and they outlive the work — but they are keyed by encoded directory name, they are megabytes each, and they are impossible to tie back to a specific piece of work months later. So the archive is not about preservation, it is about retrieval: one dated folder named the way the work is actually remembered — "that thing on the mqtt-range branch in August" — holding the conversations and an index that points back at the plan.

`/impl` offers this once a plan is spent. It is optional, and skipping it costs nothing but the conversation.

## What runs

```
pwsh <skill-dir>/scripts/Archive-Sessions.ps1 \
    -RepoPath "<abs path to the work tree>" \
    -ArchiveRoot "/Users/kimbirkelund/Documents/Obsidian Vault/plan-archive" \
    [-PlanPath "<abs path to the plan>"]
```

The script derives the folder name (`yyyy-MM-dd - repo - branch` from the origin remote and the checked-out branch), creates it under the archive root, copies the matching session transcripts into `conversations.zip`, and writes an `index.md`. It prints one line of JSON describing what it did — read that rather than re-deriving anything yourself, and never reimplement its path or filtering logic in shell.

`-PlanPath` is optional and read-only. Given one, the index records the plan's title, status, base commit, path, and the plans-repository commit the archive was taken beside; the plan itself is neither moved nor modified. Omit it and the archive is just the conversations, titled from the repository and branch.

Useful flags:

- `-WhatIf` — report the same JSON without touching anything. Use it when you want to show the user the folder name and session list before committing to it.
- `-Force` — overwrite an existing `conversations.zip` or `index.md` in the destination folder. Only with the user's say-so.
- `-Since <datetime>` — keep sessions still active at or after this time. Defaults to the plan's creation minus `-GraceHours` when a plan is given, otherwise a week back.
- `-GraceHours <n>` — how far before the plan's creation a session may have ended and still count. Default 6. Ignored when `-Since` is given.
- `-Date <date>` — date for the folder name. Defaults to the plan's creation date, or today without a plan.

Exit codes: `0` success, `1` plan named but not found, `2` unusable archive root, `3` destination already populated, `4` not a git work tree, `5` other failure. On a non-zero exit, report the error and stop — do not work around it by copying files yourself.

## Procedure

1. **Find the plan, if there is one.** The argument if given; otherwise run `pwsh -File "${CLAUDE_PLUGIN_ROOT}/scripts/Get-PlanContext.ps1"` from the repository root, never from this skill's directory, and take `PlanPath`. `PlanMatch` of `ambiguous` means several plans could be meant — list them and ask rather than guessing. No plan at all is fine: archive the conversations without one and say that is what you did.
2. **Run the script**, with `-RepoPath` at the work tree the sessions ran in. The user invoking `/archive-sessions` is the go-ahead; a dry run first only costs them a round trip. Do it in the session that did the work when you can — that session's own transcript is then part of what gets copied.
3. **Report** the archive folder, how many transcripts went in, and that the plan stayed where it is. Keep it to a couple of lines; the JSON is for you, not for them.

## What this skill does not do

- **Nothing to the plan.** Not moved, not copied, not edited, not committed. It is referenced by path and left alone; the plans repository is its home and its history is the point.
- **No commits.** Neither repository is touched.
- **No cleanup of `~/.claude/projects/`.** Transcripts are copied, never moved. That directory is Claude Code's, and other sessions may still be appending to files in it.
- **No reading of the transcripts.** They are megabytes each and the archive exists so that nobody has to read them now. Copy them and move on.
- **Nothing else in the vault.** Only the one dated folder under `plan-archive`. Daily notes and project notes belong to other skills.

## How transcripts are matched

Worth knowing, because it is the one place the result can look surprising:

Claude Code names each project folder after the session's working directory, with every character outside `[A-Za-z0-9]` replaced by `-`. The script encodes the work tree root the same way and takes that folder, plus any folder whose name extends it — but only after confirming from the recorded `cwd` that the sessions really ran inside this work tree. That check is what keeps a sibling worktree out: `…-safepilot-` also prefixes `…-safepilot-4108-…`, and those are different branches of work.

One consequence of `/impl` creating a worktree: the planning conversation and the implementation ran in different directories, so they are in different project folders. Archive from the worktree and you get the implementation sessions; the planning session ran at the repository root and is picked up by the same prefix rule only if the worktree is nested inside it. When both matter and the layout puts them apart, run the script once per work tree.
