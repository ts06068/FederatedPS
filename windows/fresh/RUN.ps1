#Requires -Version 5.1
# Run the selected studySpecific comparisons against the existing YUHS ODBC setup.
[CmdletBinding()]
param(
    [ValidateSet('All','Cdm','Preset')][string]$Family='All',
    [string[]]$Study=@(),
    [switch]$PlanOnly, [switch]$SkipSmd, [switch]$UpdatePackage,
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
$project=Join-Path $PSScriptRoot 'FederatedPS'
if($UpdatePackage -and -not $PlanOnly){
    & (Join-Path $project 'windows/Update-FederatedPs.ps1') -InstallRoot $InstallRoot `
        -RHome $RHome -JavaHome $JavaHome -DbBackend odbc
}
$forward=@{}+$PSBoundParameters
$forward.Remove('UpdatePackage')
$forward.Remove('SkipSmd')
$forward['ExportSmd']=-not $SkipSmd
& (Join-Path $project 'windows/Run-AllStudies.ps1') @forward
