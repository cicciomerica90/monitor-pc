# Tests for install.ps1 (Pester 5). Run them with tests/powershell/Run-Tests.ps1.
#
# Everything that would change the PC is replaced by a mock: scheduled tasks,
# processes, the registry, shortcuts, the administrator prompt, downloads.
# Files are only written inside Pester's temporary TestDrive folder, so the
# tests are safe to run on your own Windows PC too.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Stubs.ps1')
    $script:InstallScript = Join-Path $PSScriptRoot '..\..\install.ps1'
    $script:OnWindows = [Environment]::OSVersion.Platform -eq 'Win32NT'

    # A zip that passes the installer's checks: >1 MB, contains LibreHardwareMonitor.exe.
    function New-FakeLhmZip {
        param([string]$Path, [string]$EntryName = 'LibreHardwareMonitor.exe')
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        $bytes = New-Object byte[] (1200KB)
        (New-Object Random 7).NextBytes($bytes)
        $zip = [System.IO.Compression.ZipFile]::Open($Path, 'Create')
        try {
            $e = $zip.CreateEntry($EntryName, 'NoCompression')
            $s = $e.Open(); $s.Write($bytes, 0, $bytes.Length); $s.Dispose()
            $e = $zip.CreateEntry('LibreHardwareMonitor.config')
            $s = $e.Open(); $w = New-Object IO.StreamWriter($s)
            $w.Write('<?xml version="1.0" encoding="utf-8"?><configuration><appSettings><add key="plotPanel.Min" value="5" /></appSettings></configuration>')
            $w.Dispose()
        } finally { $zip.Dispose() }
    }

    # Fresh Program Files / Temp / setup folder for every test, then load the script's functions.
    function Initialize-Install {
        param([string]$Lang = 'en', [switch]$NoLocalZip)
        $root = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N').Substring(0, 8))
        $env:ProgramFiles = Join-Path $root 'Program Files'
        $env:TEMP = Join-Path $root 'Temp'
        $env:SystemRoot = Join-Path $root 'Windows'
        $setup = Join-Path $root 'setup'
        New-Item -ItemType Directory -Path $env:ProgramFiles, $env:TEMP, $env:SystemRoot, $setup | Out-Null
        foreach ($f in 'Monitor PC.html', 'monitor.ico', 'uninstall.ps1', 'Uninstall.bat') {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot "..\..\$f") -Destination $setup
        }
        $script:FixtureZip = Join-Path $root 'fixture.zip'
        New-FakeLhmZip $script:FixtureZip
        if (-not $NoLocalZip) { Copy-Item $script:FixtureZip (Join-Path $setup 'LibreHardwareMonitor.zip') }
        $script:Root = $root
        return $setup
    }
}

Describe 'install.ps1' {
    BeforeEach {
        $script:SavedEnv = @{ ProgramFiles = $env:ProgramFiles; TEMP = $env:TEMP; SystemRoot = $env:SystemRoot }
        $script:Setup = Initialize-Install
        . $script:InstallScript -FunctionsOnly -Lang en
        $Source = $script:Setup

        # nothing below may reach the real system
        Mock Write-Host { }
        Mock Start-Sleep { }
        Mock Test-Admin { $true }
        Mock Get-UICulture { [pscustomobject]@{ TwoLetterISOLanguageName = 'en' } }
        $script:Running = @()
        Mock Get-Process { $script:Running }
        Mock Stop-Process { $script:Running = @($script:Running | Where-Object { $_.Id -ne $Id }) }
        $script:TaskXml = $null
        Mock Register-ScheduledTask { $script:TaskXml = $Xml }
        Mock Get-ScheduledTask { throw 'no task' }
        Mock Start-ScheduledTask { $script:Running = @([pscustomobject]@{ Id = 77; Path = (Join-Path (Join-Path $Dest 'LibreHardwareMonitor') 'LibreHardwareMonitor.exe') }) }
        Mock Start-Process { }
        Mock New-Item { } -ParameterFilter { "$Path" -like 'HKLM:*' }
        Mock Set-ItemProperty { }
        Mock New-Shortcut { Set-Content -LiteralPath $File -Value "$Target|$Arguments|$Icon" }
        Mock Test-Path { $false } -ParameterFilter { "$LiteralPath" -like 'HK*' }
        Mock Read-Host { '' }
        Mock Get-SpecialFolder { $p = Join-Path $script:Root $Name; New-Item -ItemType Directory -Force -Path $p | Out-Null; $p }
        Mock Invoke-WebRequest {
            if ($OutFile) { Copy-Item $script:FixtureZip $OutFile; return }
            [pscustomobject]@{ StatusCode = 200; Content = '{"Text":"Sensor","Children":[]}' }
        }
    }
    AfterEach {
        foreach ($k in $script:SavedEnv.Keys) { Set-Item "env:$k" $script:SavedEnv[$k] }
    }

    Context 'messages' {
        It 'has the same messages in both languages, with the same placeholders' {
            $Messages.en.Keys | Sort-Object | Should -Be ($Messages.it.Keys | Sort-Object)
            foreach ($k in $Messages.en.Keys) {
                ([regex]::Matches($Messages.it[$k], '\{\d\}')).Count | Should -Be ([regex]::Matches($Messages.en[$k], '\{\d\}')).Count -Because $k
            }
        }
        It 'uses only messages that exist and has no unused ones' {
            $used = [regex]::Matches((Get-Content $script:InstallScript -Raw), "\(?L '([A-Za-z0-9]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
            @($used | Where-Object { $Messages.en.Keys -notcontains $_ }) | Should -BeNullOrEmpty
            @($Messages.en.Keys | Where-Object { $used -notcontains $_ }) | Should -BeNullOrEmpty
        }
        It 'fills in arguments, falls back to English, then to the key' {
            L 'MissingFile' 'a.txt' | Should -Be 'A file is missing from the setup folder: a.txt'
            $Lang = 'it'
            L 'WillCopy' 'X:\a' | Should -Be '   - copia il programma in X:\a'
            $Messages.it.Remove('Done')
            L 'Done' | Should -Be '  DONE.'
            L 'NoSuchKey' | Should -Be 'NoSuchKey'
        }
        It 'speaks Italian on an Italian Windows and English otherwise' {
            Mock Get-UICulture { [pscustomobject]@{ TwoLetterISOLanguageName = 'it' } }
            . $script:InstallScript -FunctionsOnly
            $Lang | Should -Be 'it'
            Mock Get-UICulture { [pscustomobject]@{ TwoLetterISOLanguageName = 'de' } }
            . $script:InstallScript -FunctionsOnly
            $Lang | Should -Be 'en'
            Mock Get-UICulture { throw 'no culture' }
            . $script:InstallScript -FunctionsOnly
            $Lang | Should -Be 'en'
        }
    }

    Context 'LibreHardwareMonitor settings file' {
        It 'creates it when missing' {
            $f = Join-Path $script:Root 'a.config'
            Set-LhmConfig -File $f -Values @{ runWebServerMenuItem = 'true'; listenerPort = '8085' }
            ([xml](Get-Content $f -Raw)).configuration.appSettings.add | Where-Object key -eq 'listenerPort' | ForEach-Object value | Should -Be '8085'
        }
        It 'updates an existing one without duplicates and keeps everything else' {
            $f = Join-Path $script:Root 'b.config'
            '<?xml version="1.0" encoding="utf-8"?><configuration><appSettings><add key="listenerPort" value="9000" /><add key="plotPanel.Min" value="5" /></appSettings></configuration>' | Set-Content $f
            Set-LhmConfig -File $f -Values @{ listenerPort = '8085'; startMinMenuItem = 'true' }
            $a = ([xml](Get-Content $f -Raw)).configuration.appSettings.add
            @($a | Where-Object key -eq 'listenerPort').Count | Should -Be 1
            ($a | Where-Object key -eq 'listenerPort').value | Should -Be '8085'
            ($a | Where-Object key -eq 'plotPanel.Min').value | Should -Be '5'
            ($a | Where-Object key -eq 'startMinMenuItem').value | Should -Be 'true'
        }
        It 'rewrites a broken file and adds appSettings when missing' {
            $f = Join-Path $script:Root 'c.config'
            'not xml <<<' | Set-Content $f
            Set-LhmConfig -File $f -Values @{ runWebServerMenuItem = 'true' }
            ([xml](Get-Content $f -Raw)).configuration.appSettings.add.value | Should -Be 'true'
            '<?xml version="1.0"?><configuration />' | Set-Content $f
            Set-LhmConfig -File $f -Values @{ runWebServerMenuItem = 'true' }
            ([xml](Get-Content $f -Raw)).configuration.appSettings.add.value | Should -Be 'true'
            '<?xml version="1.0"?><other />' | Set-Content $f
            Set-LhmConfig -File $f -Values @{ runWebServerMenuItem = 'true' }
            ([xml](Get-Content $f -Raw)).configuration.appSettings.add.value | Should -Be 'true'
        }
    }

    Context 'download' {
        It 'accepts a real zip and rejects fakes' {
            Test-LhmZip $script:FixtureZip | Should -BeTrue
            Test-LhmZip (Join-Path $script:Root 'missing.zip') | Should -BeFalse
            $small = Join-Path $script:Root 'small.zip'; 'x' | Set-Content $small
            Test-LhmZip $small | Should -BeFalse
            $junk = Join-Path $script:Root 'junk.zip'; [IO.File]::WriteAllBytes($junk, (New-Object byte[] (1100KB)))
            Test-LhmZip $junk | Should -BeFalse
            $other = Join-Path $script:Root 'other.zip'; New-FakeLhmZip $other -EntryName 'Something.exe'
            Test-LhmZip $other | Should -BeFalse
        }
        It 'downloads the latest release' {
            $z = Get-LhmZip -Url 'https://example.invalid/x.zip' -TempFolder $env:TEMP -LocalZip ''
            $z | Should -BeLike '*LibreHardwareMonitor-download.zip'
            Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter { $OutFile -like '*download.zip' }
        }
        It 'replaces an old download' {
            $old = Join-Path $env:TEMP 'LibreHardwareMonitor-download.zip'; 'old' | Set-Content $old
            Get-LhmZip -Url 'https://example.invalid/x.zip' -TempFolder $env:TEMP -LocalZip '' | Should -Be $old
            Test-LhmZip $old | Should -BeTrue
        }
        It 'falls back to the zip next to the installer' {
            Mock Invoke-WebRequest { throw 'offline' }
            $local = Join-Path $script:Setup 'LibreHardwareMonitor.zip'
            Get-LhmZip -Url 'https://example.invalid/x.zip' -TempFolder $env:TEMP -LocalZip $local | Should -Be $local
        }
        It 'falls back when the download is not a valid zip' {
            Mock Invoke-WebRequest { 'error page' | Set-Content $OutFile }
            $local = Join-Path $script:Setup 'LibreHardwareMonitor.zip'
            Get-LhmZip -Url 'https://example.invalid/x.zip' -TempFolder $env:TEMP -LocalZip $local | Should -Be $local
        }
        It 'stops with a clear message when there is no way to get it' {
            Mock Invoke-WebRequest { throw 'offline' }
            { Get-LhmZip -Url 'https://example.invalid/x.zip' -TempFolder $env:TEMP -LocalZip '' } | Should -Throw 'Cannot download LibreHardwareMonitor*'
        }
    }

    Context 'helpers' {
        It 'checks whether the sensors answer' {
            Test-SensorServer | Should -BeTrue
            Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = [Text.Encoding]::UTF8.GetBytes('{"Children":[]}') } }
            Test-SensorServer | Should -BeTrue
            Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = 'hello' } }
            Test-SensorServer | Should -BeFalse
            Mock Invoke-WebRequest { throw 'refused' }
            Test-SensorServer | Should -BeFalse
        }
        It 'builds file addresses with spaces encoded' {
            ConvertTo-FileUrl 'C:\Program Files\Monitor PC\Monitor PC.html' | Should -Be 'file:///C:/Program%20Files/Monitor%20PC/Monitor%20PC.html'
        }
        It 'builds a valid scheduled task, also for paths with &' {
            $x = [xml]((New-StartupTaskXml 'C:\A & B\LibreHardwareMonitor.exe') -replace 'encoding="UTF-16"', '')
            $x.Task.Actions.Exec.Command | Should -Be 'C:\A & B\LibreHardwareMonitor.exe'
            $x.Task.Actions.Exec.WorkingDirectory | Should -Be (Split-Path -Parent 'C:\A & B\LibreHardwareMonitor.exe')
            $x.Task.Principals.Principal.RunLevel | Should -Be 'HighestAvailable'
            $x.Task.Settings.ExecutionTimeLimit | Should -Be 'PT0S'
            $x.Task.Triggers.LogonTrigger.Enabled | Should -Be 'true'
        }
        It 'registers the task, with schtasks as a second route' {
            Register-LhmStartup 'C:\x\LibreHardwareMonitor.exe'
            $script:TaskXml | Should -Match 'LibreHardwareMonitor.exe'
            Mock Register-ScheduledTask { throw 'not available' }
            $script:SchtasksCode = 0
            function schtasks.exe { $script:SchtasksArgs = $args; $global:LASTEXITCODE = $script:SchtasksCode }
            Register-LhmStartup 'C:\x\LibreHardwareMonitor.exe'
            $script:SchtasksArgs -join ' ' | Should -BeLike '/Create /TN LibreHardwareMonitor /XML *monitor-pc-startup.xml /F'
            Test-Path (Join-Path $env:TEMP 'monitor-pc-startup.xml') | Should -BeFalse
            $script:SchtasksCode = 1
            { Register-LhmStartup 'C:\x\LibreHardwareMonitor.exe' } | Should -Throw 'Cannot create the automatic start*'
        }
        It 'knows whether the task exists' {
            Test-StartupTaskExists | Should -BeFalse
            Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'LibreHardwareMonitor' } }
            Test-StartupTaskExists | Should -BeTrue
        }
        It 'lists running copies, also when a path cannot be read' {
            $locked = [pscustomobject]@{ Id = 2 } | Add-Member -PassThru ScriptProperty Path { throw 'access denied' }
            Mock Get-Process { @([pscustomobject]@{ Id = 1; Path = 'C:\a\LibreHardwareMonitor.exe' }, $locked) }
            $r = @(Get-RunningLhm)
            $r.Count | Should -Be 2
            $r[0].ExePath | Should -Be 'C:\a\LibreHardwareMonitor.exe'
            $r[1].ExePath | Should -BeNullOrEmpty
        }
        It 'stops only the copies inside a folder' {
            $script:Running = @([pscustomobject]@{ Id = 1; Path = 'C:\ours\LibreHardwareMonitor.exe' },
                                [pscustomobject]@{ Id = 2; Path = 'C:\other\LibreHardwareMonitor.exe' },
                                [pscustomobject]@{ Id = 3; Path = $null })
            Stop-LhmIn 'C:\ours'
            Should -Invoke Stop-Process -Times 1 -Exactly
            Should -Invoke Stop-Process -Times 1 -ParameterFilter { $Id -eq 1 }
            Should -Invoke Start-Sleep -Times 1
            Stop-LhmIn 'C:\nothing'
            Should -Invoke Stop-Process -Times 1 -Exactly
        }
        It 'finds Edge, Chrome or Brave in the registry' {
            $exe = Join-Path $script:Root 'chrome.exe'; 'x' | Set-Content $exe
            Mock Test-Path { $true } -ParameterFilter { "$LiteralPath" -like '*App Paths\chrome.exe' -and "$LiteralPath" -like 'HKCU:*' }
            Mock Test-Path { $true } -ParameterFilter { "$LiteralPath" -like '*App Paths\msedge.exe' -and "$LiteralPath" -like 'HKLM:*' }
            $edgeKey = [pscustomobject]@{} | Add-Member -PassThru ScriptMethod GetValue { param($n) throw 'unreadable' }
            $chromeKey = [pscustomobject]@{ Exe = $exe } | Add-Member -PassThru ScriptMethod GetValue { param($n) '"' + $this.Exe + '"' }
            Mock Get-Item { $edgeKey } -ParameterFilter { "$LiteralPath" -like '*msedge.exe' }
            Mock Get-Item { $chromeKey } -ParameterFilter { "$LiteralPath" -like '*chrome.exe' }
            Get-Browser | Should -Be $exe
            Mock Test-Path { $false } -ParameterFilter { "$LiteralPath" -like 'HK*' }
            Get-Browser | Should -BeNullOrEmpty
        }
        It 'skips a registered browser whose program is gone or empty' {
            Mock Test-Path { $true } -ParameterFilter { "$LiteralPath" -like 'HKLM:*App Paths\msedge.exe' -or "$LiteralPath" -like 'HKLM:*App Paths\chrome.exe' }
            $empty = [pscustomobject]@{} | Add-Member -PassThru ScriptMethod GetValue { param($n) '' }
            $gone = [pscustomobject]@{} | Add-Member -PassThru ScriptMethod GetValue { param($n) 'C:\nowhere\chrome.exe' }
            Mock Get-Item { $empty } -ParameterFilter { "$LiteralPath" -like '*msedge.exe' }
            Mock Get-Item { $gone } -ParameterFilter { "$LiteralPath" -like '*chrome.exe' }
            Get-Browser | Should -BeNullOrEmpty
        }
        It 'makes the shortcut open the page in a browser window without toolbars' {
            $lnk = New-MonitorShortcut $script:Root
            Get-Content $lnk -Raw | Should -BeLike '*Monitor PC.html||*monitor.ico*'
            Mock Get-Browser { 'C:\Edge\msedge.exe' }
            $lnk = New-MonitorShortcut $script:Root
            Get-Content $lnk -Raw | Should -BeLike 'C:\Edge\msedge.exe|--app="file:///*Monitor%20PC.html"|*'
        }
    }

    Context 'system stage' {
        It 'installs everything on a clean PC' {
            Invoke-SystemStage
            foreach ($f in 'Monitor PC.html', 'monitor.ico', 'uninstall.ps1', 'Uninstall.bat', 'install-state.json',
                           'LibreHardwareMonitor\LibreHardwareMonitor.exe', 'LibreHardwareMonitor\LibreHardwareMonitor.config') {
                Join-Path $Dest $f | Should -Exist
            }
            $a = ([xml](Get-Content (Join-Path $Dest 'LibreHardwareMonitor\LibreHardwareMonitor.config') -Raw)).configuration.appSettings.add
            foreach ($k in 'runWebServerMenuItem', 'startMinMenuItem', 'minTrayMenuItem', 'minCloseMenuItem') {
                ($a | Where-Object key -eq $k).value | Should -Be 'true' -Because $k
            }
            ($a | Where-Object key -eq 'listenerPort').value | Should -Be '8085'
            ($a | Where-Object key -eq 'plotPanel.Min').value | Should -Be '5'
            $state = Get-Content (Join-Path $Dest 'install-state.json') -Raw | ConvertFrom-Json
            $state.adopted | Should -BeFalse
            $state.taskCreated | Should -BeTrue
            $script:TaskXml | Should -Match ([regex]::Escape((Join-Path $Dest 'LibreHardwareMonitor\LibreHardwareMonitor.exe')))
            Should -Invoke Set-ItemProperty -ParameterFilter { $Name -eq 'UninstallString' -and $Value -like '*uninstall.ps1*' }
            Should -Invoke Set-ItemProperty -ParameterFilter { $Name -eq 'NoRepair' -and $Value -is [int] }
            Should -Invoke Write-Host -Times 0 -ParameterFilter { "$Object" -like '*not serious*' }
            Should -Invoke Start-ScheduledTask -Times 1
            Should -Invoke Start-Process -Times 0
        }
        It 'stops its own running copy before overwriting it' {
            $script:Running = @([pscustomobject]@{ Id = 50; Path = (Join-Path $Dest 'LibreHardwareMonitor\LibreHardwareMonitor.exe') })
            Invoke-SystemStage
            Should -Invoke Stop-Process -ParameterFilter { $Id -eq 50 }
            (Get-Content (Join-Path $Dest 'install-state.json') -Raw | ConvertFrom-Json).adopted | Should -BeFalse
        }
        It 'uses a LibreHardwareMonitor that is already running elsewhere' {
            $ext = Join-Path $script:Root 'Tools\LHM'; New-Item -ItemType Directory $ext | Out-Null
            'x' | Set-Content (Join-Path $ext 'LibreHardwareMonitor.exe')
            '<?xml version="1.0" encoding="utf-8"?><configuration><appSettings><add key="startMinMenuItem" value="false" /></appSettings></configuration>' | Set-Content (Join-Path $ext 'LibreHardwareMonitor.config')
            $script:Running = @([pscustomobject]@{ Id = 60; Path = (Join-Path $ext 'LibreHardwareMonitor.exe') })
            Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'LibreHardwareMonitor' } }
            Mock Start-ScheduledTask { $script:Running = @([pscustomobject]@{ Id = 61; Path = (Join-Path $ext 'LibreHardwareMonitor.exe') }) }
            Invoke-SystemStage
            $state = Get-Content (Join-Path $Dest 'install-state.json') -Raw | ConvertFrom-Json
            $state.adopted | Should -BeTrue
            $state.taskCreated | Should -BeFalse
            Join-Path $Dest 'LibreHardwareMonitor' | Should -Not -Exist
            $script:TaskXml | Should -BeNullOrEmpty
            $a = ([xml](Get-Content (Join-Path $ext 'LibreHardwareMonitor.config') -Raw)).configuration.appSettings.add
            ($a | Where-Object key -eq 'runWebServerMenuItem').value | Should -Be 'true'
            ($a | Where-Object key -eq 'startMinMenuItem').value | Should -Be 'false'      # the user's own choice stays
        }
        It 'creates the task for an adopted copy that had none' {
            $ext = Join-Path $script:Root 'LHM'; New-Item -ItemType Directory $ext | Out-Null
            'x' | Set-Content (Join-Path $ext 'LibreHardwareMonitor.exe')
            $script:Running = @([pscustomobject]@{ Id = 60; Path = (Join-Path $ext 'LibreHardwareMonitor.exe') })
            Invoke-SystemStage
            (Get-Content (Join-Path $Dest 'install-state.json') -Raw | ConvertFrom-Json).taskCreated | Should -BeTrue
            $script:TaskXml | Should -Match ([regex]::Escape((Join-Path $ext 'LibreHardwareMonitor.exe')))
        }
        It 'starts LibreHardwareMonitor directly when the task does not start it' {
            Mock Start-ScheduledTask { throw 'task not started' }
            Invoke-SystemStage
            Should -Invoke Start-Process -Times 1 -ParameterFilter { $FilePath -like '*LibreHardwareMonitor.exe' }
            Should -Invoke Start-Sleep -Times 10 -Exactly
        }
        It 'keeps going when the apps list cannot be written' {
            Mock New-Item { throw 'access denied' } -ParameterFilter { "$Path" -like 'HKLM:*' }
            Invoke-SystemStage
            Join-Path $Dest 'install-state.json' | Should -Exist
            Should -Invoke Write-Host -ParameterFilter { "$Object" -like '*failed (not serious*' }
        }
        It 'stops when a file is missing from the setup folder' {
            Remove-Item (Join-Path $Source 'monitor.ico')
            { Invoke-SystemStage } | Should -Throw 'A file is missing from the setup folder: monitor.ico'
        }
        It 'stops when the adopted copy has no program file' {
            $script:Running = @([pscustomobject]@{ Id = 60; Path = (Join-Path $script:Root 'gone\LibreHardwareMonitor.exe') })
            { Invoke-SystemStage } | Should -Throw 'Cannot find *'
        }
    }

    Context 'user stage' {
        BeforeEach {
            # "elevation": run the system stage in-process
            Mock Start-Process { Invoke-SystemStage } -ParameterFilter { $Verb -eq 'RunAs' }
            Mock Test-Admin { $false }
            Mock Test-SensorServer { $true }
            $script:Succeeded = $false
        }
        It 'installs, waits for the sensors, creates the shortcuts and opens the monitor' {
            Invoke-UserStage
            $script:Succeeded | Should -BeTrue
            Should -Invoke Start-Process -Times 1 -ParameterFilter { $Verb -eq 'RunAs' -and ($ArgumentList -join ' ') -like '*-Stage system -Lang en' }
            Join-Path $script:Root 'Desktop\Monitor PC.lnk' | Should -Exist
            Join-Path $script:Root 'Startup\Monitor PC.lnk' | Should -Exist
            Should -Invoke Start-Process -ParameterFilter { $FilePath -like '*Desktop*Monitor PC.lnk' }
        }
        It 'runs the system stage directly when already administrator' {
            Mock Test-Admin { $true }
            Invoke-UserStage
            $script:Succeeded | Should -BeTrue
            Should -Invoke Start-Process -Times 0 -ParameterFilter { $Verb -eq 'RunAs' }
        }
        It 'removes the automatic opening when the answer is no' {
            Mock Read-Host { 'n' } -ParameterFilter { "$Prompt" -like '*every logon*' }
            $startup = Join-Path $script:Root 'Startup'; New-Item -ItemType Directory $startup | Out-Null
            'old' | Set-Content (Join-Path $startup 'Monitor PC.lnk')
            Invoke-UserStage
            Join-Path $startup 'Monitor PC.lnk' | Should -Not -Exist
            $script:Succeeded | Should -BeTrue
        }
        It 'says so when the sensors do not answer' {
            Mock Test-SensorServer { $false }
            Invoke-UserStage
            Should -Invoke Test-SensorServer -Times 75 -Exactly
            Should -Invoke Write-Host -ParameterFilter { "$Object" -like '*not answering yet*' }
            $script:Succeeded | Should -BeTrue
        }
        It 'stops when the administrator prompt is refused' {
            Mock Start-Process { throw 'The operation was canceled by the user.' } -ParameterFilter { $Verb -eq 'RunAs' }
            Invoke-UserStage
            $script:Succeeded | Should -BeFalse
            Should -Invoke Write-Host -ParameterFilter { "$Object" -like '*Setup cancelled*' }
        }
        It 'stops when the system stage did not finish' {
            Mock Start-Process { } -ParameterFilter { $Verb -eq 'RunAs' }
            Invoke-UserStage
            $script:Succeeded | Should -BeFalse
            Should -Invoke Write-Host -ParameterFilter { "$Object" -like '*did not complete*' }
        }
        It 'opens the page directly when the desktop shortcut cannot be made' {
            Mock New-MonitorShortcut { throw 'no shell' }
            Invoke-UserStage
            $script:Succeeded | Should -BeTrue
            Should -Invoke Write-Host -ParameterFilter { "$Object" -like '*Could not create the desktop shortcut*' }
            Should -Invoke Write-Host -ParameterFilter { "$Object" -like '*Could not set the monitor to open automatically*' }
            Should -Invoke Start-Process -ParameterFilter { $FilePath -like '*Monitor PC.html' }
        }
        It 'does not fail when the monitor cannot be opened at the end' {
            Mock Start-Process { throw 'no browser' } -ParameterFilter { $FilePath -like '*Monitor PC*' }
            Invoke-UserStage
            $script:Succeeded | Should -BeTrue
        }
    }

    Context 'entry point' {
        BeforeEach {
            Mock Invoke-SystemStage { }
            Mock Invoke-UserStage { $script:Succeeded = $true }
        }
        It 'system stage: exit code 0 when it works' {
            $Stage = 'system'
            Invoke-Main
            $script:ExitCode | Should -Be 0
        }
        It 'system stage: refuses to run without administrator rights' {
            $Stage = 'system'
            Mock Test-Admin { $false }
            Invoke-Main
            $script:ExitCode | Should -Be 1
            Should -Invoke Invoke-SystemStage -Times 0
            Should -Invoke Write-Host -ParameterFilter { "$Object" -like '*ERROR: This stage needs administrator permission.*' }
        }
        It 'user stage: exit code follows the result' {
            $Stage = 'user'
            Invoke-Main
            $script:ExitCode | Should -Be 0
            Mock Invoke-UserStage { $script:Succeeded = $false; throw 'boom' }
            Invoke-Main
            $script:ExitCode | Should -Be 1
            Should -Invoke Write-Host -ParameterFilter { "$Object" -like '*ERROR: boom*' }
        }
    }
}

# The few helpers that talk to Windows itself, run for real (no mocks).
Describe 'install.ps1 Windows helpers' {
    BeforeAll {
        if (-not $env:ProgramFiles) { $env:ProgramFiles = $TestDrive }     # not set outside Windows
        . $script:InstallScript -FunctionsOnly -Lang en
    }
    It 'returns the real special folders' {
        Get-SpecialFolder 'ApplicationData' | Should -Be ([Environment]::GetFolderPath('ApplicationData'))
    }
    It 'tells whether it runs as administrator' -Skip:([Environment]::OSVersion.Platform -ne 'Win32NT') {
        Test-Admin | Should -BeOfType [bool]
    }
    It 'writes a real Windows shortcut' -Skip:([Environment]::OSVersion.Platform -ne 'Win32NT') {
        $lnk = Join-Path $TestDrive 'test.lnk'
        New-Shortcut -File $lnk -Target 'C:\Windows\notepad.exe' -Arguments '--x' -Icon 'C:\Windows\notepad.exe' -Folder 'C:\Windows'
        $c = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
        $c.TargetPath | Should -Be 'C:\Windows\notepad.exe'
        $c.Arguments | Should -Be '--x'
        $c.Description | Should -Be 'CPU and GPU temperature, clock and load'
    }
}
