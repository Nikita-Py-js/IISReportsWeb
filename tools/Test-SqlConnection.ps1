#requires -Version 5.1
# Read-only connectivity probe. No CREATE/ALTER/INSERT/UPDATE/DELETE is performed.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$SqlServer,
    [string]$Database='master',
    [System.Management.Automation.PSCredential]$AdminCredential,
    [switch]$TrustServerCertificate
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Setup.Common.ps1"
if ($SqlServer -ne $SqlServer.Trim() -or $SqlServer -match '[\r\n\x00]') {
    throw 'SqlServer contains leading/trailing whitespace or a control character.'
}
if ($SqlServer -match '://|;|=') {
    throw 'SqlServer must be an instance name/address, not a URL or a whole connection string.'
}
# JSON/C# escaping must not be copied into a normal PowerShell instance name.
if (-not $SqlServer.StartsWith('np:',[StringComparison]::OrdinalIgnoreCase) -and
    -not $SqlServer.StartsWith('\\') -and $SqlServer.Contains('\\')) {
    throw 'A PowerShell server\instance string needs ONE backslash. Do not copy JSON double escaping.'
}
$auth = if ($null -eq $AdminCredential) { 'Windows' } else { 'SQL login' }
Write-Host ('Testing one endpoint: [{0}]; database=[{1}]; auth={2}; Encrypt=True; TrustServerCertificate={3}' -f
    $SqlServer,$Database,$auth,[bool]$TrustServerCertificate)
$c=$null
$cmd=$null
$reader=$null
try {
    $c=Open-SetupDatabase -SqlServer $SqlServer -Database $Database -Credential $AdminCredential -TrustServerCertificate ([bool]$TrustServerCertificate)
    $cmd=$c.CreateCommand()
    $cmd.CommandTimeout=15
    $cmd.CommandText=@'
SELECT CONVERT(nvarchar(128), SERVERPROPERTY('ServerName')) AS ServerName,
       CONVERT(nvarchar(128), SERVERPROPERTY('InstanceName')) AS InstanceName,
       DB_NAME() AS DatabaseName,
       ORIGINAL_LOGIN() AS LoginName;
'@
    $reader=$cmd.ExecuteReader()
    if (-not $reader.Read()) { throw 'SQL connected but the identity query returned no row.' }
    $result=[pscustomobject]@{
        RequestedServer=$SqlServer
        ServerName=if($reader.IsDBNull(0)){$null}else{$reader.GetString(0)}
        InstanceName=if($reader.IsDBNull(1)){'(default)'}else{$reader.GetString(1)}
        DatabaseName=$reader.GetString(2)
        LoginName=$reader.GetString(3)
    }
    Write-Host 'PASS SQL Open and read-only instance query. No database or schema was created.'
    $result
} catch {
    Write-Warning 'SQL connection test failed. Do not continue provisioning. Check the exact endpoint and the first exception below. No fallback instance was tried.'
    throw
} finally {
    if($null -ne $reader){$reader.Dispose()}
    if($null -ne $cmd){$cmd.Dispose()}
    if($null -ne $c){$c.Dispose()}
}
