# tdd-workflow

Test-driven development as a Claude Code skill. One skill, `tdd`, makes code
changes follow a strict test-driven workflow, one test at a time.

## The skill

| Skill | Does                                                                                                                                                                                                               |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `tdd` | Writes a test list, then works through it one test at a time: write one test, see it fail, make it pass, refactor or decide none is needed, update the list. Predicts and commits before every build and test run. |

## When it triggers

Claude loads the skill on its own, through its description; there is no hook and
no command. It applies when work starts that changes the behaviour of code (a
feature, a bug fix, a refactor, however small) and when a plan is written for
such work, so the plan gets a test list. It applies even when nobody mentions
tests. It does not apply to documentation, configuration or pure removal of
unused code.

## The test list

The list is written up front, one entry per test, grouped by unit of work. It
lives in the written plan when one drives the work, otherwise in the
conversation, shown to the user before the first test.

| Marker       | Means                                                                                   |
| ------------ | --------------------------------------------------------------------------------------- |
| `[ ]`        | To do.                                                                                  |
| `[x]`        | Its cycle is finished.                                                                  |
| `(may pass)` | Expected to pass on its first run; still proven by breaking the production code.        |
| ~~struck~~   | Wrong or redundant, struck through with the reason. Entries are never dropped silently. |

## Commits

Every build and test run is preceded by a commit of the tree as it is about to
be built, with the prediction as the message. These commits are a working log:
many are red or do not compile on purpose, and nobody verifies them one by one.

When the work is finished, the history is rewritten, with the user, into the
commits a reviewer reads. Each final commit is one logical unit, either
structural or behavioural, and builds and passes the whole test suite on its
own. The tree after the rewrite is identical to the tree before it.

The skill commits on whatever branch is checked out. It does not create branches
or push.

## Sources

The workflow builds on two articles by Kent Beck:

- [Canon TDD](https://newsletter.kentbeck.com/p/canon-tdd)
- [Augmented Coding: Beyond the Vibes](https://newsletter.kentbeck.com/p/augmented-coding-beyond-the-vibes)

## Install

```sh
claude plugin marketplace add https://github.com/kimbirkelund/agent-plugins.git
claude plugin install tdd-workflow@agent-plugins
```
