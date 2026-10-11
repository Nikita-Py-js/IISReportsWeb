/* IIS Reports 3.1.0 -- read-only schema verification (VERIFY-FIX1).
   001-v3-schema.sql creates 18 CORE tables.
   005-auto-sources.sql adds ir3.DiscoveryState (19 total at v3.1.0).
   Verify core objects by NAME instead of rejecting additional tables.
   Then run 006-auto-sources-verify.sql to require schema version 310.
   No DDL/DML; no modifications to existing data or schema. */
SET NOCOUNT ON;

SELECT DB_NAME() AS DatabaseName, USER_NAME() AS ExecutingDatabaseUser,
       SCHEMA_ID(N'ir3') AS Ir3SchemaId,
       (SELECT compatibility_level FROM sys.databases WHERE name=DB_NAME()) AS CompatibilityLevel;

SELECT t.name AS TableName
FROM sys.tables AS t
WHERE t.schema_id=SCHEMA_ID(N'ir3')
ORDER BY t.name;

SELECT v.name AS ViewName
FROM sys.views AS v
WHERE v.schema_id=SCHEMA_ID(N'ir3')
ORDER BY v.name;

SELECT p.name AS RoleName, p.type_desc AS PrincipalType
FROM sys.database_principals AS p
WHERE p.name IN (N'ir3_web', N'ir3_agent')
ORDER BY p.name;

SELECT i.name AS IndexName, OBJECT_NAME(i.object_id) AS TableName
FROM sys.indexes AS i
JOIN sys.tables AS t ON t.object_id=i.object_id
WHERE t.schema_id=SCHEMA_ID(N'ir3') AND i.name LIKE N'%ir3%'
ORDER BY TableName, IndexName;

-- Exactly the 18 core objects created by 001-v3-schema.sql.
DECLARE @CoreTables TABLE (TableName sysname NOT NULL PRIMARY KEY);
INSERT INTO @CoreTables(TableName) VALUES
(N'AgentState'),
(N'AlertRules'),
(N'AlertState'),
(N'AuditEvents'),
(N'CheckResults'),
(N'Checks'),
(N'Files'),
(N'Generations'),
(N'ImportChunks'),
(N'ImportRuns'),
(N'IncidentEvents'),
(N'Incidents'),
(N'Jobs'),
(N'NotificationOutbox'),
(N'RawEvents'),
(N'Requests'),
(N'SchemaVersions'),
(N'Sources');

DECLARE @MissingCount int;
SELECT @MissingCount=COUNT(*)
FROM @CoreTables AS expected
LEFT JOIN sys.tables AS actual
  ON actual.schema_id=SCHEMA_ID(N'ir3') AND actual.name=expected.TableName
WHERE actual.object_id IS NULL;

SELECT expected.TableName AS MissingRequiredCoreTable
FROM @CoreTables AS expected
LEFT JOIN sys.tables AS actual
  ON actual.schema_id=SCHEMA_ID(N'ir3') AND actual.name=expected.TableName
WHERE actual.object_id IS NULL
ORDER BY expected.TableName;

SELECT (SELECT COUNT(*) FROM sys.tables WHERE schema_id=SCHEMA_ID(N'ir3')) AS ActualTableCount,
       (SELECT COUNT(*) FROM @CoreTables) AS RequiredCoreTableCount,
       @MissingCount AS MissingCoreTableCount;

DECLARE @ValidationResult nvarchar(256);
SET @ValidationResult = CASE
 WHEN SCHEMA_ID(N'ir3') IS NULL THEN N'ERROR: missing ir3 schema'
 WHEN @MissingCount<>0 THEN N'ERROR: required core table(s) missing (see MissingRequiredCoreTable)'
 WHEN OBJECT_ID(N'ir3.CurrentRequests',N'V') IS NULL THEN N'ERROR: missing ir3.CurrentRequests view'
 WHEN DATABASE_PRINCIPAL_ID(N'ir3_web') IS NULL
   OR DATABASE_PRINCIPAL_ID(N'ir3_agent') IS NULL THEN N'ERROR: SQL roles missing'
 ELSE N'OK: 18 required core tables, view, and roles are present. Extra migration tables allowed; run 006 for schema 310.'
 END;
SELECT @ValidationResult AS ValidationResult;
IF @ValidationResult LIKE N'ERROR:%'
    THROW 51110, 'Schema verification failed; review the result sets above.', 1;
GO
