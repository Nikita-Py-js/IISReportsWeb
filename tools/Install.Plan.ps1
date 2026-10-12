# Pure settings validation; no IIS/SQL/ACL writes. Imported by Install.ps1 and tests.
function Read-InstallPlan {
 param([Parameter(Mandatory=$true)][string]$SettingsFile,[Parameter(Mandatory=$true)][string]$PackageRoot)
 if(-not(Test-Path -LiteralPath $SettingsFile -PathType Leaf)){throw "Settings file not found: $SettingsFile. Copy one setup/*.psd1 template outside the package and edit it first."}
 if((Get-Command Import-PowerShellDataFile).Parameters.ContainsKey('LiteralPath')){
  $p=Import-PowerShellDataFile -LiteralPath $SettingsFile -ErrorAction Stop
 }else{
  $p=Import-PowerShellDataFile -Path ([WildcardPattern]::Escape($SettingsFile)) -ErrorAction Stop
 }
 $allowed=@('ConfigDirectory','WebRoot','AgentRoot','SiteName','AppPoolName','SqlServer','Database','SqlAuthentication','Editor','Readers','PublicUrl','BindingMode','BindingUrl','CertificateThumbprint','TrustSqlCertificate','AllowCreateDatabase')
 foreach($key in $p.Keys){if($key -notin $allowed){throw "Unknown installation setting '$key'. Fix the spelling in the settings file."}}
 foreach($key in $allowed){if(-not $p.ContainsKey($key)){throw "Missing installation setting '$key'. Copy a complete setup template."}}
 foreach($key in @('ConfigDirectory','WebRoot','AgentRoot','SiteName','AppPoolName','SqlServer','Database','SqlAuthentication','Editor','PublicUrl','BindingMode')){
  if($p[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($p[$key]) -or $p[$key] -ne $p[$key].Trim()){throw "Setting '$key' must be a nonempty string without outer whitespace."}
 }
 foreach($key in @('TrustSqlCertificate','AllowCreateDatabase')){if($p[$key] -isnot [bool]){throw "Setting '$key' must be `$true or `$false, not a quoted string."}}
 foreach($key in @('SiteName','AppPoolName')){if($p[$key] -notmatch '^[A-Za-z0-9_.-]{1,64}$'){throw "Invalid $key. Use letters, digits, dot, underscore or dash."}}
 if($p.Database -notmatch '^[A-Za-z][A-Za-z0-9_]{0,63}$' -or $p.Database -in @('master','model','msdb','tempdb')){throw 'Use a dedicated Database name, not a SQL system database.'}
 if($p.SqlServer -match '(?i)https?://|[;\r\n]' -or $p.SqlServer.Contains('\\') -or $p.SqlServer.EndsWith('\')){throw 'SqlServer is not a SQL instance. Examples: localhost or HOST\INSTANCE, with one backslash.'}
 if($p.SqlAuthentication -notin @('WindowsLocal','SqlLogins')){throw 'SqlAuthentication must be WindowsLocal or SqlLogins.'}
 if($p.BindingMode -notin @('Https','LocalHttp','ReverseProxy')){throw 'BindingMode must be Https, LocalHttp or ReverseProxy.'}
 if($p.Editor.Contains(';') -or $p.Editor -match '(?i)REPLACE|<|>'){throw 'Set Editor to one real SERVER\User or DOMAIN\Group. This is the browser operator, not a SQL account.'}
 $public=Get-CanonicalOrigin $p.PublicUrl
 if(([uri]$p.PublicUrl).AbsolutePath -ne '/'){throw 'Clean installation requires a root application URL ending in /.'}
 $p.PublicUrl=$public+'/'
 foreach($key in @('ConfigDirectory','WebRoot','AgentRoot')){$p[$key]=Get-SetupDirectoryPath $p[$key]}
 $paths=@($p.ConfigDirectory,$p.WebRoot,$p.AgentRoot,[IO.Path]::GetFullPath($PackageRoot).TrimEnd('\'))
 for($i=0;$i -lt $paths.Count;$i++){for($j=$i+1;$j -lt $paths.Count;$j++){
  $a=$paths[$i].TrimEnd('\')+'\';$b=$paths[$j].TrimEnd('\')+'\'
  if($a.StartsWith($b,[StringComparison]::OrdinalIgnoreCase) -or $b.StartsWith($a,[StringComparison]::OrdinalIgnoreCase)){throw 'PackageRoot, ConfigDirectory, WebRoot and AgentRoot must be separate, non-nested directories.'}
 }}
 $settingsPath=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $SettingsFile).Path)
 if($settingsPath.StartsWith($p.WebRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Keep setup settings outside the web root.'}
 if($p.ConfigDirectory -match '(?i)\\inetpub\\wwwroot(?:\\|$)' -or $p.AgentRoot -match '(?i)\\inetpub\\wwwroot(?:\\|$)'){throw 'Keep configuration staging and the agent outside wwwroot.'}
 if($p.BindingMode -eq 'Https'){
  if(([uri]$public).Scheme -ne 'https'){throw 'Https mode requires an https PublicUrl.'}
  $p.CertificateThumbprint=([string]$p.CertificateThumbprint -replace '\s','').ToUpperInvariant()
  if($p.CertificateThumbprint -notmatch '^[A-F0-9]{40}$'){throw 'Https mode requires the real certificate Thumbprint from LocalMachine\My. Use LocalHttp only for a loopback test, or ReverseProxy when TLS actually terminates there.'}
  if($p.BindingUrl -and (Get-CanonicalOrigin $p.BindingUrl) -ne $public){throw 'Https BindingUrl must match PublicUrl.'}
  $p.BindingUrl=$p.PublicUrl
 }elseif($p.BindingMode -eq 'LocalHttp'){
  if(([uri]$public).Scheme -ne 'http' -or ([uri]$public).Host -notin @('localhost','127.0.0.1')){throw 'LocalHttp is restricted to http://localhost:PORT or http://127.0.0.1:PORT.'}
  if($p.BindingUrl -and (Get-CanonicalOrigin $p.BindingUrl) -ne $public){throw 'LocalHttp BindingUrl must match PublicUrl.'}
  $p.BindingUrl=$p.PublicUrl
  if($p.CertificateThumbprint){throw 'LocalHttp does not use CertificateThumbprint; leave it empty.'}
 }else{
  if(([uri]$public).Scheme -ne 'https'){throw 'ReverseProxy requires the external HTTPS PublicUrl.'}
  $binding=Get-CanonicalOrigin $p.BindingUrl
  if(([uri]$binding).Scheme -ne 'http' -or ([uri]$p.BindingUrl).AbsolutePath -ne '/'){throw 'ReverseProxy BindingUrl must be a root HTTP URL; secure the backend with firewall restrictions.'}
  if($p.CertificateThumbprint){throw 'ReverseProxy mode does not bind a TLS certificate in IIS; leave CertificateThumbprint empty.'}
  $p.BindingUrl=$binding+'/'
 }
 return $p
}
