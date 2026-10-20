# Tests for uninstall.ps1 (Pester 5). Run them with tests/powershell/Run-Tests.ps1.
# As in Install.Tests.ps1, everything that would change the PC is mocked and
# files are only written inside Pester's TestDrive.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Stubs.ps1')
    $script:UninstallScript = Join-Path $PSScriptRoot '..\..\uninstall.ps1'
}

Describe 'uninstall.ps1' {
    BeforeEach {
        $script:SavedEnv = @{ ProgramFiles = $env:ProgramFiles; TEMP = $env:TEMP }
        $script:Root = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N').Substring(0, 8))
        $env:ProgramFiles = Join-Path $script:Root 'Program Files'
        $env:TEMP = Join-Path $script:Root 'Temp'
        New-Item -ItemType Directory -Path $env:ProgramFiles, $env:TEMP | Out-Null
        . $script:UninstallScript -FunctionsOnly -Lang en

        # an installed copy
        $script:Ours = Join-Path $Dest 'LibreHardwareMonitor'
        New-Item -ItemType Directory -Path $script:Ours | Out-Null
        'x' | Set-Content (Join-Path $script:Ours 'LibreHardwareMonitor.exe')
        '{"version":"1.1","lhm":"x","adopted":false,"taskCreated":true}' | Set-Content (Join-Path $Dest 'install-state.json')

        Push-Location $script:Root
        Mock Write-Host { }
        Mock Start-Sleep { }
        Mock Test-Admin { $true }
        Mock Read-Host { 'y' }
        Mock Get-Process { @([pscustomobject]@{ Id = 91; Path = (Join-Path $script:Ours 'LibreHardwareMonitor.exe') },
                             [pscustomobject]@{ Id = 92; Path = 'C:\elsewhere\LibreHardwareMonitor.exe' }) }
        Mock Stop-Process { }
        Mock Get-ScheduledTask { throw 'no task' }
        Mock Unregister-ScheduledTask { }
        Mock Start-Process { }
        Mock Test-Path { $false } -ParameterFilter { "$LiteralPath" -like 'HKLM:*' }
        Mock Get-SpecialFolder { $p = Join-Path $script:Root $Name; New-Item -ItemType Directory -Force -Path $p | Out-Null; $p }
    }
    AfterEach {
        Pop-Location
        foreach ($k in $script:SavedEnv.Keys) { Set-Item "env:$k" $script:SavedEnv[$k] }
    }

    Context 'messages' {
        It 'has the same messages in both languages and uses only existing ones' {
            $Messages.en.Keys | Sort-Object | Should -Be ($Messages.it.Keys | Sort-Object)
            $used = [regex]::Matches((Get-Content $script:UninstallScript -Raw), "\(?L '([A-Za-z0-9]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
            @($used | Where-Object { $Messages.en.Keys -notcontains $_ }) | Should -BeNullOrEmpty
            @($Messages.en.Keys | Where-Object { $used -notcontains $_ }) | Should -BeNullOrEmpty
        }
        It 'falls back to English, then to the key, and picks the language from Windows' {
            $Lang = 'it'
            $Messages.it.Remove('Removed')
            L 'Removed' | Should -Be '  Monitor PC has been removed.'
            L 'Nope' | Should -Be 'Nope'
            L 'LhmKept' 'C:\x' | Should -BeLike '*C:\x'
            Mock Get-UICulture { [pscustomobject]@{ TwoLetterISOLanguageName = 'it' } }
            . $script:UninstallScript -FunctionsOnly
            $Lang | Should -Be 'it'
            Mock Get-UICulture { throw 'no culture' }
            . $script:UninstallScript -FunctionsOnly
            $Lang | Should -Be 'en'
        }
    }

    Context 'state left by the installer' {
        It 'reads the current format' {
            $s = Read-State
            $s.TaskCreated | Should -BeTrue
            $s.Adopted | Should -BeFalse
        }
        It 'reads the format written by version 1.0' {
            Remove-Item (Join-Path $Dest 'install-state.json')
            '{"versione":"1.0","lhm":"C:\\x","adottato":true,"taskCreato":false}' | Set-Content (Join-Path $Dest 'installazione.json')
            $s = Read-State
            $s.Adopted | Should -BeTrue
            $s.TaskCreated | Should -BeFalse
            $s.Lhm | Should -Be 'C:\x'
        }
        It 'ignores a damaged or missing file' {
            'not json' | Set-Content (Join-Path $Dest 'install-state.json')
            Read-State | Should -BeNullOrEmpty
            Remove-Item (Join-Path $Dest 'install-state.json')
            Read-State | Should -BeNullOrEmpty
        }
        It 'recognizes its own scheduled task' {
            Test-StartupTaskIsOurs $script:Ours | Should -BeFalse
            Mock Get-ScheduledTask { [pscustomobject]@{ Actions = @([pscustomobject]@{ Execute = '"' + (Join-Path $script:Ours 'LibreHardwareMonitor.exe') + '"' }) } }
            Test-StartupTaskIsOurs $script:Ours | Should -BeTrue
            Mock Get-ScheduledTask { [pscustomobject]@{ Actions = @([pscustomobject]@{ Execute = 'C:\Tools\LibreHardwareMonitor.exe' }) } }
            Test-StartupTaskIsOurs $script:Ours | Should -BeFalse
        }
    }

    Context 'system stage' {
        It 'stops only its own copy, removes the task, the apps entry and the folder' {
            Mock Test-Path { $true } -ParameterFilter { "$LiteralPath" -like 'HKLM:*' }
            Mock Remove-Item { } -ParameterFilter { "$LiteralPath" -like 'HKLM:*' }
            Invoke-SystemStage
            Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 91 }
            Should -Invoke Unregister-ScheduledTask -Times 1
            Should -Invoke Remove-Item -Times 1 -ParameterFilter { "$LiteralPath" -like 'HKLM:*' }
            $Dest | Should -Not -Exist
        }
        It 'removes a task that points to its own copy even without the state file' {
            Remove-Item (Join-Path $Dest 'install-state.json')
            Mock Get-ScheduledTask { [pscustomobject]@{ Actions = @([pscustomobject]@{ Execute = (Join-Path $script:Ours 'LibreHardwareMonitor.exe') }) } }
            Invoke-SystemStage
            Should -Invoke Unregister-ScheduledTask -Times 1
        }
        It 'leaves alone a task it did not create' {
            '{"adopted":true,"taskCreated":false,"lhm":"C:\\Tools"}' | Set-Content (Join-Path $Dest 'install-state.json')
            Mock Get-Process { @() }
            Invoke-SystemStage
            Should -Invoke Unregister-ScheduledTask -Times 0
            Should -Invoke Stop-Process -Times 0
        }
        It 'uses schtasks when the task cmdlets are not available' {
            Mock Unregister-ScheduledTask { throw 'not available' }
            function schtasks.exe { $script:SchtasksArgs = $args }
            Invoke-SystemStage
            $script:SchtasksArgs -join ' ' | Should -Be '/Delete /TN LibreHardwareMonitor /F'
        }
        It 'reports a folder it cannot delete' {
            Mock Remove-Item { throw 'in use' } -ParameterFilter { "$LiteralPath" -eq $Dest }
            { Invoke-SystemStage } | Should -Throw 'Cannot delete *'
            Should -Invoke Start-Sleep -Times 6 -Exactly -ParameterFilter { $Seconds -eq 1 }
        }
        It 'keeps going when a process path cannot be read or the apps entry cannot be removed' {
            $locked = [pscustomobject]@{ Id = 93 } | Add-Member -PassThru ScriptProperty Path { throw 'access denied' }
            Mock Get-Process { @($locked) }
            Mock Test-Path { throw 'registry locked' } -ParameterFilter { "$LiteralPath" -like 'HKLM:*' }
            Invoke-SystemStage
            Should -Invoke Stop-Process -Times 0
            $Dest | Should -Not -Exist
        }
        It 'does not stay inside the folder it deletes' {
            Set-Location $Dest
            Invoke-SystemStage
            (Get-Location).Path | Should -Be $env:TEMP
        }
    }

    Context 'user stage' {
        BeforeEach {
            $desk = Join-Path $script:Root 'Desktop'; New-Item -ItemType Directory -Force $desk | Out-Null
            $start = Join-Path $script:Root 'Startup'; New-Item -ItemType Directory -Force $start | Out-Null
            'lnk' | Set-Content (Join-Path $desk 'Monitor PC.lnk')
            'lnk' | Set-Content (Join-Path $start 'Monitor PC.lnk')
        }
        It 'removes everything after a yes' {
            Invoke-UserStage
            $Dest | Should -Not -Exist
            Join-Path $script:Root 'Desktop\Monitor PC.lnk' | Should -Not -Exist
            Join-Path $script:Root 'Startup\Monitor PC.lnk' | Should -Not -Exist
            Should -Invoke Write-Host -ParameterFilter { "$Object" -like '*has been removed*' }
        }
        It 'changes nothing after a no' {
            Mock Read-Host { 'n' }
            Invoke-UserStage
            $Dest | Should -Exist
            Join-Path $script:Root 'Desktop\Monitor PC.lnk' | Should -Exist
        }
        It 'only cleans up shortcuts when the program is not installed' {
            Remove-Item $Dest -Recurse -Force
            Invoke-UserStage
            Join-Path $script:Root 'Desktop\Monitor PC.lnk' | Should -Not -Exist
            Should -Invoke Read-Host -Times 0
        }
        It 'asks for administrator rights and passes the language on' {
            Mock Test-Admin { $false }
            Mock Start-Process { Invoke-SystemStage } -ParameterFilter { $Verb -eq 'RunAs' }
            Invoke-UserStage
            Should -Invoke Start-Process -Times 1 -ParameterFilter { ($ArgumentList -join ' ') -like '*-Stage system -Lang en' }
            $Dest | Should -Not -Exist
        }
        It 'stops when the administrator prompt is refused' {
            Mock Test-Admin { $false }
            Mock Start-Process { throw 'canceled' } -ParameterFilter { $Verb -eq 'RunAs' }
            Invoke-UserStage
            $Dest | Should -Exist
            Should -Invoke Write-Host -ParameterFilter { "$Object" -like '*Uninstall cancelled*' }
        }
        It 'says so when the folder is still there' {
            Mock Test-Admin { $false }
            Mock Start-Process { } -ParameterFilter { $Verb -eq 'RunAs' }
            Invoke-UserStage
            Should -Invoke Write-Host -ParameterFilter { "$Object" -like '*is still there*' }
        }
        It 'reminds that a LibreHardwareMonitor that was already there stays' {
            '{"adopted":true,"taskCreated":false,"lhm":"C:\\Tools\\LHM"}' | Set-Content (Join-Path $Dest 'install-state.json')
            Invoke-UserStage
            Should -Invoke Write-Host -ParameterFilter { "$Object" -like '*stays where it is: C:\Tools\LHM' }
        }
        It 'shrugs off a shortcut that cannot be deleted' {
            Mock Remove-Item { throw 'locked' } -ParameterFilter { "$LiteralPath" -like '*.lnk' }
            Invoke-UserStage
            $Dest | Should -Not -Exist
        }
    }

    Context 'entry point' {
        BeforeEach { Mock Invoke-SystemStage { }; Mock Invoke-UserStage { } }
        It 'system stage: 0 when it works, 1 without administrator rights' {
            $Stage = 'system'
            Invoke-Main
            $script:ExitCode | Should -Be 0
            Mock Test-Admin { $false }
            Invoke-Main
            $script:ExitCode | Should -Be 1
        }
        It 'user stage: shows errors and waits for ENTER' {
            $Stage = 'user'
            Mock Invoke-UserStage { throw 'boom' }
            Invoke-Main
            $script:ExitCode | Should -Be 0
            Should -Invoke Write-Host -ParameterFilter { "$Object" -like '*ERROR: boom*' }
            Should -Invoke Read-Host -Times 1
        }
    }
}

Describe 'uninstall.ps1 Windows helpers' {
    BeforeAll {
        if (-not $env:ProgramFiles) { $env:ProgramFiles = $TestDrive }     # not set outside Windows
        . $script:UninstallScript -FunctionsOnly -Lang en
    }
    It 'returns the real special folders' {
        Get-SpecialFolder 'ApplicationData' | Should -Be ([Environment]::GetFolderPath('ApplicationData'))
    }
    It 'tells whether it runs as administrator' -Skip:([Environment]::OSVersion.Platform -ne 'Win32NT') {
        Test-Admin | Should -BeOfType [bool]
    }
}
