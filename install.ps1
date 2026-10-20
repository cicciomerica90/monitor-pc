# Monitor PC - installer
# Start it by double-clicking "Install.bat".
#
# What it does:
#   1. copies the program to "C:\Program Files\Monitor PC"
#   2. downloads LibreHardwareMonitor (the sensor reader) from GitHub;
#      if a LibreHardwareMonitor.zip sits next to this file, that is the fallback
#   3. turns on its local web server and makes it start minimized to the tray
#   4. makes it start at every Windows logon (scheduled task, no UAC prompt)
#   5. creates the "Monitor PC" shortcut on the desktop
#
# Messages are shown in Italian on an Italian Windows, in English otherwise.
# This file is plain ASCII on purpose: Windows PowerShell 5.1 reads scripts
# without a BOM as ANSI and would garble accented letters.

param(
    [ValidateSet('user', 'system')]
    [string]$Stage = 'user',
    [ValidateSet('', 'it', 'en')]
    [string]$Lang = '',
    [switch]$FunctionsOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$AppName      = 'Monitor PC'
$Version      = '1.1'
$Source       = $PSScriptRoot
$Dest         = Join-Path $env:ProgramFiles $AppName
$LhmUrl       = 'https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases/latest/download/LibreHardwareMonitor.zip'
$DataUrl      = 'http://localhost:8085/data.json'
$TaskName     = 'LibreHardwareMonitor'
$UninstallKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\MonitorPC'
$StateFile    = 'install-state.json'
$script:Succeeded = $false
$script:ExitCode = 1

if (-not $Lang) {
    $Lang = 'en'
    try { if ((Get-UICulture).TwoLetterISOLanguageName -eq 'it') { $Lang = 'it' } } catch { }
}

# ---------------------------------------------------------------- messages

$Messages = @{
    en = @{
        Title           = 'Monitor PC - setup'
        TitleAdmin      = 'Monitor PC - setup (administrator)'
        Tagline         = '  CPU and GPU temperature, clock and load on a small monitor'
        WillDo          = '  This setup will:'
        WillCopy        = '   - copy the program to {0}'
        WillLhm         = '   - install LibreHardwareMonitor, the free program that reads the sensors'
        WillStartup     = '   - make it start by itself, minimized, at every logon'
        WillShortcut    = '   - put a "Monitor PC" shortcut on the desktop'
        AskAutostart    = '  Should the monitor also open by itself at every logon? [Y/n]'
        UacNotice       = '  Windows will now ask for administrator permission: answer Yes.'
        PressEnterGo    = '  Press ENTER to install (close this window to cancel)'
        Cancelled       = '  Setup cancelled: without that permission the sensors cannot be read.'
        NotCompleted    = '  Setup did not complete. Try again by double-clicking Install.bat.'
        Step1           = '[1/5] Copying the program'
        Step2           = '[2/5] LibreHardwareMonitor, the sensor reader'
        Step3           = '[3/5] Turning on the sensor server (this PC only, port 8085)'
        Step4           = '[4/5] Start at every Windows logon'
        Step5           = '[5/5] Registering the program in the installed apps list'
        MissingFile     = 'A file is missing from the setup folder: {0}'
        Downloaded      = '      latest version downloaded from GitHub'
        UsedLocalZip    = '      download failed: using LibreHardwareMonitor.zip from this folder'
        DownloadFailed  = 'Cannot download LibreHardwareMonitor. Check the connection, or download LibreHardwareMonitor.zip from its GitHub page and put it next to Install.bat.'
        Adopted         = '      one is already running, using that: {0}'
        ExeNotFound     = 'Cannot find {0}'
        TaskKept        = '      already set up, leaving it as it is'
        TaskFailed      = 'Cannot create the automatic start of LibreHardwareMonitor.'
        RegisterFailed  = '      failed (not serious: "Uninstall.bat" still works)'
        NeedAdmin       = 'This stage needs administrator permission.'
        Waiting         = '  Waiting for the sensors to answer...'
        PawnIo1         = '  If a window says "PawnIO is not installed", press OK and complete that'
        PawnIo2         = '  setup: it is the driver that reads the CPU temperature.'
        PawnIo3         = '  (if you do not see it, look for it in the taskbar)'
        SensorsOk       = '  The sensors are answering.'
        SensorsNo1      = '  The sensors are not answering yet. Open LibreHardwareMonitor from its icon'
        SensorsNo2      = '  near the clock and check that Options > Remote Web Server > Run is ticked.'
        ShortcutOk      = '  "Monitor PC" shortcut created on the desktop.'
        ShortcutFailed  = '  Could not create the desktop shortcut: open {0} by hand'
        AutostartOk     = '  The monitor will open by itself at every logon.'
        AutostartFailed = '  Could not set the monitor to open automatically.'
        Done            = '  DONE.'
        Tip1            = '  Drag the monitor window to the small screen and press F for full screen.'
        Tip2            = '  Press S to change the alarm thresholds and the language.'
        Tip3            = '  To remove everything: Settings > Apps > Installed apps > Monitor PC.'
        Error           = '  ERROR: {0}'
        PressEnterClose = '  Press ENTER to close'
        ShortcutDesc    = 'CPU and GPU temperature, clock and load'
    }
    it = @{
        Title           = 'Monitor PC - installazione'
        TitleAdmin      = 'Monitor PC - installazione (amministratore)'
        Tagline         = '  Temperature, frequenze e carico di CPU e GPU sul monitor piccolo'
        WillDo          = '  Questa installazione:'
        WillCopy        = '   - copia il programma in {0}'
        WillLhm         = '   - installa LibreHardwareMonitor, il programma gratuito che legge i sensori'
        WillStartup     = '   - lo fa partire da solo, ridotto a icona, a ogni accensione'
        WillShortcut    = '   - mette il collegamento "Monitor PC" sul desktop'
        AskAutostart    = '  Vuoi che anche il monitor si apra da solo a ogni accensione? [S/n]'
        UacNotice       = "  Ora Windows chiede il permesso di amministratore: rispondi Si'."
        PressEnterGo    = '  Premi INVIO per installare (chiudi la finestra per annullare)'
        Cancelled       = '  Installazione annullata: senza quel permesso non si possono leggere i sensori.'
        NotCompleted    = "  L'installazione non e' arrivata in fondo. Riprova con un doppio clic su Install.bat."
        Step1           = '[1/5] Copio il programma'
        Step2           = '[2/5] LibreHardwareMonitor, il lettore dei sensori'
        Step3           = '[3/5] Attivo il server dei sensori (solo su questo PC, porta 8085)'
        Step4           = '[4/5] Avvio automatico a ogni accesso a Windows'
        Step5           = '[5/5] Registro il programma tra le app installate'
        MissingFile     = 'Nella cartella di installazione manca il file: {0}'
        Downloaded      = "      scaricata l'ultima versione da GitHub"
        UsedLocalZip    = '      download non riuscito: uso LibreHardwareMonitor.zip di questa cartella'
        DownloadFailed  = 'Non riesco a scaricare LibreHardwareMonitor. Controlla la connessione, oppure scarica LibreHardwareMonitor.zip dalla sua pagina su GitHub e mettilo accanto a Install.bat.'
        Adopted         = "      ne hai gia' uno in funzione, uso quello: {0}"
        ExeNotFound     = 'Non trovo {0}'
        TaskKept        = "      era gia' impostato, lo lascio com'e'"
        TaskFailed      = "Non riesco a creare l'avvio automatico di LibreHardwareMonitor."
        RegisterFailed  = '      non riuscito (non e'' grave: resta "Uninstall.bat")'
        NeedAdmin       = 'Questa fase richiede i permessi di amministratore.'
        Waiting         = '  Aspetto che i sensori rispondano...'
        PawnIo1         = '  Se compare la finestra "PawnIO is not installed", premi OK e completa'
        PawnIo2         = "  quella installazione: e' il driver che legge la temperatura della CPU."
        PawnIo3         = '  (se non la vedi, cercala nella barra delle applicazioni)'
        SensorsOk       = '  I sensori rispondono.'
        SensorsNo1      = "  I sensori non rispondono ancora. Apri LibreHardwareMonitor dall'icona vicino"
        SensorsNo2      = "  all'orologio e controlla che in Options > Remote Web Server sia spuntato Run."
        ShortcutOk      = '  Collegamento "Monitor PC" creato sul desktop.'
        ShortcutFailed  = '  Non sono riuscito a creare il collegamento sul desktop: apri a mano {0}'
        AutostartOk     = "  Il monitor si aprira' da solo a ogni accensione."
        AutostartFailed = "  Non sono riuscito a impostare l'apertura automatica del monitor."
        Done            = '  FATTO.'
        Tip1            = '  Trascina la finestra del monitor sullo schermo piccolo e premi F per lo schermo intero.'
        Tip2            = '  Con S cambi le soglie di allarme e la lingua.'
        Tip3            = '  Per togliere tutto: Impostazioni > App > App installate > Monitor PC.'
        Error           = '  ERRORE: {0}'
        PressEnterClose = '  Premi INVIO per chiudere'
        ShortcutDesc    = 'Temperature, frequenze e carico di CPU e GPU'
    }
}

# Message in the current language; {0}, {1}... are filled with the extra arguments.
function L {
    param([string]$Key)
    $s = $Messages[$Lang][$Key]
    if ($null -eq $s) { $s = $Messages['en'][$Key] }
    if ($null -eq $s) { return $Key }
    if ($args.Count -gt 0) { return ($s -f $args) }
    return $s
}

# ---------------------------------------------------------------- functions

# Desktop, Startup...: a separate function so the tests never touch the real folders.
function Get-SpecialFolder {
    param([string]$Name)
    return [Environment]::GetFolderPath($Name)
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

# True when LibreHardwareMonitor is publishing the sensors on this PC.
function Test-SensorServer {
    param([string]$Url = $DataUrl, [int]$Seconds = 3)
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $Seconds
        $text = $r.Content
        if ($text -is [byte[]]) { $text = [Text.Encoding]::UTF8.GetString($text) }
        return ($r.StatusCode -eq 200 -and "$text" -match '"Children"')
    } catch {
        return $false
    }
}

# True when the zip really contains LibreHardwareMonitor.exe.
function Test-LhmZip {
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

# Returns the path of a valid zip: the latest release from GitHub first,
# then a LibreHardwareMonitor.zip found next to the installer.
function Get-LhmZip {
    param([string]$Url, [string]$TempFolder, [string]$LocalZip)
    $downloaded = Join-Path $TempFolder 'LibreHardwareMonitor-download.zip'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
    try {
        if (Test-Path -LiteralPath $downloaded) { Remove-Item -LiteralPath $downloaded -Force }
        Invoke-WebRequest -Uri $Url -OutFile $downloaded -UseBasicParsing -TimeoutSec 90
        if (Test-LhmZip $downloaded) {
            Say (L 'Downloaded') 'DarkGray'
            return $downloaded
        }
    } catch { }
    if ($LocalZip -and (Test-LhmZip $LocalZip)) {
        Say (L 'UsedLocalZip') 'DarkGray'
        return $LocalZip
    }
    throw (L 'DownloadFailed')
}

# Writes (or updates, leaving everything else untouched) LibreHardwareMonitor's settings file.
function Set-LhmConfig {
    param([string]$File, [hashtable]$Values)
    $doc = New-Object System.Xml.XmlDocument
    $loaded = $false
    if (Test-Path -LiteralPath $File) {
        try {
            $doc.Load($File)
            if ($doc.SelectSingleNode('/configuration')) { $loaded = $true }
        } catch {
            $loaded = $false
        }
    }
    if (-not $loaded) {
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
    foreach ($key in $Values.Keys) {
        $node = $null
        foreach ($n in $app.SelectNodes('add')) {
            if ($n.GetAttribute('key') -eq $key) { $node = $n }
        }
        if (-not $node) {
            $node = $doc.CreateElement('add')
            $node.SetAttribute('key', $key)
            [void]$app.AppendChild($node)
        }
        $node.SetAttribute('value', [string]$Values[$key])
    }
    $doc.Save($File)
}

# Scheduled task definition: at logon, with the highest privileges the user has
# (so no UAC prompt), no time limit, also on battery.
function New-StartupTaskXml {
    param([string]$Exe)
    $e = [Security.SecurityElement]::Escape($Exe)
    $d = [Security.SecurityElement]::Escape((Split-Path -Parent $Exe))
    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Starts LibreHardwareMonitor for Monitor PC</Description>
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

function Register-LhmStartup {
    param([string]$Exe)
    $xml = New-StartupTaskXml $Exe
    try {
        Register-ScheduledTask -TaskName $TaskName -Xml $xml -Force | Out-Null
        return
    } catch { }
    # second route: schtasks with the same XML
    $f = Join-Path $env:TEMP 'monitor-pc-startup.xml'
    [IO.File]::WriteAllText($f, $xml, [Text.Encoding]::Unicode)
    & schtasks.exe /Create /TN $TaskName /XML $f /F | Out-Null
    $code = $LASTEXITCODE
    Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    if ($code -ne 0) { throw (L 'TaskFailed') }
}

function Test-StartupTaskExists {
    try {
        return [bool](Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop)
    } catch {
        return $false
    }
}

# Running LibreHardwareMonitor processes, with the path of their executable.
function Get-RunningLhm {
    $list = @()
    foreach ($p in @(Get-Process -Name 'LibreHardwareMonitor' -ErrorAction SilentlyContinue)) {
        $path = $null
        try { $path = $p.Path } catch { }
        $list += New-Object PSObject -Property @{ Id = $p.Id; ExePath = $path }
    }
    return $list
}

function Stop-LhmIn {
    param([string]$Folder)
    $stopped = 0
    foreach ($p in @(Get-RunningLhm)) {
        if ($p.ExePath -and $p.ExePath.StartsWith($Folder, [StringComparison]::OrdinalIgnoreCase)) {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            $stopped++
        }
    }
    if ($stopped -gt 0) { Start-Sleep -Seconds 2 }
}

# Windows path -> file:/// address with spaces encoded.
function ConvertTo-FileUrl {
    param([string]$Path)
    $parts = ($Path -replace '\\', '/').Split('/')
    $out = @()
    foreach ($s in $parts) {
        if ($s -match '^[A-Za-z]:$') { $out += $s } else { $out += [Uri]::EscapeDataString($s) }
    }
    return 'file:///' + ($out -join '/')
}

# Edge, Chrome or Brave: used to open the monitor in a window without toolbars.
function Get-Browser {
    foreach ($name in 'msedge.exe', 'chrome.exe', 'brave.exe') {
        foreach ($root in 'HKLM:', 'HKCU:') {
            $key = "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$name"
            try {
                if (Test-Path -LiteralPath $key) {
                    $p = (Get-Item -LiteralPath $key).GetValue('')
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

function New-Shortcut {
    param([string]$File, [string]$Target, [string]$Arguments = '', [string]$Icon = '', [string]$Folder = '')
    $shell = New-Object -ComObject WScript.Shell
    $c = $shell.CreateShortcut($File)
    $c.TargetPath = $Target
    $c.Arguments = $Arguments
    if ($Folder) { $c.WorkingDirectory = $Folder }
    if ($Icon) { $c.IconLocation = "$Icon,0" }
    $c.Description = (L 'ShortcutDesc')
    $c.Save()
}

# Creates the monitor shortcut in the given folder. Returns the path it created.
function New-MonitorShortcut {
    param([string]$Folder)
    $html = Join-Path $Dest 'Monitor PC.html'
    $ico = Join-Path $Dest 'monitor.ico'
    $lnk = Join-Path $Folder 'Monitor PC.lnk'
    $browser = Get-Browser
    if ($browser) {
        New-Shortcut -File $lnk -Target $browser -Arguments ('--app="{0}"' -f (ConvertTo-FileUrl $html)) -Icon $ico -Folder $Dest
    } else {
        New-Shortcut -File $lnk -Target $html -Icon $ico -Folder $Dest
    }
    return $lnk
}

# ---------------------------------------------------------------- "system" stage (runs with administrator rights)

function Invoke-SystemStage {
    Say ''
    Say (L 'Step1') 'White'
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    foreach ($f in 'Monitor PC.html', 'monitor.ico', 'uninstall.ps1', 'Uninstall.bat') {
        $from = Join-Path $Source $f
        if (-not (Test-Path -LiteralPath $from)) { throw (L 'MissingFile' $f) }
        Copy-Item -LiteralPath $from -Destination (Join-Path $Dest $f) -Force
    }
    Say "      $Dest" 'DarkGray'

    Say (L 'Step2') 'White'
    $ours = Join-Path $Dest 'LibreHardwareMonitor'
    $adopted = $false
    $lhmDir = $ours
    foreach ($p in @(Get-RunningLhm)) {
        if ($p.ExePath -and -not $p.ExePath.StartsWith($ours, [StringComparison]::OrdinalIgnoreCase)) {
            # one is already running on this PC: use it instead of installing a second copy
            $adopted = $true
            $lhmDir = Split-Path -Parent $p.ExePath
        }
    }
    if ($adopted) {
        Say (L 'Adopted' $lhmDir) 'DarkGray'
    } else {
        $zip = Get-LhmZip -Url $LhmUrl -TempFolder $env:TEMP -LocalZip (Join-Path $Source 'LibreHardwareMonitor.zip')
        Stop-LhmIn $ours
        New-Item -ItemType Directory -Path $ours -Force | Out-Null
        Expand-Archive -LiteralPath $zip -DestinationPath $ours -Force
    }
    $exe = Join-Path $lhmDir 'LibreHardwareMonitor.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw (L 'ExeNotFound' $exe) }

    Say (L 'Step3') 'White'
    Stop-LhmIn $lhmDir
    $settings = @{ runWebServerMenuItem = 'true'; listenerPort = '8085' }
    if (-not $adopted) {
        # start minimized to the tray, and stay there when the window is closed
        $settings['startMinMenuItem'] = 'true'
        $settings['minTrayMenuItem'] = 'true'
        $settings['minCloseMenuItem'] = 'true'
    }
    Set-LhmConfig -File (Join-Path $lhmDir 'LibreHardwareMonitor.config') -Values $settings

    Say (L 'Step4') 'White'
    $taskCreated = $false
    if ($adopted -and (Test-StartupTaskExists)) {
        Say (L 'TaskKept') 'DarkGray'
    } else {
        Register-LhmStartup $exe
        $taskCreated = $true
    }

    Say (L 'Step5') 'White'
    try {
        New-Item -Path $UninstallKey -Force | Out-Null
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $cmd = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}"' -f $ps, (Join-Path $Dest 'uninstall.ps1')
        Set-ItemProperty -Path $UninstallKey -Name 'DisplayName' -Value $AppName
        Set-ItemProperty -Path $UninstallKey -Name 'DisplayVersion' -Value $Version
        Set-ItemProperty -Path $UninstallKey -Name 'InstallLocation' -Value $Dest
        Set-ItemProperty -Path $UninstallKey -Name 'DisplayIcon' -Value (Join-Path $Dest 'monitor.ico')
        Set-ItemProperty -Path $UninstallKey -Name 'UninstallString' -Value $cmd
        Set-ItemProperty -Path $UninstallKey -Name 'NoModify' -Value ([int]1)
        Set-ItemProperty -Path $UninstallKey -Name 'NoRepair' -Value ([int]1)
    } catch {
        Say (L 'RegisterFailed') 'DarkYellow'
    }

    $state = @{
        version     = $Version
        date        = (Get-Date).ToString('s')
        lhm         = $lhmDir
        adopted     = $adopted
        taskCreated = $taskCreated
    }
    ($state | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $Dest $StateFile) -Encoding ASCII

    # start it now through the scheduled task, so the task gets tested too
    try { Start-ScheduledTask -TaskName $TaskName } catch { }
    $started = $false
    for ($i = 0; $i -lt 10 -and -not $started; $i++) {
        Start-Sleep -Seconds 1
        if (@(Get-RunningLhm).Count -gt 0) { $started = $true }
    }
    if (-not $started) {
        Start-Process -FilePath $exe -WorkingDirectory $lhmDir
    }
}

# ---------------------------------------------------------------- "user" stage (the one a double click starts)

function Invoke-UserStage {
    try { $Host.UI.RawUI.WindowTitle = (L 'Title') } catch { }
    Say ''
    Say '  MONITOR PC' 'Cyan'
    Say (L 'Tagline')
    Say ''
    Say (L 'WillDo')
    Say (L 'WillCopy' $Dest)
    Say (L 'WillLhm')
    Say (L 'WillStartup')
    Say (L 'WillShortcut')
    Say ''
    $r = Read-Host (L 'AskAutostart')
    $autostart = -not ("$r".Trim() -match '^[nN]')
    Say ''
    Say (L 'UacNotice') 'Yellow'
    [void](Read-Host (L 'PressEnterGo'))

    $begin = Get-Date
    if (Test-Admin) {
        Invoke-SystemStage
    } else {
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath), '-Stage', 'system', '-Lang', $Lang)
        try {
            Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -Wait
        } catch {
            Say ''
            Say (L 'Cancelled') 'Red'
            return
        }
    }

    # the elevated stage leaves a state file: if it is fresh, it went through
    $done = $false
    $statePath = Join-Path $Dest $StateFile
    if (Test-Path -LiteralPath $statePath) {
        if ((Get-Item -LiteralPath $statePath).LastWriteTime -ge $begin.AddSeconds(-5)) { $done = $true }
    }
    if (-not $done) {
        Say ''
        Say (L 'NotCompleted') 'Red'
        return
    }

    Say ''
    Say (L 'Waiting') 'White'
    Say (L 'PawnIo1') 'Yellow'
    Say (L 'PawnIo2') 'Yellow'
    Say (L 'PawnIo3') 'DarkGray'
    $ready = $false
    for ($i = 0; $i -lt 75; $i++) {
        if (Test-SensorServer) { $ready = $true; break }
        Write-Host '.' -NoNewline
        Start-Sleep -Seconds 2
    }
    Say ''
    if ($ready) {
        Say (L 'SensorsOk') 'Green'
    } else {
        Say (L 'SensorsNo1') 'Yellow'
        Say (L 'SensorsNo2') 'Yellow'
    }

    # shortcuts: on the desktop and, if asked, among the programs that start at logon
    $desktopLnk = $null
    try {
        $desktopLnk = New-MonitorShortcut (Get-SpecialFolder 'Desktop')
        Say (L 'ShortcutOk') 'Green'
    } catch {
        Say (L 'ShortcutFailed' (Join-Path $Dest 'Monitor PC.html')) 'Yellow'
    }
    try {
        $startupFolder = Get-SpecialFolder 'Startup'
        if ($autostart) {
            [void](New-MonitorShortcut $startupFolder)
            Say (L 'AutostartOk') 'Green'
        } else {
            $startupLnk = Join-Path $startupFolder 'Monitor PC.lnk'
            if (Test-Path -LiteralPath $startupLnk) { Remove-Item -LiteralPath $startupLnk -Force }
        }
    } catch {
        Say (L 'AutostartFailed') 'Yellow'
    }

    # open the monitor
    try {
        if ($desktopLnk -and (Test-Path -LiteralPath $desktopLnk)) {
            Start-Process -FilePath $desktopLnk
        } else {
            Start-Process -FilePath (Join-Path $Dest 'Monitor PC.html')
        }
    } catch { }

    Say ''
    Say (L 'Done') 'Green'
    Say (L 'Tip1')
    Say (L 'Tip2')
    Say (L 'Tip3')
    $script:Succeeded = $true
}

# ---------------------------------------------------------------- entry point

# Runs the requested stage and leaves the exit code in $script:ExitCode.
function Invoke-Main {
    if ($Stage -eq 'system') {
        try {
            try { $Host.UI.RawUI.WindowTitle = (L 'TitleAdmin') } catch { }
            if (-not (Test-Admin)) { throw (L 'NeedAdmin') }
            Invoke-SystemStage
            $script:ExitCode = 0
        } catch {
            Say ''
            Say (L 'Error' $_.Exception.Message) 'Red'
            Say ''
            [void](Read-Host (L 'PressEnterClose'))
            $script:ExitCode = 1
        }
        return
    }
    try {
        Invoke-UserStage
    } catch {
        Say ''
        Say (L 'Error' $_.Exception.Message) 'Red'
    }
    Say ''
    [void](Read-Host (L 'PressEnterClose'))
    if ($script:Succeeded) { $script:ExitCode = 0 } else { $script:ExitCode = 1 }
}

if ($FunctionsOnly) { return }
Invoke-Main | Out-Null
exit $script:ExitCode
