<#
.SYNOPSIS
    Fonctions communes aux outils Kenshi du dépôt (chemins, en-têtes .mod, liste de
    mods, journaux, plantages).

.DESCRIPTION
    Module partagé par tous les scripts de tools\. Compatible Windows PowerShell 5.1
    et PowerShell 7. Aucune fonction ne lance, n'arrête ni ne touche Steam ou Kenshi :
    seules Write-ModList, Backup-File et Set-KenshiMonitorLock écrivent sur le disque,
    et uniquement au chemin qu'on leur donne.

    Fonctions exportées :
      Get-KenshiPaths          détecte Steam, la bibliothèque et les dossiers du jeu
      Read-ModHeader           lit l'en-tête d'un fichier .mod (auteur, dépendances...)
      Get-ModFileIndex         indexe les fichiers .mod présents sur le disque
      Get-ActiveModList        lit un mods.cfg (à envelopper dans @() côté appelant)
      Test-KenshiModList       vérifie une liste de mods (fichiers, dépendances, ordre)
      Backup-File              copie un fichier en .<horodatage>.bak (nom unique)
      Write-ModList            écrit un mods.cfg (UTF-8 sans BOM) avec sauvegarde
      Get-KenshiLogSummary     résume kenshi_info.log sous forme de données
      Format-KenshiLogSummary  rend ce résumé en texte français
      Get-KenshiCrashEvents    lit les événements Windows 1000 de kenshi_x64.exe
      Get-KenshiHangEvents     lit les événements Windows 1002 (gel) de kenshi_x64.exe
      Get-KenshiSessions       découpe save.log en sessions de jeu
      Open-KenshiLogReader     lit un journal que le jeu tient encore ouvert en écriture
      Read-KenshiMonitorLock   lit monitor.lock et vérifie que son moniteur tourne encore
      Set-KenshiMonitorLock    écrit monitor.lock (PID, création du processus, phase)

.EXAMPLE
    Import-Module .\tools\KenshiTools.psm1
    (Get-KenshiPaths).Game
#>

Set-StrictMode -Version 2.0

$script:KenshiAppId = '233860'
$script:CoreFiles = @('gamedata.base', 'Newwworld.mod', 'Dialogue.mod', 'rebirth.mod')

# --- helpers privés ---------------------------------------------------------

# -Unescape : valeurs de libraryfolders.vdf ("C:\\Program Files (x86)\\Steam"). Sans lui,
# un chemin UNC (\\nas\jeux) est conservé tel quel.
function ConvertTo-WindowsPath([string]$Path, [switch]$Unescape) {
    $p = $Path -replace '/', '\'
    if ($Unescape) { $p = $p -replace '\\\\', '\' }
    $p = $p.TrimEnd('\')
    if ($p -match '^[a-z]:') { $p = $p.Substring(0, 1).ToUpper() + $p.Substring(1) }
    $p
}

# Chemin absolu (résolu sur $PWD, pas sur le répertoire courant du processus) avec la
# casse réelle du disque pour les segments qui existent (le registre donne
# « c:/program files (x86)/steam »).
function Resolve-FullPath([string]$Path) {
    $full = $Path
    try { $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) } catch { }
    if ($full -like '\\*') { return $full.TrimEnd('\') }   # UNC : pas de lecture réseau pour la casse
    try {
        $root = [IO.Path]::GetPathRoot($full)
        if (-not $root) { return $full.TrimEnd('\') }
        $rest = $full.Substring($root.Length).TrimEnd('\')
        $cur = $root
        if ($cur -match '^[a-z]:') { $cur = $cur.Substring(0, 1).ToUpper() + $cur.Substring(1) }
        $segments = @(); if ($rest) { $segments = @($rest -split '\\') }
        $exact = $true
        foreach ($seg in $segments) {
            if ($exact) {
                $hits = @([IO.Directory]::GetFileSystemEntries($cur, $seg))
                if ($hits.Count -eq 1) { $cur = $hits[0]; continue }
                $exact = $false
            }
            $cur = Join-Path $cur $seg
        }
        $cur.TrimEnd('\')
    }
    catch { $full.TrimEnd('\') }
}

function New-StringSet {
    New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
}

function Read-Int32Checked([IO.BinaryReader]$Reader, [string]$What) {
    $fs = $Reader.BaseStream
    if ($fs.Position + 4 -gt $fs.Length) { throw "en-tête tronqué ($What attendu à l'octet $($fs.Position), fichier de $($fs.Length) octets)" }
    $Reader.ReadInt32()
}

function Read-LengthPrefixedString([IO.BinaryReader]$Reader, [string]$What) {
    $n = Read-Int32Checked $Reader "longueur de $What"
    $fs = $Reader.BaseStream
    if ($n -lt 0) { throw "longueur négative pour $What ($n)" }
    if ($fs.Position + $n -gt $fs.Length) { throw "en-tête tronqué ($What annonce $n octets, il en reste $($fs.Length - $fs.Position))" }
    if ($n -eq 0) { return '' }
    [Text.Encoding]::UTF8.GetString($Reader.ReadBytes($n))
}

function Split-ModNameList([string]$Text) {
    @($Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# Lecteur UTF-8 sur un fichier que quelqu'un d'autre peut tenir ouvert en écriture
# (kenshi.log et kenshi_info.log pendant la session). À disposer par l'appelant.
function Open-SharedTextReader([string]$Path) {
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
}

# --- chemins ----------------------------------------------------------------

function Get-KenshiPaths {
    <#
    .SYNOPSIS
        Détecte les dossiers de Steam et de Kenshi.
    .DESCRIPTION
        Lit SteamPath dans HKCU:\Software\Valve\Steam (sinon C:\Program Files (x86)\Steam),
        parcourt libraryfolders.vdf pour trouver la bibliothèque qui contient
        appmanifest_233860.acf, et en déduit le dossier du jeu et celui du Workshop.
        -Game et -Workshop remplacent la détection.
    .PARAMETER Game
        Dossier du jeu à utiliser tel quel (par ex. un faux dossier de test).
    .PARAMETER Workshop
        Dossier Workshop (steamapps\workshop\content\233860) à utiliser tel quel.
    .EXAMPLE
        Get-KenshiPaths
    .EXAMPLE
        (Get-KenshiPaths -Game "$env:TEMP\faux-kenshi").ModsCfg
    #>
    [CmdletBinding()]
    param(
        [string]$Game,
        [string]$Workshop
    )
    $steam = $null
    try { $steam = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath } catch { }
    if (-not $steam) { $steam = 'C:\Program Files (x86)\Steam' }
    $steam = Resolve-FullPath (ConvertTo-WindowsPath $steam)

    $libraries = @($steam)
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        $raw = Get-Content -LiteralPath $vdf -Raw -Encoding UTF8
        foreach ($m in [regex]::Matches($raw, '"path"\s+"([^"]+)"')) {
            $p = Resolve-FullPath (ConvertTo-WindowsPath $m.Groups[1].Value -Unescape)
            if ($libraries -notcontains $p) { $libraries += $p }
        }
    }
    $library = $null
    foreach ($lib in $libraries) {
        if (Test-Path -LiteralPath (Join-Path $lib "steamapps\appmanifest_$script:KenshiAppId.acf")) { $library = $lib; break }
    }
    if (-not $library) { $library = $libraries[0] }

    $installDir = 'Kenshi'
    $manifest = Join-Path $library "steamapps\appmanifest_$script:KenshiAppId.acf"
    if (Test-Path -LiteralPath $manifest) {
        $txt = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8
        if ($txt -match '"installdir"\s+"([^"]+)"') { $installDir = $Matches[1] }
    }

    $gameDir = Join-Path (Join-Path $library 'steamapps\common') $installDir
    if ($Game) { $gameDir = Resolve-FullPath (ConvertTo-WindowsPath $Game) }
    $workshopDir = Join-Path $library "steamapps\workshop\content\$script:KenshiAppId"
    if ($Workshop) { $workshopDir = Resolve-FullPath (ConvertTo-WindowsPath $Workshop) }

    [pscustomobject]@{
        SteamPath      = $steam
        Library        = $library
        Game           = $gameDir
        Workshop       = $workshopDir
        Detected       = (-not $Game)   # $false si -Game a remplacé l'installation Steam
        AppWorkshopAcf = Join-Path $library "steamapps\workshop\appworkshop_$script:KenshiAppId.acf"
        ModsCfg        = Join-Path $gameDir 'data\mods.cfg'
        SaveLog        = Join-Path $gameDir 'save.log'
        InfoLog        = Join-Path $gameDir 'kenshi_info.log'
        SavesDir       = Join-Path $env:LOCALAPPDATA 'kenshi\save'
        CrashDumps     = Join-Path $env:LOCALAPPDATA 'CrashDumps'
        WerReportDirs  = @(
            'C:\ProgramData\Microsoft\Windows\WER\ReportArchive',
            'C:\ProgramData\Microsoft\Windows\WER\ReportQueue',
            (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportArchive'),
            (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportQueue')
        )
    }
}

# --- fichiers .mod ----------------------------------------------------------

function Read-ModHeader {
    <#
    .SYNOPSIS
        Lit l'en-tête d'un fichier .mod de Kenshi.
    .DESCRIPTION
        Format : int32 type (16 ou 17) ; si 17, int32 taille d'en-tête ; int32 version ;
        puis 4 chaînes UTF-8 précédées de leur longueur (int32) : auteur, description,
        dépendances (fichiers .mod séparés par des virgules) et références.
        Chaque lecture est bornée par la taille du fichier : un en-tête tronqué ou
        aberrant produit une erreur claire au lieu d'une exception .NET.
    .PARAMETER Path
        Chemin du fichier .mod.
    .EXAMPLE
        (Read-ModHeader 'C:\...\233860\1358096888\Reactive World.mod').Dependencies
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0)][string]$Path)

    $full = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    $fs = $null
    try {
        $fs = [IO.File]::Open($full, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $br = New-Object IO.BinaryReader($fs)
        $type = Read-Int32Checked $br 'type'
        if ($type -ne 16 -and $type -ne 17) { throw "type d'en-tête inconnu ($type, attendu 16 ou 17)" }
        $headerSize = $null
        if ($type -eq 17) { $headerSize = Read-Int32Checked $br "taille d'en-tête" }
        $version = Read-Int32Checked $br 'version'
        $author = Read-LengthPrefixedString $br 'auteur'
        $description = Read-LengthPrefixedString $br 'description'
        $dependencies = Read-LengthPrefixedString $br 'dépendances'
        $references = Read-LengthPrefixedString $br 'références'
    }
    catch {
        throw "En-tête .mod illisible ($full) : $($_.Exception.Message)"
    }
    finally {
        if ($fs) { $fs.Dispose() }
    }
    [pscustomobject]@{
        Path         = $full
        Name         = [IO.Path]::GetFileName($full)
        Type         = $type
        HeaderSize   = $headerSize
        Version      = $version
        Author       = $author
        Description  = $description
        Dependencies = [string[]](Split-ModNameList $dependencies)
        References   = [string[]](Split-ModNameList $references)
    }
}

function Get-ModFileIndex {
    <#
    .SYNOPSIS
        Indexe les fichiers .mod présents dans des dossiers (jeu\mods, Workshop).
    .DESCRIPTION
        Retourne une table nom de fichier -> objet { Name, Path, WorkshopId, Paths,
        WorkshopIds, IsDuplicate, NestedPaths, IsNestedOnly }. Paths liste tous les
        emplacements, ce qui rend visibles les doublons (même nom dans deux objets
        Workshop). WorkshopId est renseigné quand le fichier se trouve dans un dossier
        d'objet Workshop (dossier numérique directement sous le dossier donné). Un .mod
        en sous-dossier d'un objet Workshop (<id>\<sous-dossier>\x.mod) n'est pas chargé
        par Kenshi : il est listé dans NestedPaths, et IsNestedOnly vaut $true quand le
        nom n'existe nulle part ailleurs. Path, IsDuplicate et WorkshopIds ne tiennent
        compte que des emplacements chargeables.
    .PARAMETER Folders
        Dossiers à parcourir récursivement ; ceux qui n'existent pas sont ignorés.
    .EXAMPLE
        $index = Get-ModFileIndex -Folders "$game\mods", $workshop
        $index['OroborosArmor.mod'].Paths
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0)][AllowEmptyCollection()][string[]]$Folders)

    $index = @{}
    foreach ($folder in $Folders) {
        if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { continue }
        $root = (Resolve-Path -LiteralPath $folder).ProviderPath.TrimEnd('\')
        $files = Get-ChildItem -LiteralPath $root -Recurse -File -Filter *.mod -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -eq '.mod' }   # -Filter *.mod accepte aussi .model, .modx...
        foreach ($f in $files) {
            $rel = $f.FullName.Substring($root.Length).TrimStart('\')
            $parts = $rel -split '\\'
            $wsId = $null
            if ($parts.Count -gt 1 -and $parts[0] -match '^\d+$') { $wsId = $parts[0] }
            $nested = [bool]($wsId -and $parts.Count -gt 2)
            if (-not $index.ContainsKey($f.Name)) {
                $index[$f.Name] = [pscustomobject]@{
                    Name = $f.Name; Path = $null; WorkshopId = $null
                    Paths = @(); WorkshopIds = @(); IsDuplicate = $false
                    NestedPaths = @(); IsNestedOnly = $true
                }
            }
            $e = $index[$f.Name]
            $e.Paths = @($e.Paths) + $f.FullName
            if ($nested) { $e.NestedPaths = @($e.NestedPaths) + $f.FullName; continue }
            if (-not $e.Path) { $e.Path = $f.FullName; $e.WorkshopId = $wsId }
            if ($wsId) { $e.WorkshopIds = @($e.WorkshopIds) + $wsId }
            $e.IsNestedOnly = $false
            $e.IsDuplicate = (($e.Paths.Count - $e.NestedPaths.Count) -gt 1)
        }
    }
    $index
}

function Get-ActiveModList {
    <#
    .SYNOPSIS
        Lit un mods.cfg : une entrée par ligne, lignes vides ignorées.
    .DESCRIPTION
        Comme toute commande PowerShell, le résultat est déroulé par le pipeline : un
        fichier d'une ligne donne une chaîne et un fichier vide ne donne rien. Toujours
        envelopper l'appel dans @(...) pour obtenir un tableau (0, 1 ou n éléments) ;
        tous les scripts du dépôt le font. (Renvoyer un tableau non déroulé, avec
        « , » ou Write-Output -NoEnumerate, casserait justement @(...), qui
        l'imbriquerait dans un tableau d'un élément.)
    .PARAMETER Path
        Chemin du mods.cfg.
    .EXAMPLE
        @(Get-ActiveModList (Get-KenshiPaths).ModsCfg).Count
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Liste de mods introuvable : $Path" }
    [string[]]@(Get-Content -LiteralPath $Path -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-KenshiModList {
    <#
    .SYNOPSIS
        Vérifie une liste de mods : fichiers, en-têtes, dépendances, ordre, doublons, écart au pack.
    .DESCRIPTION
        Pour chaque mod de ModsCfg : le fichier .mod doit exister (jeu\mods ou Workshop),
        son en-tête doit être lisible, chaque dépendance doit être présente, activée et
        chargée avant lui. Les fichiers de base du jeu (gamedata.base, Newwworld.mod,
        Dialogue.mod, rebirth.mod et tout .mod/.base de jeu\data) comptent comme
        toujours chargés. Un .mod présent seulement en sous-dossier d'un objet Workshop
        (que Kenshi ne charge pas) compte comme introuvable et figure dans NestedFiles.
        DuplicateFiles liste les mods actifs dont le nom existe à plusieurs endroits.
        Avec -PackCfg, NotInPack et PackModsNotActive donnent l'écart entre la liste
        active et celle du pack. Toute erreur interne est levée (jamais un résultat
        IsClean partiel).
    .PARAMETER ModsCfg
        Liste à vérifier.
    .PARAMETER PackCfg
        Liste de référence du pack (optionnelle).
    .PARAMETER Game
        Dossier du jeu (détection automatique sinon).
    .PARAMETER Workshop
        Dossier Workshop (détection automatique sinon).
    .PARAMETER ModIndex
        Index déjà construit par Get-ModFileIndex sur jeu\mods et le Workshop de -Game et
        -Workshop, utilisé tel quel au lieu de parcourir de nouveau le Workshop.
    .EXAMPLE
        $r = Test-KenshiModList -ModsCfg "$game\data\mods.cfg" -PackCfg .\modlist\mods.cfg
        $r.Counts
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ModsCfg,
        [string]$PackCfg,
        [string]$Game,
        [string]$Workshop,
        [hashtable]$ModIndex
    )
    $ErrorActionPreference = 'Stop'   # une erreur interne ne doit jamais donner IsClean = $true
    $paths = Get-KenshiPaths -Game $Game -Workshop $Workshop
    $active = @(Get-ActiveModList -Path $ModsCfg)

    $core = New-StringSet
    foreach ($c in $script:CoreFiles) { [void]$core.Add($c) }
    $dataDir = Join-Path $paths.Game 'data'
    if (Test-Path -LiteralPath $dataDir) {
        Get-ChildItem -LiteralPath $dataDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -eq '.mod' -or $_.Extension -eq '.base' } |
            ForEach-Object { [void]$core.Add($_.Name) }
    }

    $index = $ModIndex
    if ($null -eq $index) { $index = Get-ModFileIndex -Folders @((Join-Path $paths.Game 'mods'), $paths.Workshop) }

    $pos = @{}
    for ($i = 0; $i -lt $active.Count; $i++) { if (-not $pos.ContainsKey($active[$i])) { $pos[$active[$i]] = $i } }

    $missingFiles = @(); $nestedFiles = @(); $unreadable = @(); $absentDeps = @(); $inactiveDeps = @(); $lateDeps = @(); $duplicates = @()
    for ($i = 0; $i -lt $active.Count; $i++) {
        $m = $active[$i]
        if ($core.Contains($m)) { continue }
        if (-not $index.ContainsKey($m)) { $missingFiles += $m; continue }
        $entry = $index[$m]
        if ($entry.IsNestedOnly) {
            $missingFiles += $m
            $nestedFiles += [pscustomobject]@{ Mod = $m; Position = $i + 1; Path = $entry.NestedPaths[0] }
            continue
        }
        if ($entry.IsDuplicate) {
            $duplicates += [pscustomobject]@{ Mod = $m; Position = $i + 1; Paths = $entry.Paths; WorkshopIds = $entry.WorkshopIds }
        }
        $header = $null
        try { $header = Read-ModHeader -Path $entry.Path }
        catch { $unreadable += [pscustomobject]@{ Mod = $m; Path = $entry.Path; Error = $_.Exception.Message }; continue }
        foreach ($d in $header.Dependencies) {
            if ($core.Contains($d)) { continue }
            if ($pos.ContainsKey($d)) {
                if ($pos[$d] -gt $i) {
                    $lateDeps += [pscustomobject]@{ Mod = $m; Position = $i + 1; Dependency = $d; DependencyPosition = $pos[$d] + 1 }
                }
            }
            elseif ($index.ContainsKey($d) -and -not $index[$d].IsNestedOnly) {
                $inactiveDeps += [pscustomobject]@{ Mod = $m; Dependency = $d; Path = $index[$d].Path; WorkshopId = $index[$d].WorkshopId }
            }
            else {
                $absentDeps += [pscustomobject]@{ Mod = $m; Dependency = $d }
            }
        }
    }

    $notInPack = @(); $packNotActive = @(); $packCount = $null
    if ($PackCfg) {
        $pack = @(Get-ActiveModList -Path $PackCfg)
        $packCount = $pack.Count
        $packSet = New-StringSet; foreach ($p in $pack) { [void]$packSet.Add($p) }
        $activeSet = New-StringSet; foreach ($a in $active) { [void]$activeSet.Add($a) }
        $notInPack = @($active | Where-Object { -not $packSet.Contains($_) })
        $packNotActive = @($pack | Where-Object { -not $activeSet.Contains($_) })
    }

    $counts = [ordered]@{
        Active                = $active.Count
        FilesOnDisk           = $index.Count
        Pack                  = $packCount
        MissingFiles          = $missingFiles.Count
        NestedFiles           = $nestedFiles.Count   # inclus dans MissingFiles
        Unreadable            = $unreadable.Count
        AbsentDependencies    = $absentDeps.Count
        InactiveDependencies  = $inactiveDeps.Count
        LateDependencies      = $lateDeps.Count
        DuplicateFiles        = $duplicates.Count
        NotInPack             = $notInPack.Count
        PackModsNotActive     = $packNotActive.Count
    }
    $problems = $missingFiles.Count + $unreadable.Count + $absentDeps.Count + $inactiveDeps.Count +
        $lateDeps.Count + $duplicates.Count + $notInPack.Count + $packNotActive.Count
    $counts.Problems = $problems

    [pscustomobject]@{
        ModsCfg              = $ModsCfg
        PackCfg              = $PackCfg
        Game                 = $paths.Game
        Workshop             = $paths.Workshop
        MissingFiles         = [string[]]$missingFiles
        NestedFiles          = $nestedFiles
        Unreadable           = $unreadable
        AbsentDependencies   = $absentDeps
        InactiveDependencies = $inactiveDeps
        LateDependencies     = $lateDeps
        DuplicateFiles       = $duplicates
        NotInPack            = [string[]]$notInPack
        PackModsNotActive    = [string[]]$packNotActive
        Counts               = $counts
        IsClean              = ($problems -eq 0)
    }
}

function Backup-File {
    <#
    .SYNOPSIS
        Copie un fichier en <fichier>.<horodatage>.bak et retourne le chemin de la copie.
    .DESCRIPTION
        Le nom est unique : si deux copies tombent dans la même seconde, un compteur est
        ajouté (-2, -3...) au lieu d'écraser la première. Lève une erreur si la copie
        échoue ou n'existe pas après coup.
    .PARAMETER Path
        Fichier à copier (chemin relatif résolu sur $PWD).
    .EXAMPLE
        $bak = Backup-File -Path .\modlist\pack-modlist.csv
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0)][string]$Path)
    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = '{0}.{1}.bak' -f $Path, $stamp
    $n = 1
    while (Test-Path -LiteralPath $backup) { $n++; $backup = '{0}.{1}-{2}.bak' -f $Path, $stamp, $n }
    try { Copy-Item -LiteralPath $Path -Destination $backup -ErrorAction Stop }
    catch { throw "Sauvegarde impossible de $Path vers $backup : $($_.Exception.Message)" }
    if (-not (Test-Path -LiteralPath $backup)) { throw "Sauvegarde introuvable après copie : $backup" }
    $backup
}

function Write-ModList {
    <#
    .SYNOPSIS
        Écrit un mods.cfg (UTF-8 sans BOM, une entrée par ligne) après sauvegarde de l'ancien.
    .DESCRIPTION
        Si le fichier existe, il est d'abord copié en <fichier>.<horodatage>.bak
        (Backup-File) ; si cette copie échoue, rien n'est écrit. L'écriture est ensuite
        relue et comparée : toute différence, ou toute erreur (fichier en lecture seule,
        dossier inaccessible), lève une erreur au lieu de retourner un résultat.
        Le chemin relatif est résolu sur $PWD. Supporte -WhatIf : rien n'est alors ni
        copié ni écrit.
    .PARAMETER Path
        Fichier à écrire.
    .PARAMETER Lines
        Entrées à écrire (les vides sont ignorées).
    .EXAMPLE
        Write-ModList -Path "$game\data\mods.cfg" -Lines (Get-ActiveModList .\modlist\mods.cfg) -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines
    )
    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $clean = [string[]]@($Lines | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    $backup = $null
    $existed = Test-Path -LiteralPath $Path
    if ($existed -and $PSCmdlet.ShouldProcess($Path, 'Sauvegarder en .bak')) {
        $backup = Backup-File -Path $Path   # lève une erreur : on n'écrit pas sans sauvegarde
    }
    if ($PSCmdlet.ShouldProcess($Path, "Écrire $($clean.Count) mods")) {
        $dir = Split-Path -Parent $Path
        try {
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
            [IO.File]::WriteAllLines($Path, $clean, (New-Object Text.UTF8Encoding $false))
        }
        catch { throw "Écriture impossible de $Path : $($_.Exception.Message) (fichier en lecture seule ?)" }
        $check = [string[]]@([IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8) | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
        if (($check -join "`n") -ne ($clean -join "`n")) { throw "Relecture de $Path différente de ce qui devait être écrit ($($check.Count) lignes au lieu de $($clean.Count))." }
    }
    [pscustomobject]@{ Path = $Path; Backup = $backup; Count = $clean.Count; Existed = $existed }
}

# --- journaux ---------------------------------------------------------------

function Get-KenshiLogSummary {
    <#
    .SYNOPSIS
        Résume kenshi_info.log : mods chargés, erreurs, avertissements, messages groupés.
    .DESCRIPTION
        Les messages sont regroupés après remplacement des nombres par '#'. Les
        avertissements « Part map contains invalid colour » (cosmétiques) sont
        comptés à part. « Item X modified by <Mod> does not exist » est attribué au
        mod qui modifie un objet absent. Avec -PackCfg, ExtraMods liste les mods
        chargés qui ne sont pas dans le pack et PackModsNotLoaded l'inverse ; si le
        fichier n'existe pas, un avertissement est émis et PackCfg vaut $null dans
        le résultat (PackCount aussi), pour ne pas afficher une comparaison vide.
    .PARAMETER InfoLog
        Chemin de kenshi_info.log (ou d'une copie).
    .PARAMETER PackCfg
        Liste de référence du pack (optionnelle).
    .EXAMPLE
        Get-KenshiLogSummary -InfoLog .\logs\sessions\X\kenshi_info.log -PackCfg .\modlist\mods.cfg | Format-KenshiLogSummary
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InfoLog,
        [string]$PackCfg
    )
    if (-not (Test-Path -LiteralPath $InfoLog)) { throw "Journal introuvable : $InfoLog" }
    $loaded = New-Object 'System.Collections.Generic.List[string]'
    $errorCount = 0; $warningCount = 0; $partMap = 0
    $messages = @{}; $missingItems = @{}
    $full = (Resolve-Path -LiteralPath $InfoLog).ProviderPath
    # Lecture en flux avec partage lecture/écriture : le jeu (ou WER) garde le journal ouvert
    # en écriture pendant la session, ce que [IO.File]::ReadLines (partage lecture seule) refuse.
    $reader = Open-SharedTextReader $full
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if ($line -match '\[Mods\] Loaded mod: (.+)$') { $loaded.Add($Matches[1].Trim() + '.mod'); continue }
            if ($line -match '\[(error|warning)\]: (.*)$') {
                $level = $Matches[1]; $text = $Matches[2]
                if ($level -eq 'error') { $errorCount++ } else { $warningCount++ }
                if ($text -match '^Part map contains invalid colour') { $partMap++; continue }
                $key = $level + "`t" + ($text -replace '\d+', '#')
                if ($key.Length -gt 220) { $key = $key.Substring(0, 220) }
                $messages[$key] = 1 + [int]$messages[$key]
                if ($text -match 'modified by (.+?) does not exist') { $missingItems[$Matches[1]] = 1 + [int]$missingItems[$Matches[1]] }
            }
        }
    }
    finally { $reader.Dispose() }

    $extra = @(); $packNotLoaded = @(); $packCount = $null; $packUsed = $null
    if ($PackCfg -and -not (Test-Path -LiteralPath $PackCfg)) { Write-Warning "Liste du pack introuvable, comparaison ignorée : $PackCfg" }
    elseif ($PackCfg) {
        $packUsed = $PackCfg
        $pack = @(Get-ActiveModList -Path $PackCfg)
        $packCount = $pack.Count
        $packSet = New-StringSet; foreach ($p in $pack) { [void]$packSet.Add($p) }
        $loadedSet = New-StringSet; foreach ($l in $loaded) { [void]$loadedSet.Add($l) }
        $extra = @($loaded | Where-Object { -not $packSet.Contains($_) })
        $packNotLoaded = @($pack | Where-Object { -not $loadedSet.Contains($_) })
    }

    $msgList = @($messages.GetEnumerator() | ForEach-Object {
            $parts = $_.Key -split "`t", 2
            [pscustomobject]@{ Count = $_.Value; Level = $parts[0]; Message = $parts[1] }
        } | Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Message'; Descending = $false })
    $modList = @($missingItems.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Count = $_.Value; Mod = $_.Key } } |
            Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Mod'; Descending = $false })

    [pscustomobject]@{
        InfoLog                   = $full
        PackCfg                   = $packUsed
        PackCount                 = $packCount
        LoadedMods                = [string[]]$loaded.ToArray()
        LoadedCount               = $loaded.Count
        ExtraMods                 = [string[]]$extra
        PackModsNotLoaded         = [string[]]$packNotLoaded
        ErrorCount                = $errorCount
        WarningCount              = $warningCount
        PartMapCount              = $partMap
        Messages                  = $msgList
        ModsModifyingMissingItems = $modList
    }
}

function Format-KenshiLogSummary {
    <#
    .SYNOPSIS
        Rend en texte français le résumé produit par Get-KenshiLogSummary.
    .PARAMETER Summary
        Objet retourné par Get-KenshiLogSummary (accepté par le pipeline).
    .PARAMETER MaxExtras
        Nombre maximal de mods hors pack listés (60 par défaut).
    .PARAMETER MaxMessages
        Nombre maximal de messages listés (80 par défaut).
    .PARAMETER MaxMods
        Nombre maximal de mods « objets inexistants » listés (40 par défaut).
    .EXAMPLE
        Get-KenshiLogSummary -InfoLog $log | Format-KenshiLogSummary | Set-Content errors-summary.txt -Encoding UTF8
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]$Summary,
        [int]$MaxExtras = 60,
        [int]$MaxMessages = 80,
        [int]$MaxMods = 40
    )
    process {
        $out = New-Object 'System.Collections.Generic.List[string]'
        $out.Add("Journal : $($Summary.InfoLog)")
        $out.Add("Mods chargés : $($Summary.LoadedCount)")
        if ($null -ne $Summary.PackCount) {
            $out.Add("Mods chargés hors liste du dépôt : $($Summary.ExtraMods.Count)")
            foreach ($e in @($Summary.ExtraMods | Select-Object -First $MaxExtras)) { $out.Add("  $e") }
            if ($Summary.ExtraMods.Count -gt $MaxExtras) { $out.Add("  ... et $($Summary.ExtraMods.Count - $MaxExtras) autres") }
            $out.Add("Mods du pack non chargés : $($Summary.PackModsNotLoaded.Count)")
            foreach ($e in @($Summary.PackModsNotLoaded | Select-Object -First $MaxExtras)) { $out.Add("  $e") }
            if ($Summary.PackModsNotLoaded.Count -gt $MaxExtras) { $out.Add("  ... et $($Summary.PackModsNotLoaded.Count - $MaxExtras) autres") }
        }
        $out.Add("Erreurs : $($Summary.ErrorCount) ; avertissements : $($Summary.WarningCount) (dont $($Summary.PartMapCount) 'Part map', cosmétiques)")
        $out.Add('')
        $out.Add('== Messages hors Part map, par fréquence (nombres remplacés par #) ==')
        foreach ($m in @($Summary.Messages | Select-Object -First $MaxMessages)) {
            $out.Add(('{0,7}  [{1}] {2}' -f $m.Count, $m.Level, $m.Message))
        }
        $out.Add('')
        $out.Add('== Mods qui modifient des objets inexistants ==')
        foreach ($m in @($Summary.ModsModifyingMissingItems | Select-Object -First $MaxMods)) {
            $out.Add(('{0,7}  {1}' -f $m.Count, $m.Mod))
        }
        # errors-summary.txt est publié : le dossier du profil (nom d'utilisateur) est masqué
        $profileRx = [regex]::Escape($env:USERPROFILE)
        [string[]]@($out.ToArray() | ForEach-Object { [regex]::Replace($_, $profileRx, '%USERPROFILE%', 'IgnoreCase') })
    }
}

# --- plantages et sessions --------------------------------------------------

function Get-KenshiCrashEvents {
    <#
    .SYNOPSIS
        Lit les événements Windows « Application Error » (ID 1000) de kenshi_x64.exe.
    .DESCRIPTION
        Les champs sont pris dans les propriétés de l'événement (indépendantes de la
        langue) : application, module fautif, code d'exception, décalage. En secours,
        les motifs 0x... du texte sont utilisés. Résultat trié du plus ancien au plus récent.
    .PARAMETER Since
        Ne retourne que les événements postérieurs à cette date.
    .PARAMETER ProcessName
        Nom de l'exécutable à filtrer (kenshi_x64 par défaut).
    .EXAMPLE
        Get-KenshiCrashEvents -Since (Get-Date).AddDays(-1) | Format-Table Time, Module, ExceptionCode, FaultOffset
    #>
    [CmdletBinding()]
    param(
        [datetime]$Since,
        [string]$ProcessName = 'kenshi_x64'
    )
    $filter = @{ LogName = 'Application'; Id = 1000 }
    if ($PSBoundParameters.ContainsKey('Since')) { $filter.StartTime = $Since }
    $events = @(Get-WinEvent -FilterHashtable $filter -ErrorAction SilentlyContinue)
    $result = @()
    foreach ($e in $events) {
        $props = @($e.Properties | ForEach-Object { "$($_.Value)" })
        $msg = "$($e.Message)"
        $app = ''
        if ($props.Count -gt 0) { $app = $props[0] }
        if ($app -notmatch [regex]::Escape($ProcessName) -and $msg -notmatch [regex]::Escape($ProcessName)) { continue }

        # Disposition du modèle 1000 : 0 app, 1 version, 2 horodatage, 3 module, 4 version,
        # 5 horodatage, 6 code d'exception, 7 décalage, 8 PID, 9 heure de début, 10 chemin
        # app, 11 chemin module, 12 ID rapport. Les jetons 0x... du texte suivent le même ordre.
        $hex = @([regex]::Matches($msg, '0x[0-9A-Fa-f]+') | ForEach-Object { $_.Value })
        $pick = {
            param($i, $hexIndex)
            if ($props.Count -gt $i -and $props[$i]) { return $props[$i] }
            if ($hexIndex -ge 0 -and $hex.Count -gt $hexIndex) { return $hex[$hexIndex] }
            $null
        }
        $module = & $pick 3 -1
        if (-not $module -and $msg -match '(?m)^[^\r\n:]*module[^\r\n:]*:\s*([^,\r\n]+)') { $module = $Matches[1].Trim() }
        $code = & $pick 6 2
        $offset = & $pick 7 3
        $pid0 = & $pick 8 4
        $normHex = {
            param($v)
            if (-not $v) { return $null }
            $v = "$v" -replace '^0x', ''
            $t = $v.TrimStart('0'); if (-not $t) { $t = '0' }
            '0x' + $t.ToLower()
        }
        $processId = $null
        if ($pid0) {
            if ($pid0 -match '^0x') { $processId = [Convert]::ToInt64($pid0.Substring(2), 16) }
            elseif ($pid0 -match '^\d+$') { $processId = [int64]$pid0 }
        }
        # Windows écrit parfois l'événement après la fermeture : la date de création
        # du processus permet de distinguer deux exécutions portant le même PID.
        $processStartTime = $null
        $started0 = & $pick 9 5
        if ($started0) {
            try {
                $fileTime = 0L
                if ($started0 -match '^0x([0-9a-f]+)$') { $fileTime = [Convert]::ToInt64($Matches[1], 16) }
                elseif ($started0 -match '^\d+$') { $fileTime = [int64]$started0 }
                if ($fileTime -gt 0) { $processStartTime = [datetime]::FromFileTime($fileTime) }
            }
            catch { }   # un champ absent ou illisible reste null
        }
        $result += [pscustomobject]@{
            Time          = $e.TimeCreated
            Application   = $app
            AppVersion    = & $pick 1 -1
            Module        = $module
            ModuleVersion = & $pick 4 -1
            ExceptionCode = & $normHex $code
            FaultOffset   = & $normHex $offset
            ProcessId     = $processId
            ProcessStartTime = $processStartTime
            AppPath       = & $pick 10 -1
            ModulePath    = & $pick 11 -1
            ReportId      = & $pick 12 -1
            RecordId      = $e.RecordId
            Message       = $msg
        }
    }
    $result | Sort-Object Time
}

function Get-KenshiHangEvents {
    <#
    .SYNOPSIS
        Lit les événements Windows « Application Hang » (ID 1002) de kenshi_x64.exe.
    .DESCRIPTION
        Windows écrit cet événement quand il ferme un programme qui ne répond plus (gel :
        fenêtre « ne répond pas » fermée). Les champs sont pris dans les propriétés de
        l'événement : 0 application, 1 version, 2 PID, 3 date de création du processus
        (FILETIME), 5 chemin, 6 ID de rapport, 9 type de gel. ProcessId, ProcessStartTime,
        AppPath et Time portent les mêmes noms que dans Get-KenshiCrashEvents, pour
        rattacher un gel à une session de la même façon. Résultat trié du plus ancien au
        plus récent.
    .PARAMETER Since
        Ne retourne que les événements postérieurs à cette date.
    .PARAMETER ProcessName
        Nom de l'exécutable à filtrer (kenshi_x64 par défaut).
    .EXAMPLE
        Get-KenshiHangEvents -Since (Get-Date).AddDays(-1) | Format-Table Time, ProcessId, AppPath
    #>
    [CmdletBinding()]
    param(
        [datetime]$Since,
        [string]$ProcessName = 'kenshi_x64'
    )
    $filter = @{ LogName = 'Application'; ProviderName = 'Application Hang'; Id = 1002 }
    if ($PSBoundParameters.ContainsKey('Since')) { $filter.StartTime = $Since }
    $events = @(Get-WinEvent -FilterHashtable $filter -ErrorAction SilentlyContinue)
    $result = @()
    foreach ($e in $events) {
        $props = @($e.Properties | ForEach-Object { "$($_.Value)" })
        $app = ''
        if ($props.Count -gt 0) { $app = $props[0] }
        if ($app -notmatch [regex]::Escape($ProcessName)) { continue }
        $pick = { param($i) if ($props.Count -gt $i -and $props[$i]) { $props[$i] } else { $null } }
        $processId = $null
        $pid0 = & $pick 2
        if ($pid0 -match '^0x([0-9a-f]+)$') { $processId = [Convert]::ToInt64($Matches[1], 16) }
        elseif ($pid0 -match '^\d+$') { $processId = [int64]$pid0 }
        $processStartTime = $null
        $started0 = & $pick 3
        try {
            $fileTime = 0L
            if ($started0 -match '^0x([0-9a-f]+)$') { $fileTime = [Convert]::ToInt64($Matches[1], 16) }
            elseif ($started0 -match '^\d+$') { $fileTime = [int64]$started0 }
            if ($fileTime -gt 0) { $processStartTime = [datetime]::FromFileTime($fileTime) }
        }
        catch { }   # un champ absent ou illisible reste null
        $result += [pscustomobject]@{
            Time             = $e.TimeCreated
            Application      = $app
            AppVersion       = & $pick 1
            ProcessId        = $processId
            ProcessStartTime = $processStartTime
            AppPath          = & $pick 5
            ReportId         = & $pick 6
            HangType         = & $pick 9
            RecordId         = $e.RecordId
            Message          = "$($e.Message)"
        }
    }
    $result | Sort-Object Time
}

function Get-KenshiSessions {
    <#
    .SYNOPSIS
        Découpe save.log en sessions de jeu (début, fin, sauvegardes).
    .DESCRIPTION
        Lignes reconnues : « HH:mm:ss [Info] Session start. », « ... [Info] Exit. » et
        « ... [Info] ------------- Saving <chemin> ---------------- ». Les heures ne
        sont pas toujours complétées par des zéros (« 1:3:52 ») et il n'y a pas de date :
        les heures sont renvoyées normalisées (HH:mm:ss) et la durée suppose au plus un
        passage de minuit. Une session sans « Exit. » s'est terminée brutalement ou est
        encore en cours (dernière session).
    .PARAMETER SaveLog
        Chemin de save.log (ou d'une copie).
    .EXAMPLE
        Get-KenshiSessions -SaveLog "$game\save.log" | Format-Table Index, StartTime, ExitTime, SaveCount, HasExit
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$SaveLog)
    if (-not (Test-Path -LiteralPath $SaveLog)) { throw "Journal introuvable : $SaveLog" }
    $sessions = New-Object 'System.Collections.Generic.List[object]'
    $current = $null
    $lineNo = 0
    foreach ($line in Get-Content -LiteralPath $SaveLog -Encoding UTF8) {
        $lineNo++
        if ($line -notmatch '^\s*(\d{1,2}):(\d{1,2}):(\d{1,2})\s+\[(\w+)\]\s*(.*)$') { continue }
        $time = New-Object TimeSpan ([int]$Matches[1]), ([int]$Matches[2]), ([int]$Matches[3])
        $timeText = $time.ToString()
        $level = $Matches[4]; $text = $Matches[5].Trim()
        if ($text -eq 'Session start.') {
            $current = [pscustomobject]@{
                Index = $sessions.Count + 1; StartTime = $timeText; ExitTime = $null; HasExit = $false
                Duration = $null; Saves = @(); SavedPaths = @(); SaveCount = 0
                WarningCount = 0; ErrorCount = 0; StartLine = $lineNo; EndLine = $lineNo
            }
            $sessions.Add($current)
            continue
        }
        if (-not $current) { continue }
        $current.EndLine = $lineNo
        if ($level -eq 'Warning') { $current.WarningCount++ }
        elseif ($level -eq 'Error') { $current.ErrorCount++ }
        if ($text -eq 'Exit.') {
            $current.ExitTime = $timeText; $current.HasExit = $true
            $start = [TimeSpan]::Parse($current.StartTime)
            $d = $time - $start
            if ($d.TotalSeconds -lt 0) { $d = $d.Add([TimeSpan]::FromDays(1)) }
            $current.Duration = $d
            $current = $null
            continue
        }
        if ($text -match '^-+\s*Saving\s+(.+?)\s*-+$') {
            $p = $Matches[1].Trim()
            $current.Saves = @($current.Saves) + [pscustomobject]@{ Time = $timeText; Path = $p }
            $current.SaveCount = $current.Saves.Count
            if ($current.SavedPaths -notcontains $p) { $current.SavedPaths = @($current.SavedPaths) + $p }
        }
    }
    $sessions.ToArray()
}

function Open-KenshiLogReader {
    <#
    .SYNOPSIS
        Ouvre un journal du jeu en lecture, même s'il est encore ouvert en écriture.
    .DESCRIPTION
        Kenshi garde kenshi.log et kenshi_info.log ouverts pendant toute la session, et
        WER encore un moment après un plantage : [IO.File]::ReadLines (partage lecture
        seule) échoue alors. Ce lecteur ouvre le fichier avec partage lecture/écriture
        et le lit en flux (UTF-8). L'appelant lit avec ReadLine() et appelle Dispose().
    .PARAMETER Path
        Chemin du journal.
    .EXAMPLE
        $r = Open-KenshiLogReader "$game\kenshi.log"
        try { while ($null -ne ($l = $r.ReadLine())) { $l } } finally { $r.Dispose() }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Journal introuvable : $Path" }
    Open-SharedTextReader (Resolve-Path -LiteralPath $Path).ProviderPath
}

# --- verrou du moniteur -----------------------------------------------------

# Le verrou contient « PID;date de création du processus (format o);phase;échéance » :
# un PID seul ne suffit pas, Windows le réattribue après un arrêt brutal du moniteur.
$script:MonitorLockPhases = @('waiting', 'session', 'finishing')
$script:ProcessCreationDate = $null

function Get-ProcessCreationDate([int]$ProcessId) {
    $p = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
    if ($p) { return $p.CreationDate }
    $null
}

function Read-KenshiMonitorLock {
    <#
    .SYNOPSIS
        Lit monitor.lock et dit si le moniteur qu'il désigne tourne encore.
    .DESCRIPTION
        Le verrou est vivant (IsLive) seulement si un processus porte son PID, que ce
        processus est powershell.exe ou pwsh.exe et que sa date de création correspond
        à celle enregistrée (à 2 s près) : un verrou laissé par un moniteur tué
        (Stop-Process, arrêt de Windows) est ainsi reconnu périmé même si le PID a été
        réattribué. Un ancien verrou contenant seulement le PID, ou une date absente
        ou illisible, est périmé : il ne permet pas d'identifier le processus.
        Phase : waiting (attend le jeu), session (jeu en cours), finishing
        (après la sortie du jeu : copie des journaux, attente des rapports Windows).
        Deadline : fin de l'attente du jeu (-WaitTimeoutSec), $null sans limite.
        Retourne $null si le fichier n'existe pas.
    .PARAMETER Path
        Chemin de monitor.lock.
    .EXAMPLE
        (Read-KenshiMonitorLock .\logs\sessions\monitor.lock).IsLive
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    # Le moniteur réécrit le verrou à chaque phase (troncature puis écriture) : une lecture vide ou
    # refusée pendant cet instant ne doit pas faire croire à un verrou périmé, d'où quelques essais.
    $raw = ''
    for ($try = 1; $try -le 5 -and -not $raw; $try++) {
        try {
            $s = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            try { $raw = (New-Object IO.StreamReader($s)).ReadToEnd().Trim() } finally { $s.Dispose() }
        }
        catch { }
        if (-not $raw -and $try -lt 5) { Start-Sleep -Milliseconds 100 }
    }
    $fields = @($raw -split ';')
    $invariant = [Globalization.CultureInfo]::InvariantCulture
    $lockPid = 0
    if ($fields[0] -match '^\d+$') { $lockPid = [int]$fields[0] }
    $started = $null; $phase = ''; $deadline = $null
    if ($fields.Count -gt 1 -and $fields[1]) { try { $started = [datetime]::Parse($fields[1], $invariant, 'RoundtripKind') } catch { } }
    if ($fields.Count -gt 2) { $phase = $fields[2].Trim() }
    if ($fields.Count -gt 3 -and $fields[3]) { try { $deadline = [datetime]::Parse($fields[3], $invariant, 'RoundtripKind') } catch { } }

    $live = $false; $reason = ''; $procName = $null
    $proc = $null
    if ($lockPid -gt 0) { $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $lockPid" -ErrorAction SilentlyContinue }
    if ($lockPid -le 0) { $reason = "contenu illisible (« $raw »)" }
    elseif (-not $proc) { $reason = "PID $lockPid absent" }
    else {
        $procName = "$($proc.Name)"
        if ($procName -notmatch '^(powershell|pwsh)\.exe$') { $reason = "le PID $lockPid appartient à $procName, pas à un PowerShell" }
        elseif (-not $started) { $reason = 'date de création absente ou illisible dans le verrou' }
        elseif (-not $proc.CreationDate) { $reason = "date de création du PID $lockPid introuvable" }
        elseif ([math]::Abs(($proc.CreationDate - $started).TotalSeconds) -gt 2) {
            $reason = "le PID $lockPid a été réattribué (processus démarré à $($proc.CreationDate.ToString('HH:mm:ss')), moniteur à $($started.ToString('HH:mm:ss')))"
        }
        else { $live = $true }
    }
    [pscustomobject]@{
        Path        = $Path
        ProcessId   = $lockPid
        StartTime   = $started
        Phase       = $phase
        Deadline    = $deadline
        IsLive      = $live
        Reason      = $reason
        ProcessName = $procName
    }
}

function Set-KenshiMonitorLock {
    <#
    .SYNOPSIS
        Écrit monitor.lock pour le processus courant, avec sa phase.
    .DESCRIPTION
        Écrit « PID;date de création du processus;phase;échéance » en UTF-8 sans BOM.
        À appeler par le moniteur à chaque changement de phase (waiting, session,
        finishing) ; play-kenshi.ps1 ne réutilise un moniteur qu'en phase waiting.
    .PARAMETER Path
        Chemin de monitor.lock.
    .PARAMETER Phase
        waiting, session ou finishing.
    .PARAMETER Deadline
        Fin de l'attente du jeu (phase waiting avec -WaitTimeoutSec) ; omise sinon.
    .EXAMPLE
        Set-KenshiMonitorLock -Path $lock -Phase waiting -Deadline (Get-Date).AddSeconds(600)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Phase,
        [Nullable[datetime]]$Deadline
    )
    if ($script:MonitorLockPhases -notcontains $Phase) { throw "Phase inconnue : $Phase (attendu : $($script:MonitorLockPhases -join ', '))" }
    if (-not $script:ProcessCreationDate) { $script:ProcessCreationDate = Get-ProcessCreationDate $PID }
    # Sans date, Read-KenshiMonitorLock juge le verrou périmé : repli sur .NET si WMI échoue.
    if (-not $script:ProcessCreationDate) { try { $script:ProcessCreationDate = (Get-Process -Id $PID -ErrorAction Stop).StartTime } catch { } }
    $started = ''
    if ($script:ProcessCreationDate) { $started = $script:ProcessCreationDate.ToString('o') }
    $until = ''
    if ($null -ne $Deadline) { $until = ([datetime]$Deadline).ToString('o') }   # PowerShell déballe le Nullable
    $text = '{0};{1};{2};{3}' -f $PID, $started, $Phase, $until
    # Quelques essais : play-kenshi.ps1 peut lire le verrou au même instant (violation de partage)
    for ($try = 1; ; $try++) {
        try { [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding $false)); break }
        catch [IO.IOException] { if ($try -ge 5) { throw }; Start-Sleep -Milliseconds 100 }
    }
}

Export-ModuleMember -Function Get-KenshiPaths, Read-ModHeader, Get-ModFileIndex, Get-ActiveModList,
    Test-KenshiModList, Backup-File, Write-ModList, Get-KenshiLogSummary, Format-KenshiLogSummary,
    Get-KenshiCrashEvents, Get-KenshiHangEvents, Get-KenshiSessions, Open-KenshiLogReader, Read-KenshiMonitorLock, Set-KenshiMonitorLock
