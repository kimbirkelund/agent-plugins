@{
    # Source of truth for PowerShell formatting. Mirrors .vscode powershell.codeFormatting.*
    # Consumed by Invoke-Formatter -Settings (nvim/conform, CLI).
    # VSCode does NOT read this file for formatting; keep .vscode settings in sync by hand.
    # GAP: .vscode autoCorrectAliases expands aliases (gci -> Get-ChildItem). Invoke-Formatter
    #      does NOT expand aliases (PSAvoidUsingCmdletAliases is diagnostic-only), so the
    #      nvim/CLI path leaves aliases untouched. No psd1 setting closes this.
    IncludeRules = @(
        'PSPlaceOpenBrace'
        'PSPlaceCloseBrace'
        'PSUseConsistentWhitespace'
        'PSUseConsistentIndentation'
        'PSAlignAssignmentStatement'
        'PSUseCorrectCasing'
        'PSAvoidUsingDoubleQuotesForConstantString'
    )
    Rules        = @{
        # preset = Allman, openBraceOnSameLine = false
        PSPlaceOpenBrace                       = @{
            Enable             = $true
            OnSameLine         = $false
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }
        PSPlaceCloseBrace                      = @{
            Enable             = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore  = $false
        }
        # pipelineIndentationStyle = IncreaseIndentationForFirstPipeline
        PSUseConsistentIndentation             = @{
            Enable              = $true
            Kind                = 'space'
            IndentationSize     = 4
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
        }
        # trimWhitespaceAroundPipe + whitespaceBetweenParameters
        PSUseConsistentWhitespace              = @{
            Enable                                  = $true
            CheckInnerBrace                         = $true
            CheckOpenBrace                          = $true
            CheckOpenParen                          = $true
            CheckOperator                           = $true
            CheckPipe                               = $true
            CheckPipeForRedundantWhitespace         = $true
            CheckSeparator                          = $true
            CheckParameter                          = $true
        }
        PSAlignAssignmentStatement             = @{
            Enable         = $true
            CheckHashtable = $true
        }
        # useCorrectCasing
        PSUseCorrectCasing                     = @{
            Enable = $true
        }
        # useConstantStrings
        PSAvoidUsingDoubleQuotesForConstantString = @{
            Enable = $true
        }
    }
}
