[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$ExistingWebConfig,
 [Parameter(Mandatory=$true)][string]$Destination,
 [Parameter(Mandatory=$true)][string]$Editor,
 [string]$PublicOrigin=''
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Setup.Common.ps1"
Assert-SetupWindows
Write-Warning 'Legacy migration helper. For a new installation use Install.ps1 -Step Config.'
$fullDest=[IO.Path]::GetFullPath($Destination)
if(Test-Path -LiteralPath $fullDest){throw 'Destination exists. This script will not overwrite it.'}
$destDir=Get-SetupDirectoryPath (Split-Path -Parent $fullDest)
New-RestrictedDirectory $destDir

[xml]$old=[IO.File]::ReadAllText((Resolve-Path -LiteralPath $ExistingWebConfig).Path)
$setting=$old.SelectSingleNode('/configuration/appSettings/add[@key="ConnStr"]')
if($null -eq $setting -or [string]::IsNullOrWhiteSpace($setting.value)){throw 'Existing config has no appSettings ConnStr.'}
$template=Join-Path (Split-Path $PSScriptRoot -Parent) 'web\Web.config.example'
[xml]$doc=[IO.File]::ReadAllText($template)
$doc.SelectSingleNode('/configuration/appSettings/add[@key="ConnStr"]').SetAttribute('value',$setting.value)
$doc.SelectSingleNode('/configuration/appSettings/add[@key="IISReportsEditors"]').SetAttribute('value',$Editor)
$doc.SelectSingleNode('/configuration/appSettings/add[@key="IISReportsPublicOrigin"]').SetAttribute('value',$PublicOrigin)
Save-NewXml $doc $fullDest
Write-Host 'Created v3 config with the existing connection string. No connection string was printed.'
Write-Host 'Review other custom settings in the old file; this script does not migrate rewrite rules or authentication modules.'
