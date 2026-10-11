/* IIS Reports v3.0 -- corrected full SQL schema installer, revision 302.
   Execute in SSMS as DBA in the IISReports database (not master).
   Requires SQL Server 2012+, database compatibility >= 110.
   NO DROP/TRUNCATE/DELETE. Existing dbo.* data is unchanged.
   All DDL is executed in child batches so newly created metadata can be resolved.
   The full installation is one transaction: any failure rolls it back.
   Re-runnable for a correctly installed ir3 schema. */
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() IN (N'master', N'model', N'msdb', N'tempdb')
    THROW 51001, 'Choose your IISReports database in SSMS, not a system database.', 1;
IF CAST(DATABASEPROPERTYEX(DB_NAME(), 'Updateability') AS nvarchar(60)) <> N'READ_WRITE'
    THROW 51002, 'Selected database is not writable.', 1;
IF (SELECT compatibility_level FROM sys.databases WHERE name=DB_NAME()) < 110
    THROW 51003, 'Database compatibility level 110 or higher is required.', 1;

BEGIN TRY
    BEGIN TRANSACTION;
    IF SCHEMA_ID(N'ir3') IS NULL
        EXEC sys.sp_executesql N'CREATE SCHEMA ir3 AUTHORIZATION dbo;';
    IF SCHEMA_ID(N'ir3') IS NULL
        THROW 51010, 'Schema ir3 was not created: check database permissions.', 1;

    IF OBJECT_ID(N'ir3.SchemaVersions') IS NOT NULL AND OBJECT_ID(N'ir3.SchemaVersions', N'U') IS NULL
        THROW 51011, 'ir3.SchemaVersions exists but is not a table.', 1;
    IF OBJECT_ID(N'ir3.SchemaVersions', N'U') IS NULL
    BEGIN
        EXEC sys.sp_executesql N'CREATE TABLE ir3.SchemaVersions(Version int NOT NULL PRIMARY KEY, AppliedUtc datetime2(7) NOT NULL DEFAULT SYSUTCDATETIME());';
        PRINT N'Created ir3.SchemaVersions';
    END;
    IF OBJECT_ID(N'ir3.Sources') IS NOT NULL AND OBJECT_ID(N'ir3.Sources', N'U') IS NULL
        THROW 51011, 'ir3.Sources exists but is not a table.', 1;
    IF OBJECT_ID(N'ir3.Sources', N'U') IS NULL
    BEGIN
        EXEC sys.sp_executesql N'CREATE TABLE ir3.Sources(
  Id int IDENTITY PRIMARY KEY, Name nvarchar(128) NOT NULL, SiteId int NOT NULL,
  RootPath nvarchar(1024) NOT NULL, Enabled bit NOT NULL DEFAULT 1,
  LastScanUtc datetime2(7) NULL, LastError nvarchar(1024) NULL);';
        PRINT N'Created ir3.Sources';
    END;
    IF OBJECT_ID(N'ir3.Files') IS NOT NULL AND OBJECT_ID(N'ir3.Files', N'U') IS NULL
        THROW 51011, 'ir3.Files exists but is not a table.', 1;
    IF OBJECT_ID(N'ir3.Files', N'U') IS NULL
    BEGIN
        EXEC sys.sp_executesql N'CREATE TABLE ir3.Files(
  Id bigint IDENTITY PRIMARY KEY, SourceId int NOT NULL REFERENCES ir3.Sources(Id),
  PathKey binary(32) NOT NULL, FullPath nvarchar(1024) NOT NULL, ActiveGenerationId bigint NULL,
  ObservedSize bigint NOT NULL DEFAULT 0, ObservedMtime datetime2(7) NULL, LastSeenUtc datetime2(7) NULL,
  Status nvarchar(32) NOT NULL DEFAULT N''new'', LastError nvarchar(1024) NULL,
  CONSTRAINT UQ_ir3_Files UNIQUE(SourceId,PathKey));';
        PRINT N'Created ir3.Files';
    END;
    IF OBJECT_ID(N'ir3.Generations') IS NOT NULL AND OBJECT_ID(N'ir3.Generations', N'U') IS NULL
        THROW 51011, 'ir3.Generations exists but is not a table.', 1;
    IF OBJECT_ID(N'ir3.Generations', N'U') IS NULL
    BEGIN
        EXEC sys.sp_executesql N'CREATE TABLE ir3.Generations(
  Id bigint IDENTITY PRIMARY KEY, FileId bigint NOT NULL REFERENCES ir3.Files(Id), Number int NOT NULL,
  CreatedUtc datetime2(7) NOT NULL DEFAULT SYSUTCDATETIME(), Reason nvarchar(256) NOT NULL,
  CommittedOffset bigint NOT NULL DEFAULT 0, LineNumber bigint NOT NULL DEFAULT 0,
  Fields nvarchar(max) NULL, LastImportUtc datetime2(7) NULL,
  LastVerifiedUtc datetime2(7) NULL, VerificationStatus nvarchar(32) NULL,
  CONSTRAINT UQ_ir3_Generations UNIQUE(FileId,Number),
  CONSTRAINT CK_ir3_Offset CHECK(CommittedOffset>=0));';
        PRINT N'Created ir3.Generations';
    END;
    IF OBJECT_ID(N'ir3.RawEvents') IS NOT NULL AND OBJECT_ID(N'ir3.RawEvents', N'U') IS NULL
        THROW 51011, 'ir3.RawEvents exists but is not a table.', 1;
    IF OBJECT_ID(N'ir3.RawEvents', N'U') IS NULL
    BEGIN
        EXEC sys.sp_executesql N'CREATE TABLE ir3.RawEvents(
  Id bigint IDENTITY PRIMARY KEY, GenerationId bigint NOT NULL REFERENCES ir3.Generations(Id),
  ByteOffset bigint NOT NULL, EndOffset bigint NOT NULL, LineNumber bigint NOT NULL,
  RawText nvarchar(max) NOT NULL, RawHash binary(32) NOT NULL,
  ParseError nvarchar(512) NULL, ParserVersion int NOT NULL,
  ImportedUtc datetime2(7) NOT NULL DEFAULT SYSUTCDATETIME(),
  CONSTRAINT UQ_ir3_Raw UNIQUE(GenerationId,ByteOffset));';
        PRINT N'Created ir3.RawEvents';
    END;
    IF OBJECT_ID(N'ir3.Requests') IS NOT NULL AND OBJECT_ID(N'ir3.Requests', N'U') IS NULL
        THROW 51011, 'ir3.Requests exists but is not a table.', 1;
    IF OBJECT_ID(N'ir3.Requests', N'U') IS NULL
    BEGIN
        EXEC sys.sp_executesql N'CREATE TABLE ir3.Requests(
  Id bigint IDENTITY PRIMARY KEY, GenerationId bigint NOT NULL, ByteOffset bigint NOT NULL,
  RawEventId bigint NOT NULL REFERENCES ir3.RawEvents(Id), Ts datetime2(7) NOT NULL,
  SiteId int NOT NULL, ServerIp nvarchar(45) NULL, ServerPort int NULL,
  ClientIp nvarchar(45) NULL, UserName nvarchar(256) NULL, Method nvarchar(16) NULL,
  UriStem nvarchar(2048) NULL, UriQuery nvarchar(2048) NULL,
  Status int NULL, SubStatus int NULL, Win32Status bigint NULL, TimeMs bigint NULL,
  UserAgent nvarchar(1024) NULL, Referer nvarchar(2048) NULL, LogFile nvarchar(1024) NULL,
  CONSTRAINT UQ_ir3_Requests UNIQUE(GenerationId,ByteOffset));';
        PRINT N'Created ir3.Requests';
    END;
    IF OBJECT_ID(N'ir3.ImportChunks') IS NOT NULL AND OBJECT_ID(N'ir3.ImportChunks', N'U') IS NULL
        THROW 51011, 'ir3.ImportChunks exists but is not a table.', 1;
    IF OBJECT_ID(N'ir3.ImportChunks', N'U') IS NULL
    BEGIN
        EXEC sys.sp_executesql N'CREATE TABLE ir3.ImportChunks(
  GenerationId bigint NOT NULL REFERENCES ir3.Generations(Id), StartOffset bigint NOT NULL,
  EndOffset bigint NOT NULL, Sha256 binary(32) NOT NULL,
  ImportedUtc datetime2(7) NOT NULL DEFAULT SYSUTCDATETIME(),
  CONSTRAINT PK_ir3_Chunks PRIMARY KEY(GenerationId,StartOffset,EndOffset));';
        PRINT N'Created ir3.ImportChunks';
    END;
    IF OBJECT_ID(N'ir3.ImportRuns') IS NOT NULL AND OBJECT_ID(N'ir3.ImportRuns', N'U') IS NULL
        THROW 51011, 'ir3.ImportRuns exists but is not a table.', 1;
    IF OBJECT_ID(N'ir3.ImportRuns', N'U') IS NULL
    BEGIN
        EXEC sys.sp_executesql N'CREATE TABLE ir3.ImportRuns(
  Id uniqueidentifier NOT NULL PRIMARY KEY, StartedUtc datetime2(7) NOT NULL,
  FinishedUtc datetime2(7) NULL, Kind nvarchar(32) NOT NULL, FileId bigint NULL,
  Status nvarchar(32) NOT NULL, RowsProcessed bigint NOT NULL DEFAULT 0,
  Detail nvarchar(2048) NULL);';
        PRINT N'Created ir3.ImportRuns';
    END;
    IF OBJECT_ID(N'ir3.AgentState') IS NOT NULL AND OBJECT_ID(N'ir3.AgentState', N'U') IS NULL
        THROW 51011, 'ir3.AgentState exists but is not a table.', 1;
    IF OBJECT_ID(N'ir3.AgentState', N'U') IS NULL
    BEGIN
        EXEC sys.sp_executesql N'CREATE TABLE ir3.AgentState(
  Id int NOT NULL PRIMARY KEY CHECK(Id=1), MachineName nvarchar(256) NOT NULL,
  HeartbeatUtc datetime2(7) NOT NULL, LastScanUtc datetime2(7) NULL,
  LastSuccessfulScanUtc datetime2(7) NULL, State nvarchar(32) NOT NULL,
  LastError nvarchar(2048) NULL, Version nvarchar(32) NOT NULL);';
        PRINT N'Created ir3.AgentState';
    END;
    IF OBJECT_ID(N'ir3.Jobs') IS NOT NULL AND OBJECT_ID(N'ir3.Jobs', N'U') IS NULL
        THROW 51011, 'ir3.Jobs exists but is not a table.', 1;
    IF OBJECT_ID(N'ir3.Jobs', N'U') IS NULL
    BEGIN
        EXEC sys.sp_executesql N'CREATE TABLE ir3.Jobs(
  Id uniqueidentifier NOT NULL PRIMARY KEY, Kind nvarchar(32) NOT NULL, FileId bigint NULL,
  State nvarchar(32) NOT NULL DEFAULT N''queued'', RequestedUtc datetime2(7) NOT NULL DEFAULT SYSUTCDATETIME(),
  RequestedBy nvarchar(256) NOT NULL, StartedUtc datetime2(7) NULL, FinishedUtc datetime2(7) NULL,
  Attempts int NOT NULL DEFAULT 0, Result nvarchar(2048) NULL,
  ProgressOffset bigint NOT NULL DEFAULT 0, GenerationId bigint NULL, TargetOffset bigint NULL);';
        PRINT N'Created ir3.Jobs';
    END;
    IF OBJECT_ID(N'ir3.Checks') IS NOT NULL AND OBJECT_ID(N'ir3.Checks', N'U') IS NULL
        THROW 51011, 'ir3.Checks exists but is not a table.', 1;
    IF OBJECT_ID(N'ir3.Checks', N'U') IS NULL
    BEGIN
        EXEC sys.sp_executesql N'CREATE TABLE ir3.Checks(
  Id uniqueidentifier NOT NULL PRIMARY KEY, Name nvarchar(128) NOT NULL, Url nvarchar(2048) NOT NULL,
  Enabled bit NOT NULL DEFAULT 1, ExpectedStatus int NOT NULL DEFAULT 200,
  ContainsText nvarchar(256) NULL, JsonKey nvarchar(128) NULL, JsonValue nvarchar(256) NULL,
  IntervalSeconds int NOT NULL DEFAULT 60, TimeoutSeconds int NOT NULL DEFAULT 10,
  MaxLatencyMs int NOT NULL DEFAULT 5000, FailAfter int NOT NULL DEFAULT 3, RecoverAfter int NOT NULL DEFAULT 2,
  BadCount int NOT NULL DEFAULT 0, GoodCount int NOT NULL DEFAULT 0,
  NextDueUtc datetime2(7) NOT NULL DEFAULT SYSUTCDATETIME(), LastCheckUtc datetime2(7) NULL,
  LastSuccess bit NULL, LastMessage nvarchar(512) NULL, MutedUntilUtc datetime2(7) NULL,
  Revision int NOT NULL DEFAULT 1,
  CONSTRAINT CK_ir3_CheckIntervals CHECK(IntervalSeconds BETWEEN 10 AND 86400 AND TimeoutSeconds BETWEEN 1 AND 30));';
        PRINT N'Created ir3.Checks';
    END;
    IF OBJECT_ID(N'ir3.CheckResults') IS NOT NULL AND OBJECT_ID(N'ir3.CheckResults', N'U') IS NULL
        THROW 51011, 'ir3.CheckResults exists but is not a table.', 1;
    IF OBJECT_ID(N'ir3.CheckResults', N'U') IS NULL
    BEGIN
        EXEC sys.sp_executesql N'CREATE TABLE ir3.CheckResults(
  Id bigint IDENTITY PRIMARY KEY, CheckId uniqueidentifier NOT NULL REFERENCES ir3.Checks(Id),
  StartedUtc datetime2(7) NOT NULL, FinishedUtc datetime2(7) NOT NULL,
  Success bit NOT NULL, HttpStatus int NULL, ElapsedMs bigint NOT NULL, Detail nvarchar(512) NOT NULL);';
        PRINT N'Created ir3.CheckResults';
    END;
    IF OBJECT_ID(N'ir3.AlertRules') IS NOT NULL AND OBJECT_ID(N'ir3.AlertRules', N'U') IS NULL
        THROW 51011, 'ir3.AlertRules exists but is not a table.', 1;
    IF OBJECT_ID(N'ir3.AlertRules', N'U') IS NULL
    BEGIN
        EXEC sys.sp_executesql N'CREATE TABLE ir3.AlertRules(
  Id uniqueidentifier NOT NULL PRIMARY KEY, Name nvarchar(128) NOT NULL, Metric nvarchar(32) NOT NULL,
  SiteId int NULL, Enabled bit NOT NULL DEFAULT 1, WindowMinutes int NOT NULL DEFAULT 5,
  Threshold float NOT NULL, MinSamples int NOT NULL DEFAULT 1,
  FailAfter int NOT NULL DEFAULT 1, RecoverAfter int NOT NULL DEFAULT 2,
  MutedUntilUtc datetime2(7) NULL, Revision int NOT NULL DEFAULT 1,
  CONSTRAINT CK_ir3_RuleWindow CHECK(WindowMinutes BETWEEN 1 AND 1440));';
        PRINT N'Created ir3.AlertRules';
    END;
    IF OBJECT_ID(N'ir3.AlertState') IS NOT NULL AND OBJECT_ID(N'ir3.AlertState', N'U') IS NULL
        THROW 51011, 'ir3.AlertState exists but is not a table.', 1;
    IF OBJECT_ID(N'ir3.AlertState', N'U') IS NULL
    BEGIN
        EXEC sys.sp_executesql N'CREATE TABLE ir3.AlertState(
  RuleId uniqueidentifier NOT NULL PRIMARY KEY REFERENCES ir3.AlertRules(Id),
  BadCount int NOT NULL DEFAULT 0, GoodCount int NOT NULL DEFAULT 0,
  NextDueUtc datetime2(7) NOT NULL DEFAULT SYSUTCDATETIME(),
  LastValue float NULL, LastSamples bigint NULL, LastEvaluatedUtc datetime2(7) NULL,
  LastMessage nvarchar(512) NULL);';
        PRINT N'Created ir3.AlertState';
    END;
    IF OBJECT_ID(N'ir3.Incidents') IS NOT NULL AND OBJECT_ID(N'ir3.Incidents', N'U') IS NULL
        THROW 51011, 'ir3.Incidents exists but is not a table.', 1;
    IF OBJECT_ID(N'ir3.Incidents', N'U') IS NULL
    BEGIN
        EXEC sys.sp_executesql N'CREATE TABLE ir3.Incidents(
  Id uniqueidentifier NOT NULL PRIMARY KEY, EntityKey nvarchar(160) NOT NULL,
  Title nvarchar(256) NOT NULL, State nvarchar(32) NOT NULL DEFAULT N''open'', Active bit NOT NULL DEFAULT 1,
  OpenedUtc datetime2(7) NOT NULL, UpdatedUtc datetime2(7) NOT NULL, ResolvedUtc datetime2(7) NULL,
  AcknowledgedBy nvarchar(256) NULL, Detail nvarchar(2048) NOT NULL);';
        PRINT N'Created ir3.Incidents';
    END;
    IF OBJECT_ID(N'ir3.IncidentEvents') IS NOT NULL AND OBJECT_ID(N'ir3.IncidentEvents', N'U') IS NULL
        THROW 51011, 'ir3.IncidentEvents exists but is not a table.', 1;
    IF OBJECT_ID(N'ir3.IncidentEvents', N'U') IS NULL
    BEGIN
        EXEC sys.sp_executesql N'CREATE TABLE ir3.IncidentEvents(
  Id uniqueidentifier NOT NULL PRIMARY KEY, IncidentId uniqueidentifier NOT NULL REFERENCES ir3.Incidents(Id),
  AtUtc datetime2(7) NOT NULL, Kind nvarchar(32) NOT NULL, Actor nvarchar(256) NOT NULL, Detail nvarchar(2048) NOT NULL);';
        PRINT N'Created ir3.IncidentEvents';
    END;
    IF OBJECT_ID(N'ir3.NotificationOutbox') IS NOT NULL AND OBJECT_ID(N'ir3.NotificationOutbox', N'U') IS NULL
        THROW 51011, 'ir3.NotificationOutbox exists but is not a table.', 1;
    IF OBJECT_ID(N'ir3.NotificationOutbox', N'U') IS NULL
    BEGIN
        EXEC sys.sp_executesql N'CREATE TABLE ir3.NotificationOutbox(
  Id uniqueidentifier NOT NULL PRIMARY KEY, IncidentId uniqueidentifier NULL,
  CreatedUtc datetime2(7) NOT NULL, Kind nvarchar(32) NOT NULL, Payload nvarchar(max) NOT NULL,
  State nvarchar(32) NOT NULL DEFAULT N''pending'', Attempts int NOT NULL DEFAULT 0,
  NextAttemptUtc datetime2(7) NOT NULL DEFAULT SYSUTCDATETIME(), SentUtc datetime2(7) NULL,
  LastError nvarchar(512) NULL, HttpStatus int NULL);';
        PRINT N'Created ir3.NotificationOutbox';
    END;
    IF OBJECT_ID(N'ir3.AuditEvents') IS NOT NULL AND OBJECT_ID(N'ir3.AuditEvents', N'U') IS NULL
        THROW 51011, 'ir3.AuditEvents exists but is not a table.', 1;
    IF OBJECT_ID(N'ir3.AuditEvents', N'U') IS NULL
    BEGIN
        EXEC sys.sp_executesql N'CREATE TABLE ir3.AuditEvents(
  Id bigint IDENTITY PRIMARY KEY, AtUtc datetime2(7) NOT NULL DEFAULT SYSUTCDATETIME(),
  Actor nvarchar(256) NOT NULL, Action nvarchar(64) NOT NULL, Target nvarchar(160) NOT NULL, Detail nvarchar(2048) NULL);';
        PRINT N'Created ir3.AuditEvents';
    END;

    /* Reject drift instead of adding indexes or grants to unrelated tables. */
    DECLARE @ExpectedColumns TABLE (TableName sysname NOT NULL, ColumnName sysname NOT NULL);
    INSERT @ExpectedColumns(TableName,ColumnName) VALUES
      (N'SchemaVersions', N'Version'),(N'SchemaVersions', N'AppliedUtc'),(N'Sources', N'Id'),(N'Sources', N'Name'),(N'Sources', N'SiteId'),(N'Sources', N'RootPath'),(N'Sources', N'Enabled'),(N'Sources', N'LastScanUtc'),(N'Sources', N'LastError'),(N'Files', N'Id'),(N'Files', N'SourceId'),(N'Files', N'PathKey'),(N'Files', N'FullPath'),(N'Files', N'ActiveGenerationId'),(N'Files', N'ObservedSize'),(N'Files', N'ObservedMtime'),(N'Files', N'LastSeenUtc'),(N'Files', N'Status'),(N'Files', N'LastError'),(N'Generations', N'Id'),(N'Generations', N'FileId'),(N'Generations', N'Number'),(N'Generations', N'CreatedUtc'),(N'Generations', N'Reason'),(N'Generations', N'CommittedOffset'),(N'Generations', N'LineNumber'),(N'Generations', N'Fields'),(N'Generations', N'LastImportUtc'),(N'Generations', N'LastVerifiedUtc'),(N'Generations', N'VerificationStatus'),(N'RawEvents', N'Id'),(N'RawEvents', N'GenerationId'),(N'RawEvents', N'ByteOffset'),(N'RawEvents', N'EndOffset'),(N'RawEvents', N'LineNumber'),(N'RawEvents', N'RawText'),(N'RawEvents', N'RawHash'),(N'RawEvents', N'ParseError'),(N'RawEvents', N'ParserVersion'),(N'RawEvents', N'ImportedUtc'),(N'Requests', N'Id'),(N'Requests', N'GenerationId'),(N'Requests', N'ByteOffset'),(N'Requests', N'RawEventId'),(N'Requests', N'Ts'),(N'Requests', N'SiteId'),(N'Requests', N'ServerIp'),(N'Requests', N'ServerPort'),(N'Requests', N'ClientIp'),(N'Requests', N'UserName'),(N'Requests', N'Method'),(N'Requests', N'UriStem'),(N'Requests', N'UriQuery'),(N'Requests', N'Status'),(N'Requests', N'SubStatus'),(N'Requests', N'Win32Status'),(N'Requests', N'TimeMs'),(N'Requests', N'UserAgent'),(N'Requests', N'Referer'),(N'Requests', N'LogFile'),(N'ImportChunks', N'GenerationId'),(N'ImportChunks', N'StartOffset'),(N'ImportChunks', N'EndOffset'),(N'ImportChunks', N'Sha256'),(N'ImportChunks', N'ImportedUtc'),(N'ImportRuns', N'Id'),(N'ImportRuns', N'StartedUtc'),(N'ImportRuns', N'FinishedUtc'),(N'ImportRuns', N'Kind'),(N'ImportRuns', N'FileId'),(N'ImportRuns', N'Status'),(N'ImportRuns', N'RowsProcessed'),(N'ImportRuns', N'Detail'),(N'AgentState', N'Id'),(N'AgentState', N'MachineName'),(N'AgentState', N'HeartbeatUtc'),(N'AgentState', N'LastScanUtc'),(N'AgentState', N'LastSuccessfulScanUtc'),(N'AgentState', N'State'),(N'AgentState', N'LastError'),(N'AgentState', N'Version'),(N'Jobs', N'Id'),(N'Jobs', N'Kind'),(N'Jobs', N'FileId'),(N'Jobs', N'State'),(N'Jobs', N'RequestedUtc'),(N'Jobs', N'RequestedBy'),(N'Jobs', N'StartedUtc'),(N'Jobs', N'FinishedUtc'),(N'Jobs', N'Attempts'),(N'Jobs', N'Result'),(N'Jobs', N'ProgressOffset'),(N'Jobs', N'GenerationId'),(N'Jobs', N'TargetOffset'),(N'Checks', N'Id'),(N'Checks', N'Name'),(N'Checks', N'Url'),(N'Checks', N'Enabled'),(N'Checks', N'ExpectedStatus'),(N'Checks', N'ContainsText'),(N'Checks', N'JsonKey'),(N'Checks', N'JsonValue'),(N'Checks', N'IntervalSeconds'),(N'Checks', N'TimeoutSeconds'),(N'Checks', N'MaxLatencyMs'),(N'Checks', N'FailAfter'),(N'Checks', N'RecoverAfter'),(N'Checks', N'BadCount'),(N'Checks', N'GoodCount'),(N'Checks', N'NextDueUtc'),(N'Checks', N'LastCheckUtc'),(N'Checks', N'LastSuccess'),(N'Checks', N'LastMessage'),(N'Checks', N'MutedUntilUtc'),(N'Checks', N'Revision'),(N'CheckResults', N'Id'),(N'CheckResults', N'CheckId'),(N'CheckResults', N'StartedUtc'),(N'CheckResults', N'FinishedUtc'),(N'CheckResults', N'Success'),(N'CheckResults', N'HttpStatus'),(N'CheckResults', N'ElapsedMs'),(N'CheckResults', N'Detail'),(N'AlertRules', N'Id'),(N'AlertRules', N'Name'),(N'AlertRules', N'Metric'),(N'AlertRules', N'SiteId'),(N'AlertRules', N'Enabled'),(N'AlertRules', N'WindowMinutes'),(N'AlertRules', N'Threshold'),(N'AlertRules', N'MinSamples'),(N'AlertRules', N'FailAfter'),(N'AlertRules', N'RecoverAfter'),(N'AlertRules', N'MutedUntilUtc'),(N'AlertRules', N'Revision'),(N'AlertState', N'RuleId'),(N'AlertState', N'BadCount'),(N'AlertState', N'GoodCount'),(N'AlertState', N'NextDueUtc'),(N'AlertState', N'LastValue'),(N'AlertState', N'LastSamples'),(N'AlertState', N'LastEvaluatedUtc'),(N'AlertState', N'LastMessage'),(N'Incidents', N'Id'),(N'Incidents', N'EntityKey'),(N'Incidents', N'Title'),(N'Incidents', N'State'),(N'Incidents', N'Active'),(N'Incidents', N'OpenedUtc'),(N'Incidents', N'UpdatedUtc'),(N'Incidents', N'ResolvedUtc'),(N'Incidents', N'AcknowledgedBy'),(N'Incidents', N'Detail'),(N'IncidentEvents', N'Id'),(N'IncidentEvents', N'IncidentId'),(N'IncidentEvents', N'AtUtc'),(N'IncidentEvents', N'Kind'),(N'IncidentEvents', N'Actor'),(N'IncidentEvents', N'Detail'),(N'NotificationOutbox', N'Id'),(N'NotificationOutbox', N'IncidentId'),(N'NotificationOutbox', N'CreatedUtc'),(N'NotificationOutbox', N'Kind'),(N'NotificationOutbox', N'Payload'),(N'NotificationOutbox', N'State'),(N'NotificationOutbox', N'Attempts'),(N'NotificationOutbox', N'NextAttemptUtc'),(N'NotificationOutbox', N'SentUtc'),(N'NotificationOutbox', N'LastError'),(N'NotificationOutbox', N'HttpStatus'),(N'AuditEvents', N'Id'),(N'AuditEvents', N'AtUtc'),(N'AuditEvents', N'Actor'),(N'AuditEvents', N'Action'),(N'AuditEvents', N'Target'),(N'AuditEvents', N'Detail');
    DECLARE @MissingColumn nvarchar(512);
    SELECT TOP (1) @MissingColumn = N'ir3.' + e.TableName + N'.' + e.ColumnName
      FROM @ExpectedColumns e
      LEFT JOIN sys.tables t ON t.name=e.TableName AND t.schema_id=SCHEMA_ID(N'ir3')
      LEFT JOIN sys.columns c ON c.object_id=t.object_id AND c.name=e.ColumnName
     WHERE t.object_id IS NULL OR c.column_id IS NULL
     ORDER BY e.TableName,e.ColumnName;
    IF @MissingColumn IS NOT NULL
    BEGIN
      DECLARE @DriftError nvarchar(1500) = N'Existing ir3 schema is incomplete: ' + @MissingColumn +
           N'. Stop; inspect schema before retrying. No data was deleted.';
      THROW 51012, @DriftError, 1;
    END;

    /* Indexes are compiled only after their tables exist. */
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'ir3.Requests', N'U') AND name=N'IX_ir3_Requests_Ts')
        EXEC sys.sp_executesql N'CREATE INDEX IX_ir3_Requests_Ts ON ir3.Requests(Ts) INCLUDE(SiteId,Status,TimeMs);';
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'ir3.Requests', N'U') AND name=N'IX_ir3_Requests_SiteTs')
        EXEC sys.sp_executesql N'CREATE INDEX IX_ir3_Requests_SiteTs ON ir3.Requests(SiteId,Ts) INCLUDE(Status,TimeMs);';
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'ir3.Requests', N'U') AND name=N'IX_ir3_Requests_Client')
        EXEC sys.sp_executesql N'CREATE INDEX IX_ir3_Requests_Client ON ir3.Requests(ClientIp,Ts);';
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'ir3.Requests', N'U') AND name=N'IX_ir3_Requests_Status')
        EXEC sys.sp_executesql N'CREATE INDEX IX_ir3_Requests_Status ON ir3.Requests(Status,Ts);';
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'ir3.Jobs', N'U') AND name=N'IX_ir3_Jobs_State')
        EXEC sys.sp_executesql N'CREATE INDEX IX_ir3_Jobs_State ON ir3.Jobs(State,RequestedUtc);';
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'ir3.CheckResults', N'U') AND name=N'IX_ir3_CheckResults_Time')
        EXEC sys.sp_executesql N'CREATE INDEX IX_ir3_CheckResults_Time ON ir3.CheckResults(CheckId,StartedUtc DESC);';
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'ir3.Incidents', N'U') AND name=N'UX_ir3_IncidentActive')
        EXEC sys.sp_executesql N'CREATE UNIQUE INDEX UX_ir3_IncidentActive ON ir3.Incidents(EntityKey) WHERE Active=1;';
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'ir3.NotificationOutbox', N'U') AND name=N'IX_ir3_Outbox_Due')
        EXEC sys.sp_executesql N'CREATE INDEX IX_ir3_Outbox_Due ON ir3.NotificationOutbox(State,NextAttemptUtc);';

    /* CREATE VIEW and ALTER VIEW must run in their own child batches. */
    IF OBJECT_ID(N'ir3.CurrentRequests') IS NOT NULL AND OBJECT_ID(N'ir3.CurrentRequests',N'V') IS NULL
        THROW 51013, 'ir3.CurrentRequests exists but is not a view.', 1;
    IF OBJECT_ID(N'ir3.CurrentRequests',N'V') IS NULL
        EXEC sys.sp_executesql N'CREATE VIEW ir3.CurrentRequests AS SELECT r.* FROM ir3.Requests r JOIN ir3.Generations g ON g.Id=r.GenerationId JOIN ir3.Files f ON f.Id=g.FileId AND f.ActiveGenerationId=g.Id;';
    ELSE
        EXEC sys.sp_executesql N'ALTER VIEW ir3.CurrentRequests AS SELECT r.* FROM ir3.Requests r JOIN ir3.Generations g ON g.Id=r.GenerationId JOIN ir3.Files f ON f.Id=g.FileId AND f.ActiveGenerationId=g.Id;';

    /* No hardcoded log sources. Register actual sources after installation.
       Existing source registrations are never removed by this installer. */

    IF DATABASE_PRINCIPAL_ID(N'ir3_web') IS NULL
        EXEC sys.sp_executesql N'CREATE ROLE ir3_web AUTHORIZATION dbo;';
    IF DATABASE_PRINCIPAL_ID(N'ir3_agent') IS NULL
        EXEC sys.sp_executesql N'CREATE ROLE ir3_agent AUTHORIZATION dbo;';
    IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name IN (N'ir3_web', N'ir3_agent') AND type <> 'R')
        THROW 51015, 'ir3_web or ir3_agent is not a database role.', 1;
    IF DATABASE_PRINCIPAL_ID(N'ir3_web') IS NULL OR DATABASE_PRINCIPAL_ID(N'ir3_agent') IS NULL
        THROW 51014, 'Database roles could not be created.', 1;

    EXEC sys.sp_executesql N'GRANT SELECT ON SCHEMA::ir3 TO ir3_web;';
    EXEC sys.sp_executesql N'GRANT INSERT,UPDATE ON ir3.Jobs TO ir3_web;';
    EXEC sys.sp_executesql N'GRANT INSERT,UPDATE ON ir3.Checks TO ir3_web;';
    EXEC sys.sp_executesql N'GRANT INSERT,UPDATE ON ir3.AlertRules TO ir3_web;';
    EXEC sys.sp_executesql N'GRANT INSERT,UPDATE ON ir3.AlertState TO ir3_web;';
    EXEC sys.sp_executesql N'GRANT UPDATE ON ir3.Incidents TO ir3_web;';
    EXEC sys.sp_executesql N'GRANT INSERT ON ir3.IncidentEvents TO ir3_web;';
    EXEC sys.sp_executesql N'GRANT INSERT,UPDATE ON ir3.NotificationOutbox TO ir3_web;';
    EXEC sys.sp_executesql N'GRANT INSERT ON ir3.AuditEvents TO ir3_web;';
    EXEC sys.sp_executesql N'GRANT SELECT,INSERT,UPDATE,DELETE ON SCHEMA::ir3 TO ir3_agent;';

    /* Version is recorded only after all prior steps succeed. */
    EXEC sys.sp_executesql N'IF NOT EXISTS (SELECT 1 FROM ir3.SchemaVersions WHERE Version=300) INSERT ir3.SchemaVersions(Version) VALUES(300);';
    COMMIT TRANSACTION;
    PRINT N'OK: ir3 version 300 ready; no dbo tables were changed.';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    PRINT N'FAILED: the ir3 installation has been rolled back. Original error follows:';
    THROW;
END CATCH;
