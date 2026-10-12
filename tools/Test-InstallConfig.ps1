#requires -Version 5.1
# Read-only: validates both prepared configuration files; never prints passwords/ConnStr.
[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$ConfigDirectory,
 [string]$ExpectedSqlServer='', [string]$ExpectedDatabase='',
 [string]$ExpectedPublicUrl='', [string]$ExpectedEditor=''
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Setup.Common.ps1"
$dir=Get-SetupDirectoryPath $ConfigDirectory
$web=Get-SetupXmlSettings (Join-Path $dir 'Web.config')
$agent=Get-SetupXmlSettings (Join-Path $dir 'agent-local.config')
$w=Get-SetupSqlBuilder $web['ConnStr'];$a=Get-SetupSqlBuilder $agent['ConnStr']
foreach($pair in @(@{Name='Web';Builder=$w},@{Name='Agent';Builder=$a})){
 $b=$pair.Builder
 if([string]::IsNullOrWhiteSpace([string]$b['Data Source']) -or [string]::IsNullOrWhiteSpace([string]$b['Initial Catalog'])){throw "$($pair.Name) SQL server/database is empty."}
 if(-not [bool]$b['Encrypt']){throw "$($pair.Name) must use Encrypt=True."}
 if($ExpectedSqlServer -and [string]$b['Data Source'] -ine $ExpectedSqlServer){throw "$($pair.Name) targets another SQL instance. Review settings; configuration not changed."}
 if($ExpectedDatabase -and [string]$b['Initial Catalog'] -ine $ExpectedDatabase){throw "$($pair.Name) targets another database."}
 if(-not [bool]$b['Integrated Security'] -and ([string]::IsNullOrWhiteSpace([string]$b['User ID']) -or [string]::IsNullOrWhiteSpace([string]$b['Password']))){throw "$($pair.Name) SQL login or password is missing."}
}
if([string]$w['Data Source'] -ine [string]$a['Data Source'] -or [string]$w['Initial Catalog'] -ine [string]$a['Initial Catalog']){throw 'Web and agent must use the same server/database.'}
if([bool]$w['Integrated Security'] -ne [bool]$a['Integrated Security']){throw 'Do not mix Windows SQL and SQL-login authentication in generated configs.'}
if(-not [bool]$w['Integrated Security'] -and [string]$w['User ID'] -ieq [string]$a['User ID']){throw 'Web and agent must use separate SQL logins.'}
if($web['IISReportsAccessMode'] -ne 'windows' -or [string]::IsNullOrWhiteSpace([string]$web['IISReportsEditors'])){throw 'Generated configuration must use Windows mode with an explicit operator.'}
$origin=Get-CanonicalOrigin $web['IISReportsPublicOrigin']
if($ExpectedPublicUrl -and $origin -ne (Get-CanonicalOrigin $ExpectedPublicUrl)){throw 'PublicOrigin differs from the settings file. Do not disable CSRF; choose the intended browser URL.'}
if($ExpectedEditor -and @($web['IISReportsEditors'] -split ';'|ForEach-Object{$_.Trim()}) -notcontains $ExpectedEditor){throw 'Expected Windows operator is not in IISReportsEditors.'}
[xml]$doc=[IO.File]::ReadAllText((Join-Path $dir 'Web.config'))
if($doc.SelectSingleNode('/configuration/system.web/authentication').GetAttribute('mode') -ne 'Windows'){throw 'ASP.NET authentication mode must be Windows.'}
[pscustomobject]@{ConfigDirectory=$dir;SqlServer=$w['Data Source'];Database=$w['Initial Catalog'];SqlWindowsAuthentication=$w['Integrated Security'];SqlCertificateValidation=(-not [bool]$w['TrustServerCertificate']);PublicOrigin=$origin;Editors=$web['IISReportsEditors']} | Format-List | Out-Host
Write-Host 'PASS configuration pair. Both files exist and target the intended environment; secrets were not printed.'
