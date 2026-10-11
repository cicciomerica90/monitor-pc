# Monitor PC - disinstallazione
# Toglie il programma, i collegamenti, l'avvio automatico e la copia di
# LibreHardwareMonitor installata insieme al monitor.
# Il driver PawnIO resta: si toglie da Impostazioni > App > App installate.

param(
    [ValidateSet('utente', 'sistema')]
    [string]$Fase = 'utente',
    [switch]$SoloFunzioni
)

$ErrorActionPreference = 'Stop'

$NomeApp       = 'Monitor PC'
$Dest          = Join-Path $env:ProgramFiles $NomeApp
$NomeTask      = 'LibreHardwareMonitor'
$ChiaveDisinst = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\MonitorPC'
$FileStato     = 'installazione.json'

function Scrivi {
    param([string]$Testo = '', [string]$Colore = 'Gray')
    Write-Host $Testo -ForegroundColor $Colore
}

function Test-Amministratore {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Il processo non deve "stare" nella cartella che va cancellata.
function Exit-Cartella {
    try {
        Set-Location -LiteralPath $env:TEMP
        [Environment]::CurrentDirectory = $env:TEMP
    } catch { }
}

function Remove-CollegamentiUtente {
    foreach ($nome in 'Desktop', 'Startup') {
        try {
            $lnk = Join-Path ([Environment]::GetFolderPath($nome)) 'Monitor PC.lnk'
            if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }
        } catch { }
    }
}

function Read-Stato {
    $f = Join-Path $Dest $FileStato
    if (Test-Path -LiteralPath $f) {
        try { return (Get-Content -LiteralPath $f -Raw | ConvertFrom-Json) } catch { }
    }
    return $null
}

# Vero se l'attivita' pianificata avvia un eseguibile dentro la cartella indicata.
function Test-AvvioNostro {
    param([string]$Cartella)
    try {
        $t = Get-ScheduledTask -TaskName $NomeTask -ErrorAction Stop
        foreach ($a in @($t.Actions)) {
            if ("$($a.Execute)".Trim('"').StartsWith($Cartella, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
    } catch { }
    return $false
}

function Invoke-FaseSistema {
    Exit-Cartella
    $stato = Read-Stato
    $nostra = Join-Path $Dest 'LibreHardwareMonitor'

    Scrivi '[1/3] Fermo LibreHardwareMonitor' 'White'
    $fermati = 0
    foreach ($p in @(Get-Process -Name 'LibreHardwareMonitor' -ErrorAction SilentlyContinue)) {
        $percorso = $null
        try { $percorso = $p.Path } catch { }
        if ($percorso -and $percorso.StartsWith($nostra, [StringComparison]::OrdinalIgnoreCase)) {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            $fermati++
        }
    }
    if ($fermati -gt 0) { Start-Sleep -Seconds 2 }

    Scrivi '[2/3] Tolgo l''avvio automatico' 'White'
    $togliTask = $false
    if ($stato -and $stato.taskCreato) { $togliTask = $true }
    if (Test-AvvioNostro $nostra) { $togliTask = $true }
    if ($togliTask) {
        try {
            Unregister-ScheduledTask -TaskName $NomeTask -Confirm:$false -ErrorAction Stop
        } catch {
            try { & schtasks.exe /Delete /TN $NomeTask /F 2>$null | Out-Null } catch { }
        }
    }

    Scrivi '[3/3] Cancello il programma' 'White'
    try {
        if (Test-Path -LiteralPath $ChiaveDisinst) { Remove-Item -LiteralPath $ChiaveDisinst -Recurse -Force }
    } catch { }
    for ($i = 0; $i -lt 6; $i++) {
        if (-not (Test-Path -LiteralPath $Dest)) { break }
        try { Remove-Item -LiteralPath $Dest -Recurse -Force -ErrorAction Stop } catch { Start-Sleep -Seconds 1 }
    }
    if (Test-Path -LiteralPath $Dest) {
        throw "Non riesco a cancellare $Dest : chiudi il monitor e LibreHardwareMonitor, poi cancellala a mano."
    }
}

function Invoke-FaseUtente {
    try { $Host.UI.RawUI.WindowTitle = 'Monitor PC - disinstallazione' } catch { }
    Exit-Cartella
    Scrivi ''
    Scrivi '  MONITOR PC - disinstallazione' 'Cyan'
    Scrivi ''
    if (-not (Test-Path -LiteralPath $Dest)) {
        Remove-CollegamentiUtente
        Scrivi '  Monitor PC non risulta installato su questo PC.'
        return
    }
    $r = Read-Host '  Vuoi togliere Monitor PC da questo PC? [s/N]'
    if (-not ("$r".Trim() -match '^[sSyY]')) {
        Scrivi '  Nessuna modifica.'
        return
    }
    $stato = Read-Stato
    Remove-CollegamentiUtente

    if (Test-Amministratore) {
        Invoke-FaseSistema
    } else {
        Scrivi ''
        Scrivi '  Ora Windows chiede il permesso di amministratore: rispondi Si''.' 'Yellow'
        $argomenti = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath), '-Fase', 'sistema')
        try {
            Start-Process -FilePath 'powershell.exe' -ArgumentList $argomenti -Verb RunAs -Wait
        } catch {
            Scrivi '  Disinstallazione annullata.' 'Red'
            return
        }
    }

    Scrivi ''
    if (Test-Path -LiteralPath $Dest) {
        Scrivi "  La cartella $Dest c'e' ancora: riprova, oppure cancellala a mano." 'Yellow'
    } else {
        Scrivi '  Monitor PC e'' stato tolto.' 'Green'
    }
    if ($stato -and $stato.adottato) {
        Scrivi "  LibreHardwareMonitor c'era gia' prima e resta dov'e': $($stato.lhm)"
    }
    Scrivi '  Il driver PawnIO, se lo avevi installato, resta: si toglie da'
    Scrivi '  Impostazioni > App > App installate > PawnIO.'
}

if ($SoloFunzioni) { return }

if ($Fase -eq 'sistema') {
    try {
        if (-not (Test-Amministratore)) { throw 'Questa fase richiede i permessi di amministratore.' }
        Invoke-FaseSistema
        exit 0
    } catch {
        Scrivi ''
        Scrivi "  ERRORE: $($_.Exception.Message)" 'Red'
        Scrivi ''
        [void](Read-Host '  Premi INVIO per chiudere')
        exit 1
    }
} else {
    try {
        Invoke-FaseUtente
    } catch {
        Scrivi ''
        Scrivi "  ERRORE: $($_.Exception.Message)" 'Red'
    }
    Scrivi ''
    [void](Read-Host '  Premi INVIO per chiudere')
}
