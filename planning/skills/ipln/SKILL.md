---
name: ipln
description: Turn what is being discussed into one or more issues in the current repository's issue tracker — drafted locally, shown for review, and posted only on an explicit go-ahead.
argument-hint: "[what to file, or omit for what we've been discussing]"
disable-model-invocation: true
---

# Issue plan

Capture what we have been discussing as issues in this repository's issue tracker. Same conversation as `/pln` — collect what was settled, scout what is genuinely open, lay out the steps — but the deliverable is an issue someone can pick up, not a plan file. Nothing is posted until the user says to post.

## Procedure

1. **Is there something to file?** With no argument and a conversation that settled nothing, ask what to file and stop there.
2. **Find the tracker.** Run `pwsh -File "${CLAUDE_PLUGIN_ROOT}/scripts/Get-IssueContext.ps1"` from the repository root, never from this skill's directory. **Once per run, not once per issue** — it is a fact about the repository, and the answer cannot change while you draft. Act on `Tracker` and `CliAvailable` per _Finding the tracker_ below.
3. **Harvest every `∫∫...∫∫` marker** in a draft you are revising, before folding in anything from the conversation. Drafts are normally revised in the session that wrote them, so the files are the ones in the scratchpad you already know; a later session has no record of them, so ask the user to point you at the draft file rather than going looking for it.
4. **Scout**, but only for questions the conversation genuinely left open.
5. **One issue or several.** Apply `../pln/references/splitting.md`. When it says split, propose the parts in your reply and wait — the user decides the boundaries before anything is written.
6. **Draft**, one file per issue in the scratchpad, from the template below. Nothing goes in the repository and nothing goes in the plans repository.
7. **Surface the drafts** — see _Surfacing the drafts_.
8. **Report, and stop.** Say what you drafted and what is still open. Do not post. Posting waits for an explicit go-ahead in the user's next message.
9. **On a go-ahead, post** — create the issues in order, patch the `Related issues` lists, report the URLs. See _Posting_.

The rest of this file is why, and what each step involves.

## Why this exists

An issue is the unit other people pick work up from. It outlives the conversation, it is read by someone who was not here, and — unlike a plan — it is public the moment it exists, which is the whole reason drafting and posting are two acts rather than one. The failure mode this prevents is a half-thought idea appearing in the tracker under the user's name, where taking it back costs more than writing it did.

The other failure mode is the opposite one: a conversation that settled something real and then evaporated because nobody wrote it down anywhere the team can see. That is what makes the issue, not a plan file, the right deliverable here — the user asked for something in the tracker, so the tracker is where the durable record goes, and no plan is written to disk at all.

## Finding the tracker

`Get-IssueContext.ps1` is the only thing that knows which tracker this repository uses. Never infer it from a remote URL yourself, and never assume `gh`. It prints one JSON object:

- **`Tracker`** — `github`, `gitlab`, or `unknown`. It reads the origin remote's host first, then the `issueTracker` key in the planning config for a self-hosted instance whose host name gives nothing away.
- **`Cli`** — `gh`, `glab`, or `null`. **`CliAvailable`** — whether that CLI is actually on `PATH`.
- **`RepoRoot`** — where to run `gh` and `glab` from. Both resolve which repository they are talking to from the working directory, and your drafts are in the scratchpad, so this is the one field you need at posting time rather than a surrounding fact. **`RepoName`**, **`Remote`**, **`ConfigPath`** — the surrounding facts.
- **`Surface`** — the user's hook, or absent. See _Surfacing the drafts_.

Two cases need handling, and they bite at different moments — one before you draft, one only when you would post:

- **`Tracker` is `unknown`** — this one stops you before you draft. Ask the user which tracker this repository uses and which CLI talks to it, and tell them that setting `issueTracker` in `$XDG_CONFIG_HOME/claude-planning/config.json` answers it permanently for this machine. Ask first: the body template does not depend on the tracker, but posting does, and finding out at the go-ahead wastes the review.
- **`CliAvailable` is false** — this one blocks only the posting. Drafting is still worth doing, so draft and surface as normal, but say plainly in your report that the CLI is missing and that you cannot post until it is installed and authenticated. Never try the create anyway to see what happens.

## One issue or several

Default to one. `../pln/references/splitting.md` carries the test, how to phrase the proposal, and the rule that the user decides — read it before you write, and do not restate its criteria here in your own words.

What is specific to issues: the parts you propose are the issues you will file, so the boundaries the user accepts are the boundaries in the tracker. That makes the proposal the last cheap moment to redraw them. Redrawing after posting means editing issues that other people may already have read.

## Drafting

Drafts are files in the scratchpad, one per issue, named so the reviewer can tell them apart — `1-<slug>.md`, `2-<slug>.md`, in the order they will be created. They are the review artifact and nothing more: no plan file, nothing written into the repository being discussed, nothing committed anywhere.

Each draft's first line is `# <the issue title>` and the rest is the issue body. The heading is for the person reviewing the file, so keep the title sharp — it is the line everyone scanning the tracker reads, and "Fix the thing" costs a click to decode.

### Template

```markdown
# <the issue title>

## Goal

What this issue is for, and what "done" means.

## Context

What already exists that matters here — files, constraints, prior decisions.
Conclusions and `path:line` pointers only.

## Decisions

Choices already settled, each with the reason, so the work is not re-litigated
by whoever picks this up.

## Steps

The work, as a numbered list, in order. Each step names the files it touches
and what done looks like for that step.

## Verify

The command, and the observable outcome that makes it a pass.

## Related issues

The sibling issues this was split from, by number, and how they depend on each
other. Filled in after the issues exist — see _Posting_.
```

Six sections, and no `Team:`, `Parallel:` or `Checkpoints:`. Those are `/impl`'s contract with a plan file; an issue is read by a person deciding whether to pick it up, and staffing lines mean nothing to them. A lone issue has no siblings, so unless the user named something related there is nothing for `Related issues` to hold — drop the section rather than writing `None` into it.

## The issue must stand on its own

Same test as a plan, for the same reason, and it bites harder here: read each step as though you had just opened the repository and knew nothing else. `/pln`'s _The plan must stand on its own, and it must stay a page_ carries the full argument — read it there rather than a summary here.

The one thing that differs is who the reader is. A plan is read by `/impl` in a fresh session; an issue is read by a colleague, weeks later, who was never in this conversation and cannot ask you what you meant. So the conclusions go in, the argument that produced them stays out, and a `path:line` pointer stands in for a paragraph of context — but a constraint you leave out is not recoverable by anyone.

## Human input in a draft: `∫∫...∫∫`

The user can write straight into a draft, wrapping anything they want handled in `∫∫` on both sides. Handle them exactly as `/pln` does — its _Human input in the file_ section is the definition, including that a marker is input rather than content, that it comes out once handled, and that a question gets answered in your reply rather than silently folded into the text.

Two things follow for issues specifically. A marker that is still standing means the draft is not ready, so never post a draft with one in it — it would land in the tracker as literal `∫∫` text. And a marker handled after the user has already given a go-ahead invalidates that go-ahead: the drafts changed, so you show them again and wait for a new one.

## Surfacing the drafts

The user may configure a hook that puts a file in front of them. `Get-IssueContext.ps1` returns it as `Surface`, the same shape `/pln` uses:

- **`Surface.Skill`** — invoke that skill with the draft's absolute path as its argument.
- **`Surface.Command`** — run it, with `{path}` replaced by the draft's absolute path.
- **absent** — surface nothing, and say nothing about it. Not configured is a preference, not a problem to report.

Surface every draft you wrote or changed on this turn, each one once. The drafts are the thing under review and there is no other copy, so unlike a plan they are surfaced on every revision, not only at creation.

## Posting needs an explicit go-ahead

Writes to GitHub and GitLab need an explicit human instruction, per occurrence. So:

- **Draft, surface, report, stop.** Ending the turn without posting is the correct outcome of a `/ipln` run, not an incomplete one. Do not ask "shall I post?" and treat silence, a thumbs-up on something else, or an earlier "yes, let's file this" as the answer — the go-ahead comes after the drafts have been shown, because it is consent to the text that was shown.
- **One go-ahead covers exactly the set of drafts shown in that reply.** Not a draft you wrote afterwards, not a revision of one, not a seventh issue that occurred to you while posting the first six.
- **Any later change means new drafts and a new go-ahead.** Show the changed drafts, then wait again.
- **An edit to an issue that is already posted is its own instruction**, each time. The one exception is the `Related issues` patch below, which is part of the post the user approved.

## Posting

On the go-ahead, create the issues **in order**, so the numbers run the way the drafts do.

Each draft's first line is the title and the rest is the body, so write the body — everything after that first heading — to a `<n>-<slug>.body.md` beside the draft and post that:

- **GitHub** — `gh issue create --title "<title>" --body-file <n>-<slug>.body.md`
- **GitLab** — `glab issue create --title "<title>" --description "$(cat <n>-<slug>.body.md)"`

`glab` takes the description as an argument rather than a path, so read the file into it rather than pasting the body into the command line — a multi-line body typed as a quoted argument is how a stray backtick or quote ends up mangling the issue.

**Run both commands from `RepoRoot`**, not from the scratchpad. `gh` and `glab` decide which repository they are filing against by looking at the working directory, and the scratchpad is not in a repository at all, so a create run where the drafts live either fails or — worse — targets something else. Pass `gh --repo` or `glab --repo` explicitly if you would rather not change directory.

Create one, note its number and URL, then the next. No labels, milestones or assignees unless the user named them in the conversation; adding them because they seem sensible is a decision the user did not make.

Then **patch the siblings in**. The numbers do not exist until the issues do, so `Related issues` is written twice by construction: once as the placeholder the user reviewed, once with the real numbers. Update each body file with the sibling numbers and the dependency order, then push it back:

- **GitHub** — `gh issue edit <number> --body-file <n>-<slug>.body.md`
- **GitLab** — `glab issue update <number> --description "$(cat <n>-<slug>.body.md)"`

This edit is part of the post the user approved, so it does not need its own go-ahead. Nothing else about a posted issue is covered by that approval.

If a create fails part way through the set, stop. Report which issues exist, with their URLs, and what failed — never retry blind and never carry on to the next issue, because a partial set with a half-written `Related issues` list is the state that is hardest for the user to untangle.

## You are the lead, and the drafts are yours

The drafts are your deliverable. You write them yourself, in this session, never through an agent — they are the thing the user is reviewing with you, and a lead who does not hold them cannot answer "change step 3". What you delegate is everything that would bury the conversation: reading the codebase and running commands. Read `../pln/references/delegation.md` before spawning anything; it governs here without exception.

This half of the work is serial and convergent, so there is no standing team and no roles. When a factual question arises that the conversation cannot answer, send one scout for one question, ask for a verdict and `path:line` references, and never for the code itself.

## After posting, the mode ends

There is no mode to hold. `/pln` holds planning mode because `/impl` is waiting for it; nothing is waiting here — the issues are the record, and whoever picks one up does so from the tracker. So once the URLs are reported the run is over, and the next message is an ordinary message.

Running `/impl` from an issue is not a thing this skill does. If the user wants to start the work now, that is `/pln` and a plan, and saying so costs them one keystroke.

## Reporting back

Step 8, and then step 9, each has a shape. A couple of lines, in your own words:

**When you have drafted** — what each issue covers, one line each; where the drafts are, by absolute path; the split you proposed and why, if you proposed one; anything still open, said plainly as a blocker on posting; your answer to any `∫∫...?∫∫` question, in full, rather than compressed into "handled your question". Then say that nothing has been posted and that you are waiting for a go-ahead.

**When you have posted** — the URLs, one per issue, in the order they were created, and the fact that the sibling links are in. Nothing else; the issues speak for themselves from here.

Relaying rules from `delegation.md` apply: a scout's report never reaches the user verbatim, and whatever mattered in it, you say.
