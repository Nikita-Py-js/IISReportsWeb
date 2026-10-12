/* IIS Reports v3: READ ONLY audit of four critical default constraints.
   Works in the IISReports database. Does not modify objects or data.
   For each row, ExpectedSqlLiteral should be present within ActualDefinition.
   Use this report when investigating jobs stuck in non-queued states.
*/
SET NOCOUNT ON;
DECLARE @Defaults TABLE (TableName sysname, ColumnName sysname, ExpectedValue nvarchar(32));
INSERT @Defaults VALUES
 (N'Files', N'Status', N'new'),
 (N'Jobs', N'State', N'queued'),
 (N'Incidents', N'State', N'open'),
 (N'NotificationOutbox', N'State', N'pending');
DECLARE @Results TABLE(TableName sysname,ColumnName sysname,ExpectedValue nvarchar(32),ActualDefinition nvarchar(max),AuditStatus nvarchar(80));
INSERT @Results
SELECT e.TableName, e.ColumnName, e.ExpectedValue,
       d.definition AS ActualDefinition,
       CASE WHEN t.object_id IS NULL OR col.column_id IS NULL THEN N'MISSING COLUMN'
            WHEN d.object_id IS NULL THEN N'MISSING DEFAULT'
            WHEN REPLACE(REPLACE(REPLACE(d.definition, N'(', N''), N')', N''), N' ', N'')
                 IN (N'''' + e.ExpectedValue + N'''', N'N''' + e.ExpectedValue + N'''')
                 THEN N'OK'
            WHEN d.definition LIKE N'%' + e.ExpectedValue + N'%' THEN N'REVIEW: unexpected quotation'
            ELSE N'UNEXPECTED VALUE' END AS AuditStatus
FROM @Defaults e
LEFT JOIN sys.tables t ON t.name=e.TableName AND t.schema_id=SCHEMA_ID(N'ir3')
LEFT JOIN sys.columns col ON col.object_id=t.object_id AND col.name=e.ColumnName
LEFT JOIN sys.default_constraints d ON d.parent_object_id=col.object_id AND d.parent_column_id=col.column_id
;
SELECT * FROM @Results ORDER BY TableName,ColumnName;
IF EXISTS(SELECT 1 FROM @Results WHERE AuditStatus<>N'OK')
 THROW 51040,'Default-constraint verification failed. Review the audit rows; no objects were modified.',1;
-- Actual existing job states and the current queue, including unexpected state values:
IF OBJECT_ID(N'ir3.Jobs', N'U') IS NOT NULL
    EXEC sys.sp_executesql N'SELECT State, COUNT_BIG(*) AS JobCount FROM ir3.Jobs GROUP BY State ORDER BY State;';
