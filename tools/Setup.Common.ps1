# Shared setup helpers. Dot-source this file; no changes are made on import.
Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.Data
function Assert-Administrator {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Use elevated Windows PowerShell 5.1 (Run as administrator).'
    }
}
function Get-CanonicalOrigin([string]$PublicUrl) {
    $u = $null
    if (-not [Uri]::TryCreate($PublicUrl,[UriKind]::Absolute,[ref]$u) -or
        $u.Scheme -notin @('http','https') -or $u.UserInfo -or $u.Query -or $u.Fragment -or -not $u.Host) {
        throw 'PublicUrl must be an absolute HTTP(S) address without credentials, query or fragment.'
    }
    return $u.GetLeftPart([UriPartial]::Authority).ToLowerInvariant()
}
function Set-XmlSetting([xml]$Document,[string]$Key,[string]$Value) {
    $settings = $Document.SelectSingleNode('/configuration/appSettings')
    if ($null -eq $settings) { throw 'appSettings is missing in the configuration template.' }
    $node = $settings.SelectSingleNode("add[@key='$Key']")
    if ($null -eq $node) {
        $node = $Document.CreateElement('add'); $node.SetAttribute('key',$Key)
        [void]$settings.AppendChild($node)
    }
    $node.SetAttribute('value',$Value)
}
function New-RestrictedDirectory([string]$Directory) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($Directory))
    & icacls.exe $Directory /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)(F)' '*S-1-5-18:(OI)(CI)(F)' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not restrict NTFS permissions: $Directory" }
}
function Save-NewXml([xml]$Document,[string]$Destination) {
    $full = [IO.Path]::GetFullPath($Destination)
    if (Test-Path -LiteralPath $full) { throw "File exists, not overwritten: $full" }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))
    $settings = New-Object Xml.XmlWriterSettings
    $settings.Indent = $true; $settings.Encoding = New-Object Text.UTF8Encoding($true)
    $writer = [Xml.XmlWriter]::Create($full,$settings)
    try { $Document.Save($writer) } finally { $writer.Dispose() }
}
function New-SqlConnectionString {
    param([string]$SqlServer,[string]$Database,[System.Management.Automation.PSCredential]$Credential,
          [bool]$TrustServerCertificate=$false,[string]$Application='IISReports.Setup')
    Add-Type -AssemblyName System.Data
    if ([string]::IsNullOrWhiteSpace($SqlServer)) { throw 'SqlServer must not be empty.' }
    if ([string]::IsNullOrWhiteSpace($Database)) { throw 'Database must not be empty.' }

    # IMPORTANT: SqlConnectionStringBuilder implements IDictionary. In Windows PowerShell,
    # `$builder.DataSource = ...` can be interpreted as dictionary-key assignment to
    # "DataSource" instead of the .NET property DataSource. SqlClient does NOT recognize
    # the keyword "DataSource". Index by the actual SqlClient connection-string keywords.
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b['Data Source'] = $SqlServer
    $b['Initial Catalog'] = $Database
    $b['Encrypt'] = $true
    $b['TrustServerCertificate'] = $TrustServerCertificate
    $b['Connect Timeout'] = 15
    $b['Application Name'] = $Application
    $b['Persist Security Info'] = $false
    if ($null -eq $Credential) {
        $b['Integrated Security'] = $true
    } else {
        $b['Integrated Security'] = $false
        $b['User ID'] = $Credential.UserName
        $b['Password'] = $Credential.GetNetworkCredential().Password
    }
    # ToString() is the canonical SqlConnectionStringBuilder serialization.
    # Never print this value to the console: SQL-auth passwords may be present.
    return $b.ToString()
}
function Open-SetupDatabase {
    param([string]$SqlServer,[string]$Database,[System.Management.Automation.PSCredential]$Credential,
          [bool]$TrustServerCertificate=$false)
    $cs = New-SqlConnectionString -SqlServer $SqlServer -Database $Database -Credential $Credential -TrustServerCertificate $TrustServerCertificate
    $c = New-Object Data.SqlClient.SqlConnection($cs)
    try { $c.Open(); return $c }
    catch { $c.Dispose(); throw }
}
function Invoke-SetupSql {
    param([Data.SqlClient.SqlConnection]$Connection,[string]$Sql,[hashtable]$Parameters=@{},[switch]$Scalar)
    $cmd = $Connection.CreateCommand(); $cmd.CommandText=$Sql; $cmd.CommandTimeout=300
    try {
        foreach ($key in $Parameters.Keys) {
            $value=$Parameters[$key]
            if ($value -is [int]) { $par=$cmd.Parameters.Add($key,[Data.SqlDbType]::Int) }
            elseif ($value -is [bool]) { $par=$cmd.Parameters.Add($key,[Data.SqlDbType]::Bit) }
            else { $par=$cmd.Parameters.Add($key,[Data.SqlDbType]::NVarChar,-1) }
            $par.Value=if($null -eq $value){[DBNull]::Value}else{$value}
        }
        if ($Scalar) { return $cmd.ExecuteScalar() }
        [void]$cmd.ExecuteNonQuery()
    } finally { $cmd.Dispose() }
}
function Invoke-SqlFile {
    param([Data.SqlClient.SqlConnection]$Connection,[string]$Path,[switch]$ShowRows)
    $text=[IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path)
    # Shipped files only: GO separators are on their own line; no sqlcmd directives.
    $batches=[regex]::Split($text,'(?im)^\s*GO\s*(?:--[^\r\n]*)?\r?$')
    foreach($batch in $batches) {
        if ([string]::IsNullOrWhiteSpace($batch)) { continue }
        if ($ShowRows) {
            $cmd=$Connection.CreateCommand();$cmd.CommandText=$batch;$cmd.CommandTimeout=300
            $reader=$null
            try {
                $reader=$cmd.ExecuteReader()
                do {
                    # Each result set has its own columns. Do not merge heterogeneous rows
                    # into a single Format-Table, which would hide later result sets.
                    $rows=New-Object 'System.Collections.Generic.List[object]'
                    while($reader.Read()) {
                        $row=[ordered]@{}
                        for($i=0;$i -lt $reader.FieldCount;$i++) { $row[$reader.GetName($i)]=$reader.GetValue($i) }
                        $rows.Add([pscustomobject]$row)
                    }
                    if($rows.Count -gt 0) { $rows | Format-Table -AutoSize | Out-Host }
                } while($reader.NextResult())
            } finally { if($null -ne $reader){$reader.Dispose()};$cmd.Dispose() }
        } else { Invoke-SetupSql -Connection $Connection -Sql $batch }
    }
}
