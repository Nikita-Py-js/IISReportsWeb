/* IIS Reports v3 read-only installation verification.
   Does not modify any database objects or rows. */
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
WHERE p.name IN (N'ir3_web',N'ir3_agent');
SELECT i.name AS IndexName, OBJECT_NAME(i.object_id) AS TableName
FROM sys.indexes AS i
JOIN sys.tables AS t ON t.object_id=i.object_id
WHERE t.schema_id=SCHEMA_ID(N'ir3') AND i.name LIKE N'%ir3%'
ORDER BY TableName,IndexName;
SELECT CASE WHEN SCHEMA_ID(N'ir3') IS NULL THEN N'ERROR: missing ir3 schema'
 WHEN (SELECT COUNT(*) FROM sys.tables WHERE schema_id=SCHEMA_ID(N'ir3')) <> 18 THEN N'ERROR: expected 18 tables'
 WHEN OBJECT_ID(N'ir3.CurrentRequests',N'V') IS NULL THEN N'ERROR: missing ir3.CurrentRequests view'
 WHEN DATABASE_PRINCIPAL_ID(N'ir3_web') IS NULL OR DATABASE_PRINCIPAL_ID(N'ir3_agent') IS NULL THEN N'ERROR: roles missing'
 ELSE N'OK: schema, 18 tables, view, and roles are present' END AS ValidationResult;
IF SCHEMA_ID(N'ir3') IS NULL
 OR (SELECT COUNT(*) FROM sys.tables WHERE schema_id=SCHEMA_ID(N'ir3')) <> 18
 OR OBJECT_ID(N'ir3.CurrentRequests',N'V') IS NULL
 OR DATABASE_PRINCIPAL_ID(N'ir3_web') IS NULL
 OR DATABASE_PRINCIPAL_ID(N'ir3_agent') IS NULL
 THROW 51110, 'Schema verification failed; review the result sets above.', 1;
GO
