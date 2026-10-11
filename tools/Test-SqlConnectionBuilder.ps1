# Regression test for the installer SQL connection-string builder. Does not connect to SQL.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Setup.Common.ps1"

function Assert-SetupValue([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
}

$server = 'localhost\SQLEXPRESS'
$database = 'IISReports'
$cs = New-SqlConnectionString -SqlServer $server -Database $database -TrustServerCertificate $false
$parsed = New-Object System.Data.SqlClient.SqlConnectionStringBuilder -ArgumentList $cs
Assert-SetupValue ($parsed['Data Source'] -eq $server) 'Data Source keyword'
Assert-SetupValue ($parsed['Initial Catalog'] -eq $database) 'Initial Catalog keyword'
Assert-SetupValue ([bool]$parsed['Integrated Security']) 'Windows authentication'
Assert-SetupValue ([bool]$parsed['Encrypt']) 'Encryption enabled'
Assert-SetupValue (-not [bool]$parsed['TrustServerCertificate']) 'Certificate verification enabled'
Assert-SetupValue ($cs -notmatch '(?i)(?:^|;)\s*DataSource\s*=') 'Unsupported DataSource keyword absent'
Write-Host 'PASS SQL connection string (Windows authentication; trusted TLS)'

# Use a synthetic password containing characters that require correct connection-string escaping.
# This never opens a connection and does not log the password or connection string.
$secure = ConvertTo-SecureString -String 'unit;pass=word' -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential -ArgumentList 'iisreports_test',$secure
$cs = New-SqlConnectionString -SqlServer $server -Database $database -Credential $cred -TrustServerCertificate $true -Application 'IISReports.Setup.Test'
$parsed = New-Object System.Data.SqlClient.SqlConnectionStringBuilder -ArgumentList $cs
Assert-SetupValue (-not [bool]$parsed['Integrated Security']) 'SQL authentication selected'
Assert-SetupValue ($parsed['User ID'] -eq 'iisreports_test') 'SQL user ID'
Assert-SetupValue ($parsed['Password'] -eq 'unit;pass=word') 'SQL password serialized safely'
Assert-SetupValue ([bool]$parsed['Encrypt']) 'Encryption retained with TrustServerCertificate'
Assert-SetupValue ([bool]$parsed['TrustServerCertificate']) 'Explicit certificate trust switch'
Assert-SetupValue ($parsed['Application Name'] -eq 'IISReports.Setup.Test') 'Application name'
Write-Host 'PASS SQL connection string (SQL authentication; explicit test certificate trust)'
Write-Host 'PASS TOTAL 2. No network or database commands were executed.'
