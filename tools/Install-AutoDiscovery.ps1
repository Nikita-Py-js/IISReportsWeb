#requires -Version 5.1
# Install/update the protected IIS inventory publisher. No SQL or IIS setting changes.
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string]$AgentDirectory='C:\Services\IISReportsAgentV3',
    [ValidateRange(1,30)][int]$IntervalMinutes=1,
    [switch]$NoGrantLogRead
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Setup.Common.ps1"
Assert-Administrator
if(-not [Environment]::Is64BitProcess -or $PSVersionTable.PSEdition -ne 'Desktop') { throw 'Use Windows PowerShell 5.1 x64.' }
$serviceName='IISReportsAgentV3'
$service=Get-Service -Name $serviceName -ErrorAction Stop
if($service.Status -ne 'Stopped') { throw 'Stop-Service IISReportsAgentV3 before updating automatic discovery.' }
$servicePath=(Get-CimInstance Win32_Service -Filter "Name='$serviceName'").PathName.Trim('"')
$exe=Join-Path ([IO.Path]::GetFullPath($AgentDirectory)) 'IISReports.Agent.exe'
if(-not [string]::Equals($servicePath,$exe,[StringComparison]::OrdinalIgnoreCase)) { throw 'AgentDirectory does not match the installed service executable.' }
$configPath=Join-Path $AgentDirectory 'IISReports.Agent.exe.config'
[xml]$config=[IO.File]::ReadAllText($configPath)
$dir=Join-Path $env:ProgramData 'IISReports\Discovery'
# Do not follow links or accept an existing directory writable by ordinary users.
$check=New-Object IO.DirectoryInfo($dir)
while($null -ne $check) {
    if($check.Exists -and (($check.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'Discovery directory has a reparse-point ancestor.' }
    $check=$check.Parent
}
$sid=(New-Object Security.Principal.NTAccount("NT SERVICE\$serviceName")).Translate([Security.Principal.SecurityIdentifier])
$root=Split-Path $PSScriptRoot -Parent
if(-not(Test-Path -LiteralPath "$root\discovery\Export-IISInventory.ps1")) { throw 'Publisher script is missing from the package.' }
if(-not $PSCmdlet.ShouldProcess($dir,'Install protected SYSTEM inventory publisher, periodic task and agent configuration')) {return}
Import-Module ScheduledTasks -ErrorAction Stop
$taskName='IISReports-DiscoverSites'
$old=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if($old) {
    $expectedScript=Join-Path $dir 'Export-IISInventory.ps1'
    if(@($old.Actions).Count -ne 1 -or [string]$old.Actions[0].Arguments -notlike ('*"'+$expectedScript+'"*')) {
        throw 'An unrelated task already uses IISReports-DiscoverSites. Resolve the name conflict manually.'
    }
    Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop
    for($i=0;$i -lt 30;$i++) {
        if((Get-ScheduledTask -TaskName $taskName).State -ne 'Running'){break}
        Start-Sleep -Milliseconds 200
    }
    if((Get-ScheduledTask -TaskName $taskName).State -eq 'Running'){throw 'Publisher is still running. Retry after it stops.'}
}
[void][IO.Directory]::CreateDirectory($dir)
# Protect the dedicated parent as well, so ordinary users cannot replace the child directory.
# Replace the DACL, including explicit entries. Agent has READ, never write access to SYSTEM scripts.
$acl=New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true,$false)
foreach($wellKnown in @('S-1-5-32-544','S-1-5-18')) {
    $identity=New-Object Security.Principal.SecurityIdentifier($wellKnown)
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
}
$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid,'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow')))
$acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
Set-Acl -LiteralPath (Split-Path $dir -Parent) -AclObject $acl
Set-Acl -LiteralPath $dir -AclObject $acl
foreach($child in Get-ChildItem -LiteralPath $dir -Force) {
    if($child.PSIsContainer -or (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'Unexpected directory/link in protected inventory directory.' }
    # Reset any prior explicit file ACL to the protected parent. Do not grant write to the agent.
    & icacls.exe $child.FullName /reset | Out-Null
    if($LASTEXITCODE -ne 0){throw 'Cannot reset publisher file ACL.'}
}
Copy-Item -LiteralPath "$root\discovery\Export-IISInventory.ps1" -Destination (Join-Path $dir 'Export-IISInventory.ps1') -Force
$settings=[ordered]@{agentSid=$sid.Value;grantAgentRead=(-not [bool]$NoGrantLogRead)}
[IO.File]::WriteAllText((Join-Path $dir 'publisher.json'),($settings|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
# Run the same script once now, so metadata errors are visible before service startup.
& (Join-Path $dir 'Export-IISInventory.ps1')
$ps=Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $dir 'Export-IISInventory.ps1')+'"'
$action=New-ScheduledTaskAction -Execute $ps -Argument $arguments
$trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
$startup=New-ScheduledTaskTrigger -AtStartup
$principal=New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
$options=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -StartWhenAvailable
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($trigger,$startup) -Principal $principal -Settings $options -Description 'IIS Reports: read-only IIS site inventory and read ACLs for W3C logs; no database access.' -Force | Out-Null
Copy-Item -LiteralPath $configPath -Destination ($configPath+'.bak-'+(Get-Date -Format 'yyyyMMddHHmmssfff'))
Set-XmlSetting $config 'IISReportsAutoDiscoveryEnabled' 'true'
Set-XmlSetting $config 'IISReportsDiscoveryManifest' (Join-Path $dir 'sites.json')
Set-XmlSetting $config 'IISReportsDiscoveryMaxAgeSeconds' ([string][Math]::Max(600,$IntervalMinutes*180))
$config.Save($configPath)
Write-Host "Installed $taskName (every $IntervalMinutes minute(s)); manifest $dir\sites.json. Agent is still stopped."
Write-Host 'New W3C log directories receive read permissions only. Monitoring checkboxes control import, not IIS logging or NTFS ACLs.'
