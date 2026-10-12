#requires -Version 5.1
# BUILD-FIX1: explicit native process execution, staged artifacts and persistent logs.
# This script only builds/tests local sources. It never installs or starts the service.
[CmdletBinding()]
param(
    [string]$OutputDirectory = '',
    [ValidateRange(30, 3600)][int]$ProcessTimeoutSeconds = 300
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Windows and the .NET Framework C# compiler are required for this build.'
}
$root = (Resolve-Path -LiteralPath (Split-Path $PSScriptRoot -Parent)).Path
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'build' }
$OutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$out = (Resolve-Path -LiteralPath $OutputDirectory).Path
$runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
$logDir = Join-Path $out ('logs\' + $runId)
$work = Join-Path $out ('.work\' + $runId)
[void][IO.Directory]::CreateDirectory($logDir)
[void][IO.Directory]::CreateDirectory($work)
$script:BuildLogPath = Join-Path $logDir 'build.log'
$script:BuildUtf8 = New-Object Text.UTF8Encoding($false)
$buildInfoPath = Join-Path $out 'BUILDINFO.json'
$buildLock = $null

function Write-BuildLog {
    param([Parameter(Mandatory=$true)][string]$Text)
    [IO.File]::AppendAllText($script:BuildLogPath, $Text + [Environment]::NewLine, $script:BuildUtf8)
    Write-Host $Text
}

function Quote-CscValue {
    param([Parameter(Mandatory=$true)][string]$Value)
    if ($Value.IndexOfAny([char[]]@(0,10,13,34)) -ge 0) {
        throw 'A compiler path contains a quote, NUL or newline.'
    }
    return '"' + $Value + '"'
}

function Invoke-IISReportsBuildProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [AllowEmptyString()][string]$ArgumentLine = '',
        [Parameter(Mandatory=$true)][string]$WorkingDirectory,
        [Parameter(Mandatory=$true)][string]$LogPrefix,
        [Parameter(Mandatory=$true)][int]$TimeoutSeconds
    )
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw "Executable is missing before launch: $FilePath"
    }
    $stdoutFile = $LogPrefix + '.stdout.log'
    $stderrFile = $LogPrefix + '.stderr.log'
    [IO.File]::WriteAllText($stdoutFile, '', $script:BuildUtf8)
    [IO.File]::WriteAllText($stderrFile, '', $script:BuildUtf8)
    Write-BuildLog ('RUN: "{0}" {1}' -f $FilePath, $ArgumentLine)
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $ArgumentLine
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = $script:BuildUtf8
    $startInfo.StandardErrorEncoding = $script:BuildUtf8
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Process.Start returned false.' }
        # Drain both streams concurrently; reading them sequentially can deadlock.
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $exited = $process.WaitForExit($TimeoutSeconds * 1000)
        if (-not $exited) {
            try { $process.Kill() } catch { Write-BuildLog ('STOP ERROR: ' + $_.Exception.Message) }
            if (-not $process.WaitForExit(5000)) { throw 'Timed-out process did not stop.' }
        }
        # Complete stream reads after process exit.
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        [IO.File]::WriteAllText($stdoutFile, $stdout, $script:BuildUtf8)
        [IO.File]::WriteAllText($stderrFile, $stderr, $script:BuildUtf8)
        if (-not [string]::IsNullOrWhiteSpace($stdout)) { Write-BuildLog ($stdout.TrimEnd()) }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) { Write-BuildLog ($stderr.TrimEnd()) }
        $exitCode = $process.ExitCode
        Write-BuildLog ('EXIT: {0}' -f $exitCode)
        if (-not $exited) { throw "Process timed out after $TimeoutSeconds seconds. See $LogPrefix.*.log" }
        return [pscustomobject]@{ ExitCode=$exitCode; Stdout=$stdout; Stderr=$stderr }
    }
    catch {
        [IO.File]::AppendAllText($stderrFile, [Environment]::NewLine + $_.Exception.Message, $script:BuildUtf8)
        throw
    }
    finally { $process.Dispose() }
}

function Assert-BuildAssembly {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Expected compiler output is missing: $Path. Inspect this run's compiler logs and local protection logs. Do not disable protection or skip tests."
    }
    if ((Get-Item -LiteralPath $Path).Length -le 0) { throw "Compiler output is empty: $Path" }
    # Read assembly metadata without loading/executing the assembly.
    try { $null = [Reflection.AssemblyName]::GetAssemblyName($Path) }
    catch { throw "Compiler output is not a readable managed assembly: $Path. $($_.Exception.Message)" }
}

function Invoke-IISReportsCsc {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Stage,
        [Parameter(Mandatory=$true)][string]$Compiler,
        [Parameter(Mandatory=$true)][ValidateSet('exe','library')][string]$Target,
        [Parameter(Mandatory=$true)][string]$OutputPath,
        [Parameter(Mandatory=$true)][string[]]$SourceFiles,
        [string[]]$References = @(),
        [Parameter(Mandatory=$true)][string]$Logs,
        [Parameter(Mandatory=$true)][string]$WorkingDirectory,
        [Parameter(Mandatory=$true)][int]$TimeoutSeconds
    )
    if ($SourceFiles.Count -eq 0) { throw "No source files for $Stage" }
    if (Test-Path -LiteralPath $OutputPath) { throw "Staging output already exists: $OutputPath" }
    $rspLines = @('/nologo','/langversion:5','/optimize+','/warn:4','/utf8output','/fullpaths','/errorreport:none')
    $rspLines += '/target:' + $Target
    $rspLines += '/out:' + (Quote-CscValue -Value $OutputPath)
    foreach ($reference in $References) { $rspLines += '/reference:' + (Quote-CscValue -Value $reference) }
    foreach ($source in $SourceFiles) {
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Source file is missing: $source" }
        $rspLines += Quote-CscValue -Value $source
    }
    $rsp = Join-Path $Logs ($Stage + '.rsp')
    [IO.File]::WriteAllLines($rsp, [string[]]$rspLines, (New-Object Text.UTF8Encoding($true)))
    Write-BuildLog ("BUILD {0}: {1}" -f $Stage, $OutputPath)
    # One quoted response-file argument; no PowerShell array/positional argument ambiguity.
    $result = Invoke-IISReportsBuildProcess -FilePath $Compiler -ArgumentLine ('/noconfig @' + (Quote-CscValue -Value $rsp)) -WorkingDirectory $WorkingDirectory -LogPrefix (Join-Path $Logs $Stage) -TimeoutSeconds $TimeoutSeconds
    if ($result.ExitCode -ne 0) { throw "C# compilation failed at $Stage (exit $($result.ExitCode)). See $rsp and the adjacent log files." }
    Assert-BuildAssembly -Path $OutputPath
    Write-BuildLog ("PASS artifact: {0} ({1} bytes)" -f [IO.Path]::GetFileName($OutputPath), (Get-Item -LiteralPath $OutputPath).Length)
}

try {
    # Refuse concurrent builds writing the same destination.
    $buildLock = [IO.File]::Open((Join-Path $out '.build.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    [IO.File]::WriteAllText((Join-Path $out 'LAST-BUILD-LOG.txt'), $script:BuildLogPath, $script:BuildUtf8)
    # A failed rebuild must never leave a successful build marker behind.
    if (Test-Path -LiteralPath $buildInfoPath) { Remove-Item -LiteralPath $buildInfoPath }
    Write-BuildLog 'IIS Reports 3.1.1 BUILD-FIX1'
    Write-BuildLog ('Package: ' + $root)
    Write-BuildLog ('Output: ' + $out)
    Write-BuildLog ('PowerShell: ' + $PSVersionTable.PSVersion.ToString())
    Write-BuildLog ('Logs: ' + $logDir)
    & (Join-Path $PSScriptRoot 'Test-PowerShellSyntax.ps1') -Root $root

    $csc = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) { $csc = Join-Path $env:windir 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
    if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) { throw '.NET Framework C# compiler not found. .NET Framework 4.8 is required.' }
    Write-BuildLog ('Compiler: ' + $csc)
    Write-BuildLog ('Compiler file version: ' + (Get-Item -LiteralPath $csc).VersionInfo.FileVersion)
    foreach ($sharedName in @('Program.cs','V3Core.cs','V3Import.cs','V3Monitoring.cs','V3Discovery.cs')) {
        $canonical = if ($sharedName -eq 'Program.cs') { Join-Path $root 'agent\Program.cs' } else { Join-Path $root ('web\App_Code\' + $sharedName) }
        $copy = Join-Path $root ('agent\source\' + $sharedName)
        if ((Get-FileHash -LiteralPath $canonical -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash) { throw "Standalone source is out of sync: $sharedName" }
    }
    $webSources = @(Get-ChildItem -LiteralPath (Join-Path $root 'web\App_Code') -Filter '*.cs' -File | Sort-Object FullName | ForEach-Object { $_.FullName })
    $sourceFiles = @($webSources) + @('agent\Program.cs','web\Reports.ashx','tests\UnitTests.cs','tests\SqlIntegrationTests.cs','tests\DiscoverySqlTests.cs','tools\Build-And-Test.ps1','tools\Test-PowerShellSyntax.ps1' | ForEach-Object { Join-Path $root $_ })
    $sourceHashes = @($sourceFiles | Sort-Object -Unique | ForEach-Object {
        [pscustomobject]@{ path=$_.Substring($root.Length+1).Replace('\','/'); sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }
    })
    $refs = @('System.dll','System.Core.dll','System.Data.dll','System.Configuration.dll','System.Web.dll','System.Web.Extensions.dll','System.Xml.dll')
    $compileArgs = @{ Compiler=$csc; Logs=$logDir; WorkingDirectory=$work; TimeoutSeconds=$ProcessTimeoutSeconds }

    # Preflight the compiler AND executable launch before building the full project.
    $probeCs = Join-Path $work 'CompilerProbe.cs'
    [IO.File]::WriteAllText($probeCs, 'public static class CompilerProbe { public static int Main() { System.Console.WriteLine("IISREPORTS_COMPILER_PROBE_OK"); return 0; } }', (New-Object Text.UTF8Encoding($true)))
    $probeExe = Join-Path $work 'CompilerProbe.exe'
    Invoke-IISReportsCsc @compileArgs -Stage '00-CompilerProbe' -Target exe -OutputPath $probeExe -SourceFiles @($probeCs) -References @('System.dll')
    $probeRun = Invoke-IISReportsBuildProcess -FilePath $probeExe -WorkingDirectory $work -LogPrefix (Join-Path $logDir '00-CompilerProbe-run') -TimeoutSeconds $ProcessTimeoutSeconds
    if ($probeRun.ExitCode -ne 0 -or $probeRun.Stdout -notmatch '(?m)^IISREPORTS_COMPILER_PROBE_OK\s*$') { throw 'Compiler probe could not execute successfully. See probe logs; no application files have been deployed.' }
    Write-BuildLog 'PASS compiler probe'

    $core = Join-Path $work 'IISReports.WebCore.dll'
    Invoke-IISReportsCsc @compileArgs -Stage '01-WebCore' -Target library -OutputPath $core -SourceFiles $webSources -References $refs
    $handler = [IO.File]::ReadAllText((Join-Path $root 'web\Reports.ashx'))
    $handler = [regex]::Replace($handler, '(?s)^\s*<%@.*?%>\s*', '')
    $handlerFile = Join-Path $work 'ReportsHandler.cs'
    [IO.File]::WriteAllText($handlerFile, $handler, (New-Object Text.UTF8Encoding($true)))
    Invoke-IISReportsCsc @compileArgs -Stage '02-Handler' -Target library -OutputPath (Join-Path $work 'IISReports.HandlerTest.dll') -SourceFiles @($handlerFile) -References ($refs + @($core))
    $agentSources = @((Join-Path $root 'agent\Program.cs')) + @('V3Core.cs','V3Import.cs','V3Monitoring.cs','V3Discovery.cs' | ForEach-Object { Join-Path $root ('web\App_Code\' + $_) })
    Invoke-IISReportsCsc @compileArgs -Stage '03-Agent' -Target exe -OutputPath (Join-Path $work 'IISReports.Agent.exe') -SourceFiles $agentSources -References ($refs + @('System.ServiceProcess.dll'))
    $ordinal = 4
    foreach ($testName in @('UnitTests','SqlIntegrationTests','DiscoverySqlTests')) {
        Invoke-IISReportsCsc @compileArgs -Stage ('{0:00}-{1}' -f $ordinal,$testName) -Target exe -OutputPath (Join-Path $work ($testName + '.exe')) -SourceFiles @((Join-Path $root ('tests\' + $testName + '.cs'))) -References ($refs + @($core))
        $ordinal++
    }
    $unitExe = Join-Path $work 'UnitTests.exe'
    Assert-BuildAssembly -Path $unitExe
    $unitRun = Invoke-IISReportsBuildProcess -FilePath $unitExe -WorkingDirectory $work -LogPrefix (Join-Path $logDir '07-UnitTests-run') -TimeoutSeconds $ProcessTimeoutSeconds
    if ($unitRun.ExitCode -ne 0) { throw "Unit tests failed (exit $($unitRun.ExitCode)). See 07-UnitTests-run logs." }
    $unitSummary = [regex]::Match($unitRun.Stdout, '(?m)^PASS TOTAL\s+(\d+)\s*$')
    if (-not $unitSummary.Success -or [int]$unitSummary.Groups[1].Value -lt 1) { throw 'Unit tests exited without the expected PASS TOTAL summary.' }
    $unitCount = [int]$unitSummary.Groups[1].Value
    foreach ($source in $sourceHashes) {
        if ((Get-FileHash -LiteralPath (Join-Path $root $source.path) -Algorithm SHA256).Hash -ne $source.sha256) { throw "Source changed during compilation: $($source.path). Rebuild." }
    }
    # Publish only the six known artifacts, after every compilation and local test succeeds.
    $artifactNames = @('IISReports.Agent.exe','IISReports.WebCore.dll','IISReports.HandlerTest.dll','UnitTests.exe','SqlIntegrationTests.exe','DiscoverySqlTests.exe')
    foreach ($artifactName in $artifactNames) {
        $from = Join-Path $work $artifactName
        $to = Join-Path $out $artifactName
        Assert-BuildAssembly -Path $from
        Copy-Item -LiteralPath $from -Destination $to -Force
        Assert-BuildAssembly -Path $to
        if ((Get-FileHash -LiteralPath $from -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $to -Algorithm SHA256).Hash) { throw "Artifact copy verification failed: $artifactName" }
    }
    $artifactHashes = @($artifactNames | ForEach-Object { [pscustomobject]@{ name=$_; sha256=(Get-FileHash -LiteralPath (Join-Path $out $_) -Algorithm SHA256).Hash } })
    $info = [ordered]@{
        artifacts=$artifactHashes; version=([IO.File]::ReadAllText((Join-Path $root 'VERSION')).Trim())
        buildDriver='BUILD-FIX1'; builtUtc=[DateTime]::UtcNow.ToString('o'); compiler=$csc
        unitTestsPassed=$true; unitTestCount=$unitCount; sources=$sourceHashes; logDirectory=$logDir
    }
    $tempInfo = Join-Path $out ('BUILDINFO.' + $runId + '.tmp')
    [IO.File]::WriteAllText($tempInfo, ($info | ConvertTo-Json -Depth 6), $script:BuildUtf8)
    Move-Item -LiteralPath $tempInfo -Destination $buildInfoPath
    Write-BuildLog ("SUCCESS: 6 artifacts verified; {0} local unit tests passed. Output: {1}" -f $unitCount,$out)
    Write-BuildLog 'SQL integration and live IIS authentication/CSRF tests are separate. Do not copy test DLLs into web/Bin.'
}
catch {
    if ($null -ne $buildLock -and (Test-Path -LiteralPath $buildInfoPath)) { Remove-Item -LiteralPath $buildInfoPath -ErrorAction SilentlyContinue }
    Write-BuildLog ('FAILED: ' + $_.Exception.Message)
    Write-BuildLog ('Log directory: ' + $logDir)
    Write-BuildLog 'No IIS configuration, service or SQL data was changed. Do not install artifacts from a failed build.'
    throw
}
finally {
    if ($null -ne $buildLock) { $buildLock.Dispose() }
    # Staging files are kept for diagnosis. Do not deploy them.
}
