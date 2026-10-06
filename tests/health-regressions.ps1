# Régressions matérielles de health-check.ps1, appelé par run-tests.ps1.
# Les contrôles et leurs fonctions sont exécutés depuis le vrai script ; seuls les
# processus et le registre sont simulés. Tous les fichiers sont sous les fixtures.
function Invoke-HealthHardwareChecks([string]$GameDir, [hashtable]$GpuPreferences,
    [object[]]$Processes = @(), [switch]$RegistryUnreadable) {
    $source = Get-Content -LiteralPath (Join-Path $tools 'health-check.ps1') -Raw -Encoding UTF8
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw 'health-check.ps1 ne se parse pas' }
    $definitions = @($ast.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -in @('Add-Check', 'Invoke-Check')
    } | ForEach-Object { $_.Extent.Text }) -join [Environment]::NewLine
    $first = $source.IndexOf('# --- RE_Kenshi ')
    $last = $source.IndexOf('# --- Smart App Control ')
    if ($first -lt 0 -or $last -le $first) { throw 'sections RE_Kenshi / GPU introuvables' }
    $body = [scriptblock]::Create($definitions + [Environment]::NewLine + $source.Substring($first, $last - $first))
    & {
        param($gameDir, $mockGpuPreferences, $mockProcesses, $mockRegistryUnreadable, $body)
        $checks = New-Object 'System.Collections.Generic.List[object]'
        $gameExists = Test-Path -LiteralPath $gameDir -PathType Container
        function Get-ItemProperty {
            [CmdletBinding()]
            param([string]$Path)
            if ($Path -ne 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences') { throw "registre imprévu : $Path" }
            if ($mockRegistryUnreadable) { throw 'registre inaccessible (simulé)' }
            [pscustomobject]$mockGpuPreferences
        }
        function Get-Process {
            [CmdletBinding()]
            param([string]$Name)
            if ($Name -ne 'kenshi_x64') { throw "processus imprévu : $Name" }
            $mockProcesses
        }
        . $body
        $checks.ToArray()
    } $GameDir $GpuPreferences $Processes ([bool]$RegistryUnreadable) $body
}

function New-HealthRegressionGame([string]$Name, [switch]$Loader, [switch]$Enabled,
    [switch]$ReExecutable, [switch]$StaleLog) {
    $dir = Join-Path $script:fixtures ('health-hardware\' + $Name)
    Write-TextFile (Join-Path $dir 'kenshi_x64.exe') @('exécutable factice, jamais lancé')
    $plugins = @('Plugin=RenderSystem_Direct3D11_x64')
    if ($Enabled) { $plugins += 'Plugin=RE_Kenshi' }
    Write-TextFile (Join-Path $dir 'Plugins_x64.cfg') $plugins
    if ($Loader) { Write-TextFile (Join-Path $dir 'RE_Kenshi.dll') @('DLL factice, jamais chargée') }
    if ($ReExecutable) { Write-TextFile (Join-Path $dir 'RE_Kenshi\kenshi_x64.exe') @('exécutable factice, jamais lancé') }
    if ($StaleLog) { Write-TextFile (Join-Path $dir 'RE_Kenshi_log.txt') @('ancien journal') }
    $dir
}

function Get-HealthRegressionRow([object[]]$Checks, [string]$Name) {
    $rows = @($Checks | Where-Object { $_.Check -eq $Name })
    Assert-Equal 1 $rows.Count "un contrôle $Name"
    $rows[0]
}

Test-Case 'health-check.ps1 : GPU du jeu RE_Kenshi fermé, pas celui du lanceur' {
    $dir = New-HealthRegressionGame 'child-power-saving' -Loader -Enabled -ReExecutable
    $root = Join-Path $dir 'kenshi_x64.exe'; $child = Join-Path $dir 'RE_Kenshi\kenshi_x64.exe'
    $prefs = @{}; $prefs[$root] = 'GpuPreference=2;'; $prefs[$child] = 'GpuPreference=1;'
    $checks = @(Invoke-HealthHardwareChecks $dir $prefs)
    Assert-Equal 'OK' (Get-HealthRegressionRow $checks 'RE_Kenshi').Status 'installation complète'
    $gpu = Get-HealthRegressionRow $checks 'Préférence GPU'
    Assert-Equal 'ATTENTION' $gpu.Status 'GPU intégré du jeu signalé'
    Assert-Match $gpu.Detail 'GpuPreference=1' 'préférence du jeu'
    Assert-Match $gpu.Advice ([regex]::Escape($child)) 'conseil vers le vrai exécutable'
}

Test-Case 'health-check.ps1 : préférence RE_Kenshi absente malgré celle du lanceur' {
    $dir = New-HealthRegressionGame 'child-unconfigured' -Loader -Enabled -ReExecutable
    $root = Join-Path $dir 'kenshi_x64.exe'; $child = Join-Path $dir 'RE_Kenshi\kenshi_x64.exe'
    $prefs = @{}; $prefs[$root] = 'GpuPreference=2;'
    $gpu = Get-HealthRegressionRow @(Invoke-HealthHardwareChecks $dir $prefs) 'Préférence GPU'
    Assert-Equal 'ATTENTION' $gpu.Status 'préférence du jeu absente'
    Assert-Match $gpu.Detail ('aucune préférence enregistrée pour ' + [regex]::Escape($child)) 'exécutable du jeu signalé'
}

Test-Case 'health-check.ps1 : GPU du jeu normal fermé' {
    $dir = New-HealthRegressionGame 'normal-root'
    $root = Join-Path $dir 'kenshi_x64.exe'; $prefs = @{}; $prefs[$root] = 'GpuPreference=2;'
    $gpu = Get-HealthRegressionRow @(Invoke-HealthHardwareChecks $dir $prefs) 'Préférence GPU'
    Assert-Equal 'OK' $gpu.Status 'GPU du jeu normal'
    Assert-Match $gpu.Detail ([regex]::Escape($root)) 'exécutable normal vérifié'
}

Test-Case 'health-check.ps1 : processus racine en cours prime sur RE_Kenshi installé' {
    $dir = New-HealthRegressionGame 'running-root' -Loader -Enabled -ReExecutable
    $root = Join-Path $dir 'kenshi_x64.exe'; $child = Join-Path $dir 'RE_Kenshi\kenshi_x64.exe'
    $prefs = @{}; $prefs[$root] = 'GpuPreference=2;'; $prefs[$child] = 'GpuPreference=1;'
    $processes = @([pscustomobject]@{ Path = $root })
    $gpu = Get-HealthRegressionRow @(Invoke-HealthHardwareChecks $dir $prefs $processes) 'Préférence GPU'
    Assert-Equal 'OK' $gpu.Status 'RE_Kenshi contourné pour cette partie'
    Assert-Match $gpu.Detail ([regex]::Escape($root)) 'chemin du processus racine'
}

Test-Case 'health-check.ps1 : processus RE_Kenshi en cours prime pendant la relance' {
    $dir = New-HealthRegressionGame 'running-child' -Loader -Enabled -ReExecutable
    $root = Join-Path $dir 'kenshi_x64.exe'; $child = Join-Path $dir 'RE_Kenshi\kenshi_x64.exe'
    $prefs = @{}; $prefs[$root] = 'GpuPreference=1;'; $prefs[$child] = 'GpuPreference=2;'
    $processes = @([pscustomobject]@{ Path = $child }, [pscustomobject]@{ Path = $root })
    $gpu = Get-HealthRegressionRow @(Invoke-HealthHardwareChecks $dir $prefs $processes) 'Préférence GPU'
    Assert-Equal 'OK' $gpu.Status 'GPU du processus relancé'
    Assert-Match $gpu.Detail ([regex]::Escape($child)) 'chemin du processus RE_Kenshi'
}

Test-Case 'health-check.ps1 : chemin du processus inaccessible reste indéterminé' {
    $dir = New-HealthRegressionGame 'process-unreadable' -Loader -Enabled -ReExecutable
    $child = Join-Path $dir 'RE_Kenshi\kenshi_x64.exe'; $prefs = @{}; $prefs[$child] = 'GpuPreference=2;'
    $process = New-Object PSObject
    $process | Add-Member -MemberType ScriptProperty -Name Path -Value { throw 'chemin inaccessible (simulé)' }
    $gpu = Get-HealthRegressionRow @(Invoke-HealthHardwareChecks $dir $prefs @($process)) 'Préférence GPU'
    Assert-Equal 'ATTENTION' $gpu.Status 'préférence non certifiée'
    Assert-Match $gpu.Detail 'chemin du jeu en cours illisible' 'lecture impossible expliquée'
    Assert-Match $gpu.Advice ([regex]::Escape($child)) 'exécutable attendu indiqué'
}

Test-Case 'health-check.ps1 : registre GPU inaccessible donne une attention' {
    $dir = New-HealthRegressionGame 'registry-unreadable'
    $gpu = Get-HealthRegressionRow @(Invoke-HealthHardwareChecks $dir @{} -RegistryUnreadable) 'Préférence GPU'
    Assert-Equal 'ATTENTION' $gpu.Status 'registre inaccessible'
    Assert-Match $gpu.Detail 'préférences Windows illisibles' 'lecture impossible expliquée'
}

Test-Case 'health-check.ps1 : ancien journal et entrée plugin sans DLL sont partiels' {
    $dir = New-HealthRegressionGame 'stale-log' -Enabled -ReExecutable -StaleLog
    $root = Join-Path $dir 'kenshi_x64.exe'; $prefs = @{}; $prefs[$root] = 'GpuPreference=2;'
    $checks = @(Invoke-HealthHardwareChecks $dir $prefs)
    $re = Get-HealthRegressionRow $checks 'RE_Kenshi'
    Assert-Equal 'ATTENTION' $re.Status 'DLL absente détectée'
    Assert-Match $re.Detail 'traces partielles' 'installation partielle'
    Assert-Match $re.Detail 'RE_Kenshi\.dll introuvable' 'chargeur manquant indiqué'
    Assert-Equal 'OK' (Get-HealthRegressionRow $checks 'Préférence GPU').Status 'ancien dossier ignoré pour le GPU'
}

Test-Case 'health-check.ps1 : un dossier nommé RE_Kenshi.dll ne remplace pas le chargeur' {
    $dir = New-HealthRegressionGame 'loader-directory' -Enabled -StaleLog
    New-Item -ItemType Directory -Path (Join-Path $dir 'RE_Kenshi.dll') | Out-Null
    $re = Get-HealthRegressionRow @(Invoke-HealthHardwareChecks $dir @{}) 'RE_Kenshi'
    Assert-Equal 'ATTENTION' $re.Status 'faux chargeur ignoré'
    Assert-Match $re.Detail 'RE_Kenshi\.dll introuvable' 'fichier attendu indiqué'
}

Test-Case 'health-check.ps1 : DLL sans entrée active garde le GPU du jeu normal' {
    $dir = New-HealthRegressionGame 'plugin-disabled' -Loader -ReExecutable
    Write-TextFile (Join-Path $dir 'Plugins_x64.cfg') @('# Plugin=RE_Kenshi', 'Plugin=Other_RE_Kenshi')
    $root = Join-Path $dir 'kenshi_x64.exe'; $prefs = @{}; $prefs[$root] = 'GpuPreference=2;'
    $checks = @(Invoke-HealthHardwareChecks $dir $prefs)
    $re = Get-HealthRegressionRow $checks 'RE_Kenshi'
    Assert-Equal 'ATTENTION' $re.Status 'entrée RE_Kenshi inactive'
    Assert-Match $re.Detail 'traces partielles' 'DLL seule signalée'
    Assert-Equal 'OK' (Get-HealthRegressionRow $checks 'Préférence GPU').Status 'préférence normale retenue'
}
