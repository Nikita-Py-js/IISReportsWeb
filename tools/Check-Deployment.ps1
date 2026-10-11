# Read-only quick checks for the CURRENT installed IIS Reports v3.
[CmdletBinding()]
param(
  [string]$WebRoot='C:\inetpub\wwwroot\IISReportsV3',
  [string]$BuildDirectory=(Join-Path (Split-Path $PSScriptRoot -Parent) 'build'),
  [string]$ServiceName='IISReportsAgentV3',
  [string]$ServiceRoot='C:\Services\IISReportsAgentV3'
)
$ErrorActionPreference='Stop'
$files=@(
 'index.html','Reports.ashx','v3.css','v3.js',
 'App_Code\Main.cs','App_Code\V3Api.cs','App_Code\Security.cs',
 'App_Code\V3Core.cs','App_Code\V3Import.cs','App_Code\V3Monitoring.cs',
 'Web.config'
)
$files | ForEach-Object {
  [PSCustomObject]@{Type='web';Name=$_;Present=(Test-Path -LiteralPath (Join-Path $WebRoot $_))}
} | Format-Table -AutoSize
$service=Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
[PSCustomObject]@{
 BuildExePresent=Test-Path -LiteralPath (Join-Path $BuildDirectory 'IISReports.Agent.exe')
 ServiceRegistered=($null -ne $service)
 ServiceStatus=if($null -eq $service){'not installed'}else{$service.Status.ToString()}
 InstalledExePresent=Test-Path -LiteralPath (Join-Path $ServiceRoot 'IISReports.Agent.exe')
 InstalledConfigPresent=Test-Path -LiteralPath (Join-Path $ServiceRoot 'IISReports.Agent.exe.config')
 ToolsExposedUnderWebRoot=Test-Path -LiteralPath (Join-Path $WebRoot 'tools')
 SqlExposedUnderWebRoot=Test-Path -LiteralPath (Join-Path $WebRoot 'sql')
 AgentExposedUnderWebRoot=Test-Path -LiteralPath (Join-Path $WebRoot 'agent')
} | Format-List
Write-Host 'No SQL connections, HTTP mutations, or filesystem changes were made.'
