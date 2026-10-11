#requires -Version 5.1
# Runs as SYSTEM in Task Scheduler. Read IIS metadata; never execute SQL or mutate IIS.
# No web-supplied paths or usernames are accepted. Installation settings are admin-only.
[CmdletBinding()]
param([string]$SettingsFile = (Join-Path $PSScriptRoot 'publisher.json'))
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$settings = ConvertFrom-Json ([IO.File]::ReadAllText($SettingsFile))
$destination = Join-Path $PSScriptRoot 'sites.json'
function Write-Inventory($Snapshot) {
    $text = $Snapshot | ConvertTo-Json -Depth 8
    $temp = Join-Path $PSScriptRoot ('sites-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temp,$text,(New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($destination)) { [IO.File]::Replace($temp,$destination,$null) }
        else { [IO.File]::Move($temp,$destination) }
    } finally { if([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
function Assert-LocalDirectory([string]$Path) {
    if($Path -notmatch '^[A-Za-z]:\\' -or $Path.StartsWith('\\')) { throw 'Only local drive paths are supported automatically.' }
    $dir = New-Object IO.DirectoryInfo($Path)
    while ($null -ne $dir) {
        if ($dir.Exists -and (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw 'Reparse points are not allowed in automatic log paths.'
        }
        $dir = $dir.Parent
    }
}
function Grant-LogRead([string]$Path,[Security.Principal.SecurityIdentifier]$Sid) {
    # Change only the selected log directory ACL, not IIS config or the disk root.
    $acl = Get-Acl -LiteralPath $Path
    $required = [Security.AccessControl.FileSystemRights]::ReadAndExecute
    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    $present = @($acl.GetAccessRules($true,$false,[Security.Principal.SecurityIdentifier]) | Where-Object {
        $_.IdentityReference.Value -eq $Sid.Value -and $_.AccessControlType -eq 'Allow' -and
        ($_.FileSystemRights -band $required) -eq $required -and ($_.InheritanceFlags -band $inherit) -eq $inherit
    })
    if($present.Count -eq 0) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($Sid,$required,$inherit,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $Path -AclObject $acl
    }
}
$manager = $null
$snapshot = [ordered]@{version=1;machineName=$env:COMPUTERNAME;generatedUtc=[DateTime]::UtcNow.ToString('o');success=$false;error='';sites=@()}
try {
    if(-not [Environment]::Is64BitProcess) { throw 'Use x64 Windows PowerShell for IIS inventory.' }
    $assembly = Join-Path $env:windir 'System32\inetsrv\Microsoft.Web.Administration.dll'
    Add-Type -Path $assembly
    $manager = New-Object Microsoft.Web.Administration.ServerManager
    $config = $manager.GetApplicationHostConfiguration()
    $centralMode = [string]$config.GetSection('system.applicationHost/log').GetAttributeValue('centralLogFileMode')
    $sid = New-Object Security.Principal.SecurityIdentifier([string]$settings.agentSid)
    $items = New-Object 'System.Collections.Generic.List[object]'
    foreach($site in $manager.Sites) {
        $id = [int]$site.Id
        $log = $site.LogFile
        $base = [Environment]::ExpandEnvironmentVariables([string]$log.Directory)
        if([string]::IsNullOrWhiteSpace($base)) { throw "Site $id has no resolvable log directory; refusing an incomplete inventory." }
        $path = [IO.Path]::GetFullPath((Join-Path $base ('W3SVC'+$id)))
        $format = [string]$log.LogFormat
        $target = [string]$log.GetAttributeValue('logTargetW3C')
        $state = 'ready'; $message=''; $available=$false
        if($centralMode -notin @('Site','0')) { $state='central_unsupported';$message='Centralized IIS logging is not supported. Use per-site W3C file logs.' }
        elseif($format -notin @('W3C','2')) { $state='format_unsupported';$message="Log format is $format; W3C is required." }
        elseif($target -notmatch 'File|Both|1|3') { $state='etw_only';$message='IIS is not writing W3C log files (ETW-only target).' }
        else {
            try {
                Assert-LocalDirectory $path
                if(-not [IO.Directory]::Exists($path)) { $state='waiting_directory';$message='Waiting for IIS to create its log directory. No directory is created by IIS Reports.' }
                else {
                    if([bool]$settings.grantAgentRead) { Grant-LogRead $path $sid }
                    $available=$true
                    if(-not $log.Enabled) { $state='logging_disabled';$message='IIS logging is disabled. Existing W3C files can be imported, but no new events will be written.' }
                }
            } catch {
                $state='path_or_acl_error';$message=$_.Exception.Message;$available=$false
            }
        }
        $items.Add([ordered]@{siteId=$id;name=[string]$site.Name;rootPath=$path;available=$available;status=$state;message=$message})
    }
    $snapshot.sites = @($items.ToArray())
    $snapshot.success=$true
    $snapshot.generatedUtc=[DateTime]::UtcNow.ToString('o')
    Write-Inventory $snapshot
} catch {
    $snapshot.error=$_.Exception.Message
    $snapshot.success=$false
    try { Write-Inventory $snapshot } catch { }
    throw
} finally { if($null -ne $manager) { $manager.Dispose() } }
