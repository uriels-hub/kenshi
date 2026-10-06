<#
.SYNOPSIS
    Résume les journaux actuels de Kenshi (kenshi_info.log, kenshi.log, save.log) sans
    passer par le moniteur.

.DESCRIPTION
    À lancer après une partie (ou un plantage) pour voir d'un coup : la dernière session
    de save.log (début, fin, sauvegardes), les mods chargés et ceux hors liste du pack,
    les erreurs et avertissements de kenshi_info.log (part des « Part map », cosmétiques),
    les messages les plus fréquents, les mods qui modifient des objets inexistants, les
    erreurs du moteur graphique (kenshi.log), puis les plantages depuis le début de la
    session : événements Windows 1000, dumps WER et crashDump*.zip écrit par Kenshi.
    Lecture seule : ne modifie ni le jeu, ni les sauvegardes, ni le Workshop.
    Kenshi écrase kenshi_info.log et kenshi.log à chaque lancement : le résumé porte
    donc sur la dernière session ; save.log, lui, s'accumule.
    Les deux journaux décrivent le même passage si « Session start. » (save.log) suit
    « [Launcher] Launching game » (kenshi_info.log) de 2 min au plus ; le temps passé
    dans le lanceur avant le clic sur Play ne compte pas. Sinon (passage arrêté au
    lanceur, qui réécrit kenshi_info.log sans rien ajouter à save.log, ou journaux
    d'époques différentes), le rapport le signale (« Passages différents ») et cherche
    les plantages depuis le plus ancien des deux débuts. Windows écrivant l'événement
    et le dump jusqu'à une minute après la fermeture, attendre un peu avant de lancer
    le résumé. Les journaux encore ouverts par le jeu (session en cours) sont lus
    quand même.
    Code de sortie : 0 sans signe de plantage, 2 si un plantage est détecté
    (événement Windows, dump ou session sans « Exit. »), 1 si les journaux manquent
    ou si -OutFile n'a pas pu être écrit.

.PARAMETER Game
    Dossier du jeu (détection automatique via Steam sinon).
.PARAMETER PackCfg
    Liste de référence (par défaut : modlist\mods.cfg du dépôt). Chaîne vide pour ne pas comparer.
.PARAMETER Top
    Nombre de lignes affichées dans chaque classement (30 par défaut).
.PARAMETER OutFile
    Écrit aussi le rapport (Markdown, UTF-8) dans ce fichier.
.PARAMETER SkipWindowsCrashReports
    N'interroge ni le journal des événements Windows ni le dossier des dumps WER
    (%LOCALAPPDATA%\CrashDumps) : seuls les journaux et l'archive crashDump*.zip du
    dossier du jeu sont examinés. Sert aux tests sur un faux dossier de jeu, pour ne
    pas y mêler les vrais plantages de la machine.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\summarize-logs.ps1
.EXAMPLE
    .\tools\summarize-logs.ps1 -Top 10 -OutFile reports\derniere-session.md
#>
[CmdletBinding()]
param(
    [string]$Game,
    [string]$PackCfg,
    [ValidateRange(0, 10000)][int]$Top = 30,
    [string]$OutFile,
    [switch]$SkipWindowsCrashReports
)
Import-Module (Join-Path $PSScriptRoot 'KenshiTools.psm1') -Force
if (-not $PSBoundParameters.ContainsKey('PackCfg')) { $PackCfg = Join-Path $PSScriptRoot '..\modlist\mods.cfg' }
if ($PackCfg -and -not (Test-Path -LiteralPath $PackCfg)) { Write-Warning "Liste du pack introuvable, comparaison ignorée : $PackCfg"; $PackCfg = '' }
if ($PackCfg) { $PackCfg = (Resolve-Path -LiteralPath $PackCfg).ProviderPath }

$paths = Get-KenshiPaths -Game $Game
$gameDir = $paths.Game
$infoLog = $paths.InfoLog
$ogreLog = Join-Path $gameDir 'kenshi.log'
$saveLog = $paths.SaveLog
$invariant = [Globalization.CultureInfo]::InvariantCulture

if (-not (Test-Path -LiteralPath $infoLog) -and -not (Test-Path -LiteralPath $saveLog)) {
    Write-Error "Aucun journal trouvé dans $gameDir (kenshi_info.log, save.log)."
    exit 1
}

# --- helpers privés ---------------------------------------------------------

$md = New-Object 'System.Collections.Generic.List[string]'
function Add-Line([string]$Text = '') { $md.Add($Text) }
function Format-Cell([string]$Text) { ($Text -replace '\|', '\|').Trim() }
function Format-Size([long]$Bytes) {
    if ($Bytes -ge 1MB) { return ('{0:N1} Mo' -f ($Bytes / 1MB)) }
    '{0:N0} Ko' -f [math]::Max(1, [math]::Round($Bytes / 1KB))
}
function Format-When([datetime]$Time) { $Time.ToString('dd/MM/yyyy HH:mm:ss') }
function Format-Span([timespan]$Span) {
    $s = [math]::Abs($Span.TotalSeconds)
    if ($s -lt 120) { return ('{0} s' -f [math]::Round($s)) }
    if ($s -lt 7200) { return ('{0} min' -f [math]::Round($s / 60, 1)) }
    '{0} h' -f [math]::Round($s / 3600, 1)
}
function Get-ExceptionLabel([string]$Code) {
    switch ("$Code".ToLower()) {
        '0xc0000005' { return "violation d'accès" }
        '0xc0000006' { return 'erreur de page (lecture mémoire/disque)' }
        '0xc0000017' { return 'mémoire insuffisante' }
        '0xc000001d' { return 'instruction illégale' }
        '0xc0000374' { return 'corruption du tas' }
        '0xc0000409' { return 'dépassement de tampon détecté' }
        '0xc000041d' { return 'exception non gérée dans un rappel (callback)' }
        '0xc00000fd' { return 'débordement de pile' }
        '0xe06d7363' { return 'exception C++ non rattrapée' }
        '0x80000003' { return "point d'arrêt" }
    }
    $null
}
# Heure HH:mm:ss de save.log -> date complète, calée sur la date de référence
function ConvertTo-DateTime([string]$Clock, [datetime]$Reference, [switch]$NotAfter) {
    $t = [TimeSpan]::Parse($Clock)
    $d = $Reference.Date + $t
    if ($NotAfter) { if ($d -gt $Reference) { $d = $d.AddDays(-1) } }
    elseif ($d -lt $Reference) { $d = $d.AddDays(1) }
    $d
}
function Add-List([string]$Label, [string[]]$Items) {
    Add-Line ("- {0} : {1}" -f $Label, $Items.Count)
    foreach ($i in @($Items | Select-Object -First $Top)) { Add-Line "  - $i" }
    if ($Items.Count -gt $Top) { Add-Line ("  - ... et {0} autres" -f ($Items.Count - $Top)) }
}

# --- fichiers et repères temporels -----------------------------------------

$files = @{}
foreach ($f in $infoLog, $ogreLog, $saveLog) { if (Test-Path -LiteralPath $f) { $files[$f] = Get-Item -LiteralPath $f } }
$running = [bool](Get-Process kenshi_x64 -ErrorAction SilentlyContinue)

$sessionStart = $null; $version = $null; $launched = $false; $launchTime = $null
if ($files.ContainsKey($infoLog)) {
    foreach ($line in @(Get-Content -LiteralPath $infoLog -Encoding UTF8 -TotalCount 200)) {
        if (-not $sessionStart -and $line -match '(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) \[info\]: \*\* Kenshi start') {
            $sessionStart = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $invariant)
        }
        if (-not $version -and $line -match '\[info\]: Version: (.+)$') { $version = $Matches[1].Trim() }
        # Le lanceur n'écrit cette ligne qu'au clic sur Play ; sans elle, le passage s'est arrêté au lanceur.
        # Son heure est celle à comparer avec « Session start. » (écrit ~3 s plus tard), pas « Kenshi start ».
        if (-not $launchTime -and $line -match '(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) \[info\]: \[Launcher\] Launching game') {
            $launchTime = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $invariant)
        }
        if ($line -match '\[Launcher\] Launching game|\[Mods\] Loaded mod:') { $launched = $true }
    }
}

$sessions = @(); $last = $null
if ($files.ContainsKey($saveLog)) {
    try { $sessions = @(Get-KenshiSessions -SaveLog $saveLog) }
    catch { Write-Warning "save.log illisible : $($_.Exception.Message)" }
    if ($sessions.Count -gt 0) { $last = $sessions[-1] }
}
$startSource = 'kenshi_info.log'
$saveStart = $null   # début de la dernière session de save.log, daté par sa dernière écriture
if ($last) { $saveStart = ConvertTo-DateTime $last.StartTime $files[$saveLog].LastWriteTime -NotAfter }
if (-not $sessionStart -and $last) {
    # Pas de date dans save.log : on prend celle de sa dernière écriture
    $sessionStart = $saveStart
    $startSource = 'save.log, date déduite de sa dernière écriture'
}
# kenshi_info.log est réécrit à chaque passage, même arrêté au lanceur ; save.log ne reçoit
# « Session start. » qu'après le clic sur Play. Les deux fichiers décrivent le même passage
# si save.log démarre dans les 2 min qui suivent « Launching game » (le lanceur peut rester
# ouvert longtemps avant le clic : « Kenshi start » ne sert de repère qu'à défaut).
$runsDiffer = $false; $infoRunNewer = $false
if ($last -and $startSource -eq 'kenshi_info.log') {
    $reference = $sessionStart
    if ($launchTime) { $reference = $launchTime }
    $gap = ([TimeSpan]::Parse($last.StartTime) - $reference.TimeOfDay).TotalMinutes
    if ($gap -lt -1) { $gap += 1440 }
    if (-not $launched -or $gap -gt 2) {
        $runsDiffer = $true
        $infoRunNewer = ($saveStart -lt $sessionStart)
        if ($infoRunNewer) { $sessionStart = $saveStart; $startSource = 'save.log (passage antérieur à celui de kenshi_info.log), date déduite de sa dernière écriture' }
    }
}
$lastWrite = $null
foreach ($fi in $files.Values) { if (-not $lastWrite -or $fi.LastWriteTime -gt $lastWrite) { $lastWrite = $fi.LastWriteTime } }

# --- en-tête ---------------------------------------------------------------

Add-Line ("# Journaux Kenshi : résumé du {0}" -f (Format-When (Get-Date)))
Add-Line
Add-Line "- Jeu : $gameDir"
if ($version) { Add-Line "- Version : $version" }
if ($PackCfg) { Add-Line ("- Pack de référence : {0} ({1} mods)" -f $PackCfg, @(Get-ActiveModList -Path $PackCfg).Count) }
else { Add-Line '- Pack de référence : aucun (comparaison désactivée)' }
if ($running) { Add-Line '- **Kenshi est en cours d''exécution** : les journaux sont incomplets.' }
Add-Line
Add-Line '## Fichiers analysés'
Add-Line
foreach ($f in $infoLog, $ogreLog, $saveLog) {
    $name = [IO.Path]::GetFileName($f)
    if ($files.ContainsKey($f)) { Add-Line ("- {0} : {1}, dernière écriture {2}" -f $name, (Format-Size $files[$f].Length), (Format-When $files[$f].LastWriteTime)) }
    else { Add-Line "- $name : absent" }
}

# --- dernière session (save.log) ---------------------------------------------

Add-Line
Add-Line '## Dernière session (save.log)'
Add-Line
$abruptEnd = $false
if (-not $last) {
    Add-Line '- Aucune session trouvée dans save.log.'
}
else {
    Add-Line ("- Session {0} sur {1} dans save.log" -f $last.Index, $sessions.Count)
    $startText = "- Début : $($last.StartTime)"
    if ($sessionStart -and $startSource -eq 'kenshi_info.log') { $startText += " (kenshi_info.log : $(Format-When $sessionStart))" }
    Add-Line $startText
    if ($runsDiffer) {
        $why = 'kenshi_info.log décrit un passage plus récent'
        if (-not $infoRunNewer) { $why = 'kenshi_info.log décrit un passage antérieur à cette session de save.log' }
        if (-not $launched) { $why += ', arrêté au lanceur (pas de « Launching game »)' }
        Add-Line ("- **Passages différents** : {0} ; cette session de save.log n'est pas celle de kenshi_info.log (mods et erreurs ci-dessous = passage de kenshi_info.log)." -f $why)
    }
    if ($last.HasExit) {
        Add-Line ("- Fin : « Exit. » à {0}, durée {1}" -f $last.ExitTime, $last.Duration.ToString())
    }
    else {
        $abruptEnd = -not $running
        $tail = 'arrêt brutal'
        if ($running) { $tail = 'session en cours' }
        Add-Line ("- Fin : pas de « Exit. » ({0}) ; dernière écriture dans les journaux à {1}" -f $tail, (Format-When $lastWrite))
    }
    if ($last.WarningCount + $last.ErrorCount -gt 0) {
        Add-Line ("- Lignes [Warning] / [Error] dans save.log : {0} / {1}" -f $last.WarningCount, $last.ErrorCount)
    }
    if ($last.SaveCount -eq 0) { Add-Line '- Sauvegardes pendant la session : aucune' }
    else {
        Add-Line ("- Sauvegardes pendant la session : {0}" -f $last.SaveCount)
        foreach ($s in @($last.Saves | Select-Object -Last $Top)) { Add-Line ("  - {0} : {1}" -f $s.Time, $s.Path) }
    }
    # Dernière sauvegarde connue, toutes sessions confondues (utile quand la dernière n'en a aucune)
    $lastSave = $null
    foreach ($s in $sessions) { if ($s.SaveCount -gt 0) { $lastSave = [pscustomobject]@{ Session = $s.Index; Save = $s.Saves[-1] } } }
    if ($lastSave -and $lastSave.Session -ne $last.Index) {
        Add-Line ("- Dernière sauvegarde de save.log : session {0}, {1}, {2}" -f $lastSave.Session, $lastSave.Save.Time, $lastSave.Save.Path)
    }
}

# --- mods, erreurs et avertissements (kenshi_info.log) ---------------------

Add-Line
Add-Line '## Mods chargés (kenshi_info.log)'
Add-Line
$summary = $null
if ($files.ContainsKey($infoLog)) {
    try { $summary = Get-KenshiLogSummary -InfoLog $infoLog -PackCfg $PackCfg }
    catch { Write-Warning "kenshi_info.log illisible : $($_.Exception.Message)" }
}
if (-not $summary) {
    Add-Line '- kenshi_info.log absent ou illisible : pas de résumé des mods ni des erreurs.'
}
else {
    Add-Line "- Mods chargés : $($summary.LoadedCount)"
    if (Test-Path -LiteralPath $paths.ModsCfg) {
        try { Add-Line ("- Liste active (data\mods.cfg) : {0} entrées" -f @(Get-ActiveModList -Path $paths.ModsCfg).Count) } catch { }
    }
    if ($PackCfg) {
        Add-List 'Mods chargés hors liste du pack' $summary.ExtraMods
        Add-List 'Mods du pack non chargés' $summary.PackModsNotLoaded
    }

    Add-Line
    Add-Line '## Erreurs et avertissements (kenshi_info.log)'
    Add-Line
    $share = 0
    if ($summary.WarningCount -gt 0) { $share = [math]::Round(100 * $summary.PartMapCount / $summary.WarningCount, 1) }
    Add-Line ("- Erreurs : {0}" -f $summary.ErrorCount)
    Add-Line ("- Avertissements : {0}, dont {1} « Part map contains invalid colour » ({2} %, cosmétiques)" -f $summary.WarningCount, $summary.PartMapCount, $share)
    $otherCount = $summary.ErrorCount + $summary.WarningCount - $summary.PartMapCount
    Add-Line ("- Messages distincts hors Part map : {0} (pour {1} lignes)" -f $summary.Messages.Count, $otherCount)
    Add-Line
    Add-Line ("### Messages les plus fréquents (hors Part map, nombres remplacés par #, {0} premiers)" -f $Top)
    Add-Line
    if ($summary.Messages.Count -eq 0) { Add-Line 'Aucun.' }
    else {
        Add-Line '| Nb | Niveau | Message |'
        Add-Line '|---:|---|---|'
        foreach ($m in @($summary.Messages | Select-Object -First $Top)) {
            Add-Line ("| {0} | {1} | {2} |" -f $m.Count, $m.Level, (Format-Cell $m.Message))
        }
    }
    Add-Line
    Add-Line '### Mods qui modifient des objets inexistants'
    Add-Line
    if ($summary.ModsModifyingMissingItems.Count -eq 0) { Add-Line 'Aucun.' }
    else {
        Add-Line ("{0} mod(s) concerné(s)." -f $summary.ModsModifyingMissingItems.Count)
        Add-Line
        Add-Line '| Nb | Mod |'
        Add-Line '|---:|---|'
        foreach ($m in @($summary.ModsModifyingMissingItems | Select-Object -First $Top)) {
            Add-Line ("| {0} | {1} |" -f $m.Count, (Format-Cell $m.Mod))
        }
        if ($summary.ModsModifyingMissingItems.Count -gt $Top) { Add-Line ("| ... | et {0} autres |" -f ($summary.ModsModifyingMissingItems.Count - $Top)) }
    }
}

# --- moteur graphique (kenshi.log, journal OGRE) ----------------------------

Add-Line
Add-Line '## Moteur graphique (kenshi.log)'
Add-Line
if (-not $files.ContainsKey($ogreLog)) {
    Add-Line '- kenshi.log absent.'
}
else {
    $ogreLines = 0; $firstClock = $null; $lastClock = $null; $shutdown = $false
    $ogreGroups = @{}; $ogreCounts = [ordered]@{ Exceptions = 0; CompilerErrors = 0; Warnings = 0 }
    # Le jeu garde kenshi.log ouvert en écriture pendant la session : lecture avec partage
    $ogreReader = $null
    try {
        $ogreReader = Open-KenshiLogReader -Path $ogreLog
        while ($null -ne ($line = $ogreReader.ReadLine())) {
            $ogreLines++
            $text = $line
            if ($line -match '^(\d{1,2}:\d{1,2}:\d{1,2}):\s*(.*)$') {
                if (-not $firstClock) { $firstClock = $Matches[1] }
                $lastClock = $Matches[1]; $text = $Matches[2]
            }
            if ($text -match 'OGRE Shutdown') { $shutdown = $true }
            $kind = $null
            if ($text -match 'OGRE EXCEPTION') { $kind = 'Exceptions' }
            elseif ($text -match '^Compiler error') { $kind = 'CompilerErrors' }
            elseif ($text -match '^WARNING') { $kind = 'Warnings' }
            if (-not $kind) { continue }
            $ogreCounts[$kind] = $ogreCounts[$kind] + 1
            $key = $text -replace '\d+', '#'
            if ($key.Length -gt 200) { $key = $key.Substring(0, 200) }
            $ogreGroups[$key] = 1 + [int]$ogreGroups[$key]
        }
    }
    catch { Write-Warning "kenshi.log illisible : $($_.Exception.Message)" }
    finally { if ($ogreReader) { $ogreReader.Dispose() } }
    Add-Line ("- {0} lignes, de {1} à {2}" -f $ogreLines, $firstClock, $lastClock)
    if ($shutdown) { Add-Line "- Séquence d'arrêt d'OGRE (« OGRE Shutdown ») : présente, le moteur s'est arrêté normalement" }
    else { Add-Line "- Séquence d'arrêt d'OGRE (« OGRE Shutdown ») : absente ; le jeu ne s'est pas fermé proprement, ou le journal est encore ouvert" }
    Add-Line ("- Exceptions OGRE : {0} ; erreurs de compilation (scripts .pu/.material) : {1} ; avertissements : {2}" -f $ogreCounts.Exceptions, $ogreCounts.CompilerErrors, $ogreCounts.Warnings)
    $ogreTop = @($ogreGroups.GetEnumerator() |
        Sort-Object -Property @{ Expression = 'Value'; Descending = $true }, @{ Expression = 'Key'; Descending = $false } |
        Select-Object -First $Top)
    if ($ogreTop.Count -gt 0) {
        Add-Line
        Add-Line ("### Messages OGRE les plus fréquents (nombres remplacés par #, {0} premiers)" -f $Top)
        Add-Line
        Add-Line '| Nb | Message |'
        Add-Line '|---:|---|'
        foreach ($g in $ogreTop) { Add-Line ("| {0} | {1} |" -f $g.Value, (Format-Cell $g.Key)) }
    }
}

# --- plantages depuis le début de la session ---------------------------------

Add-Line
Add-Line '## Plantages depuis le début de la session'
Add-Line
$crashEvidence = $false
$since = $sessionStart
if (-not $since) {
    $since = (Get-Date).AddDays(-1)
    Add-Line ("- Début de session inconnu : recherche limitée aux dernières 24 h (depuis {0})." -f (Format-When $since))
}
else { Add-Line ("- Recherche depuis {0} (début de session d'après {1})." -f (Format-When $since), $startSource) }

$exitAt = $null
if ($sessionStart -and $last -and $last.HasExit) {
    $ref = $sessionStart
    if ($runsDiffer) { $ref = $saveStart }   # l'heure « Exit. » appartient à la session de save.log
    $exitAt = ConvertTo-DateTime $last.ExitTime $ref
}
if (-not $running -and $lastWrite -and ((Get-Date) - $lastWrite).TotalSeconds -lt 90) {
    Add-Line "- Journaux écrits il y a moins d'une minute et demie : Windows peut encore écrire l'événement de plantage et le dump, relancer dans un instant."
}

$events = @()
if (-not $SkipWindowsCrashReports) {
    try { $events = @(Get-KenshiCrashEvents -Since $since) } catch { Write-Warning "Journal des événements Windows illisible : $($_.Exception.Message)" }
}
if ($SkipWindowsCrashReports) { Add-Line '- Événements Windows et dumps WER : non examinés (-SkipWindowsCrashReports)' }
elseif ($events.Count -eq 0) { Add-Line '- Événements Windows 1000 (Application Error) : aucun' }
else {
    $crashEvidence = $true
    Add-Line ("- Événements Windows 1000 (Application Error) : {0}" -f $events.Count)
    foreach ($e in $events) {
        $label = Get-ExceptionLabel $e.ExceptionCode
        $code = "$($e.ExceptionCode)"
        if ($label) { $code += " ($label)" }
        $module = ("{0} {1}" -f $e.Module, $e.ModuleVersion).Trim()
        $item = "  - {0} : {1}, code {2}, offset {3}" -f (Format-When $e.Time), $module, $code, $e.FaultOffset
        if ($e.ProcessId) { $item += ", PID $($e.ProcessId)" }
        if ($exitAt) {
            $delta = $e.Time - $exitAt
            if ([math]::Abs($delta.TotalHours) -lt 12) {
                if ($delta.TotalSeconds -ge 0) { $item += (" ; {0} après « Exit. »" -f (Format-Span $delta)) }
                else { $item += (" ; {0} avant « Exit. »" -f (Format-Span $delta)) }
            }
        }
        Add-Line $item
    }
}

$dumps = @()
if (-not $SkipWindowsCrashReports -and (Test-Path -LiteralPath $paths.CrashDumps)) {
    $dumps = @(Get-ChildItem -LiteralPath $paths.CrashDumps -File -Filter 'kenshi_x64*.dmp' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $since } | Sort-Object LastWriteTime)
}
if ($SkipWindowsCrashReports) { }
elseif ($dumps.Count -eq 0) { Add-Line ("- Dumps WER ({0}) plus récents que la session : aucun" -f $paths.CrashDumps) }
else {
    $crashEvidence = $true
    Add-Line ("- Dumps WER ({0}) plus récents que la session : {1}" -f $paths.CrashDumps, $dumps.Count)
    foreach ($d in $dumps) { Add-Line ("  - {0} : {1}, {2}" -f $d.Name, (Format-When $d.LastWriteTime), (Format-Size $d.Length)) }
}

$zips = @(Get-ChildItem -LiteralPath $gameDir -File -Filter 'crashDump*.zip' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
$newZips = @($zips | Where-Object { $_.LastWriteTime -ge $since })
if ($newZips.Count -gt 0) {
    $crashEvidence = $true
    foreach ($z in $newZips) {
        Add-Line ("- crashDump*.zip écrit par Kenshi : {0}, {1}, {2} : **postérieur au début de la session**" -f $z.Name, (Format-When $z.LastWriteTime), (Format-Size $z.Length))
    }
}
elseif ($zips.Count -gt 0) {
    foreach ($z in $zips) {
        Add-Line ("- crashDump*.zip écrit par Kenshi : {0} présent mais antérieur à la session ({1})" -f $z.Name, (Format-When $z.LastWriteTime))
    }
}
else { Add-Line '- crashDump*.zip écrit par Kenshi : aucun' }

if ($abruptEnd) { $crashEvidence = $true }
Add-Line
if ($crashEvidence) { Add-Line '**Conclusion : signes de plantage pendant ou après cette session.**' }
elseif ($running) { Add-Line '**Conclusion : session en cours, aucun plantage pour l''instant.**' }
else { Add-Line '**Conclusion : aucun signe de plantage pour cette session.**' }

# --- sortie ------------------------------------------------------------------

foreach ($l in $md) { Write-Host $l }
if ($OutFile) {
    # Chemin absolu sur $PWD : .NET résoudrait un chemin relatif sur le répertoire du processus
    $OutFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
    try {
        $dir = Split-Path -Parent $OutFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
        # Rapport destiné à être partagé : le dossier du profil (nom d'utilisateur) est masqué
        $profileRx = [regex]::Escape($env:USERPROFILE)
        $lines = [string[]]@($md.ToArray() | ForEach-Object { [regex]::Replace($_, $profileRx, '%USERPROFILE%', 'IgnoreCase') })
        [IO.File]::WriteAllLines($OutFile, $lines, (New-Object Text.UTF8Encoding $false))
    }
    catch { Write-Error "Rapport non écrit ($OutFile) : $($_.Exception.Message)"; exit 1 }
    Write-Host ''
    Write-Host "Rapport écrit : $OutFile"
}

if ($crashEvidence) { exit 2 } else { exit 0 }
