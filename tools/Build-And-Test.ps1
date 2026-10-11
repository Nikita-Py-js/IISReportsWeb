[CmdletBinding()]
param([string]$OutputDirectory='')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
& (Join-Path $PSScriptRoot 'Test-PowerShellSyntax.ps1') -Root $root
if(-not $OutputDirectory){$OutputDirectory=Join-Path $root 'build'}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$out=(Resolve-Path -LiteralPath $OutputDirectory).Path
# A failed rebuild must not leave a successful build marker behind.
$buildInfoPath=Join-Path $out 'BUILDINFO.json'
if(Test-Path -LiteralPath $buildInfoPath){Remove-Item -LiteralPath $buildInfoPath}
$csc=Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not (Test-Path -LiteralPath $csc)){$csc=Join-Path $env:windir 'Microsoft.NET\Framework\v4.0.30319\csc.exe'}
if(-not (Test-Path -LiteralPath $csc)){throw '.NET Framework C# compiler not found. .NET Framework 4.8 is required.'}
$refs=@('/r:System.dll','/r:System.Core.dll','/r:System.Data.dll','/r:System.Configuration.dll','/r:System.Web.dll','/r:System.Web.Extensions.dll','/r:System.Xml.dll')
$common=@('/nologo','/langversion:5','/optimize+','/warn:4','/utf8output')+$refs
function Compile([string[]]$Options) {
    & $csc @Options
    if($LASTEXITCODE -ne 0){throw 'C# compilation failed. No files have been deployed.'}
}
foreach($sharedName in @('Program.cs','V3Core.cs','V3Import.cs','V3Monitoring.cs')) {
    $canonical=if($sharedName -eq 'Program.cs'){Join-Path $root 'agent\Program.cs'}else{Join-Path $root ('web\App_Code\'+$sharedName)}
    $copy=Join-Path $root ('agent\source\'+$sharedName)
    if((Get-FileHash -LiteralPath $canonical -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash) {throw "Standalone source is out of sync: $sharedName"}
}
$webSources=@(Get-ChildItem -LiteralPath (Join-Path $root 'web\App_Code') -Filter '*.cs' | ForEach-Object {$_.FullName})
$core=Join-Path $out 'IISReports.WebCore.dll'
Compile ($common+@('/target:library',"/out:$core")+$webSources)
$handler=[IO.File]::ReadAllText((Join-Path $root 'web\Reports.ashx'))
$handler=[regex]::Replace($handler,'(?s)^\s*<%@.*?%>\s*','')
$handlerFile=Join-Path $out 'ReportsHandler.cs';[IO.File]::WriteAllText($handlerFile,$handler,(New-Object Text.UTF8Encoding($true)))
Compile ($common+@('/target:library',"/r:$core",('/out:'+(Join-Path $out 'IISReports.HandlerTest.dll')),$handlerFile))
$agentSources=@('V3Core.cs','V3Import.cs','V3Monitoring.cs') | ForEach-Object {Join-Path $root "web\App_Code\$_"}
Compile ($common+@('/target:exe','/r:System.ServiceProcess.dll',('/out:'+(Join-Path $out 'IISReports.Agent.exe')),(Join-Path $root 'agent\Program.cs'))+$agentSources)
foreach($name in @('UnitTests','SqlIntegrationTests')) {
    Compile ($common+@('/target:exe',"/r:$core",('/out:'+(Join-Path $out "$name.exe")),(Join-Path $root "tests\$name.cs")))
}
& (Join-Path $out 'UnitTests.exe')
if($LASTEXITCODE -ne 0){throw 'Unit tests failed.'}
Write-Host "Compiled web, handler and agent; local unit tests passed. Output: $out"
Write-Host 'SQL integration and live IIS authentication/CSRF tests are separate. Do not copy WebCore.dll into web/Bin: App_Code compiles the same classes.'

# Bind the build to its source files; packaging with -SkipBuild checks these hashes.
$sourceFiles=@($webSources)+@((Join-Path $root 'agent\Program.cs'),(Join-Path $root 'web\Reports.ashx'),(Join-Path $root 'tests\UnitTests.cs'),(Join-Path $root 'tests\SqlIntegrationTests.cs'))
$sourceHashes=@($sourceFiles | Sort-Object -Unique | ForEach-Object {
    [pscustomobject]@{path=$_.Substring($root.Length+1).Replace('\','/');sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash}
})
$artifactHashes=@(@('IISReports.Agent.exe','IISReports.WebCore.dll','IISReports.HandlerTest.dll','UnitTests.exe','SqlIntegrationTests.exe') | ForEach-Object {
    [pscustomobject]@{name=$_;sha256=(Get-FileHash -LiteralPath (Join-Path $out $_) -Algorithm SHA256).Hash}
})
$info=[ordered]@{artifacts=$artifactHashes;version=([IO.File]::ReadAllText((Join-Path $root 'VERSION')).Trim());builtUtc=[DateTime]::UtcNow.ToString('o');compiler=$csc;unitTestsPassed=$true;sources=$sourceHashes}
[IO.File]::WriteAllText((Join-Path $out 'BUILDINFO.json'),($info | ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
