#requires -Version 5.1
# Standalone agent source build. Does not install, start or connect to SQL.
[CmdletBinding()]
param([string]$OutputDirectory='')
$ErrorActionPreference='Stop'
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $PSVersionTable.PSEdition -ne 'Desktop'){throw 'Use Windows PowerShell 5.1 and .NET Framework 4.8.'}
if(-not $OutputDirectory){$OutputDirectory=Join-Path $PSScriptRoot 'build'}
$dir=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($dir)
$work=Join-Path $dir ('work-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($work)
$csc=Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not(Test-Path -LiteralPath $csc)){$csc=Join-Path $env:windir 'Microsoft.NET\Framework\v4.0.30319\csc.exe'}
if(-not(Test-Path -LiteralPath $csc)){throw '.NET Framework C# compiler not found.'}
$files=@('Program.cs','V3Core.cs','V3Import.cs','V3Monitoring.cs','V3Discovery.cs')|ForEach-Object{Join-Path $PSScriptRoot $_}
$output=Join-Path $work 'IISReports.Agent.exe'
$rsp=@('/nologo','/langversion:5','/optimize+','/warn:4','/utf8output','/target:exe','/out:"'+$output+'"')
foreach($assembly in @('System.dll','System.Core.dll','System.Data.dll','System.Configuration.dll','System.Web.dll','System.Web.Extensions.dll','System.Xml.dll','System.ServiceProcess.dll')){$rsp+='/reference:'+ $assembly}
foreach($file in $files){if(-not(Test-Path -LiteralPath $file -PathType Leaf)){throw "Missing: $file"};if($file -match '[\x00\r\n"]'){throw 'Unsafe compiler source path.'};$rsp+='"'+$file+'"'}
$rspFile=Join-Path $work 'agent.rsp';[IO.File]::WriteAllLines($rspFile,[string[]]$rsp,(New-Object Text.UTF8Encoding($true)))
$psi=New-Object Diagnostics.ProcessStartInfo
$psi.FileName=$csc;$psi.Arguments='/noconfig @"'+$rspFile+'"';$psi.WorkingDirectory=$work
$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
$psi.StandardOutputEncoding=New-Object Text.UTF8Encoding($false);$psi.StandardErrorEncoding=$psi.StandardOutputEncoding
$p=New-Object Diagnostics.Process;$p.StartInfo=$psi
try{
 if(-not $p.Start()){throw 'Compiler failed to start.'}
 $outTask=$p.StandardOutput.ReadToEndAsync();$errTask=$p.StandardError.ReadToEndAsync()
 if(-not $p.WaitForExit(300000)){try{$p.Kill()}catch{};throw "Compiler timed out. Inspect $work"}
 $stdout=$outTask.Result;$stderr=$errTask.Result
 [IO.File]::WriteAllText((Join-Path $work 'compiler.stdout.log'),$stdout)
 [IO.File]::WriteAllText((Join-Path $work 'compiler.stderr.log'),$stderr)
 if($stdout){Write-Host $stdout};if($stderr){Write-Host $stderr}
 if($p.ExitCode -ne 0){throw "Agent compilation failed: exit=$($p.ExitCode). Logs: $work"}
}finally{$p.Dispose()}
if(-not(Test-Path -LiteralPath $output -PathType Leaf) -or (Get-Item -LiteralPath $output).Length -eq 0){throw 'Compiler did not create a nonempty EXE.'}
$null=[Reflection.AssemblyName]::GetAssemblyName($output)
$target=Join-Path $dir 'IISReports.Agent.exe';Copy-Item -LiteralPath $output -Destination $target -Force
if((Get-FileHash -LiteralPath $target).Hash -ne (Get-FileHash -LiteralPath $output).Hash){throw 'Output copy hash mismatch.'}
Write-Host "Built $target"
Write-Host "SHA256: $((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash)"
Write-Host 'No unit/SQL/HTTP tests were run. Use the complete project Build-And-Test.ps1 before deployment.'
