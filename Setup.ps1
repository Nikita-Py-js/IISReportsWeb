# IIS Reports Simple. Run in elevated Windows PowerShell 5.1.
# A new local IIS site + existing/new local SQL database. No services or tasks.
[CmdletBinding()]
param(
    [string]$SqlServer = 'localhost',
    [string]$Database = 'IISReports',
    [string]$SiteName = 'IISReportsSimple',
    [string]$WebRoot = 'C:\inetpub\wwwroot\IISReportsSimple',
    [ValidateRange(1,65535)][int]$Port = 8090,
    [string]$BindAddress = '127.0.0.1',
    [string[]]$LogRoots = @(),
    [switch]$TrustSqlCertificate
)
$ErrorActionPreference = 'Stop'
$package = $PSScriptRoot
$who = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$who).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run Windows PowerShell as Administrator.'
}
if ($PSVersionTable.PSEdition -eq 'Core' -or -not [Environment]::Is64BitProcess) {
    throw 'Use 64-bit Windows PowerShell 5.1 (powershell.exe), not pwsh.'
}
if ($SiteName -notmatch '^[A-Za-z0-9_.-]{1,64}$') {throw 'Use a simple IIS site name, e.g. IISReportsSimple.'}
if ([string]::IsNullOrWhiteSpace($Database) -or $Database.Length -gt 128 -or $Database -in @('master','msdb','tempdb','model')) {
    throw 'Choose a dedicated application database.'
}
# The automated install grants local Windows accounts. Remote SQL has a manual recipe.
$serverHost = ($SqlServer -replace '^(?i)lpc:', '').Split('\')[0]
if ($serverHost -notin @('.', '(local)', 'localhost', $env:COMPUTERNAME)) {
    throw 'Setup.ps1 supports local SQL. For remote SQL use docs/REMOTE-SQL.md; no server is silently substituted.'
}
$full = [IO.Path]::GetFullPath($WebRoot)
if ($full.TrimEnd('\') -eq [IO.Path]::GetPathRoot($full).TrimEnd('\')) {throw 'WebRoot must not be a drive root.'}
if ($full.StartsWith($package.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) {throw 'WebRoot must be outside the extracted package.'}
$marker=Join-Path $full 'App_Data\simple-install.json'
$owned=Test-Path -LiteralPath $marker
if ((Test-Path -LiteralPath $full) -and @(Get-ChildItem -LiteralPath $full -Force).Count -gt 0 -and -not $owned) {
    throw "Destination $full is not empty and is not owned by this installer. Use a new WebRoot or docs/UPGRADE.md."
}
if ($owned) {
    $saved=[IO.File]::ReadAllText($marker) | ConvertFrom-Json
    if ($saved.SiteName -ne $SiteName -or $saved.SqlServer -ne $SqlServer -or $saved.Database -ne $Database -or [int]$saved.Port -ne $Port -or $saved.BindAddress -ne $BindAddress) {
        throw 'Existing installation uses different parameters. Repeat the original Setup.ps1 command or update settings manually.'
    }
}
$release = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue
if ($null -eq $release -or $release.Release -lt 528040) {throw 'Install .NET Framework 4.8 or later before continuing.'}
if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
    $need = @('Web-Asp-Net45','Web-Static-Content','Web-Default-Doc','Web-Http-Errors','Web-Scripting-Tools')
    $missing = @(Get-WindowsFeature $need | Where-Object {-not $_.Installed} | Select-Object -ExpandProperty Name)
    if ($missing.Count -gt 0) {
        $r = Install-WindowsFeature $missing
        if (-not $r.Success) {throw 'IIS feature installation failed.'}
        if ([string]$r.RestartNeeded -ne 'No') {throw 'Windows requested a restart. Restart in a maintenance window, then run Setup.ps1 again.'}
    }
}
Add-Type -Path "$env:windir\System32\inetsrv\Microsoft.Web.Administration.dll"
$manager = New-Object Microsoft.Web.Administration.ServerManager
try {
    if (($null -ne $manager.Sites[$SiteName] -or $null -ne $manager.ApplicationPools[$SiteName]) -and -not $owned) {throw "IIS site/pool $SiteName already exists and is not owned by this installation."}
    if($null -ne $manager.Sites[$SiteName]) {
        $actual=$manager.Sites[$SiteName].Applications['/'].VirtualDirectories['/'].PhysicalPath
        if([IO.Path]::GetFullPath($actual).TrimEnd('\') -ne $full.TrimEnd('\')) {throw 'Existing IIS site has a different physical path.'}
    }
    foreach ($site in $manager.Sites) {
        foreach ($binding in $site.Bindings) {
            if ($site.Name -ne $SiteName -and $binding.Protocol -in @('http','https') -and $binding.EndPoint.Port -eq $Port) {throw "Port $Port is used by '$($site.Name)'. Choose another -Port."}
        }
    }
    $names = @{}
    $roots = New-Object 'System.Collections.Generic.List[string]'
    foreach ($site in $manager.Sites) {
        $names[[string]$site.Id] = [string]$site.Name
        if ($site.LogFile.LogFormat.ToString() -eq 'W3C') {
            $path = [Environment]::ExpandEnvironmentVariables([string]$site.LogFile.Directory)
            if ($path -and -not $path.StartsWith('\\')) {$roots.Add($path)}
        }
    }
    foreach ($r in $LogRoots) {if ($r) {$roots.Add([Environment]::ExpandEnvironmentVariables($r))}}
    if($roots.Count -eq 0){$roots.Add((Join-Path $env:SystemDrive 'inetpub\logs\LogFiles'))}
    $LogRoots = @($roots | Select-Object -Unique)
} finally {$manager.Dispose()}
function Open-Db([string]$name) {
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b['Data Source']=$SqlServer; $b['Initial Catalog']=$name
    $b['Integrated Security']=$true; $b['Encrypt']=$true
    $b['TrustServerCertificate']=[bool]$TrustSqlCertificate; $b['Connect Timeout']=15
    $b['Application Name']='IISReports.Simple.Setup'
    $c = New-Object System.Data.SqlClient.SqlConnection($b.ConnectionString)
    try {$c.Open();return $c} catch {$c.Dispose();throw}
}
function Sql([System.Data.SqlClient.SqlConnection]$c,[string]$text) {
    $q=$c.CreateCommand();$q.CommandTimeout=180;$q.CommandText=$text
    try {[void]$q.ExecuteNonQuery()}finally{$q.Dispose()}
}
Write-Host '[1/4] SQL database and schema (existing data retained)'
$c=Open-Db 'master'
$dbLiteral=$Database.Replace("'","''");$dbIdentifier=$Database.Replace(']',']]')
try {Sql $c "IF DB_ID(N'$dbLiteral') IS NULL EXEC(N'CREATE DATABASE [$($dbIdentifier.Replace("'","''"))]');"}finally{$c.Dispose()}
$c=Open-Db $Database
try {
    foreach ($script in @('001-v3-schema.sql','005-auto-sources.sql')) {
        Sql $c ([IO.File]::ReadAllText((Join-Path $package "sql\$script")))
    }
} finally {$c.Dispose()}
Write-Host '[2/4] Web files and one Web.config'
[void][IO.Directory]::CreateDirectory($full)
# Publish only once. Re-running after a failed SQL/ACL step preserves configured files.
if(-not $owned) {
    Get-ChildItem -LiteralPath "$package\web" -Force | Copy-Item -Destination $full -Recurse
    [xml]$config=[IO.File]::ReadAllText("$full\Web.config")
    $b=New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b['Data Source']=$SqlServer;$b['Initial Catalog']=$Database;$b['Integrated Security']=$true
    $b['Encrypt']=$true;$b['TrustServerCertificate']=[bool]$TrustSqlCertificate;$b['Application Name']='IISReports.Simple'
    $config.SelectSingleNode('/configuration/appSettings/add[@key="ConnStr"]').SetAttribute('value',$b.ConnectionString)
    $config.SelectSingleNode('/configuration/appSettings/add[@key="LogRoots"]').SetAttribute('value',($LogRoots -join ';'))
    $config.Save("$full\Web.config")
    [IO.File]::WriteAllText("$full\sites.json",($names | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    $stamp=@{SiteName=$SiteName;SqlServer=$SqlServer;Database=$Database;Port=$Port;BindAddress=$BindAddress}|ConvertTo-Json
    [IO.File]::WriteAllText($marker,$stamp,(New-Object Text.UTF8Encoding($false)))
}
Write-Host '[3/4] IIS site, application pool, file and SQL permissions'
$manager=New-Object Microsoft.Web.Administration.ServerManager
try {
    $pool=$manager.ApplicationPools[$SiteName]
    if($null -eq $pool){$pool=$manager.ApplicationPools.Add($SiteName)}
    $pool.ManagedRuntimeVersion='v4.0';$pool.ManagedPipelineMode='Integrated'
    $pool.ProcessModel.IdentityType='ApplicationPoolIdentity'
    $pool.ProcessModel.MaxProcesses=1
    $site=$manager.Sites[$SiteName]
    $createdSite=($null -eq $site)
    if($null -eq $site){$site=$manager.Sites.Add($SiteName,'http',($BindAddress+':'+$Port+':'),$full)}
    $site.ServerAutoStart=$false
    $site.Applications['/'].ApplicationPoolName=$SiteName
    # Existing sites may already have operator-configured authentication. Preserve it.
    if($createdSite) {
        $hostConfig=$manager.GetApplicationHostConfiguration()
        $anonymous=$hostConfig.GetSection('system.webServer/security/authentication/anonymousAuthentication',$SiteName)
        $anonymous['enabled']=$true;$anonymous['userName']=''
        try {$hostConfig.GetSection('system.webServer/security/authentication/windowsAuthentication',$SiteName)['enabled']=$false}catch{}
    }
    $manager.CommitChanges()
}finally{$manager.Dispose()}
$account='IIS APPPOOL\'+$SiteName
# Grant read access only. Use SIDs for language-independent admin/system names.
$acl=New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true,$false)
foreach($entry in @(@('S-1-5-32-544','FullControl'),@('S-1-5-18','FullControl'),@($account,'ReadAndExecute'))) {
    $identity = if($entry[0] -like 'S-1-*'){New-Object Security.Principal.SecurityIdentifier($entry[0])}else{New-Object Security.Principal.NTAccount($entry[0])}
    $rule=New-Object Security.AccessControl.FileSystemAccessRule($identity,$entry[1],'ContainerInherit,ObjectInherit','None','Allow')
    [void]$acl.AddAccessRule($rule)
}
[IO.Directory]::SetAccessControl($full,$acl)
foreach($r in $LogRoots) {
    if(Test-Path -LiteralPath $r -PathType Container) {
        $a=Get-Acl -LiteralPath $r
        $rule=New-Object Security.AccessControl.FileSystemAccessRule($account,'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow')
        $a.AddAccessRule($rule);Set-Acl -LiteralPath $r -AclObject $a
    }else{Write-Warning "Log directory does not exist yet: $r. Configure Logging and grant the pool read access when it is created."}
}
$loginIdentifier=$account.Replace(']',']]');$loginLiteral=$account.Replace("'","''")
$c=Open-Db 'master'
try{Sql $c "IF SUSER_ID(N'$loginLiteral') IS NULL CREATE LOGIN [$loginIdentifier] FROM WINDOWS;"}finally{$c.Dispose()}
$c=Open-Db $Database
try {
    Sql $c "IF USER_ID(N'$loginLiteral') IS NULL CREATE USER [$loginIdentifier] FOR LOGIN [$loginIdentifier]; GRANT CONNECT TO [$loginIdentifier]; GRANT SELECT,INSERT,UPDATE,DELETE ON SCHEMA::ir3 TO [$loginIdentifier];"
}finally{$c.Dispose()}
$manager=New-Object Microsoft.Web.Administration.ServerManager
try{$manager.Sites[$SiteName].ServerAutoStart=$true;$manager.CommitChanges();[void]$manager.Sites[$SiteName].Start()}finally{$manager.Dispose()}
Write-Host '[4/4] Finished. Open the page; no agent, EXE build or scheduled task is required.'
Write-Host "URL: http://localhost:$Port/"
Write-Host "Config: $full\Web.config"
Write-Host "Log roots: $($LogRoots -join '; ')"
Write-Warning 'Application authentication is delegated to IIS/network controls. Anonymous users who can reach this site can read and modify reports. Keep it local/private until access is restricted.'
Write-Host 'If an older IISReportsAgentV3 exists, run Stop-Legacy.ps1 once before using Simple. SQL history is not cleared.'
