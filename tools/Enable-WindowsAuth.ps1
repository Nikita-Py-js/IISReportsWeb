# Works with the v2 application as well as v3. Preserves ConnStr and other settings.
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)][string]$IisPath,
    [Parameter(Mandatory=$true)][string]$WebRoot,
    [Parameter(Mandatory=$true)][string]$Editor,
    [string]$BackupDirectory = "$env:ProgramData\IISReportsBackups"
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Setup.Common.ps1"
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {throw 'Run Windows PowerShell as Administrator.'}
$appcmd=Join-Path $env:windir 'System32\inetsrv\appcmd.exe'
if(-not (Test-Path -LiteralPath $appcmd)) {throw 'IIS appcmd.exe was not found.'}
$root=(Resolve-Path -LiteralPath $WebRoot).Path.TrimEnd('\')
$file=Join-Path $root 'Web.config'
if(-not (Test-Path -LiteralPath $file)) {throw 'Create Web.config first. Do not overwrite a working ConnStr.'}
if([string]::IsNullOrWhiteSpace($Editor) -or $Editor.Contains(';')) {throw 'Specify one exact Windows account or group in -Editor.'}
# Resolve the chosen account, not the elevated shell account, unless explicitly passed.
try {$null=(New-Object Security.Principal.NTAccount($Editor)).Translate([Security.Principal.SecurityIdentifier])}
catch {throw "Cannot resolve editor '$Editor'. Use SERVER\User or DOMAIN\Group as recognized on this server."}
# Validate the actual IIS path and physical root before changing authentication.
Add-Type -Path (Join-Path $env:windir 'System32\inetsrv\Microsoft.Web.Administration.dll')
$manager=New-Object Microsoft.Web.Administration.ServerManager
try {
    $parts=$IisPath.Split(@('/'),2)
    $site=$manager.Sites[$parts[0]]
    if($null -eq $site){throw "IIS site '$($parts[0])' not found. Run appcmd list site; the folder name is not the site name."}
    $appPath=if($parts.Count -gt 1){'/'+$parts[1].Trim('/')}else{'/'}
    $application=$site.Applications[$appPath]
    if($null -eq $application){throw "IIS application not found: $IisPath"}
    $physical=[Environment]::ExpandEnvironmentVariables($application.VirtualDirectories['/'].PhysicalPath)
    if([IO.Path]::GetFullPath($physical).TrimEnd('\') -ine $root){throw 'WebRoot differs from the IIS application physical path. No authentication settings changed.'}
} finally {$manager.Dispose()}
$backup=[IO.Path]::GetFullPath($BackupDirectory)
if(($backup+'\').StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)) {throw 'Backup directory must be outside the website.'}
if(-not $PSCmdlet.ShouldProcess($IisPath,"Enable Windows Authentication, disable Anonymous, authorize $Editor")){return}
New-RestrictedDirectory $backup
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
Copy-Item -LiteralPath $file -Destination (Join-Path $backup "Web-$stamp.config")
Invoke-SetupNative -FilePath $appcmd -Arguments @('add','backup',"IISReports-$stamp")
Invoke-SetupNative -FilePath $appcmd -Arguments @('set','config',$IisPath,'-section:system.webServer/security/authentication/windowsAuthentication','/enabled:true','/commit:apphost')
Invoke-SetupNative -FilePath $appcmd -Arguments @('set','config',$IisPath,'-section:system.webServer/security/authentication/anonymousAuthentication','/enabled:false','/commit:apphost')
[xml]$doc=[IO.File]::ReadAllText($file)
function Ensure-Child([System.Xml.XmlElement]$Parent,[string]$Name) {
    $child=$Parent.SelectSingleNode($Name)
    if($null -eq $child){$child=$doc.CreateElement($Name);$null=$Parent.AppendChild($child)}
    return $child
}
$app=Ensure-Child $doc.DocumentElement 'appSettings'
function Set-App([string]$Key,[string]$Value) {
    $node=$app.SelectSingleNode("add[@key='$Key']")
    if($null -eq $node){$node=$doc.CreateElement('add');$node.SetAttribute('key',$Key);$null=$app.AppendChild($node)}
    $node.SetAttribute('value',$Value)
}
Set-App 'IISReportsAccessMode' 'windows'
$current=$app.SelectSingleNode("add[@key='IISReportsEditors']")
$editors=@()
if($null -ne $current){$editors=@($current.GetAttribute('value') -split ';' | Where-Object {$_ -and $_ -notmatch '^REPLACE_'})}
if($editors -notcontains $Editor){$editors+=$Editor}
Set-App 'IISReportsEditors' ($editors -join ';')
$system=Ensure-Child $doc.DocumentElement 'system.web'
$auth=Ensure-Child $system 'authentication';$auth.SetAttribute('mode','Windows')
$identity=Ensure-Child $system 'identity';$identity.SetAttribute('impersonate','false')
$settings=New-Object System.Xml.XmlWriterSettings
$settings.Indent=$true;$settings.Encoding=New-Object Text.UTF8Encoding($true)
$writer=[Xml.XmlWriter]::Create($file,$settings)
try{$doc.Save($writer)}finally{$writer.Dispose()}
Write-Host "Configured application '$IisPath'. Editor: $Editor"
Write-Host 'v3: open Reports.ashx?action=whoami on the same origin as the dashboard.'
Write-Host "Backup: $backup; IIS backup: IISReports-$stamp"
