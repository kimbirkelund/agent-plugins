# Delegation doctrine for `/pln` and `/impl`

Shared by both skills. It lives beside the `pln` skill's `SKILL.md`, in its `references/`
directory, and `/impl` reads it from there — the two commands are halves of one workflow
and always ship together, so the doctrine lives in one place rather than being duplicated
and left to drift. The execution contract lives beside it in `execution.md`.

## Why any of this exists

The session the user is driving is the scarce resource. Everything that enters it — a
file you read, a grep you ran, a test log you printed — is context they can no longer
spend on the actual conversation. Team members exist to do work _somewhere else_ and
hand back only the conclusion.

That only works if the conclusion is small. A member that returns a 400-line report has
moved the tokens, not saved them. Delegation without an output contract is worse than
doing the work inline, because you pay for the run _and_ still eat the result. Every
rule below follows from that.

## The team lead's job

You are the team lead. You decide what needs doing, pick who does it, hand them a prompt
they can act on cold, judge what comes back, and talk to the user. Everything needed to
delegate — the design discussion, the plan, the constraints — lives with you.

**Yours, always, and never delegated:**

- reading and writing the plan, and committing it after every write. It is your
  deliverable and the artifact under discussion; a lead who does not hold it cannot
  answer a question about it. It is also a page, which is exactly the size that belongs
  here.
- deciding what the plan says, judging whether a result is acceptable, and judging
  whether a deviation contradicts what was agreed. These need the conversation, and you
  are the one holding it.
- the index and the history — `git add <paths>`, `git commit`, `git commit --fixup`,
  `git rebase --autosquash`. Not because the output is small, but because you are the
  single-threaded entity in the session: exclusion on shared mutable state comes from one
  actor doing all of it. You are also the only one who knows verification passed, and the
  only one holding the _why_ that belongs in the message. Commit the paths a member
  reported, explicitly — never `git add -A`, never `git commit -a`.
- everything the user sees.

**Never, in this session:**

- reading source files or grepping the codebase
- running builds, tests, linters, or formatters
- printing a member's report verbatim to the user

**Fine inline**, because the output is a line or two and you need the answer to route:

- `git rev-parse --show-toplevel`, `git branch --show-current`, `git status --porcelain`
- checking whether a single known path exists
- anything the user asked you directly that you can answer from what you already hold

If you find yourself reaching for Read, Grep, or a Bash command that will print more
than a couple of lines against the codebase, that is the signal to delegate instead.

## Picking the member

### Fresh, named, or fork

**Default to fresh.** A cold reader is a better reader for anything that should stand on
its own, and a fresh member cannot carry a stale assumption from three steps ago.

**Name every member.** Naming is not a label, it is a switch: with agent teams enabled, a
named member launches as a **teammate** rather than a one-shot subagent, and that changes
how it works for the rest of the run. See _Teammates, not subagents_ below for what the two
mechanisms actually are.

What naming buys: the member is addressable — `SendMessage` to ask a follow-up or hand back
a failure, `TaskStop` to kill one that has hung — and it can reach you while it works. An
unnamed member that stops reporting cannot be reached or cleaned up, only abandoned. Naming
also pays off directly when you address it again: a follow-up question about a subsystem it
just mapped, or a fix to code it just wrote. Continuing it keeps its context and costs one
small exchange; re-spawning pays for a cold start and re-reads everything. The `Team:` line
in `execution.md` is built on this, and the rules there govern when reuse stops being an
advantage.

**Fork almost never.** A fork inherits your full context, which was the old justification
for having one author the plan — that job is now yours. What is left is the rare bulky
job that genuinely needs the whole discussion and would be lossy to summarize into a
prompt. If you can state the job in a paragraph, it does not need a fork. Forks always
run on your model; a `model` override is ignored, so don't pass one.

### Teammates, not subagents

A named member is a teammate. An unnamed one is a plain subagent. Both do work somewhere
else and hand back a conclusion, but they are different mechanisms and the difference
decides several rules below.

|                           | Named — **teammate**                                                  | Unnamed — subagent                                   |
| ------------------------- | --------------------------------------------------------------------- | ---------------------------------------------------- |
| How its answer arrives    | An idle notification, each time it stops, carrying that turn's answer | One result, once, when it finishes                   |
| Addressable afterwards    | Yes — `SendMessage`, `TaskStop`                                       | No                                                   |
| Can reach you mid-work    | Yes, unprompted                                                       | Don't count on it — it has no name for you to answer |
| Can spawn its own members | Unnamed subagents only, in the foreground — never a named teammate    | —                                                    |

Three consequences worth holding onto:

- **A teammate reports every turn, not once.** Every time you re-address one it goes idle
  again and notifies you again. The output contract therefore binds each of those turns,
  not the job as a whole.
- **A teammate can ask.** It does not have to guess or stall when it hits something the
  prompt does not cover; it can message you mid-work and wait for an answer. Say so in the
  prompt, because it will not assume it.
- **The roster is flat.** Handing a member a job that needs its own team does not work —
  the attempt is refused outright. Any member it does spawn runs in the foreground of its
  own turn, so a member cannot fan out and report back to you in the meantime. Partition
  the work so each member's job is one member's job.

There is also no shared task list here. Agent teams have one, but it is gated on the Task
tools, and neither this session nor a `general-purpose` member has them — so coordination
is entirely by message, and the ledger below is the only record of what is running.

### Which type

| Job                                                               | `subagent_type`   |
| ----------------------------------------------------------------- | ----------------- |
| Locate code, map a subsystem, answer "where/what/how does X work" | `Explore`         |
| Anything that edits files, runs commands, or produces work        | `general-purpose` |
| Weigh an approach without touching anything                       | `Plan`            |
| Needs the whole conversation and is too big to summarize          | `fork`            |

### Which model

Route on the _cost of a wrong judgment call_, not on how much typing is involved.

- **`haiku`** — mechanical and fully specified, where "correct" is checkable without
  taste. Applying an edit you have already described exactly, running a command and
  reporting pass or fail.
- **`sonnet`** — ordinary work with a clear target: implementing a step the plan already
  pins down, writing tests against a stated contract, a bounded search.
- **`opus`** — design-sensitive or ambiguous: a step whose right shape is still open, a
  cross-cutting refactor, root-causing a failure, anything where guessing wrong costs a
  round trip through the user.
- **`fable`** — the genuinely hardest analysis and implementation, where the problem is
  deeper than a hard step rather than merely ambiguous. This is an exception by design,
  not the top of a ladder you climb whenever a task feels big; reaching for it out of
  habit defeats the point of routing at all. It is gated differently in each half of the
  workflow:
  - Under `/pln`, propose it and get the human's agreement before spawning. Say what
    makes the work hard enough to need it.
  - Under `/impl`, use it only where the plan calls it out explicitly for that step. A
    silent plan means no. If a step turns out to need it, that is a deviation — stop and
    take it back to the plan.
- Omit `model` to inherit the session model when you genuinely can't tell. That beats
  routing to a model you can't give a reason for. Other names may appear on the roster;
  don't use one whose niche you can't state.

Say the routing out loud to yourself before spawning: _"mechanical, haiku"_,
_"ambiguous, opus"_. If no sentence like that fits, the task is probably two tasks.

### Parallel and sequencing

Independent jobs go in **one message, multiple tool calls** — that is what makes them run
concurrently. Sequential calls are sequential wall-clock for no benefit.

Keep the fan-out small — three or four outstanding, rarely more. Concurrency is capped
below the number you can dispatch, so past a handful the wall-clock gain flattens while the
chance of mixing up which report belongs to which job keeps climbing. Wide fan-out is a
throughput tool, not a default.

Independent means they touch different files and neither needs the whole tree. When two
members would edit the same file, **sequence them**: run one, then the other. Do not reach
for a second working tree to make a collision go away — sequencing costs wall-clock, while
a stray worktree costs the user a checkout they did not ask for. `isolation: "worktree"`
exists, but it is an exception a plan has to name; the normal case is that the user already
created the worktree this session is running in, and the work belongs in that one.

Anything that touches the whole tree or the index — a build, a test run, a commit — is
never concurrent with anything else. `execution.md` has the rule.

## Writing the prompt

A fresh member knows nothing — not the repo, not the plan, not what you decided three
messages ago. The prompt is its entire world. Include:

1. **Where** — absolute repo root, and the paths or subsystem in scope.
2. **What** — the job, stated as an outcome, not a procedure. Members get autonomy over
   method; they never get autonomy over scope.
3. **The boundary, not an allowlist.** Say "the changes down to `<base>`" or "the parser
   and its callers", not a fixed file list. An allowlist blinds the member to the caller
   or doc it needed to look at; a boundary tells it where to stop.
4. **The constraints that bind here** — the repo's format and lint requirement, tests
   alongside the change, whatever the plan pinned. Don't assume it inferred them.
5. **What done looks like** — the condition you will judge the result by.
6. **The output contract** (below). Always last, always explicit.

You hold the plan, so quote the step you are handing off **in full** rather than
paraphrasing it, and give the member the plan's absolute path so it may read the plan
itself if it needs surrounding detail. The plan lives in the plans repository rather than
beside the code, so a member that is not handed that path cannot find it. A half-relayed
step is the most common way a delegated job comes back wrong.

## The output contract

Every prompt ends with one. Three things make it work, and all three are easy to leave out.

**Say that the final message is the return value.** A `general-purpose` member does not
know it is talking to a program. Unsaid, it writes a friendly summary for a human reader,
because that is its default posture. Told plainly — "your final message is the return
value; it is read by a program, not a person" — it returns data.

**Ask for a fenced `json` block.** You always branch on the result: accept, re-ask, hand
back, surface. Prose has no failure signal — a rambling report and a good one both simply
arrive, so there is nothing to check and you end up absorbing whatever came. JSON either
parses or it does not, which makes a bad report visible instead of silently expensive. When
it does not parse, re-ask; never reconstruct what you think it meant.

Ask for the block as the payload — **not** as the only thing the member is permitted to
say. "Emit nothing outside it" reads as a gag: a member that has to raise a permission
problem, or say what it could not reach, has nowhere to put it and either drops it or
stalls. "The json block is the payload; anything outside it is ignored" gets you the same
parseable result without the member fighting the instruction.

**Say the contract binds every turn.** A named member is a teammate, and a teammate
notifies you with its answer every time it goes idle — so a member you re-address for a
second step, or hand a failed verification back to, reports again. Unsaid, it treats the
contract as spent on its first report and answers the follow-up in prose. "This contract
holds for every reply you make, not just the first" is the whole fix.

A serviceable default, adapt the fields per job:

````
Your final message is the return value — read by a program, not a person. Emit one fenced
json block; anything outside it is ignored. This holds for every reply you make, not only
your first.

```json
{
  "outcome": "DONE | BLOCKED | FAILED | QUESTION",
  "files": ["path — what changed"],
  "evidence": "if not DONE, the single most decisive line, quoted exactly, else null"
}
```

If you need a decision I have not given you, do not guess and do not stop: message me with
the question while you work, or return `QUESTION` with it in `evidence`. Asking costs one
exchange; guessing costs the step.
````

Keep the fields few and the values short. `files` is one line per path; `evidence` is one
line, never a log or a diff. If a field would run long, the job was too big — that is worth
knowing, and a fixed shape is what tells you.

`QUESTION` is not a failure and is cheaper than either alternative. A member that guesses
produces work you have to unpick; a member that stalls burns the run's wall-clock and
reports nothing. Judging the question is your job — you hold the plan and the conversation
— so make asking the obviously licensed move.

## While work is outstanding

Dispatching is asynchronous. The tool call returns before the work is done and the result
arrives later, so "I delegated it" and "I have the answer" are different states and must not
blur together.

- **Keep a ledger.** When you dispatch, say what is outstanding and what each member was
  asked for. Two named members with similar jobs are indistinguishable a few turns later
  unless you wrote it down. There is no shared task list to fall back on — the ledger is
  the only record there is.
- **Never end a turn as though the work is done** while members are still running. Say
  what is pending instead.
- **Never infer a result that has not arrived.** No notification means still running, not
  finished-and-probably-fine. Reconcile each report against the ledger before acting on it,
  and if you cannot tell which job a report belongs to, ask the member rather than guessing.

**Reports are not the only thing that arrives.** A teammate can message you mid-work,
unprompted — a question, a partial finding, something it hit that the prompt did not cover.
That is not noise and not a report: it is a member doing the right thing instead of
guessing. Answer it, note it against the ledger, and do not treat the job as finished until
its idle notification actually lands.

When a member goes quiet, what you have is the ledger, `SendMessage` to poke a named one,
and `TaskStop` to kill a hung one by name so you can re-dispatch. **`ListAgents` is not the
tool for this** — in this session it lists other Claude sessions, not the members you
spawned, and members do not have it at all.

**Never read a subagent task's `.output` file.** It is a symlink to that member's entire
conversation transcript as JSONL, and reading it will overflow this window — destroying the
exact thing every rule here exists to protect. Chasing a lost report is precisely when the
file looks tempting. If a report never came, poke the member; if that fails, stop it and
re-dispatch.

## Relaying

The user never sees a member's report. Whatever mattered in it, you say — in your own
words, at the size the moment deserves. Pasting the report through defeats the whole
exercise: it lands in your context _and_ theirs.

Report faithfully. If a member came back BLOCKED, say so plainly and say what it hit;
never smooth a failed step into progress.
