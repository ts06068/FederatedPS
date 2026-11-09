#Requires -Version 5.1
$ErrorActionPreference='Stop'
$project=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$plan=@(& (Join-Path $project 'windows/Run-AllStudies.ps1') -PlanOnly)
if($plan.Count -ne 31 -or @($plan[0..13] | Where-Object Source -ne 'ohdsiStudy').Count -or
    @($plan[14..17] | Where-Object Source -ne 'phenotypeLibrary').Count -or
    @($plan | Where-Object Scenario -ne 'studySpecific').Count -or
    @($plan[18..30] | Where-Object Source -ne 'preset').Count -or
    @($plan[18..30] | Group-Object Study | Where-Object Count -ne 1).Count){
    throw 'Wrong catalog, scenario, or ordering.'
}

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
        catch {$caught=$_.Exception.Message -match '^1 of 31 combinations failed'}
        if(-not $caught){throw 'Expected only the simulated vocabulary failure.'}
    }
    $rows=@(Import-Csv (Join-Path $work 'batch-status.csv'))
    if($rows.Count -ne 62 -or @($rows[0..30] | Where-Object Fit -eq 'complete').Count -ne 30 -or
        @($rows[31..61] | Where-Object Fit -eq 'reused').Count -ne 30 -or
        $rows[14].Fit -ne 'failed' -or $rows[30].Study -ne 'statin'){
        throw 'Batch continuation or successful-case reuse failed.'
    }
    Write-Host 'PASS: 31 ordered jobs, vocabulary failure recorded, other jobs continued, 30 successes reused.'
} finally {
    if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}
}
