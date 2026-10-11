# Standalone clean-install configuration. No old Web.config is needed.
[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$ConfigDirectory,
 [Parameter(Mandatory=$true)][string]$SqlServer,
 [string]$Database='IISReports',
 [Parameter(Mandatory=$true)][string]$Editor,
 [string]$Readers='',
 [Parameter(Mandatory=$true)][string]$PublicUrl,
 [System.Management.Automation.PSCredential]$WebSqlCredential,
 [System.Management.Automation.PSCredential]$AgentSqlCredential,
 [switch]$TrustServerCertificate
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Setup.Common.ps1"
Assert-Administrator
$origin=Get-CanonicalOrigin $PublicUrl
if(([uri]$PublicUrl).AbsolutePath -ne '/') { throw 'Clean site installer expects a root application URL; use /, not a subdirectory.' }
if([string]::IsNullOrWhiteSpace($Editor) -or $Editor.Contains(';')) { throw 'Provide one exact initial Windows operator or group.' }
try { $null=(New-Object Security.Principal.NTAccount($Editor)).Translate([Security.Principal.SecurityIdentifier]) }
catch { throw "Cannot resolve Windows account/group: $Editor" }
if(($null -eq $WebSqlCredential) -ne ($null -eq $AgentSqlCredential)) { throw 'Provide both separate SQL credentials, or neither for Windows SQL authentication.' }
if($null -ne $WebSqlCredential -and $WebSqlCredential.UserName -eq $AgentSqlCredential.UserName) { throw 'Use distinct SQL logins for web and agent.' }
$dir=Get-SetupDirectoryPath -Directory $ConfigDirectory
if($dir -match '(?i)\\inetpub\\wwwroot(?:\\|$)') { throw 'Put installation secrets outside all IIS roots (for example C:\Deploy\IISReports-config).' }
foreach($name in @('Web.config','agent-local.config')) { if(Test-Path -LiteralPath (Join-Path $dir $name)) { throw "Configuration already exists: $name. No files were changed." } }
$root=Split-Path $PSScriptRoot -Parent
[xml]$web=[IO.File]::ReadAllText("$root\web\Web.config.example")
[xml]$agent=[IO.File]::ReadAllText("$root\agent\IISReports.Agent.exe.config.example")
Set-XmlSetting $web 'ConnStr' (New-SqlConnectionString -SqlServer $SqlServer -Database $Database -Credential $WebSqlCredential -TrustServerCertificate ([bool]$TrustServerCertificate) -Application 'IISReports.Web')
Set-XmlSetting $agent 'ConnStr' (New-SqlConnectionString -SqlServer $SqlServer -Database $Database -Credential $AgentSqlCredential -TrustServerCertificate ([bool]$TrustServerCertificate) -Application 'IISReports.Agent')
Set-XmlSetting $web 'IISReportsEditors' $Editor
Set-XmlSetting $web 'IISReportsReaders' $Readers
Set-XmlSetting $web 'IISReportsAccessMode' 'windows'
Set-XmlSetting $web 'IISReportsPublicOrigin' $origin
# Validate templates and connection settings before changing any ACL.
New-RestrictedDirectory -Directory $dir
Save-NewXml $web (Join-Path $dir 'Web.config')
Save-NewXml $agent (Join-Path $dir 'agent-local.config')
Write-Host "Created Web.config and agent-local.config in $dir. Secrets were not printed."
Write-Host "Public browser origin: $origin. Use this exact scheme/host/port in browser and Test-Http."
