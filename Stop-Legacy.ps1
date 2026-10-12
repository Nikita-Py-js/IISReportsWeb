# Optional migration step. Stops only the old IIS Reports service and discovery task.
# No deletion, no SQL writes, no changes to other IIS sites.
[CmdletBinding(SupportsShouldProcess=$true)]
param()
$ErrorActionPreference='Stop'
$service=Get-Service 'IISReportsAgentV3' -ErrorAction SilentlyContinue
if($service -and $PSCmdlet.ShouldProcess('IISReportsAgentV3','Stop and disable old service')) {
    if($service.Status -ne 'Stopped'){Stop-Service -Name $service.Name}
    Set-Service -Name $service.Name -StartupType Disabled
}
if(Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue){
    $task=Get-ScheduledTask -TaskName 'IISReports-DiscoverSites' -ErrorAction SilentlyContinue
    if($task -and $PSCmdlet.ShouldProcess('IISReports-DiscoverSites','Stop and disable old task')){
        Stop-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue
        Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath | Out-Null
    }
}
Write-Host 'Legacy components are stopped/disabled (or were absent). SQL history and old files were not deleted.'
