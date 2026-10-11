# Monitor PC - uninstaller
# Removes the program, the shortcuts, the automatic start and the copy of
# LibreHardwareMonitor that was installed together with the monitor.
# The PawnIO driver stays: remove it from Settings > Apps > Installed apps.
#
# Plain ASCII on purpose (see install.ps1).

param(
    [ValidateSet('user', 'system')]
    [string]$Stage = 'user',
    [ValidateSet('', 'it', 'en')]
    [string]$Lang = '',
    [switch]$FunctionsOnly
)

$ErrorActionPreference = 'Stop'

$AppName      = 'Monitor PC'
$Dest         = Join-Path $env:ProgramFiles $AppName
$TaskName     = 'LibreHardwareMonitor'
$UninstallKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\MonitorPC'
# the second name is the state file written by version 1.0
$StateFiles   = @('install-state.json', 'installazione.json')

if (-not $Lang) {
    $Lang = 'en'
    try { if ((Get-UICulture).TwoLetterISOLanguageName -eq 'it') { $Lang = 'it' } } catch { }
}

$Messages = @{
    en = @{
        Title           = 'Monitor PC - uninstall'
        Heading         = '  MONITOR PC - uninstall'
        NotInstalled    = '  Monitor PC does not appear to be installed on this PC.'
        Confirm         = '  Remove Monitor PC from this PC? [y/N]'
        NoChange        = '  Nothing was changed.'
        UacNotice       = '  Windows will now ask for administrator permission: answer Yes.'
        Cancelled       = '  Uninstall cancelled.'
        Step1           = '[1/3] Stopping LibreHardwareMonitor'
        Step2           = '[2/3] Removing the automatic start'
        Step3           = '[3/3] Deleting the program'
        CannotDelete    = 'Cannot delete {0} : close the monitor and LibreHardwareMonitor, then delete it by hand.'
        StillThere      = '  The folder {0} is still there: try again, or delete it by hand.'
        Removed         = '  Monitor PC has been removed.'
        LhmKept         = '  LibreHardwareMonitor was already there before and stays where it is: {0}'
        PawnIo1         = '  The PawnIO driver, if you installed it, stays: remove it from'
        PawnIo2         = '  Settings > Apps > Installed apps > PawnIO.'
        NeedAdmin       = 'This stage needs administrator permission.'
        Error           = '  ERROR: {0}'
        PressEnterClose = '  Press ENTER to close'
    }
    it = @{
        Title           = 'Monitor PC - disinstallazione'
        Heading         = '  MONITOR PC - disinstallazione'
        NotInstalled    = '  Monitor PC non risulta installato su questo PC.'
        Confirm         = '  Vuoi togliere Monitor PC da questo PC? [s/N]'
        NoChange        = '  Nessuna modifica.'
        UacNotice       = "  Ora Windows chiede il permesso di amministratore: rispondi Si'."
        Cancelled       = '  Disinstallazione annullata.'
        Step1           = '[1/3] Fermo LibreHardwareMonitor'
        Step2           = "[2/3] Tolgo l'avvio automatico"
        Step3           = '[3/3] Cancello il programma'
        CannotDelete    = 'Non riesco a cancellare {0} : chiudi il monitor e LibreHardwareMonitor, poi cancellala a mano.'
        StillThere      = "  La cartella {0} c'e' ancora: riprova, oppure cancellala a mano."
        Removed         = "  Monitor PC e' stato tolto."
        LhmKept         = "  LibreHardwareMonitor c'era gia' prima e resta dov'e': {0}"
        PawnIo1         = '  Il driver PawnIO, se lo avevi installato, resta: si toglie da'
        PawnIo2         = '  Impostazioni > App > App installate > PawnIO.'
        NeedAdmin       = 'Questa fase richiede i permessi di amministratore.'
        Error           = '  ERRORE: {0}'
        PressEnterClose = '  Premi INVIO per chiudere'
    }
}

function L {
    param([string]$Key)
    $s = $Messages[$Lang][$Key]
    if ($null -eq $s) { $s = $Messages['en'][$Key] }
    if ($null -eq $s) { return $Key }
    if ($args.Count -gt 0) { return ($s -f $args) }
    return $s
}

function Say {
    param([string]$Text = '', [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# The process must not "sit" in the folder that is about to be deleted.
function Exit-Folder {
    try {
        Set-Location -LiteralPath $env:TEMP
        [Environment]::CurrentDirectory = $env:TEMP
    } catch { }
}

function Remove-UserShortcuts {
    foreach ($name in 'Desktop', 'Startup') {
        try {
            $lnk = Join-Path ([Environment]::GetFolderPath($name)) 'Monitor PC.lnk'
            if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }
        } catch { }
    }
}

# What the installer recorded: where LibreHardwareMonitor is, whether it was already
# on the PC before ("adopted") and whether the installer created the startup task.
function Read-State {
    foreach ($name in $StateFiles) {
        $f = Join-Path $Dest $name
        if (Test-Path -LiteralPath $f) {
            try {
                $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
                return New-Object PSObject -Property @{
                    Lhm         = $j.lhm
                    Adopted     = [bool]($j.adopted -or $j.adottato)
                    TaskCreated = [bool]($j.taskCreated -or $j.taskCreato)
                }
            } catch { }
        }
    }
    return $null
}

# True when the scheduled task starts an executable inside the given folder.
function Test-StartupTaskIsOurs {
    param([string]$Folder)
    try {
        $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        foreach ($a in @($t.Actions)) {
            if ("$($a.Execute)".Trim('"').StartsWith($Folder, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
    } catch { }
    return $false
}

function Invoke-SystemStage {
    Exit-Folder
    $state = Read-State
    $ours = Join-Path $Dest 'LibreHardwareMonitor'

    Say (L 'Step1') 'White'
    $stopped = 0
    foreach ($p in @(Get-Process -Name 'LibreHardwareMonitor' -ErrorAction SilentlyContinue)) {
        $path = $null
        try { $path = $p.Path } catch { }
        if ($path -and $path.StartsWith($ours, [StringComparison]::OrdinalIgnoreCase)) {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            $stopped++
        }
    }
    if ($stopped -gt 0) { Start-Sleep -Seconds 2 }

    Say (L 'Step2') 'White'
    $removeTask = $false
    if ($state -and $state.TaskCreated) { $removeTask = $true }
    if (Test-StartupTaskIsOurs $ours) { $removeTask = $true }
    if ($removeTask) {
        try {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        } catch {
            try { & schtasks.exe /Delete /TN $TaskName /F 2>$null | Out-Null } catch { }
        }
    }

    Say (L 'Step3') 'White'
    try {
        if (Test-Path -LiteralPath $UninstallKey) { Remove-Item -LiteralPath $UninstallKey -Recurse -Force }
    } catch { }
    for ($i = 0; $i -lt 6; $i++) {
        if (-not (Test-Path -LiteralPath $Dest)) { break }
        try { Remove-Item -LiteralPath $Dest -Recurse -Force -ErrorAction Stop } catch { Start-Sleep -Seconds 1 }
    }
    if (Test-Path -LiteralPath $Dest) {
        throw (L 'CannotDelete' $Dest)
    }
}

function Invoke-UserStage {
    try { $Host.UI.RawUI.WindowTitle = (L 'Title') } catch { }
    Exit-Folder
    Say ''
    Say (L 'Heading') 'Cyan'
    Say ''
    if (-not (Test-Path -LiteralPath $Dest)) {
        Remove-UserShortcuts
        Say (L 'NotInstalled')
        return
    }
    $r = Read-Host (L 'Confirm')
    if (-not ("$r".Trim() -match '^[sSyY]')) {
        Say (L 'NoChange')
        return
    }
    $state = Read-State
    Remove-UserShortcuts

    if (Test-Admin) {
        Invoke-SystemStage
    } else {
        Say ''
        Say (L 'UacNotice') 'Yellow'
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath), '-Stage', 'system', '-Lang', $Lang)
        try {
            Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -Wait
        } catch {
            Say (L 'Cancelled') 'Red'
            return
        }
    }

    Say ''
    if (Test-Path -LiteralPath $Dest) {
        Say (L 'StillThere' $Dest) 'Yellow'
    } else {
        Say (L 'Removed') 'Green'
    }
    if ($state -and $state.Adopted) {
        Say (L 'LhmKept' $state.Lhm)
    }
    Say (L 'PawnIo1')
    Say (L 'PawnIo2')
}

if ($FunctionsOnly) { return }

if ($Stage -eq 'system') {
    try {
        if (-not (Test-Admin)) { throw (L 'NeedAdmin') }
        Invoke-SystemStage
        exit 0
    } catch {
        Say ''
        Say (L 'Error' $_.Exception.Message) 'Red'
        Say ''
        [void](Read-Host (L 'PressEnterClose'))
        exit 1
    }
} else {
    try {
        Invoke-UserStage
    } catch {
        Say ''
        Say (L 'Error' $_.Exception.Message) 'Red'
    }
    Say ''
    [void](Read-Host (L 'PressEnterClose'))
}
