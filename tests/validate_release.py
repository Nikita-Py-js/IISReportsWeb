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
    check('release version', (root/'VERSION').read_text().strip()=='3.1.0')
    for name in ('Program.cs','V3Core.cs','V3Import.cs','V3Monitoring.cs','V3Discovery.cs'):
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
    auto=(root/'web/App_Code/V3Discovery.cs').read_text(encoding='utf-8-sig')
    migration=(root/'sql/005-auto-sources.sql').read_text(encoding='utf-8-sig')
    api=(root/'web/App_Code/V3Api.cs').read_text(encoding='utf-8-sig')
    importer=(root/'web/App_Code/V3Import.cs').read_text(encoding='utf-8-sig')
    installer=(root/'tools/Install-Agent.ps1').read_text(encoding='utf-8-sig')
    task=(root/'tools/Install-AutoDiscovery.ps1').read_text(encoding='utf-8-sig')
    publisher=(root/'discovery/Export-IISInventory.ps1').read_text(encoding='utf-8-sig')
    initdb=(root/'tools/Initialize-Database.ps1').read_text(encoding='utf-8-sig')
    check('migration adds nineteenth table', 'CREATE TABLE ir3.DiscoveryState' in migration and 'DiscoveryState' not in tables)
    check('schema version 310 checked by runtime', bool(re.search(r'!=\s*310',core)) and 'VALUES(310)' in migration)
    stripped=re.sub(r'/\*.*?\*/|--[^\n]*','',migration,flags=re.S)
    check('new migration does not delete or truncate data',not re.search(r'\b(?:DROP\s+TABLE|TRUNCATE\s+TABLE|DELETE\s+FROM)\b',stripped,re.I))
    check('web granted source flag/revision columns only', 'GRANT UPDATE (Enabled,Revision) ON OBJECT::ir3.Sources TO ir3_web' in migration)
    check('source choices use explicit nullable boolean', 'bool? enabled' in auto and '!x.enabled.HasValue' in auto)
    check('source changes use revision and rollback scope', 'Revision=@revision' in auto and 'SourceConflictException' in auto and 'using(var tx=c.BeginTransaction())' in auto)
    check('rediscovery never updates Enabled or Revision',not re.search(r'UPDATE ir3\.Sources SET[^;]*(?:Enabled|Revision)\s*=',auto.split('public static void Apply(',1)[1],re.I))
    check('snapshot is bounded and validated before Apply', '4*1024*1024' in auto and 'DateTime stamp=Validate(' in auto and auto.index('DateTime stamp=Validate(')<auto.index('Apply(connection,snapshot,stamp)'))
    check('snapshot validates machine and freshness','Inventory belongs to a different machine' in auto and 'maxAgeSeconds' in auto)
    check('missing metadata retires availability, not monitoring choice',"Available=0,DiscoveryStatus='not_in_iis'" in auto)
    check('pause checked inside batch transaction','SourceSelection.RequireImport(c,tx,sourceId,true)' in importer)
    check('pause is not treated as corrupted source','catch(SourcePausedException)' in importer)
    check('sources-save shares mutation CSRF guard','"sources-save"' in api.split('public static bool Handles',1)[0] and 'if(Writes.Contains(action))AccessControl.RequirePost(ctx)' in api)
    check('sources-save requires editor role',api.index('AccessControl.RequireEditor(ctx); // Operational')<api.index('if(action=="sources-save")'))
    check('agent installation installs inventory task','Install-AutoDiscovery.ps1' in installer and 'SkipAutoDiscovery' in installer)
    check('publisher uses IIS MWA without changing config','Microsoft.Web.Administration.ServerManager' in publisher and 'CommitChanges' not in publisher and 'SqlConnection' not in publisher)
    check('publisher handles unsupported modes explicitly',all(x in publisher for x in ('central_unsupported','format_unsupported','etw_only','waiting_directory','ReparsePoint')))
    check('publisher replaces snapshot atomically','[IO.File]::Replace' in publisher and '[IO.File]::Move' in publisher)
    check('task principal uses SYSTEM, not agent admin','S-1-5-18' in task and "-LogonType ServiceAccount" in task and "'ReadAndExecute'" in task)
    check('task protects parent and directory DACL','SetAccessRuleProtection($true,$false)' in task and 'Set-Acl -LiteralPath (Split-Path $dir -Parent)' in task)
    check('database installer applies and verifies 005/006','005-auto-sources.sql' in initdb and '006-auto-sources-verify.sql' in initdb)
    verify_sql=(root/'sql/003-v3-verify.sql').read_text(encoding='utf-8-sig')
    check('core verifier uses table-name membership, not exact table count','LEFT JOIN sys.tables' in verify_sql and 'actual.name=expected.TableName' in verify_sql and 'expected 18 tables' not in verify_sql)
    check('3.1 discovery verifier still checks schema 310',"Version=310" in (root/'sql/006-auto-sources-verify.sql').read_text())
    docs=(root/'docs/INSTALL.md').read_text()
    check('clean install needs no manual source variables',not re.search(r'(?m)^\$(?:sourceSiteId|sourceName|logRoot)\s*=',docs))
    check('HTTP test protects source endpoint', 'Source choices require CSRF' in http and 'Empty source change set is rejected' in http)
    build=(root/'tools/Build-And-Test.ps1').read_text(encoding='utf-8-sig')
    check('build includes discovery and SQL regression tests','V3Discovery.cs' in build and 'DiscoverySqlTests' in build)
    check('standalone and csproj include discovery','V3Discovery.cs' in (root/'agent/IISReports.Agent.csproj').read_text() and 'V3Discovery.cs' in (root/'agent/source/Build-Agent-Standalone.ps1').read_text(encoding='utf-8-sig'))
    check('SQL connection builder fix preserved',"$b['Data Source'] = $SqlServer" in (root/'tools/Setup.Common.ps1').read_text(encoding='utf-8-sig'))
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
