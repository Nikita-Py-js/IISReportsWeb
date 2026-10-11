# Grant existing ir3 roles. No db_owner/sysadmin; no existing permissions are revoked.
[CmdletBinding(DefaultParameterSetName='LocalWindows',SupportsShouldProcess=$true)]
param(
 [Parameter(Mandatory=$true)][string]$SqlServer,
 [string]$Database='IISReports',
 [System.Management.Automation.PSCredential]$AdminCredential,
 [switch]$TrustServerCertificate,
 [Parameter(Mandatory=$true,ParameterSetName='LocalWindows')][switch]$LocalWindows,
 [Parameter(ParameterSetName='LocalWindows')][string]$AppPoolName='IISReportsV3',
 [Parameter(ParameterSetName='LocalWindows')][string]$ServiceName='IISReportsAgentV3',
 [Parameter(Mandatory=$true,ParameterSetName='SqlLogins')][System.Management.Automation.PSCredential]$WebCredential,
 [Parameter(Mandatory=$true,ParameterSetName='SqlLogins')][System.Management.Automation.PSCredential]$AgentCredential
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Setup.Common.ps1"
$argsSql=@{SqlServer=$SqlServer;Credential=$AdminCredential;TrustServerCertificate=[bool]$TrustServerCertificate}
$c=Open-SetupDatabase @argsSql -Database master
try {
    if($LocalWindows) {
        $machine=[string](Invoke-SetupSql $c "SELECT CONVERT(nvarchar(128),SERVERPROPERTY('MachineName'))" -Scalar)
        if($machine -ine $env:COMPUTERNAME) { throw 'LocalWindows is only for SQL running on this same Windows machine; use separate SQL logins or DBA-provisioned domain accounts for remote SQL.' }
        $accounts=@(('IIS APPPOOL\'+$AppPoolName),('NT SERVICE\'+$ServiceName))
        foreach($account in $accounts) {
            try {$null=(New-Object Security.Principal.NTAccount($account)).Translate([Security.Principal.SecurityIdentifier])}
            catch {throw "Account does not resolve: $account. Create the IIS pool and install the service first."}
        }
    } else {
        $accounts=@($WebCredential.UserName,$AgentCredential.UserName)
        if($accounts[0] -ieq $accounts[1]) { throw 'Web and agent must use distinct SQL logins.' }
    }
    for($i=0;$i -lt 2;$i++) {
        $name=[string]$accounts[$i]
        if($name.Length -gt 128 -or $name -in @('sa','dbo') -or [string]::IsNullOrWhiteSpace($name)) { throw 'Invalid application login name.' }
        if(-not $PSCmdlet.ShouldProcess("$SqlServer/$name",'Create login if absent and grant ir3 role')) { continue }
        if($LocalWindows) {
            $sql=@'
IF SUSER_ID(@name) IS NULL BEGIN
 DECLARE @sql nvarchar(max)=N'CREATE LOGIN '+QUOTENAME(@name)+N' FROM WINDOWS;';
 EXEC sys.sp_executesql @sql;
END;
IF NOT EXISTS(SELECT 1 FROM sys.server_principals WHERE name=@name AND type IN ('U','G'))
 THROW 51100,'Existing login is not a Windows login.',1;
'@
            Invoke-SetupSql $c $sql @{'@name'=$name}
        } else {
            $cred=if($i -eq 0){$WebCredential}else{$AgentCredential}
            $sql=@'
IF SUSER_ID(@name) IS NULL BEGIN
 DECLARE @sql nvarchar(max)=N'CREATE LOGIN '+QUOTENAME(@name)+N' WITH PASSWORD='+QUOTENAME(@password,'''')+N', CHECK_POLICY=ON;';
 IF @sql IS NULL THROW 51101,'Password must have 1 to 128 characters.',1;
 EXEC sys.sp_executesql @sql;
END;
IF NOT EXISTS(SELECT 1 FROM sys.server_principals WHERE name=@name AND type='S')
 THROW 51102,'Existing login is not a SQL login.',1;
'@
            Invoke-SetupSql $c $sql @{'@name'=$name;'@password'=$cred.GetNetworkCredential().Password}
        }
        $db=Open-SetupDatabase @argsSql -Database $Database
        try {
            $role=if($i -eq 0){'ir3_web'}else{'ir3_agent'}
            $sql=@'
SET XACT_ABORT ON;
BEGIN TRY
 BEGIN TRANSACTION;
 IF DATABASE_PRINCIPAL_ID(@role) IS NULL THROW 51103,'Install ir3 schema first.',1;
 DECLARE @sql nvarchar(max);
 IF USER_ID(@name) IS NULL BEGIN
  SET @sql=N'CREATE USER '+QUOTENAME(@name)+N' FOR LOGIN '+QUOTENAME(@name)+N';';
  EXEC sys.sp_executesql @sql;
 END;
 IF NOT EXISTS(SELECT 1 FROM sys.database_principals WHERE name=@name AND sid=SUSER_SID(@name))
  THROW 51104,'Existing database user SID does not match the login; ask DBA to repair mapping.',1;
 SET @sql=N'GRANT CONNECT TO '+QUOTENAME(@name)+N';'; EXEC sys.sp_executesql @sql;
 IF IS_ROLEMEMBER(@role,@name)<>1 BEGIN
  SET @sql=N'ALTER ROLE '+QUOTENAME(@role)+N' ADD MEMBER '+QUOTENAME(@name)+N';';
  EXEC sys.sp_executesql @sql;
 END;
 COMMIT;
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK;
 THROW;
END CATCH;
'@
            Invoke-SetupSql $db $sql @{'@name'=$name;'@role'=$role}
            Write-Host "Granted $role to $name in $Database."
        } finally {$db.Dispose()}
    }
} finally {$c.Dispose()}
Write-Host 'Existing passwords are not reset. Existing broad privileges, if any, are not removed.'
