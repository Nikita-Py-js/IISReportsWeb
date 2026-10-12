#requires -Version 5.1
# Create the dedicated virtual-account service; do not start it.
[CmdletBinding(SupportsShouldProcess=$true)]
param(
 [Parameter(Mandatory=$true)][string]$BuildDirectory,
 [Parameter(Mandatory=$true)][string]$ConfigFile,
 [string]$Destination='C:\Services\IISReportsAgentV3',
 [string[]]$LogRoots=@(),
 [switch]$SkipAutoDiscovery
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Setup.Common.ps1"
Assert-SetupWindows
$package=Split-Path $PSScriptRoot -Parent
Assert-SetupBuild -PackageRoot $package -BuildDirectory $BuildDirectory
Assert-SetupFile $ConfigFile 'Prepared agent-local.config'
$name='IISReportsAgentV3';$account="NT SERVICE\$name"
if(Get-Service -Name $name -ErrorAction SilentlyContinue){throw 'Service already exists. Use the Upgrade procedure; do not recreate its account or replace its config.'}
$exe=Join-Path $BuildDirectory 'IISReports.Agent.exe'
$null=Get-SetupXmlSettings $ConfigFile
$target=Get-SetupDirectoryPath $Destination
if($target -match '(?i)\\inetpub\\wwwroot(?:\\|$)'){throw 'Install the agent outside the IIS web root.'}
if(Test-Path -LiteralPath $target){
 if(@(Get-ChildItem -LiteralPath $target -Force).Count -gt 0){throw 'Service directory is not empty. Inspect it before continuing; no files were changed.'}
}
foreach($path in $LogRoots){$null=Get-SetupDirectoryPath $path}
if(-not $PSCmdlet.ShouldProcess($target,'Create virtual-account Windows service (not started)')){return}
New-RestrictedDirectory $target
Copy-Item -LiteralPath $exe -Destination (Join-Path $target 'IISReports.Agent.exe')
Copy-Item -LiteralPath $ConfigFile -Destination (Join-Path $target 'IISReports.Agent.exe.config')
$bin='"'+(Join-Path $target 'IISReports.Agent.exe')+'"'
$sc=Join-Path $env:windir 'System32\sc.exe'
Invoke-SetupNative -FilePath $sc -Arguments @('create',$name,'binpath=',$bin,'start=','demand','obj=',$account,'DisplayName=','IIS Reports v3 Agent')
Invoke-SetupNative -FilePath $sc -Arguments @('sidtype',$name,'unrestricted')
Set-SetupDirectoryAccess -Directory $target -ReadAccounts @($account)
$logs=Join-Path $target 'logs';[void][IO.Directory]::CreateDirectory($logs)
Set-SetupDirectoryAccess -Directory $logs -ReadAccounts @($account) -ModifyAccounts @($account)
foreach($path in $LogRoots){
 if(Test-Path -LiteralPath $path){Grant-SetupLogRead -Directory $path -Account $account}
 else{Write-Warning "Log root does not exist: $path"}
}
if(-not $SkipAutoDiscovery){& "$PSScriptRoot\Install-AutoDiscovery.ps1" -AgentDirectory $target}
Write-Host "Service created in Manual/Stopped state at $target. Configure SQL and pass SecurityTest, then run Install.ps1 -Step Start."
