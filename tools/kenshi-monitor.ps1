<#
.SYNOPSIS
    Moniteur de session Kenshi : mémoire, liste de mods, plantages, résumé des journaux.

.DESCRIPTION
    Attend kenshi_x64.exe (sans jamais le lancer), mesure la mémoire du jeu et du
    système toutes les -IntervalSec secondes, copie mods.cfg au lancement, puis, à la
    sortie du jeu : copie aussitôt les journaux du jeu (kenshi_info.log, kenshi.log,
    save.log, settings.cfg, mods.cfg) avant qu'un nouveau lancement ne les écrase,
    attend 60 s que Windows écrive ses rapports, note le plantage éventuel (événement
    Windows 1000) et le gel éventuel (événement 1002 « Application Hang », ou code de
    sortie 0xCFFFFFFF : Windows a fermé le jeu qui ne répondait plus), copie le dump
    WER (%LOCALAPPDATA%\CrashDumps), le crashDump*.zip écrit par Kenshi et les dossiers
    de rapport WER AppCrash_kenshi_x64* et AppHang_kenshi_x64*, et écrit
    errors-summary.txt (résumé de kenshi_info.log) et summary.json.
    Un dossier par session : <OutDir>\AAAA-MM-JJ_HH-mm-ss (suffixe -2, -3... si le
    nom existe déjà).
    Le lanceur de Kenshi peut réécrire data\mods.cfg au clic sur Play, après la copie
    mods.cfg.at-launch : mods.cfg.at-exit et mods_loaded (mods réellement chargés
    d'après kenshi_info.log) dans summary.json donnent la liste effective.
    Un fichier monitor.lock dans OutDir empêche deux moniteurs de tourner en même
    temps. Il contient le PID du moniteur, la date de création de son processus et sa
    phase (waiting : attend le jeu ; session : jeu en cours ; finishing : journaux,
    rapports Windows et résumé après la sortie du jeu) ; il est supprimé à la fin.
    Un verrou dont le PID n'existe plus, n'est pas un PowerShell ou a été réattribué
    (moniteur tué par Stop-Process, arrêt de Windows) est reconnu périmé et remplacé.
    -Stop arrête le moniteur désigné par le verrou après cette même vérification,
    supprime le verrou et sort ; un verrou périmé est simplement supprimé.
    Les fichiers écrits sont en UTF-8 sans BOM sous les deux hôtes PowerShell.

.PARAMETER IntervalSec
    Intervalle des mesures de mémoire en secondes (5 par défaut).
.PARAMETER Game
    Dossier du jeu (détection automatique via Steam sinon).
.PARAMETER OutDir
    Dossier des sessions (par défaut : logs\sessions du dépôt).
.PARAMETER Once
    S'arrête après une seule session au lieu d'attendre la suivante.
.PARAMETER WaitTimeoutSec
    Si Kenshi n'est pas apparu au bout de ce délai, le moniteur s'arrête (0 = attente
    sans limite, valeur par défaut). play-kenshi.ps1 passe 600.
.PARAMETER Stop
    Arrête le moniteur désigné par <OutDir>\monitor.lock (s'il tourne vraiment) et
    supprime le verrou. Ne touche ni au jeu ni à Steam.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\kenshi-monitor.ps1
.EXAMPLE
    .\tools\kenshi-monitor.ps1 -Once -IntervalSec 2 -WaitTimeoutSec 600
.EXAMPLE
    .\tools\kenshi-monitor.ps1 -Stop
#>
[CmdletBinding()]
param(
    [int]$IntervalSec = 5,
    [string]$Game,
    [string]$OutDir,
    [switch]$Once,
    [int]$WaitTimeoutSec = 0,
    [switch]$Stop
)
Import-Module (Join-Path $PSScriptRoot 'KenshiTools.psm1') -Force
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot '..\logs\sessions' }
$OutDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir)
$lock = Join-Path $OutDir 'monitor.lock'

# --- -Stop : arrêter le moniteur du verrou, après vérification --------------
if ($Stop) {
    $info = Read-KenshiMonitorLock -Path $lock
    if (-not $info) { Write-Host "Aucun verrou $lock : pas de moniteur à arrêter."; exit 0 }
    if (-not $info.IsLive) {
        Remove-Item -LiteralPath $lock -Force
        Write-Host "Verrou périmé supprimé : $lock ($($info.Reason)). Aucun moniteur à arrêter."
        exit 0
    }
    if ($info.ProcessId -eq $PID) { Write-Error 'Le verrou désigne ce processus.'; exit 1 }
    try { Stop-Process -Id $info.ProcessId -Force -ErrorAction Stop }
    catch { Write-Error "Arrêt impossible du moniteur (PID $($info.ProcessId)) : $($_.Exception.Message)"; exit 1 }
    Start-Sleep 1
    Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
    Write-Host "Moniteur arrêté (PID $($info.ProcessId), phase « $($info.Phase) »), verrou supprimé : $lock"
    exit 0
}

$packCfg = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\modlist\mods.cfg'))
$paths = Get-KenshiPaths -Game $Game
$gameDir = $paths.Game
$rootExe = Join-Path $gameDir 'kenshi_x64.exe'
$reExe = Join-Path $gameDir 'RE_Kenshi\kenshi_x64.exe'
$utf8NoBom = New-Object Text.UTF8Encoding $false
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# --- un seul moniteur à la fois ---------------------------------------------
$existing = Read-KenshiMonitorLock -Path $lock
if ($existing) {
    if ($existing.IsLive -and $existing.ProcessId -ne $PID) {
        Write-Error "Un moniteur tourne déjà (PID $($existing.ProcessId), phase « $($existing.Phase) », verrou $lock) : pas de second moniteur. Pour l'arrêter : kenshi-monitor.ps1 -Stop (même -OutDir)."
        exit 1
    }
    Write-Warning "Verrou périmé ignoré : $lock ($($existing.Reason))"
}
function Set-Phase([string]$Phase, [Nullable[datetime]]$Deadline) {
    try { Set-KenshiMonitorLock -Path $lock -Phase $Phase -Deadline $Deadline } catch { Write-Warning "Verrou non écrit ($lock) : $($_.Exception.Message)" }
}
Set-Phase 'waiting'
Write-Host "Moniteur prêt (PID $PID). Jeu : $gameDir ; sessions : $OutDir. En attente de kenshi_x64.exe..."

function Write-SessionLogSummary([string]$Dir) {
    $info = Join-Path $Dir 'kenshi_info.log'
    if (-not (Test-Path -LiteralPath $info)) { return $null }
    $s = $null
    try {
        $s = Get-KenshiLogSummary -InfoLog $info -PackCfg $packCfg
        [IO.File]::WriteAllLines((Join-Path $Dir 'errors-summary.txt'), [string[]]@($s | Format-KenshiLogSummary), $utf8NoBom)
    }
    catch { Write-Warning "Résumé du journal impossible : $($_.Exception.Message)" }
    $s
}

function New-SessionDir([string]$Parent) {
    $base = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $name = $base; $n = 1
    while ($true) {
        $candidate = Join-Path $Parent $name
        # Sans -Force : si un autre moniteur a créé le même nom dans la seconde, on passe au suivant
        try { New-Item -ItemType Directory -Path $candidate -ErrorAction Stop | Out-Null; return $candidate }
        catch { $n++; $name = '{0}-{1}' -f $base, $n; if ($n -gt 50) { throw } }
    }
}

function Copy-SessionLogs([string]$Dir) {
    foreach ($f in 'kenshi_info.log', 'kenshi.log', 'save.log', 'settings.cfg', 'RE_Kenshi_log.txt') {
        Copy-Item -LiteralPath (Join-Path $gameDir $f) -Destination $Dir -ErrorAction SilentlyContinue
    }
    Copy-Item -LiteralPath $paths.ModsCfg -Destination (Join-Path $Dir 'mods.cfg.at-exit') -ErrorAction SilentlyContinue
}

function Get-SessionProcessInfo($Process, $CimProcess = $null) {
    # Lire ces valeurs tant que le processus est vivant ; le lanceur peut déjà être
    # terminé lorsque WMI est interrogé. Le handle garde StartTime/ExitTime lisibles.
    try { $null = $Process.Handle } catch { }
    $created = $null; $exe = $null
    try { $created = $Process.StartTime } catch { }
    try { $exe = $Process.Path } catch { }
    if (-not $CimProcess) {
        $CimProcess = Get-CimInstance Win32_Process -Filter "ProcessId = $($Process.Id)" -ErrorAction SilentlyContinue
    }
    if (-not $created -and $CimProcess) { $created = $CimProcess.CreationDate }
    if (-not $exe -and $CimProcess) { $exe = $CimProcess.ExecutablePath }
    [pscustomobject]@{
        ProcessId = $Process.Id
        StartTime = $created
        Path = $exe
        ExitTime = $null
    }
}

function Find-REKenshiChild($Parent) {
    # ParentProcessId reste enregistré sur l'enfant après la sortie du parent.
    # L'heure de création exclut un nouveau lanceur ayant réutilisé le PID du parent.
    if (-not $Parent.StartTime) { return $null }
    $children = @(Get-CimInstance Win32_Process -Filter "Name = 'kenshi_x64.exe' AND ParentProcessId = $($Parent.ProcessId)" -ErrorAction SilentlyContinue)
    foreach ($child in $children) {
        if (-not $child.CreationDate -or $child.CreationDate -lt $Parent.StartTime -or $child.CreationDate -gt $Parent.ExitTime) { continue }
        $candidate = Get-Process -Id $child.ProcessId -ErrorAction SilentlyContinue
        if (-not $candidate) { continue }
        $identity = Get-SessionProcessInfo $candidate $child
        if ($identity.Path -ine $reExe -or -not $identity.StartTime -or
            [math]::Abs(($identity.StartTime - $child.CreationDate).TotalSeconds) -gt 0.01) { continue }
        [pscustomobject]@{ Process = $candidate; Identity = $identity }
        return
    }
    $null
}

# Rattache un événement Windows (plantage 1000 ou gel 1002) aux processus suivis de la session
function Test-SessionEvent($CrashEvent, [object[]]$Processes) {
    if (-not $CrashEvent.ProcessId) {
        # PID illisible dans l'événement : repli sur la fenêtre de la session, du lancement
        # d'un processus suivi à 60 s après sa fermeture, plutôt que d'ignorer le plantage
        foreach ($identity in $Processes) {
            if ($identity.StartTime -and $CrashEvent.Time -lt $identity.StartTime) { continue }
            if ($identity.ExitTime -and $CrashEvent.Time -gt $identity.ExitTime.AddSeconds(60)) { continue }
            return $true
        }
        return $false
    }
    $eventStart = $CrashEvent.ProcessStartTime
    foreach ($identity in $Processes) {
        if ($CrashEvent.ProcessId -ne $identity.ProcessId) { continue }
        if ($CrashEvent.AppPath -and $identity.Path -and $CrashEvent.AppPath -ine $identity.Path) { continue }
        if ($eventStart -and $identity.StartTime -and
            [math]::Abs(($eventStart - $identity.StartTime).TotalSeconds) -gt 0.01) { continue }
        # L'événement peut être écrit après ExitTime. Le PID et, lorsqu'elle existe,
        # la date de création le rattachent au bon processus, même si le PID est réutilisé.
        if ($identity.StartTime -and $CrashEvent.Time -lt $identity.StartTime) { continue }
        if (-not ($eventStart -and $identity.StartTime) -and $CrashEvent.Time -gt $identity.ExitTime.AddSeconds(60)) { continue }
        return $true
    }
    $false
}

try {
    do {
        $p = $null
        $waitStart = Get-Date
        $deadline = $null
        if ($WaitTimeoutSec -gt 0) { $deadline = $waitStart.AddSeconds($WaitTimeoutSec) }
        Set-Phase 'waiting' $deadline
        while (-not $p) {
            Start-Sleep 2
            $p = Get-Process kenshi_x64 -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $p -and $WaitTimeoutSec -gt 0 -and ((Get-Date) - $waitStart).TotalSeconds -ge $WaitTimeoutSec) {
                Write-Host "Kenshi n'a pas démarré dans le délai ($WaitTimeoutSec s) : moniteur arrêté."
                exit 0
            }
        }

        $identity = Get-SessionProcessInfo $p
        $sessionProcesses = New-Object 'System.Collections.Generic.List[object]'
        $sessionProcesses.Add($identity)
        Set-Phase 'session'
        $dir = New-SessionDir $OutDir
        Copy-Item -LiteralPath $paths.ModsCfg -Destination (Join-Path $dir 'mods.cfg.at-launch') -ErrorAction SilentlyContinue
        $csv = Join-Path $dir 'memory.csv'
        [IO.File]::WriteAllText($csv, "time,working_set_mb,private_mb,peak_working_set_mb,handles,threads,free_ram_mb,commit_used_mb,commit_limit_mb`r`n", $utf8NoBom)
        $start = Get-Date
        Write-Host "Session démarrée (PID $($p.Id)) : $dir"

        $relaunches = 0
        while ($true) {
            while (-not $p.HasExited) {
                try {
                    $p.Refresh()
                    $os = Get-CimInstance Win32_OperatingSystem
                    $line = '{0},{1},{2},{3},{4},{5},{6},{7},{8}' -f (Get-Date -Format 'HH:mm:ss'),
                        [math]::Round($p.WorkingSet64 / 1MB), [math]::Round($p.PrivateMemorySize64 / 1MB),
                        [math]::Round($p.PeakWorkingSet64 / 1MB), $p.HandleCount, $p.Threads.Count,
                        [math]::Round($os.FreePhysicalMemory / 1KB),
                        [math]::Round(($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / 1KB),
                        [math]::Round($os.TotalVirtualMemorySize / 1KB)
                    [IO.File]::AppendAllText($csv, $line + "`r`n", $utf8NoBom)
                } catch { Write-Warning "Mesure mémoire impossible : $($_.Exception.Message)" }
                # Même cadence de mesure, mais réveil immédiat à la fermeture : une
                # pause entière laisserait le prochain lancement écraser les journaux.
                try { $null = $p.WaitForExit([int][math]::Min([int]::MaxValue, 1000.0 * $IntervalSec)) }
                catch { if (-not $p.HasExited) { Start-Sleep $IntervalSec } }
            }
            $end = Get-Date
            $identity.ExitTime = $end
            try { if ($p.ExitTime) { $identity.ExitTime = $p.ExitTime } } catch { }
            # Copier avant toute attente : un redémarrage normal peut écraser les
            # journaux immédiatement. Seul un enfant RE_Kenshi vérifié prolonge la session.
            Copy-SessionLogs $dir
            # Avec RE_Kenshi, l'exe lancé par Steam relance RE_Kenshi\kenshi_x64.exe puis se ferme :
            # suivre ce second processus dans la même session au lieu de clore la session.
            $next = $null
            # Sans RE_Kenshi\kenshi_x64.exe, aucun enfant possible : pas d'attente de 20 s.
            if ((-not $identity.Path -or $identity.Path -ieq $rootExe) -and (Test-Path -LiteralPath $reExe -PathType Leaf)) {
                $relaunchDeadline = (Get-Date).AddSeconds(20)
                while (-not $next -and (Get-Date) -lt $relaunchDeadline) {
                    $next = Find-REKenshiChild $identity
                    if (-not $next) { Start-Sleep 1 }
                }
            }
            if (-not $next) { break }
            $relaunches++
            Write-Host "Enfant RE_Kenshi confirmé (PID $($next.Process.Id)) : suivi du nouveau processus."
            $p = $next.Process
            $identity = $next.Identity
            $sessionProcesses.Add($identity)
        }

        Set-Phase 'finishing'
        Write-Host "Kenshi fermé à $($end.ToString('HH:mm:ss')), journaux copiés ; attente des rapports Windows (60 s)..."
        Start-Sleep 60   # laisse le temps à Windows d'écrire l'événement, le dump et le rapport WER

        $crashSince = $start
        if ($sessionProcesses[0].StartTime -and $sessionProcesses[0].StartTime -lt $crashSince) { $crashSince = $sessionProcesses[0].StartTime }
        $trackedProcesses = $sessionProcesses.ToArray()
        $crash = Get-KenshiCrashEvents -Since $crashSince |
            Where-Object { Test-SessionEvent $_ $trackedProcesses } | Select-Object -First 1
        $hang = Get-KenshiHangEvents -Since $crashSince |
            Where-Object { Test-SessionEvent $_ $trackedProcesses } | Select-Object -First 1
        $exitCode = $null
        try { $exitCode = $p.ExitCode } catch { }
        # 0xCFFFFFFF : code que Windows donne à un programme figé qu'il ferme, même sans événement 1002
        $hung = [bool]$hang -or $exitCode -eq -805306369

        # Les valeurs lues par Import-Csv sont des chaînes : les convertir avant Measure-Object
        $mem = @(Import-Csv -LiteralPath $csv)
        $peakPrivate = $null; $minFree = $null
        if ($mem.Count -gt 0) {
            $peakPrivate = ($mem | ForEach-Object { [double]$_.private_mb } | Measure-Object -Maximum).Maximum
            $minFree = ($mem | ForEach-Object { [double]$_.free_ram_mb } | Measure-Object -Minimum).Minimum
        }

        $dumps = @()
        if (Test-Path -LiteralPath $paths.CrashDumps) {
            $dumps = @(Get-ChildItem -LiteralPath $paths.CrashDumps -File -Filter 'kenshi_x64*.dmp' -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -gt $start })
        }
        foreach ($d in $dumps) { Copy-Item -LiteralPath $d.FullName -Destination $dir -ErrorAction SilentlyContinue }
        $zips = @(Get-ChildItem -LiteralPath $gameDir -File -Filter 'crashDump*.zip' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt $start })
        foreach ($z in $zips) { Copy-Item -LiteralPath $z.FullName -Destination $dir -ErrorAction SilentlyContinue }
        $wer = @()
        foreach ($werDir in $paths.WerReportDirs) {
            if (-not (Test-Path -LiteralPath $werDir)) { continue }
            $wer += @(Get-ChildItem -LiteralPath $werDir -Directory -ErrorAction SilentlyContinue |
                Where-Object { ($_.Name -like 'AppCrash_kenshi_x64*' -or $_.Name -like 'AppHang_kenshi_x64*') -and $_.LastWriteTime -gt $start })
        }
        foreach ($w in $wer) { Copy-Item -LiteralPath $w.FullName -Destination (Join-Path $dir $w.Name) -Recurse -ErrorAction SilentlyContinue }

        $lastExit = $null
        try {
            $sessions = @(Get-KenshiSessions -SaveLog (Join-Path $dir 'save.log'))
            if ($sessions.Count -gt 0) { $lastExit = $sessions[-1].ExitTime }
        } catch { }

        $logSummary = Write-SessionLogSummary $dir
        # Affectation directe (pas $(...), qui ramènerait une liste vide à $null)
        $listAtLaunch = $null; $listAtExit = $null
        try { $listAtLaunch = @(Get-ActiveModList -Path (Join-Path $dir 'mods.cfg.at-launch')) } catch { }
        try { $listAtExit = @(Get-ActiveModList -Path (Join-Path $dir 'mods.cfg.at-exit')) } catch { }
        $modsAtLaunch = $null; $modsAtExit = $null
        if ($null -ne $listAtLaunch) { $modsAtLaunch = $listAtLaunch.Count }
        if ($null -ne $listAtExit) { $modsAtExit = $listAtExit.Count }
        $modsLoaded = $null; $modsOutsidePack = $null
        if ($logSummary) {
            $modsLoaded = $logSummary.LoadedCount
            if ($null -ne $logSummary.PackCount) { $modsOutsidePack = $logSummary.ExtraMods.Count }
        }
        # Comparaison entrée par entrée, dans l'ordre : un simple comptage manquerait un réordonnancement
        $listChanged = ($null -ne $listAtLaunch -and $null -ne $listAtExit -and (($listAtLaunch -join "`n") -ne ($listAtExit -join "`n")))

        $summary = [ordered]@{
            start                 = $start.ToString('s')
            end                   = $end.ToString('s')
            minutes               = [math]::Round(($end - $start).TotalMinutes, 1)
            exit_code             = $exitCode
            relaunches            = $relaunches
            mods_at_launch        = $modsAtLaunch
            mods_at_exit          = $modsAtExit
            mods_loaded           = $modsLoaded
            mods_outside_pack     = $modsOutsidePack
            mods_list_rewritten   = $listChanged
            samples               = $mem.Count
            peak_private_mb       = $peakPrivate
            min_free_ram_mb       = $minFree
            crashed               = [bool]$crash
            # « else { $null } » obligatoire : sans lui, PowerShell 5.1 sérialise la valeur vide en {} au lieu de null
            crash_time            = $(if ($crash) { $crash.Time.ToString('s') } else { $null })
            crash_module          = $(if ($crash) { $crash.Module } else { $null })
            crash_exception_code  = $(if ($crash) { $crash.ExceptionCode } else { $null })
            crash_fault_offset    = $(if ($crash) { $crash.FaultOffset } else { $null })
            crash_info            = $(if ($crash) { "$($crash.Module) $($crash.ModuleVersion) | $($crash.ExceptionCode) | $($crash.FaultOffset)" } else { $null })
            hung                  = $hung
            hang_time             = $(if ($hang) { $hang.Time.ToString('s') } else { $null })
            wer_dumps             = @($dumps | ForEach-Object { $_.Name })
            kenshi_crash_zips     = @($zips | ForEach-Object { $_.Name })
            wer_reports           = @($wer | ForEach-Object { $_.Name })
            last_exit_in_save_log = $lastExit
        }
        [IO.File]::WriteAllText((Join-Path $dir 'summary.json'), (($summary | ConvertTo-Json -Depth 3) + "`r`n"), $utf8NoBom)
        if ($listChanged) {
            $how = 'contenu ou ordre modifié'
            if ($modsAtLaunch -ne $modsAtExit) { $how = "$modsAtLaunch mods au lancement, $modsAtExit à la sortie" }
            Write-Warning "mods.cfg a changé pendant la session : $how (le lanceur a réécrit la liste)."
        }
        if ($null -ne $modsLoaded) {
            $loadedText = "Mods chargés d'après kenshi_info.log : $modsLoaded"
            if ($null -ne $modsOutsidePack) { $loadedText += " (dont $modsOutsidePack hors pack)" }
            Write-Host $loadedText
        }
        if ($crash) { Write-Host "Plantage : $($summary.crash_info)" } else { Write-Host 'Aucun événement de plantage trouvé.' }
        if ($hung) { Write-Host 'Gel : le jeu ne répondait plus et Windows l''a fermé.' }
        Write-Host "Session enregistrée : $dir"
    } while (-not $Once)
}
finally {
    try {
        $mine = Read-KenshiMonitorLock -Path $lock
        if ($mine -and $mine.ProcessId -eq $PID) { Remove-Item -LiteralPath $lock -Force }
    } catch { }
}
