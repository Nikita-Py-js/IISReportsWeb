# Read-only quick checks for the CURRENT installed IIS Reports v3.
[CmdletBinding()]
param(
  [string]$WebRoot='C:\inetpub\wwwroot\IISReportsV3',
  [string]$BuildDirectory=(Join-Path (Split-Path $PSScriptRoot -Parent) 'build'),
  [string]$ServiceName='IISReportsAgentV3',
  [string]$ServiceRoot='C:\Services\IISReportsAgentV3',
  [switch]$Strict
)
$ErrorActionPreference='Stop'
$files=@(
 'index.html','Reports.ashx','v3.css','v3.js',
 'App_Code\Main.cs','App_Code\V3Api.cs','App_Code\Security.cs',
 'App_Code\V3Core.cs','App_Code\V3Import.cs','App_Code\V3Monitoring.cs','App_Code\V3Discovery.cs',
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
if(Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
    Get-ScheduledTask -TaskName 'IISReports-DiscoverSites' -ErrorAction SilentlyContinue | Select-Object TaskName,State | Format-Table -AutoSize
}
[pscustomobject]@{InventorySnapshotPresent=Test-Path -LiteralPath (Join-Path $env:ProgramData 'IISReports\Discovery\sites.json')} | Format-List
Write-Host 'No SQL connections, HTTP mutations, or filesystem changes were made.'

if($Strict) {
 $missing=@($files | Where-Object {-not(Test-Path -LiteralPath (Join-Path $WebRoot $_) -PathType Leaf)})
 if($missing.Count -gt 0){throw ('Missing installed web files: '+($missing -join ', '))}
 if($null -eq $service -or $service.Status -ne 'Running'){throw 'Windows agent service is not running.'}
 foreach($name in @('IISReports.Agent.exe','IISReports.Agent.exe.config')){if(-not(Test-Path -LiteralPath (Join-Path $ServiceRoot $name) -PathType Leaf)){throw "Missing installed service file: $name"}}
 foreach($name in @('tools','sql','agent','tests','docs','setup')){if(Test-Path -LiteralPath (Join-Path $WebRoot $name)){throw "Source/setup directory is exposed under web root: $name"}}
 if($null -eq (Get-ScheduledTask -TaskName 'IISReports-DiscoverSites' -ErrorAction SilentlyContinue)){throw 'Automatic discovery task is missing.'}
 if(-not(Test-Path -LiteralPath (Join-Path $env:ProgramData 'IISReports\Discovery\sites.json') -PathType Leaf)){throw 'Discovery inventory has not been created yet. Inspect the discovery task.'}
 Write-Host 'PASS deployed file/service checks. HTTP health is a separate check.'
}
