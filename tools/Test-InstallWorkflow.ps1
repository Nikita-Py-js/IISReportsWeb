#requires -Version 5.1
# Windows PowerShell tests for the installation plan/config guards. No SQL/IIS/service writes.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Setup.Common.ps1"
. "$PSScriptRoot\Install.Plan.ps1"
Assert-SetupWindows
$root=Split-Path $PSScriptRoot -Parent
$temp=Join-Path $env:TEMP ('iisreports-contract-'+[Guid]::NewGuid().ToString('N'))
New-RestrictedDirectory $temp
$count=0
function Check([bool]$Ok,[string]$Name){if(-not $Ok){throw "FAIL $Name"};$script:count++;Write-Host "PASS $Name"}
function Reject([scriptblock]$Action,[string]$Name){$denied=$false;try{& $Action|Out-Null}catch{$denied=$true};Check $denied $Name}
function Write-Plan([hashtable]$Changes=@{}){
 $text=[IO.File]::ReadAllText((Join-Path $root 'setup\LocalHttp.psd1'))
 $text=$text.Replace('REPLACE_SERVER\REPLACE_OPERATOR',[Security.Principal.WindowsIdentity]::GetCurrent().Name)
 foreach($key in $Changes.Keys){
  $pattern='(?m)^    '+[regex]::Escape($key)+' = .+$'
  $replacement='    '+$key+' = '+$Changes[$key]
  $text=[regex]::Replace($text,$pattern,[Text.RegularExpressions.MatchEvaluator]{param($m)$replacement})
 }
 $file=Join-Path $temp 'case.psd1';[IO.File]::WriteAllText($file,$text,(New-Object Text.UTF8Encoding($true)))
 return $file
}
try{
 $file=Write-Plan
 $p=Read-InstallPlan $file $root
 Check ($p.BindingMode -eq 'LocalHttp') 'loopback mode is explicit'
 Check ($p.SqlServer -eq 'localhost') 'server setting persisted without shell variables'
 Check ($p.TrustSqlCertificate -eq $false) 'TLS verification enabled by default'
 Reject {Read-InstallPlan (Write-Plan @{Editor="'REPLACE_SERVER\REPLACE_OPERATOR'"}) $root} 'placeholder operator rejected'
 Reject {Read-InstallPlan (Write-Plan @{SqlServer="'localhost\\SQLEXPRESS'"}) $root} 'JSON double escaping in SQL instance rejected'
 Reject {Read-InstallPlan (Write-Plan @{SqlServer="'https://sql.invalid/'"}) $root} 'SQL URL rejected'
 Reject {Read-InstallPlan (Write-Plan @{TrustSqlCertificate="'false'"}) $root} 'string boolean rejected'
 Reject {Read-InstallPlan (Write-Plan @{PublicUrl="'http://public.invalid:801/'"}) $root} 'LocalHttp cannot listen under public DNS'
 Reject {Read-InstallPlan (Write-Plan @{BindingMode="'Https'";PublicUrl="'https://reports.invalid/'"}) $root} 'HTTPS without certificate rejected'
 Reject {Read-InstallPlan (Write-Plan @{PublicUrl="'http://localhost:801/app/'"}) $root} 'child application path rejected by clean installer'
 Reject {Read-InstallPlan (Write-Plan @{ConfigDirectory="'C:\inetpub\wwwroot\IISReportsV3\configs'"}) $root} 'secrets under web root rejected'
 Reject {Read-InstallPlan (Write-Plan @{Database="'master'"}) $root} 'system database rejected'
 Reject {Read-InstallPlan (Write-Plan @{WebRoot="'C:\'"}) $root} 'drive root rejected'
 $config=Join-Path $temp 'nested\configs'
 $argsConfig=@{ConfigDirectory=$config;SqlServer='localhost';Database='IISReports';Editor=[Security.Principal.WindowsIdentity]::GetCurrent().Name;PublicUrl='http://localhost:801/'}
 & "$PSScriptRoot\New-InstallConfig.ps1" @argsConfig
 Check ((Test-Path "$config\Web.config") -and (Test-Path "$config\agent-local.config")) 'Config step creates missing directory and both files'
 $webHash=(Get-FileHash "$config\Web.config").Hash
 & "$PSScriptRoot\New-InstallConfig.ps1" @argsConfig -UseExisting
 Check ((Get-FileHash "$config\Web.config").Hash -eq $webHash) 'matching existing config reused without rewriting'
 $argsConfig.Database='DifferentDb'
 Reject {& "$PSScriptRoot\New-InstallConfig.ps1" @argsConfig -UseExisting} 'different existing SQL destination rejected'
 Check ((Get-FileHash "$config\Web.config").Hash -eq $webHash) 'mismatch leaves config unchanged'
 $argsConfig.Database='IISReports'
 Remove-Item -LiteralPath "$config\agent-local.config" # Only the temporary fixture created above
 & "$PSScriptRoot\New-InstallConfig.ps1" @argsConfig -UseExisting
 Check ((Test-Path "$config\agent-local.config") -and (Get-FileHash "$config\Web.config").Hash -eq $webHash) 'partial config pair completed without overwriting existing file'
 Check ((ConvertTo-SetupNativeArgument '') -eq '""') 'native empty argument quoted'
 Check ((ConvertTo-SetupNativeArgument 'C:\plain.exe') -eq 'C:\plain.exe') 'native plain argument preserved'
 Check ((ConvertTo-SetupNativeArgument 'C:\with space\file') -eq '"C:\with space\file"') 'native spaced argument quoted'
 Write-Host "PASS TOTAL $count. Windows workflow tests; no SQL, IIS or service installation was executed."
}finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}}
