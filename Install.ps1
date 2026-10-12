#requires -Version 5.1
# One settings file, explicit stages. No passwords saved in the settings file.
[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$SettingsFile,
 [ValidateSet('Check','Prerequisites','Build','Database','Config','Web','Agent','Permissions','SecurityTest','Start','Verify')]
 [string]$Step='Check',
 [System.Management.Automation.PSCredential]$AdminCredential,
 [System.Management.Automation.PSCredential]$WebSqlCredential,
 [System.Management.Automation.PSCredential]$AgentSqlCredential
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\tools\Setup.Common.ps1"
. "$PSScriptRoot\tools\Install.Plan.ps1"
Assert-SetupWindows
Assert-SetupFile $SettingsFile 'Installation settings file'
$SettingsFile=(Resolve-Path -LiteralPath $SettingsFile).Path
$pkg=$PSScriptRoot
Set-Location -LiteralPath $pkg
[Environment]::CurrentDirectory=$pkg
$plan=Read-InstallPlan -SettingsFile $SettingsFile -PackageRoot $pkg
$build=Join-Path $pkg 'build'
$webConfig=Join-Path $plan.ConfigDirectory 'Web.config'
$agentConfig=Join-Path $plan.ConfigDirectory 'agent-local.config'
$dbArgs=@{SqlServer=$plan.SqlServer;Database=$plan.Database;TrustServerCertificate=$plan.TrustSqlCertificate}
if($null -ne $AdminCredential){$dbArgs.AdminCredential=$AdminCredential}
function Confirm-ConfigPair {
 & "$pkg\tools\Test-InstallConfig.ps1" -ConfigDirectory $plan.ConfigDirectory -ExpectedSqlServer $plan.SqlServer -ExpectedDatabase $plan.Database -ExpectedPublicUrl $plan.PublicUrl -ExpectedEditor $plan.Editor
}
function Get-ApplicationSqlCredentials {
 if($plan.SqlAuthentication -eq 'SqlLogins'){
  if($null -eq $script:WebSqlCredential){$script:WebSqlCredential=Get-Credential -Message 'Separate SQL login for the WEB application (not sa).'}
  if($null -eq $script:AgentSqlCredential){$script:AgentSqlCredential=Get-Credential -Message 'Separate SQL login for the AGENT (not sa, not the web login).'}
  if($null -eq $script:WebSqlCredential -or $null -eq $script:AgentSqlCredential){throw 'SQL credentials were not supplied. No configuration written.'}
 }
}
function Test-ExactInstalledWeb {
 Add-Type -Path (Join-Path $env:windir 'System32\inetsrv\Microsoft.Web.Administration.dll')
 $manager=New-Object Microsoft.Web.Administration.ServerManager
 try {
  $site=$manager.Sites[$plan.SiteName]
  if($null -eq $site){return $false}
  $app=$site.Applications['/'];$physical=[Environment]::ExpandEnvironmentVariables($app.VirtualDirectories['/'].PhysicalPath)
  if([IO.Path]::GetFullPath($physical).TrimEnd('\') -ine $plan.WebRoot -or $app.ApplicationPoolName -ine $plan.AppPoolName){throw 'Existing IIS site points to another folder or pool. Nothing overwritten. Choose the correct settings or use UPGRADING.md.'}
  $cfg=$manager.GetApplicationHostConfiguration()
  if(-not [bool]$cfg.GetSection('system.webServer/security/authentication/windowsAuthentication',$plan.SiteName)['enabled'] -or [bool]$cfg.GetSection('system.webServer/security/authentication/anonymousAuthentication',$plan.SiteName)['enabled']){throw 'Existing site authentication differs. Run Enable-WindowsAuth.ps1 for the correct IIS path; do not recreate the site.'}
  $target=[uri]$plan.BindingUrl;$hostValue=$target.DnsSafeHost;$address='*';$hostHeader=$hostValue
  $ip=$null
  if($hostValue -eq 'localhost'){$address='127.0.0.1';$hostHeader=''}elseif([Net.IPAddress]::TryParse($hostValue,[ref]$ip)){$address=$hostValue;$hostHeader=''}
  $expected=$address+':'+$target.Port+':'+$hostHeader
  $bindings=@($site.Bindings|Where-Object{$_.Protocol -eq $target.Scheme -and $_.BindingInformation -ieq $expected})
  if($bindings.Count -ne 1){throw 'Existing IIS binding differs from the saved BindingUrl. Review bindings manually; no binding was changed.'}
  if($target.Scheme -eq 'https'){
   $hash=([BitConverter]::ToString($bindings[0].CertificateHash)).Replace('-','')
   if($hash -ine $plan.CertificateThumbprint){throw 'Existing HTTPS certificate differs from the saved thumbprint.'}
  }
  foreach($source in Get-ChildItem -LiteralPath "$pkg\web" -Recurse -File){
   if($source.Name -like '*.example' -or $source.Name -eq 'Web.config'){continue}
   $relative=$source.FullName.Substring((Join-Path $pkg 'web').Length+1)
   $dest=Join-Path $plan.WebRoot $relative
   if(-not(Test-Path -LiteralPath $dest -PathType Leaf) -or (Get-FileHash -LiteralPath $dest).Hash -ne (Get-FileHash -LiteralPath $source.FullName).Hash){throw "Installed web file differs/missing: $relative. Follow UPGRADING.md; the clean installer will not overwrite it."}
  }
  Assert-SetupFile (Join-Path $plan.WebRoot 'Web.config') 'Installed Web.config'
  $settings=Get-SetupXmlSettings (Join-Path $plan.WebRoot 'Web.config')
  if((Get-CanonicalOrigin $settings['IISReportsPublicOrigin']) -ne (Get-CanonicalOrigin $plan.PublicUrl)){throw 'Installed PublicOrigin differs from settings. Follow SECURITY.md; do not disable CSRF.'}
  $prepared=Get-SetupXmlSettings $webConfig
  $installedSql=Get-SetupSqlBuilder $settings['ConnStr'];$preparedSql=Get-SetupSqlBuilder $prepared['ConnStr']
  if(-not $installedSql.EquivalentTo($preparedSql)){throw 'Installed web SQL settings differ from prepared configuration. No credentials printed or overwritten; follow UPGRADING.md.'}
  foreach($key in @('IISReportsAccessMode','IISReportsEditors','IISReportsReaders')){
   if($settings[$key] -ine $prepared[$key]){throw "Installed web setting differs: $key. Review the running configuration; it was not replaced."}
  }
  return $true
 }finally{$manager.Dispose()}
}
function Assert-InstalledAgent {
 $service=Get-CimInstance Win32_Service -Filter "Name='IISReportsAgentV3'" -ErrorAction Stop
 if($null -eq $service){throw 'Agent service is not installed. Run the Agent step.'}
 $path=Join-Path $plan.AgentRoot 'IISReports.Agent.exe'
 if($service.PathName.Trim('"') -ine $path){throw 'Installed service points to a different AgentRoot. No service was modified.'}
 Assert-SetupFile $path 'Installed agent EXE'
 $buildExe=Join-Path $build 'IISReports.Agent.exe'
 Assert-SetupFile $buildExe 'Current built agent EXE'
 if((Get-FileHash -LiteralPath $path).Hash -ne (Get-FileHash -LiteralPath $buildExe).Hash){throw 'Installed agent differs from the current build. Follow UPGRADING.md.'}
 Assert-SetupFile (Join-Path $plan.AgentRoot 'IISReports.Agent.exe.config') 'Installed agent config'
 if($service.StartName -ine 'NT SERVICE\IISReportsAgentV3'){throw 'Existing service uses a different account. This clean-install plan expects the dedicated virtual service account; review an upgrade separately.'}
 $active=Get-SetupXmlSettings (Join-Path $plan.AgentRoot 'IISReports.Agent.exe.config')
 $prepared=Get-SetupXmlSettings $agentConfig
 $activeSql=Get-SetupSqlBuilder $active['ConnStr'];$preparedSql=Get-SetupSqlBuilder $prepared['ConnStr']
 if(-not $activeSql.EquivalentTo($preparedSql)){throw 'Installed agent SQL settings differ from prepared configuration. No files changed.'}
 $task=Get-ScheduledTask -TaskName 'IISReports-DiscoverSites' -ErrorAction SilentlyContinue
 if($null -eq $task){throw 'Discovery task is missing. Stop the service and run Install-AutoDiscovery.ps1 -AgentDirectory <AgentRoot>.'}
}
Write-Host "IIS Reports 3.1.1 | stage: $Step | settings: $SettingsFile"
switch($Step){
 'Check' {
  [pscustomobject]@{Package=$pkg;ConfigDirectory=$plan.ConfigDirectory;WebRoot=$plan.WebRoot;AgentRoot=$plan.AgentRoot;IisSite=$plan.SiteName;IisPool=$plan.AppPoolName;SqlServer=$plan.SqlServer;Database=$plan.Database;SqlAuthentication=$plan.SqlAuthentication;PublicUrl=$plan.PublicUrl;BindingMode=$plan.BindingMode;Editor=$plan.Editor;WebConfigExists=(Test-Path -LiteralPath $webConfig);AgentConfigExists=(Test-Path -LiteralPath $agentConfig)} | Format-List | Out-Host
  Write-Host 'No changes made. Missing config files are normal BEFORE the Config step; it creates the protected folder and BOTH files.'
 }
 'Prerequisites' {& "$pkg\tools\Install-Prerequisites.ps1" -InstallMissing}
 'Build' {& "$pkg\tools\Verify-Package.ps1";& "$pkg\tools\Build-And-Test.ps1"}
 'Database' {
  $probe=@{SqlServer=$plan.SqlServer;Database='master';TrustServerCertificate=$plan.TrustSqlCertificate}
  if($null -ne $AdminCredential){$probe.AdminCredential=$AdminCredential}
  & "$pkg\tools\Test-SqlConnection.ps1" @probe
  & "$pkg\tools\Initialize-Database.ps1" @dbArgs -CreateDatabase:$plan.AllowCreateDatabase
 }
 'Config' {
  Get-ApplicationSqlCredentials
  $argsConfig=@{ConfigDirectory=$plan.ConfigDirectory;SqlServer=$plan.SqlServer;Database=$plan.Database;Editor=$plan.Editor;Readers=$plan.Readers;PublicUrl=$plan.PublicUrl;TrustServerCertificate=$plan.TrustSqlCertificate;UseExisting=$true}
  if($plan.SqlAuthentication -eq 'SqlLogins'){$argsConfig.WebSqlCredential=$WebSqlCredential;$argsConfig.AgentSqlCredential=$AgentSqlCredential}
  & "$pkg\tools\New-InstallConfig.ps1" @argsConfig
  Confirm-ConfigPair
 }
 'Web' {
  Confirm-ConfigPair
  Assert-SetupBuild -PackageRoot $pkg -BuildDirectory $build
  if(Test-ExactInstalledWeb){Write-Host 'Web application already matches this package; no changes made.';break}
  $argsWeb=@{SiteName=$plan.SiteName;AppPoolName=$plan.AppPoolName;WebRoot=$plan.WebRoot;ConfigFile=$webConfig;BindingUrl=$plan.BindingUrl;CertificateThumbprint=$plan.CertificateThumbprint}
  if($plan.BindingMode -ne 'Https'){$argsWeb.AllowHttp=$true}
  if($plan.BindingMode -eq 'ReverseProxy'){$argsWeb.ReverseProxy=$true}
  & "$pkg\tools\Install-Web.ps1" @argsWeb
 }
 'Agent' {
  Confirm-ConfigPair
  Assert-SetupBuild -PackageRoot $pkg -BuildDirectory $build
  if(Get-Service IISReportsAgentV3 -ErrorAction SilentlyContinue){Assert-InstalledAgent;Write-Host 'Agent already matches this build; no changes made.';break}
  & "$pkg\tools\Install-Agent.ps1" -BuildDirectory $build -ConfigFile $agentConfig -Destination $plan.AgentRoot
 }
 'Permissions' {
  Confirm-ConfigPair
  if(-not(Test-ExactInstalledWeb)){throw 'Install the Web stage first.'}
  Assert-InstalledAgent
  if($plan.SqlAuthentication -eq 'WindowsLocal'){& "$pkg\tools\Grant-DatabaseAccess.ps1" @dbArgs -LocalWindows -AppPoolName $plan.AppPoolName -ServiceName 'IISReportsAgentV3'}
  else{Get-ApplicationSqlCredentials;& "$pkg\tools\Grant-DatabaseAccess.ps1" @dbArgs -WebCredential $WebSqlCredential -AgentCredential $AgentSqlCredential}
 }
 'SecurityTest' {& "$pkg\tools\Test-Http.ps1" -ApplicationUrl $plan.PublicUrl}
 'Start' {
  Confirm-ConfigPair
  if(-not(Test-ExactInstalledWeb)){throw 'Install the Web stage first.'}
  Assert-InstalledAgent
  & "$pkg\tools\Initialize-Database.ps1" @dbArgs -VerifyOnly
  # Always recheck security immediately before enabling background work.
  & "$pkg\tools\Test-Http.ps1" -ApplicationUrl $plan.PublicUrl
  Invoke-SetupNative -FilePath (Join-Path $env:windir 'System32\sc.exe') -Arguments @('config','IISReportsAgentV3','start=','delayed-auto')
  Start-Service IISReportsAgentV3 -ErrorAction Stop
  Get-Service IISReportsAgentV3 | Format-Table | Out-Host
  Write-Host 'Service is running. This does not yet prove import succeeded: run Verify and inspect action=health / Sources.'
 }
 'Verify' {
  Confirm-ConfigPair
  if(-not(Test-ExactInstalledWeb)){throw 'Expected web application is not installed.'}
  Assert-InstalledAgent
  & "$pkg\tools\Initialize-Database.ps1" @dbArgs -VerifyOnly
  & "$pkg\tools\Check-Deployment.ps1" -WebRoot $plan.WebRoot -BuildDirectory $build -ServiceRoot $plan.AgentRoot -Strict
  & "$pkg\tools\Test-Health.ps1" -ApplicationUrl $plan.PublicUrl
  Write-Host ('Open '+$plan.PublicUrl+'Reports.ashx?action=health and the Sources tab. Check agentOnline, discovery state and import errors.')
 }
}
Write-Host "DONE: $Step. If the command threw an error, do not advance to the next stage."
