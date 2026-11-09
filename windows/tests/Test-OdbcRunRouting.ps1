#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$temp=Join-Path ([IO.Path]::GetTempPath()) ('fps-run-odbc-'+[guid]::NewGuid().ToString('N'))
try {
    $target=Join-Path $temp 'FederatedPS/windows'
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Copy-Item (Join-Path $root 'fresh/RUN.ps1') $temp
    @'
param($Family,[switch]$PlanOnly,[switch]$ExportSmd,$PatientLimits,$CdmExtractionWorkers)
[pscustomobject]@{Family=$Family;Plan=$PlanOnly.IsPresent;Export=$ExportSmd.IsPresent;
    Limits=$PatientLimits;CdmWorkers=$CdmExtractionWorkers}
'@ | Set-Content (Join-Path $target 'Run-AllStudies.ps1')
    @'
param($InstallRoot,$RHome,$JavaHome,$DbBackend)
if(Test-Path (Join-Path $PSScriptRoot 'fail-update')){throw 'fixture update failed'}
"$DbBackend/$InstallRoot" | Set-Content (Join-Path $PSScriptRoot 'updated')
'@ | Set-Content (Join-Path $target 'Update-FederatedPs.ps1')
    $run=Join-Path $temp 'RUN.ps1'
    $r=& $run
    if(-not $r.Export){throw 'RUN must export SMD by default.'}
    $r=& $run -PlanOnly -UpdatePackage -Family Cdm -SkipSmd -PatientLimits @{2=100} -CdmExtractionWorkers 3
    if(-not $r.Plan -or $r.Export -or $r.Family -ne 'Cdm' -or $r.Limits[2] -ne 100 -or
        $r.CdmWorkers -ne 3 -or (Test-Path (Join-Path $target 'updated'))){throw 'Wrong plan/override handling.'}
    & $run -UpdatePackage -InstallRoot fixture | Out-Null
    if((Get-Content (Join-Path $target 'updated')).Trim() -cne 'odbc/fixture'){throw 'Wrong update backend or install root.'}
    '' | Set-Content (Join-Path $target 'fail-update')
    $caught=$false
    try { & $run -UpdatePackage | Out-Null } catch {$caught=$_.Exception.Message -match 'fixture update failed'}
    if(-not $caught){throw 'Update failure was not propagated.'}
    Write-Host 'PASS: RUN uses the study batch, exports SMD by default and forwards plan and runtime options.'
} finally {if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}}
