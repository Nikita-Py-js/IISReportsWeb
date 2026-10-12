"""Portable textual/structural regression checks. NOT PowerShell execution or a parser."""
from pathlib import Path
import json
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
results = []
def text(rel):
    return (ROOT / rel).read_text(encoding='utf-8-sig')
def check(name, condition):
    results.append({'test': name, 'status': 'PASS' if condition else 'FAIL'})
    print(('PASS ' if condition else 'FAIL ') + name)
def params(rel):
    header = text(rel).split("$ErrorActionPreference", 1)[0]
    return set(re.findall(r'\$(\w+)', header))
def forwarded_map(script, variable):
    m = re.search(r'\$' + re.escape(variable) + r'\s*=\s*@\{([^}]+)\}', script)
    return set(re.findall(r'(\w+)\s*=', m.group(1))) if m else set()

runner = text('Install.ps1')
plan = text('tools/Install.Plan.ps1')
common = text('tools/Setup.Common.ps1')
config = text('tools/New-InstallConfig.ps1')
http = text('tools/Test-Http.ps1')
api = text('web/App_Code/V3Api.cs')
steps = set(re.search(r'\[ValidateSet\(([^)]+)\)\]', runner).group(1).replace("'", '').split(','))
expected = {'Check','Prerequisites','Build','Database','Config','Web','Agent','Permissions','SecurityTest','Start','Verify'}
check('eleven explicit installation stages, no unsafe All mode', steps == expected)
check('each documented main stage exists', set(re.findall(r'-Step ([A-Za-z]+)', text('docs/INSTALL.md'))) <= steps)
check('all main stages documented', expected <= set(re.findall(r'-Step ([A-Za-z]+)', text('docs/INSTALL.md'))))
check('settings imported as data, not executed', 'Import-PowerShellDataFile' in plan and 'Invoke-Expression' not in plan)
check('PowerShell 5.1 Path fallback provided', "ContainsKey('LiteralPath')" in plan and 'WildcardPattern' in plan)
check('relative settings resolved before changing cwd', runner.index('Resolve-Path -LiteralPath $SettingsFile') < runner.index('Set-Location -LiteralPath $pkg'))
check('both native and PowerShell working directories explicit', 'Set-Location -LiteralPath $pkg' in runner and '[Environment]::CurrentDirectory=$pkg' in runner)
allowed = set(re.findall(r"'([^']+)'", re.search(r'\$allowed=@\(([^)]+)\)', plan).group(1)))
for filename, mode in [('LocalHttp.psd1','LocalHttp'),('Https.psd1','Https'),('ReverseProxy.psd1','ReverseProxy')]:
    t = text('setup/' + filename)
    keys = set(re.findall(r'^\s+(\w+)\s*=', t, re.M))
    check('template keys match schema: ' + filename, keys == allowed)
    check('template binding mode: ' + filename, bool(re.search(r"BindingMode\s*=\s*'" + mode + "'", t)))
    check('template secure SQL default: ' + filename, bool(re.search(r'TrustSqlCertificate\s*=\s*\$false', t)))
check('rejects missing or mistyped settings', 'Unknown installation setting' in plan and 'Missing installation setting' in plan)
check('rejects string booleans', '-isnot [bool]' in plan)
check('rejects placeholder editor and system database', 'REPLACE' in plan and "@('master','model','msdb','tempdb')" in plan)
check('rejects SQL URLs/double escaping', "Contains('\\\\')" in plan and 'https?://' in plan)
check('requires separate source/config/web/agent roots', 'non-nested directories' in plan and 'Keep setup settings outside' in plan)
for variable, child in [('dbArgs','Initialize-Database.ps1'),('probe','Test-SqlConnection.ps1'),('argsConfig','New-InstallConfig.ps1'),('argsWeb','Install-Web.ps1')]:
    forwarded = forwarded_map(runner, variable)
    check('forwarded keys accepted by ' + child, bool(forwarded) and forwarded <= params('tools/' + child))
check('SQL probe admin credential uses correct parameter', '$probe.AdminCredential=$AdminCredential' in runner and 'AdminCredential' in params('tools/Test-SqlConnection.ps1'))
check('missing configuration reported before IIS resolves it', text('tools/Install-Web.ps1').index('Assert-SetupFile $ConfigFile') < text('tools/Install-Web.ps1').index('Resolve-Path -LiteralPath $ConfigFile'))
check('SQL builder uses canonical dictionary keywords', "$b['Data Source'] = $SqlServer" in common and '$b.DataSource =' not in common)
check('existing config pair checked before directory/file writes', config.index('foreach($plan in $plans)') < config.index('New-RestrictedDirectory -Directory $dir') < config.index('Save-NewXml $plan.Document'))
check('existing config mismatch never silently overwritten', 'EquivalentTo' in config and 'No files changed.' in config and '[switch]$UseExisting' in config)
check('config file write atomic and without replace', '[IO.File]::Move(' in common and 'Save-NewXml' in common)
check('both generated files validated after writing', 'Test-InstallConfig.ps1' in config and 'Assert-SetupFile $path' in config)
check('directory ACL creation uses managed API', '[IO.Directory]::CreateDirectory($full,$acl)' in common or '[IO.Directory]::CreateDirectory($full, $acl)' in common)
check('native commands have explicit cwd and wait', '$psi.WorkingDirectory=' in common and '$p.WaitForExit(' in common)
for rel in ['tools/Install-Web.ps1','tools/Install-Agent.ps1','tools/Enable-WindowsAuth.ps1','tools/Install-AutoDiscovery.ps1']:
    source = re.sub(r'(?m)^\s*#.*$', '', text(rel))
    check('no icacls launch: ' + rel, not re.search(r'(?im)^\s*&\s*(?:["\']?[^\r\n ]*icacls)', source))
check('discovery respects PowerShell execution policy', '-ExecutionPolicy Bypass' not in text('tools/Install-AutoDiscovery.ps1'))
check('agent initially Manual and stopped', "'start=','demand'" in text('tools/Install-Agent.ps1') and 'Start-Service' not in text('tools/Install-Agent.ps1'))
start_stage = runner.split("'Start' {",1)[1].split("'Verify' {",1)[0]
check('fresh security check required before starting agent', start_stage.index('Test-Http.ps1') < start_stage.index('Start-Service'))
verify_stage = runner.split("'Verify' {",1)[1]
check('Verify checks installed files and live health', '-Strict' in verify_stage and 'Test-Health.ps1' in verify_stage)
check('live health does not accept HTTP 200 alone', all(x in text('tools/Test-Health.ps1') for x in ['$result.agentOnline','$result.discoveryHealthy','$result.healthy']))
check('CSRF no-op registered as protected write', 'new[]{"csrf-check","refresh"' in api and 'if(Writes.Contains(action))AccessControl.RequirePost(ctx);' in api)
check('CSRF no-op exits before SQL access', api.index('if(action=="csrf-check")return') < api.index('using(var c=Store.Open())'))
check('isolated HTTP request per call', '[System.Net.WebRequest]::Create($url)' in http)
check('negative CSRF tests target no-op action', http.count("-Action 'csrf-check'") == 5)
check('real refresh POST requires QueueScan', "if ($QueueScan)" in http and http.count("-Action 'refresh'") == 2 and http.index("if ($QueueScan)") < http.index("-Name 'Valid POST queues scan'"))
check('positive CSRF control verifies no-op payload', '$positive.Data.validated -ne $true' in http and '$positive.Data.mutation -ne $false' in http)
check('invalid SQL defaults now fail verification', 'THROW 51040' in text('sql/004-v3-defaults-audit.sql'))
check('core schema verifier accepts extra named tables', 'MissingCoreTableCount' in text('sql/003-v3-verify.sql'))
check('existing source checkbox semantics retained', 'SourceSelection.CanImport' in api and 'SourceSelection' in text('web/App_Code/V3Import.cs'))
for name in ['Program.cs','V3Core.cs','V3Import.cs','V3Monitoring.cs','V3Discovery.cs']:
    canonical = 'agent/Program.cs' if name == 'Program.cs' else 'web/App_Code/' + name
    check('agent source exact copy: ' + name, (ROOT/canonical).read_bytes() == (ROOT/'agent/source'/name).read_bytes())
check('standalone build checks exit and assembly metadata', 'ExitCode' in text('agent/source/Build-Agent-Standalone.ps1') and 'GetAssemblyName' in text('agent/source/Build-Agent-Standalone.ps1'))
check('new workflow test does not need SQL/IIS writes', 'Read-InstallPlan' in text('tools/Test-InstallWorkflow.ps1') and 'New-InstallConfig.ps1' in text('tools/Test-InstallWorkflow.ps1') and 'Initialize-Database.ps1' not in text('tools/Test-InstallWorkflow.ps1'))
check('CI includes actual future Windows workflow test', 'Test-InstallWorkflow.ps1' in text('.github/workflows/windows-build.yml'))
check('docs state Windows execution not performed here', 'НЕ выполнено' in text('docs/TESTING.md') and 'не выполнены' in text('docs/TESTING.md').lower())
report = {'suite':'portable installer contract (text/structure only; not PowerShell execution)', 'passed': sum(x['status']=='PASS' for x in results), 'total':len(results), 'tests':results}
(ROOT/'tests/install-contract-results.json').write_text(json.dumps(report, indent=2)+'\n')
sys.exit(0 if report['passed']==report['total'] else 1)
