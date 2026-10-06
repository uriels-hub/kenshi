<#
.SYNOPSIS
    Bilan de santé (lecture seule) de l'installation moddée de Kenshi.

.DESCRIPTION
    Imprime un tableau de contrôles OK / ATTENTION / ECHEC / MANUEL, avec un conseil
    pour chaque point à corriger :
      - Kenshi en cours d'exécution ou fermé ;
      - version du jeu (currentVersion.txt) ;
      - écart entre data\mods.cfg et la liste du pack, et problèmes de dépendances
        (Test-KenshiModList du module KenshiTools) ;
      - abonnements Workshop (appworkshop_233860.acf) : total et nombre hors pack.
        L'identifiant de compte Steam présent dans ce fichier n'est ni affiché ni conservé ;
      - préférence GPU Windows de l'exécutable Kenshi actif ou attendu
        (racine ou RE_Kenshi\kenshi_x64.exe, GpuPreference=2 attendu) ;
      - présence de RE_Kenshi (RE_Kenshi.dll et entrée Plugin=RE_Kenshi) ;
      - état de Smart App Control ;
      - RAM, fichier d'échange, espace libre du lecteur du jeu ;
      - plantages des 24 dernières heures (événements Windows 1000, crashDump*.zip, dumps WER).
    Les réglages impossibles à lire de façon fiable (processeur PhysX NVIDIA) sont
    signalés MANUEL avec la marche à suivre.
    Ne modifie rien : ni le jeu, ni le Workshop, ni le registre.
    Code de sortie : 0 s'il n'y a aucun ECHEC, 1 sinon.

.PARAMETER Game
    Dossier du jeu (détection automatique via Steam sinon).
.PARAMETER Workshop
    Dossier Workshop (détection automatique sinon), utilisé pour la vérification des
    dépendances.
.PARAMETER PackCfg
    Liste de référence du pack (par défaut : modlist\mods.cfg du dépôt ; chaîne vide
    pour ne pas comparer, comme dans scan-mods.ps1). Le fichier pack-modlist.csv du
    même dossier sert aux identifiants Workshop.
.PARAMETER Json
    Sort le bilan en JSON (contrôles, résumé, code de sortie) au lieu du tableau texte.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\health-check.ps1
.EXAMPLE
    .\tools\health-check.ps1 -Json | ConvertFrom-Json | Select-Object -ExpandProperty Checks
#>
[CmdletBinding()]
param(
    [string]$Game,
    [string]$Workshop,
    [string]$PackCfg,
    [switch]$Json
)
Import-Module (Join-Path $PSScriptRoot 'KenshiTools.psm1') -Force
if (-not $PSBoundParameters.ContainsKey('PackCfg')) { $PackCfg = Join-Path $PSScriptRoot '..\modlist\mods.cfg' }
if ($PackCfg -and (Test-Path -LiteralPath $PackCfg)) { $PackCfg = (Resolve-Path -LiteralPath $PackCfg).ProviderPath }

$checks = New-Object 'System.Collections.Generic.List[object]'
$since = (Get-Date).AddHours(-24)

function Add-Check([string]$Name, [string]$Status, [string]$Detail, [string]$Advice = '') {
    $checks.Add([pscustomobject]@{ Check = $Name; Status = $Status; Detail = $Detail; Advice = $Advice })
}

# Exécute un contrôle ; une exception devient une ligne ATTENTION au lieu d'arrêter le bilan.
function Invoke-Check([string]$Name, [scriptblock]$Body) {
    try { & $Body }
    catch { Add-Check $Name 'ATTENTION' "contrôle impossible : $($_.Exception.Message)" 'Relancer le script ; si l''erreur persiste, vérifier ce point à la main.' }
}

function Format-Gb([double]$Bytes) { '{0:N1} Go' -f ($Bytes / 1GB) }

$paths = Get-KenshiPaths -Game $Game -Workshop $Workshop
$gameDir = $paths.Game
$gameExists = Test-Path -LiteralPath $gameDir

# --- Kenshi en cours d'exécution ------------------------------------------
Invoke-Check 'Kenshi' {
    $procs = @(Get-Process kenshi_x64 -ErrorAction SilentlyContinue)
    if ($procs.Count -gt 0) {
        Add-Check 'Kenshi' 'ATTENTION' "en cours d'exécution (PID $($procs[0].Id))" 'Fermer le jeu avant de restaurer mods.cfg ; les journaux et data\mods.cfg peuvent changer pendant le bilan.'
    }
    else { Add-Check 'Kenshi' 'OK' 'fermé' }
}

# --- Dossier et version du jeu --------------------------------------------
$versionText = ''
if (-not $gameExists) {
    Add-Check 'Dossier du jeu' 'ECHEC' "introuvable : $gameDir" 'Vérifier l''installation Steam de Kenshi, ou passer -Game <dossier>.'
}
else {
    Add-Check 'Dossier du jeu' 'OK' $gameDir
    Invoke-Check 'Version' {
        $verFile = Join-Path $gameDir 'currentVersion.txt'
        if (-not (Test-Path -LiteralPath $verFile)) {
            Add-Check 'Version' 'ATTENTION' 'currentVersion.txt introuvable' 'Vérifier l''intégrité des fichiers du jeu dans Steam (jeu fermé).'
            return
        }
        $script:versionText = (Get-Content -LiteralPath $verFile -Raw -Encoding UTF8).Trim()
        if ($versionText -match '1\.0\.68') { Add-Check 'Version' 'OK' $versionText }
        elseif ($versionText -match '1\.0\.65') { Add-Check 'Version' 'OK' "$versionText (version rétrogradée, typique de RE_Kenshi)" 'Les adresses de plantage ne sont plus comparables avec celles relevées en 1.0.68.' }
        else { Add-Check 'Version' 'ATTENTION' "version inattendue : $versionText" 'Le pack a été vérifié avec Kenshi 1.0.68 ; une autre version peut changer le comportement des mods.' }
    }
}

# --- Liste de mods active et dépendances ----------------------------------
$packExists = [bool]$PackCfg -and (Test-Path -LiteralPath $PackCfg)
if (-not $PackCfg) {
    Add-Check 'Liste du pack' 'ATTENTION' 'comparaison désactivée (-PackCfg '''')' 'Sans liste de référence, l''écart au pack et les abonnements hors pack ne sont pas calculés.'
}
elseif (-not $packExists) {
    Add-Check 'Liste du pack' 'ATTENTION' "introuvable : $PackCfg" 'Passer -PackCfg <fichier> ; sans liste de référence, l''écart au pack n''est pas calculé.'
}
if ($gameExists) {
    Invoke-Check 'Liste de mods' {
        $modsCfg = $paths.ModsCfg
        if (-not (Test-Path -LiteralPath $modsCfg)) {
            Add-Check 'Liste de mods' 'ECHEC' "data\mods.cfg introuvable ($modsCfg)" 'Jeu fermé, lancer tools\restore-modlist.ps1 pour écrire la liste du pack.'
            return
        }
        $refCfg = ''
        if ($packExists) { $refCfg = $PackCfg }
        $r = Test-KenshiModList -ModsCfg $modsCfg -PackCfg $refCfg -Game $Game -Workshop $Workshop
        $c = $r.Counts
        if ($packExists) {
            if ($c.NotInPack -eq 0 -and $c.PackModsNotActive -eq 0) {
                $active = @(Get-ActiveModList -Path $modsCfg)
                $pack = @(Get-ActiveModList -Path $PackCfg)
                $sameOrder = ($active.Count -eq $pack.Count)
                if ($sameOrder) {
                    for ($i = 0; $i -lt $active.Count; $i++) { if ($active[$i] -ne $pack[$i]) { $sameOrder = $false; break } }
                }
                if ($sameOrder) { Add-Check 'Liste de mods' 'OK' "$($c.Active) mods actifs, identique à la liste du pack" }
                else { Add-Check 'Liste de mods' 'ATTENTION' "$($c.Active) mods actifs : mêmes mods que le pack, mais ordre ou doublons différents" 'Jeu fermé, lancer tools\restore-modlist.ps1 pour remettre l''ordre du pack.' }
            }
            else {
                Add-Check 'Liste de mods' 'ECHEC' "$($c.Active) mods actifs : $($c.NotInPack) hors pack, $($c.PackModsNotActive) du pack non activés (pack : $($c.Pack))" 'Jeu fermé, lancer tools\restore-modlist.ps1. Le lanceur Kenshi réactive les abonnements hors pack à chaque passage : se désabonner dans Steam règle le problème pour de bon.'
            }
        }
        else {
            Add-Check 'Liste de mods' 'ATTENTION' "$($c.Active) mods actifs (pas de liste de référence)"
        }

        $depProblems = $c.MissingFiles + $c.Unreadable + $c.AbsentDependencies + $c.InactiveDependencies + $c.LateDependencies
        if ($depProblems -eq 0 -and $c.DuplicateFiles -eq 0) {
            Add-Check 'Dépendances' 'OK' 'fichiers présents, en-têtes lisibles, dépendances activées et dans le bon ordre'
        }
        elseif ($depProblems -eq 0) {
            Add-Check 'Dépendances' 'ATTENTION' "$($c.DuplicateFiles) mod(s) actif(s) dont le fichier existe à plusieurs endroits" 'tools\scan-mods.ps1 liste les doublons ; se désabonner de la copie hors pack.'
        }
        else {
            $detail = 'fichiers introuvables : {0}, en-têtes illisibles : {1}, dépendances introuvables : {2}, non activées : {3}, chargées trop tard : {4}, doublons : {5}' -f `
                $c.MissingFiles, $c.Unreadable, $c.AbsentDependencies, $c.InactiveDependencies, $c.LateDependencies, $c.DuplicateFiles
            Add-Check 'Dépendances' 'ECHEC' $detail 'tools\scan-mods.ps1 donne le détail par mod. Avec la liste du pack seule, il n''y a aucun problème attendu.'
        }
    }
}

# --- Abonnements Workshop ---------------------------------------------------
Invoke-Check 'Workshop' {
    $acf = $paths.AppWorkshopAcf
    if (-not (Test-Path -LiteralPath $acf)) {
        Add-Check 'Workshop' 'ATTENTION' "appworkshop_233860.acf introuvable ($acf)" 'Steam n''a encore rien téléchargé pour Kenshi, ou la bibliothèque n''est pas celle détectée.'
        return
    }
    # Seuls les identifiants numériques au niveau 2 de WorkshopItemsInstalled sont extraits.
    # Les champs de niveau 3 (dont « subscribedby », l'identifiant de compte) ne sont jamais lus.
    $raw = Get-Content -LiteralPath $acf -Raw -Encoding UTF8
    $installed = New-Object 'System.Collections.Generic.HashSet[string]'
    if ($raw -match '(?s)"WorkshopItemsInstalled"\s*\{(.*?)\r?\n\t\}') {
        foreach ($m in [regex]::Matches($Matches[1], '^\t\t"(\d+)"', 'Multiline')) { [void]$installed.Add($m.Groups[1].Value) }
    }
    $raw = $null
    if ($installed.Count -eq 0) {
        Add-Check 'Workshop' 'ATTENTION' 'aucun objet Workshop installé d''après appworkshop_233860.acf' 'Vérifier les abonnements dans Steam ; le pack en compte 676.'
        return
    }
    $csv = ''
    if ($packExists) { $csv = Join-Path (Split-Path -Parent $PackCfg) 'pack-modlist.csv' }
    if (-not $csv -or -not (Test-Path -LiteralPath $csv)) {
        Add-Check 'Workshop' 'ATTENTION' "$($installed.Count) objets installés ; pack-modlist.csv introuvable, écart au pack non calculé" 'Le fichier modlist\pack-modlist.csv du dépôt donne les identifiants Workshop du pack.'
        return
    }
    $packIds = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($row in @(Import-Csv -LiteralPath $csv -Encoding UTF8)) {
        if ("$($row.workshop_id)" -match '^\d+$') { [void]$packIds.Add($row.workshop_id) }
    }
    $outside = 0; foreach ($id in $installed) { if (-not $packIds.Contains($id)) { $outside++ } }
    $notInstalled = 0; foreach ($id in $packIds) { if (-not $installed.Contains($id)) { $notInstalled++ } }
    $detail = "$($installed.Count) objets installés : $outside hors pack, $notInstalled du pack non installés (pack : $($packIds.Count))"
    if ($outside -eq 0 -and $notInstalled -eq 0) { Add-Check 'Workshop' 'OK' $detail }
    elseif ($outside -eq 0) { Add-Check 'Workshop' 'ATTENTION' $detail 'Mods du pack absents du disque : vérifier les abonnements dans Steam (tools\update-pack.ps1 liste les mods non téléchargés ou devenus indisponibles).' }
    else { Add-Check 'Workshop' 'ATTENTION' $detail 'Se désabonner des mods hors pack dans Steam (verdicts dans modlist\extras-400.csv) : tant qu''ils sont installés, le lanceur Kenshi peut les réactiver.' }
}

# --- RE_Kenshi --------------------------------------------------------------
$reKenshi = [pscustomobject]@{ Enabled = $false; Executable = (Join-Path $gameDir 'RE_Kenshi\kenshi_x64.exe') }
if ($gameExists) {
    Invoke-Check 'RE_Kenshi' {
        $files = @(Get-ChildItem -LiteralPath $gameDir -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^RE_Kenshi' })
        $pluginLines = @()
        $pluginsCfg = Join-Path $gameDir 'Plugins_x64.cfg'
        $pluginsReadable = $false
        if (Test-Path -LiteralPath $pluginsCfg -PathType Leaf) {
            try {
                $pluginLines = @(Get-Content -LiteralPath $pluginsCfg -Encoding UTF8 -ErrorAction Stop | Where-Object { $_ -match '^\s*Plugin\s*=\s*RE_Kenshi(?:\.dll)?\s*$' })
                $pluginsReadable = $true
            }
            catch { }
        }
        $loaderPresent = Test-Path -LiteralPath (Join-Path $gameDir 'RE_Kenshi.dll') -PathType Leaf
        $baks = @(Get-ChildItem -LiteralPath $gameDir -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*.pre-rekenshi.bak' })
        $notInstalledAdvice = 'Requis par KenshiExtensionPlugin, Heightmap Fix et Fixed Skimmer Ragdoll (voir README). À installer après un premier test du pack seul, pour ne pas mélanger deux changements.'
        if ($loaderPresent -and $pluginLines.Count -gt 0) {
            $reKenshi.Enabled = $true
            $names = @($files | ForEach-Object { $_.Name }) -join ', '
            Add-Check 'RE_Kenshi' 'OK' "installé ($names ; $($pluginLines.Count) entrée(s) Plugin=RE_Kenshi)" 'RE_Kenshi fait tourner une version 1.0.65 du jeu et 33 mods du pack chargent alors leurs propres DLL : nouvelle source possible de plantages.'
        }
        elseif ($files.Count -gt 0 -or $pluginLines.Count -gt 0) {
            $what = @()
            if ($files.Count -gt 0) { $what += "fichiers : " + (@($files | ForEach-Object { $_.Name }) -join ', ') }
            if ($pluginLines.Count -gt 0) { $what += "Plugins_x64.cfg : " + ($pluginLines -join ' ; ') }
            if (-not $loaderPresent) { $what += 'RE_Kenshi.dll introuvable' }
            if (-not $pluginsReadable) { $what += 'Plugins_x64.cfg illisible' }
            Add-Check 'RE_Kenshi' 'ATTENTION' ('traces partielles, état indéterminé (' + ($what -join ' ; ') + ')') 'Installation incomplète ou désinstallation partielle : relancer l''installateur RE_Kenshi, ou restaurer les copies *.pre-rekenshi.bak.'
        }
        elseif ($baks.Count -gt 0) {
            Add-Check 'RE_Kenshi' 'ATTENTION' "non détecté ; $($baks.Count) copie(s) *.pre-rekenshi.bak présente(s) (installation préparée, non effectuée)" $notInstalledAdvice
        }
        elseif (-not $pluginsReadable) {
            Add-Check 'RE_Kenshi' 'ATTENTION' 'indéterminé : aucun fichier RE_Kenshi* et Plugins_x64.cfg illisible' 'Vérifier à la main la présence de RE_Kenshi dans le dossier du jeu.'
        }
        else {
            Add-Check 'RE_Kenshi' 'ATTENTION' 'non détecté (aucun fichier RE_Kenshi*, aucune entrée Plugin=RE_Kenshi)' $notInstalledAdvice
        }
    }
}

# --- Préférence GPU Windows -------------------------------------------------
Invoke-Check 'Préférence GPU' {
    $rootExe = Join-Path $gameDir 'kenshi_x64.exe'
    $exe = $rootExe
    if ($reKenshi.Enabled -and (Test-Path -LiteralPath $reKenshi.Executable -PathType Leaf)) { $exe = $reKenshi.Executable }

    # Le processus réel prime sur l'installation : --norekenshi garde l'exe racine.
    # Pendant la relance, le processus RE_Kenshi prime si les deux existent encore.
    $rootRunning = $false; $reRunning = $false; $unreadableProcessPath = $false
    foreach ($process in @(Get-Process kenshi_x64 -ErrorAction SilentlyContinue)) {
        $processPath = $null
        try { $processPath = $process.Path } catch { }
        if (-not $processPath) { $unreadableProcessPath = $true; continue }
        if ($processPath -ieq $rootExe) { $rootRunning = $true }
        if ($processPath -ieq $reKenshi.Executable) { $reRunning = $true }
    }
    if ($reRunning) { $exe = $reKenshi.Executable }
    elseif ($rootRunning) { $exe = $rootExe }
    $advice = "Paramètres Windows > Système > Affichage > Graphiques : ajouter $exe et choisir « Hautes performances » (GPU NVIDIA)."
    if ($unreadableProcessPath -and -not $rootRunning -and -not $reRunning) {
        Add-Check 'Préférence GPU' 'ATTENTION' "chemin du jeu en cours illisible ; exécutable attendu : $exe" $advice
        return
    }

    $value = $null
    try {
        $props = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' -ErrorAction Stop
        foreach ($p in $props.PSObject.Properties) { if ($p.Name -ieq $exe) { $value = "$($p.Value)"; break } }
    }
    catch { Add-Check 'Préférence GPU' 'ATTENTION' "préférences Windows illisibles pour $exe" $advice; return }
    if (-not $value) { Add-Check 'Préférence GPU' 'ATTENTION' "aucune préférence enregistrée pour $exe" $advice; return }
    if ($value -notmatch 'GpuPreference=(\d+)') { Add-Check 'Préférence GPU' 'ATTENTION' "valeur illisible pour $exe : $value" $advice; return }
    $pref = [int]$Matches[1]
    switch ($pref) {
        2 { Add-Check 'Préférence GPU' 'OK' "$exe : GpuPreference=2 (hautes performances)" }
        1 { Add-Check 'Préférence GPU' 'ATTENTION' "$exe : GpuPreference=1 (économie d'énergie : GPU intégré Intel)" $advice }
        0 { Add-Check 'Préférence GPU' 'ATTENTION' "$exe : GpuPreference=0 (choix laissé à Windows)" $advice }
        default { Add-Check 'Préférence GPU' 'ATTENTION' "$exe : GpuPreference=$pref (valeur inconnue)" $advice }
    }
}

# --- Smart App Control ------------------------------------------------------
Invoke-Check 'Smart App Control' {
    $where = 'Sécurité Windows > Contrôle des applications et du navigateur > Paramètres de Smart App Control.'
    $state = $null
    try { $state = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -ErrorAction Stop).VerifiedAndReputablePolicyState } catch { }
    if ($null -eq $state) { Add-Check 'Smart App Control' 'MANUEL' 'état illisible dans le registre' "Vérifier l'état dans $where"; return }
    switch ([int]$state) {
        0 { Add-Check 'Smart App Control' 'OK' 'désactivé' }
        1 { Add-Check 'Smart App Control' 'ATTENTION' 'activé : les fichiers non signés (RE_Kenshi, DLL de mods) peuvent être bloqués' "Si un mod ou RE_Kenshi est bloqué, le désactiver dans $where (irréversible sans réinstaller Windows)." }
        2 { Add-Check 'Smart App Control' 'ATTENTION' 'mode évaluation : Windows peut l''activer de lui-même et bloquer les fichiers non signés (RE_Kenshi, DLL de mods)' "Avant d'installer RE_Kenshi, choisir un état définitif dans $where" }
        default { Add-Check 'Smart App Control' 'ATTENTION' "état inconnu ($state)" "Vérifier l'état dans $where" }
    }
}

# --- Mémoire et fichier d'échange -------------------------------------------
Invoke-Check 'Mémoire' {
    $cs = Get-CimInstance Win32_ComputerSystem
    $os = Get-CimInstance Win32_OperatingSystem
    $ramGb = $cs.TotalPhysicalMemory / 1GB
    $freeGb = $os.FreePhysicalMemory * 1KB / 1GB
    $detail = '{0:N1} Go installés, {1:N1} Go libres' -f $ramGb, $freeGb
    if ($ramGb -lt 15) { Add-Check 'Mémoire' 'ATTENTION' $detail 'Avec 676 mods, Kenshi dépasse facilement 8 Go : 16 Go est le minimum confortable.' }
    elseif ($freeGb -lt 6) { Add-Check 'Mémoire' 'ATTENTION' $detail 'Fermer les applications gourmandes (navigateur, etc.) avant de lancer le jeu.' }
    else { Add-Check 'Mémoire' 'OK' $detail }

    $commitGb = $os.TotalVirtualMemorySize * 1KB / 1GB
    $usage = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
    $allocMb = 0; $peakMb = 0
    foreach ($u in $usage) { $allocMb += [int]$u.AllocatedBaseSize; $peakMb += [int]$u.PeakUsage }
    $fixAdvice = 'Paramètres système avancés > Performances > Avancé > Mémoire virtuelle : « Taille gérée par le système », ou taille fixe de 16 384 à 32 768 Mo.'
    if ($cs.AutomaticManagedPagefile) {
        Add-Check 'Fichier d''échange' 'OK' ('géré automatiquement par Windows ({0} Mo alloués, pic {1} Mo ; limite d''allocation {2:N1} Go)' -f $allocMb, $peakMb, $commitGb)
    }
    else {
        $settings = @(Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue)
        if ($settings.Count -eq 0) {
            Add-Check 'Fichier d''échange' 'ECHEC' 'aucun fichier d''échange configuré' "Kenshi moddé peut dépasser la RAM : $fixAdvice"
            return
        }
        $desc = @($settings | ForEach-Object { '{0} ({1}-{2} Mo)' -f $_.Name, $_.InitialSize, $_.MaximumSize }) -join ', '
        $maxMb = 0; $systemManaged = $false
        foreach ($s in $settings) { if ([int]$s.MaximumSize -eq 0) { $systemManaged = $true } else { $maxMb += [int]$s.MaximumSize } }
        if ($systemManaged) { Add-Check 'Fichier d''échange' 'OK' ('taille gérée par le système : {0} ; limite d''allocation {1:N1} Go' -f $desc, $commitGb) }
        elseif ($maxMb -lt 16384) { Add-Check 'Fichier d''échange' 'ATTENTION' ('taille fixe trop petite : {0} ; limite d''allocation {1:N1} Go' -f $desc, $commitGb) $fixAdvice }
        else { Add-Check 'Fichier d''échange' 'OK' ('taille fixe : {0} ; limite d''allocation {1:N1} Go' -f $desc, $commitGb) }
    }
}

# --- Espace disque du lecteur du jeu ----------------------------------------
Invoke-Check 'Espace disque' {
    $root = [IO.Path]::GetPathRoot($gameDir)
    if (-not $root) { Add-Check 'Espace disque' 'ATTENTION' "lecteur du jeu indéterminé ($gameDir)"; return }
    $drive = New-Object IO.DriveInfo($root)
    if (-not $drive.IsReady) { Add-Check 'Espace disque' 'ECHEC' "lecteur $root non prêt" 'Vérifier que le disque du jeu est bien connecté.'; return }
    $free = $drive.AvailableFreeSpace
    $detail = '{0} libres sur {1} (total {2})' -f (Format-Gb $free), $root, (Format-Gb $drive.TotalSize)
    if ($free -lt 10GB) { Add-Check 'Espace disque' 'ECHEC' $detail 'Libérer de la place : chaque plantage écrit un dump de ~70 Mo dans %LOCALAPPDATA%\CrashDumps et le Workshop pèse ~40 Go.' }
    elseif ($free -lt 30GB) { Add-Check 'Espace disque' 'ATTENTION' $detail 'Surveiller : les dumps de plantage (~70 Mo chacun) et les mises à jour Workshop consomment vite.' }
    else { Add-Check 'Espace disque' 'OK' $detail }
}

# --- Plantages récents ------------------------------------------------------
Invoke-Check 'Plantages 24 h' {
    $events = @(Get-KenshiCrashEvents -Since $since)
    $zips = @(); $dumps = @()
    if ($gameExists) {
        $zips = @(Get-ChildItem -LiteralPath $gameDir -File -Filter 'crashDump*.zip' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $since })
    }
    if (Test-Path -LiteralPath $paths.CrashDumps) {
        $dumps = @(Get-ChildItem -LiteralPath $paths.CrashDumps -File -Filter 'kenshi_x64*.dmp' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $since })
    }
    if ($events.Count -eq 0 -and $zips.Count -eq 0 -and $dumps.Count -eq 0) {
        Add-Check 'Plantages 24 h' 'OK' 'aucun (événements Windows 1000, crashDump*.zip, dumps WER)'
        return
    }
    $detail = '{0} événement(s) Windows, {1} archive(s) crashDump*.zip, {2} dump(s) WER' -f $events.Count, $zips.Count, $dumps.Count
    if ($events.Count -gt 0) {
        $last = $events[-1]
        $detail += ' ; dernier : {0} {1} {2} {3}' -f $last.Time.ToString('dd/MM HH:mm'), $last.Module, $last.ExceptionCode, $last.FaultOffset
    }
    elseif ($zips.Count -gt 0) {
        $detail += ' ; dernier : ' + ($zips | Sort-Object LastWriteTime | Select-Object -Last 1).LastWriteTime.ToString('dd/MM HH:mm')
    }
    Add-Check 'Plantages 24 h' 'ATTENTION' $detail 'Voir reports\crash-history.md ; lancer le jeu avec tools\play-kenshi.ps1 (qui démarre le moniteur) pour capturer journaux et dumps de la prochaine session.'
}

# --- Cartes graphiques et contrôles manuels ---------------------------------
Invoke-Check 'Cartes graphiques' {
    $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
    if ($gpus.Count -eq 0) { Add-Check 'Cartes graphiques' 'ATTENTION' 'aucune carte détectée par WMI'; return }
    $parts = @()
    foreach ($g in $gpus) {
        $label = "$($g.Name) (pilote $($g.DriverVersion)"
        # Pilote NVIDIA : les 5 derniers chiffres donnent le numéro GeForce (32.0.15.9608 -> 596.08)
        $digits = "$($g.DriverVersion)" -replace '\.', ''
        if ($g.Name -match 'NVIDIA' -and $digits -match '(\d{3})(\d{2})$') { $label += ", GeForce $($Matches[1]).$($Matches[2])" }
        $parts += $label + ')'
    }
    Add-Check 'Cartes graphiques' 'OK' ($parts -join ' ; ')
}
Add-Check 'Processeur PhysX' 'MANUEL' 'réglage NVIDIA non lisible de façon fiable depuis un script' 'Panneau de configuration NVIDIA > Configurer Surround, PhysX > Processeur PhysX : noter le choix (GPU RTX ou processeur). Kenshi utilise PhysX 2.8 ; en cas de plantage dans PhysXCore64.dll, essayer « Processeur ».'

# --- Sortie -----------------------------------------------------------------
$summary = [ordered]@{ OK = 0; ATTENTION = 0; ECHEC = 0; MANUEL = 0 }
foreach ($ch in $checks) { $summary[$ch.Status] = 1 + [int]$summary[$ch.Status] }
$exitCode = 0
if ($summary.ECHEC -gt 0) { $exitCode = 1 }

if ($Json) {
    [pscustomobject]@{
        Date       = (Get-Date).ToString('s')
        PowerShell = $PSVersionTable.PSVersion.ToString()
        Game       = $gameDir
        PackCfg    = $PackCfg
        Checks     = $checks.ToArray()
        Summary    = $summary
        ExitCode   = $exitCode
    } | ConvertTo-Json -Depth 4
}
else {
    $colors = @{ OK = 'Green'; ATTENTION = 'Yellow'; ECHEC = 'Red'; MANUEL = 'Cyan' }
    Write-Host ("Bilan de santé Kenshi : {0} (PowerShell {1})" -f (Get-Date).ToString('dd/MM/yyyy HH:mm'), $PSVersionTable.PSVersion)
    Write-Host "Jeu : $gameDir"
    Write-Host "Pack : $PackCfg"
    Write-Host ''
    Write-Host ('{0,-10} {1,-20} {2}' -f 'STATUT', 'CONTRÔLE', 'DÉTAIL')
    foreach ($ch in $checks) {
        Write-Host ('{0,-10} ' -f $ch.Status) -ForegroundColor $colors[$ch.Status] -NoNewline
        Write-Host ('{0,-20} {1}' -f $ch.Check, $ch.Detail)
        if ($ch.Advice) { Write-Host ('{0,-31} -> {1}' -f '', $ch.Advice) -ForegroundColor DarkGray }
    }
    Write-Host ''
    Write-Host ("Résumé : {0} OK, {1} ATTENTION, {2} ECHEC, {3} MANUEL" -f $summary.OK, $summary.ATTENTION, $summary.ECHEC, $summary.MANUEL)
    if ($exitCode -eq 0) { Write-Host 'Aucun ECHEC : rien ne bloque.' } else { Write-Host 'Au moins un ECHEC : corriger les points marqués avant de jouer.' }
}
exit $exitCode
