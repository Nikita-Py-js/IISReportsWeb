/* LOCAL SQL SERVER ONLY. Run after 001 as DBA.
   Change the pool/service names to the actual accounts. Create the service first.
   For remote SQL use separate SQL logins or properly provisioned domain identities;
   a local virtual account name is not a remote Windows principal. */
USE [master];
GO
IF SUSER_ID(N'IIS APPPOOL\IISReportsV3') IS NULL
 CREATE LOGIN [IIS APPPOOL\IISReportsV3] FROM WINDOWS;
IF SUSER_ID(N'NT SERVICE\IISReportsAgentV3') IS NULL
 CREATE LOGIN [NT SERVICE\IISReportsAgentV3] FROM WINDOWS;
GO
USE [IISReports]; -- Change if your database name differs.
GO
IF USER_ID(N'IIS APPPOOL\IISReportsV3') IS NULL
 CREATE USER [IIS APPPOOL\IISReportsV3] FOR LOGIN [IIS APPPOOL\IISReportsV3];
IF USER_ID(N'NT SERVICE\IISReportsAgentV3') IS NULL
 CREATE USER [NT SERVICE\IISReportsAgentV3] FOR LOGIN [NT SERVICE\IISReportsAgentV3];
IF IS_ROLEMEMBER(N'ir3_web',N'IIS APPPOOL\IISReportsV3')<>1
 ALTER ROLE ir3_web ADD MEMBER [IIS APPPOOL\IISReportsV3];
IF IS_ROLEMEMBER(N'ir3_agent',N'NT SERVICE\IISReportsAgentV3')<>1
 ALTER ROLE ir3_agent ADD MEMBER [NT SERVICE\IISReportsAgentV3];
GO
/* This script does not remove older permissions. Review any existing db_owner,
   db_datawriter, ALTER/CREATE TABLE grants inherited from previous versions. */
