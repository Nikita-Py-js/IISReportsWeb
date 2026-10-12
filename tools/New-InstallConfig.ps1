# Standalone clean-install configuration. No old Web.config is needed.
[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$ConfigDirectory,
 [Parameter(Mandatory=$true)][string]$SqlServer,
 [string]$Database='IISReports',
 [Parameter(Mandatory=$true)][string]$Editor,
 [string]$Readers='',
 [Parameter(Mandatory=$true)][string]$PublicUrl,
 [System.Management.Automation.PSCredential]$WebSqlCredential,
 [System.Management.Automation.PSCredential]$AgentSqlCredential,
 [switch]$TrustServerCertificate,
 [switch]$UseExisting
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Setup.Common.ps1"
Assert-Administrator
$origin=Get-CanonicalOrigin $PublicUrl
if(([uri]$PublicUrl).AbsolutePath -ne '/') { throw 'Clean site installer expects a root application URL; use /, not a subdirectory.' }
if([string]::IsNullOrWhiteSpace($Editor) -or $Editor.Contains(';')) { throw 'Provide one exact initial Windows operator or group.' }
try { $null=(New-Object Security.Principal.NTAccount($Editor)).Translate([Security.Principal.SecurityIdentifier]) }
catch { throw "Cannot resolve Windows account/group: $Editor" }
if(($null -eq $WebSqlCredential) -ne ($null -eq $AgentSqlCredential)) { throw 'Provide both separate SQL credentials, or neither for Windows SQL authentication.' }
if($null -ne $WebSqlCredential -and $WebSqlCredential.UserName -eq $AgentSqlCredential.UserName) { throw 'Use distinct SQL logins for web and agent.' }
$dir=Get-SetupDirectoryPath -Directory $ConfigDirectory
if($dir -match '(?i)\\inetpub\\wwwroot(?:\\|$)') { throw 'Put installation secrets outside all IIS roots (for example C:\Deploy\IISReports-config).' }

$root=Split-Path $PSScriptRoot -Parent
[xml]$web=[IO.File]::ReadAllText("$root\web\Web.config.example")
[xml]$agent=[IO.File]::ReadAllText("$root\agent\IISReports.Agent.exe.config.example")
Set-XmlSetting $web 'ConnStr' (New-SqlConnectionString -SqlServer $SqlServer -Database $Database -Credential $WebSqlCredential -TrustServerCertificate ([bool]$TrustServerCertificate) -Application 'IISReports.Web')
Set-XmlSetting $agent 'ConnStr' (New-SqlConnectionString -SqlServer $SqlServer -Database $Database -Credential $AgentSqlCredential -TrustServerCertificate ([bool]$TrustServerCertificate) -Application 'IISReports.Agent')
Set-XmlSetting $web 'IISReportsEditors' $Editor
Set-XmlSetting $web 'IISReportsReaders' $Readers
Set-XmlSetting $web 'IISReportsAccessMode' 'windows'
Set-XmlSetting $web 'IISReportsPublicOrigin' $origin
# Validate ALL existing files before creating any missing file. Never rewrite a working config.
$plans=@(@{Name='Web.config';Document=$web},@{Name='agent-local.config';Document=$agent})
foreach($plan in $plans) {
    $path=Join-Path $dir $plan.Name
    if(Test-Path -LiteralPath $path) {
        if(-not $UseExisting){throw "Configuration already exists: $($plan.Name). Use -UseExisting to validate and keep it, or choose another folder. No files changed."}
        $actual=Get-SetupXmlSettings $path
        # Validate critical intended settings only; allow separately configured optional settings.
        $keys=if($plan.Name -eq 'Web.config'){@('ConnStr','IISReportsEditors','IISReportsReaders','IISReportsAccessMode','IISReportsPublicOrigin')}else{@('ConnStr')}
        foreach($key in $keys){
            $expected=$plan.Document.SelectSingleNode("/configuration/appSettings/add[@key='$key']").GetAttribute('value')
            if(-not $actual.ContainsKey($key)){throw "Existing $($plan.Name) is missing $key. It was not overwritten."}
            if($key -eq 'ConnStr') {
                $a=Get-SetupSqlBuilder $actual[$key];$b=Get-SetupSqlBuilder $expected
                if(-not $a.EquivalentTo($b)){throw "Existing $($plan.Name) has a different SQL connection. No credentials were printed; review the configuration or settings file."}
            }elseif($actual[$key] -ine $expected){throw "Existing $($plan.Name) disagrees with the intended setting $key. No files changed."}
        }
    }
}
New-RestrictedDirectory -Directory $dir
foreach($plan in $plans){
    $path=Join-Path $dir $plan.Name
    if(-not(Test-Path -LiteralPath $path)){Save-NewXml $plan.Document $path}
    Assert-SetupFile $path $plan.Name
}
& "$PSScriptRoot\Test-InstallConfig.ps1" -ConfigDirectory $dir -ExpectedSqlServer $SqlServer -ExpectedDatabase $Database -ExpectedPublicUrl $PublicUrl -ExpectedEditor $Editor
Write-Host "Created Web.config and agent-local.config in $dir. Secrets were not printed."
Write-Host "Public browser origin: $origin. Use this exact scheme/host/port in browser and Test-Http."
