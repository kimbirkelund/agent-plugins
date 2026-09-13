---
name: rewrt
description: Consume `∫∫...∫∫` markers the user has written into files — carry out the requests, answer the questions in chat, delete the markers. Runs over a session-scoped set of files that grows as you name them and that picks up marked, changed files automatically inside a repository. Use when the user types /rewrt.
argument-hint: "[file to add to the set — omit to sweep the files already in it]"
disable-model-invocation: true
---

# Rewrite

The user has written notes into their own files, wrapped in `∫∫` on both sides — `∫∫why not reuse the existing parser here?∫∫`, `∫∫split this paragraph in two∫∫`, `∫∫this name is wrong, it's a queue not a stack∫∫`. Each one is a piece of the conversation moved into the margin, put where pointing is easier than describing. Your job is to consume them: do what they ask, answer what they ask, and take them out of the file.

## Why this exists

Feedback is easier to give in place than in prose. Saying "in the third paragraph of the design section, the one about retries, the tone is off" costs more than typing `∫∫tone∫∫` next to it — and the second is more precise. The marker is the user pointing at something.

## The set

The set is session state — it lives in this conversation, not on disk, and it ends when the session does. Nothing is written to track it.

The set consists of two things

- Files explicitly added by running **`/rewrt path/to/file`** (where path to file can also be something you need to interpret)
- The files reported by git as having changes; run `git status --porcelain -z --untracked-files=all` to find these (just ignore deleted files)

## Read everything before you write anything

Read every file in the sweep, and collect every marker in all of them — `grep -rn '∫∫'` finds them — before making a single edit.

This is not tidiness. Markers interact: two can contradict each other, one can be answered by another, and a marker asking you to unify something can only be honoured once you have seen both halves. Editing the first file before you have read the third means discovering the conflict after you have already committed to one side of it.

Note where each marker sits, too. Position is part of the message — `∫∫too long∫∫` at the head of a section means the section, and the same three words in the middle of a paragraph mean that sentence.

## Handling a marker

A marker is a prompt. Not a special kind of input with its own protocol — the same message the user would have typed in the chat, written where they were looking instead of described from a distance. `∫∫this repeats the point above∫∫` at the end of a paragraph is the user saying "this repeats the point above" and pointing; the only thing the file adds is that you do not have to work out which paragraph they meant.

So respond as you would to any prompt. Do what is asked. Push back when you think it is wrong, ask when it is unclear, answer a question in your reply rather than silently editing the file to reflect a conclusion the user never read — all of it exactly as it would go in the conversation, because there is nothing different about it.

What the medium adds is bookkeeping. A marker is input, not content, so once you have dealt with it, it comes out of the file. One still sitting there after you have written means it was not handled — a legitimate outcome when you disagreed or the question is open, but never a silent one.

### Deleting a marker cleanly

Markers are written raw into the file, wherever the user was pointing — dropped into a sentence, or sitting alone on a line between two paragraphs. They are not comments and are not styled to fit the surrounding syntax. In a source file that means the marker is very likely breaking the parse, which is fine and temporary: it is scratch, and the user expects it gone.

So take the marker and whatever whitespace existed only to hold it. A marker alone on a line takes the line, and the blank line beside it if that blank was only separating it from the text. A marker inline in a sentence leaves the sentence reading as one sentence — mind the spacing and the punctuation on either side.

Occasionally a marker does turn up inside a comment the user already had — `// FIXME: ∫∫is this still true?∫∫`. Keep the comment's own content and remove only the marker; if nothing is left but the comment leader, the comment goes too.

Afterwards the file should read as though the marker was never there, and — for source files — parse again.

## Leave the files in the state the project expects

If the project defines formatting and linting for a file you touched — a `CLAUDE.md` that names the commands, a config in the repository root — run them on that file and fix what they report. A rewrite that leaves the tree failing its own checks is not finished.

That is where your involvement in verification ends. Do not take on a build or a test cycle of your own — a sweep is a set of margin edits, and turning one into a full verification run buries the conversation the markers were part of. If a change genuinely needs proving, say so in your report and let the user decide how.

## Reporting back

Say, per file, what changed — in your own words, briefly. The user should not have to diff to learn what you did.

Two parts of the report are not compressible:

- **Answers to questions.** They are the thing the user was waiting for. "Handled your question" is not an answer.
- **Markers you left in place**, and why. Each one is a disagreement or an open question, and it is now waiting on the user.

Finish with the set as it now stands, so a bare `/rewrt` next time is predictable: which files are sticky members, which came in from the working tree this sweep, and which are clean.
