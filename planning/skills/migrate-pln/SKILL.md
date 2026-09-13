---
name: migrate-pln
description: Move an old working-tree PLAN.md into the plans repository, in the current plan format, and delete the original once it is committed. Use when the user types /migrate-pln.
argument-hint: "[path to the old plan — omit for PLAN.md at the repository root]"
disable-model-invocation: true
---

# Migrate plan

Take a plan written under the old convention — an uncommitted `PLAN.md` at the root of the repository it was about — and put it where plans live now.

## Why this exists

The old convention left the plan in the working tree, permanently modified in `git status`, with no history and one plan per repository at a time. Plans now live in their own git repository, committed after every write, dated and named so several can coexist.

Old plans do not migrate themselves, and a stale `PLAN.md` sitting in a repository is worse than either convention: `/pln` will not find it, `/impl` will not run it, and it still dirties the tree. This is the one-shot fix, per plan.

## What runs

```
pwsh -File ../../scripts/Migrate-Plan.ps1 \
    -RepoPath "<abs path to the work tree>" \
    [-PlanPath "<abs path to the plan>"] \
    [-KeepSource] [-WhatIf]
```

Paths are relative to this skill's own directory. The script does all of it: derives the destination, rewrites the header, writes the file, commits the plans repository, and removes the original. It prints one JSON object — read that rather than re-deriving anything, and never move or rewrite a plan by hand.

What it changes is the header and the location, never the substance:

- The file lands at `<plans repo>/<repo name>/<date>-<slug>.md`, **dated from when the plan was written** rather than from today, so the directory stays in the order the work happened. The slug comes from the plan's title.
- A `Repo:` line is added. The file no longer sits in the repository it is about, and nothing else records which one that is.
- `Status:`, `Updated:`, and any `Branch:` or `Base:` lines carry over as they stand. A spent plan stays `DONE`; an interrupted one stays resumable, and `/impl` can pick it up from the plans repository exactly as it would have from the tree.
- Everything below the header is copied verbatim.

Useful flags:

- `-WhatIf` — report where the plan would land and what it would be called, touching nothing.
- `-KeepSource` — copy rather than move. Use it when the user wants the original left alone.

## Procedure

1. **Find the plan.** The argument if given; otherwise `PLAN.md` at the repository root, which is where the old convention put it. If there is none, say so and stop — there is nothing to migrate, and this is not the command for starting a plan.
2. **Dry run**, unless the user has already seen one. `-WhatIf` costs nothing and the destination name is the thing worth confirming: it is derived from a title and a date the user may not have thought about in months.
3. **Run it.** Report the JSON's `Destination`, `Status` and `Commit`.
4. **Say what happens next**, from `Status`:
   - `PLANNING` — `/pln` picks it up from here; `/oimpl` will run it.
   - `IMPLEMENTING` — a run was interrupted. `/impl` resumes it, on the branch its `Branch:` line names if it has one.
   - `DONE` — spent, and kept for its record. Nothing to run.
5. **Mention any markers.** `Markers` counts the unconsumed `∫∫...∫∫` in the file. They are carried over deliberately — migrating is not the moment to answer the user's own input — but they will block `/impl` at the gate, so say how many there are and that `/pln` is what consumes them.

## Order matters

The source file is the only copy of an uncommitted plan. The script writes the destination, commits the plans repository, and **only then** deletes the original — so a failed commit costs nothing and leaves both copies. It reports `SourceKept: true` when that happens.

Never delete a `PLAN.md` yourself, and never reorder these steps by copying the content out and cleaning up afterwards.

## What this skill does not do

- **Nothing to the repository the plan came from.** No commits, no staging, no other files touched. Deleting the old `PLAN.md` is the only change there, and it was never tracked.
- **It does not judge the plan.** A plan that is stale, wrong, or half-finished migrates exactly as it is. Rewriting it is `/pln`'s job, after it is in the plans repository.
- **It does not run the plan**, or set up a branch. `/oimpl` does that.
- **One plan per invocation.** Several old plans across several repositories are several runs; each needs its own work tree, and there is no scan.
