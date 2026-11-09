#Requires -Version 5.1
$ErrorActionPreference='Stop'
$project=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$plan=@(& (Join-Path $project 'windows/Run-AllStudies.ps1') -PlanOnly)
$expected=@(
    'ohdsi_htn_acei_thiazide','ohdsi_htn_chlorthalidone_hctz',
    'ohdsi_depression_sertraline_duloxetine','ohdsi_levetiracetam_phenytoin','ohdsi_alendronate_raloxifene',
    'opioid','ppi','statin'
)
if($plan.Count -ne 8 -or ($plan.Study -join ',') -cne ($expected -join ',') -or
    @($plan[0..4] | Where-Object Source -ne 'ohdsiStudy').Count -or
    @($plan[5..7] | Where-Object Source -ne 'preset').Count -or
    @($plan | Where-Object Scenario -ne 'studySpecific').Count){
    throw 'Wrong catalog, scenario, or ordering.'
}

$selected=@(& (Join-Path $project 'windows/Run-AllStudies.ps1') -PlanOnly -Study ppi,ohdsi_htn_acei_thiazide)
if(($selected.Study -join ',') -cne 'ohdsi_htn_acei_thiazide,ppi'){throw 'Study selection lost CDM-first order.'}
$invalid=$false
try { & (Join-Path $project 'windows/Run-AllStudies.ps1') -PlanOnly -Study antiemetic | Out-Null }
catch {$invalid=$_.Exception.Message -match 'outside this plan'}
if(-not $invalid){throw 'Study outside the 8-comparison plan was accepted.'}

$temp=Join-Path ([IO.Path]::GetTempPath()) ('fps-allstudies-'+[guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path (Join-Path $temp 'windows/config'),(Join-Path $temp 'inst/studies') -Force | Out-Null
    Copy-Item (Join-Path $project 'windows/Run-AllStudies.ps1') (Join-Path $temp 'windows')
    Copy-Item (Join-Path $project 'inst/studies/registry.json') (Join-Path $temp 'inst/studies')
    Copy-Item (Join-Path $project 'windows/config/yuhs-sites.json') (Join-Path $temp 'windows/config')
    '' | Set-Content (Join-Path $temp 'windows/Common.ps1')
    @'
param($Project,$ConfigDirectory,$InstallRoot,$RHome,$JavaHome)
'@ | Set-Content (Join-Path $temp 'windows/Test-OdbcConnection.ps1')
    @'
param($InstallRoot,$RHome,$JavaHome,$DbBackend,[bool]$Test,$Study,$Scenario,$Methods,$RunId,
    $PatientLimit,$PatientLimits,$ExtractionWorkers,$StatusSeconds,$WorkDirectory,$ConfigDirectory,
    $DbQueryTimeoutSeconds,$RunTimeoutSeconds)
if($Test -or $DbBackend -ne 'odbc' -or ($Methods -join ',') -ne 'local-only,pooled'){throw 'Wrong fixture options'}
$out=Join-Path $WorkDirectory $RunId
New-Item -ItemType Directory -Path $out | Out-Null
@{test=$Test;study=$Study;scenario=$Scenario;dbBackend=$DbBackend;methods=$Methods;
    sites=@('1','2','3');patientLimits=@{'1'=0;'2'=0;'3'=0}} |
    ConvertTo-Json | Set-Content (Join-Path $out 'run.json')
if($Study -eq 'ohdsi_htn_chlorthalidone_hctz'){throw 'Fixture vocabulary failure'}
'PASS' | Set-Content (Join-Path $out 'SUCCESS.txt')
'@ | Set-Content (Join-Path $temp 'windows/Run-YUHS-Methods.ps1')
    $run=Join-Path $temp 'windows/Run-AllStudies.ps1'
    $work=Join-Path $temp 'work'
    for($i=0;$i -lt 2;$i++){
        $caught=$false
        try { & $run -WorkDirectory $work -WarningAction SilentlyContinue }
        catch {$caught=$_.Exception.Message -match '^1 of 8 combinations failed'}
        if(-not $caught){throw 'Expected only the simulated vocabulary failure.'}
    }
    $rows=@(Import-Csv (Join-Path $work 'batch-status.csv'))
    if($rows.Count -ne 16 -or @($rows[0..7] | Where-Object Fit -eq 'complete').Count -ne 7 -or
        @($rows[8..15] | Where-Object Fit -eq 'reused').Count -ne 7 -or
        $rows[1].Fit -ne 'failed' -or $rows[7].Study -ne 'statin'){
        throw 'Batch continuation or successful-case reuse failed.'
    }
    $times=@(Import-Csv (Join-Path $work 'batch-timing.csv'))
    if($times.Count -ne 16 -or $times[0].FitSeconds -eq '' -or $times[8].FitSeconds -ne '' -or
        $times[0].Workers -ne '1' -or $times[5].Workers -ne '3'){
        throw 'Per-case timing, worker count or reuse accounting failed.'
    }
    Write-Host 'PASS: 8 ordered jobs, vocabulary failure recorded, other jobs continued, 7 successes reused.'
} finally {
    if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}
}
