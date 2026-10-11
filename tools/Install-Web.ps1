# Create a NEW dedicated IIS site and pool. Only web/ is published.
[CmdletBinding(SupportsShouldProcess=$true)]
param(
 [string]$SiteName='IISReportsV3',
 [string]$AppPoolName='IISReportsV3',
 [string]$WebRoot='C:\inetpub\wwwroot\IISReportsV3',
 [Parameter(Mandatory=$true)][string]$ConfigFile,
 [string]$BindingUrl='',
 [string]$CertificateThumbprint='',
 [switch]$AllowHttp,
 [switch]$ReverseProxy
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Setup.Common.ps1"
Assert-Administrator
foreach($n in @($SiteName,$AppPoolName)) { if($n -notmatch '^[A-Za-z0-9_.-]{1,64}$') { throw 'Use a simple dedicated IIS site/pool name (letters, digits, dot, dash, underscore).' } }
$package=Split-Path $PSScriptRoot -Parent
$config=(Resolve-Path -LiteralPath $ConfigFile).Path
[xml]$doc=[IO.File]::ReadAllText($config)
$setting=$doc.SelectSingleNode('/configuration/appSettings/add[@key="IISReportsPublicOrigin"]')
if($null -eq $setting -or -not $setting.value) { throw 'Generate a configuration with a fixed PublicUrl before deployment.' }
$public=Get-CanonicalOrigin $setting.value
if(-not $BindingUrl) { $BindingUrl=$public+'/' }
$bindingOrigin=Get-CanonicalOrigin $BindingUrl
$uri=[uri]$BindingUrl
if($uri.AbsolutePath -ne '/') { throw 'Install-Web creates a root application, not an IIS child application.' }
if($bindingOrigin -ne $public -and -not $ReverseProxy) { throw 'BindingUrl differs from public origin. Use -ReverseProxy intentionally, or correct the URL.' }
if($uri.Scheme -eq 'http' -and -not $AllowHttp) { throw 'Use HTTPS; -AllowHttp explicitly permits a local test or restricted reverse-proxy backend.' }
if($uri.Scheme -eq 'https') {
    $CertificateThumbprint=($CertificateThumbprint -replace '\s','').ToUpperInvariant()
    if($CertificateThumbprint -notmatch '^[A-F0-9]{40}$') { throw 'Provide a valid certificate thumbprint from LocalMachine\My.' }
    $cert=Get-Item -LiteralPath "Cert:\LocalMachine\My\$CertificateThumbprint"
    if(-not $cert.HasPrivateKey -or $cert.NotAfter -le (Get-Date)) { throw 'Certificate must have a private key and must not be expired.' }
}
$target=[IO.Path]::GetFullPath($WebRoot).TrimEnd('\')
if(($target+'\').StartsWith($package.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'WebRoot must be separate from the unpacked source package.' }
if(Test-Path -LiteralPath $target) {
    if(@(Get-ChildItem -LiteralPath $target -Force).Count -gt 0) { throw 'WebRoot is not empty. Use a clean directory or follow docs/UPGRADING.md.' }
}
Add-Type -Path (Join-Path $env:windir 'System32\inetsrv\Microsoft.Web.Administration.dll')
$manager=New-Object Microsoft.Web.Administration.ServerManager
try {
    if($null -ne $manager.Sites[$SiteName]) { throw "IIS SITE already exists: $SiteName. No settings changed." }
    if($null -ne $manager.ApplicationPools[$AppPoolName]) { throw "IIS pool already exists: $AppPoolName. Choose a new dedicated pool." }
    # Never reuse another site's port; this conservative installer does not alter shared HTTPS bindings.
    foreach($site in $manager.Sites) { foreach($b in $site.Bindings) { if($b.Protocol -in @('http','https') -and $b.EndPoint.Port -eq $uri.Port) { throw "Port $($uri.Port) is already used by IIS site '$($site.Name)'. Choose a free port or configure an intentional shared binding manually." } } }
    if(-not $PSCmdlet.ShouldProcess($target,"Create site $SiteName and pool $AppPoolName")) { return }
    $backupDir=Join-Path $env:ProgramData 'IISReportsBackups'
    New-RestrictedDirectory $backupDir
    $appcmd=Join-Path $env:windir 'System32\inetsrv\appcmd.exe'
    & $appcmd add backup ('IISReports-install-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')) | Out-Null
    if($LASTEXITCODE -ne 0) { throw 'IIS backup failed.' }
    New-RestrictedDirectory $target
    # Templates and samples are not copied to the publicly served directory.
    Get-ChildItem -LiteralPath "$package\web" -File | Where-Object { $_.Name -notlike '*.example' -and $_.Name -ne 'Web.config' } |
        Copy-Item -Destination $target
    Copy-Item -LiteralPath "$package\web\App_Code" -Destination $target -Recurse
    [void][IO.Directory]::CreateDirectory((Join-Path $target 'App_Data'))
    Copy-Item -LiteralPath $config -Destination (Join-Path $target 'Web.config')
    $pool=$manager.ApplicationPools.Add($AppPoolName)
    $pool.ManagedRuntimeVersion='v4.0'; $pool.ManagedPipelineMode='Integrated'
    $pool.ProcessModel.IdentityType='ApplicationPoolIdentity'
    $bindingHost=$uri.DnsSafeHost
    $address='*'; $hostHeader=$bindingHost
    if($bindingHost -eq 'localhost') { $address='127.0.0.1'; $hostHeader='' }
    $parsedIp=$null
    if([Net.IPAddress]::TryParse($bindingHost,[ref]$parsedIp)) { $address=$bindingHost; $hostHeader='' }
    if($parsedIp -and $parsedIp.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) { throw 'This installer expects a DNS name or IPv4 binding. Configure IPv6 bindings in IIS Manager.' }
    $info=$address+':'+$uri.Port+':'+$hostHeader
    $site=$manager.Sites.Add($SiteName,$uri.Scheme,$info,$target)
    $site.ServerAutoStart=$false
    $site.Applications['/'].ApplicationPoolName=$AppPoolName
    if($uri.Scheme -eq 'https') {
        $b=$site.Bindings[0];$b.CertificateHash=$cert.GetCertHash();$b.CertificateStoreName='My'
        $b.SslFlags=if($hostHeader){1}else{0}
    }
    $cfg=$manager.GetApplicationHostConfiguration()
    $cfg.GetSection('system.webServer/security/authentication/windowsAuthentication',$SiteName)['enabled']=$true
    $cfg.GetSection('system.webServer/security/authentication/anonymousAuthentication',$SiteName)['enabled']=$false
    $manager.CommitChanges()
} finally { $manager.Dispose() }
$account='IIS AppPool\'+$AppPoolName
& icacls.exe $target /grant "${account}:(OI)(CI)(RX)" | Out-Null
if($LASTEXITCODE -ne 0) { throw 'Site remains stopped. Failed to grant the pool read/execute permissions.' }
# Static files can be opened under the authenticated browser identity: grant read-only ACL,
# while ASP.NET role checks still govern access to report data. No write permissions are granted.
& icacls.exe $target /grant '*S-1-5-11:(OI)(CI)(RX)' | Out-Null
if($LASTEXITCODE -ne 0) { throw 'Failed to grant read-only static-file access for authenticated users.' }
# Connection strings are readable only by the pool, Administrators and SYSTEM on the filesystem.
& icacls.exe (Join-Path $target 'Web.config') /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' "${account}:R" | Out-Null
if($LASTEXITCODE -ne 0) { throw 'Failed to restrict Web.config permissions.' }
$manager=New-Object Microsoft.Web.Administration.ServerManager
try { $manager.Sites[$SiteName].ServerAutoStart=$true;$manager.CommitChanges();$null=$manager.Sites[$SiteName].Start() }
finally { $manager.Dispose() }
Write-Host "Installed: site=$SiteName; pool=$AppPoolName; physicalPath=$target"
Write-Host "Binding: $bindingOrigin; browser origin: $public"
Write-Host 'No firewall/DNS changes were made. Complete SQL permissions and test whoami/CSRF at the public origin.'
