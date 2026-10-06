# Régressions de update-pack.ps1, chargées par run-tests.ps1 après ses helpers.
# Les scripts enfants remplacent les deux commandes réseau : aucune requête Steam.

function New-PackRegressionFixture([string]$Name, [object[]]$OldRows, [string[]]$AuthorFiles = @()) {
    $root = Join-Path $script:fixtures $Name
    $workshop = Join-Path $root 'workshop'
    $pack = Join-Path $root 'pack'
    New-ModFile -Path (Join-Path $workshop '1001\Alpha.mod')
    New-ModFile -Path (Join-Path $workshop '1002\Sub\Nested.mod')
    if ($AuthorFiles.Count -gt 0) {
        New-ModFile -Path (Join-Path $workshop '1005\Extra.mod') -Dependencies 'Alpha.mod'
    }
    $children = @(
        [pscustomobject]@{ publishedfileid = '1001'; sortorder = 0; filetype = 0 },
        [pscustomobject]@{ publishedfileid = '1002'; sortorder = 1; filetype = 0 },
        [pscustomobject]@{ publishedfileid = '1003'; sortorder = 2; filetype = 0 },
        [pscustomobject]@{ publishedfileid = '1004'; sortorder = 3; filetype = 0 }
    )
    $collection = [pscustomobject]@{
        response = [pscustomobject]@{
            collectiondetails = @([pscustomobject]@{ result = 1; children = $children })
        }
    }
    $details = @(
        [pscustomobject]@{ publishedfileid = '1001'; result = 1; title = 'Alpha' },
        [pscustomobject]@{ publishedfileid = '1002'; result = 1; title = 'Nested' },
        [pscustomobject]@{ publishedfileid = '1003'; result = 1; title = 'Recorded' },
        [pscustomobject]@{ publishedfileid = '1004'; result = 1; title = 'Unknown' },
        [pscustomobject]@{ publishedfileid = '1005'; result = 1; title = 'Extra' }
    )
    Write-TextFile (Join-Path $root 'collection.json') @($collection | ConvertTo-Json -Depth 8)
    Write-TextFile (Join-Path $root 'details.json') @([pscustomobject]@{
        response = [pscustomobject]@{ publishedfiledetails = $details }
    } | ConvertTo-Json -Depth 8)
    Write-TextFile (Join-Path $root 'topic.html') @(
        '<div id="forum_op_content_fixture-topic"><div class="bb_code">' +
        ($AuthorFiles -join '<br>') + '</div></div>'
    )
    Write-TextFile (Join-Path $pack 'pack-modlist.csv') @($OldRows | ConvertTo-Csv -NoTypeInformation)
    Write-TextFile (Join-Path $pack 'mods.cfg') @($OldRows | ForEach-Object { $_.mod_file })
    $wrapper = Join-Path $root 'mock-update.ps1'
    $wrapperText = @'
param([string]$Repo, [string]$Fixture, [string]$LoadOrderTopic = '', [switch]$Apply)
function Invoke-RestMethod {
    param($Method, [string]$Uri, $Body, $TimeoutSec, $ErrorAction)
    if ($Uri -like '*/GetCollectionDetails/v1/') {
        return Get-Content -LiteralPath (Join-Path $Fixture 'collection.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    if ($Uri -like '*/GetPublishedFileDetails/v1/') {
        return Get-Content -LiteralPath (Join-Path $Fixture 'details.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    throw "API inattendue dans le test : $Uri"
}
function Invoke-WebRequest {
    param([string]$Uri, [switch]$UseBasicParsing, $TimeoutSec, $ErrorAction)
    if ($Uri -notlike '*/workshop/filedetails/discussion/fixture/fixture-topic/') {
        throw "Page inattendue dans le test : $Uri"
    }
    [pscustomobject]@{ Content = [IO.File]::ReadAllText((Join-Path $Fixture 'topic.html')) }
}
& (Join-Path $Repo 'tools\update-pack.ps1') -CollectionId fixture -LoadOrderTopic $LoadOrderTopic -Workshop (Join-Path $Fixture 'workshop') -ModlistDir (Join-Path $Fixture 'pack') -Apply:$Apply
'@
    Write-TextFile $wrapper @($wrapperText)
    [pscustomobject]@{ Root = $root; Workshop = $workshop; Pack = $pack; Wrapper = $wrapper }
}

function New-PackRegressionRow([int]$Position, [string]$Id, [string]$File, [string]$Title, [string]$Dependencies = '') {
    [pscustomobject]@{
        position = $Position; workshop_id = $Id; mod_file = $File; title = $Title
        dependencies = $Dependencies; url = "https://steamcommunity.com/sharedfiles/filedetails/?id=$Id"
    }
}

Test-Case 'update-pack.ps1 : nouveau .mod imbriqué exclu, ancien non téléchargé conservé' {
    $oldRows = @(New-PackRegressionRow 1 '1003' 'Recorded.mod' 'Recorded' 'Alpha.mod')
    $f = New-PackRegressionFixture 'pack-nested-new' $oldRows
    $r = Invoke-Tool $f.Wrapper @{ Repo = $repo; Fixture = $f.Root } @('Apply')
    Assert-Equal 0 $r.ExitCode 'code de sortie de -Apply'
    Assert-Equal 'Alpha.mod|Recorded.mod' ((Get-FileLines (Join-Path $f.Pack 'mods.cfg')) -join '|') 'liste chargeable avec le nom ancien non téléchargé'
    $rows = @(Import-Csv -LiteralPath (Join-Path $f.Pack 'pack-modlist.csv') -Encoding UTF8)
    Assert-Equal '1001|1003' (($rows | ForEach-Object { $_.workshop_id }) -join '|') 'aucune entrée nouvelle imbriquée ou sans fichier connu'
    Assert-Equal 'Alpha.mod' $rows[1].dependencies 'dépendances anciennes conservées pour le mod non téléchargé'
    Assert-Match $r.Output 'seulement en sous-dossier, Kenshi ne le chargera pas' 'diagnostic du mod imbriqué'
    Assert-Match $r.Output 'Non téléchargés localement : 2' 'objets réellement non téléchargés'
    Assert-Match $r.Output 'Exclus de la liste .* : 2' 'objets imbriqué et sans fichier connu exclus'
}

Test-Case 'update-pack.ps1 : ancien .mod imbriqué retiré avec l''ordre de l''auteur' {
    $oldRows = @(
        (New-PackRegressionRow 1 '1002' 'Nested.mod' 'Nested' 'Alpha.mod'),
        (New-PackRegressionRow 2 '1001' 'Alpha.mod' 'Alpha'),
        (New-PackRegressionRow 3 '1003' 'Recorded.mod' 'Recorded' 'Alpha.mod')
    )
    $authorFiles = @('Alpha.mod', 'Extra.mod', 'Nested.mod', 'Recorded.mod')
    $f = New-PackRegressionFixture 'pack-nested-recorded' $oldRows $authorFiles
    $r = Invoke-Tool $f.Wrapper @{ Repo = $repo; Fixture = $f.Root; LoadOrderTopic = 'fixture-topic' } @('Apply')
    Assert-Equal 0 $r.ExitCode 'code de sortie de -Apply avec le fil de l''auteur'
    Assert-Equal 'Alpha.mod|Extra.mod|Recorded.mod' ((Get-FileLines (Join-Path $f.Pack 'mods.cfg')) -join '|') 'ordre de l''auteur sans l''ancien mod imbriqué'
    $rows = @(Import-Csv -LiteralPath (Join-Path $f.Pack 'pack-modlist.csv') -Encoding UTF8)
    Assert-Equal '1001|1005|1003' (($rows | ForEach-Object { $_.workshop_id }) -join '|') 'ancien objet imbriqué retiré du CSV'
    Assert-Equal '1|2|3' (($rows | ForEach-Object { $_.position }) -join '|') 'positions continues'
    Assert-Equal 'Alpha.mod' $rows[1].dependencies 'dépendances du mod hors collection'
    Assert-Equal 'Alpha.mod' $rows[2].dependencies 'dépendances conservées pour le mod non téléchargé'
    Assert-Match $r.Output 'Retirés : 1' 'ancienne entrée imbriquée signalée comme retirée'
    Assert-Match $r.Output 'Dans le fil mais non installés .* : 1\s+Nested\.mod' 'le fil ne réintroduit pas l''entrée imbriquée'
    Assert-Equal 2 @(Get-ChildItem -LiteralPath $f.Pack -Filter '*.bak' -File).Count 'deux fichiers du pack sauvegardés'
}
