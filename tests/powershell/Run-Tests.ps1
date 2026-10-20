# Runs the installer tests with code coverage.
#
#   pwsh -File tests/powershell/Run-Tests.ps1          (PowerShell 7)
#   powershell -File tests\powershell\Run-Tests.ps1    (Windows PowerShell 5.1)
#
# Needs Pester 5.5 or later:  Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser
# Results go to tests/results/: test report, JaCoCo coverage and a text summary.

param([string]$PesterPath = '')

$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$results = Join-Path $repo 'tests\results'
New-Item -ItemType Directory -Force -Path $results | Out-Null

if ($PesterPath) { Import-Module $PesterPath -Force } else { Import-Module Pester -MinimumVersion 5.5 -Force }

$cfg = New-PesterConfiguration
$cfg.Run.Path = $PSScriptRoot
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = 'Detailed'
$cfg.TestResult.Enabled = $true
$cfg.TestResult.OutputPath = Join-Path $results 'powershell-tests.xml'
$cfg.CodeCoverage.Enabled = $true
$cfg.CodeCoverage.Path = @((Join-Path $repo 'install.ps1'), (Join-Path $repo 'uninstall.ps1'))
$cfg.CodeCoverage.OutputPath = Join-Path $results 'powershell-coverage.xml'

$run = Invoke-Pester -Configuration $cfg

# summary per file, with the lines that never ran
$edition = "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)) on $([Environment]::OSVersion.Platform)"
$lines = @("Installer coverage, $edition")
$cc = $run.CodeCoverage
foreach ($file in $cfg.CodeCoverage.Path.Value) {
    $name = Split-Path $file -Leaf
    $hit = @($cc.CommandsExecuted | Where-Object { $_.File -eq $file }).Count
    $miss = @($cc.CommandsMissed | Where-Object { $_.File -eq $file })
    $total = $hit + $miss.Count
    $pct = if ($total) { [math]::Round(100 * $hit / $total, 1) } else { 0 }
    $lines += ('  {0,-16} commands {1}/{2}  {3}%' -f $name, $hit, $total, $pct)
    if ($miss.Count) {
        $lines += '    never run: ' + (($miss | Sort-Object Line -Unique | ForEach-Object { "$($_.Line) $(($_.Command -replace '\s+', ' ').Substring(0, [Math]::Min(60, ($_.Command -replace '\s+', ' ').Length)))" }) -join '; ')
    }
}
$lines += ('  total            commands {0}/{1}  {2}%' -f $cc.CommandsExecutedCount, $cc.CommandsAnalyzedCount, [math]::Round($cc.CoveragePercent, 1))
$lines += "  tests: $($run.PassedCount) passed, $($run.FailedCount) failed, $($run.SkippedCount) skipped"
$text = $lines -join [Environment]::NewLine
$text | Set-Content -Path (Join-Path $results 'powershell-coverage.txt') -Encoding UTF8
Write-Host ''
Write-Host $text
if ($env:GITHUB_STEP_SUMMARY) {
    "### Installer coverage`n`n``````n$text`n```````n" | Add-Content -Path $env:GITHUB_STEP_SUMMARY -Encoding UTF8
}
if ($run.FailedCount -gt 0 -or $run.Result -ne 'Passed') { exit 1 }
exit 0
