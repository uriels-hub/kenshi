<#
.SYNOPSIS
    Vérifie la liste de mods active de Kenshi.

.DESCRIPTION
    Interface en ligne de commande de Test-KenshiModList (tools\KenshiTools.psm1) :
    fichiers .mod introuvables, en-têtes illisibles, dépendances absentes ou non
    activées, dépendances chargées trop tard, fichiers en double sur le disque, et
    écart entre la liste active et celle du pack (modlist\mods.cfg).
    Un .mod présent seulement en sous-dossier d'un objet Workshop (que Kenshi ne
    charge pas) compte comme introuvable et est signalé à part.
    Lecture seule : ne modifie ni le jeu ni le Workshop.
    Code de sortie : 0 si tout est propre, 2 s'il y a au moins un problème, 1 si la
    liste est introuvable.

.PARAMETER Game
    Dossier du jeu (détection automatique via Steam sinon).
.PARAMETER Workshop
    Dossier Workshop (détection automatique sinon).
.PARAMETER ModsCfg
    Liste à vérifier (par défaut : data\mods.cfg du jeu).
.PARAMETER PackCfg
    Liste de référence (par défaut : modlist\mods.cfg du dépôt). Chaîne vide pour ne pas comparer.
.PARAMETER Json
    Sort le résultat complet en JSON au lieu du rapport texte.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\scan-mods.ps1
.EXAMPLE
    .\tools\scan-mods.ps1 -ModsCfg .\modlist\mods.cfg -PackCfg '' -Json
#>
[CmdletBinding()]
param(
    [string]$Game,
    [string]$Workshop,
    [string]$ModsCfg,
    [string]$PackCfg,
    [switch]$Json
)
Import-Module (Join-Path $PSScriptRoot 'KenshiTools.psm1') -Force
if (-not $PSBoundParameters.ContainsKey('PackCfg')) { $PackCfg = Join-Path $PSScriptRoot '..\modlist\mods.cfg' }
if ($PackCfg -and -not (Test-Path -LiteralPath $PackCfg)) { Write-Warning "Liste du pack introuvable, comparaison ignorée : $PackCfg"; $PackCfg = '' }
if (-not $ModsCfg) { $ModsCfg = (Get-KenshiPaths -Game $Game -Workshop $Workshop).ModsCfg }
if (-not (Test-Path -LiteralPath $ModsCfg)) { Write-Error "Liste de mods introuvable : $ModsCfg"; exit 1 }
if ($PackCfg) { $PackCfg = (Resolve-Path -LiteralPath $PackCfg).ProviderPath }

$r = Test-KenshiModList -ModsCfg $ModsCfg -PackCfg $PackCfg -Game $Game -Workshop $Workshop

if ($Json) {
    $r | ConvertTo-Json -Depth 6
}
else {
    function Show([string]$Label, [array]$Items) {
        Write-Host ("{0} : {1}" -f $Label, $Items.Count)
        foreach ($i in $Items) { Write-Host "  $i" }
    }
    $c = $r.Counts
    Write-Host "Liste analysée : $($r.ModsCfg) ($($c.Active) mods actifs, $($c.FilesOnDisk) fichiers .mod sur le disque)"
    Write-Host "Jeu : $($r.Game) ; Workshop : $($r.Workshop)"
    Show 'Fichiers .mod introuvables' $r.MissingFiles
    if ($c.NestedFiles -gt 0) { Show '  dont présents seulement en sous-dossier Workshop (non chargés par Kenshi)' @($r.NestedFiles | ForEach-Object { "$($_.Mod) : $($_.Path)" }) }
    Show 'En-têtes illisibles' @($r.Unreadable | ForEach-Object { "$($_.Mod) : $($_.Error)" })
    Show 'Dépendances introuvables' @($r.AbsentDependencies | ForEach-Object { "$($_.Mod) -> $($_.Dependency)" })
    Show 'Dépendances non activées' @($r.InactiveDependencies | ForEach-Object { "$($_.Mod) -> $($_.Dependency) (présent sur le disque : $($_.Path))" })
    Show 'Dépendances chargées trop tard' @($r.LateDependencies | ForEach-Object { "$($_.Mod) (#$($_.Position)) se charge avant sa dépendance $($_.Dependency) (#$($_.DependencyPosition))" })
    Show 'Fichiers en double sur le disque (mods actifs)' @($r.DuplicateFiles | ForEach-Object { "$($_.Mod) (#$($_.Position)) : " + ($_.Paths -join ' | ') })
    if ($r.PackCfg) {
        Write-Host "Comparaison avec le pack : $($r.PackCfg) ($($c.Pack) mods)"
        Show 'Mods actifs hors pack' $r.NotInPack
        Show 'Mods du pack non activés' $r.PackModsNotActive
    }
    if ($r.IsClean) { Write-Host 'OK : aucun problème détecté.' }
    else { Write-Host "Problèmes : $($c.Problems)" }
}

if ($r.IsClean) { exit 0 } else { exit 2 }
