"""Portable text/structure checks only: does NOT execute PowerShell or compile C#."""
import argparse
import json
import re
from pathlib import Path


def main(root: Path) -> int:
    p = root / 'tools/Build-And-Test.ps1'
    s = p.read_text(encoding='utf-8-sig')
    checks = []
    def check(name, ok):
        checks.append({'test': name, 'status': 'PASS' if ok else 'FAIL'})
    check('Windows-only build is explicit', '[PlatformID]::Win32NT' in s)
    check('PowerShell 5.1 requirement', '#requires -Version 5.1' in s)
    check('output path resolved using PowerShell provider', 'GetUnresolvedProviderPathFromPSPath($OutputDirectory)' in s)
    check('explicit native process instead of ambiguous Compile command', 'New-Object Diagnostics.Process' in s and not re.search(r'(?m)^\s*Compile\s', s))
    check('wait and process-owned exit code', '$process.WaitForExit($TimeoutSeconds * 1000)' in s and '$exitCode = $process.ExitCode' in s)
    check('no native exit-code state inherited from caller', '$LASTEXITCODE' not in s)
    check('stdout and stderr drained asynchronously', s.count('.ReadToEndAsync()') == 2)
    check('stdout and stderr logs persisted', '[IO.File]::WriteAllText($stdoutFile, $stdout' in s and '[IO.File]::WriteAllText($stderrFile, $stderr' in s)
    check('response files used and default compiler rsp excluded', "'/noconfig @'" in s and '[IO.File]::WriteAllLines($rsp' in s)
    check('quotes in argument paths validated', 'IndexOfAny([char[]]@(0,10,13,34))' in s)
    check('compiler output checked after exit code', s.index('if ($result.ExitCode -ne 0)') < s.index('Assert-BuildAssembly -Path $OutputPath'))
    check('assembly existence size and metadata validated', all(x in s for x in ('-PathType Leaf', '.Length -le 0', '[Reflection.AssemblyName]::GetAssemblyName($Path)')))
    check('compiler preflight precedes application build', s.index('-Stage \'00-CompilerProbe\'') < s.index('-Stage \'01-WebCore\''))
    check('probe execution checked', 'IISREPORTS_COMPILER_PROBE_OK' in s and 'if ($probeRun.ExitCode -ne 0' in s)
    check('unit test execution and positive summary required', all(x in s for x in ('if ($unitRun.ExitCode -ne 0)', 'PASS TOTAL', '$unitSummary.Success', '.Value -lt 1')))
    check('staging directory is unique', "'.work\\' + $runId" in s and '[Guid]::NewGuid()' in s)
    check('build lock exclusive', '[IO.FileShare]::None' in s)
    check('prior success marker invalidated before compile', s.index('Remove-Item -LiteralPath $buildInfoPath') < s.index('-Stage \'00-CompilerProbe\''))
    check('success marker written only after test execution', s.index('Move-Item -LiteralPath $tempInfo -Destination $buildInfoPath') > s.index('$unitSummary.Success'))
    check('source changes during build checked', 'Source changed during compilation:' in s)
    check('test order and all test executables retained', "@('UnitTests','SqlIntegrationTests','DiscoverySqlTests')" in s and 'V3Discovery.cs' in s)
    check('no security bypass or installation command', not re.search(r'(?mi)^\s*(?:Start-Service|Install-WindowsFeature|Set-MpPreference|Invoke-Expression)\b', s))
    check('build marker compatible with packaging keys', all(x in s for x in ('artifacts=$artifactHashes', 'version=', 'unitTestsPassed=$true', 'sources=$sourceHashes')))
    check('standalone C# still identical', all((root / ('agent/Program.cs' if n == 'Program.cs' else 'web/App_Code/' + n)).read_bytes() == (root/'agent/source'/n).read_bytes() for n in ('Program.cs','V3Core.cs','V3Import.cs','V3Monitoring.cs','V3Discovery.cs')))
    report = {'suite': 'BUILD-FIX1 portable source checks, not PowerShell/C# execution', 'passed': sum(c['status']=='PASS' for c in checks), 'total':len(checks), 'tests':checks}
    (root/'tests/build-driver-static-results.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    for c in checks:
        print(c['status'], c['test'])
    print('RESULT', report['passed'], '/', report['total'])
    return 0 if report['passed'] == report['total'] else 1

if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    raise SystemExit(main(parser.parse_args().root))
