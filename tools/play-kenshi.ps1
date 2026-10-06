<#
.SYNOPSIS
    Lance Kenshi proprement : liste du pack remise en place, vérifiée, moniteur armé.

.DESCRIPTION
    Enchaîne, dans l'ordre :
      1. refuse si kenshi_x64.exe tourne déjà, ou si -Game ou -Workshop désigne un
         autre dossier que ceux de l'installation Steam détectée (sauf -DryRun) :
         Steam lancerait le vrai jeu avec une liste jamais restaurée, ou vérifiée
         contre un autre Workshop que celui qu'il lit ;
      2. vérifie la liste du pack (modlist\mods.cfg) avec Test-KenshiModList et
         s'arrête (code 2) sur fichiers .mod introuvables ou dépendances absentes /
         non activées / chargées trop tard, sauf -Force : rien n'est écrit avant ;
      3. compare data\mods.cfg du jeu avec la liste du pack et, si elle diffère, la
         restaure avec restore-modlist.ps1 en montrant ce qui change (sauf -NoRestore),
         puis relit data\mods.cfg pour vérifier qu'il est bien devenu la liste du pack ;
         le Workshop n'est parcouru qu'une fois : l'index des fichiers .mod de l'étape 2
         est passé à restore-modlist.ps1 ;
      4. démarre kenshi-monitor.ps1 -Once -WaitTimeoutSec 600 dans un PowerShell
         caché, qui se termine de lui-même à la fin de la session ou si le jeu
         n'apparaît pas en 10 min (sauf -NoMonitor). Si logs\sessions\monitor.lock
         désigne un moniteur qui tourne vraiment (PID, date de création du processus
         et phase vérifiés) et attend encore le jeu avec au moins 2 min devant lui,
         il est conservé ; s'il termine la session précédente (phase finishing : 60 s
         d'attente des rapports Windows) ou arrive au bout de son délai, le script
         attend qu'il se retire (au plus 150 s) puis en démarre un nouveau ; un
         verrou périmé est ignoré ;
      5. affiche la RAM libre, la marge d'allocation de mémoire et les applications
         gourmandes ouvertes (navigateurs, VS Code, Discord...), avec un avertissement
         si la marge est faible ; ne bloque jamais ;
      6. lance le jeu via Steam (steam://rungameid/233860).
    Le lanceur de Kenshi peut réécrire data\mods.cfg au clic sur Play : après la
    session, summary.json (mods_loaded, mods_at_exit) ou summarize-logs.ps1
    (« Mods chargés ») disent quelle liste le jeu a réellement chargée.
    Avec -DryRun, toutes les vérifications sont faites et chaque action est
    affichée, mais rien n'est écrit, aucun moniteur n'est démarré et le jeu n'est
    pas lancé. Code de sortie : 0 si tout s'est déroulé (ou simulation sans
    blocage), 1 si refusé ou entrée invalide (jeu ouvert, -Game ou -Workshop hors
    Steam sans -DryRun, restauration refusée ou échouée), 2 si bloqué par la
    vérification.

.PARAMETER Game
    Dossier du jeu (détection automatique via Steam sinon). Un dossier différent de
    l'installation Steam n'est accepté qu'avec -DryRun.
.PARAMETER Workshop
    Dossier Workshop (détection automatique sinon). Un dossier différent du Workshop
    Steam n'est accepté qu'avec -DryRun : le jeu lancé par Steam lit le sien.
.PARAMETER DryRun
    Simulation : vérifie et affiche tout, ne restaure rien, ne lance rien.
.PARAMETER NoRestore
    Ne remet pas la liste du pack même si la liste active en diffère.
.PARAMETER NoMonitor
    Ne démarre pas le moniteur de session.
.PARAMETER Force
    Continue (et lance le jeu) malgré les fichiers ou dépendances manquants.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\play-kenshi.ps1
.EXAMPLE
    .\tools\play-kenshi.ps1 -DryRun
.EXAMPLE
    .\tools\play-kenshi.ps1 -NoRestore -NoMonitor
#>
[CmdletBinding()]
param(
    [string]$Game,
    [string]$Workshop,
    [switch]$DryRun,
    [switch]$NoRestore,
    [switch]$NoMonitor,
    [switch]$Force
)
Import-Module (Join-Path $PSScriptRoot 'KenshiTools.psm1') -Force
$packCfg = Join-Path $PSScriptRoot '..\modlist\mods.cfg'
$restoreScript = Join-Path $PSScriptRoot 'restore-modlist.ps1'
$monitorScript = Join-Path $PSScriptRoot 'kenshi-monitor.ps1'
$sessionsDir = Join-Path $PSScriptRoot '..\logs\sessions'
$steamUrl = 'steam://rungameid/233860'
$maxListed = 15
$monitorWaitSec = 600
$monitorMinLeftSec = 120   # marge minimale avant la fin d'attente d'un moniteur pour le réutiliser
$lockWaitSec = 150         # attente maximale d'un moniteur qui termine la session précédente (60 s + rapports)
$minFreeRamGb = 6          # en dessous, Kenshi (environ 8,5 Go avec le pack et RE_Kenshi) utilisera beaucoup le fichier d'échange
$minCommitFreeGb = 12      # marge d'allocation conseillée (mémoire privée du jeu + croissance en cours de partie)
$heavyApps = @{
    'Code' = 'VS Code'; 'msedge' = 'Edge'; 'chrome' = 'Chrome'; 'firefox' = 'Firefox'; 'opera' = 'Opera'
    'steamwebhelper' = 'Steam (pages web)'; 'Discord' = 'Discord'; 'claude' = 'Claude'
    'ms-teams' = 'Teams'; 'Teams' = 'Teams'; 'Spotify' = 'Spotify'; 'EpicGamesLauncher' = 'Epic Games'
}

$tag = ''
if ($DryRun) { $tag = '[simulation] ' }
function Step([string]$Text) { Write-Host ("{0}{1}" -f $tag, $Text) }
function ShowSome([string]$Label, [string[]]$Items) {
    Write-Host ("  {0} : {1}" -f $Label, $Items.Count)
    foreach ($i in @($Items | Select-Object -First $maxListed)) { Write-Host "    $i" }
    if ($Items.Count -gt $maxListed) { Write-Host "    ... et $($Items.Count - $maxListed) autres" }
}
function Format-When($Time) { if ($null -eq $Time) { return '?' }; ([datetime]$Time).ToString('HH:mm:ss') }
# Moniteur vivant qui attend encore le jeu avec assez de marge avant la fin de son délai
function Test-ReusableMonitor($Lock) {
    $Lock.IsLive -and $Lock.Phase -eq 'waiting' -and ($null -eq $Lock.Deadline -or ($Lock.Deadline - (Get-Date)).TotalSeconds -ge $monitorMinLeftSec)
}
function Test-SameList([string[]]$A, [string[]]$B) {
    if ($A.Count -ne $B.Count) { return $false }
    for ($i = 0; $i -lt $A.Count; $i++) { if ($A[$i] -ne $B[$i]) { return $false } }
    $true
}
# Paramètres -Game/-Workshop à transmettre tels quels aux autres scripts
$passThru = @{}
if ($Game) { $passThru.Game = $Game }
if ($Workshop) { $passThru.Workshop = $Workshop }

$done = New-Object 'System.Collections.Generic.List[string]'
if ($DryRun) { Write-Host 'Mode simulation : rien ne sera écrit ni lancé.' }

# --- 1. jeu déjà ouvert, dossier du jeu --------------------------------------
if (Get-Process kenshi_x64 -ErrorAction SilentlyContinue) {
    Write-Error 'Kenshi (ou son lanceur) tourne déjà : ferme-le avant de relancer.'
    exit 1
}
foreach ($f in $packCfg, $restoreScript, $monitorScript) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Error "Introuvable : $f"; exit 1 }
}
$packCfg = (Resolve-Path -LiteralPath $packCfg).ProviderPath
$paths = Get-KenshiPaths -Game $Game -Workshop $Workshop
$liveCfg = $paths.ModsCfg
if (($Game -or $Workshop) -and -not $DryRun) {
    # Steam lance toujours son installation, qui lit son propre Workshop : un autre -Game ne
    # serait ni restauré ni vérifié, un autre -Workshop ferait vérifier une liste que le jeu ne lit pas
    $steam = Get-KenshiPaths
    $mismatch = @()
    if ($Game -and $paths.Game -ine $steam.Game) { $mismatch += "-Game ($($paths.Game)) ne correspond pas à l'installation Steam ($($steam.Game)) : le jeu lancé par Steam ne lirait pas cette liste." }
    if ($Workshop -and $paths.Workshop -ine $steam.Workshop) { $mismatch += "-Workshop ($($paths.Workshop)) ne correspond pas au Workshop Steam ($($steam.Workshop)) : la liste serait vérifiée contre des fichiers que le jeu ne charge pas." }
    if ($mismatch.Count -gt 0) {
        Write-Error (($mismatch + 'Utiliser -DryRun pour tester.') -join ' ')
        exit 1
    }
}
if (-not $DryRun -and -not (Test-Path -LiteralPath (Join-Path $paths.Game 'kenshi_x64.exe'))) {
    Write-Error "kenshi_x64.exe introuvable dans $($paths.Game) : installation Steam de Kenshi non trouvée."
    exit 1
}
Write-Host "Jeu : $($paths.Game)"
Write-Host "Workshop : $($paths.Workshop)"
Write-Host "Liste active : $liveCfg"
Write-Host "Liste du pack : $packCfg"

# --- 2. vérification de la liste du pack, avant toute écriture ---------------
$pack = @(Get-ActiveModList -Path $packCfg)
$live = @()
$liveExists = Test-Path -LiteralPath $liveCfg
if ($liveExists) { $live = @(Get-ActiveModList -Path $liveCfg) }
$same = $liveExists -and (Test-SameList $live $pack)
$willRestore = (-not $same) -and (-not $NoRestore)

$listToCheck = $liveCfg
if ($willRestore -or -not $liveExists) { $listToCheck = $packCfg }
Step "Vérification de la liste qui sera chargée : $listToCheck"
# Un seul parcours du Workshop, partagé par la vérification et restore-modlist.ps1
$modIndex = Get-ModFileIndex -Folders @((Join-Path $paths.Game 'mods'), $paths.Workshop)
$r = Test-KenshiModList -ModsCfg $listToCheck -PackCfg $packCfg -Game $Game -Workshop $Workshop -ModIndex $modIndex
$c = $r.Counts
Write-Host "  $($c.Active) mods actifs, $($c.FilesOnDisk) fichiers .mod sur le disque."
ShowSome 'Fichiers .mod introuvables' $r.MissingFiles
ShowSome 'Dépendances introuvables' @($r.AbsentDependencies | ForEach-Object { "$($_.Mod) -> $($_.Dependency)" })
ShowSome 'Dépendances non activées' @($r.InactiveDependencies | ForEach-Object { "$($_.Mod) -> $($_.Dependency)" })
ShowSome 'Dépendances chargées trop tard' @($r.LateDependencies | ForEach-Object { "$($_.Mod) (#$($_.Position)) avant $($_.Dependency) (#$($_.DependencyPosition))" })
if ($c.Unreadable -gt 0) { ShowSome 'En-têtes illisibles (dépendances non vérifiées)' @($r.Unreadable | ForEach-Object { "$($_.Mod) : $($_.Error)" }) }
if ($c.DuplicateFiles -gt 0) { ShowSome 'Fichiers en double sur le disque' @($r.DuplicateFiles | ForEach-Object { "$($_.Mod) : " + ($_.Paths -join ' | ') }) }
if ($listToCheck -ne $packCfg -and ($c.NotInPack -gt 0 -or $c.PackModsNotActive -gt 0)) {
    Write-Host "  Écart avec le pack conservé (-NoRestore) : $($c.NotInPack) hors pack, $($c.PackModsNotActive) du pack non actifs."
}

$blocking = $c.MissingFiles + $c.AbsentDependencies + $c.InactiveDependencies + $c.LateDependencies
if ($blocking -gt 0) {
    if (-not $Force) {
        Write-Error "Lancement annulé : $blocking problème(s) de fichiers ou de dépendances (détail ci-dessus ; -Force pour passer outre). Rien n'a été écrit."
        exit 2
    }
    Write-Warning "-Force : lancement malgré $blocking problème(s) de fichiers ou de dépendances."
}
else {
    Write-Host '  OK : fichiers et dépendances en ordre.'
}

# --- 3. liste active contre liste du pack -----------------------------------
if ($same) {
    Write-Host "Liste active identique au pack ($($pack.Count) mods) : rien à restaurer."
}
else {
    if (-not $liveExists) {
        Write-Host 'Liste active absente : le jeu n''a pas encore de data\mods.cfg.'
    }
    else {
        Write-Host "Liste active différente du pack : $($live.Count) mods actifs, $($pack.Count) dans le pack."
        $packSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($p in $pack) { [void]$packSet.Add($p) }
        $liveSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($l in $live) { [void]$liveSet.Add($l) }
        $extra = @($live | Where-Object { -not $packSet.Contains($_) })
        $absent = @($pack | Where-Object { -not $liveSet.Contains($_) })
        ShowSome 'Mods actifs hors pack (seraient désactivés)' $extra
        ShowSome 'Mods du pack non actifs (seraient réactivés)' $absent
        if ($extra.Count -eq 0 -and $absent.Count -eq 0) { Write-Host '  Mêmes mods, mais ordre de chargement différent.' }
    }

    if ($NoRestore) {
        Write-Warning '-NoRestore : la liste active est conservée telle quelle.'
        if (-not $liveExists) { Write-Error "Impossible de continuer sans liste active : $liveCfg"; exit 1 }
    }
    else {
        # En simulation, restore-modlist.ps1 tourne avec -WhatIf : il vérifie tout sans rien écrire
        Step "Restauration de la liste du pack avec restore-modlist.ps1 (sauvegarde de l'ancienne liste en .bak)."
        $restoreArgs = @{ Source = $packCfg; Force = $Force; WhatIf = $DryRun; ModIndex = $modIndex } + $passThru
        $global:LASTEXITCODE = 0
        & $restoreScript @restoreArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Error "restore-modlist.ps1 a échoué (code $LASTEXITCODE) : liste non restaurée, jeu non lancé."
            exit 1
        }
        if ($DryRun) {
            $done.Add("Restauration simulée : $liveCfg serait remplacé par les $($pack.Count) mods du pack.")
        }
        else {
            # Relecture du fichier réellement écrit, pas de la copie du dépôt
            $after = @()
            if (Test-Path -LiteralPath $liveCfg) { $after = @(Get-ActiveModList -Path $liveCfg) }
            if (-not (Test-SameList $after $pack)) {
                Write-Error "Après restauration, $liveCfg ($($after.Count) mods) diffère toujours du pack ($($pack.Count)) : jeu non lancé."
                exit 1
            }
            $done.Add("Liste du pack restaurée dans $liveCfg ($($pack.Count) mods, relue et conforme).")
        }
    }
}

# --- 4. moniteur de session -------------------------------------------------
if ($NoMonitor) {
    Write-Host 'Moniteur non démarré (-NoMonitor).'
}
else {
    $sessionsDir = [IO.Path]::GetFullPath($sessionsDir)
    $lock = Join-Path $sessionsDir 'monitor.lock'
    # Un moniteur n'est réutilisé que s'il attend encore le jeu avec assez de marge : en phase
    # finishing (ou session, jeu fermé) il va s'arrêter sans voir la nouvelle session (-Once)
    $existing = Read-KenshiMonitorLock -Path $lock
    $action = 'start'   # start | reuse | wait
    $busy = ''
    if ($existing) {
        if (-not $existing.IsLive) { Write-Warning "Verrou de moniteur périmé ignoré : $lock ($($existing.Reason))." }
        elseif (Test-ReusableMonitor $existing) { $action = 'reuse' }
        elseif ($existing.Phase -eq 'waiting') { $action = 'wait'; $busy = "arrive au bout de son délai d'attente ($(Format-When $existing.Deadline))" }
        else { $action = 'wait'; $busy = "termine la session précédente (phase « $($existing.Phase) »)" }
    }
    if ($action -eq 'wait') {
        Step "Le moniteur PID $($existing.ProcessId) $busy : attente de sa fin (au plus $lockWaitSec s) avant d'en démarrer un nouveau."
        $action = 'start'
        if (-not $DryRun) {
            $waitUntil = (Get-Date).AddSeconds($lockWaitSec)
            while ((Get-Date) -lt $waitUntil) {
                Start-Sleep 2
                $existing = Read-KenshiMonitorLock -Path $lock
                if (-not $existing -or -not $existing.IsLive) { break }
                # Moniteur sans -Once : revenu en attente du jeu avec un nouveau délai, il enregistrera cette session
                if (Test-ReusableMonitor $existing) { $action = 'reuse'; break }
            }
            if ($action -ne 'reuse' -and $existing -and $existing.IsLive) {
                Write-Warning "Le moniteur PID $($existing.ProcessId) tient toujours le verrou après $lockWaitSec s : pas de second moniteur, cette session ne sera pas enregistrée. Pour l'arrêter : kenshi-monitor.ps1 -Stop."
                $done.Add("Moniteur non démarré : l'ancien (PID $($existing.ProcessId)) occupe encore le verrou ; session non enregistrée.")
                $action = 'none'
            }
            elseif ($action -ne 'reuse') { Write-Host 'Ancien moniteur terminé, verrou libre.' }
        }
    }
    if ($action -eq 'reuse') {
        Write-Host "Un moniteur attend déjà le jeu (PID $($existing.ProcessId), $lock) : il enregistrera cette session, pas de second moniteur. Pour l'arrêter : kenshi-monitor.ps1 -Stop."
        $done.Add("Moniteur existant conservé (PID $($existing.ProcessId), en attente du jeu).")
    }
    elseif ($action -eq 'start') {
        if (-not $DryRun) { New-Item -ItemType Directory -Force $sessionsDir | Out-Null }
        $monitorLog = Join-Path $sessionsDir ('monitor-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
        # Hôte console de la même édition (jamais powershell_ise.exe, qui n'accepte pas ces options), caché, une seule session puis fin
        $hostExe = Join-Path $PSHOME 'powershell.exe'
        if ($PSVersionTable.PSEdition -eq 'Core') { $hostExe = Join-Path $PSHOME 'pwsh.exe' }
        $inner = "Start-Transcript -LiteralPath '{0}' | Out-Null; & '{1}' -Once -WaitTimeoutSec {2}" -f ($monitorLog -replace "'", "''"), ($monitorScript -replace "'", "''"), $monitorWaitSec
        if ($Game) { $inner += " -Game '{0}'" -f ($Game -replace "'", "''") }
        $inner += '; Stop-Transcript | Out-Null'
        $monitorArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -Command "{0}"' -f $inner
        Step "Démarrage du moniteur (caché) : $hostExe $monitorArgs"
        if (-not $DryRun) {
            $mp = Start-Process -FilePath $hostExe -ArgumentList $monitorArgs -WindowStyle Hidden -PassThru
            $done.Add("Moniteur démarré (PID $($mp.Id)), journal : $monitorLog ; session dans $sessionsDir ; s'arrête seul après la session ou après $monitorWaitSec s sans jeu.")
        }
        else {
            $done.Add("Moniteur simulé : serait démarré caché, journal $monitorLog.")
        }
    }
}

# --- 5. mémoire disponible (information seulement, ne bloque jamais) --------
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $freeGb = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    $commitFreeGb = [math]::Round($os.FreeVirtualMemory / 1MB, 1)
    $commitLimitGb = [math]::Round($os.TotalVirtualMemorySize / 1MB, 1)
    Step ("Mémoire : {0} Go de RAM libre ; marge d'allocation {1} Go (limite {2} Go)." -f $freeGb, $commitFreeGb, $commitLimitGb)
    $heavy = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $heavyApps.ContainsKey($_.ProcessName) } |
        Group-Object ProcessName | ForEach-Object {
            [pscustomobject]@{ Name = $heavyApps[$_.Name]; Gb = [math]::Round((($_.Group | Measure-Object PrivateMemorySize64 -Sum).Sum) / 1GB, 1) }
        } | Where-Object { $_.Gb -ge 0.3 } | Sort-Object Gb -Descending)
    if ($heavy.Count -gt 0) {
        Step ('  Applications gourmandes ouvertes : ' + (($heavy | ForEach-Object { "$($_.Name) ($($_.Gb) Go)" }) -join ', ') + '. Les fermer libère de la RAM pour Kenshi.')
    }
    if ($freeGb -lt $minFreeRamGb) { Write-Warning ("Moins de {0} Go de RAM libre : Kenshi utilisera beaucoup le fichier d'échange (saccades possibles)." -f $minFreeRamGb) }
    if ($commitFreeGb -lt $minCommitFreeGb) { Write-Warning ("Marge d'allocation inférieure à {0} Go : risque de manque de mémoire pendant la partie ; fermer des applications." -f $minCommitFreeGb) }
}
catch { Write-Warning "Mémoire disponible illisible : $($_.Exception.Message)" }

# --- 6. lancement -----------------------------------------------------------
Step "Lancement du jeu : $steamUrl"
if (-not $DryRun) {
    Start-Process $steamUrl
    $done.Add("Kenshi lancé via Steam ($steamUrl).")
}
else {
    $done.Add("Lancement simulé : Start-Process $steamUrl.")
}

Write-Host ''
Write-Host 'Résumé :'
foreach ($d in $done) { Write-Host "  - $d" }
Write-Host '  Le lanceur de Kenshi peut encore réécrire data\mods.cfg au clic sur Play : après la session, vérifier « Mods chargés » (summarize-logs.ps1) ou mods_loaded / mods_at_exit dans summary.json.'
if ($DryRun) { Write-Host 'Simulation terminée : rien n''a été écrit ni lancé.' }
else { Write-Host 'Bon jeu.' }
exit 0
