[CmdletBinding(SupportsShouldProcess=$true)]
param(
 [Parameter(Mandatory=$true)][string]$BuildDirectory,
 [Parameter(Mandatory=$true)][string]$ConfigFile,
 [string]$Destination='C:\Services\IISReportsAgentV3',
 [string[]]$LogRoots=@(),
 [switch]$SkipAutoDiscovery
)
$ErrorActionPreference='Stop'
$name='IISReportsAgentV3';$account="NT SERVICE\$name"
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run elevated Windows PowerShell.'}
if(Get-Service -Name $name -ErrorAction SilentlyContinue){throw 'Service exists. Stop it and replace the compiled EXE manually; do not recreate its identity/config.'}
$exe=Join-Path $BuildDirectory 'IISReports.Agent.exe'
if(-not(Test-Path -LiteralPath $exe)){throw 'Run Build-And-Test.ps1 first.'}
[xml]$cfg=[IO.File]::ReadAllText((Resolve-Path -LiteralPath $ConfigFile).Path)
if(-not $cfg.SelectSingleNode('/configuration/appSettings/add[@key="ConnStr"]')){throw 'Agent config lacks ConnStr.'}
$target=[IO.Path]::GetFullPath($Destination).TrimEnd('\')
if($target -match '(?i)\\inetpub\\wwwroot(?:\\|$)'){throw 'Install the agent outside the IIS web root.'}
if(Test-Path -LiteralPath $target){throw 'Use a new empty destination outside the IIS website. Existing paths are not changed.'}
if(-not $PSCmdlet.ShouldProcess($target,'Create virtual-account Windows service (not started)')){return}
New-Item -ItemType Directory -Path $target -Force | Out-Null
# Restrict ACL before copying the configuration containing connection credentials.
& icacls.exe $target /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)(F)' '*S-1-5-18:(OI)(CI)(F)' | Out-Null
if($LASTEXITCODE -ne 0){throw 'Cannot restrict the service directory.'}
Copy-Item -LiteralPath $exe -Destination (Join-Path $target 'IISReports.Agent.exe')
Copy-Item -LiteralPath $ConfigFile -Destination (Join-Path $target 'IISReports.Agent.exe.config')
$bin='"'+(Join-Path $target 'IISReports.Agent.exe')+'"'
& sc.exe create $name binpath= $bin start= delayed-auto obj= $account DisplayName= 'IIS Reports v3 Agent'
if($LASTEXITCODE -ne 0){throw 'Service creation failed. See sc.exe output. No fallback to LocalSystem was attempted.'}
& sc.exe sidtype $name unrestricted | Out-Null
if($LASTEXITCODE -ne 0){throw 'Cannot set the service SID type.'}
& icacls.exe $target /grant "${account}:(OI)(CI)(RX)" | Out-Null
if($LASTEXITCODE -ne 0){throw 'Cannot grant agent read/execute rights.'}
$logs=Join-Path $target 'logs';New-Item -ItemType Directory -Path $logs | Out-Null
& icacls.exe $logs /grant "${account}:(OI)(CI)(M)" | Out-Null
if($LASTEXITCODE -ne 0){throw 'Cannot grant agent log write rights.'}
foreach($path in $LogRoots){
    if(Test-Path -LiteralPath $path){
        & icacls.exe $path /grant "${account}:(OI)(CI)(RX)" /T /C | Out-Null
        if($LASTEXITCODE -ne 0){throw "Cannot grant read rights on $path"}
    }else{Write-Warning "Log root does not exist: $path"}
}
if(-not $SkipAutoDiscovery) { & "$PSScriptRoot\Install-AutoDiscovery.ps1" -AgentDirectory $target }
Write-Host 'Service created but NOT started. Provision SQL permissions first, then Start-Service IISReportsAgentV3.'
Write-Host "Installed at $target. Protect this directory from ordinary users."
