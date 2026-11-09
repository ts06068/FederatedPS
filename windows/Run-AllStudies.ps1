#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('All','Cdm','Preset')][string]$Family='All',
    [string[]]$Study=@(),
    [switch]$PlanOnly, [switch]$ExportSmd,
    [string]$WorkDirectory='',
    [ValidateRange(0,2147483647)][int]$PatientLimit=0,
    [hashtable]$PatientLimits=@{},
    [ValidateRange(1,3)][int]$CdmExtractionWorkers=1,
    [ValidateRange(1,3)][int]$PresetExtractionWorkers=3,
    [ValidateRange(1,3600)][int]$StatusSeconds=10,
    [ValidateRange(1,2147483647)][int]$DbQueryTimeoutSeconds=7200,
    [ValidateRange(1,2147483647)][int]$RunTimeoutSeconds=86400,
    [string]$InstallRoot='C:\FederatedPS',
    [string]$RHome='C:\Program Files\R\R-4.6.1',
    [string]$JavaHome='', [string]$ConfigDirectory=''
)
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
$registry=Get-Content -LiteralPath (Join-Path $project 'inst/studies/registry.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$cdmStudies=@(
    'ohdsi_htn_acei_thiazide','ohdsi_htn_chlorthalidone_hctz',
    'ohdsi_depression_sertraline_duloxetine','ohdsi_levetiracetam_phenytoin','ohdsi_alendronate_raloxifene'
)
$presets=@('opioid','ppi','statin')
$plan=@(
    if($Family -ne 'Preset'){
        foreach($key in $cdmStudies){
            $found=@($registry | Where-Object {
                $_.study -ceq $key -and $_.sourceType -ceq 'ohdsiStudy' -and
                -not [string]::IsNullOrWhiteSpace($_.doi)
            })
            if($found.Count -ne 1){throw "Missing published CDM definition: $key."}
            [pscustomobject]@{Study=$key;Scenario='studySpecific';Source=$found[0].sourceType;Workers=$CdmExtractionWorkers}
        }
    }
    if($Family -ne 'Cdm'){
        foreach($preset in $presets){
            [pscustomobject]@{Study=$preset;Scenario='studySpecific';Source='preset';Workers=$PresetExtractionWorkers}
        }
    }
)
if(@($plan | Group-Object Study,Scenario | Where-Object Count -ne 1).Count){
    throw 'Duplicate study/scenario in the batch plan.'
}
if($Study.Count){
    $unknown=@($Study | Where-Object {$_ -cnotin $plan.Study})
    if($unknown.Count){throw "Studies outside this plan: $($unknown -join ', ')."}
    $plan=@($plan | Where-Object {$_.Study -cin $Study})
}
if($PlanOnly){$plan;return}

. (Join-Path $PSScriptRoot 'Common.ps1')
if(-not $ConfigDirectory){$ConfigDirectory=Join-Path $PSScriptRoot 'config'}
if(-not $WorkDirectory){$WorkDirectory=Join-Path $project 'work/all-studies'}
$WorkDirectory=[IO.Path]::GetFullPath($WorkDirectory)
$mappingPath=Join-Path $ConfigDirectory 'yuhs-sites.json'
if(-not (Test-Path -LiteralPath $mappingPath)){$mappingPath=Join-Path $PSScriptRoot 'config/yuhs-sites.json'}
$mapping=Get-Content -LiteralPath $mappingPath -Raw -Encoding UTF8 | ConvertFrom-Json
$limits=@{}
foreach($property in $mapping.PSObject.Properties){$limits[[string]$property.Value]=$PatientLimit}
if($PatientLimit -eq 1){throw 'PatientLimit must be zero or at least two.'}
foreach($key in $PatientLimits.Keys){
    $id=[string]$key
    $value=$PatientLimits[$key]
    $n=0L
    if(-not $limits.ContainsKey($id) -or $null -eq $value -or $value -is [bool] -or
        -not [long]::TryParse([string]$value,[ref]$n) -or $n -lt 0 -or $n -eq 1 -or $n -gt 2147483647){
        throw "PatientLimits[$key] must use a configured site ID and a limit of zero or at least two."
    }
    $limits[$id]=[int]$n
}

function Find-CompletedStudy($Directory,$Item,$Limits){
    foreach($candidate in (Get-ChildItem -LiteralPath $Directory -Directory | Sort-Object LastWriteTime -Descending)){
        if(-not (Test-Path -LiteralPath (Join-Path $candidate.FullName 'SUCCESS.txt'))){continue}
        try {$run=Get-Content -LiteralPath (Join-Path $candidate.FullName 'run.json') -Raw -Encoding UTF8 | ConvertFrom-Json}
        catch {continue}
        if($run.test -ne $false -or $run.study -cne $Item.Study -or $run.scenario -cne $Item.Scenario -or
            $run.dbBackend -cne 'odbc' -or ($run.methods -join ',') -cne 'local-only,pooled' -or
            @($run.sites).Count -ne $Limits.Count -or $null -eq $run.patientLimits){continue}
        $matches=$true
        foreach($id in $Limits.Keys){
            $value=$run.patientLimits.PSObject.Properties[$id]
            if(-not $value -or $value.Value -ne $Limits[$id]){$matches=$false;break}
        }
        if($matches){return $candidate.FullName}
    }
}

$runtimeArgs=@{InstallRoot=$InstallRoot;RHome=$RHome;JavaHome=$JavaHome}
# Probe once per invocation before any database extraction.
& (Join-Path $PSScriptRoot 'Test-OdbcConnection.ps1') -Project $project -ConfigDirectory $ConfigDirectory @runtimeArgs
New-Item -ItemType Directory -Path $WorkDirectory -Force | Out-Null
$report=Join-Path $WorkDirectory 'batch-status.csv'
$timings=Join-Path $WorkDirectory 'batch-timing.csv'
$failed=0
for($i=0;$i -lt $plan.Count;$i++){
    $item=$plan[$i]
    $work=Join-Path (Join-Path $WorkDirectory $item.Study) $item.Scenario
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $result=Find-CompletedStudy $work $item $limits
    $state='reused'
    $smdState='not-requested'
    $message=''
    $fitSeconds=$null
    $smdSeconds=$null
    $caseClock=[Diagnostics.Stopwatch]::StartNew()
    Write-Host "[$($i+1)/$($plan.Count)] $($item.Study)/$($item.Scenario)"
    try {
        if(-not $result){
            $runId=[guid]::NewGuid().ToString('N')
            $result=Join-Path $work $runId
            $state='failed'
            $fitStart=$caseClock.Elapsed.TotalSeconds
            & (Join-Path $PSScriptRoot 'Run-YUHS-Methods.ps1') @runtimeArgs -DbBackend odbc -Test $false `
                -Study $item.Study -Scenario $item.Scenario -Methods local-only,pooled -RunId $runId `
                -PatientLimit $PatientLimit -PatientLimits $PatientLimits -ExtractionWorkers $item.Workers `
                -StatusSeconds $StatusSeconds -WorkDirectory $work -ConfigDirectory $ConfigDirectory `
                -DbQueryTimeoutSeconds $DbQueryTimeoutSeconds -RunTimeoutSeconds $RunTimeoutSeconds
            if(-not (Test-Path -LiteralPath (Join-Path $result 'SUCCESS.txt'))){throw 'Missing successful fit marker.'}
            $state='complete'
            $fitSeconds=[Math]::Round($caseClock.Elapsed.TotalSeconds-$fitStart,1)
        }
        if($ExportSmd){
            $smdState='failed'
            $smdStart=$caseClock.Elapsed.TotalSeconds
            $runtime=Set-FederatedEnvironment @runtimeArgs
            Invoke-FederatedR $runtime.Rscript @((Join-Path $PSScriptRoot 'Export-StudySmd.R'),$result,$InstallRoot)
            $smdState='complete'
            $smdSeconds=[Math]::Round($caseClock.Elapsed.TotalSeconds-$smdStart,1)
        }
    } catch {
        $failed++
        $message=$_.Exception.Message
        Write-Warning "$($item.Study)/$($item.Scenario): $message"
    }
    $caseClock.Stop()
    $totalSeconds=[Math]::Round($caseClock.Elapsed.TotalSeconds,1)
    [pscustomobject]@{
        Time=[DateTime]::Now.ToString('o'); Study=$item.Study; Scenario=$item.Scenario; Source=$item.Source
        Workers=$item.Workers; Fit=$state; Smd=$smdState; FitSeconds=$fitSeconds
        SmdSeconds=$smdSeconds; TotalSeconds=$totalSeconds; Directory=$result
    } | Export-Csv -LiteralPath $timings -NoTypeInformation -Encoding UTF8 -Append
    Write-Host "$($item.Study)/$($item.Scenario): fit=$state; SMD=$smdState; elapsed ${totalSeconds}s"
    [pscustomobject]@{
        Time=[DateTime]::Now.ToString('o'); Study=$item.Study; Scenario=$item.Scenario; Source=$item.Source
        Fit=$state; Smd=$smdState; Directory=$result; Error=$message
    } | Export-Csv -LiteralPath $report -NoTypeInformation -Encoding UTF8 -Append
}
Write-Host "Batch status: $report"
Write-Host "Batch timing: $timings"
if($failed){throw "$failed of $($plan.Count) combinations failed. See batch-status.csv for individual results."}
