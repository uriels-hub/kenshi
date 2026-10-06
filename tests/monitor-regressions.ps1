# Chargé par run-tests.ps1 : le moniteur réel tourne dans un enfant PowerShell,
# avec un module, des processus, WMI et une horloge entièrement synthétiques.
function Invoke-MonitorRegression([string]$Scenario) {
    $root = Join-Path $script:fixtures ('monitor-regressions\' + $Scenario)
    $mockTools = Join-Path $root 'tools'
    New-Item -ItemType Directory -Path $mockTools -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $tools 'kenshi-monitor.ps1') -Destination $mockTools
    Write-TextFile (Join-Path $mockTools 'KenshiTools.psm1') @'
function Get-KenshiPaths {
    param($Game)
    [pscustomobject]@{ Game=$Game; ModsCfg=(Join-Path $Game 'data\mods.cfg'); CrashDumps=(Join-Path $Game 'dumps'); WerReportDirs=@() }
}
function Read-KenshiMonitorLock {
    param($Path)
    if (Test-Path -LiteralPath $Path) { [pscustomobject]@{ ProcessId=$PID; IsLive=$true; Reason=''; Phase='waiting' } }
}
function Set-KenshiMonitorLock { param($Path,$Phase,$Deadline) [IO.File]::WriteAllText($Path,"$PID;$Phase") }
function Get-KenshiSessions { param($SaveLog) }
function Get-KenshiLogSummary { param($InfoLog,$PackCfg) [pscustomobject]@{ LoadedCount=1; PackCount=$null; ExtraMods=@() } }
function Format-KenshiLogSummary { param([Parameter(ValueFromPipeline=$true)]$Summary) process { 'synthetic summary' } }
function Get-ActiveModList { param($Path) Get-Content -LiteralPath $Path }
function Get-KenshiCrashEvents { param($Since) $global:MonitorTestEvents | Where-Object { $_.Time -ge $Since } }
function Get-KenshiHangEvents { param($Since) $global:MonitorTestHangs | Where-Object { $_.Time -ge $Since } }
Export-ModuleMember -Function *
'@
    $wrapper = Join-Path $root 'run.ps1'
    Write-TextFile $wrapper @'
param([string]$Root,[string]$Scenario)
$ErrorActionPreference = 'Stop'
$global:MonitorTestBase = [datetime]'2026-01-02T10:00:00'
$global:MonitorTestNow = $global:MonitorTestBase
$global:MonitorTestScenario = $Scenario
$global:MonitorTestGame = Join-Path $Root 'game'
$global:MonitorTestOut = Join-Path $Root 'out'
$global:MonitorTestRestartWritten = $false
$global:MonitorTestParentLookupGone = $false
New-Item -ItemType Directory -Path (Join-Path $global:MonitorTestGame 'data') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $global:MonitorTestGame 'data\mods.cfg'),'First.mod')
[IO.File]::WriteAllText((Join-Path $global:MonitorTestGame 'kenshi_info.log'),'FIRST SESSION LOG')
$rootExe = Join-Path $global:MonitorTestGame 'kenshi_x64.exe'
$reExe = Join-Path $global:MonitorTestGame 'RE_Kenshi\kenshi_x64.exe'
# Le moniteur ne cherche un enfant RE_Kenshi que si son exécutable existe.
if ($Scenario -in 're-handoff', 'wrong-parent', 'wrong-path', 'reused-parent') {
    New-Item -ItemType Directory -Path (Split-Path -Parent $reExe) -Force | Out-Null
    [IO.File]::WriteAllText($reExe, 'exécutable factice, jamais lancé')
}
function New-TestProcess([int]$Id,[string]$Path,[double]$Born,[double]$Ends,[int]$Parent) {
    $p = [pscustomobject]@{
        Id=$Id; ProcessName='kenshi_x64'; Handle=1; Path=$Path; ParentProcessId=$Parent
        StartTime=$global:MonitorTestBase.AddSeconds($Born); ExitTime=$global:MonitorTestBase.AddSeconds($Ends)
        ExitCode=0; WorkingSet64=1048576; PrivateMemorySize64=2097152; PeakWorkingSet64=3145728; HandleCount=1; Threads=@(1)
    }
    $p | Add-Member -MemberType ScriptProperty -Name HasExited -Value { $global:MonitorTestNow -ge $this.ExitTime }
    $p | Add-Member -MemberType ScriptMethod -Name Refresh -Value { }
    $p | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
        param([int]$Milliseconds)
        $until = $global:MonitorTestNow.AddMilliseconds($Milliseconds)
        if ($this.ExitTime -le $until) {
            $global:MonitorTestNow = $this.ExitTime
            return $true
        }
        Start-Sleep -Milliseconds $Milliseconds
        $false
    }
    $p
}
$global:MonitorTestProcesses = @(New-TestProcess 100 $rootExe 0 4 42)
switch ($Scenario) {
    'quick-restart' {
        $global:MonitorTestProcesses[0].ExitTime = $global:MonitorTestBase.AddSeconds(2.2)
        $global:MonitorTestProcesses += New-TestProcess 200 $rootExe 2.3 15 42
    }
    're-handoff' { $global:MonitorTestProcesses += New-TestProcess 200 $reExe 3 12 100 }
    'wrong-parent' { $global:MonitorTestProcesses += New-TestProcess 200 $reExe 3 12 42 }
    'wrong-path' { $global:MonitorTestProcesses += New-TestProcess 200 $rootExe 3 12 100 }
    'reused-parent' { $global:MonitorTestProcesses += New-TestProcess 200 $reExe 6 15 100 }
    # Code que Windows donne à un programme figé qu'il ferme
    'hang-exit-code' { $global:MonitorTestProcesses[0].ExitCode = -805306369 }
}
function New-TestCrash([int]$Id,[string]$Path,[int]$Born,[int]$At,[string]$Module) {
    [pscustomobject]@{
        ProcessId=$Id; AppPath=$Path; ProcessStartTime=$global:MonitorTestBase.AddSeconds($Born)
        Time=$global:MonitorTestBase.AddSeconds($At); Module=$Module; ModuleVersion='1'; ExceptionCode='0xc0000005'; FaultOffset='0x1'
    }
}
$global:MonitorTestEvents = @()
$global:MonitorTestHangs = @()
switch ($Scenario) {
    'hang' { $global:MonitorTestHangs = @(New-TestCrash 100 $rootExe 0 30 'hang') }
    'hang-other-pid' { $global:MonitorTestHangs = @(New-TestCrash 300 $rootExe 0 30 'hang') }
    'quick-restart' { $global:MonitorTestEvents = @(New-TestCrash 200 $rootExe 5 15 'later-game.dll') }
    're-handoff' { $global:MonitorTestEvents = @((New-TestCrash 900 $reExe 3 20 'unrelated.dll'),(New-TestCrash 200 $reExe 3 42 're-child.dll')) }
    'reused-event-pid' { $global:MonitorTestEvents = @(New-TestCrash 100 $rootExe 5 15 'reused-pid.dll') }
    'delayed-report' { $global:MonitorTestEvents = @(New-TestCrash 100 $rootExe 0 40 'delayed-root.dll') }
    'very-delayed-report' { $global:MonitorTestEvents = @(New-TestCrash 100 $rootExe 0 70 'very-delayed-root.dll') }
    'missing-event-start' {
        $e = New-TestCrash 100 $rootExe 0 40 'legacy-root.dll'
        $e.ProcessStartTime = $null
        $global:MonitorTestEvents = @($e)
    }
    'missing-event-pid' {
        $e = New-TestCrash 100 $rootExe 0 40 'no-pid.dll'
        $e.ProcessId = $null
        $global:MonitorTestEvents = @($e)
    }
    'missing-event-pid-late' {
        $e = New-TestCrash 100 $rootExe 0 90 'no-pid-late.dll'
        $e.ProcessId = $null
        $global:MonitorTestEvents = @($e)
    }
}
function global:Get-Date { param([string]$Format) if ($Format) { $global:MonitorTestNow.ToString($Format) } else { $global:MonitorTestNow } }
function global:Start-Sleep {
    param([int]$Seconds,[int]$Milliseconds)
    $global:MonitorTestNow = $global:MonitorTestNow.AddSeconds($Seconds).AddMilliseconds($Milliseconds)
    if ($global:MonitorTestScenario -eq 'quick-restart' -and -not $global:MonitorTestRestartWritten -and
        $global:MonitorTestNow -ge $global:MonitorTestBase.AddSeconds(2.3)) {
        $global:MonitorTestRestartWritten = $true
        [IO.File]::WriteAllText((Join-Path $global:MonitorTestGame 'kenshi_info.log'),'SECOND SESSION LOG')
        [IO.File]::WriteAllText((Join-Path $global:MonitorTestGame 'data\mods.cfg'),'Second.mod')
    }
}
function global:Get-Process {
    param([string]$Name,[int]$Id,$ErrorAction)
    if ($PSBoundParameters.ContainsKey('Id')) {
        $global:MonitorTestProcesses | Where-Object { $_.Id -eq $Id -and $_.StartTime -le $global:MonitorTestNow -and -not $_.HasExited }
    }
    elseif ($Name -eq 'kenshi_x64') {
        $global:MonitorTestProcesses | Where-Object { $_.StartTime -le $global:MonitorTestNow -and -not $_.HasExited }
    }
    else { throw "Unexpected process access: $Name" }
}
function global:Get-CimInstance {
    param([string]$ClassName,[string]$Filter,$ErrorAction)
    if ($ClassName -eq 'Win32_OperatingSystem') {
        return [pscustomobject]@{ FreePhysicalMemory=1048576; TotalVirtualMemorySize=4194304; FreeVirtualMemory=2097152 }
    }
    if ($ClassName -ne 'Win32_Process') { throw "Unexpected CIM access: $ClassName" }
    if ($Filter -eq 'ProcessId = 100' -and $global:MonitorTestScenario -eq 're-handoff' -and -not $global:MonitorTestParentLookupGone) {
        # Le parent se ferme entre la lecture de .NET et la recherche WMI.
        $global:MonitorTestParentLookupGone = $true
        $global:MonitorTestNow = $global:MonitorTestBase.AddSeconds(5)
        [IO.File]::WriteAllText((Join-Path $global:MonitorTestGame 'kenshi_info.log'),'RE CHILD LOG')
        return
    }
    $live = @($global:MonitorTestProcesses | Where-Object { $_.StartTime -le $global:MonitorTestNow -and -not $_.HasExited })
    if ($Filter -match '^ProcessId = (\d+)$') { $live = @($live | Where-Object { $_.Id -eq [int]$Matches[1] }) }
    elseif ($Filter -match "^Name = 'kenshi_x64.exe' AND ParentProcessId = (\d+)$") {
        $wantedParent = [int]$Matches[1]
        $live = @($live | Where-Object { $_.ParentProcessId -eq $wantedParent })
    }
    else { throw "Unexpected process filter: $Filter" }
    foreach ($p in $live) { [pscustomobject]@{ ProcessId=$p.Id; ParentProcessId=$p.ParentProcessId; CreationDate=$p.StartTime; ExecutablePath=$p.Path } }
}
& (Join-Path $Root 'tools\kenshi-monitor.ps1') -Game $global:MonitorTestGame -OutDir $global:MonitorTestOut -Once -IntervalSec 2 -WaitTimeoutSec 10
if ($Scenario -eq 're-handoff' -and -not $global:MonitorTestParentLookupGone) { throw 'Missing parent-exit exercise' }
'@
    $result = Invoke-Tool $wrapper @{ Root = $root; Scenario = $Scenario }
    Assert-Equal 0 $result.ExitCode "moniteur synthétique ($($result.Output) $($result.Errors))"
    $sessions = @(Get-ChildItem -LiteralPath (Join-Path $root 'out') -Directory)
    Assert-Equal 1 $sessions.Count 'une session archivée'
    [pscustomobject]@{
        Summary = ([IO.File]::ReadAllText((Join-Path $sessions[0].FullName 'summary.json')) | ConvertFrom-Json)
        Info = [IO.File]::ReadAllText((Join-Path $sessions[0].FullName 'kenshi_info.log'))
        Mods = [IO.File]::ReadAllText((Join-Path $sessions[0].FullName 'mods.cfg.at-exit'))
        LiveInfo = [IO.File]::ReadAllText((Join-Path $root 'game\kenshi_info.log'))
    }
}

Test-Case 'kenshi-monitor.ps1 : redémarrage rapide -> anciens journaux conservés, nouveau plantage exclu' {
    $r = Invoke-MonitorRegression 'quick-restart'
    Assert-Equal 0 $r.Summary.relaunches 'nouveau lancement indépendant'
    Assert-Equal 'FIRST SESSION LOG' $r.Info 'journal copié avant le redémarrage'
    Assert-Equal 'SECOND SESSION LOG' $r.LiveInfo 'le nouveau jeu a bien écrasé son journal'
    Assert-Equal 'First.mod' $r.Mods 'liste de la première session conservée'
    Assert-Equal '2026-01-02T10:00:02' ([datetime]$r.Summary.end).ToString('s') 'réveil à la fermeture avant la mesure suivante'
    Assert-True (-not $r.Summary.crashed) 'plantage du nouveau PID exclu'
}

Test-Case 'kenshi-monitor.ps1 : enfant RE_Kenshi confirmé malgré parent absent de WMI, rapport retardé accepté' {
    $r = Invoke-MonitorRegression 're-handoff'
    Assert-Equal 1 $r.Summary.relaunches 'un seul passage au vrai enfant'
    Assert-Equal 'RE CHILD LOG' $r.Info 'journal du vrai enfant archivé'
    Assert-True $r.Summary.crashed 'rapport retardé du processus enfant accepté'
    Assert-Equal 're-child.dll' $r.Summary.crash_module 'événement sans lien exclu'
    Assert-Equal '2026-01-02T10:00:42' ([datetime]$r.Summary.crash_time).ToString('s') 'événement 30 s après la fermeture'
}

Test-Case 'kenshi-monitor.ps1 : parent, chemin et génération du processus contrôlés avant suivi RE_Kenshi' {
    foreach ($scenario in 'wrong-parent', 'wrong-path', 'reused-parent') {
        $r = Invoke-MonitorRegression $scenario
        Assert-Equal 0 $r.Summary.relaunches "$scenario : aucun faux passage RE_Kenshi"
        Assert-Equal '2026-01-02T10:00:04' ([datetime]$r.Summary.end).ToString('s') "$scenario : première fermeture retenue"
    }
}

Test-Case 'kenshi-monitor.ps1 : PID réutilisé avec autre date de création -> événement exclu' {
    $r = Invoke-MonitorRegression 'reused-event-pid'
    Assert-True (-not $r.Summary.crashed) 'même PID et chemin, autre génération exclue'
    Assert-Null $r.Summary.crash_time 'pas de date de plantage attribuée'
}

Test-Case 'kenshi-monitor.ps1 : rapport Windows retardé du PID suivi accepté, date de création facultative' {
    $r = Invoke-MonitorRegression 'delayed-report'
    Assert-True $r.Summary.crashed 'rapport écrit après fermeture accepté'
    Assert-Equal 'delayed-root.dll' $r.Summary.crash_module 'module du processus suivi'
    $late = Invoke-MonitorRegression 'very-delayed-report'
    Assert-True $late.Summary.crashed 'création identique : rapport plus de 60 s après fermeture accepté'
    Assert-Equal 'very-delayed-root.dll' $late.Summary.crash_module 'rapport tardif du processus suivi'
    $legacy = Invoke-MonitorRegression 'missing-event-start'
    Assert-True $legacy.Summary.crashed 'repli sur le PID lorsque Windows ne donne pas la création'
    Assert-Equal 'legacy-root.dll' $legacy.Summary.crash_module 'rapport partiel conservé'
}

Test-Case 'kenshi-monitor.ps1 : événement sans PID lisible -> rattaché par la fenêtre de la session' {
    $r = Invoke-MonitorRegression 'missing-event-pid'
    Assert-True $r.Summary.crashed 'PID illisible, événement 36 s après la fermeture : plantage retenu'
    Assert-Equal 'no-pid.dll' $r.Summary.crash_module 'module de l''événement'
    $late = Invoke-MonitorRegression 'missing-event-pid-late'
    Assert-True (-not $late.Summary.crashed) 'PID illisible, plus de 60 s après la fermeture : exclu'
}

Test-Case 'kenshi-monitor.ps1 : gel (événement 1002 ou code 0xCFFFFFFF) -> hung, sans plantage' {
    $r = Invoke-MonitorRegression 'hang'
    Assert-True $r.Summary.hung 'événement de gel du processus suivi'
    Assert-Equal '2026-01-02T10:00:30' ([datetime]$r.Summary.hang_time).ToString('s') 'heure du gel'
    Assert-True (-not $r.Summary.crashed) 'un gel n''est pas un plantage'
    $other = Invoke-MonitorRegression 'hang-other-pid'
    Assert-True (-not $other.Summary.hung) 'gel d''un autre processus exclu'
    Assert-Null $other.Summary.hang_time 'pas d''heure de gel'
    $code = Invoke-MonitorRegression 'hang-exit-code'
    Assert-True $code.Summary.hung 'code de sortie 0xCFFFFFFF sans événement'
    Assert-Null $code.Summary.hang_time 'pas d''événement, pas d''heure'
    Assert-Equal -805306369 $code.Summary.exit_code 'code de sortie enregistré'
}
