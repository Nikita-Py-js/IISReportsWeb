# Windows PowerShell 5.1, .NET Framework 4.8. Build the agent from the FIVE source files in this folder.
[CmdletBinding()]
param([string]$OutputDirectory='')
$ErrorActionPreference='Stop'
if(-not $OutputDirectory){$OutputDirectory=Join-Path $PSScriptRoot 'build'}
$dir=[IO.Path]::GetFullPath($OutputDirectory)
if(-not(Test-Path -LiteralPath $dir)){New-Item -ItemType Directory -Path $dir -Force|Out-Null}
$csc=Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not(Test-Path -LiteralPath $csc)){$csc=Join-Path $env:windir 'Microsoft.NET\Framework\v4.0.30319\csc.exe'}
if(-not(Test-Path -LiteralPath $csc)){throw '.NET Framework 4.8 C# compiler not found.'}
$files=@('Program.cs','V3Core.cs','V3Import.cs','V3Monitoring.cs','V3Discovery.cs')|ForEach-Object{Join-Path $PSScriptRoot $_}
foreach($file in $files){if(-not(Test-Path -LiteralPath $file)){throw "Missing: $file"}}
$output=Join-Path $dir 'IISReports.Agent.exe'
& $csc /nologo /langversion:5 /optimize+ /warn:4 /utf8output /target:exe `
  /r:System.dll /r:System.Core.dll /r:System.Data.dll /r:System.Configuration.dll `
  /r:System.Web.dll /r:System.Web.Extensions.dll /r:System.Xml.dll /r:System.ServiceProcess.dll `
  "/out:$output" @files
if($LASTEXITCODE -ne 0){throw "Agent compilation failed, exit code $LASTEXITCODE"}
Write-Host "Built $output"
Write-Host "SHA256: $((Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash)"
Write-Host 'Create IISReports.Agent.exe.config separately; do not publish connection-string secrets.'
