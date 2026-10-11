# Explicit source registration: no assumption that W3SVC1/2/3 exist on a clean server.
[CmdletBinding(SupportsShouldProcess=$true)]
param(
 [Parameter(Mandatory=$true)][string]$SqlServer,
 [string]$Database='IISReports',
 [System.Management.Automation.PSCredential]$AdminCredential,
 [switch]$TrustServerCertificate,
 [Parameter(Mandatory=$true)][ValidateRange(1,2147483647)][int]$SiteId,
 [Parameter(Mandatory=$true)][ValidateLength(1,128)][string]$Name,
 [Parameter(Mandatory=$true)][string]$RootPath
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Setup.Common.ps1"
$path=[IO.Path]::GetFullPath($RootPath).TrimEnd('\')
if($path.Length -gt 1024) { throw 'RootPath exceeds the database column size.' }
if(-not(Test-Path -LiteralPath $path -PathType Container)) { throw 'Log directory does not exist. Enable W3C logging or supply the correct path on the agent machine.' }
$c=Open-SetupDatabase -SqlServer $SqlServer -Database $Database -Credential $AdminCredential -TrustServerCertificate ([bool]$TrustServerCertificate)
try {
    $cmd=$c.CreateCommand();$cmd.CommandText='SELECT SiteId,RootPath FROM ir3.Sources'
    $r=$cmd.ExecuteReader()
    try {
        while($r.Read()) {
            $existing=$r.GetString(1).TrimEnd('\');$existingId=$r.GetInt32(0)
            if($existing -ieq $path) {
                if($existingId -ne $SiteId){throw 'This log directory is already registered for a different SiteId.'}
            } elseif(($existing+'\').StartsWith($path+'\',[StringComparison]::OrdinalIgnoreCase) -or
                     ($path+'\').StartsWith($existing+'\',[StringComparison]::OrdinalIgnoreCase)) {
                throw 'Overlapping source roots would import the same files more than once. Use disjoint roots.'
            }
        }
    } finally {$r.Dispose();$cmd.Dispose()}
    if(-not $PSCmdlet.ShouldProcess("$Database / $path",'Register source (or update its display name); preserve checkpoints')){return}
    $sql=@'
SET XACT_ABORT ON;
BEGIN TRY
 BEGIN TRANSACTION;
 IF EXISTS(SELECT 1 FROM ir3.Sources WITH(UPDLOCK,HOLDLOCK) WHERE SiteId=@site AND RootPath=@path)
  UPDATE ir3.Sources SET Name=@name WHERE SiteId=@site AND RootPath=@path;
 ELSE INSERT ir3.Sources(Name,SiteId,RootPath) VALUES(@name,@site,@path);
 COMMIT;
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK;
 THROW;
END CATCH;
'@
    Invoke-SetupSql $c $sql @{'@site'=$SiteId;'@name'=$Name;'@path'=$path}
    Write-Host "Registered site $SiteId ($Name): $path"
    Write-Host 'Grant the Windows agent read/execute on this directory. No IIS logging settings or existing history were changed.'
} finally {$c.Dispose()}
