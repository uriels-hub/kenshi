<#
.SYNOPSIS
    Synchronise la liste du pack (modlist\) avec la collection Steam.

.DESCRIPTION
    Lit la collection Workshop via l'API Web publique de Steam (GetCollectionDetails
    puis GetPublishedFileDetails par lots de 100), retrouve pour chaque objet le
    fichier .mod téléchargé dans le dossier Workshop (dossier nommé par l'ID) et
    compare le résultat avec modlist\pack-modlist.csv : mods ajoutés, retirés,
    déplacés, modifiés (titre, fichier, dépendances), non téléchargés localement et
    devenus indisponibles sur le Workshop (result != 1). Les éléments qui ne sont pas
    des mods (sous-collections liées) sont ignorés et signalés.
    L'ORDRE de chargement vient du fil « Load Order » de l'auteur du pack (son mods.cfg
    officiel, plus à jour que l'ordre de la collection et qui peut contenir des mods
    hors collection, comme Beam Thing) : les mods y sont rangés dans cet ordre, ceux de
    la collection absents du fil sont ajoutés à la fin et signalés, ceux du fil non
    installés (mods hors Steam) sont signalés et ignorés. -LoadOrderTopic '' revient à
    l'ordre de la collection.
    Par défaut, rapport seulement. Avec -Apply, réécrit modlist\mods.cfg (UTF-8 sans
    BOM) et modlist\pack-modlist.csv (mêmes colonnes) dans le dépôt uniquement,
    après sauvegarde en .<horodatage>.bak ; le dossier du jeu n'est jamais touché.
    Un mod sans fichier .mod connu (nouveau et pas encore téléchargé) n'est pas
    écrit dans mods.cfg : s'y abonner dans Steam puis relancer le script.
    Code de sortie : 0 si le pack est à jour (ou vient d'être écrit), 2 si des
    différences existent sans -Apply, 1 en cas d'erreur (réseau, fichiers).

.PARAMETER CollectionId
    ID Workshop de la collection (par défaut : 2822248814, MEGA Kaizo/UWE+).
.PARAMETER LoadOrderTopic
    ID du fil de discussion « Load Order » de la collection (par défaut :
    3417684283218879155). Chaîne vide : ordre de la collection.
.PARAMETER Apply
    Écrit mods.cfg et pack-modlist.csv dans le dossier modlist.
.PARAMETER Workshop
    Dossier Workshop (détection automatique via Steam sinon).
.PARAMETER ModlistDir
    Dossier contenant mods.cfg et pack-modlist.csv (par défaut : modlist\ du dépôt).
    Utile pour tester -Apply sur une copie.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\update-pack.ps1
.EXAMPLE
    .\tools\update-pack.ps1 -Apply
.EXAMPLE
    .\tools\update-pack.ps1 -Apply -ModlistDir "$env:TEMP\modlist-test"
#>
[CmdletBinding()]
param(
    [string]$CollectionId = '2822248814',
    [string]$LoadOrderTopic = '3417684283218879155',
    [switch]$Apply,
    [string]$Workshop,
    [string]$ModlistDir
)
Import-Module (Join-Path $PSScriptRoot 'KenshiTools.psm1') -Force
if (-not $ModlistDir) { $ModlistDir = Join-Path $PSScriptRoot '..\modlist' }
if (-not (Test-Path -LiteralPath $ModlistDir)) { Write-Error "Dossier modlist introuvable : $ModlistDir"; exit 1 }
$ModlistDir = (Resolve-Path -LiteralPath $ModlistDir).ProviderPath
$csvPath = Join-Path $ModlistDir 'pack-modlist.csv'
$cfgPath = Join-Path $ModlistDir 'mods.cfg'

$coreFiles = @('gamedata.base', 'Newwworld.mod', 'Dialogue.mod', 'rebirth.mod')
$csvColumns = @('position', 'workshop_id', 'mod_file', 'title', 'dependencies', 'url')
$apiBase = 'https://api.steampowered.com/ISteamRemoteStorage/'

# --- helpers privés ---------------------------------------------------------

# Deux nouvelles tentatives sur une erreur passagère du serveur (HTTP 5xx, délai dépassé)
function Invoke-SteamApi([string]$Method, [hashtable]$Form) {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $ProgressPreference = 'SilentlyContinue'
    $r = $null; $lastError = $null
    for ($attempt = 1; $attempt -le 3 -and -not $r; $attempt++) {
        try { $r = Invoke-RestMethod -Method Post -Uri ($apiBase + $Method + '/v1/') -Body $Form -TimeoutSec 60 -ErrorAction Stop }
        catch {
            $lastError = $_.Exception.Message
            $transient = ($lastError -match '\(5\d\d\)|success: 5\d\d|délai|timed out|timeout')
            if (-not $transient -or $attempt -eq 3) { break }
            Write-Warning "Steam $Method : $lastError ; nouvelle tentative ($attempt/2) dans 5 s."
            Start-Sleep 5
        }
    }
    if (-not $r) { throw "Appel Steam $Method impossible : $lastError (réessayer dans quelques minutes si le serveur Steam répond 5xx)" }
    if (-not $r.response) { throw "Réponse Steam vide pour $Method" }
    $r.response
}

function Get-Prop($Object, [string]$Name, $Default) {
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    $p.Value
}

# Indique, pour chaque élément de la suite, s'il fait partie d'une plus longue
# sous-suite croissante : les autres sont ceux qui ont bougé.
function Get-LisMembership([int[]]$Seq) {
    $n = $Seq.Count
    $member = New-Object bool[] $n
    if ($n -eq 0) { return $member }
    $tail = New-Object int[] $n
    $prev = New-Object int[] $n
    $len = 0
    for ($i = 0; $i -lt $n; $i++) {
        $lo = 0; $hi = $len
        while ($lo -lt $hi) {
            $mid = [int][Math]::Floor(($lo + $hi) / 2)
            if ($Seq[$tail[$mid]] -lt $Seq[$i]) { $lo = $mid + 1 } else { $hi = $mid }
        }
        if ($lo -gt 0) { $prev[$i] = $tail[$lo - 1] } else { $prev[$i] = -1 }
        $tail[$lo] = $i
        if ($lo -eq $len) { $len++ }
    }
    $k = $tail[$len - 1]
    while ($k -ge 0) { $member[$k] = $true; $k = $prev[$k] }
    $member
}

function ConvertTo-CsvLine([object]$Row) {
    $cells = foreach ($c in $csvColumns) { '"' + ("$($Row.$c)" -replace '"', '""') + '"' }
    $cells -join ','
}

# Titre, sinon nom du fichier .mod (mods devenus privés : Steam ne renvoie plus de titre)
function Get-DisplayTitle([string]$Title, [string]$File = '') {
    if ($Title) { return $Title }
    if ($File) { return "(sans titre : $File)" }
    '(sans titre)'
}

# mods.cfg officiel publié par l'auteur dans le premier message du fil « Load Order »
# (bloc de code BBCode) : lignes .mod dans l'ordre, sans les titres de section.
function Get-AuthorLoadOrder([string]$Collection, [string]$Topic) {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $ProgressPreference = 'SilentlyContinue'
    $uri = "https://steamcommunity.com/workshop/filedetails/discussion/$Collection/$Topic/"
    $html = $null; $lastError = $null
    for ($attempt = 1; $attempt -le 3 -and -not $html; $attempt++) {
        try { $html = (Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop).Content }
        catch { $lastError = $_.Exception.Message; if ($attempt -lt 3) { Start-Sleep 5 } }
    }
    if (-not $html) { throw "Fil « Load Order » illisible ($uri) : $lastError" }
    $start = $html.IndexOf("id=""forum_op_content_$Topic""")
    if ($start -lt 0) { throw "Premier message du fil introuvable dans $uri" }
    $code = $html.IndexOf('<div class="bb_code">', $start)
    if ($code -lt 0) { throw "Bloc mods.cfg introuvable dans le premier message de $uri" }
    $code += '<div class="bb_code">'.Length
    $end = $html.IndexOf('</div>', $code)
    $text = $html.Substring($code, $end - $code) -replace '(?i)<br\s*/?>', "`n" -replace '<[^>]+>', ''
    $text = [Net.WebUtility]::HtmlDecode($text)
    $updated = ''
    if ($html.Substring($start, $code - $start) -match 'Updated\s+([0-9][0-9./-]+)') { $updated = $Matches[1] }
    [pscustomobject]@{
        Uri = $uri; Updated = $updated
        Files = @($text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '\.mod$' } | Select-Object -Unique)
    }
}

function Show([string]$Label, [array]$Items) {
    Write-Host ("{0} : {1}" -f $Label, $Items.Count)
    foreach ($i in $Items) { Write-Host "  $i" }
}

# --- collection Steam -------------------------------------------------------

try {
    $resp = Invoke-SteamApi 'GetCollectionDetails' @{ collectioncount = 1; 'publishedfileids[0]' = $CollectionId }
    $col = @(Get-Prop $resp 'collectiondetails' @())
    if ($col.Count -eq 0) { throw "Collection $CollectionId absente de la réponse Steam" }
    $col = $col[0]
    $colResult = [int](Get-Prop $col 'result' 0)
    if ($colResult -ne 1) { throw "Collection $CollectionId indisponible (result=$colResult)" }
}
catch { Write-Error $_.Exception.Message; exit 1 }

$children = @()
$i = 0
foreach ($c in @(Get-Prop $col 'children' @())) {
    $children += [pscustomobject]@{
        Id = "$(Get-Prop $c 'publishedfileid' '')"
        SortOrder = [int](Get-Prop $c 'sortorder' 0)
        FileType = [int](Get-Prop $c 'filetype' 0)
        Index = $i
    }
    $i++
}
$children = @($children | Where-Object { $_.Id } | Sort-Object SortOrder, Index)   # Index : départage les sortorder en double
$modChildren = @($children | Where-Object { $_.FileType -eq 0 })
$otherChildren = @($children | Where-Object { $_.FileType -ne 0 })

$details = @{}
$allIds = @($children | ForEach-Object { $_.Id })
try {
    for ($start = 0; $start -lt $allIds.Count; $start += 100) {
        $batch = @($allIds[$start..([Math]::Min($start + 99, $allIds.Count - 1))])
        $form = @{ itemcount = $batch.Count }
        for ($j = 0; $j -lt $batch.Count; $j++) { $form["publishedfileids[$j]"] = $batch[$j] }
        $resp = Invoke-SteamApi 'GetPublishedFileDetails' $form
        foreach ($d in @(Get-Prop $resp 'publishedfiledetails' @())) { $details["$(Get-Prop $d 'publishedfileid' '')"] = $d }
    }
}
catch { Write-Error $_.Exception.Message; exit 1 }

$author = $null
if ($LoadOrderTopic) {
    try { $author = Get-AuthorLoadOrder $CollectionId $LoadOrderTopic }
    catch { Write-Error "$($_.Exception.Message). Réessayer plus tard, ou passer -LoadOrderTopic '' pour l'ordre de la collection."; exit 1 }
    if ($author.Files.Count -eq 0) { Write-Error "Aucune ligne .mod dans le fil $($author.Uri)"; exit 1 }
}

# --- fichiers locaux --------------------------------------------------------

$paths = Get-KenshiPaths -Workshop $Workshop
$wsDir = $paths.Workshop
$rootFiles = @{}   # id -> noms des .mod à la racine du dossier de l'objet (ceux que Kenshi charge)
$deepFiles = @{}   # id -> noms des .mod en sous-dossier
$wsObjects = 0
if (Test-Path -LiteralPath $wsDir) {
    $wsRoot = (Resolve-Path -LiteralPath $wsDir).ProviderPath.TrimEnd('\')
    $index = Get-ModFileIndex -Folders @($wsRoot)
    foreach ($e in $index.Values) {
        foreach ($p in $e.Paths) {
            $parts = $p.Substring($wsRoot.Length).TrimStart('\') -split '\\'
            if ($parts.Count -lt 2 -or $parts[0] -notmatch '^\d+$') { continue }
            $id = $parts[0]
            $table = $deepFiles
            if ($parts.Count -eq 2) { $table = $rootFiles }
            if (-not $table.ContainsKey($id)) { $table[$id] = @() }
            $table[$id] += [pscustomobject]@{ Name = $e.Name; Path = $p }
        }
    }
    $wsObjects = @($rootFiles.Keys + $deepFiles.Keys | Select-Object -Unique).Count
}
else { Write-Warning "Dossier Workshop introuvable : $wsDir (aucun mod considéré comme téléchargé)" }

# --- liste actuelle du pack -------------------------------------------------

$oldRows = @()
if (Test-Path -LiteralPath $csvPath) { $oldRows = @(Import-Csv -LiteralPath $csvPath -Encoding UTF8) }
else { Write-Warning "Liste du pack introuvable, tout sera considéré comme ajouté : $csvPath" }
$oldById = @{}
foreach ($row in $oldRows) { $oldById["$($row.workshop_id)"] = $row }
$oldCfg = @()
if (Test-Path -LiteralPath $cfgPath) { $oldCfg = @(Get-ActiveModList -Path $cfgPath) }

# --- construction de la nouvelle liste --------------------------------------

$newList = New-Object System.Collections.Generic.List[object]
$unavailable = @(); $notDownloaded = @(); $excluded = @(); $ambiguous = @(); $badHeaders = @()
foreach ($child in $modChildren) {
    $id = $child.Id
    $old = $oldById[$id]
    $d = $details[$id]
    $result = [int](Get-Prop $d 'result' 0)
    $title = ''
    if ($old) { $title = "$($old.title)" }
    if ($result -eq 1) { $title = "$(Get-Prop $d 'title' $title)".Trim() }

    $file = ''; $deps = ''
    if ($old) { $file = "$($old.mod_file)"; $deps = "$($old.dependencies)" }
    if ($result -ne 1) { $unavailable += "$id  $(Get-DisplayTitle $title $file) (result=$result)" }
    $candidates = @()
    if ($rootFiles.ContainsKey($id)) { $candidates = @($rootFiles[$id]) }
    elseif ($deepFiles.ContainsKey($id)) {
        Write-Warning "$id ($(Get-DisplayTitle $title $file)) : .mod seulement en sous-dossier, Kenshi ne le chargera pas : $($deepFiles[$id][0].Path)"
        # Un objet présent mais non chargeable ne bénéficie pas du nom conservé
        # pour les objets réellement non téléchargés : retirer aussi une ancienne entrée.
        $excluded += "$id  $(Get-DisplayTitle $title $file) (seulement en sous-dossier)"
        continue
    }
    if ($candidates.Count -gt 0) {
        $pick = @($candidates | Where-Object { $_.Name -eq $file })
        if ($pick.Count -eq 0) { $pick = @($candidates | Sort-Object Name) }
        if ($candidates.Count -gt 1) { $ambiguous += "$id  $(Get-DisplayTitle $title $file) : " + (@($candidates | ForEach-Object { $_.Name }) -join ' | ') + " (retenu : $($pick[0].Name))" }
        $file = $pick[0].Name
        try {
            $h = Read-ModHeader -Path $pick[0].Path
            $deps = @($h.Dependencies | Where-Object { $coreFiles -notcontains $_ }) -join '; '
        }
        catch { $badHeaders += "$file : $($_.Exception.Message)" }
    }
    else {
        $notDownloaded += "$id  $(Get-DisplayTitle $title $file)" + $(if ($file) { " (fichier connu : $file)" } else { '' })
    }
    if (-not $file) { $excluded += "$id  $(Get-DisplayTitle $title)"; continue }

    $newList.Add([pscustomobject]@{
        position = $newList.Count + 1; workshop_id = $id; mod_file = $file; title = $title
        dependencies = $deps; url = "https://steamcommunity.com/sharedfiles/filedetails/?id=$id"
    })
}

# --- ordre de l'auteur -------------------------------------------------------

$authorExtra = @(); $authorMissing = @(); $notInAuthor = @()
if ($author) {
    $byFile = @{}
    foreach ($row in $newList) { if (-not $byFile.ContainsKey($row.mod_file)) { $byFile[$row.mod_file] = $row } }
    $fileToId = @{}
    # Ordre stable (plus petit ID d'abord) : l'ordre des clés d'une table varie d'une exécution à l'autre sous PowerShell 7
    foreach ($id in @($rootFiles.Keys | Sort-Object { [int64]$_ })) {
        foreach ($f in $rootFiles[$id]) { if (-not $fileToId.ContainsKey($f.Name)) { $fileToId[$f.Name] = [pscustomobject]@{ Id = $id; Path = $f.Path } } }
    }
    $extraIds = @($author.Files | Where-Object { -not $byFile.ContainsKey($_) -and $fileToId.ContainsKey($_) } | ForEach-Object { $fileToId[$_].Id } | Select-Object -Unique)
    if ($extraIds.Count -gt 0) {
        try {
            $form = @{ itemcount = $extraIds.Count }
            for ($j = 0; $j -lt $extraIds.Count; $j++) { $form["publishedfileids[$j]"] = $extraIds[$j] }
            foreach ($d in @(Get-Prop (Invoke-SteamApi 'GetPublishedFileDetails' $form) 'publishedfiledetails' @())) { $details["$(Get-Prop $d 'publishedfileid' '')"] = $d }
        }
        catch { Write-Warning "Titres des mods hors collection indisponibles : $($_.Exception.Message)" }
    }
    $ordered = New-Object System.Collections.Generic.List[object]
    $used = @{}
    foreach ($f in $author.Files) {
        if ($used.ContainsKey($f)) { continue }
        if ($byFile.ContainsKey($f)) { $ordered.Add($byFile[$f]); $used[$f] = $true; continue }
        if (-not $fileToId.ContainsKey($f)) { $authorMissing += $f; continue }
        $e = $fileToId[$f]
        $title = "$(Get-Prop $details[$e.Id] 'title' '')".Trim()
        if (-not $title -and $oldById.ContainsKey($e.Id)) { $title = "$($oldById[$e.Id].title)" }
        $deps = ''
        try { $deps = @((Read-ModHeader -Path $e.Path).Dependencies | Where-Object { $coreFiles -notcontains $_ }) -join '; ' }
        catch { $badHeaders += "$f : $($_.Exception.Message)" }
        $ordered.Add([pscustomobject]@{
            position = 0; workshop_id = $e.Id; mod_file = $f; title = $title
            dependencies = $deps; url = "https://steamcommunity.com/sharedfiles/filedetails/?id=$($e.Id)"
        })
        $used[$f] = $true
        $authorExtra += "$($e.Id)  $(Get-DisplayTitle $title $f)"
    }
    foreach ($row in $newList) {
        if ($used.ContainsKey($row.mod_file)) { continue }
        $ordered.Add($row); $used[$row.mod_file] = $true
        $notInAuthor += "$($row.workshop_id)  $($row.title)  [$($row.mod_file)]"
    }
    $pos = 0
    foreach ($row in $ordered) { $pos++; $row.position = $pos }
    $newList = $ordered
}

$newRows = @($newList.ToArray())
$newById = @{}
foreach ($row in $newRows) { $newById[$row.workshop_id] = $row }

# --- comparaison -------------------------------------------------------------

$added = @($newRows | Where-Object { -not $oldById.ContainsKey($_.workshop_id) } | ForEach-Object { "#$($_.position)  $($_.workshop_id)  $($_.title)  [$($_.mod_file)]" })
$removed = @($oldRows | Where-Object { -not $newById.ContainsKey("$($_.workshop_id)") } | ForEach-Object { "#$($_.position)  $($_.workshop_id)  $($_.title)  [$($_.mod_file)]" })
$common = @($newRows | Where-Object { $oldById.ContainsKey($_.workshop_id) })
$member = Get-LisMembership ([int[]]@($common | ForEach-Object { [int]$oldById[$_.workshop_id].position }))
$moved = @()
for ($k = 0; $k -lt $common.Count; $k++) {
    if ($member[$k]) { continue }
    $r = $common[$k]
    $moved += "$($r.workshop_id)  $($r.title) : #$($oldById[$r.workshop_id].position) -> #$($r.position)"
}
$changed = @()
foreach ($r in $common) {
    $o = $oldById[$r.workshop_id]
    $diffs = @()
    if ("$($o.title)" -cne $r.title) { $diffs += "titre « $($o.title) » -> « $($r.title) »" }
    if ("$($o.mod_file)" -cne $r.mod_file) { $diffs += "fichier $($o.mod_file) -> $($r.mod_file)" }
    if ("$($o.dependencies)" -cne $r.dependencies) { $diffs += "dépendances [$($o.dependencies)] -> [$($r.dependencies)]" }
    if ($diffs.Count -gt 0) { $changed += "$($r.workshop_id)  $($r.title) : " + ($diffs -join ' ; ') }
}

$newCfg = [string[]]@($newRows | ForEach-Object { $_.mod_file })
$newCsv = [string[]]@(@(($csvColumns | ForEach-Object { '"' + $_ + '"' }) -join ',') + @($newRows | ForEach-Object { ConvertTo-CsvLine $_ }))
# Comparaisons sensibles à la casse : un .mod renommé « Foo.mod » -> « foo.mod » doit être réécrit
$cfgDiffers = (Compare-Object -ReferenceObject @($oldCfg) -DifferenceObject $newCfg -SyncWindow 0 -CaseSensitive | Measure-Object).Count -gt 0
# Comparaison champ par champ (et non texte) : un simple écart de guillemets ne force pas une réécriture.
$csvDiffers = ($oldRows.Count -ne $newRows.Count)
for ($k = 0; -not $csvDiffers -and $k -lt $newRows.Count; $k++) {
    foreach ($c in $csvColumns) {
        if ("$($oldRows[$k].$c)" -cne "$($newRows[$k].$c)") { $csvDiffers = $true; break }
    }
}

# --- rapport -----------------------------------------------------------------

Write-Host "Collection $CollectionId : $($children.Count) éléments, dont $($modChildren.Count) mods et $($otherChildren.Count) non-mods (sous-collections, ignorés)"
Write-Host "Workshop : $wsDir ($wsObjects objets avec un .mod)"
Write-Host "Pack actuel : $csvPath ($($oldRows.Count) mods) ; mods.cfg : $($oldCfg.Count) lignes"
if ($author) {
    Write-Host "Ordre de chargement : fil de l'auteur $($author.Uri)$(if ($author.Updated) { " (mis à jour le $($author.Updated))" }), $($author.Files.Count) lignes .mod"
}
else { Write-Host 'Ordre de chargement : collection (-LoadOrderTopic vide)' }
Write-Host "Nouvelle liste : $($newRows.Count) mods"
if ($author) {
    Show 'Ajoutés par l''auteur hors collection' $authorExtra
    Show 'Dans le fil mais non installés (ignorés : mods hors Steam ou non abonnés)' $authorMissing
    Show 'Dans la collection mais absents du fil (placés à la fin)' $notInAuthor
}
Show 'Ajoutés' $added
Show 'Retirés' $removed
Show 'Déplacés (ordre relatif changé)' $moved
Show 'Modifiés (titre, fichier ou dépendances)' $changed
Show 'Non téléchargés localement' $notDownloaded
Show 'Indisponibles sur le Workshop' $unavailable
Show 'Exclus de la liste (aucun fichier .mod connu ou seulement en sous-dossier)' $excluded
Show 'Plusieurs .mod dans le dossier Workshop' $ambiguous
Show 'En-têtes illisibles (dépendances conservées)' $badHeaders
Show 'Éléments non-mods de la collection' @($otherChildren | ForEach-Object { "$($_.Id)  $(Get-Prop $details[$_.Id] 'title' '')  (filetype=$($_.FileType))" })
Write-Host ("mods.cfg : {0} ; pack-modlist.csv : {1}" -f $(if ($cfgDiffers) { 'à mettre à jour' } else { 'à jour' }), $(if ($csvDiffers) { 'à mettre à jour' } else { 'à jour' }))

if (-not $cfgDiffers -and -not $csvDiffers) {
    Write-Host 'OK : le pack est à jour, rien à écrire.'
    exit 0
}
if (-not $Apply) {
    Write-Host 'Rapport seulement : rien n''a été écrit (relancer avec -Apply pour mettre à jour modlist\).'
    exit 2
}

# --- écriture (dépôt uniquement) --------------------------------------------

try {
    # Sauvegarde du CSV avant toute écriture : si elle échoue, mods.cfg n'est pas modifié non plus
    if (Test-Path -LiteralPath $csvPath) {
        $bak = Backup-File -Path $csvPath   # lève une erreur : pas d'écriture sans sauvegarde
        Write-Host "Ancien pack-modlist.csv sauvegardé : $bak"
    }
    $w = Write-ModList -Path $cfgPath -Lines $newCfg -ErrorAction Stop
    if ($w.Backup) { Write-Host "Ancien mods.cfg sauvegardé : $($w.Backup)" }
    Write-Host "mods.cfg écrit : $($w.Count) mods."
    [IO.File]::WriteAllLines($csvPath, $newCsv, (New-Object Text.UTF8Encoding $true))
    Write-Host "pack-modlist.csv écrit : $($newRows.Count) mods."
}
catch { Write-Error "Mise à jour interrompue : $($_.Exception.Message)"; exit 1 }
exit 0
