[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$WebConfig,[Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Setup.Common.ps1"
Assert-SetupWindows
Write-Warning 'Legacy migration helper. For a new installation use Install.ps1 -Step Config.'
$fullDest=[IO.Path]::GetFullPath($Destination)
if(Test-Path -LiteralPath $fullDest){throw 'Destination exists; it will not be overwritten.'}
if($fullDest -match '(?i)\\inetpub\\wwwroot\\'){throw 'Keep the agent configuration outside the IIS website.'}
$destDir=Get-SetupDirectoryPath (Split-Path -Parent $fullDest)
New-RestrictedDirectory $destDir

[xml]$web=[IO.File]::ReadAllText((Resolve-Path -LiteralPath $WebConfig).Path)
[xml]$doc=[IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'agent\IISReports.Agent.exe.config.example'))
foreach($key in @('ConnStr','IISReportsCheckHosts','IISReportsCheckPorts','IISReportsAllowHttpChecks')){
 $a=$web.SelectSingleNode("/configuration/appSettings/add[@key='$key']")
 $b=$doc.SelectSingleNode("/configuration/appSettings/add[@key='$key']")
 if($null -ne $a){$b.SetAttribute('value',$a.value)}
}
Save-NewXml $doc $fullDest
# Configuration can contain SQL or webhook credentials. Restrict the file on NTFS.
Set-SetupFileAccess -Path $fullDest
Write-Host "Agent config created at $fullDest with Administrators/System-only ACL."
Write-Host 'With Integrated Security, grant SQL access to the SERVICE identity, not only the IIS pool.'
Write-Host 'Configure webhook URL/allowlist here; never put the agent config under the IIS website.'
