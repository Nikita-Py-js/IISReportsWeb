SET NOCOUNT ON;
IF OBJECT_ID(N'ir3.DiscoveryState',N'U') IS NULL
 THROW 51032,'Automatic discovery schema missing. Run 005-auto-sources.sql.',1;
IF COL_LENGTH(N'ir3.Sources',N'Revision') IS NULL OR COL_LENGTH(N'ir3.Sources',N'DiscoveryKey') IS NULL
 THROW 51033,'Source selection columns missing.',1;
IF NOT EXISTS(SELECT 1 FROM ir3.SchemaVersions WHERE Version=310)
 THROW 51034,'Expected schema version 310.',1;
SELECT MAX(Version) AS SchemaVersion FROM ir3.SchemaVersions;
SELECT Id,Name,SiteId,Enabled,Revision,AutoDiscovered,Available,DiscoveryStatus,LastDiscoveredUtc,LastError FROM ir3.Sources ORDER BY SiteId,Id;
SELECT * FROM ir3.DiscoveryState;
PRINT 'OK: automatic source discovery schema is present. An empty Sources table is normal before the first agent sync.';
