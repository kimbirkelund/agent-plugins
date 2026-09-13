# agent-plugins

Kim Birkelund's personal [Claude Code](https://claude.ai/code) plugin marketplace.

| Plugin     | Does                                                                                                                                                                                                              |
| ---------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `planning` | Plan-driven workflow: capture a plan in its own git repository, run it with a delegated team in a worktree of its own, and file the conversations that produced it. See [planning/README.md](planning/README.md). |

## Install

```sh
claude plugin marketplace add https://github.com/kimbirkelund/agent-plugins.git
claude plugin install planning@agent-plugins
```

## Develop

Clone it, edit a plugin, and nothing changes in any session until the change is shipped —
the marketplace installs from a pushed commit, not from a working tree.

```pwsh
./Invoke-PesterTests.ps1                          # Pester v5 suite for every script
claude plugin validate .                          # marketplace manifest
claude plugin validate ./planning                 # plugin manifest
./Update-ClaudePlugin.ps1 planning Minor          # bump, commit, push, refresh, update
```

`CLAUDE.md` carries the conventions: formatting, tests beside scripts, and why the version
bump is the promote gesture.

## License

MIT — see [LICENSE](LICENSE).
