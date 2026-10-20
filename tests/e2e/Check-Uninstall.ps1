# Run on a real Windows after "uninstall.ps1 -Stage system": everything must be gone.
$failed = 0
function Check([string]$What, [bool]$Ok) {
    if ($Ok) { Write-Host "ok    $What" } else { Write-Host "FAIL  $What" -ForegroundColor Red; $script:failed++ }
}
Check 'program folder removed' (-not (Test-Path (Join-Path $env:ProgramFiles 'Monitor PC')))
Check 'scheduled task removed' ($null -eq (Get-ScheduledTask -TaskName 'LibreHardwareMonitor' -ErrorAction SilentlyContinue))
Check 'apps entry removed' (-not (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\MonitorPC'))
Check 'LibreHardwareMonitor stopped' (@(Get-Process LibreHardwareMonitor -ErrorAction SilentlyContinue).Count -eq 0)
if ($failed) { exit 1 }
Write-Host 'all checks passed'
