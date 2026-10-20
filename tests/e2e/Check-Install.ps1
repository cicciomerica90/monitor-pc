# Run on a real Windows after "install.ps1 -Stage system" (used by the GitHub workflow).
# Checks what the installer left behind and that LibreHardwareMonitor answers.
$ErrorActionPreference = 'Stop'
$dest = Join-Path $env:ProgramFiles 'Monitor PC'
$lhm = Join-Path $dest 'LibreHardwareMonitor\LibreHardwareMonitor.exe'
$failed = 0
function Check([string]$What, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "ok    $What" } else { Write-Host "FAIL  $What $Detail" -ForegroundColor Red; $script:failed++ }
}

foreach ($f in 'Monitor PC.html', 'monitor.ico', 'uninstall.ps1', 'Uninstall.bat', 'install-state.json') {
    Check "file $f" (Test-Path (Join-Path $dest $f))
}
Check 'LibreHardwareMonitor.exe' (Test-Path $lhm)

$cfg = [xml](Get-Content (Join-Path $dest 'LibreHardwareMonitor\LibreHardwareMonitor.config') -Raw)
$get = { param($k) ($cfg.configuration.appSettings.add | Where-Object key -eq $k).value }
Check 'web server turned on' ((& $get 'runWebServerMenuItem') -eq 'true')
Check 'port 8085' ((& $get 'listenerPort') -eq '8085')
Check 'starts minimized' ((& $get 'startMinMenuItem') -eq 'true')

$task = Get-ScheduledTask -TaskName 'LibreHardwareMonitor' -ErrorAction SilentlyContinue
Check 'scheduled task exists' ($null -ne $task)
if ($task) {
    Check 'task starts our copy' ($task.Actions[0].Execute -eq $lhm) $task.Actions[0].Execute
    Check 'task runs at logon' ($task.Triggers[0].CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger') $task.Triggers[0].CimClass.CimClassName
    Check 'task runs with highest privileges' ($task.Principal.RunLevel -eq 'Highest') $task.Principal.RunLevel
}

$key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\MonitorPC'
Check 'listed in installed apps' (Test-Path $key)
if (Test-Path $key) {
    $k = Get-ItemProperty $key
    Check 'apps entry name' ($k.DisplayName -eq 'Monitor PC') $k.DisplayName
    Check 'apps entry uninstall command' ($k.UninstallString -like '*uninstall.ps1*') $k.UninstallString
    Check 'apps entry NoRepair is a DWORD' ((Get-Item $key).GetValueKind('NoRepair') -eq 'DWord') ((Get-Item $key).GetValueKind('NoRepair'))
}

Check 'LibreHardwareMonitor running' (@(Get-Process LibreHardwareMonitor -ErrorAction SilentlyContinue).Count -gt 0)

# the sensors: the same address the monitor page reads
$json = $null
for ($i = 0; $i -lt 60 -and -not $json; $i++) {
    try { $json = (Invoke-WebRequest 'http://localhost:8085/data.json' -UseBasicParsing -TimeoutSec 3).Content } catch { Start-Sleep 2 }
}
Check 'sensor server answers on http://localhost:8085/data.json' ($null -ne $json)
if ($json) {
    $out = Join-Path $PSScriptRoot '..\results'
    New-Item -ItemType Directory -Force $out | Out-Null
    [IO.File]::WriteAllText((Join-Path $out 'real-data.json'), $json)
    $tree = $json | ConvertFrom-Json
    $hw = @()
    function Walk($n) { if ($n.HardwareId) { $script:hw += "$($n.HardwareId) = $($n.Text)" }; foreach ($c in $n.Children) { Walk $c } }
    Walk $tree
    Write-Host "hardware seen by LibreHardwareMonitor:"
    $hw | ForEach-Object { Write-Host "  $_" }
    Check 'at least one CPU listed' (@($hw | Where-Object { $_ -match 'cpu/' }).Count -gt 0)
}
if ($failed) { Write-Host "$failed check(s) failed"; exit 1 }
Write-Host 'all checks passed'
