# slimer: Pester 5 tests for the pure functions in slimer.psm1.
#
# UNTESTED: these tests were written without PowerShell and have never been
# run. Run them with:
#
#   Invoke-Pester -Path src/shell-integration/powershell/tests
#
# The module is imported with the Ghostty environment variables cleared, so
# it does not wrap the prompt of the session running the tests. Private
# functions are called inside the module's scope with `& $M { ... }`.
#
# Requires PowerShell 7 (this file contains UTF-8 literals without a BOM,
# which Windows PowerShell 5.1 would misread) and Pester 5.

BeforeAll {
    $env:TERM_PROGRAM = $null
    $env:GHOSTTY_RESOURCES_DIR = $null
    $modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'slimer.psm1'
    $script:M = Import-Module $modulePath -Force -PassThru
    $script:ESC = [string][char]0x1b
    $script:BEL = [string][char]0x07
}

AfterAll {
    Remove-Module slimer -Force -ErrorAction Ignore
}

Describe 'activation guard' {
    It 'does not wrap the prompt outside Ghostty' {
        $status = Get-SlimerIntegrationStatus
        $status.Enabled | Should -BeFalse
        $status.PromptWrapped | Should -BeFalse
    }
}

Describe 'Test-SlimerFeature' {
    It 'matches whole comma-separated names only' {
        & $M { Test-SlimerFeature -Features 'cursor,title,autocomplete' -Name 'title' } | Should -BeTrue
        & $M { Test-SlimerFeature -Features 'cursor, title' -Name 'title' } | Should -BeTrue
        & $M { Test-SlimerFeature -Features 'subtitle' -Name 'title' } | Should -BeFalse
        & $M { Test-SlimerFeature -Features '' -Name 'title' } | Should -BeFalse
        & $M { Test-SlimerFeature -Features $null -Name 'title' } | Should -BeFalse
    }
}

Describe 'OSC builders' {
    It 'builds prompt marks' {
        & $M { Get-SlimerPromptMark -Kind A } | Should -BeExactly "$ESC]133;A$BEL"
        & $M { Get-SlimerPromptMark -Kind B } | Should -BeExactly "$ESC]133;B$BEL"
        & $M { Get-SlimerPromptMark -Kind C } | Should -BeExactly "$ESC]133;C$BEL"
        & $M { Get-SlimerPromptMark -Kind D } | Should -BeExactly "$ESC]133;D$BEL"
        & $M { Get-SlimerPromptMark -Kind D -ExitCode 0 } | Should -BeExactly "$ESC]133;D;0$BEL"
        & $M { Get-SlimerPromptMark -Kind D -ExitCode 127 } | Should -BeExactly "$ESC]133;D;127$BEL"
    }

    It 'strips control characters from titles and caps them' {
        $t = & $M { New-SlimerTitleSequence -Title ("a" + [char]0x1b + "]52;c;x" + [char]7 + "b") }
        $t | Should -BeExactly "$ESC]2;a]52;c;xb$BEL"
        $long = & $M { New-SlimerTitleSequence -Title ('x' * 300) }
        # ESC ] 2 ; <256 characters> BEL
        $long.Length | Should -Be (256 + 5)
    }

    It 'builds the shell self-report and sanitizes values' {
        $r = & $M {
            New-SlimerShellReport -Fields ([ordered]@{
                    shell = 'pwsh'; version = '7.4.6'; edition = 'Core'; os = 'windows'
                })
        }
        $r | Should -BeExactly "$ESC]7706;shell=pwsh;version=7.4.6;edition=Core;os=windows$BEL"

        $bad = & $M {
            New-SlimerShellReport -Fields ([ordered]@{
                    shell = "pw;sh$([char]7)"; BadKey = 'x'; distro = 'Ubuntu 24.04'
                })
        }
        $bad | Should -BeExactly "$ESC]7706;shell=pwsh;distro=Ubuntu24.04$BEL"
    }

    It 'reports this shell' {
        $f = & $M { Get-SlimerShellReportFields }
        $f.shell | Should -Be 'pwsh'
        $f.edition | Should -BeIn @('Core', 'Desktop')
        $f.os | Should -BeIn @('windows', 'macos', 'linux', 'unknown')
    }
}

Describe 'OSC 7' {
    It 'converts Windows drive paths' {
        & $M { ConvertTo-SlimerOsc7Uri -ProviderPath 'C:\Users\me' -HostName 'box' } |
            Should -BeExactly 'kitty-shell-cwd://box/C:/Users/me'
        & $M { ConvertTo-SlimerOsc7Uri -ProviderPath 'C:\' -HostName 'box' } |
            Should -BeExactly 'kitty-shell-cwd://box/C:/'
        & $M { ConvertTo-SlimerOsc7Uri -ProviderPath 'd:\a b\c' -HostName 'box' } |
            Should -BeExactly 'kitty-shell-cwd://box/d:/a b/c'
    }

    It 'keeps Unix paths and percent-encodes only the file scheme' {
        & $M { ConvertTo-SlimerOsc7Uri -ProviderPath '/home/me/a b' -HostName 'box' } |
            Should -BeExactly 'kitty-shell-cwd://box/home/me/a b'
        & $M { ConvertTo-SlimerOsc7Uri -ProviderPath '/home/me/a b%#é' -HostName 'box' -Scheme file } |
            Should -BeExactly 'file://box/home/me/a%20b%25%23%C3%A9'
        & $M { ConvertTo-SlimerOsc7Uri -ProviderPath 'C:\x y' -HostName 'box' -Scheme file } |
            Should -BeExactly 'file://box/C:/x%20y'
    }

    It 'strips control characters from the path and host' {
        $p = '/tmp/x' + [char]7 + [char]0x1b + ']52;c;SGk=' + [char]7
        & $M { param($p) ConvertTo-SlimerOsc7Uri -ProviderPath $p -HostName ("bo" + [char]0x1b + "x") } $p |
            Should -BeExactly 'kitty-shell-cwd://box/tmp/x]52;c;SGk='
    }

    It 'skips UNC, relative and empty paths' {
        & $M { ConvertTo-SlimerOsc7Uri -ProviderPath '\\server\share\dir' -HostName 'box' } | Should -BeNullOrEmpty
        & $M { ConvertTo-SlimerOsc7Uri -ProviderPath '\\?\C:\x' -HostName 'box' } | Should -BeNullOrEmpty
        & $M { ConvertTo-SlimerOsc7Uri -ProviderPath 'relative\dir' -HostName 'box' } | Should -BeNullOrEmpty
        & $M { ConvertTo-SlimerOsc7Uri -ProviderPath '' -HostName 'box' } | Should -BeNullOrEmpty
        & $M { New-SlimerOsc7 -ProviderPath '\\server\share' -HostName 'box' } | Should -BeExactly ''
    }

    It 'wraps the URI in OSC 7' {
        & $M { New-SlimerOsc7 -ProviderPath 'C:\w' -HostName 'box' } |
            Should -BeExactly "$ESC]7;kitty-shell-cwd://box/C:/w$BEL"
    }
}

Describe 'Get-SlimerDirectoryTitle' {
    It 'uses the leaf, ~ for home, and the path for roots' {
        & $M { Get-SlimerDirectoryTitle -ProviderPath 'C:\Users\me\Dev\slimer' -HomePath 'C:\Users\me' } | Should -BeExactly 'slimer'
        & $M { Get-SlimerDirectoryTitle -ProviderPath 'C:\Users\me' -HomePath 'C:\Users\me' } | Should -BeExactly '~'
        & $M { Get-SlimerDirectoryTitle -ProviderPath 'C:\' -HomePath 'C:\Users\me' } | Should -BeExactly 'C:\'
        & $M { Get-SlimerDirectoryTitle -ProviderPath '/' -HomePath '/home/me' } | Should -BeExactly '/'
        & $M { Get-SlimerDirectoryTitle -ProviderPath '/home/me/src/' -HomePath '/home/me' } | Should -BeExactly 'src'
    }
}

Describe 'Get-SlimerExitCode' {
    It 'is 0 on success even with a stale native exit code' {
        & $M { Get-SlimerExitCode -Success $true -LastExitCode 3 -PreviousLastExitCode 3 -NewErrorRecord $false } | Should -Be 0
    }
    It 'uses $LASTEXITCODE for a native failure' {
        & $M { Get-SlimerExitCode -Success $false -LastExitCode 2 -PreviousLastExitCode 0 -NewErrorRecord $false } | Should -Be 2
    }
    It 'uses $LASTEXITCODE for the same native failure twice' {
        & $M { Get-SlimerExitCode -Success $false -LastExitCode 2 -PreviousLastExitCode 2 -NewErrorRecord $false } | Should -Be 2
    }
    It 'uses $LASTEXITCODE when native errors raise ErrorRecords' {
        & $M { Get-SlimerExitCode -Success $false -LastExitCode 5 -PreviousLastExitCode 0 -NewErrorRecord $true } | Should -Be 5
    }
    It 'is 1 for a cmdlet failure with a stale native exit code' {
        & $M { Get-SlimerExitCode -Success $false -LastExitCode 2 -PreviousLastExitCode 2 -NewErrorRecord $true } | Should -Be 1
    }
    It 'is 1 for a cmdlet failure without any native command' {
        & $M { Get-SlimerExitCode -Success $false -LastExitCode $null -PreviousLastExitCode $null -NewErrorRecord $true } | Should -Be 1
        & $M { Get-SlimerExitCode -Success $false -LastExitCode 0 -PreviousLastExitCode $null -NewErrorRecord $true } | Should -Be 1
    }
}

Describe 'percent encoding' {
    It 'encodes like the zsh integration' {
        & $M { ConvertTo-SlimerPercentEncoding -Text 'git commit -m "a;b" 100%' } |
            Should -BeExactly 'git commit -m "a%3Bb" 100%25'
        & $M { ConvertTo-SlimerPercentEncoding -Text ("a" + [char]0 + [char]9 + [char]0x1b + [char]0x7f + "b") } |
            Should -BeExactly 'a%00%09%1B%7Fb'
    }

    It 'passes UTF-8 through raw by default' {
        & $M { ConvertTo-SlimerPercentEncoding -Text 'café 😀' } | Should -BeExactly 'café 😀'
    }

    It 'encodes C1 controls' {
        & $M { ConvertTo-SlimerPercentEncoding -Text ("x" + [char]0x9c + "y") } | Should -BeExactly 'x%C2%9Cy'
    }

    It 'encodes all non-ASCII as UTF-8 bytes with -AsciiOnly' {
        & $M { ConvertTo-SlimerPercentEncoding -Text 'é😀;' -AsciiOnly } | Should -BeExactly '%C3%A9%F0%9F%98%80%3B'
    }

    It 'returns an empty string for empty input' {
        & $M { ConvertTo-SlimerPercentEncoding -Text '' } | Should -BeExactly ''
    }

    It 'decodes either hex case and raw characters' {
        & $M { ConvertFrom-SlimerPercentEncoding -Payload '%61%3b%3B%25b' } | Should -BeExactly 'a;;%b'
        & $M { ConvertFrom-SlimerPercentEncoding -Payload '%C3%A9t%C3%A9' } | Should -BeExactly 'été'
        & $M { ConvertFrom-SlimerPercentEncoding -Payload 'plain' } | Should -BeExactly 'plain'
        & $M { ConvertFrom-SlimerPercentEncoding -Payload '' } | Should -BeExactly ''
    }

    It 'rejects malformed escapes and invalid UTF-8' {
        & $M { ConvertFrom-SlimerPercentEncoding -Payload '%' } | Should -BeNullOrEmpty
        & $M { ConvertFrom-SlimerPercentEncoding -Payload '%4' } | Should -BeNullOrEmpty
        & $M { ConvertFrom-SlimerPercentEncoding -Payload '%zz' } | Should -BeNullOrEmpty
        & $M { ConvertFrom-SlimerPercentEncoding -Payload '%C3' } | Should -BeNullOrEmpty
        & $M { ConvertFrom-SlimerPercentEncoding -Payload '%FF%FE' } | Should -BeNullOrEmpty
    }

    It 'round-trips' {
        foreach ($s in @('ls -la', 'echo "x;y" % 100', ("tab" + [char]9 + "nl" + [char]10), 'ünï 😀')) {
            $enc = & $M { param($s) ConvertTo-SlimerPercentEncoding -Text $s } $s
            & $M { param($e) ConvertFrom-SlimerPercentEncoding -Payload $e } $enc | Should -BeExactly $s
            $enc2 = & $M { param($s) ConvertTo-SlimerPercentEncoding -Text $s -AsciiOnly } $s
            & $M { param($e) ConvertFrom-SlimerPercentEncoding -Payload $e } $enc2 | Should -BeExactly $s
        }
    }
}

Describe 'truncation and cursor' {
    It 'does not truncate short text' {
        $r = & $M { Limit-SlimerUtf8 -Text 'abc' -MaxBytes 4096 }
        $r.Text | Should -BeExactly 'abc'
        $r.Truncated | Should -BeFalse
    }

    It 'truncates to the byte limit on a code point boundary' {
        $r = & $M { Limit-SlimerUtf8 -Text ('a' * 5000) -MaxBytes 4096 }
        $r.Text.Length | Should -Be 4096
        $r.Truncated | Should -BeTrue

        # 'é' is 2 bytes: 4095 + 2 > 4096, so it is dropped whole.
        $r = & $M { Limit-SlimerUtf8 -Text (('a' * 4095) + 'é') -MaxBytes 4096 }
        $r.Text | Should -BeExactly ('a' * 4095)
        $r.Truncated | Should -BeTrue

        # A surrogate pair (4 bytes) is never split.
        $r = & $M { Limit-SlimerUtf8 -Text (('a' * 4094) + '😀') -MaxBytes 4096 }
        $r.Text | Should -BeExactly ('a' * 4094)
    }

    It 'counts code points, not UTF-16 units' {
        & $M { Get-SlimerCodePointCount -Text 'a😀b' -Length 3 } | Should -Be 2
        & $M { Get-SlimerCodePointCount -Text 'a😀b' -Length 4 } | Should -Be 3
        & $M { Get-SlimerCodePointCount -Text 'abc' -Length 99 } | Should -Be 3
        & $M { Get-SlimerCodePointCount -Text '' -Length 0 } | Should -Be 0
    }
}

Describe 'New-SlimerAutocompleteReport' {
    It 'builds a report with token and pid' {
        $r = & $M {
            New-SlimerAutocompleteReport -Buffer 'git ch;x' -Cursor 6 -Keymap emacs `
                -Token '0123456789abcdef0123456789abcdef' -ProcessId 4242
        }
        $r | Should -BeExactly "$ESC]7704;v=1;n=0123456789abcdef0123456789abcdef;p=4242;c=6;k=emacs;t=0;b=git ch%3Bx$BEL"
    }

    It 'omits n= without a token and maps bad keymaps to other' {
        $r = & $M { New-SlimerAutocompleteReport -Buffer 'ls' -Cursor 2 -Keymap 'bad key!' }
        $r | Should -BeExactly "$ESC]7704;v=1;c=2;k=other;t=0;b=ls$BEL"
    }

    It 'builds a deactivate report' {
        $r = & $M { New-SlimerAutocompleteReport -Deactivate -Buffer 'ignored' -Cursor 3 -Token 'abc' -ProcessId 7 }
        $r | Should -BeExactly "$ESC]7704;v=1;n=abc;p=7;d=1;c=0;k=emacs;t=0;b=$BEL"
    }

    It 'truncates long buffers and sets t=1' {
        $r = & $M { New-SlimerAutocompleteReport -Buffer ('x' * 5000) -Cursor 5000 }
        $r | Should -Match ';c=5000;k=emacs;t=1;b=x{4096}\x07$'
    }

    It 'uses a code point cursor and clamps it' {
        & $M { New-SlimerAutocompleteReport -Buffer '😀a' -Cursor 3 } | Should -Match ';c=2;'
        & $M { New-SlimerAutocompleteReport -Buffer 'ab' -Cursor 99 } | Should -Match ';c=2;'
        & $M { New-SlimerAutocompleteReport -Buffer 'ab' -Cursor -5 } | Should -Match ';c=0;'
    }

    It 'never contains a raw control character inside the OSC' {
        $buf = -join ((0..31) + 127 + 0x9b | ForEach-Object { [char]$_ })
        $r = & $M { param($b) New-SlimerAutocompleteReport -Buffer $b -Cursor 0 } $buf
        $inner = $r.Substring(2, $r.Length - 3)
        $inner | Should -Not -Match '[\x00-\x1F\x7F-\x9F]'
    }
}

Describe 'Test-SlimerSafeText' {
    It 'accepts ordinary text' {
        & $M { Test-SlimerSafeText -Text 'checkout' } | Should -BeTrue
        & $M { Test-SlimerSafeText -Text 'café 😀' } | Should -BeTrue
    }
    It 'rejects empty, oversized and control text' {
        & $M { Test-SlimerSafeText -Text '' } | Should -BeFalse
        & $M { Test-SlimerSafeText -Text ('a' * 4097) } | Should -BeFalse
        & $M { Test-SlimerSafeText -Text ("a" + [char]10) } | Should -BeFalse
        & $M { Test-SlimerSafeText -Text ("a" + [char]0x7f) } | Should -BeFalse
        & $M { Test-SlimerSafeText -Text ("a" + [char]0x85) } | Should -BeFalse
    }
    It 'rejects bidi controls, line separators and lone surrogates' {
        foreach ($cp in 0x202A, 0x202E, 0x2066, 0x2069, 0x200B, 0x2028, 0x2029, 0xFEFF) {
            & $M { param($c) Test-SlimerSafeText -Text ("a" + [char]$c) } $cp | Should -BeFalse
        }
        & $M { Test-SlimerSafeText -Text ("a" + [char]0xD83D) } | Should -BeFalse
        & $M { Test-SlimerSafeText -Text ([string][char]0xDE00) } | Should -BeFalse
    }
}

Describe 'Get-SlimerTokenRange' {
    It 'returns an empty range at the start, after whitespace and after operators' {
        foreach ($case in @(
                @{ Line = ''; Cursor = 0 },
                @{ Line = 'git '; Cursor = 4 },
                @{ Line = 'ls |'; Cursor = 4 },
                @{ Line = 'a;'; Cursor = 2 },
                @{ Line = 'Get-Item ('; Cursor = 10 },
                @{ Line = 'x >'; Cursor = 3 }
            )) {
            $r = & $M { param($l, $c) Get-SlimerTokenRange -Line $l -Cursor $c } $case.Line $case.Cursor
            $r.Start | Should -Be $case.Cursor -Because "line '$($case.Line)'"
            $r.Length | Should -Be 0 -Because "line '$($case.Line)'"
        }
    }

    It 'finds the word before the cursor' {
        $r = & $M { Get-SlimerTokenRange -Line 'git chec' -Cursor 8 }
        $r.Start | Should -Be 4
        $r.Length | Should -Be 4
    }

    It 'finds the command name' {
        $r = & $M { Get-SlimerTokenRange -Line 'Get-Chi' -Cursor 7 }
        $r.Start | Should -Be 0
        $r.Length | Should -Be 7
    }

    It 'finds parameters, variables and quoted strings' {
        (& $M { Get-SlimerTokenRange -Line 'Get-ChildItem -Rec' -Cursor 18 }).Start | Should -Be 14
        (& $M { Get-SlimerTokenRange -Line 'echo $env:PA' -Cursor 12 }).Start | Should -Be 5
        $r = & $M { Get-SlimerTokenRange -Line "cd 'C:\Program Fi" -Cursor 17 }
        $r.Start | Should -Be 3
        $r.Length | Should -Be 14
    }

    It 'only replaces up to the cursor' {
        $r = & $M { Get-SlimerTokenRange -Line 'git checkout main' -Cursor 8 }
        $r.Start | Should -Be 4
        $r.Length | Should -Be 4
    }

    It 'finds the word after a pipe' {
        $r = & $M { Get-SlimerTokenRange -Line 'ls | Sel' -Cursor 8 }
        $r.Start | Should -Be 5
        $r.Length | Should -Be 3
    }

    It 'clamps the cursor' {
        $r = & $M { Get-SlimerTokenRange -Line 'abc' -Cursor 99 }
        $r.Start | Should -Be 0
        $r.Length | Should -Be 3
        $r = & $M { Get-SlimerTokenRange -Line 'abc' -Cursor -1 }
        $r.Start | Should -Be 0
        $r.Length | Should -Be 0
    }
}

Describe 'ConvertTo-SlimerShellWord' {
    It 'keeps plain words raw' {
        foreach ($w in 'checkout', '-Recurse', 'C:\Users\me\file.txt', './src/main.zig', 'a=b', 'origin/main') {
            & $M { param($w) ConvertTo-SlimerShellWord -Text $w } $w | Should -BeExactly $w
        }
    }
    It 'single-quotes everything else and doubles quotes' {
        & $M { ConvertTo-SlimerShellWord -Text 'my file' } | Should -BeExactly "'my file'"
        & $M { ConvertTo-SlimerShellWord -Text "it's" } | Should -BeExactly "'it''s'"
        & $M { ConvertTo-SlimerShellWord -Text '$(rm -rf ~)' } | Should -BeExactly "'`$(rm -rf ~)'"
        & $M { ConvertTo-SlimerShellWord -Text 'a;b' } | Should -BeExactly "'a;b'"
        & $M { ConvertTo-SlimerShellWord -Text 'a,b' } | Should -BeExactly "'a,b'"
        & $M { ConvertTo-SlimerShellWord -Text '@splat' } | Should -BeExactly "'@splat'"
        & $M { ConvertTo-SlimerShellWord -Text ("x" + [char]0x2019 + "y") } |
            Should -BeExactly ("'x" + [char]0x2019 + [char]0x2019 + "y'")
    }
}

Describe 'Get-SlimerAcceptEdit' {
    It 'replaces the current token with quoted text' {
        $e = & $M { Get-SlimerAcceptEdit -Line 'cd Prog' -Cursor 7 -Text 'Program Files' }
        $e.Start | Should -Be 3
        $e.Length | Should -Be 4
        $e.Replacement | Should -BeExactly "'Program Files'"
    }
    It 'inserts at the cursor after whitespace' {
        $e = & $M { Get-SlimerAcceptEdit -Line 'git ' -Cursor 4 -Text 'status' }
        $e.Start | Should -Be 4
        $e.Length | Should -Be 0
        $e.Replacement | Should -BeExactly 'status'
    }
    It 'refuses unsafe text' {
        & $M { Get-SlimerAcceptEdit -Line 'x' -Cursor 1 -Text ("a" + [char]13) } | Should -BeNullOrEmpty
        & $M { Get-SlimerAcceptEdit -Line 'x' -Cursor 1 -Text '' } | Should -BeNullOrEmpty
    }
    It 'replaces the whole line in line mode only for a prefix at the end' {
        $e = & $M { Get-SlimerAcceptEdit -Line 'git pu' -Cursor 6 -Text 'git push origin main' -Mode line }
        $e.Start | Should -Be 0
        $e.Length | Should -Be 6
        $e.Replacement | Should -BeExactly 'git push origin main'
        & $M { Get-SlimerAcceptEdit -Line 'git pu' -Cursor 3 -Text 'git push' -Mode line } | Should -BeNullOrEmpty
        & $M { Get-SlimerAcceptEdit -Line 'ls' -Cursor 2 -Text 'git push' -Mode line } | Should -BeNullOrEmpty
    }
}

Describe 'Read-SlimerAcceptPayloadFrom' {
    BeforeAll {
        # Build a key source over a fixed list of characters; $null after the end.
        $script:Source = {
            param([string]$Text)
            $q = [System.Collections.Generic.Queue[char]]::new()
            foreach ($c in $Text.ToCharArray()) { $q.Enqueue($c) }
            { if ($q.Count -gt 0) { $q.Dequeue() } else { $null } }.GetNewClosure()
        }
    }

    It 'reads up to BEL' {
        $src = & $Source ('%61%62' + [char]7 + 'rest')
        & $M { param($s) Read-SlimerAcceptPayloadFrom -ReadKey $s } $src | Should -BeExactly '%61%62'
    }
    It 'gives up without BEL (deadline)' {
        $src = & $Source '%61%62'
        & $M { param($s) Read-SlimerAcceptPayloadFrom -ReadKey $s } $src | Should -BeNullOrEmpty
    }
    It 'aborts on a character outside the hex alphabet' {
        $src = & $Source ('%61x' + [char]7)
        & $M { param($s) Read-SlimerAcceptPayloadFrom -ReadKey $s } $src | Should -BeNullOrEmpty
        $src = & $Source ('%61' + [char]13 + [char]7)
        & $M { param($s) Read-SlimerAcceptPayloadFrom -ReadKey $s } $src | Should -BeNullOrEmpty
    }
    It 'drains and discards an oversized payload' {
        $src = & $Source (('%41' * 5000) + [char]7)
        & $M { param($s) Read-SlimerAcceptPayloadFrom -ReadKey $s } $src | Should -BeNullOrEmpty
    }
}
