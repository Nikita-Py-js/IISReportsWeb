# Provision using built-in System.Data.SqlClient; SSMS/sqlcmd are optional.
[CmdletBinding(SupportsShouldProcess=$true)]
param(
 [Parameter(Mandatory=$true)][string]$SqlServer,
 [string]$Database='IISReports',
 [System.Management.Automation.PSCredential]$AdminCredential,
 [switch]$CreateDatabase,
 [switch]$TrustServerCertificate,
 [switch]$VerifyOnly
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Setup.Common.ps1"
if($Database -notmatch '^[A-Za-z][A-Za-z0-9_]{0,63}$' -or $Database -in @('master','model','msdb','tempdb')) {
    throw 'Choose a dedicated database name (letters, digits, underscore; max 64), not a system database.'
}
$root=Split-Path $PSScriptRoot -Parent
$sqlArgs=@{SqlServer=$SqlServer;Credential=$AdminCredential;TrustServerCertificate=[bool]$TrustServerCertificate}
$c=Open-SetupDatabase @sqlArgs -Database master
try {
    $exists=Invoke-SetupSql -Connection $c -Sql 'SELECT DB_ID(@db)' -Parameters @{'@db'=$Database} -Scalar
    if($exists -is [DBNull] -or $null -eq $exists) {
        if($VerifyOnly -or -not $CreateDatabase) { throw 'Database does not exist. Use -CreateDatabase for an intentional clean install.' }
        if(-not $PSCmdlet.ShouldProcess("$SqlServer/$Database",'Create a dedicated database')) { return }
        Invoke-SetupSql -Connection $c -Sql ("CREATE DATABASE ["+$Database+"];")
    }
} finally { $c.Dispose() }
$c=Open-SetupDatabase @sqlArgs -Database $Database
try {
    if(-not $VerifyOnly) {
        if(-not $PSCmdlet.ShouldProcess("$SqlServer/$Database",'Apply idempotent ir3 schema; preserve existing data')) { return }
        Invoke-SqlFile -Connection $c -Path "$root\sql\001-v3-schema.sql"
    }
    Invoke-SqlFile -Connection $c -Path "$root\sql\003-v3-verify.sql" -ShowRows
    Invoke-SqlFile -Connection $c -Path "$root\sql\004-v3-defaults-audit.sql" -ShowRows
    Write-Host 'Schema verification completed. Review default-constraint audit: all four rows must say OK.'
} finally { $c.Dispose() }
