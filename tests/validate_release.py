"""Portable release consistency checks. NOT a PowerShell/C# compiler or live SQL test."""
import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from xml.etree import ElementTree

def run(root):
    results=[]
    def check(name, value):
        results.append({'test':name,'status':'PASS' if value else 'FAIL'})
    check('release version', (root/'VERSION').read_text().strip()=='3.0.2')
    for name in ('Program.cs','V3Core.cs','V3Import.cs','V3Monitoring.cs'):
        canonical=root/('agent/Program.cs' if name=='Program.cs' else 'web/App_Code/'+name)
        check('standalone source matches '+name, canonical.read_bytes()==(root/'agent/source'/name).read_bytes())
    for name in ('web/Web.config.example','agent/IISReports.Agent.exe.config.example','agent/IISReports.Agent.csproj'):
        try: ElementTree.parse(root/name); good=True
        except ElementTree.ParseError: good=False
        check('XML '+name,good)
    web=ElementTree.parse(root/'web/Web.config.example')
    check('default document explicitly enabled',web.find('./system.webServer/defaultDocument').get('enabled')=='true')
    check('directory listing disabled',web.find('./system.webServer/directoryBrowse').get('enabled')=='false')
    settings={n.get('key'):n.get('value') for n in web.findall('./appSettings/add')}
    check('Windows mode default',settings.get('IISReportsAccessMode')=='windows')
    check('no runtime production Web.config in sources',not (root/'web/Web.config').exists())
    sql=(root/'sql/001-v3-schema.sql').read_text(encoding='utf-8-sig')
    tables=re.findall(r'CREATE TABLE ir3\.(\w+)',sql)
    check('schema contains eighteen unique tables',len(tables)==18 and len(set(tables))==18)
    check('requests created before indexes',sql.index('CREATE TABLE ir3.Requests')<sql.index('CREATE INDEX IX_ir3_Requests_Ts'))
    check('no hardcoded new log sources',not re.search(r'INSERT ir3\.Sources\s*\(',sql,re.I))
    check('schema transaction rolls back on failure','BEGIN TRANSACTION' in sql and 'ROLLBACK TRANSACTION' in sql and 'THROW;' in sql)
    for value in ('new','queued','open','pending'):
        check('escaped SQL default '+value,"DEFAULT N''"+value+"''" in sql)
    schema_code=re.sub(r'/\*.*?\*/|--[^\n]*','',sql,flags=re.S)
    check('schema no destructive data operations',not re.search(r'\b(?:DROP\s+TABLE|TRUNCATE\s+TABLE|DELETE\s+FROM)\b',schema_code,re.I))
    core=(root/'web/App_Code/V3Core.cs').read_text(encoding='utf-8-sig')
    check('explicit datetime2 scale 7','SqlDbType.DateTime2' in core and 'p.Scale = 7' in core)
    sec=(root/'web/App_Code/Security.cs').read_text(encoding='utf-8-sig')
    for value in ('csrf_origin','csrf_missing','csrf_invalid','csrf_expired','MachineKey.Protect','MachineKey.Unprotect','SameSiteMode.Strict'):
        check('security guard present '+value,value in sec)
    http=(root/'tools/Test-Http.ps1').read_text(encoding='utf-8-sig')
    check('isolated HTTP requests','[System.Net.WebRequest]::Create' in http and 'New-Object System.Net.CookieContainer' in http)
    check('negative CSRF assertions kept',all(x in http for x in ('Missing CSRF header denied','Invalid CSRF token denied','Missing CSRF cookie denied',"-Status 403 -ApiCode 'csrf_missing'")))
    origin=(root/'tools/Set-IISReportsPublicOrigin.ps1').read_text(encoding='utf-8-sig')
    check('origin backup outside web root','BackupDirectory must be outside' in origin and "$fullConfig + '.bak.'" not in origin)
    clean=(root/'tools/New-InstallConfig.ps1').read_text(encoding='utf-8-sig')
    check('clean config independent of previous install','ExistingWebConfig' not in clean and 'WebSqlCredential' in clean and 'AgentSqlCredential' in clean)
    missing=[]
    for f in root.rglob('*.md'):
        text=re.sub(r'```.*?```','',f.read_text(encoding='utf-8-sig'),flags=re.S)
        for link in re.findall(r'\]\(([^)]+)\)',text):
            url=link.strip().split('#',1)[0]
            if not url or re.match(r'[A-Za-z]+:',url): continue
            if not (f.parent/url).exists():missing.append(f'{f.relative_to(root)}: {url}')
    check('all relative Markdown links resolve',not missing)
    if missing: print('\n'.join(missing))
    reserved=[]
    for f in root.rglob('*.ps1'):
        s=f.read_text(encoding='utf-8-sig')
        if re.search(r'(?im)^\s*\$(?:host|pid|pshome)\s*=',s):reserved.append(str(f.relative_to(root)))
    check('no assignment to selected readonly PowerShell automatic variables',not reserved)
    private=[]
    for f in root.rglob('*'):
        if f.is_file() and f.suffix.lower() in ('.ps1','.md','.cs','.config','.example'):
            if re.search(r'reument|225520',f.read_text(encoding='utf-8-sig'),re.I): private.append(str(f.relative_to(root)))
    check('no previous server-specific names/paths in public sources/docs',not private)
    if private: print('\n'.join(private))
    report={'suite':'portable source/package consistency (not compilation)', 'passed':sum(r['status']=='PASS' for r in results), 'total':len(results),'tests':results}
    (root/'tests/consistency-results.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(report,indent=2))
    return all(r['status']=='PASS' for r in results)
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[1])
    sys.exit(0 if run(parser.parse_args().root) else 1)
