[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$WebConfig,[Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference='Stop'
$fullDest=[IO.Path]::GetFullPath($Destination)
if(Test-Path -LiteralPath $fullDest){throw 'Destination exists; it will not be overwritten.'}
if($fullDest -match '(?i)\\inetpub\\wwwroot\\'){throw 'Keep the agent configuration outside the IIS website.'}
$destDir=Split-Path -Parent $fullDest
if(-not (Test-Path -LiteralPath $destDir)){
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
}

[xml]$web=[IO.File]::ReadAllText((Resolve-Path -LiteralPath $WebConfig).Path)
[xml]$doc=[IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'agent\IISReports.Agent.exe.config.example'))
foreach($key in @('ConnStr','IISReportsCheckHosts','IISReportsCheckPorts','IISReportsAllowHttpChecks')){
 $a=$web.SelectSingleNode("/configuration/appSettings/add[@key='$key']")
 $b=$doc.SelectSingleNode("/configuration/appSettings/add[@key='$key']")
 if($null -ne $a){$b.SetAttribute('value',$a.value)}
}
$doc.Save($fullDest)
# Configuration can contain SQL or webhook credentials. Restrict the file on NTFS.
& icacls.exe $fullDest /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null
if($LASTEXITCODE -ne 0){throw 'Agent config created but the file ACL could not be restricted. Secure it before using.'}
Write-Host "Agent config created at $fullDest with Administrators/System-only ACL."
Write-Host 'With Integrated Security, grant SQL access to the SERVICE identity, not only the IIS pool.'
Write-Host 'Configure webhook URL/allowlist here; never put the agent config under the IIS website.'
