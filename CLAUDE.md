# agent-plugins — instructions

Kim Birkelund's Claude Code plugin marketplace. One marketplace manifest at the repository
root (`.claude-plugin/marketplace.json`, marketplace name `agent-plugins`), one directory
per plugin beside it.

## Shipping a change: the repository is the publish boundary

The marketplace is registered from this repository's **git remote**, not from this
directory, so Claude Code installs from a pushed commit. Editing a skill here changes
nothing in any session until the change is shipped — that is the point: work in progress is
not live.

Shipping is one command:

```pwsh
./Update-ClaudePlugin.ps1 <plugin> [Major|Minor|Patch|x.y.z]
```

It bumps the plugin's `version`, commits only that `plugin.json`, pushes, runs
`claude plugin marketplace update agent-plugins` so the marketplace clone fetches the new
commit, and then `claude plugin update <plugin>@agent-plugins`. `-WhatIf` shows what it
would do; `-SkipPush` and `-SkipUpdate` stop it part way.

**Bump `version` for every change you want to ship.** `claude plugin update` compares
nothing else, so an unbumped change reports "already at the latest version" and leaves the
installed snapshot stale, with no error.

Validate before shipping: `claude plugin validate .` for the marketplace manifest,
`claude plugin validate ./<plugin>` for a plugin manifest.

## Format and lint everything you write

Before considering any change complete, run the formatter **and** the linter for that
file's language and fix what they report.

| Language                            | Format                                                       | Lint                                                              |
| ----------------------------------- | ------------------------------------------------------------ | ----------------------------------------------------------------- |
| PowerShell (`.ps1` `.psm1` `.psd1`) | `Invoke-Formatter -Settings ./PSScriptAnalyzerSettings.psd1` | `Invoke-ScriptAnalyzer -Settings ./PSScriptAnalyzerSettings.psd1` |
| JSON / YAML / Markdown              | `prettier --write <file>`                                    | —                                                                 |

- `PSScriptAnalyzerSettings.psd1` (repo root) is the source of truth for PowerShell style
  (Allman braces, 4-space indent, aligned assignments, correct casing). Format in place:
  `Set-Content $f (Invoke-Formatter -ScriptDefinition (Get-Content -Raw $f) -Settings ./PSScriptAnalyzerSettings.psd1) -NoNewline`
- The formatter's output is canonical. When the formatter is at a fixpoint but the linter
  still complains, the linter loses — notably `PSUseConsistentWhitespace` flags the aligned
  `=` columns that `PSAlignAssignmentStatement` deliberately produces. Leave those.

## PowerShell scripts: never dot-source another script

A script must **not** dot-source another to reuse its functions. The only exception is a
`*.Tests.ps1` file, which dot-sources the script under test.

Call the other script as a command instead, passing what it needs as parameters — the way
`planning/scripts/Get-PlanList.ps1` calls `Get-PlanContext.ps1`. Dot-sourcing couples
scripts to each other's load order and leaks every function into the caller's scope.

## PowerShell scripts: keep Pester tests alongside them

When you create or edit a script, add or update its tests in the same change. A behavior
change without a test change is incomplete.

- **Location & naming**: `<ScriptName>.Tests.ps1`, next to the script. Pester v5 syntax
  (`Should -Be`, `Should -Throw` — the dashed operators).
- **What to cover**: every scenario you exercised while building — happy paths, each
  branch, guards that `throw`, and `-WhatIf` dry-runs.
- **Isolation**: never touch the real `~/code`, `~/.config` or the installed plugins.
  Redirect scripts at a temp code root via `$env:__CODE_ROOT` (config via
  `$env:XDG_CONFIG_HOME`), use `$TestDrive` for fixtures, shim `claude` and `git` remotes
  locally. Keep tests offline — bare repositories on disk, never the network.
- **Avoid `<...>` in `It`/`Describe`/`Context` names** — Pester reads angle brackets as
  `-ForEach` placeholders.
- **`BeforeEach`/`AfterEach` must live inside a `Describe`/`Context`** — Pester v5 rejects
  them at file-root scope.

## Running the tests

```pwsh
./Invoke-PesterTests.ps1                                   # every *.Tests.ps1 in the repo
./Invoke-PesterTests.ps1 -Path ./planning/scripts/Get-PlanList.Tests.ps1
```

The runner installs Pester v5 for the current user if it is missing and exits non-zero when
any test fails. Run it before shipping.

## Skills shared with `~/.claude/skills`

Cross-references between skills must stay sibling-relative
(`../pln/references/execution.md`), never `~/.claude/skills/...`, so a skill keeps working
wherever it is copied.
