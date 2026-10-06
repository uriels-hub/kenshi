<#
.SYNOPSIS
    Tests automatiques des outils Kenshi du dépôt (module et scripts), sans Pester.

.DESCRIPTION
    Construit un jeu de données jetable sous $env:TEMP (fichiers .mod synthétiques de
    type 16 et 17 avec leurs en-têtes binaires, faux dossier du jeu, faux Workshop avec
    un fichier en double, faux journaux kenshi_info.log / save.log / kenshi.log, fausse
    liste de pack), puis vérifie :
      - le module tools\KenshiTools.psm1 : Read-ModHeader, Get-ModFileIndex,
        Get-ActiveModList, Test-KenshiModList, Write-ModList, Get-KenshiLogSummary,
        Format-KenshiLogSummary, Get-KenshiSessions, Get-KenshiPaths ;
      - les scripts restore-modlist.ps1, scan-mods.ps1, summarize-logs.ps1,
        health-check.ps1, play-kenshi.ps1 (-DryRun) et update-pack.ps1, lancés dans un
        PowerShell enfant du même hôte et pointés sur les faux dossiers.
    Rien n'est écrit en dehors du dossier temporaire, qui est supprimé à la fin
    (sauf -Keep). Le vrai jeu, le Workshop, les sauvegardes et le dépôt ne sont pas
    modifiés ; Steam et Kenshi ne sont jamais lancés. Les tests qui exigent que
    Kenshi soit fermé sont ignorés s'il tourne.
    Code de sortie : 0 si tous les tests passent, 1 sinon.

.PARAMETER Filter
    Ne lance que les tests dont le nom correspond à ce motif (-like), par ex. 'Read-ModHeader*'.
.PARAMETER Keep
    Conserve le dossier temporaire des données de test (son chemin est affiché).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1
.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File tests\run-tests.ps1 -Filter 'scan-mods*'
#>
[CmdletBinding()]
param(
    [string]$Filter,
    [switch]$Keep
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$tools = Join-Path $repo 'tools'
Import-Module (Join-Path $tools 'KenshiTools.psm1') -Force

$script:passed = 0; $script:failed = 0; $script:skipped = 0
$script:failures = New-Object 'System.Collections.Generic.List[string]'
$utf8NoBom = New-Object Text.UTF8Encoding $false
$hostExe = (Get-Process -Id $PID).Path
$kenshiRunning = [bool](Get-Process kenshi_x64 -ErrorAction SilentlyContinue)

# --- mini-cadre de test -----------------------------------------------------

function Test-Case([string]$Name, [scriptblock]$Body) {
    if ($Filter -and $Name -notlike $Filter) { return }
    try {
        & $Body
        $script:passed++
        Write-Host ("  OK     {0}" -f $Name) -ForegroundColor Green
    }
    catch {
        $script:failed++
        $msg = $_.Exception.Message
        $script:failures.Add("$Name : $msg")
        Write-Host ("  ECHEC  {0}" -f $Name) -ForegroundColor Red
        Write-Host ("         {0}" -f $msg) -ForegroundColor Red
    }
}

function Skip-Case([string]$Name, [string]$Reason) {
    if ($Filter -and $Name -notlike $Filter) { return }
    $script:skipped++
    Write-Host ("  IGNORE {0} : {1}" -f $Name, $Reason) -ForegroundColor Yellow
}

function Assert-True($Condition, [string]$Label) {
    if (-not $Condition) { throw "$Label : attendu vrai" }
}

function Assert-Equal($Expected, $Actual, [string]$Label) {
    if ("$Expected" -ne "$Actual") { throw "$Label : attendu « $Expected », obtenu « $Actual »" }
}

function Assert-Null($Actual, [string]$Label) {
    if ($null -ne $Actual) { throw "$Label : attendu null, obtenu « $Actual »" }
}

function Assert-Match([string]$Text, [string]$Pattern, [string]$Label) {
    if ($Text -notmatch $Pattern) {
        $extract = $Text; if ($extract.Length -gt 300) { $extract = $extract.Substring(0, 300) + '...' }
        throw "$Label : motif « $Pattern » absent de : $extract"
    }
}

function Assert-NotMatch([string]$Text, [string]$Pattern, [string]$Label) {
    if ($Text -match $Pattern) { throw "$Label : motif « $Pattern » trouvé alors qu'il ne devrait pas l'être" }
}

function Assert-Throws([scriptblock]$Body, [string]$Pattern, [string]$Label) {
    $thrown = $null
    try { & $Body | Out-Null } catch { $thrown = $_.Exception.Message }
    if ($null -eq $thrown) { throw "$Label : aucune erreur levée" }
    if ($Pattern -and $thrown -notmatch $Pattern) { throw "$Label : erreur « $thrown » sans le motif « $Pattern »" }
}

function Test-Bom([string]$Path) {
    $b = [IO.File]::ReadAllBytes($Path)
    ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
}

function Get-FileLines([string]$Path) { [string[]]@([IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) }
function Get-FileText([string]$Path) { [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) }

# Lance un script du dépôt dans un PowerShell enfant (même hôte) : ses « exit » ne
# touchent pas ce lanceur. Retourne ExitCode, Output (stdout) et Errors (stderr).
# RawArguments est ajouté tel quel à la ligne de commande (valeurs non textuelles, par ex. -ModIndex @{}).
function Invoke-Tool([string]$Script, [hashtable]$Arguments = @{}, [string[]]$Switches = @(), [string]$Location = '', [string]$RawArguments = '') {
    $cmd = '[Console]::OutputEncoding = [Text.Encoding]::UTF8; '
    if ($Location) { $cmd += "Set-Location -LiteralPath '" + ($Location -replace "'", "''") + "'; " }
    $cmd += "& '" + ($Script -replace "'", "''") + "'"
    foreach ($k in $Arguments.Keys) { $cmd += " -{0} '{1}'" -f $k, ("$($Arguments[$k])" -replace "'", "''") }
    foreach ($s in $Switches) { $cmd += " -$s" }
    if ($RawArguments) { $cmd += " $RawArguments" }
    $cmd += '; exit $LASTEXITCODE'
    $errFile = Join-Path $script:fixtures ('stderr-{0}.txt' -f ([Guid]::NewGuid().ToString('N').Substring(0, 8)))
    $ErrorActionPreference = 'Continue'
    $out = @(& $hostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $cmd 2> $errFile | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    $err = ''
    if (Test-Path -LiteralPath $errFile) { $err = Get-FileText $errFile; Remove-Item -LiteralPath $errFile -Force }
    [pscustomobject]@{ ExitCode = $code; Output = ($out -join "`n"); Errors = $err }
}

# --- construction des données de test ---------------------------------------

function Write-TextFile([string]$Path, [string[]]$Lines) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllLines($Path, [string[]]$Lines, $utf8NoBom)
}

# Écrit un .mod synthétique : int32 type ; (type 17) int32 taille d'en-tête ; int32 version ;
# puis auteur, description, dépendances, références (int32 longueur + octets UTF-8), puis un corps factice.
function New-ModFile([string]$Path, [int]$Type = 16, [string]$Author = 'tests', [string]$Description = '',
    [string]$Dependencies = '', [string]$References = '', [int]$Version = 1) {
    $enc = [Text.Encoding]::UTF8
    $strings = @($Author, $Description, $Dependencies, $References)
    $headerSize = 4
    foreach ($s in $strings) { $headerSize += 4 + $enc.GetByteCount($s) }
    $ms = New-Object IO.MemoryStream
    $bw = New-Object IO.BinaryWriter($ms)
    $bw.Write([int32]$Type)
    if ($Type -eq 17) { $bw.Write([int32]$headerSize) }
    $bw.Write([int32]$Version)
    foreach ($s in $strings) {
        $b = $enc.GetBytes($s)
        $bw.Write([int32]$b.Length)
        $bw.Write([byte[]]$b)
    }
    $bw.Write([byte[]](1, 2, 3, 4, 5, 6, 7, 8))
    $bw.Flush()
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllBytes($Path, $ms.ToArray())
    $bw.Dispose()
}

function New-RawFile([string]$Path, [byte[]]$Bytes) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllBytes($Path, $Bytes)
}

# La dernière session commence à -LastStart (HH:mm:ss), sauvegarde à +20 min, « Exit. » à +30 min.
function Get-SaveLogLines([bool]$LastSessionExits, [string]$LastStart = '10:00:00') {
    $t0 = [TimeSpan]::Parse($LastStart)
    function Clock([TimeSpan]$T) { [TimeSpan]::FromTicks($T.Ticks % [TimeSpan]::TicksPerDay).ToString() }
    $lines = @(
        '1:3:52 [Info] Session start.',
        '1:10:0 [Info] ------------- Saving C:\Users\test\AppData\Local\kenshi\save\UR1 ----------------',
        '01:12:00 [Info] ------------- Saving C:\Users\test\AppData\Local\kenshi\save\UR1 ----------------',
        '01:12:30 [Info] ------------- Saving C:\Users\test\AppData\Local\kenshi\save\autosave1 ----------------',
        '01:15:30 [Info] Exit.',
        'ligne sans horodatage, ignorée',
        '23:50:00 [Info] Session start.',
        '23:55:00 [Warning] Could not find something',
        '23:56:00 [Error] Bad thing happened',
        '00:05:00 [Info] Exit.',
        "$(Clock $t0) [Info] Session start.",
        "$(Clock $t0.Add([TimeSpan]::FromMinutes(20))) [Info] ------------- Saving C:\Users\test\AppData\Local\kenshi\save\autosave2 ----------------"
    )
    if ($LastSessionExits) { $lines += "$(Clock $t0.Add([TimeSpan]::FromMinutes(30))) [Info] Exit." }
    $lines
}

# -LauncherOnly : passage arrêté au lanceur (pas de « Launching game », aucun mod chargé).
# -LaunchStamp : heure du clic sur Play si elle diffère de « Kenshi start » (lanceur resté ouvert).
function Get-InfoLogLines([string]$Stamp, [bool]$LauncherOnly = $false, [string]$LaunchStamp = '') {
    $p = '{0x00001234} ' + $Stamp
    if ($LauncherOnly) {
        return @("$p [info]: ** Kenshi start **", "$p [info]: Version: 1.0.68", "$p [info]: [Launcher] Initialised")
    }
    $l = $p
    if ($LaunchStamp) { $l = '{0x00001234} ' + $LaunchStamp }
    @(
        "$p [info]: ** Kenshi start **",
        "$p [info]: Version: 1.0.68",
        "$p [info]: [Launcher] Initialised",
        "$l [info]: [Launcher] Launching game...",
        "$p [info]: [Mods] Loaded mod: Alpha",
        "$p [info]: [Mods] Loaded mod: Beta",
        "$p [info]: [Mods] Loaded mod: Local",
        "$p [warning]: Part map contains invalid colour: #ff00ff",
        "$p [warning]: Part map contains invalid colour: #00ff00",
        "$p [warning]: Part map contains invalid colour: #0000ff",
        "$p [warning]: Missing texture 12.png",
        "$p [warning]: Missing texture 99.png",
        "$p [error]: Item 12 (gamedata.base) modified by Beta does not exist",
        "$p [error]: Item 34 (Beta.mod) modified by Beta does not exist",
        "$p [error]: Item 56 (x.mod) modified by Local does not exist",
        "$p [error]: Something broke"
    )
}

function Get-OgreLogLines {
    @(
        '10:00:01: Creating resource group General',
        '10:00:02: OGRE EXCEPTION(6:FileNotFoundException): Cannot locate resource foo.png',
        '10:00:03: Compiler error: unknown error in bar.particle(12)',
        '10:00:04: WARNING: something | with a pipe 7',
        '10:05:00: *-*-* OGRE Shutdown'
    )
}

# Faux dossier du jeu : data\ avec les 4 fichiers de base et un mods.cfg, mods\ avec un mod local.
# Avec kenshi_info.log, la dernière session de save.log démarre 3 s après « Launching game »
# (même passage) ; -LauncherMinutes recule « Kenshi start » d'autant (lanceur resté ouvert
# avant le clic sur Play) ; avec -LauncherOnly, kenshi_info.log décrit un passage arrêté au
# lanceur, postérieur à la dernière session de save.log (00:00:10).
function New-FakeGame([string]$Dir, [string[]]$Mods, [bool]$WithInfoLog, [bool]$LastSessionExits, [bool]$WithReKenshi, [string[]]$LocalMods, [bool]$LauncherOnly = $false, [int]$LauncherMinutes = 0) {
    $data = Join-Path $Dir 'data'
    foreach ($core in 'gamedata.base', 'Newwworld.mod', 'Dialogue.mod', 'rebirth.mod') {
        New-ModFile -Path (Join-Path $data $core) -Type 16 -Author 'Lo-Fi Games'
    }
    Write-TextFile (Join-Path $data 'mods.cfg') $Mods
    New-ModFile -Path (Join-Path $Dir 'mods\Local.mod') -Type 16 -Author 'local'
    foreach ($rel in $LocalMods) {
        Copy-Item -LiteralPath (Join-Path (Join-Path $script:fixtures 'workshop') $rel) -Destination (Join-Path $Dir 'mods')
    }
    Write-TextFile (Join-Path $Dir 'currentVersion.txt') @('1.0.68')
    # « Kenshi start » il y a 10 s, « Session start. » 3 s plus tard : les deux avant la dernière écriture des fichiers
    $now = (Get-Date).AddSeconds(-10)
    $lastStart = '10:00:00'
    if ($WithInfoLog -and -not $LauncherOnly) { $lastStart = $now.AddSeconds(3).ToString('HH:mm:ss') }
    if ($LauncherOnly) { $lastStart = '00:00:10' }   # toujours antérieur au passage de kenshi_info.log
    Write-TextFile (Join-Path $Dir 'save.log') (Get-SaveLogLines $LastSessionExits $lastStart)
    Write-TextFile (Join-Path $Dir 'kenshi.log') (Get-OgreLogLines)
    if ($WithInfoLog) {
        $kenshiStart = $now.AddMinutes(-$LauncherMinutes).ToString('yyyy-MM-dd HH:mm:ss')
        $launch = ''
        if ($LauncherMinutes -gt 0) { $launch = $now.ToString('yyyy-MM-dd HH:mm:ss') }
        Write-TextFile (Join-Path $Dir 'kenshi_info.log') (Get-InfoLogLines $kenshiStart $LauncherOnly $launch)
    }
    $plugins = @('Plugin=RenderSystem_Direct3D11_x64')
    if ($WithReKenshi) {
        New-RawFile (Join-Path $Dir 'RE_Kenshi.dll') ([byte[]](0x4D, 0x5A, 0, 0))
        $plugins += 'Plugin=RE_Kenshi'
    }
    Write-TextFile (Join-Path $Dir 'Plugins_x64.cfg') $plugins
}

function New-Fixtures([string]$Root) {
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    $ws = Join-Path $Root 'workshop'
    # Mods Workshop : Alpha (16) <- Beta (17) <- Gamma (16, + dépendance de base) ; Delta dépend d'un absent ;
    # Epsilon dépend de Gamma ; Dup.mod existe dans deux objets ; Truncated et BadType sont illisibles.
    New-ModFile -Path (Join-Path $ws '1001\Alpha.mod') -Type 16 -Author 'Auteur Alpha' -Description 'Premier mod, accents : éà'
    New-ModFile -Path (Join-Path $ws '1002\Beta.mod') -Type 17 -Author 'Auteur Beta' -Dependencies 'Alpha.mod' -References 'Newwworld.mod' -Version 3
    New-ModFile -Path (Join-Path $ws '1003\Gamma.mod') -Type 16 -Author 'Auteur Gamma' -Dependencies 'Beta.mod, rebirth.mod'
    New-ModFile -Path (Join-Path $ws '1004\Delta.mod') -Type 17 -Author 'Auteur Delta' -Dependencies 'Ghost.mod'
    New-ModFile -Path (Join-Path $ws '1005\Dup.mod') -Type 16 -Author 'Copie 1'
    New-ModFile -Path (Join-Path $ws '1006\Dup.mod') -Type 16 -Author 'Copie 2'
    New-ModFile -Path (Join-Path $ws '1009\Epsilon.mod') -Type 16 -Author 'Auteur Epsilon' -Dependencies 'Gamma.mod'
    New-ModFile -Path (Join-Path $ws 'misc\Misc.mod') -Type 16 -Author 'Sans id'
    New-ModFile -Path (Join-Path $ws '1010\Sub\Nested.mod') -Type 16 -Author 'En sous-dossier'   # non chargé par Kenshi
    New-RawFile (Join-Path $ws '1007\Truncated.mod') ([byte[]](16, 0, 0, 0, 1, 0, 0, 0, 100, 0, 0, 0, 65, 66, 67, 68, 69))
    New-RawFile (Join-Path $ws '1008\BadType.mod') ([byte[]](99, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0))
    New-RawFile (Join-Path $ws '1001\Alpha.model') ([byte[]](1, 2, 3))   # ignoré par l'index (.model)
    New-RawFile (Join-Path $Root 'empty.mod') ([byte[]]@())

    # Faux pack : 3 mods
    Write-TextFile (Join-Path $Root 'pack\mods.cfg') @('Alpha.mod', 'Beta.mod', 'Gamma.mod')
    Write-TextFile (Join-Path $Root 'pack\pack-modlist.csv') @(
        '"position","workshop_id","mod_file","title","dependencies","url"',
        '"1","1001","Alpha.mod","Alpha","","https://steamcommunity.com/sharedfiles/filedetails/?id=1001"',
        '"2","1002","Beta.mod","Beta","Alpha.mod","https://steamcommunity.com/sharedfiles/filedetails/?id=1002"',
        '"3","1003","Gamma.mod","Gamma","Beta.mod","https://steamcommunity.com/sharedfiles/filedetails/?id=1003"'
    )

    # Listes à vérifier
    $lists = Join-Path $Root 'lists'
    Write-TextFile (Join-Path $lists 'clean.cfg') @('Alpha.mod', '', '  Beta.mod  ', 'Gamma.mod')
    Write-TextFile (Join-Path $lists 'missing.cfg') @('Alpha.mod', 'Nope.mod')
    Write-TextFile (Join-Path $lists 'absent-dep.cfg') @('Alpha.mod', 'Delta.mod')
    Write-TextFile (Join-Path $lists 'inactive-dep.cfg') @('Alpha.mod', 'Epsilon.mod')
    Write-TextFile (Join-Path $lists 'late-dep.cfg') @('Beta.mod', 'Alpha.mod')
    Write-TextFile (Join-Path $lists 'dup.cfg') @('Alpha.mod', 'Dup.mod')
    Write-TextFile (Join-Path $lists 'unreadable.cfg') @('Truncated.mod', 'BadType.mod')
    Write-TextFile (Join-Path $lists 'extra.cfg') @('Alpha.mod', 'Beta.mod', 'Gamma.mod', 'Local.mod')
    Write-TextFile (Join-Path $lists 'partial.cfg') @('Alpha.mod', 'Beta.mod')
    Write-TextFile (Join-Path $lists 'single.cfg') @('Alpha.mod')
    Write-TextFile (Join-Path $lists 'empty.cfg') @('', '   ')
    Write-TextFile (Join-Path $lists 'nested.cfg') @('Alpha.mod', 'Nested.mod')
    Write-TextFile (Join-Path $lists 'problems.cfg') @('Beta.mod', 'Alpha.mod', 'Delta.mod', 'Epsilon.mod', 'Dup.mod', 'Truncated.mod', 'Nope.mod')

    # Faux jeux : A (propre, journaux complets), B (sans kenshi_info.log, arrêt brutal, mod manquant),
    # R (pour restore), H (pour health-check : ses mods sont dans jeu\mods, avec RE_Kenshi),
    # L (kenshi_info.log d'un passage arrêté au lanceur, plus récent que la dernière session de save.log)
    New-FakeGame (Join-Path $Root 'gameA') @('Alpha.mod', 'Beta.mod', 'Gamma.mod') $true $true $false @()
    New-FakeGame (Join-Path $Root 'gameB') @('Alpha.mod', 'Nope.mod') $false $false $false @('1001\Alpha.mod')
    New-FakeGame (Join-Path $Root 'gameR') @('Alpha.mod', 'Zzz.mod') $true $true $false @()
    New-FakeGame (Join-Path $Root 'gameH') @('Alpha.mod', 'Beta.mod', 'Gamma.mod') $true $true $true @('1001\Alpha.mod', '1002\Beta.mod', '1003\Gamma.mod')
    New-FakeGame (Join-Path $Root 'gameL') @('Alpha.mod') $true $true $false @() $true
    # W : lanceur resté ouvert 20 min avant le clic sur Play (même passage malgré l'écart avec « Kenshi start »)
    New-FakeGame (Join-Path $Root 'gameW') @('Alpha.mod', 'Beta.mod', 'Gamma.mod') $true $true $false @() $false 20
    Write-TextFile (Join-Path $Root 'logs\save-sessions.log') (Get-SaveLogLines $false)
    Write-TextFile (Join-Path $Root 'logs\kenshi_info.log') (Get-InfoLogLines '2026-10-06 00:44:36')
    New-Item -ItemType Directory -Path (Join-Path $Root 'empty-workshop') -Force | Out-Null

    # Copie jetable du dépôt (tools\ + faux pack) : play-kenshi.ps1 y cherche logs\sessions\monitor.lock
    # sans toucher à celui du vrai dépôt
    $repoCopy = Join-Path $Root 'repo'
    New-Item -ItemType Directory -Path (Join-Path $repoCopy 'tools') -Force | Out-Null
    Copy-Item -Path (Join-Path $tools '*.ps1') -Destination (Join-Path $repoCopy 'tools')
    Copy-Item -Path (Join-Path $tools '*.psm1') -Destination (Join-Path $repoCopy 'tools')
    Write-TextFile (Join-Path $repoCopy 'modlist\mods.cfg') @('Alpha.mod', 'Beta.mod', 'Gamma.mod')
}

# Tient un fichier ouvert en écriture avec partage lecture/écriture, comme std::ofstream (OGRE)
function Open-WriterHandle([string]$Path) {
    New-Object IO.FileStream($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
}

# PID d'un processus vivant qui n'est pas un PowerShell (pour simuler un PID réattribué)
function Get-ForeignPid {
    $p = Get-Process explorer -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $p) { $p = Get-Process | Where-Object { $_.Name -notmatch '^(powershell|pwsh)$' -and $_.Id -ne 0 } | Select-Object -First 1 }
    if ($p) { return $p.Id }
    0
}

# --- exécution ----------------------------------------------------------------

$script:fixtures = Join-Path $env:TEMP ('kenshi-tests-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$savedConsoleEncoding = [Console]::OutputEncoding
$sw = [Diagnostics.Stopwatch]::StartNew()
Write-Host ("Tests des outils Kenshi : PowerShell {0}, hôte {1}" -f $PSVersionTable.PSVersion, $hostExe)
Write-Host "Données de test : $script:fixtures"
if ($kenshiRunning) { Write-Warning 'kenshi_x64.exe tourne : les tests qui exigent le jeu fermé sont ignorés.' }

try {
    [Console]::OutputEncoding = $utf8NoBom
    New-Fixtures $script:fixtures
    $ws = Join-Path $script:fixtures 'workshop'
    $pack = Join-Path $script:fixtures 'pack\mods.cfg'
    $lists = Join-Path $script:fixtures 'lists'
    $gameA = Join-Path $script:fixtures 'gameA'
    $gameB = Join-Path $script:fixtures 'gameB'
    $gameR = Join-Path $script:fixtures 'gameR'
    $gameH = Join-Path $script:fixtures 'gameH'
    $gameL = Join-Path $script:fixtures 'gameL'
    $gameW = Join-Path $script:fixtures 'gameW'
    $repoCopy = Join-Path $script:fixtures 'repo'
    $sessionsDir = Join-Path $repo 'logs\sessions'
    function Get-SessionsSnapshot {
        if (-not (Test-Path -LiteralPath $sessionsDir)) { return '(absent)' }
        @(Get-ChildItem -LiteralPath $sessionsDir -Recurse -Force | ForEach-Object { $_.FullName }) -join '|'
    }
    $sessionsBefore = Get-SessionsSnapshot

    # --- module : en-têtes et index -----------------------------------------
    Write-Host ''
    Write-Host 'Module KenshiTools' -ForegroundColor Cyan

    Test-Case 'Read-ModHeader : type 16' {
        $h = Read-ModHeader -Path (Join-Path $ws '1001\Alpha.mod')
        Assert-Equal 16 $h.Type 'Type'
        Assert-Null $h.HeaderSize 'HeaderSize'
        Assert-Equal 1 $h.Version 'Version'
        Assert-Equal 'Auteur Alpha' $h.Author 'Author'
        Assert-Equal 'Premier mod, accents : éà' $h.Description 'Description (UTF-8)'
        Assert-Equal '' (@($h.Dependencies) -join ',') 'Dependencies vides'   # le module renvoie $null plutôt qu'un string[] vide
        Assert-Equal 'Alpha.mod' $h.Name 'Name'
    }

    Test-Case 'Read-ModHeader : type 17 avec dépendances' {
        $h = Read-ModHeader -Path (Join-Path $ws '1002\Beta.mod')
        Assert-Equal 17 $h.Type 'Type'
        Assert-Equal 3 $h.Version 'Version'
        Assert-True ($h.HeaderSize -gt 0) 'HeaderSize renseigné'
        Assert-Equal 'Alpha.mod' ($h.Dependencies -join ',') 'Dependencies'
        Assert-Equal 'Newwworld.mod' ($h.References -join ',') 'References'
        $g = Read-ModHeader -Path (Join-Path $ws '1003\Gamma.mod')
        Assert-Equal 'Beta.mod|rebirth.mod' ($g.Dependencies -join '|') 'Dependencies découpées et nettoyées'
    }

    Test-Case 'Read-ModHeader : en-tête tronqué -> erreur' {
        Assert-Throws { Read-ModHeader -Path (Join-Path $ws '1007\Truncated.mod') } 'En-tête \.mod illisible.*tronqué' 'fichier tronqué'
        Assert-Throws { Read-ModHeader -Path (Join-Path $script:fixtures 'empty.mod') } 'En-tête \.mod illisible' 'fichier vide'
    }

    Test-Case 'Read-ModHeader : type inconnu -> erreur' {
        Assert-Throws { Read-ModHeader -Path (Join-Path $ws '1008\BadType.mod') } 'type d.en-tête inconnu \(99' 'type 99'
    }

    Test-Case 'Get-ModFileIndex : doublons, ids Workshop, extensions' {
        $index = Get-ModFileIndex -Folders @((Join-Path $gameA 'mods'), $ws, (Join-Path $script:fixtures 'nexistepas'))
        Assert-Equal 11 $index.Count 'nombre de noms distincts'
        Assert-True $index['Dup.mod'].IsDuplicate 'Dup.mod en double'
        Assert-Equal 2 $index['Dup.mod'].Paths.Count 'Dup.mod : 2 chemins'
        Assert-Equal '1005,1006' (($index['Dup.mod'].WorkshopIds | Sort-Object) -join ',') 'Dup.mod : ids Workshop'
        Assert-True (-not $index['Alpha.mod'].IsDuplicate) 'Alpha.mod unique'
        Assert-Equal '1001' $index['Alpha.mod'].WorkshopId 'Alpha.mod : id Workshop'
        Assert-Null $index['Local.mod'].WorkshopId 'Local.mod sans id'
        Assert-Null $index['Misc.mod'].WorkshopId 'Misc.mod (dossier non numérique) sans id'
        Assert-True (-not $index.ContainsKey('Alpha.model')) '.model ignoré'
        Assert-True $index['Nested.mod'].IsNestedOnly 'Nested.mod seulement en sous-dossier'
        Assert-Equal 1 $index['Nested.mod'].NestedPaths.Count 'NestedPaths'
        Assert-True (-not $index['Alpha.mod'].IsNestedOnly) 'Alpha.mod chargeable'
    }

    Test-Case 'Get-ActiveModList : lignes nettoyées, fichier absent' {
        $l = Get-ActiveModList -Path (Join-Path $lists 'clean.cfg')
        Assert-Equal 'Alpha.mod|Beta.mod|Gamma.mod' ($l -join '|') 'lignes'
        Assert-Throws { Get-ActiveModList -Path (Join-Path $lists 'nope.cfg') } 'introuvable' 'fichier absent'
    }

    Test-Case 'Get-ActiveModList : @() donne un tableau pour une ligne ou un fichier vide' {
        # Contrat du module : résultat déroulé comme toute commande, à envelopper dans @() (ce que font
        # tous les appelants). Un résultat non déroulé (« , » ou -NoEnumerate) serait imbriqué par @().
        $one = @(Get-ActiveModList -Path (Join-Path $lists 'single.cfg'))
        Assert-Equal 1 $one.Count 'Count pour une ligne'
        Assert-Equal 'Alpha.mod' $one[0] 'élément unique'
        $none = @(Get-ActiveModList -Path (Join-Path $lists 'empty.cfg'))
        Assert-Equal 0 $none.Count 'Count pour un fichier vide'
        $three = @(Get-ActiveModList -Path (Join-Path $lists 'clean.cfg'))
        Assert-Equal 3 $three.Count 'Count pour trois lignes (pas d''imbrication)'
        Assert-Equal 'Beta.mod' $three[1] 'deuxième élément'
    }

    Test-Case 'Get-KenshiPaths : -Game et -Workshop' {
        $p = Get-KenshiPaths -Game ($gameA + '\') -Workshop $ws
        Assert-True ($p.Game -ieq $gameA) "Game ($($p.Game))"
        Assert-True ($p.Workshop -ieq $ws) "Workshop ($($p.Workshop))"
        Assert-True ($p.ModsCfg -ieq (Join-Path $gameA 'data\mods.cfg')) "ModsCfg ($($p.ModsCfg))"
        Assert-True ($p.SaveLog -ieq (Join-Path $gameA 'save.log')) 'SaveLog'
        Assert-True (-not $p.Detected) 'Detected = $false avec -Game'
        Assert-True (Get-KenshiPaths).Detected 'Detected = $true sans -Game'
    }

    Test-Case 'Get-KenshiPaths : chemin UNC conservé, casse réelle, chemin relatif résolu sur $PWD' {
        $u = Get-KenshiPaths -Game '\\nas\jeux\Kenshi' -Workshop '\\nas\jeux\workshop\'
        Assert-Equal '\\nas\jeux\Kenshi' $u.Game 'UNC -Game'
        Assert-Equal '\\nas\jeux\workshop' $u.Workshop 'UNC -Workshop'
        $lower = (Get-KenshiPaths -Game $gameA.ToLower()).Game
        $upper = (Get-KenshiPaths -Game $gameA.ToUpper()).Game
        Assert-True ($lower -ceq $upper) "casse normalisée ($lower / $upper)"
        Assert-True ($lower -ieq $gameA) 'même dossier'
        Push-Location -LiteralPath $script:fixtures
        try { $rel = (Get-KenshiPaths -Game '.\gameA').Game } finally { Pop-Location }
        Assert-True ($rel -ieq $gameA) "chemin relatif ($rel)"
    }

    # --- module : Test-KenshiModList ----------------------------------------
    function Test-List([string]$List, [string]$PackCfg) {
        Test-KenshiModList -ModsCfg (Join-Path $lists $List) -PackCfg $PackCfg -Game $gameA -Workshop $ws
    }

    Test-Case 'Test-KenshiModList : liste propre' {
        $r = Test-List 'clean.cfg' $pack
        Assert-True $r.IsClean 'IsClean'
        Assert-Equal 3 $r.Counts.Active 'Active'
        Assert-Equal 11 $r.Counts.FilesOnDisk 'FilesOnDisk'
        Assert-Equal 3 $r.Counts.Pack 'Pack'
        Assert-Equal 0 $r.Counts.Problems 'Problems'
        Assert-Equal 0 $r.Counts.AbsentDependencies 'dépendance de base (rebirth.mod) ignorée'
    }

    Test-Case 'Test-KenshiModList : fichier introuvable' {
        $r = Test-List 'missing.cfg' ''
        Assert-Equal 1 $r.Counts.MissingFiles 'MissingFiles'
        Assert-Equal 'Nope.mod' ($r.MissingFiles -join ',') 'nom'
        Assert-True (-not $r.IsClean) 'IsClean'
        Assert-Null $r.Counts.Pack 'Pack sans -PackCfg'
    }

    Test-Case 'Test-KenshiModList : dépendance absente' {
        $r = Test-List 'absent-dep.cfg' ''
        Assert-Equal 1 $r.Counts.AbsentDependencies 'AbsentDependencies'
        Assert-Equal 2 $r.Counts.Active 'Active'
        Assert-Equal 'Delta.mod' $r.AbsentDependencies[0].Mod 'Mod'
        Assert-Equal 'Ghost.mod' $r.AbsentDependencies[0].Dependency 'Dependency'
    }

    Test-Case 'Test-KenshiModList : dépendance non activée' {
        $r = Test-List 'inactive-dep.cfg' ''
        Assert-Equal 1 $r.Counts.InactiveDependencies 'InactiveDependencies'
        Assert-Equal 'Gamma.mod' $r.InactiveDependencies[0].Dependency 'Dependency'
        Assert-Equal '1003' $r.InactiveDependencies[0].WorkshopId 'WorkshopId'
        Assert-Equal 0 $r.Counts.AbsentDependencies 'AbsentDependencies'
    }

    Test-Case 'Test-KenshiModList : dépendance chargée trop tard' {
        $r = Test-List 'late-dep.cfg' ''
        Assert-Equal 1 $r.Counts.LateDependencies 'LateDependencies'
        $l = $r.LateDependencies[0]
        Assert-Equal 'Beta.mod' $l.Mod 'Mod'
        Assert-Equal 1 $l.Position 'Position'
        Assert-Equal 'Alpha.mod' $l.Dependency 'Dependency'
        Assert-Equal 2 $l.DependencyPosition 'DependencyPosition'
    }

    Test-Case 'Test-KenshiModList : fichier en double' {
        $r = Test-List 'dup.cfg' ''
        Assert-Equal 1 $r.Counts.DuplicateFiles 'DuplicateFiles'
        Assert-Equal 'Dup.mod' $r.DuplicateFiles[0].Mod 'Mod'
        Assert-Equal 2 $r.DuplicateFiles[0].Position 'Position'
        Assert-Equal 2 $r.DuplicateFiles[0].Paths.Count 'Paths'
    }

    Test-Case 'Test-KenshiModList : en-têtes illisibles' {
        $r = Test-List 'unreadable.cfg' ''
        Assert-Equal 2 $r.Counts.Unreadable 'Unreadable'
        Assert-Match $r.Unreadable[0].Error 'illisible' 'message'
        Assert-Equal 2 $r.Counts.Problems 'Problems'
    }

    Test-Case 'Test-KenshiModList : NotInPack et PackModsNotActive' {
        $r = Test-List 'extra.cfg' $pack
        Assert-Equal 1 $r.Counts.NotInPack 'NotInPack'
        Assert-Equal 'Local.mod' ($r.NotInPack -join ',') 'NotInPack nom'
        Assert-Equal 0 $r.Counts.PackModsNotActive 'PackModsNotActive'
        Assert-True (-not $r.IsClean) 'écart au pack = problème'
        $r2 = Test-List 'partial.cfg' $pack
        Assert-Equal 1 $r2.Counts.PackModsNotActive 'PackModsNotActive (partial)'
        Assert-Equal 'Gamma.mod' ($r2.PackModsNotActive -join '|') 'noms'
        $r3 = Test-List 'extra.cfg' ''
        Assert-True $r3.IsClean 'sans pack : propre'
    }

    Test-Case 'Test-KenshiModList : liste d''un seul mod, liste vide' {
        # Régression : Get-ActiveModList renvoyait une chaîne (une ligne) ou $null (fichier vide),
        # et le module échouait sur .Count en rendant un résultat IsClean sans compteurs.
        $r = Test-List 'single.cfg' ''
        Assert-Equal 1 $r.Counts.Active 'Active'
        Assert-True $r.IsClean 'IsClean'
        $r2 = Test-List 'clean.cfg' (Join-Path $lists 'single.cfg')
        Assert-Equal 1 $r2.Counts.Pack 'Pack d''un seul mod'
        Assert-Equal 2 $r2.Counts.NotInPack 'NotInPack'
        $r3 = Test-List 'empty.cfg' $pack
        Assert-Equal 0 $r3.Counts.Active 'Active (vide)'
        Assert-Equal 3 $r3.Counts.PackModsNotActive 'PackModsNotActive (vide)'
        Assert-True (-not $r3.IsClean) 'liste vide contre pack : pas propre'
        $r4 = Test-List 'single.cfg' (Join-Path $lists 'missing.cfg')
        Assert-Equal 'Nope.mod' ($r4.PackModsNotActive -join ',') 'un seul mod manquant du pack'
    }

    Test-Case 'Test-KenshiModList : .mod seulement en sous-dossier Workshop = introuvable' {
        $r = Test-List 'nested.cfg' ''
        Assert-Equal 1 $r.Counts.MissingFiles 'MissingFiles'
        Assert-Equal 1 $r.Counts.NestedFiles 'NestedFiles'
        Assert-Equal 'Nested.mod' $r.NestedFiles[0].Mod 'nom'
        Assert-Match $r.NestedFiles[0].Path '1010\\Sub\\Nested\.mod$' 'chemin du fichier en sous-dossier'
        Assert-True (-not $r.IsClean) 'IsClean'
    }

    Test-Case 'Test-KenshiModList : erreur interne levée, jamais IsClean partiel' {
        Assert-Throws { Test-KenshiModList -ModsCfg (Join-Path $lists 'nope.cfg') -Game $gameA -Workshop $ws } 'introuvable' 'liste absente'
        Assert-Throws { Test-KenshiModList -ModsCfg (Join-Path $lists 'clean.cfg') -PackCfg (Join-Path $lists 'nope.cfg') -Game $gameA -Workshop $ws } 'introuvable' 'pack absent'
    }

    Test-Case 'Test-KenshiModList : cumul des problèmes' {
        $r = Test-List 'problems.cfg' $pack
        $c = $r.Counts
        Assert-Equal 1 $c.MissingFiles 'MissingFiles'
        Assert-Equal 1 $c.Unreadable 'Unreadable'
        Assert-Equal 1 $c.AbsentDependencies 'AbsentDependencies'
        Assert-Equal 1 $c.InactiveDependencies 'InactiveDependencies'
        Assert-Equal 1 $c.LateDependencies 'LateDependencies'
        Assert-Equal 1 $c.DuplicateFiles 'DuplicateFiles'
        Assert-Equal 5 $c.NotInPack 'NotInPack'
        Assert-Equal 1 $c.PackModsNotActive 'PackModsNotActive'
        Assert-Equal 12 $c.Problems 'Problems'
    }

    Test-Case 'Test-KenshiModList : -ModIndex utilisé tel quel' {
        # play-kenshi.ps1 construit l'index une fois et le passe à la vérification puis à restore-modlist.ps1
        $index = Get-ModFileIndex -Folders @((Join-Path $gameA 'mods'), $ws)
        $r = Test-KenshiModList -ModsCfg (Join-Path $lists 'problems.cfg') -PackCfg $pack -Game $gameA -Workshop $ws -ModIndex $index
        $ref = Test-List 'problems.cfg' $pack
        Assert-Equal (@($ref.Counts.Values) -join ',') (@($r.Counts.Values) -join ',') 'mêmes compteurs qu''avec son propre parcours'
        $partial = @{}
        foreach ($k in $index.Keys) { if ($k -ne 'Alpha.mod') { $partial[$k] = $index[$k] } }
        $p = Test-KenshiModList -ModsCfg (Join-Path $lists 'clean.cfg') -Game $gameA -Workshop $ws -ModIndex $partial
        Assert-Equal 'Alpha.mod' ($p.MissingFiles -join ',') 'Alpha.mod absent de l''index fourni : introuvable, pas de nouveau parcours'
        Assert-Equal ($index.Count - 1) $p.Counts.FilesOnDisk 'FilesOnDisk vient de l''index fourni'
    }

    # --- module : Write-ModList ---------------------------------------------
    $writeDir = Join-Path $script:fixtures 'write\sub'
    $writeCfg = Join-Path $writeDir 'mods.cfg'

    Test-Case 'Write-ModList : création sans BOM, dossier créé' {
        $w = Write-ModList -Path $writeCfg -Lines @(' A.mod ', '', 'B.mod')
        Assert-True (Test-Path -LiteralPath $writeCfg) 'fichier écrit'
        Assert-True (-not $w.Existed) 'Existed'
        Assert-Null $w.Backup 'Backup'
        Assert-Equal 2 $w.Count 'Count'
        Assert-True (-not (Test-Bom $writeCfg)) 'pas de BOM'
        Assert-Equal 'A.mod|B.mod' ((Get-FileLines $writeCfg) -join '|') 'contenu nettoyé'
    }

    Test-Case 'Write-ModList : sauvegarde .bak de l''ancienne liste' {
        $w = Write-ModList -Path $writeCfg -Lines @('C.mod')
        Assert-True $w.Existed 'Existed'
        Assert-True ($w.Backup -and (Test-Path -LiteralPath $w.Backup)) 'Backup existe'
        Assert-Match $w.Backup '\.bak$' 'nom du .bak'
        Assert-Equal 'A.mod|B.mod' ((Get-FileLines $w.Backup) -join '|') 'contenu du .bak'
        Assert-Equal 'C.mod' ((Get-FileLines $writeCfg) -join '|') 'nouveau contenu'
        Assert-True (-not (Test-Bom $writeCfg)) 'pas de BOM'
    }

    Test-Case 'Write-ModList : -WhatIf n''écrit rien' {
        $baksBefore = @(Get-ChildItem -LiteralPath $writeDir -Filter '*.bak').Count
        $stamp = (Get-Item -LiteralPath $writeCfg).LastWriteTimeUtc
        Write-ModList -Path $writeCfg -Lines @('D.mod') -WhatIf | Out-Null
        Assert-Equal 'C.mod' ((Get-FileLines $writeCfg) -join '|') 'contenu inchangé'
        Assert-Equal $stamp (Get-Item -LiteralPath $writeCfg).LastWriteTimeUtc 'date inchangée'
        Assert-Equal $baksBefore @(Get-ChildItem -LiteralPath $writeDir -Filter '*.bak').Count 'aucun .bak supplémentaire'
    }

    Test-Case 'Write-ModList : fichier en lecture seule -> erreur, contenu intact' {
        # Régression : l'échec de WriteAllLines était ignoré et la fonction rendait Count = N.
        $fi = Get-Item -LiteralPath $writeCfg
        $fi.IsReadOnly = $true
        try {
            Assert-Throws { Write-ModList -Path $writeCfg -Lines @('E.mod') } 'Écriture impossible' 'erreur levée'
            Assert-Equal 'C.mod' ((Get-FileLines $writeCfg) -join '|') 'contenu inchangé'
        }
        finally { $fi.IsReadOnly = $false }
    }

    Test-Case 'Write-ModList : chemin relatif résolu sur $PWD, pas sur le répertoire du processus' {
        Push-Location -LiteralPath $script:fixtures
        try { $w = Write-ModList -Path 'write\rel\mods.cfg' -Lines @('R.mod') } finally { Pop-Location }
        $expected = Join-Path $script:fixtures 'write\rel\mods.cfg'
        Assert-True ($w.Path -ieq $expected) "chemin résolu ($($w.Path))"
        Assert-True (Test-Path -LiteralPath $expected) 'fichier sous le dossier courant de PowerShell'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path ([Environment]::CurrentDirectory) 'write\rel\mods.cfg'))) 'rien sous le répertoire du processus'
    }

    Test-Case 'Backup-File : noms uniques dans la même seconde, erreur si la copie échoue' {
        $src = Join-Path $script:fixtures 'write\tobackup.cfg'
        Write-TextFile $src @('X.mod')
        $b1 = Backup-File -Path $src
        $b2 = Backup-File -Path $src
        Assert-True ($b1 -ne $b2) "deux noms différents ($b1 / $b2)"
        Assert-True ((Test-Path -LiteralPath $b1) -and (Test-Path -LiteralPath $b2)) 'les deux copies existent'
        Assert-Match $b2 '-2\.bak$|\d{6}\.bak$' 'suffixe'
        Assert-Throws { Backup-File -Path (Join-Path $script:fixtures 'write\nexistepas.cfg') } 'Sauvegarde impossible' 'source absente'
    }

    # --- module : journaux ----------------------------------------------------
    Test-Case 'Get-KenshiLogSummary : comptages' {
        $s = Get-KenshiLogSummary -InfoLog (Join-Path $script:fixtures 'logs\kenshi_info.log') -PackCfg $pack
        Assert-Equal 3 $s.LoadedCount 'LoadedCount'
        Assert-Equal 'Alpha.mod|Beta.mod|Local.mod' ($s.LoadedMods -join '|') 'LoadedMods avec .mod'
        Assert-Equal 4 $s.ErrorCount 'ErrorCount'
        Assert-Equal 5 $s.WarningCount 'WarningCount'
        Assert-Equal 3 $s.PartMapCount 'PartMapCount'
        Assert-Equal 'Local.mod' ($s.ExtraMods -join ',') 'ExtraMods'
        Assert-Equal 'Gamma.mod' ($s.PackModsNotLoaded -join ',') 'PackModsNotLoaded'
        Assert-Equal 3 $s.PackCount 'PackCount'
        Assert-Equal 5 $s.Messages.Count 'messages distincts (hors Part map)'
        $top = $s.Messages[0]
        Assert-Equal 2 $top.Count 'message le plus fréquent'
        Assert-Equal 'Missing texture #.png' $top.Message 'nombres remplacés par #'
        Assert-Equal 'warning' $top.Level 'niveau'
        Assert-Equal 2 $s.ModsModifyingMissingItems.Count 'mods modifiant des objets inexistants'
        Assert-Equal 'Beta' $s.ModsModifyingMissingItems[0].Mod 'premier mod'
        Assert-Equal 2 $s.ModsModifyingMissingItems[0].Count 'compte Beta'
    }

    Test-Case 'Format-KenshiLogSummary : texte français' {
        $text = (Get-KenshiLogSummary -InfoLog (Join-Path $script:fixtures 'logs\kenshi_info.log') -PackCfg $pack | Format-KenshiLogSummary) -join "`n"
        Assert-Match $text 'Mods chargés : 3' 'mods chargés'
        Assert-Match $text 'hors liste du dépôt : 1' 'extras'
        Assert-Match $text 'Erreurs : 4 ; avertissements : 5 \(dont 3' 'erreurs'
        Assert-Match $text '\[warning\] Missing texture #\.png' 'message groupé'
        Assert-Match $text '2  Beta' 'mod objets inexistants'
    }

    Test-Case 'Get-KenshiLogSummary : pack introuvable -> avertissement, pas de comparaison affichée' {
        $s = Get-KenshiLogSummary -InfoLog (Join-Path $script:fixtures 'logs\kenshi_info.log') -PackCfg (Join-Path $lists 'nope.cfg') -WarningAction SilentlyContinue -WarningVariable warn
        Assert-Null $s.PackCfg 'PackCfg null'
        Assert-Null $s.PackCount 'PackCount null'
        Assert-Equal 3 $s.LoadedCount 'LoadedCount'
        Assert-True ($warn.Count -ge 1) 'avertissement émis'
        $text = ($s | Format-KenshiLogSummary) -join "`n"
        Assert-NotMatch $text 'hors liste du dépôt' 'pas de ligne de comparaison'
    }

    Test-Case 'Get-KenshiLogSummary / Open-KenshiLogReader : journal tenu ouvert en écriture (session en cours)' {
        # Régression : [IO.File]::ReadLines (partage lecture seule) échouait tant que le jeu ou WER
        # gardait le journal ouvert en écriture, et le résumé des mods et erreurs disparaissait.
        $log = Join-Path $script:fixtures 'logs\kenshi_info.log'
        $h = Open-WriterHandle $log
        try {
            $s = Get-KenshiLogSummary -InfoLog $log -PackCfg $pack
            Assert-Equal 3 $s.LoadedCount 'LoadedCount avec le fichier ouvert en écriture'
            Assert-Equal 4 $s.ErrorCount 'ErrorCount'
            $r = Open-KenshiLogReader -Path $log
            try { $n = 0; while ($null -ne $r.ReadLine()) { $n++ } } finally { $r.Dispose() }
            Assert-Equal 16 $n 'lignes lues par Open-KenshiLogReader'
        }
        finally { $h.Dispose() }
        Assert-Throws { Open-KenshiLogReader -Path (Join-Path $lists 'nope.log') } 'introuvable' 'journal absent'
    }

    Test-Case 'Read-KenshiMonitorLock / Set-KenshiMonitorLock : vivant, périmé (PID absent, réattribué, autre programme)' {
        $lockFile = Join-Path $script:fixtures 'locks\monitor.lock'
        New-Item -ItemType Directory -Path (Split-Path -Parent $lockFile) -Force | Out-Null
        Assert-Null (Read-KenshiMonitorLock -Path $lockFile) 'sans fichier : null'
        $deadline = (Get-Date).AddSeconds(600)
        Set-KenshiMonitorLock -Path $lockFile -Phase waiting -Deadline $deadline
        Assert-True (-not (Test-Bom $lockFile)) 'verrou sans BOM'
        $l = Read-KenshiMonitorLock -Path $lockFile
        Assert-True $l.IsLive "vivant pour ce processus ($($l.Reason))"
        Assert-Equal $PID $l.ProcessId 'ProcessId'
        Assert-Equal 'waiting' $l.Phase 'Phase'
        Assert-True ([math]::Abs(($l.Deadline - $deadline).TotalSeconds) -lt 1) 'Deadline relue'
        Assert-True ($null -ne $l.StartTime) 'StartTime renseigné'
        Set-KenshiMonitorLock -Path $lockFile -Phase finishing
        $f = Read-KenshiMonitorLock -Path $lockFile
        Assert-Equal 'finishing' $f.Phase 'phase finishing'
        Assert-Null $f.Deadline 'sans échéance'
        Assert-Throws { Set-KenshiMonitorLock -Path $lockFile -Phase sleeping } 'Phase inconnue' 'phase invalide'
        # PID absent
        Write-TextFile $lockFile @('999999;2026-01-01T00:00:00.0000000+01:00;waiting;')
        $a = Read-KenshiMonitorLock -Path $lockFile
        Assert-True (-not $a.IsLive) 'PID absent : périmé'
        Assert-Match $a.Reason 'absent' 'raison PID absent'
        # Ce processus, mais une autre date de création : PID réattribué
        Write-TextFile $lockFile @("$PID;2020-01-01T00:00:00.0000000+01:00;waiting;")
        $r = Read-KenshiMonitorLock -Path $lockFile
        Assert-True (-not $r.IsLive) 'date de création différente : périmé'
        Assert-Match $r.Reason 'réattribué' 'raison PID réattribué'
        # PID d'un autre programme
        $foreign = Get-ForeignPid
        if ($foreign -gt 0) {
            Write-TextFile $lockFile @("$foreign")
            $o = Read-KenshiMonitorLock -Path $lockFile
            Assert-True (-not $o.IsLive) "PID d'un autre programme ($foreign) : périmé"
            Assert-True ($o.Reason -ne '') 'raison donnée'
        }
        # Sans date valide, même un PowerShell vivant n'est pas identifié.
        Write-TextFile $lockFile @("$PID")
        Assert-True (-not (Read-KenshiMonitorLock -Path $lockFile).IsLive) 'PID seul de ce PowerShell : périmé'
        Write-TextFile $lockFile @("$PID;date-invalide;waiting;")
        $invalid = Read-KenshiMonitorLock -Path $lockFile
        Assert-True (-not $invalid.IsLive) 'date illisible : périmé'
        Assert-Match $invalid.Reason 'date de création' 'raison de refus de la date'
        Write-TextFile $lockFile @('pas un nombre')
        Assert-True (-not (Read-KenshiMonitorLock -Path $lockFile).IsLive) 'contenu illisible : périmé'
    }

    Test-Case 'Get-KenshiCrashEvents : date de création Windows hexadécimale, décimale ou invalide' {
        $created = (Get-Date).AddMinutes(-2)
        $startedValues = @(('0x' + $created.ToFileTime().ToString('x')), $created.ToFileTime().ToString(), 'date-invalide')
        $mockEvents = @()
        for ($i = 0; $i -lt $startedValues.Count; $i++) {
            $values = @('kenshi_x64.exe', '1.0.68', '', 'game.dll', '1', '', 'c0000005', '1234', '100', $startedValues[$i], 'C:\fake\kenshi_x64.exe', 'C:\fake\game.dll', 'report')
            $mockEvents += [pscustomobject]@{
                Properties = @($values | ForEach-Object { [pscustomobject]@{ Value = $_ } })
                Message = ''; TimeCreated = (Get-Date).AddSeconds($i); RecordId = $i + 1
            }
        }
        $parsed = @(& (Get-Module KenshiTools) {
            param($MockEvents)
            function Get-WinEvent { param($FilterHashtable, $ErrorAction) $MockEvents }
            Get-KenshiCrashEvents -Since (Get-Date).AddHours(-1)
        } $mockEvents)
        Assert-Equal 3 $parsed.Count 'événements conservés'
        Assert-True ([math]::Abs(($parsed[0].ProcessStartTime - $created).TotalSeconds) -lt 0.001) 'FILETIME hexadécimal'
        Assert-True ([math]::Abs(($parsed[1].ProcessStartTime - $created).TotalSeconds) -lt 0.001) 'FILETIME décimal'
        Assert-Null $parsed[2].ProcessStartTime 'date invalide ignorée'
        Assert-Equal 100 $parsed[0].ProcessId 'PID conservé'
    }

    Test-Case 'Get-KenshiSessions : heures non complétées, minuit, session sans Exit.' {
        $s = @(Get-KenshiSessions -SaveLog (Join-Path $script:fixtures 'logs\save-sessions.log'))
        Assert-Equal 3 $s.Count 'nombre de sessions'
        Assert-Equal '01:03:52' $s[0].StartTime 'StartTime normalisé (1:3:52)'
        Assert-Equal '01:15:30' $s[0].ExitTime 'ExitTime'
        Assert-True $s[0].HasExit 'HasExit'
        Assert-Equal '00:11:38' $s[0].Duration.ToString() 'Duration'
        Assert-Equal 3 $s[0].SaveCount 'SaveCount'
        Assert-Equal 2 $s[0].SavedPaths.Count 'SavedPaths distincts'
        Assert-Equal '01:10:00' $s[0].Saves[0].Time 'heure de sauvegarde (1:10:0)'
        Assert-Match $s[0].Saves[0].Path 'UR1$' 'chemin de sauvegarde'
        Assert-Equal '00:15:00' $s[1].Duration.ToString() 'Duration à cheval sur minuit'
        Assert-Equal 1 $s[1].WarningCount 'WarningCount'
        Assert-Equal 1 $s[1].ErrorCount 'ErrorCount'
        Assert-True (-not $s[2].HasExit) 'dernière session sans Exit.'
        Assert-Null $s[2].ExitTime 'ExitTime null'
        Assert-Null $s[2].Duration 'Duration null'
        Assert-Equal 1 $s[2].SaveCount 'SaveCount dernière session'
        Assert-Equal 11 $s[2].StartLine 'StartLine'
    }

    # --- scripts : restore-modlist.ps1 --------------------------------------
    Write-Host ''
    Write-Host 'Scripts (processus enfant)' -ForegroundColor Cyan
    $restore = Join-Path $tools 'restore-modlist.ps1'
    $scan = Join-Path $tools 'scan-mods.ps1'
    $summarize = Join-Path $tools 'summarize-logs.ps1'
    $health = Join-Path $tools 'health-check.ps1'
    $play = Join-Path $tools 'play-kenshi.ps1'
    $update = Join-Path $tools 'update-pack.ps1'
    $monitor = Join-Path $tools 'kenshi-monitor.ps1'
    $liveR = Join-Path $gameR 'data\mods.cfg'
    function Get-BakCount([string]$Dir) { @(Get-ChildItem -LiteralPath $Dir -Filter '*.bak' -File).Count }

    if ($kenshiRunning) {
        Skip-Case 'restore-modlist.ps1 : restauration normale' 'Kenshi tourne'
        Skip-Case 'restore-modlist.ps1 : fichier .mod manquant -> arrêt' 'Kenshi tourne'
        Skip-Case 'restore-modlist.ps1 : -Force' 'Kenshi tourne'
        Skip-Case 'restore-modlist.ps1 : -WhatIf' 'Kenshi tourne'
        Skip-Case 'restore-modlist.ps1 : -ModIndex utilisé tel quel' 'Kenshi tourne'
        Skip-Case 'restore-modlist.ps1 : mods.cfg en lecture seule -> 1, rien d''annoncé' 'Kenshi tourne'
        Skip-Case 'restore-modlist.ps1 : source vide, -Game invalide -> 1' 'Kenshi tourne'
    }
    else {
        Test-Case 'restore-modlist.ps1 : mods.cfg en lecture seule -> 1, rien d''annoncé' {
            # Régression : l'échec d'écriture était ignoré et le script annonçait « restauré » avec le code 0.
            $fi = Get-Item -LiteralPath $liveR
            $fi.IsReadOnly = $true
            try {
                $r = Invoke-Tool $restore @{ Game = $gameR; Workshop = $ws; Source = $pack }
                Assert-Equal 1 $r.ExitCode 'code de sortie'
                Assert-Match ($r.Output + $r.Errors) 'non restaurée' 'message d''échec'
                Assert-NotMatch $r.Output 'restauré :' 'aucune annonce de succès'
                Assert-Equal 'Alpha.mod|Zzz.mod' ((Get-FileLines $liveR) -join '|') 'mods.cfg inchangé'
            }
            finally {
                $fi.IsReadOnly = $false
                # Le .bak créé avant l'échec d'écriture est retiré pour ne pas fausser les comptes suivants
                Get-ChildItem -LiteralPath (Join-Path $gameR 'data') -Filter '*.bak' -File | Remove-Item -Force
            }
        }

        Test-Case 'restore-modlist.ps1 : source vide, -Game invalide -> 1' {
            $r = Invoke-Tool $restore @{ Game = $gameR; Workshop = $ws; Source = (Join-Path $lists 'empty.cfg') }
            Assert-Equal 1 $r.ExitCode 'source vide : code de sortie'
            Assert-Match ($r.Output + $r.Errors) 'vide' 'source vide : message'
            Assert-Equal 'Alpha.mod|Zzz.mod' ((Get-FileLines $liveR) -join '|') 'source vide : mods.cfg inchangé'
            $typo = Join-Path $script:fixtures 'gmae'
            $t = Invoke-Tool $restore @{ Game = $typo; Workshop = $ws; Source = $pack }
            Assert-Equal 1 $t.ExitCode '-Game invalide : code de sortie'
            Assert-Match ($t.Output + $t.Errors) 'Dossier du jeu invalide' '-Game invalide : message'
            Assert-True (-not (Test-Path -LiteralPath $typo)) '-Game invalide : aucune arborescence créée'
        }

        Test-Case 'restore-modlist.ps1 : restauration normale' {
            $r = Invoke-Tool $restore @{ Game = $gameR; Workshop = $ws; Source = $pack }
            Assert-Equal 0 $r.ExitCode "code de sortie ($($r.Errors))"
            Assert-Equal 'Alpha.mod|Beta.mod|Gamma.mod' ((Get-FileLines $liveR) -join '|') 'mods.cfg restauré'
            Assert-True (-not (Test-Bom $liveR)) 'pas de BOM'
            Assert-Equal 1 (Get-BakCount (Join-Path $gameR 'data')) 'un .bak'
            $bak = Get-ChildItem -LiteralPath (Join-Path $gameR 'data') -Filter '*.bak' | Select-Object -First 1
            Assert-Equal 'Alpha.mod|Zzz.mod' ((Get-FileLines $bak.FullName) -join '|') 'contenu du .bak'
            Assert-Match $r.Output 'restauré : 3 mods' 'message'
        }

        Test-Case 'restore-modlist.ps1 : fichier .mod manquant -> arrêt' {
            $r = Invoke-Tool $restore @{ Game = $gameR; Workshop = $ws; Source = (Join-Path $lists 'missing.cfg') }
            Assert-Equal 1 $r.ExitCode 'code de sortie'
            Assert-Equal 'Alpha.mod|Beta.mod|Gamma.mod' ((Get-FileLines $liveR) -join '|') 'mods.cfg inchangé'
            Assert-Equal 1 (Get-BakCount (Join-Path $gameR 'data')) 'aucun .bak supplémentaire'
            Assert-Match ($r.Output + $r.Errors) 'Nope\.mod' 'mod manquant listé'
            Assert-Match ($r.Output + $r.Errors) 'Restauration annulée' 'message d''annulation'
            $n = Invoke-Tool $restore @{ Game = $gameR; Workshop = $ws; Source = (Join-Path $lists 'nested.cfg') }
            Assert-Equal 1 $n.ExitCode '.mod en sous-dossier Workshop : refusé'
            Assert-Match ($n.Output + $n.Errors) 'Nested\.mod' '.mod en sous-dossier listé'
        }

        Test-Case 'restore-modlist.ps1 : -Force' {
            $r = Invoke-Tool $restore @{ Game = $gameR; Workshop = $ws; Source = (Join-Path $lists 'missing.cfg') } @('Force')
            Assert-Equal 0 $r.ExitCode "code de sortie ($($r.Errors))"
            Assert-Equal 'Alpha.mod|Nope.mod' ((Get-FileLines $liveR) -join '|') 'mods.cfg écrit malgré le manque'
            Assert-Equal 2 (Get-BakCount (Join-Path $gameR 'data')) 'deuxième .bak'
        }

        Test-Case 'restore-modlist.ps1 : -WhatIf' {
            $r = Invoke-Tool $restore @{ Game = $gameR; Workshop = $ws; Source = $pack } @('WhatIf')
            Assert-Equal 0 $r.ExitCode "code de sortie ($($r.Errors))"
            Assert-Equal 'Alpha.mod|Nope.mod' ((Get-FileLines $liveR) -join '|') 'mods.cfg inchangé'
            Assert-Equal 2 (Get-BakCount (Join-Path $gameR 'data')) 'aucun .bak supplémentaire'
            Assert-Match $r.Output 'WhatIf' 'message'
        }

        Test-Case 'restore-modlist.ps1 : -ModIndex utilisé tel quel' {
            # Les 3 mods du pack sont sur le disque, mais pas dans l'index fourni : le script s'y fie sans reparcourir
            $r = Invoke-Tool $restore @{ Game = $gameR; Workshop = $ws; Source = $pack } @('WhatIf') -RawArguments '-ModIndex @{}'
            Assert-Equal 1 $r.ExitCode 'code de sortie'
            Assert-Match ($r.Output + $r.Errors) 'introuvables sur le disque .*: 3' 'les 3 mods absents de l''index'
            Assert-Equal 'Alpha.mod|Nope.mod' ((Get-FileLines $liveR) -join '|') 'mods.cfg inchangé'
            Assert-Equal 2 (Get-BakCount (Join-Path $gameR 'data')) 'aucun .bak supplémentaire'
        }
    }

    # --- scripts : scan-mods.ps1 --------------------------------------------
    Test-Case 'scan-mods.ps1 : liste propre -> 0' {
        $r = Invoke-Tool $scan @{ Game = $gameA; Workshop = $ws; ModsCfg = (Join-Path $lists 'clean.cfg'); PackCfg = $pack }
        Assert-Equal 0 $r.ExitCode "code de sortie ($($r.Errors))"
        Assert-Match $r.Output 'OK : aucun problème' 'message'
    }

    Test-Case 'scan-mods.ps1 : problèmes -> 2 (et -Json)' {
        $r = Invoke-Tool $scan @{ Game = $gameA; Workshop = $ws; ModsCfg = (Join-Path $lists 'problems.cfg'); PackCfg = $pack } @('Json')
        Assert-Equal 2 $r.ExitCode 'code de sortie'
        $j = $r.Output | ConvertFrom-Json
        Assert-Equal 12 $j.Counts.Problems 'Problems (JSON)'
        Assert-Equal 1 $j.Counts.MissingFiles 'MissingFiles (JSON)'
        Assert-Equal 1 $j.Counts.LateDependencies 'LateDependencies (JSON)'
        Assert-Equal 1 $j.Counts.DuplicateFiles 'DuplicateFiles (JSON)'
        $t = Invoke-Tool $scan @{ Game = $gameA; Workshop = $ws; ModsCfg = (Join-Path $lists 'problems.cfg'); PackCfg = $pack }
        Assert-Equal 2 $t.ExitCode 'code de sortie (texte)'
        Assert-Match $t.Output 'Problèmes : 12' 'total texte'
        Assert-Match $t.Output 'Nope\.mod' 'fichier manquant listé'
    }

    Test-Case 'scan-mods.ps1 : écart au pack seul -> 2, sans pack -> 0' {
        $r = Invoke-Tool $scan @{ Game = $gameA; Workshop = $ws; ModsCfg = (Join-Path $lists 'extra.cfg'); PackCfg = $pack }
        Assert-Equal 2 $r.ExitCode 'avec pack'
        $r2 = Invoke-Tool $scan @{ Game = $gameA; Workshop = $ws; ModsCfg = (Join-Path $lists 'extra.cfg'); PackCfg = '' }
        Assert-Equal 0 $r2.ExitCode "sans pack ($($r2.Errors))"
    }

    Test-Case 'scan-mods.ps1 : liste introuvable -> 1' {
        $r = Invoke-Tool $scan @{ Game = $gameA; Workshop = $ws; ModsCfg = (Join-Path $lists 'nope.cfg'); PackCfg = $pack }
        Assert-Equal 1 $r.ExitCode 'code de sortie'
        Assert-Match ($r.Output + $r.Errors) 'introuvable' 'message'
    }

    Test-Case 'scan-mods.ps1 : liste d''un seul mod absent -> 2, liste vide -> 0 sans pack' {
        # Régression : une liste d'une ligne donnait des erreurs « Count » puis « OK : aucun problème » et le code 0.
        $one = Join-Path $lists 'single-missing.cfg'
        Write-TextFile $one @('Nope.mod')
        $r = Invoke-Tool $scan @{ Game = $gameA; Workshop = $ws; ModsCfg = $one; PackCfg = '' }
        Assert-Equal 2 $r.ExitCode "code de sortie ($($r.Errors))"
        Assert-Match $r.Output 'Fichiers \.mod introuvables : 1' 'fichier manquant compté'
        Assert-NotMatch ($r.Output + $r.Errors) 'Count' 'aucune erreur de propriété'
        $e = Invoke-Tool $scan @{ Game = $gameA; Workshop = $ws; ModsCfg = (Join-Path $lists 'empty.cfg'); PackCfg = '' }
        Assert-Equal 0 $e.ExitCode "liste vide sans pack ($($e.Errors))"
        Assert-Match $e.Output '0 mods actifs' 'liste vide comptée'
        $n = Invoke-Tool $scan @{ Game = $gameA; Workshop = $ws; ModsCfg = (Join-Path $lists 'nested.cfg'); PackCfg = '' }
        Assert-Equal 2 $n.ExitCode '.mod en sous-dossier -> 2'
        Assert-Match $n.Output 'sous-dossier Workshop' '.mod en sous-dossier signalé'
    }

    # --- scripts : summarize-logs.ps1 ---------------------------------------
    Test-Case 'summarize-logs.ps1 : session terminée proprement -> 0' {
        $out = Join-Path $script:fixtures 'reports\resume-A.md'
        $r = Invoke-Tool $summarize @{ Game = $gameA; PackCfg = $pack; Top = 5; OutFile = $out } @('SkipWindowsCrashReports')
        Assert-True (Test-Path -LiteralPath $out) 'rapport écrit'
        $md = Get-FileText $out
        Assert-True (-not (Test-Bom $out)) 'rapport sans BOM'
        Assert-Match $md '## Dernière session' 'section session'
        Assert-Match $md 'Session 3 sur 3' 'dernière session'
        Assert-Match $md 'Exit\. » à \d{2}:\d{2}:\d{2}, durée 00:30:00' 'heure de sortie et durée'
        Assert-NotMatch $md 'Passages différents' 'même passage dans les deux journaux'
        Assert-Match $md 'moins d''une minute et demie' 'journaux tout frais signalés'
        Assert-Match $md 'Version : 1\.0\.68' 'version'
        Assert-Match $md 'Mods chargés : 3' 'mods chargés'
        Assert-Match $md 'hors liste du pack : 1' 'extras'
        Assert-Match $md 'Erreurs : 4' 'erreurs'
        Assert-Match $md 'dont 3 « Part map' 'part map'
        Assert-Match $md 'Missing texture #\.png' 'message groupé'
        Assert-Match $md '\| 2 \| Beta \|' 'mod objets inexistants'
        Assert-Match $md 'OGRE Shutdown »\) : présente' 'séquence OGRE'
        Assert-Match $md 'Exceptions OGRE : 1 ; erreurs de compilation.* : 1 ; avertissements : 1' 'comptes OGRE'
        Assert-Match $md 'something \\\| with a pipe' 'barre verticale échappée'
        if ($kenshiRunning) { Assert-Match $md 'en cours d' 'jeu en cours' }
        else {
            Assert-Equal 0 $r.ExitCode "code de sortie ($($r.Errors))"
            Assert-Match $md 'aucun signe de plantage' 'conclusion'
        }
    }

    Test-Case 'summarize-logs.ps1 : sans kenshi_info.log, session sans Exit. -> 2' {
        $out = Join-Path $script:fixtures 'reports\resume-B.md'
        $r = Invoke-Tool $summarize @{ Game = $gameB; PackCfg = ''; OutFile = $out } @('SkipWindowsCrashReports')
        $md = Get-FileText $out
        Assert-Match $md 'kenshi_info\.log : absent' 'journal absent'
        Assert-Match $md 'date déduite' 'début déduit de save.log'
        Assert-Match $md 'comparaison désactivée' 'pack désactivé'
        if ($kenshiRunning) { Assert-Match $md 'session en cours' 'jeu en cours' }
        else {
            Assert-Equal 2 $r.ExitCode 'code de sortie'
            Assert-Match $md 'arrêt brutal' 'arrêt brutal'
            Assert-Match $md 'signes de plantage' 'conclusion'
        }
    }

    Test-Case 'summarize-logs.ps1 : aucun journal -> 1' {
        $empty = Join-Path $script:fixtures 'empty-game'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        $r = Invoke-Tool $summarize @{ Game = $empty; PackCfg = '' } @('SkipWindowsCrashReports')
        Assert-Equal 1 $r.ExitCode 'code de sortie'
        Assert-Match ($r.Output + $r.Errors) 'Aucun journal' 'message'
    }

    Test-Case 'summarize-logs.ps1 : -OutFile relatif écrit sous le dossier courant de PowerShell' {
        # Régression : .NET résolvait le chemin sur le répertoire du processus, le rapport n'était pas écrit
        # et le script affichait quand même « Rapport écrit ».
        $r = Invoke-Tool $summarize @{ Game = $gameA; PackCfg = ''; OutFile = 'reports\rel-test.md' } @('SkipWindowsCrashReports') $script:fixtures
        $expected = Join-Path $script:fixtures 'reports\rel-test.md'
        Assert-True (Test-Path -LiteralPath $expected) "rapport sous le dossier courant ($expected)"
        Assert-Match $r.Output ([regex]::Escape($expected)) 'chemin absolu affiché'
        Assert-Equal 'Alpha.mod' ((Get-FileLines (Join-Path $gameA 'data\mods.cfg'))[0]) 'faux jeu intact'
        # Dossier de sortie impossible à créer (un fichier porte ce nom) : code 1, pas de « Rapport écrit »
        $blocker = Join-Path $script:fixtures 'reports\blocker'
        Write-TextFile $blocker @('x')
        $f = Invoke-Tool $summarize @{ Game = $gameA; PackCfg = ''; OutFile = (Join-Path $blocker 'x.md') } @('SkipWindowsCrashReports')
        Assert-Equal 1 $f.ExitCode 'code de sortie si le rapport ne peut pas être écrit'
        Assert-Match ($f.Output + $f.Errors) 'Rapport non écrit' 'message d''échec'
        Assert-NotMatch $f.Output 'Rapport écrit' 'pas d''annonce de succès'
    }

    Test-Case 'summarize-logs.ps1 : kenshi_info.log d''un passage arrêté au lanceur -> passages différents' {
        $out = Join-Path $script:fixtures 'reports\resume-L.md'
        $r = Invoke-Tool $summarize @{ Game = $gameL; PackCfg = ''; OutFile = $out } @('SkipWindowsCrashReports')
        $md = Get-FileText $out
        Assert-Match $md 'Passages différents' 'passages distingués'
        Assert-Match $md 'plus récent' 'kenshi_info.log est bien le plus récent'
        Assert-Match $md 'arrêté au lanceur' 'raison'
        Assert-Match $md 'Recherche depuis .*passage antérieur' 'recherche depuis le début de save.log'
        Assert-Match $md 'Session 3 sur 3' 'dernière session de save.log'
    }

    Test-Case 'summarize-logs.ps1 : lanceur resté ouvert 20 min avant Play -> même passage' {
        # Régression : l'écart était mesuré depuis « Kenshi start » (15 min) et non depuis « Launching game »
        $out = Join-Path $script:fixtures 'reports\resume-W.md'
        $r = Invoke-Tool $summarize @{ Game = $gameW; PackCfg = $pack; OutFile = $out } @('SkipWindowsCrashReports')
        $md = Get-FileText $out
        Assert-NotMatch $md 'Passages différents' 'même passage malgré 20 min de lanceur'
        Assert-Match $md 'Session 3 sur 3' 'dernière session'
        Assert-Match $md 'Début : \d{2}:\d{2}:\d{2} \(kenshi_info\.log' 'début daté par kenshi_info.log'
        Assert-Match $md 'Mods chargés : 3' 'mods chargés'
        if (-not $kenshiRunning) { Assert-Equal 0 $r.ExitCode "code de sortie ($($r.Errors))" }
    }

    Test-Case 'summarize-logs.ps1 : journaux tenus ouverts en écriture par le jeu -> lus quand même' {
        # Régression : kenshi.log et kenshi_info.log ouverts par le jeu (session en cours) ou WER rendaient
        # le rapport sans mods ni erreurs, avec « 0 lignes » et « ne s'est pas fermé proprement »
        $out = Join-Path $script:fixtures 'reports\resume-locked.md'
        $h1 = Open-WriterHandle (Join-Path $gameA 'kenshi_info.log')
        $h2 = Open-WriterHandle (Join-Path $gameA 'kenshi.log')
        try { $r = Invoke-Tool $summarize @{ Game = $gameA; PackCfg = $pack; OutFile = $out } @('SkipWindowsCrashReports') }
        finally { $h1.Dispose(); $h2.Dispose() }
        $md = Get-FileText $out
        Assert-NotMatch ($r.Output + $r.Errors) 'illisible|being used by another process|utilisé par un autre processus' 'aucune erreur de partage'
        Assert-Match $md 'Mods chargés : 3' 'mods chargés malgré le fichier ouvert'
        Assert-Match $md 'Erreurs : 4' 'erreurs comptées'
        Assert-Match $md '5 lignes, de 10:00:01 à 10:05:00' 'kenshi.log lu en entier'
        Assert-Match $md 'OGRE Shutdown »\) : présente' 'séquence OGRE vue'
    }

    # --- scripts : health-check.ps1 -----------------------------------------
    # health-check.ps1 n'a pas de -Workshop : le faux jeu H porte ses mods dans jeu\mods.
    Test-Case 'health-check.ps1 : -Json sur le faux jeu' {
        $r = Invoke-Tool $health @{ Game = $gameH; PackCfg = $pack } @('Json')
        $j = $r.Output | ConvertFrom-Json
        function Get-Check([string]$Name) {
            $c = @($j.Checks | Where-Object { $_.Check -eq $Name })
            if ($c.Count -ne 1) { throw "contrôle « $Name » absent du JSON (contrôles : $(@($j.Checks | ForEach-Object { $_.Check }) -join ', '))" }
            $c[0]
        }
        Assert-Equal 'OK' (Get-Check 'Dossier du jeu').Status 'Dossier du jeu'
        Assert-Equal 'OK' (Get-Check 'Version').Status 'Version'
        Assert-Match (Get-Check 'Version').Detail '1\.0\.68' 'Version détail'
        Assert-Equal 'OK' (Get-Check 'Liste de mods').Status 'Liste de mods'
        Assert-Match (Get-Check 'Liste de mods').Detail '^3 mods actifs, identique' 'Liste de mods détail'
        Assert-Equal 'OK' (Get-Check 'Dépendances').Status 'Dépendances'
        Assert-Equal 'OK' (Get-Check 'RE_Kenshi').Status 'RE_Kenshi'
        Assert-Match (Get-Check 'RE_Kenshi').Detail 'RE_Kenshi\.dll' 'RE_Kenshi détail'
        Assert-NotMatch $r.Output 'subscribedby' 'identifiant de compte absent'
        Assert-NotMatch $r.Output '7656119\d{10}' 'SteamID64 absent'
        $expected = 0; if ([int]$j.Summary.ECHEC -gt 0) { $expected = 1 }
        Assert-Equal $expected $j.ExitCode 'ExitCode cohérent avec le résumé'
        Assert-Equal $expected $r.ExitCode 'code de sortie du processus'
    }

    Test-Case 'health-check.ps1 : mods.cfg hors pack et dépendances -> ECHEC' {
        $r = Invoke-Tool $health @{ Game = $gameB; PackCfg = $pack } @('Json')
        $j = $r.Output | ConvertFrom-Json
        $list = @($j.Checks | Where-Object { $_.Check -eq 'Liste de mods' })[0]
        $deps = @($j.Checks | Where-Object { $_.Check -eq 'Dépendances' })[0]
        Assert-Equal 'ECHEC' $list.Status 'Liste de mods'
        Assert-Match $list.Detail '1 hors pack, 2 du pack non activés' 'détail liste'
        Assert-Equal 'ECHEC' $deps.Status 'Dépendances'
        Assert-Match $deps.Detail 'fichiers introuvables : 1' 'détail dépendances'
        Assert-Equal 1 $r.ExitCode 'code de sortie'
        $t = Invoke-Tool $health @{ Game = $gameB; PackCfg = $pack }
        Assert-Equal 1 $t.ExitCode 'code de sortie (texte)'
        Assert-Match $t.Output 'Bilan de santé' 'en-tête texte'
        Assert-Match $t.Output 'Au moins un ECHEC' 'conclusion texte'
    }

    Test-Case 'health-check.ps1 : -PackCfg '''' désactive la comparaison, -Workshop accepté' {
        $r = Invoke-Tool $health @{ Game = $gameA; Workshop = $ws; PackCfg = '' } @('Json')
        $j = $r.Output | ConvertFrom-Json
        $packCheck = @($j.Checks | Where-Object { $_.Check -eq 'Liste du pack' })[0]
        Assert-Match $packCheck.Detail 'comparaison désactivée' 'liste du pack désactivée'
        $deps = @($j.Checks | Where-Object { $_.Check -eq 'Dépendances' })[0]
        Assert-Equal 'OK' $deps.Status 'dépendances vérifiées avec le faux Workshop'
        $list = @($j.Checks | Where-Object { $_.Check -eq 'Liste de mods' })[0]
        Assert-Match $list.Detail 'pas de liste de référence' 'liste de mods sans référence'
    }

    # --- scripts : kenshi-monitor.ps1 (sans jeu : délai d'attente et verrou) -------------
    $monOut = Join-Path $script:fixtures 'sessions'
    $monLock = Join-Path $monOut 'monitor.lock'
    if ($kenshiRunning) {
        Skip-Case 'kenshi-monitor.ps1 : -WaitTimeoutSec sans jeu -> fin propre, verrou retiré' 'Kenshi tourne'
        Skip-Case 'kenshi-monitor.ps1 : moniteur déjà actif (monitor.lock) -> refus' 'Kenshi tourne'
        Skip-Case 'kenshi-monitor.ps1 : verrou périmé (PID absent ou réattribué) -> remplacé' 'Kenshi tourne'
    }
    else {
        Test-Case 'kenshi-monitor.ps1 : -WaitTimeoutSec sans jeu -> fin propre, verrou retiré' {
            $r = Invoke-Tool $monitor @{ Game = $gameA; OutDir = $monOut; WaitTimeoutSec = 1 } @('Once')
            Assert-Equal 0 $r.ExitCode "code de sortie ($($r.Errors))"
            Assert-Match $r.Output 'pas démarré dans le délai' 'message de délai'
            Assert-True (-not (Test-Path -LiteralPath $monLock)) 'verrou supprimé'
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $monOut -Directory).Count 'aucun dossier de session'
            Assert-Equal $sessionsBefore (Get-SessionsSnapshot) 'logs\sessions du dépôt inchangé'
        }

        Test-Case 'kenshi-monitor.ps1 : moniteur déjà actif (monitor.lock) -> refus' {
            New-Item -ItemType Directory -Path $monOut -Force | Out-Null
            Set-KenshiMonitorLock -Path $monLock -Phase waiting   # ce lanceur de tests joue le moniteur vivant
            try {
                $r = Invoke-Tool $monitor @{ Game = $gameA; OutDir = $monOut; WaitTimeoutSec = 1 } @('Once')
                Assert-Equal 1 $r.ExitCode 'code de sortie'
                Assert-Match ($r.Output + $r.Errors) 'tourne déjà' 'message'
                Assert-Match ($r.Output + $r.Errors) '-Stop' 'conseil -Stop plutôt que Stop-Process aveugle'
                Assert-NotMatch ($r.Output + $r.Errors) 'Stop-Process' 'pas de Stop-Process aveugle'
                Assert-Match (Get-FileText $monLock) "^$PID;" 'verrou de l''autre moniteur conservé'
            }
            finally { Remove-Item -LiteralPath $monLock -Force -ErrorAction SilentlyContinue }
        }

        Test-Case 'kenshi-monitor.ps1 : verrou périmé (PID absent ou réattribué) -> remplacé' {
            # Régression : seul l'existence du PID était vérifiée ; un moniteur tué (Stop-Process saute le
            # finally) laissait un verrou qui, PID réattribué, bloquait tout nouveau moniteur.
            New-Item -ItemType Directory -Path $monOut -Force | Out-Null
            Write-TextFile $monLock @('999999')
            $s = Invoke-Tool $monitor @{ Game = $gameA; OutDir = $monOut; WaitTimeoutSec = 1 } @('Once')
            Assert-Equal 0 $s.ExitCode 'PID absent : verrou périmé ignoré'
            Assert-Match ($s.Output + $s.Errors) 'périmé' 'avertissement verrou périmé'
            Assert-True (-not (Test-Path -LiteralPath $monLock)) 'verrou retiré à la fin'
            $foreign = Get-ForeignPid
            if ($foreign -gt 0) {
                Write-TextFile $monLock @("$foreign;2020-01-01T00:00:00.0000000+01:00;waiting;")
                $f = Invoke-Tool $monitor @{ Game = $gameA; OutDir = $monOut; WaitTimeoutSec = 1 } @('Once')
                Assert-Equal 0 $f.ExitCode "PID réattribué ($foreign) : verrou périmé ignoré ($($f.Errors))"
                Assert-Match ($f.Output + $f.Errors) 'périmé' 'avertissement'
            }
        }
    }

    Test-Case 'kenshi-monitor.ps1 -Stop : sans verrou ou verrou périmé -> rien à arrêter, verrou supprimé' {
        # -Stop sur un verrou vivant tuerait ce lanceur de tests : seuls les cas sans processus sont exercés
        New-Item -ItemType Directory -Path $monOut -Force | Out-Null
        Remove-Item -LiteralPath $monLock -Force -ErrorAction SilentlyContinue
        $n = Invoke-Tool $monitor @{ OutDir = $monOut } @('Stop')
        Assert-Equal 0 $n.ExitCode "sans verrou ($($n.Errors))"
        Assert-Match $n.Output 'Aucun verrou' 'message sans verrou'
        Write-TextFile $monLock @('999999;2026-01-01T00:00:00.0000000+01:00;finishing;')
        $s = Invoke-Tool $monitor @{ OutDir = $monOut } @('Stop')
        Assert-Equal 0 $s.ExitCode "verrou périmé ($($s.Errors))"
        Assert-Match $s.Output 'périmé supprimé' 'message verrou périmé'
        Assert-True (-not (Test-Path -LiteralPath $monLock)) 'verrou supprimé'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $monOut -Directory).Count 'aucun dossier de session créé'
    }

    Test-Case 'kenshi-monitor.ps1 -Stop : date absente ou invalide -> PowerShell vivant conservé' {
        # Processus jetable appartenant au test : une régression ne tuerait pas le lanceur.
        $target = Start-Process -FilePath $hostExe -ArgumentList '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 30"' -WindowStyle Hidden -PassThru
        try {
            foreach ($contents in @("$($target.Id)", "$($target.Id);date-invalide;waiting;")) {
                Write-TextFile $monLock @($contents)
                $r = Invoke-Tool $monitor @{ OutDir = $monOut } @('Stop')
                Assert-Equal 0 $r.ExitCode "verrou non vérifiable ($($r.Errors))"
                Assert-Match $r.Output 'périmé supprimé' 'verrou traité comme périmé'
                $target.Refresh()
                Assert-True (-not $target.HasExited) 'PowerShell sans identité vérifiée conservé'
                Assert-True (-not (Test-Path -LiteralPath $monLock)) 'verrou périmé supprimé'
            }
        }
        finally {
            if (-not $target.HasExited) { Stop-Process -InputObject $target -Force -ErrorAction SilentlyContinue }
            $target.Dispose()
        }
    }

    # --- scripts : play-kenshi.ps1 -DryRun ----------------------------------
    $liveA = Join-Path $gameA 'data\mods.cfg'
    $playCopy = Join-Path $repoCopy 'tools\play-kenshi.ps1'
    $copyLock = Join-Path $repoCopy 'logs\sessions\monitor.lock'
    if ($kenshiRunning) {
        Skip-Case 'play-kenshi.ps1 -DryRun : simulation complète sans écriture' 'Kenshi tourne'
        Skip-Case 'play-kenshi.ps1 -DryRun : liste à restaurer -> restore-modlist.ps1 -WhatIf avec l''index de la vérification' 'Kenshi tourne'
        Skip-Case 'play-kenshi.ps1 -DryRun : pack invérifiable (fichiers absents) -> 2 avant toute écriture' 'Kenshi tourne'
        Skip-Case 'play-kenshi.ps1 -DryRun : bloqué par un fichier manquant, -Force passe' 'Kenshi tourne'
        Skip-Case 'play-kenshi.ps1 : faux -Game sans -DryRun -> refus, rien d''écrit ni lancé' 'Kenshi tourne'
        Skip-Case 'play-kenshi.ps1 : faux -Workshop seul sans -DryRun -> refus avant toute écriture' 'Kenshi tourne'
        Skip-Case 'play-kenshi.ps1 -DryRun : verrou de moniteur périmé -> ignoré, moniteur (simulé) démarré' 'Kenshi tourne'
        Skip-Case 'play-kenshi.ps1 -DryRun : moniteur vivant en attente -> conservé' 'Kenshi tourne'
        Skip-Case 'play-kenshi.ps1 -DryRun : moniteur vivant qui termine ou expire -> attente puis nouveau moniteur' 'Kenshi tourne'
    }
    else {
        Test-Case 'play-kenshi.ps1 : faux -Workshop seul sans -DryRun -> refus avant toute écriture' {
            # Régression : seul -Game était comparé à l'installation Steam ; un -Workshop différent faisait
            # vérifier la liste contre des fichiers que le jeu ne lit pas, puis écrire le vrai data\mods.cfg.
            # Ici -Game n'est pas passé : le script détecte le vrai jeu (lecture seule) et doit s'arrêter
            # sur -Workshop avant toute vérification, restauration ou lancement.
            $r = Invoke-Tool $play @{ Workshop = $ws } @('NoRestore', 'NoMonitor')
            Assert-Equal 1 $r.ExitCode "code de sortie ($($r.Output))"
            # Windows PowerShell 5.1 replie le message d'erreur à la largeur de la console : blancs normalisés
            $text = ($r.Output + $r.Errors) -replace '\s+', ' '
            Assert-Match $text '-Workshop .* ne correspond pas au Workshop Steam' 'message -Workshop'
            Assert-NotMatch $r.Output 'Vérification de la liste' 'pas de vérification'
            Assert-NotMatch $r.Output 'Restauration' 'pas de restauration'
            Assert-NotMatch $r.Output 'Lancement du jeu' 'pas de lancement'
            # Les deux à la fois : les deux écarts sont nommés
            $b = Invoke-Tool $play @{ Game = $gameA; Workshop = $ws } @('NoMonitor')
            Assert-Equal 1 $b.ExitCode 'code de sortie (faux -Game et faux -Workshop)'
            $textB = ($b.Output + $b.Errors) -replace '\s+', ' '
            Assert-Match $textB '-Game .* ne correspond pas à l''installation Steam' 'écart -Game nommé'
            Assert-Match $textB '-Workshop .* ne correspond pas au Workshop Steam' 'écart -Workshop nommé'
            Assert-Equal 'Alpha.mod|Beta.mod|Gamma.mod' ((Get-FileLines $liveA) -join '|') 'mods.cfg inchangé'
        }

        Test-Case 'play-kenshi.ps1 -DryRun : verrou de moniteur périmé -> ignoré, moniteur (simulé) démarré' {
            # Régression : un PID réattribué passait pour un moniteur vivant, aucun moniteur n'était démarré
            # et le script conseillait Stop-Process sur un processus quelconque.
            Write-TextFile $copyLock @('999999;2026-01-01T00:00:00.0000000+01:00;waiting;')
            $r = Invoke-Tool $playCopy @{ Game = $gameA; Workshop = $ws } @('DryRun')
            Assert-Equal 0 $r.ExitCode "code de sortie ($($r.Errors))"
            Assert-Match ($r.Output + $r.Errors) 'périmé' 'verrou périmé signalé'
            Assert-Match $r.Output 'Moniteur simulé' 'moniteur (simulé) démarré'
            Assert-NotMatch ($r.Output + $r.Errors) 'Stop-Process' 'pas de Stop-Process aveugle'
            $foreign = Get-ForeignPid
            if ($foreign -gt 0) {
                Write-TextFile $copyLock @("$foreign")
                $f = Invoke-Tool $playCopy @{ Game = $gameA; Workshop = $ws } @('DryRun')
                Assert-Match ($f.Output + $f.Errors) 'périmé' "PID d'un autre programme ($foreign) : périmé"
                Assert-Match $f.Output 'Moniteur simulé' 'moniteur (simulé) démarré'
            }
            Remove-Item -LiteralPath $copyLock -Force -ErrorAction SilentlyContinue
        }

        Test-Case 'play-kenshi.ps1 -DryRun : moniteur vivant en attente -> conservé' {
            New-Item -ItemType Directory -Path (Split-Path -Parent $copyLock) -Force | Out-Null
            Set-KenshiMonitorLock -Path $copyLock -Phase waiting -Deadline (Get-Date).AddSeconds(500)
            try {
                $r = Invoke-Tool $playCopy @{ Game = $gameA; Workshop = $ws } @('DryRun')
                Assert-Equal 0 $r.ExitCode "code de sortie ($($r.Errors))"
                Assert-Match $r.Output 'attend déjà le jeu' 'moniteur en attente reconnu'
                Assert-Match $r.Output "Moniteur existant conservé \(PID $PID" 'conservé'
                Assert-NotMatch $r.Output 'Moniteur simulé' 'pas de second moniteur'
                Assert-Match $r.Output '-Stop' 'conseil -Stop'
                Assert-NotMatch $r.Output 'Stop-Process' 'pas de Stop-Process aveugle'
                Set-KenshiMonitorLock -Path $copyLock -Phase waiting   # sans échéance : conservé aussi
                $n = Invoke-Tool $playCopy @{ Game = $gameA; Workshop = $ws } @('DryRun')
                Assert-Match $n.Output 'Moniteur existant conservé' 'sans échéance : conservé'
            }
            finally { Remove-Item -LiteralPath $copyLock -Force -ErrorAction SilentlyContinue }
        }

        Test-Case 'play-kenshi.ps1 -DryRun : moniteur vivant qui termine ou expire -> attente puis nouveau moniteur' {
            # Régression : un moniteur -Once en phase finishing (60 s d'attente des rapports) était « conservé »
            # alors qu'il allait s'arrêter sans voir la nouvelle session.
            New-Item -ItemType Directory -Path (Split-Path -Parent $copyLock) -Force | Out-Null
            try {
                Set-KenshiMonitorLock -Path $copyLock -Phase finishing
                $r = Invoke-Tool $playCopy @{ Game = $gameA; Workshop = $ws } @('DryRun')
                Assert-Equal 0 $r.ExitCode "code de sortie ($($r.Errors))"
                Assert-Match $r.Output 'termine la session précédente' 'phase finishing reconnue'
                Assert-Match $r.Output 'attente de sa fin' 'attente annoncée'
                Assert-Match $r.Output 'Moniteur simulé' 'nouveau moniteur (simulé)'
                Assert-NotMatch $r.Output 'enregistrera cette session' 'aucune promesse d''enregistrement'
                Set-KenshiMonitorLock -Path $copyLock -Phase waiting -Deadline (Get-Date).AddSeconds(30)
                $e = Invoke-Tool $playCopy @{ Game = $gameA; Workshop = $ws } @('DryRun')
                Assert-Match $e.Output 'bout de son délai' 'échéance trop proche reconnue'
                Assert-Match $e.Output 'Moniteur simulé' 'nouveau moniteur (simulé)'
            }
            finally { Remove-Item -LiteralPath $copyLock -Force -ErrorAction SilentlyContinue }
        }

        Test-Case 'play-kenshi.ps1 -DryRun : simulation complète sans écriture' {
            $r = Invoke-Tool $play @{ Game = $gameA; Workshop = $ws } @('DryRun', 'NoRestore')
            Assert-Equal 0 $r.ExitCode "code de sortie ($($r.Errors))"
            Assert-Match $r.Output 'Mode simulation' 'annonce'
            Assert-Match $r.Output 'Moniteur simulé' 'moniteur simulé'
            Assert-Match $r.Output '-WaitTimeoutSec 600' 'délai du moniteur transmis'
            Assert-Match $r.Output '(powershell|pwsh)\.exe -NoProfile' 'hôte console de la même édition'
            Assert-NotMatch $r.Output 'powershell_ise' 'jamais l''ISE'
            Assert-Match $r.Output 'Lancement simulé : Start-Process steam://rungameid/233860' 'lancement simulé'
            Assert-Match $r.Output 'Simulation terminée' 'fin'
            Assert-Match $r.Output 'OK : fichiers et dépendances en ordre' 'vérification'
            Assert-Match $r.Output 'Mods chargés' 'rappel : vérifier la liste chargée après la session'
            Assert-Equal 'Alpha.mod|Beta.mod|Gamma.mod' ((Get-FileLines $liveA) -join '|') 'mods.cfg inchangé'
            Assert-Equal 0 (Get-BakCount (Join-Path $gameA 'data')) 'aucun .bak'
            Assert-Equal $sessionsBefore (Get-SessionsSnapshot) 'logs\sessions du dépôt inchangé'
        }

        Test-Case 'play-kenshi.ps1 -DryRun : liste à restaurer -> restore-modlist.ps1 -WhatIf avec l''index de la vérification' {
            # Seul test qui passe par la restauration : l'index de la vérification est transmis (en processus) à restore-modlist.ps1
            $gameP = Join-Path $script:fixtures 'gameP'
            $liveP = Join-Path $gameP 'data\mods.cfg'
            Write-TextFile $liveP @('Alpha.mod')
            $r = Invoke-Tool $playCopy @{ Game = $gameP; Workshop = $ws } @('DryRun', 'NoMonitor')
            Assert-Equal 0 $r.ExitCode "code de sortie ($($r.Errors))"
            Assert-Match $r.Output 'Mods du pack non actifs \(seraient réactivés\) : 2' 'écart montré'
            Assert-Match $r.Output 'WhatIf : .*serait remplacé par 3 mods' 'restore-modlist.ps1 -WhatIf appelé'
            Assert-Match $r.Output 'Restauration simulée' 'restauration simulée'
            Assert-Equal 'Alpha.mod' ((Get-FileLines $liveP) -join '|') 'mods.cfg inchangé'
            Assert-Equal 0 (Get-BakCount (Join-Path $gameP 'data')) 'aucun .bak'
        }

        Test-Case 'play-kenshi.ps1 -DryRun : pack invérifiable (fichiers absents) -> 2 avant toute écriture' {
            # Le pack réel (676 mods) n'existe pas dans le faux Workshop : la vérification du pack bloque
            # avant d'appeler restore-modlist.ps1 (l'ordre vérification -> restauration est la correction).
            $r = Invoke-Tool $play @{ Game = $gameA; Workshop = $ws } @('DryRun', 'NoMonitor')
            Assert-Equal 2 $r.ExitCode 'code de sortie'
            Assert-Match ($r.Output + $r.Errors) 'Lancement annulé' 'blocage'
            Assert-Match ($r.Output + $r.Errors) 'Rien n''a été écrit' 'rien d''écrit'
            Assert-NotMatch $r.Output 'Restauration de la liste du pack' 'restauration pas tentée'
            Assert-NotMatch $r.Output 'Lancement simulé' 'pas de lancement'
            Assert-Equal 'Alpha.mod|Beta.mod|Gamma.mod' ((Get-FileLines $liveA) -join '|') 'mods.cfg inchangé'
            Assert-Equal 0 (Get-BakCount (Join-Path $gameA 'data')) 'aucun .bak'
        }

        Test-Case 'play-kenshi.ps1 : faux -Game sans -DryRun -> refus, rien d''écrit ni lancé' {
            # Sans -DryRun, un -Game différent de l'installation Steam est refusé avant toute écriture :
            # Steam lancerait le vrai jeu avec sa liste non restaurée. Le script sort au tout début.
            $r = Invoke-Tool $play @{ Game = $gameA; Workshop = $ws } @('NoMonitor')
            Assert-Equal 1 $r.ExitCode 'code de sortie'
            Assert-Match ($r.Output + $r.Errors) 'ne correspond pas à l''installation Steam' 'message'
            Assert-NotMatch $r.Output 'Lancement du jeu' 'pas de lancement'
            Assert-NotMatch $r.Output 'Restauration' 'pas de restauration'
            Assert-Equal 'Alpha.mod|Beta.mod|Gamma.mod' ((Get-FileLines $liveA) -join '|') 'mods.cfg inchangé'
            Assert-Equal 0 (Get-BakCount (Join-Path $gameA 'data')) 'aucun .bak'
            Assert-Equal $sessionsBefore (Get-SessionsSnapshot) 'logs\sessions du dépôt inchangé'
        }

        Test-Case 'play-kenshi.ps1 -DryRun : bloqué par un fichier manquant, -Force passe' {
            $r = Invoke-Tool $play @{ Game = $gameB; Workshop = $ws } @('DryRun', 'NoRestore', 'NoMonitor')
            Assert-Equal 2 $r.ExitCode 'code de sortie sans -Force'
            Assert-Match ($r.Output + $r.Errors) 'Lancement annulé' 'message de blocage'
            Assert-Match $r.Output 'Nope\.mod' 'fichier manquant listé'
            $f = Invoke-Tool $play @{ Game = $gameB; Workshop = $ws } @('DryRun', 'NoRestore', 'NoMonitor', 'Force')
            Assert-Equal 0 $f.ExitCode "code de sortie avec -Force ($($f.Errors))"
            Assert-Match ($f.Output + $f.Errors) '-Force' 'avertissement -Force'
            Assert-Match $f.Output 'Moniteur non démarré' 'moniteur désactivé'
            Assert-Equal 'Alpha.mod|Nope.mod' ((Get-FileLines (Join-Path $gameB 'data\mods.cfg')) -join '|') 'mods.cfg inchangé'
            Assert-Equal $sessionsBefore (Get-SessionsSnapshot) 'logs\sessions du dépôt inchangé'
        }
    }

    # --- scripts : update-pack.ps1 ------------------------------------------
    Test-Case 'update-pack.ps1 : dossier modlist introuvable -> 1 (sans réseau)' {
        $r = Invoke-Tool $update @{ ModlistDir = (Join-Path $script:fixtures 'nexistepas'); Workshop = $ws }
        Assert-Equal 1 $r.ExitCode 'code de sortie'
        Assert-Match ($r.Output + $r.Errors) 'Dossier modlist introuvable' 'message'
    }

    # Régressions avec processus, horloge et réponses réseau simulés ; le code des
    # outils est exécuté sur des dossiers jetables, sans lancer Steam ni Kenshi.
    . (Join-Path $PSScriptRoot 'health-regressions.ps1')
    . (Join-Path $PSScriptRoot 'pack-regressions.ps1')
    . (Join-Path $PSScriptRoot 'monitor-regressions.ps1')
}
finally {
    [Console]::OutputEncoding = $savedConsoleEncoding
    if ($Keep) { Write-Host "Données de test conservées : $script:fixtures" }
    elseif (Test-Path -LiteralPath $script:fixtures) {
        try {
            $resolvedFixtures = (Resolve-Path -LiteralPath $script:fixtures -ErrorAction Stop).ProviderPath
            $tempPrefix = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
            if (-not $resolvedFixtures.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or
                (Split-Path -Leaf $resolvedFixtures) -notmatch '^kenshi-tests-[0-9a-f]{8}$') {
                throw 'Le dossier de test à supprimer ne se trouve pas sous TEMP.'
            }
            Remove-Item -LiteralPath $resolvedFixtures -Recurse -Force -ErrorAction Stop
        }
        catch { Write-Warning "Dossier temporaire non supprimé : $script:fixtures ($($_.Exception.Message))" }
    }
}

# --- bilan --------------------------------------------------------------------
$sw.Stop()
Write-Host ''
$color = 'Green'; if ($script:failed -gt 0) { $color = 'Red' }
Write-Host ("Bilan : {0} réussis / {1} échoués / {2} ignorés ({3:N1} s, PowerShell {4})" -f $script:passed, $script:failed, $script:skipped, $sw.Elapsed.TotalSeconds, $PSVersionTable.PSVersion) -ForegroundColor $color
foreach ($f in $script:failures) { Write-Host "  - $f" -ForegroundColor Red }
if ($script:failed -gt 0) { exit 1 }
exit 0
