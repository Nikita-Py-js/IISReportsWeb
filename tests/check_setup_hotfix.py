"""Structural setup checks only: NOT a PowerShell parser or Windows ACL test."""
from pathlib import Path
import json, re, sys
root=Path(__file__).resolve().parents[1]
common=(root/'tools/Setup.Common.ps1').read_text(encoding='utf-8-sig')
config=(root/'tools/New-InstallConfig.ps1').read_text(encoding='utf-8-sig')
probe=(root/'tools/Test-SqlConnection.ps1').read_text(encoding='utf-8-sig')
test=(root/'tools/Test-SetupPaths.ps1').read_text(encoding='utf-8-sig')
helper=common.split('function New-RestrictedDirectory {',1)[1].split('function Save-NewXml(',1)[0]
results=[]
def check(name,value):
 results.append({'test':name,'status':'PASS' if value else 'FAIL'})
check('no native launch in directory helper',not re.search(r'(?im)^\s*&|Start-Process|ProcessStartInfo',helper))
check('Windows Framework explicitly required',"PSEdition -ne 'Desktop'" in helper)
check('administrator required','Assert-Administrator' in helper)
check('explicit local path guard',"Directory -notmatch '^[A-Za-z]:\\\\'" in common)
check('root guard','Refusing to change permissions on a drive root.' in common)
check('reparse-point ancestors guarded','[IO.FileAttributes]::ReparsePoint' in common and 'while ($cursor)' in common)
check('nonempty folder not rewritten','Directory contains files and does not have the expected restricted ACL.' in helper)
check('exact protected ACL','SetAccessRuleProtection($true,$false)' in helper and 'rules.Count -ne 2' in common)
check('SID based administrators and SYSTEM',"@('S-1-5-32-544','S-1-5-18')" in helper)
check('managed creation and update','[IO.Directory]::CreateDirectory($full,$acl)' in helper and '[IO.Directory]::SetAccessControl($full,$acl)' in helper)
check('resultant DACL verified','Test-RestrictedDirectoryAcl -Acl $actual' in helper)
check('no files written by helper',not re.search(r'Save-NewXml|WriteAllText|WriteAllBytes|XmlWriter',helper))
check('templates validated before ACL change',config.index('[xml]$agent')<config.index('New-RestrictedDirectory -Directory $dir'))
check('ACL checked before configs saved',config.index('New-RestrictedDirectory -Directory $dir')<config.index('Save-NewXml $plan.Document'))
check('working config overwrite guard retained','Configuration already exists:' in config)
check('SQL builder FIX1 retained',"$b['Data Source'] = $SqlServer" in common and "$b['Encrypt'] = $true" in common)
query=probe.split("$cmd.CommandText=@'",1)[1].split("'@",1)[0]
check('probe only identity SELECT',query.strip().startswith('SELECT') and not re.search(r'\bCREATE|\bALTER|\bDELETE|\bINSERT|\bUPDATE',query,re.I))
check('probe preserves connection security','-TrustServerCertificate ([bool]$TrustServerCertificate)' in probe and 'ServerCertificateValidationCallback' not in probe)
check('probe does not print connection string','Write-Host $cs' not in probe and 'ConnectionString' not in probe)
check('test uses unique temp child',"[Guid]::NewGuid().ToString('N')" in test and '-LiteralPath $testDir -Recurse -Force' in test)
check('test existing XML no overwrite','existing XML not overwritten' in test)
check('test unused native command trap','function icacls.exe' in test)
report={'suite':'structural setup checks; not Windows execution', 'passed':sum(x['status']=='PASS' for x in results),'total':len(results),'tests':results}
(root/'tests/setup-hotfix-static-results.json').write_text(json.dumps(report,indent=2)+'\n')
for x in results: print(x['status'],x['test'])
sys.exit(0 if report['passed']==report['total'] else 1)
