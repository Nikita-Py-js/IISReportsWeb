"""Static consistency checks only. Does not compile C# or execute PowerShell/SQL."""
import json
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from collections import Counter
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
checks = []
def check(name, condition):
    checks.append({'name': name, 'passed': bool(condition)})
    if not condition:
        raise AssertionError(name)

def read(name):
    return (ROOT / name).read_text(encoding='utf-8-sig')

required = ['Setup.ps1', 'Stop-Legacy.ps1', 'README.md', 'web/Web.config', 'web/Reports.ashx',
            'web/index.html', 'web/v3.js', 'web/App_Code/SimpleRuntime.cs',
            'sql/001-v3-schema.sql', 'sql/005-auto-sources.sql']
for name in required:
    check('required file: ' + name, (ROOT / name).is_file())

class Html(HTMLParser):
    def __init__(self):
        super().__init__(); self.ids = []; self.scripts = []; self.collect = False; self.text = ''
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if 'id' in attrs: self.ids.append(attrs['id'])
        if tag == 'script' and 'src' not in attrs: self.collect = True; self.text = ''
    def handle_data(self, data):
        if self.collect: self.text += data
    def handle_endtag(self, tag):
        if tag == 'script' and self.collect: self.scripts.append(self.text); self.collect = False
h = Html(); h.feed(read('web/index.html'))
check('unique HTML ids', not [i for i, n in Counter(h.ids).items() if n > 1])
js = '\n'.join(h.scripts) + '\n' + read('web/v3.js')
for code in h.scripts + [read('web/v3.js')]:
    with tempfile.NamedTemporaryFile(suffix='.js', mode='w', encoding='utf-8') as f:
        f.write(code); f.flush()
        result = subprocess.run(['node', '--check', f.name], capture_output=True, text=True)
        check('JavaScript syntax: script ' + str(len(checks)), result.returncode == 0)
static_ids = set(re.findall(r"\$\(['\"]([^'\"]+)['\"]\)", js))
check('static JavaScript ids exist in HTML', static_ids.issubset(set(h.ids)))
check('no CSRF token acquisition in client', "api('csrf'" not in js and 'renewToken(' not in js)
check('custom request header on POST', "'X-IISReports-Request':'1'" in js)
check('auto-import checks page visibility', '!document.hidden' in js)
check('no overlapping imports in browser', 'if(refreshing)return;' in js)
check('checkbox save API used', "api('sources-save'" in js)
check('manual network monitoring button used', "api('monitor'" in js)

config = ET.fromstring(read('web/Web.config'))
settings = {node.attrib['key']: node.attrib['value'] for node in config.findall('./appSettings/add')}
check('single connection string setting', bool(settings.get('ConnStr')))
check('log roots configured', bool(settings.get('LogRoots')))
check('no mandatory PublicOrigin or editor setting', not {'IISReportsPublicOrigin','IISReportsEditors'} & set(settings))
check('Web.config default index.html', config.find('./system.webServer/defaultDocument/files/add').attrib['value'] == 'index.html')
check('no Windows-auth requirement in application', config.find('./system.web/authentication').attrib['mode'] == 'None')
check('no package EXE needed or bundled', not list(ROOT.rglob('*.exe')))

runtime = read('web/App_Code/SimpleRuntime.cs')
security = read('web/App_Code/Security.cs')
api = read('web/App_Code/V3Api.cs')
importer = read('web/App_Code/V3Import.cs')
selection = read('web/App_Code/V3Discovery.cs')
core = read('web/App_Code/V3Core.cs')
setup = read('Setup.ps1')
check('import performed synchronously in refresh', 'return SimpleRuntime.Refresh();' in api)
check('direct directory discovery', 'Directory.GetDirectories(full,"W3SVC*"' in runtime)
check('no inventory timestamps or snapshots in runtime', 'generatedUtc' not in runtime and 'DiscoveryState' not in runtime)
check('single importer SQL lock retained', "IISReports.v3.agent" in runtime and "@LockTimeout=0" in runtime)
check('lock connection is not pooled', 'b.Pooling=false' in runtime)
check('discovery does not overwrite Enabled on existing source', not re.search(r'UPDATE ir3\.Sources SET [^;\n]*Enabled\s*=', runtime, re.I))
check('source pause is rechecked at batch commit', 'SourceSelection.RequireImport(c,tx,sourceId,true)' in importer)
check('atomic batch checkpoint', 'tx.Commit();' in importer and 'CommittedOffset=@end' in importer)
check('datetime2 parameters retain precision', 'SqlDbType.DateTime2' in core and 'p.Scale = 7' in core)
check('same-size timestamp changes can trigger reread', 'ObservedMtime<>@m' in importer)
check('reappeared file can resume', "WHEN Status='missing'" in importer)
check('truncated files preserve history', 'File was truncated' in importer)
check('source choices are versioned', 'Revision' in selection and 'BeginTransaction' in selection)
check('minimal write-method validation', 'c.Request.HttpMethod!="POST"' in security)
check('minimal write-header validation', 'c.Request.Headers["X-IISReports-Request"]!="1"' in security)
check('normal refresh does not perform network monitoring', '.Deliver()' not in runtime.split('public static object Refresh()')[1].split('public static object RunMonitoring()')[0])
check('no mandatory agent heartbeat', 'heartbeatAgeSeconds' not in runtime and 'AgentState' not in runtime)
check('no binary/compiler/service required in setup', not re.search(r'csc\.exe|Register-ScheduledTask|New-Service|ServiceBase', setup))
check('setup creates application directory', '[IO.Directory]::CreateDirectory($full)' in setup)
check('setup writes Web.config directly', '$config.Save("$full\\Web.config")' in setup)
check('setup uses canonical SQL keys', "$b['Data Source']" in setup and '$b.DataSource' not in setup)
check('setup repeats without resetting configured authentication', 'if($createdSite)' in setup)
check('setup default listener is loopback', "[string]$BindAddress = '127.0.0.1'" in setup)
check('setup creates only dedicated pool SQL permissions', 'GRANT SELECT,INSERT,UPDATE,DELETE ON SCHEMA::ir3' in setup)
check('no service code in web', not re.search(r'ServiceBase|Task\.Run\(|QueueBackgroundWorkItem', '\n'.join(p.read_text('utf-8-sig') for p in (ROOT/'web/App_Code').glob('*.cs'))))

sqls = [read('sql/001-v3-schema.sql'), read('sql/005-auto-sources.sql')]
check('SQL can be submitted without GO splitter', not any(re.search(r'^\s*GO\s*$', s, re.M | re.I) for s in sqls))
check('no destructive schema reset', not any(re.search(r'\bDROP\s+(TABLE|DATABASE|SCHEMA)\b|\bTRUNCATE\s+TABLE\b', s, re.I) for s in sqls))
check('compatible current requests view retained', 'ir3.CurrentRequests' in sqls[0])
check('schema 310 extension supplied', '310' in sqls[1] and 'ir3.DiscoveryState' in sqls[1])

for md in ROOT.rglob('*.md'):
    for target in re.findall(r'\]\(([^)]+)\)', md.read_text('utf-8-sig')):
        if '://' in target or target.startswith('#'): continue
        path = unquote(target.split('#')[0])
        check('Markdown link: ' + str(md.relative_to(ROOT)) + ' -> ' + path,
              (md.parent / path).exists())

browser = json.loads(read('tests/browser-results.json'))
check('browser test result available', len(browser['checks']) == 44 and all(x['status'] == 'PASS' for x in browser['checks']))
report = {
    'version': read('VERSION').strip(),
    'scope': 'Static consistency, JavaScript syntax, XML and documentation links only; not a C#/PowerShell compiler or SQL execution',
    'checks': checks,
    'passed': len(checks),
    'browser': {'checks': len(browser['checks']), 'mode': 'Chromium; mocked HTTP/SQL responses'},
    'not_executed': ['Windows PowerShell 5.1', 'C# compilation under .NET Framework', 'IIS setup and NTFS ACL', 'SQL Server integration', 'Live HTTP import and authentication'],
}
(ROOT / 'tests/validation.json').write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding='utf-8')
print('PASS', len(checks), 'static consistency checks; Windows/SQL not executed')
