---
name: list-plns
description: List this repository's plans from the plans repository, unfinished ones by default, in the order that puts the work in flight closest to the prompt. Use when the user types /list-plns, or asks what plans exist for this repository, what is still open, or which plan is current.
argument-hint: "[all — include finished plans]"
---

# List plans

Show what is planned for the repository you are in.

## Why this exists

Plans live in their own repository, one directory per repository they are about. That is what keeps the working tree clean, and it is also why nothing in the working tree says what has been planned — `git status` does not show it, `ls` does not show it, and `/pln` only ever speaks about the one plan it picked. A repository can easily carry several plans at once: one in flight, one waiting for a worktree, and a handful spent.

This is the read-only view over that directory. It changes nothing — not a status, not a date, not a commit.

## Procedure

1. **Run the script.** `pwsh -File ../../scripts/Get-PlanList.ps1` (path relative to this skill's own directory), adding `-All` when the user asked for everything. It prints one JSON object; read that and derive nothing yourself.
2. **Render it** as described below. Never dump the JSON.
3. **Say what is hidden**, when `Total` is greater than `Listed`: how many spent plans were left out, and that `/list-plns all` includes them. One clause, not a paragraph.

`all`, `--all`, `-a`, "include done", "everything" — all mean `-All`. With no argument, unfinished plans only.

## What the script returns

Per plan: `Path`, `Name`, `Title`, `Status`, `Group`, `Branch`, `Updated`, `IsCurrent`, `Goal` (the first paragraph of `## Goal`), `Steps`, `Markers` and `OpenQuestions`. Around them: `RepoName`, `PlanDir`, `CurrentPlan`, `Total` and `Listed`.

`Group` is the ordering the script already applied, and the grouping to render:

- **`done`** — `Status: DONE`. Spent, kept for its record.
- **`unknown`** — a `Status:` line that is none of the three. Not hidden by the filter, because an unreadable status is a thing to see.
- **`not-started`** — `Status: PLANNING`. Nothing has run yet, whether or not it has a branch.
- **`ongoing`** — `Status: IMPLEMENTING`. A run is in flight or was interrupted.

`Plans` is already in the order to print, and **it is deliberate: spent first, in flight last.** The terminal scrolls, so the last line printed is the one the user is looking at, and what they most often want is the work in flight. Within a group the least recently updated comes first, so the freshest plan of each group sits at its bottom. Print them in the order they arrive; never re-sort, never reverse, and never "most relevant first".

## Rendering

One header line, then the groups in the order they came, each plan as a line with an indented goal beneath it:

```
widget — 4 plans, 1 done hidden (`/list-plns all` to include)

not started
  2026-09-04-retry-budget — 6 steps · 2 open questions · updated 2026-09-05
      A per-caller retry budget, so one bad dependency cannot amplify load.
  2026-09-08-drop-legacy-uploader — 4 steps · on drop-legacy-uploader · updated 2026-09-08

ongoing
  2026-09-10-parallel-uploads — on feat/parallel-uploads · 9 steps · updated 2026-09-10 ← current
      Upload parts concurrently, capped per host, with one shared rate limit.
```

Rules for that:

- **The name without the `.md`** identifies the plan; the title is usually the same words and printing both is noise. Print the title instead when it says something the file name lost.
- **The short status is what the reader needs to decide whether to open it**: how many steps, the branch when there is one, the `Updated:` date, and anything blocking — `Markers` (unconsumed `∫∫...∫∫`) and `OpenQuestions` both stop `/impl`, so say when either is non-zero and stay quiet when both are zero.
- **Mark the current plan** — the one whose `Path` is `CurrentPlan`, flagged as `IsCurrent`. That is the plan `/pln` and `/impl` act on with no argument, which is worth knowing before running either.
- **The goal is one line, trimmed to what fits.** It is there so the name means something; it is not a summary of the plan.
- **Drop a group with nothing in it** rather than printing an empty heading.
- **Nothing at all** — say the repository has no plans and that `/pln` writes the first one. Do not list the plans of another repository to fill the space.

## What this skill does not do

- **It does not write.** No status changes, no `Updated:` refresh, no `Save-Plan.ps1`, no commits — in either repository.
- **It does not read the plans into the conversation.** The script reads the header and a few counts; opening a plan in full is `/pln`'s move, or the surface hook's when the user asks to see one. If they want to look at a plan, say which command does it rather than pasting the file.
- **It does not judge or tidy.** A stale `PLANNING` plan from three months ago is listed as it stands. Do not suggest marking it `DONE`, do not offer to delete it, and do not decide two plans overlap.
- **It does not pick a plan to run.** Listing is not choosing; `/oimpl` and `/impl` do that, and an ambiguous match is their question to ask.
- **One repository — the one you are in.** There is no cross-repository scan.
