"""Static SQL verifier checks, not execution of SQL Server batches."""
import re
from pathlib import Path
root=Path(__file__).resolve().parents[1]
sql=(root/'sql/003-v3-verify.sql').read_text(encoding='utf-8-sig')
base=(root/'sql/001-v3-schema.sql').read_text(encoding='utf-8-sig')
addon=(root/'sql/005-auto-sources.sql').read_text(encoding='utf-8-sig')
verify=(root/'sql/006-auto-sources-verify.sql').read_text(encoding='utf-8-sig')
base_names=set(re.findall(r'CREATE TABLE ir3\.(\w+)',base))
assert len(base_names)==18,base_names
assert 'CREATE TABLE ir3.DiscoveryState' in addon
required=set(re.findall(r"\(N'([A-Za-z]+)'\)", sql.split('INSERT INTO @CoreTables(TableName) VALUES',1)[1].split(';',1)[0]))
assert required == base_names, (sorted(required-base_names),sorted(base_names-required))
assert 'LEFT JOIN sys.tables' in sql and 'actual.name=expected.TableName' in sql
assert 'COUNT(*) <> 18' not in sql and 'COUNT(*) != 18' not in sql
assert "N'ir3.DiscoveryState'" in verify and 'Version=310' in verify
assert "N'ir3.CurrentRequests'" in sql and "N'ir3_web'" in sql and "N'ir3_agent'" in sql
# No SQL mutations in the verifier after excluding comments and string literals.
code=re.sub(r'/\*.*?\*/|--[^\n]*', '', sql,flags=re.S)
code=re.sub(r"N?'(?:''|[^'])*'", "''", code)
# INSERT only populates a local TABLE variable, not persistent SQL tables.
code=re.sub(r'INSERT\s+INTO\s+@CoreTables\s*\(TableName\)\s*VALUES\s*\(.*?\);', '', code, flags=re.I|re.S)
assert not re.search(r'\b(?:CREATE|ALTER|DROP|INSERT|UPDATE|DELETE|TRUNCATE|EXEC)\b',code,re.I)
print('PASS: 18 core table names match installer; 19th table and 310 checked separately; verifier is read-only.')
