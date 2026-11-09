#Requires -Version 5.1
$ErrorActionPreference='Stop'
$project=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$plan=@(& (Join-Path $project 'windows/Run-AllStudies.ps1') -PlanOnly)
if($plan.Count -ne 21 -or @($plan[0..13] | Where-Object Source -ne 'ohdsiStudy').Count -or
    @($plan[14..17] | Where-Object Source -ne 'phenotypeLibrary').Count -or
    @($plan | Where-Object Scenario -ne 'studySpecific').Count -or
    @($plan[18..20] | Where-Object Source -ne 'preset').Count -or
    ($plan[18..20].Study -join ',') -cne 'opioid,ppi,statin'){
    throw 'Wrong catalog, scenario, or ordering.'
}

$selected=@(& (Join-Path $project 'windows/Run-AllStudies.ps1') -PlanOnly -Study ppi,ohdsi_htn_acei_arb)
if(($selected.Study -join ',') -cne 'ohdsi_htn_acei_arb,ppi'){throw 'Study selection lost CDM-first order.'}
$invalid=$false
try { & (Join-Path $project 'windows/Run-AllStudies.ps1') -PlanOnly -Study antiemetic | Out-Null }
catch {$invalid=$_.Exception.Message -match 'outside this plan'}
if(-not $invalid){throw 'Study outside the 21-comparison plan was accepted.'}

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
if($Study -eq 'pl_uti_fluoroquinolone_cephalosporin'){throw 'Fixture vocabulary failure'}
'PASS' | Set-Content (Join-Path $out 'SUCCESS.txt')
'@ | Set-Content (Join-Path $temp 'windows/Run-YUHS-Methods.ps1')
    $run=Join-Path $temp 'windows/Run-AllStudies.ps1'
    $work=Join-Path $temp 'work'
    for($i=0;$i -lt 2;$i++){
        $caught=$false
        try { & $run -WorkDirectory $work -WarningAction SilentlyContinue }
        catch {$caught=$_.Exception.Message -match '^1 of 21 combinations failed'}
        if(-not $caught){throw 'Expected only the simulated vocabulary failure.'}
    }
    $rows=@(Import-Csv (Join-Path $work 'batch-status.csv'))
    if($rows.Count -ne 42 -or @($rows[0..20] | Where-Object Fit -eq 'complete').Count -ne 20 -or
        @($rows[21..41] | Where-Object Fit -eq 'reused').Count -ne 20 -or
        $rows[14].Fit -ne 'failed' -or $rows[20].Study -ne 'statin'){
        throw 'Batch continuation or successful-case reuse failed.'
    }
    $times=@(Import-Csv (Join-Path $work 'batch-timing.csv'))
    if($times.Count -ne 42 -or $times[0].FitSeconds -eq '' -or $times[21].FitSeconds -ne '' -or
        $times[0].Workers -ne '1' -or $times[18].Workers -ne '3'){
        throw 'Per-case timing, worker count or reuse accounting failed.'
    }
    Write-Host 'PASS: 21 ordered jobs, vocabulary failure recorded, other jobs continued, 20 successes reused.'
} finally {
    if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}
}
