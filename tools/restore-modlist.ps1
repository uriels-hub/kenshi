<#
.SYNOPSIS
    Remet l'ordre de chargement du pack (modlist\mods.cfg) dans le jeu.

.DESCRIPTION
    À lancer, jeu fermé, quand le lanceur de Kenshi a réactivé des mods hors pack.
    Avant d'écrire : refuse si kenshi_x64.exe tourne, si la liste source est vide ou
    si le dossier du jeu n'a pas de sous-dossier data (dossier -Game mal tapé), puis
    vérifie que chaque .mod de la liste existe sur le disque (jeu\mods ou Workshop)
    et s'arrête en listant les absents (15 premiers), sauf avec -Force. L'ancien
    data\mods.cfg est sauvegardé en mods.cfg.<horodatage>.bak ; si cette copie ou
    l'écriture échoue (fichier en lecture seule...), rien n'est annoncé comme restauré.
    Après l'écriture, le fichier est relu et comparé à la source.
    Supporte -WhatIf (aucune écriture, aucune sauvegarde).
    Code de sortie : 0 si restauré (ou -WhatIf sans blocage), 1 si refusé ou si
    l'écriture a échoué.

.PARAMETER Game
    Dossier du jeu (détection automatique via Steam sinon).
.PARAMETER Workshop
    Dossier Workshop (détection automatique sinon).
.PARAMETER Source
    Liste à restaurer (par défaut : modlist\mods.cfg du dépôt).
.PARAMETER Force
    Écrit même si des fichiers .mod sont introuvables.
.PARAMETER ModIndex
    Index des fichiers .mod déjà construit par Get-ModFileIndex sur jeu\mods et le
    Workshop, utilisé tel quel (play-kenshi.ps1 le passe pour ne parcourir le
    Workshop qu'une fois).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\restore-modlist.ps1
.EXAMPLE
    .\tools\restore-modlist.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Game,
    [string]$Workshop,
    [string]$Source,
    [switch]$Force,
    [hashtable]$ModIndex
)
Import-Module (Join-Path $PSScriptRoot 'KenshiTools.psm1') -Force
if (-not $Source) { $Source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\modlist\mods.cfg')) }
$maxListed = 15

if (Get-Process kenshi_x64 -ErrorAction SilentlyContinue) {
    Write-Error 'Kenshi (ou son lanceur) est ouvert : ferme-le avant de restaurer la liste.'
    exit 1
}
if (-not (Test-Path -LiteralPath $Source)) { Write-Error "Introuvable : $Source"; exit 1 }

$paths = Get-KenshiPaths -Game $Game -Workshop $Workshop
if (-not (Test-Path -LiteralPath (Join-Path $paths.Game 'data'))) {
    Write-Error "Dossier du jeu invalide (pas de sous-dossier data) : $($paths.Game). Vérifier -Game ou l'installation Steam."
    exit 1
}
$dst = $paths.ModsCfg
$lines = @(Get-ActiveModList -Path $Source)
if ($lines.Count -eq 0) { Write-Error "Liste source vide, restauration refusée : $Source"; exit 1 }

$index = $ModIndex
if ($null -eq $index) { $index = Get-ModFileIndex -Folders @((Join-Path $paths.Game 'mods'), $paths.Workshop) }
$missing = @($lines | Where-Object { -not $index.ContainsKey($_) -or $index[$_].IsNestedOnly })
if ($missing.Count -gt 0) {
    Write-Host "Fichiers .mod introuvables sur le disque (ou seulement en sous-dossier Workshop) : $($missing.Count)"
    foreach ($m in @($missing | Select-Object -First $maxListed)) { Write-Host "  $m" }
    if ($missing.Count -gt $maxListed) { Write-Host "  ... et $($missing.Count - $maxListed) autres (tools\scan-mods.ps1 -ModsCfg $Source pour le détail)" }
    if (-not $Force) {
        Write-Error "Restauration annulée : $($missing.Count) mod(s) introuvable(s) (vérifier les abonnements Workshop, ou relancer avec -Force)."
        exit 1
    }
    Write-Warning '-Force : la liste est écrite malgré les fichiers introuvables.'
}

$old = 0
if (Test-Path -LiteralPath $dst) { $old = @(Get-ActiveModList -Path $dst).Count }
try { $w = Write-ModList -Path $dst -Lines $lines -WhatIf:$WhatIfPreference -ErrorAction Stop }
catch { Write-Error "Liste non restaurée : $($_.Exception.Message)"; exit 1 }
if ($WhatIfPreference) {
    Write-Host "WhatIf : $dst ($old mods) serait remplacé par $($w.Count) mods venant de $Source."
    exit 0
}
# Relecture indépendante : ce qui est sur le disque doit être exactement la source
$written = @(Get-ActiveModList -Path $dst)
if (($written -join "`n") -ne ($lines -join "`n")) {
    Write-Error "Liste non restaurée : $dst contient $($written.Count) mods au lieu des $($lines.Count) attendus."
    exit 1
}
if ($w.Backup) { Write-Host "Ancienne liste sauvegardée : $($w.Backup) ($old mods)" }
Write-Host "mods.cfg restauré : $($w.Count) mods."
exit 0
