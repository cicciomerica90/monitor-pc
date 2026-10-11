# Monitor PC - installazione
# Si avvia con un doppio clic su "Installa.bat".
#
# Cosa fa:
#   1. copia il programma in "C:\Program Files\Monitor PC"
#   2. scarica LibreHardwareMonitor (il lettore dei sensori) da GitHub;
#      se non c'e' rete usa LibreHardwareMonitor.zip, se lo trovi accanto a questo file
#   3. gli attiva il server web locale e l'avvio ridotto a icona
#   4. lo fa partire da solo a ogni accesso a Windows
#   5. crea il collegamento "Monitor PC" sul desktop
#
# Il file e' volutamente senza lettere accentate: Windows PowerShell 5.1
# legge gli script senza BOM come ANSI e le rovinerebbe.

param(
    [ValidateSet('utente', 'sistema')]
    [string]$Fase = 'utente',
    [switch]$SoloFunzioni
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$NomeApp       = 'Monitor PC'
$Versione      = '1.0'
$Sorgente      = $PSScriptRoot
$Dest          = Join-Path $env:ProgramFiles $NomeApp
$UrlLhm        = 'https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases/latest/download/LibreHardwareMonitor.zip'
$UrlDati       = 'http://localhost:8085/data.json'
$NomeTask      = 'LibreHardwareMonitor'
$ChiaveDisinst = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\MonitorPC'
$FileStato     = 'installazione.json'
$script:Riuscito = $false

# ---------------------------------------------------------------- funzioni

function Scrivi {
    param([string]$Testo = '', [string]$Colore = 'Gray')
    Write-Host $Testo -ForegroundColor $Colore
}

function Test-Amministratore {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Vero se LibreHardwareMonitor sta pubblicando i sensori su questo PC.
function Test-ServerSensori {
    param([string]$Url = $UrlDati, [int]$Secondi = 3)
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $Secondi
        $testo = $r.Content
        if ($testo -is [byte[]]) { $testo = [Text.Encoding]::UTF8.GetString($testo) }
        return ($r.StatusCode -eq 200 -and "$testo" -match '"Children"')
    } catch {
        return $false
    }
}

# Vero se lo zip contiene davvero LibreHardwareMonitor.exe.
function Test-ZipLhm {
    param([string]$Zip)
    if (-not (Test-Path -LiteralPath $Zip)) { return $false }
    if ((Get-Item -LiteralPath $Zip).Length -lt 1MB) { return $false }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $a = [System.IO.Compression.ZipFile]::OpenRead($Zip)
        try {
            foreach ($e in $a.Entries) {
                if ($e.FullName -eq 'LibreHardwareMonitor.exe') { return $true }
            }
            return $false
        } finally {
            $a.Dispose()
        }
    } catch {
        return $false
    }
}

# Restituisce il percorso di uno zip valido: prima l'ultima versione da GitHub,
# poi la copia inclusa nella cartella di installazione.
function Get-ZipLhm {
    param([string]$Url, [string]$CartellaTemp, [string]$ZipIncluso)
    $scaricato = Join-Path $CartellaTemp 'LibreHardwareMonitor-scaricato.zip'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
    try {
        if (Test-Path -LiteralPath $scaricato) { Remove-Item -LiteralPath $scaricato -Force }
        Invoke-WebRequest -Uri $Url -OutFile $scaricato -UseBasicParsing -TimeoutSec 90
        if (Test-ZipLhm $scaricato) {
            Scrivi '      scaricata l''ultima versione da GitHub' 'DarkGray'
            return $scaricato
        }
    } catch { }
    if ($ZipIncluso -and (Test-ZipLhm $ZipIncluso)) {
        Scrivi '      download non riuscito: uso LibreHardwareMonitor.zip di questa cartella' 'DarkGray'
        return $ZipIncluso
    }
    throw 'Non riesco a scaricare LibreHardwareMonitor. Controlla la connessione, oppure scarica LibreHardwareMonitor.zip dalla sua pagina su GitHub e mettilo accanto a Installa.bat.'
}

# Scrive (o aggiorna, lasciando intatto il resto) il file di impostazioni di LibreHardwareMonitor.
function Set-ConfigLhm {
    param([string]$File, [hashtable]$Valori)
    $doc = New-Object System.Xml.XmlDocument
    $letto = $false
    if (Test-Path -LiteralPath $File) {
        try {
            $doc.Load($File)
            if ($doc.SelectSingleNode('/configuration')) { $letto = $true }
        } catch {
            $letto = $false
        }
    }
    if (-not $letto) {
        $doc = New-Object System.Xml.XmlDocument
        [void]$doc.AppendChild($doc.CreateXmlDeclaration('1.0', 'utf-8', $null))
        [void]$doc.AppendChild($doc.CreateElement('configuration'))
    }
    $conf = $doc.SelectSingleNode('/configuration')
    $app = $conf.SelectSingleNode('appSettings')
    if (-not $app) {
        $app = $doc.CreateElement('appSettings')
        [void]$conf.AppendChild($app)
    }
    foreach ($chiave in $Valori.Keys) {
        $nodo = $null
        foreach ($n in $app.SelectNodes('add')) {
            if ($n.GetAttribute('key') -eq $chiave) { $nodo = $n }
        }
        if (-not $nodo) {
            $nodo = $doc.CreateElement('add')
            $nodo.SetAttribute('key', $chiave)
            [void]$app.AppendChild($nodo)
        }
        $nodo.SetAttribute('value', [string]$Valori[$chiave])
    }
    $doc.Save($File)
}

# Definizione dell'attivita' pianificata: all'accesso, con i privilegi piu' alti
# (senza richiesta di conferma), senza limite di durata, anche a batteria.
function New-XmlAvvio {
    param([string]$Exe)
    $e = [Security.SecurityElement]::Escape($Exe)
    $d = [Security.SecurityElement]::Escape((Split-Path -Parent $Exe))
    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Avvia LibreHardwareMonitor per Monitor PC</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <GroupId>S-1-5-32-545</GroupId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>false</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$e</Command>
      <WorkingDirectory>$d</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
}

function Register-AvvioLhm {
    param([string]$Exe)
    $xml = New-XmlAvvio $Exe
    try {
        Register-ScheduledTask -TaskName $NomeTask -Xml $xml -Force | Out-Null
        return
    } catch { }
    # seconda strada: schtasks con lo stesso XML
    $f = Join-Path $env:TEMP 'monitor-pc-avvio.xml'
    [IO.File]::WriteAllText($f, $xml, [Text.Encoding]::Unicode)
    & schtasks.exe /Create /TN $NomeTask /XML $f /F | Out-Null
    $esito = $LASTEXITCODE
    Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    if ($esito -ne 0) { throw 'Non riesco a creare l''avvio automatico di LibreHardwareMonitor.' }
}

function Test-AvvioEsistente {
    try {
        return [bool](Get-ScheduledTask -TaskName $NomeTask -ErrorAction Stop)
    } catch {
        return $false
    }
}

# Processi LibreHardwareMonitor in esecuzione, con il percorso dell'eseguibile.
function Get-LhmAttivi {
    $lista = @()
    foreach ($p in @(Get-Process -Name 'LibreHardwareMonitor' -ErrorAction SilentlyContinue)) {
        $percorso = $null
        try { $percorso = $p.Path } catch { }
        $lista += New-Object PSObject -Property @{ Id = $p.Id; Percorso = $percorso }
    }
    return $lista
}

function Stop-LhmIn {
    param([string]$Cartella)
    $fermati = 0
    foreach ($p in @(Get-LhmAttivi)) {
        if ($p.Percorso -and $p.Percorso.StartsWith($Cartella, [StringComparison]::OrdinalIgnoreCase)) {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            $fermati++
        }
    }
    if ($fermati -gt 0) { Start-Sleep -Seconds 2 }
}

# Percorso Windows -> indirizzo file:/// con gli spazi codificati.
function ConvertTo-UrlFile {
    param([string]$Percorso)
    $parti = ($Percorso -replace '\\', '/').Split('/')
    $out = @()
    foreach ($s in $parti) {
        if ($s -match '^[A-Za-z]:$') { $out += $s } else { $out += [Uri]::EscapeDataString($s) }
    }
    return 'file:///' + ($out -join '/')
}

# Edge, Chrome o Brave: servono per aprire il monitor in una finestra senza barre.
function Get-Browser {
    foreach ($nome in 'msedge.exe', 'chrome.exe', 'brave.exe') {
        foreach ($radice in 'HKLM:', 'HKCU:') {
            $chiave = "$radice\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$nome"
            try {
                if (Test-Path -LiteralPath $chiave) {
                    $p = (Get-Item -LiteralPath $chiave).GetValue('')
                    if ($p) {
                        $p = "$p".Trim('"')
                        if (Test-Path -LiteralPath $p) { return $p }
                    }
                }
            } catch { }
        }
    }
    return $null
}

function New-Collegamento {
    param([string]$File, [string]$Destinazione, [string]$Argomenti = '', [string]$Icona = '', [string]$Cartella = '')
    $shell = New-Object -ComObject WScript.Shell
    $c = $shell.CreateShortcut($File)
    $c.TargetPath = $Destinazione
    $c.Arguments = $Argomenti
    if ($Cartella) { $c.WorkingDirectory = $Cartella }
    if ($Icona) { $c.IconLocation = "$Icona,0" }
    $c.Description = 'Temperature, frequenze e carico di CPU e GPU'
    $c.Save()
}

# Crea il collegamento al monitor nella cartella indicata. Restituisce il percorso creato.
function New-CollegamentoMonitor {
    param([string]$Cartella)
    $html = Join-Path $Dest 'Monitor PC.html'
    $ico = Join-Path $Dest 'monitor.ico'
    $lnk = Join-Path $Cartella 'Monitor PC.lnk'
    $browser = Get-Browser
    if ($browser) {
        New-Collegamento -File $lnk -Destinazione $browser -Argomenti ('--app="{0}"' -f (ConvertTo-UrlFile $html)) -Icona $ico -Cartella $Dest
    } else {
        New-Collegamento -File $lnk -Destinazione $html -Icona $ico -Cartella $Dest
    }
    return $lnk
}

# ---------------------------------------------------------------- fase "sistema" (con i permessi di amministratore)

function Invoke-FaseSistema {
    Scrivi ''
    Scrivi '[1/5] Copio il programma' 'White'
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    foreach ($f in 'Monitor PC.html', 'monitor.ico', 'disinstalla.ps1', 'Disinstalla.bat') {
        $da = Join-Path $Sorgente $f
        if (-not (Test-Path -LiteralPath $da)) { throw "Nella cartella di installazione manca il file: $f" }
        Copy-Item -LiteralPath $da -Destination (Join-Path $Dest $f) -Force
    }
    Scrivi "      $Dest" 'DarkGray'

    Scrivi '[2/5] LibreHardwareMonitor, il lettore dei sensori' 'White'
    $nostra = Join-Path $Dest 'LibreHardwareMonitor'
    $adottato = $false
    $lhmDir = $nostra
    foreach ($p in @(Get-LhmAttivi)) {
        if ($p.Percorso -and -not $p.Percorso.StartsWith($nostra, [StringComparison]::OrdinalIgnoreCase)) {
            # sul PC ce n'e' gia' uno in funzione: si usa quello, senza installarne un secondo
            $adottato = $true
            $lhmDir = Split-Path -Parent $p.Percorso
        }
    }
    if ($adottato) {
        Scrivi "      ne hai gia' uno in funzione, uso quello: $lhmDir" 'DarkGray'
    } else {
        $zip = Get-ZipLhm -Url $UrlLhm -CartellaTemp $env:TEMP -ZipIncluso (Join-Path $Sorgente 'LibreHardwareMonitor.zip')
        Stop-LhmIn $nostra
        New-Item -ItemType Directory -Path $nostra -Force | Out-Null
        Expand-Archive -LiteralPath $zip -DestinationPath $nostra -Force
    }
    $exe = Join-Path $lhmDir 'LibreHardwareMonitor.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw "Non trovo $exe" }

    Scrivi '[3/5] Attivo il server dei sensori (solo su questo PC, porta 8085)' 'White'
    Stop-LhmIn $lhmDir
    $impostazioni = @{ runWebServerMenuItem = 'true'; listenerPort = '8085' }
    if (-not $adottato) {
        # parte ridotto a icona vicino all'orologio e ci resta anche se chiudi la finestra
        $impostazioni['startMinMenuItem'] = 'true'
        $impostazioni['minTrayMenuItem'] = 'true'
        $impostazioni['minCloseMenuItem'] = 'true'
    }
    Set-ConfigLhm -File (Join-Path $lhmDir 'LibreHardwareMonitor.config') -Valori $impostazioni

    Scrivi '[4/5] Avvio automatico a ogni accesso a Windows' 'White'
    $taskCreato = $false
    if ($adottato -and (Test-AvvioEsistente)) {
        Scrivi "      era gia' impostato, lo lascio com'e'" 'DarkGray'
    } else {
        Register-AvvioLhm $exe
        $taskCreato = $true
    }

    Scrivi '[5/5] Registro il programma tra le app installate' 'White'
    try {
        New-Item -Path $ChiaveDisinst -Force | Out-Null
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $cmd = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}"' -f $ps, (Join-Path $Dest 'disinstalla.ps1')
        Set-ItemProperty -Path $ChiaveDisinst -Name 'DisplayName' -Value $NomeApp
        Set-ItemProperty -Path $ChiaveDisinst -Name 'DisplayVersion' -Value $Versione
        Set-ItemProperty -Path $ChiaveDisinst -Name 'InstallLocation' -Value $Dest
        Set-ItemProperty -Path $ChiaveDisinst -Name 'DisplayIcon' -Value (Join-Path $Dest 'monitor.ico')
        Set-ItemProperty -Path $ChiaveDisinst -Name 'UninstallString' -Value $cmd
        Set-ItemProperty -Path $ChiaveDisinst -Name 'NoModify' -Value 1 -Type DWord
        Set-ItemProperty -Path $ChiaveDisinst -Name 'NoRepair' -Value 1 -Type DWord
    } catch {
        Scrivi '      non riuscito (non e'' grave: resta "Disinstalla.bat")' 'DarkYellow'
    }

    $stato = @{
        versione   = $Versione
        quando     = (Get-Date).ToString('s')
        lhm        = $lhmDir
        adottato   = $adottato
        taskCreato = $taskCreato
    }
    ($stato | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $Dest $FileStato) -Encoding ASCII

    # avvio subito, passando dall'attivita' pianificata: cosi' si prova anche quella
    try { Start-ScheduledTask -TaskName $NomeTask } catch { }
    $partito = $false
    for ($i = 0; $i -lt 10 -and -not $partito; $i++) {
        Start-Sleep -Seconds 1
        if (@(Get-LhmAttivi).Count -gt 0) { $partito = $true }
    }
    if (-not $partito) {
        Start-Process -FilePath $exe -WorkingDirectory $lhmDir
    }
}

# ---------------------------------------------------------------- fase "utente" (quella che parte col doppio clic)

function Invoke-FaseUtente {
    try { $Host.UI.RawUI.WindowTitle = 'Monitor PC - installazione' } catch { }
    Scrivi ''
    Scrivi '  MONITOR PC' 'Cyan'
    Scrivi '  Temperature, frequenze e carico di CPU e GPU sul monitor piccolo'
    Scrivi ''
    Scrivi '  Questa installazione:'
    Scrivi "   - copia il programma in $Dest"
    Scrivi '   - installa LibreHardwareMonitor, il programma gratuito che legge i sensori'
    Scrivi '   - lo fa partire da solo, ridotto a icona, a ogni accensione'
    Scrivi '   - mette il collegamento "Monitor PC" sul desktop'
    Scrivi ''
    $r = Read-Host '  Vuoi che anche il monitor si apra da solo a ogni accensione? [S/n]'
    $avvioAuto = -not ("$r".Trim() -match '^[nN]')
    Scrivi ''
    Scrivi '  Ora Windows chiede il permesso di amministratore: rispondi Si''.' 'Yellow'
    [void](Read-Host '  Premi INVIO per installare (chiudi la finestra per annullare)')

    $inizio = Get-Date
    if (Test-Amministratore) {
        Invoke-FaseSistema
    } else {
        $argomenti = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath), '-Fase', 'sistema')
        try {
            Start-Process -FilePath 'powershell.exe' -ArgumentList $argomenti -Verb RunAs -Wait
        } catch {
            Scrivi ''
            Scrivi '  Installazione annullata: senza quel permesso non si possono leggere i sensori.' 'Red'
            return
        }
    }

    # la fase con i permessi lascia un file di stato: se e' fresco, e' andata a buon fine
    $fatto = $false
    $fileStato = Join-Path $Dest $FileStato
    if (Test-Path -LiteralPath $fileStato) {
        if ((Get-Item -LiteralPath $fileStato).LastWriteTime -ge $inizio.AddSeconds(-5)) { $fatto = $true }
    }
    if (-not $fatto) {
        Scrivi ''
        Scrivi '  L''installazione non e'' arrivata in fondo. Riprova con un doppio clic su Installa.bat.' 'Red'
        return
    }

    Scrivi ''
    Scrivi '  Aspetto che i sensori rispondano...' 'White'
    Scrivi '  Se compare la finestra "PawnIO is not installed", premi OK e completa' 'Yellow'
    Scrivi '  quella installazione: e'' il driver che legge la temperatura della CPU.' 'Yellow'
    Scrivi '  (se non la vedi, cercala nella barra delle applicazioni)' 'DarkGray'
    $pronto = $false
    for ($i = 0; $i -lt 75; $i++) {
        if (Test-ServerSensori) { $pronto = $true; break }
        Write-Host '.' -NoNewline
        Start-Sleep -Seconds 2
    }
    Scrivi ''
    if ($pronto) {
        Scrivi '  I sensori rispondono.' 'Green'
    } else {
        Scrivi '  I sensori non rispondono ancora. Apri LibreHardwareMonitor dall''icona vicino' 'Yellow'
        Scrivi '  all''orologio e controlla che in Options > Remote Web Server sia spuntato Run.' 'Yellow'
    }

    # collegamenti: sul desktop e, se richiesto, tra i programmi che partono all'accesso
    $lnkDesktop = $null
    try {
        $lnkDesktop = New-CollegamentoMonitor ([Environment]::GetFolderPath('Desktop'))
        Scrivi '  Collegamento "Monitor PC" creato sul desktop.' 'Green'
    } catch {
        Scrivi "  Non sono riuscito a creare il collegamento sul desktop: apri a mano $Dest\Monitor PC.html" 'Yellow'
    }
    try {
        $cartellaAvvio = [Environment]::GetFolderPath('Startup')
        if ($avvioAuto) {
            [void](New-CollegamentoMonitor $cartellaAvvio)
            Scrivi '  Il monitor si aprira'' da solo a ogni accensione.' 'Green'
        } else {
            $lnkAvvio = Join-Path $cartellaAvvio 'Monitor PC.lnk'
            if (Test-Path -LiteralPath $lnkAvvio) { Remove-Item -LiteralPath $lnkAvvio -Force }
        }
    } catch {
        Scrivi '  Non sono riuscito a impostare l''apertura automatica del monitor.' 'Yellow'
    }

    # apro il monitor
    try {
        if ($lnkDesktop -and (Test-Path -LiteralPath $lnkDesktop)) {
            Start-Process -FilePath $lnkDesktop
        } else {
            Start-Process -FilePath (Join-Path $Dest 'Monitor PC.html')
        }
    } catch { }

    Scrivi ''
    Scrivi '  FATTO.' 'Green'
    Scrivi '  Trascina la finestra del monitor sullo schermo piccolo e premi F per lo schermo intero.'
    Scrivi '  Le soglie di allarme si cambiano col tasto S.'
    Scrivi '  Per togliere tutto: Impostazioni > App > App installate > Monitor PC.'
    $script:Riuscito = $true
}

# ---------------------------------------------------------------- avvio

if ($SoloFunzioni) { return }

if ($Fase -eq 'sistema') {
    try {
        try { $Host.UI.RawUI.WindowTitle = 'Monitor PC - installazione (amministratore)' } catch { }
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
    if ($script:Riuscito) { exit 0 } else { exit 1 }
}
