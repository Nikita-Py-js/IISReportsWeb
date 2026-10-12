# OPTIONAL development check. Not needed to install: IIS compiles App_Code/ashx.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$out=Join-Path $env:TEMP ('IISReports-Simple-tests-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($out)
$csc=Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not(Test-Path $csc)){throw 'Windows .NET Framework compiler is not installed.'}
$baseArgs=@('/nologo','/langversion:5','/r:System.dll','/r:System.Core.dll','/r:System.Data.dll','/r:System.Configuration.dll','/r:System.Web.dll','/r:System.Web.Extensions.dll')
$code=@(Get-ChildItem "$root\web\App_Code\*.cs" | Select-Object -ExpandProperty FullName)
# Include the handler in the same test assembly: catches API references too.
$handler=Join-Path $out 'Reports.cs'
[IO.File]::WriteAllText($handler,([IO.File]::ReadAllText("$root\web\Reports.ashx") -replace '(?s)^\s*<%@.*?%>\s*',''),[Text.Encoding]::UTF8)
$exe=Join-Path $out 'UnitTests.exe'
& $csc @baseArgs /target:exe "/out:$exe" @code $handler "$PSScriptRoot\UnitTests.cs"
if($LASTEXITCODE -ne 0 -or -not(Test-Path $exe)){throw 'Compilation failed; see the compiler output above. No site files changed.'}
& $exe
if($LASTEXITCODE -ne 0){throw 'A unit test failed.'}
Write-Host "PASS compile + local tests. Output: $out"
Write-Host 'This did not connect to SQL Server and did not validate live IIS installation.'
