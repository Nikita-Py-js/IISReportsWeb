/* IIS Reports 3.1.0: additive migration, schema version 310.
   Run AFTER 001-v3-schema.sql in the same dedicated database, as DBA.
   Existing requests, raw events, offsets and Enabled choices are not changed. */
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF OBJECT_ID(N'ir3.Sources',N'U') IS NULL OR OBJECT_ID(N'ir3.SchemaVersions',N'U') IS NULL
    THROW 51030,'Run 001-v3-schema.sql in your IISReports database first.',1;
BEGIN TRY
 BEGIN TRANSACTION;
 DECLARE @lock int;
 EXEC @lock=sys.sp_getapplock @Resource=N'IISReports.schema',@LockMode='Exclusive',@LockOwner='Transaction',@LockTimeout=15000;
 IF @lock<0 THROW 51031,'Another schema migration is running.',1;
 IF COL_LENGTH(N'ir3.Sources',N'Revision') IS NULL
   EXEC(N'ALTER TABLE ir3.Sources ADD Revision int NOT NULL CONSTRAINT DF_ir3_Sources_Revision DEFAULT(1) WITH VALUES;');
 IF COL_LENGTH(N'ir3.Sources',N'AutoDiscovered') IS NULL
   EXEC(N'ALTER TABLE ir3.Sources ADD AutoDiscovered bit NOT NULL CONSTRAINT DF_ir3_Sources_Auto DEFAULT(0) WITH VALUES;');
 IF COL_LENGTH(N'ir3.Sources',N'Available') IS NULL
   EXEC(N'ALTER TABLE ir3.Sources ADD Available bit NOT NULL CONSTRAINT DF_ir3_Sources_Available DEFAULT(1) WITH VALUES;');
 IF COL_LENGTH(N'ir3.Sources',N'DiscoveryKey') IS NULL
   EXEC(N'ALTER TABLE ir3.Sources ADD DiscoveryKey binary(32) NULL;');
 IF COL_LENGTH(N'ir3.Sources',N'IisName') IS NULL
   EXEC(N'ALTER TABLE ir3.Sources ADD IisName nvarchar(256) NULL;');
 IF COL_LENGTH(N'ir3.Sources',N'DiscoveryStatus') IS NULL
   EXEC(N'ALTER TABLE ir3.Sources ADD DiscoveryStatus nvarchar(40) NULL;');
 IF COL_LENGTH(N'ir3.Sources',N'DiscoveryMessage') IS NULL
   EXEC(N'ALTER TABLE ir3.Sources ADD DiscoveryMessage nvarchar(1024) NULL;');
 IF COL_LENGTH(N'ir3.Sources',N'LastDiscoveredUtc') IS NULL
   EXEC(N'ALTER TABLE ir3.Sources ADD LastDiscoveredUtc datetime2(7) NULL;');
 IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'ir3.Sources') AND name=N'UX_ir3_SourceDiscoveryKey')
   EXEC(N'CREATE UNIQUE INDEX UX_ir3_SourceDiscoveryKey ON ir3.Sources(DiscoveryKey) WHERE DiscoveryKey IS NOT NULL;');
 IF OBJECT_ID(N'ir3.DiscoveryState',N'U') IS NULL
   EXEC(N'CREATE TABLE ir3.DiscoveryState(
    Id int NOT NULL PRIMARY KEY CONSTRAINT CK_ir3_DiscoveryState_One CHECK(Id=1),
    MachineName nvarchar(128) NULL, State nvarchar(32) NOT NULL DEFAULT(''waiting''),
    LastAttemptUtc datetime2(7) NULL, LastSuccessUtc datetime2(7) NULL, SnapshotUtc datetime2(7) NULL,
    LastError nvarchar(1024) NULL, SitesFound int NOT NULL DEFAULT(0), SourcesAdded int NOT NULL DEFAULT(0));');
 EXEC(N'GRANT UPDATE (Enabled,Revision) ON OBJECT::ir3.Sources TO ir3_web;');
 -- Other permissions are inherited from the existing schema-level grants in 001.
 EXEC(N'IF NOT EXISTS(SELECT 1 FROM ir3.SchemaVersions WHERE Version=310) INSERT ir3.SchemaVersions(Version) VALUES(310);');
 COMMIT;
 PRINT N'OK: schema 310 ready. Automatic source discovery and web monitoring switches enabled; history retained.';
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK;
 THROW;
END CATCH;
