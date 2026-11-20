# agent-plugins

Kim Birkelund's personal [Claude Code](https://claude.ai/code) plugin
marketplace.

| Plugin         | Does                                                                                                                                                                                                              |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `planning`     | Plan-driven workflow: capture a plan in its own git repository, run it with a delegated team in a worktree of its own, and file the conversations that produced it. See [planning/README.md](planning/README.md). |
| `tdd-workflow` | Test-driven development: a skill that makes code changes follow a strict one-test-at-a-time workflow, with a prediction and a commit before every run. See [tdd-workflow/README.md](tdd-workflow/README.md).      |

## Install

```sh
claude plugin marketplace add https://github.com/kimbirkelund/agent-plugins.git
claude plugin install planning@agent-plugins
claude plugin install tdd-workflow@agent-plugins
```

## Develop

Clone it, edit a plugin, and nothing changes in any session until the change is
shipped — the marketplace installs from a pushed commit, not from a working
tree.

```pwsh
./Invoke-PesterTests.ps1                          # Pester v5 suite for every script
claude plugin validate .                          # marketplace manifest
claude plugin validate ./planning                 # plugin manifest
claude plugin validate ./tdd-workflow             # plugin manifest
./Update-ClaudePlugin.ps1 planning Minor          # bump, commit, push, refresh, update
```

Formatting and linting run automatically as Claude Code hooks
(`.claude/settings.json`, scripts in `Scripts/claude-hooks/`).

`CLAUDE.md` carries the conventions: formatting, tests beside scripts, and why
the version bump is the promote gesture.

## License

MIT — see [LICENSE](LICENSE).
