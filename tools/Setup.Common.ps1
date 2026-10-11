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
function Get-SetupDirectoryPath {
    # Deliberately accept only explicit local, drive-qualified Windows paths.
    # Resolving a relative .NET path against Environment.CurrentDirectory is unsafe
    # here: that directory is NOT necessarily PowerShell's current location.
    param([Parameter(Mandatory=$true)][string]$Directory)
    if ([string]::IsNullOrWhiteSpace($Directory) -or $Directory -ne $Directory.Trim()) {
        throw 'Directory must be a nonempty path without leading/trailing whitespace.'
    }
    if ($Directory -notmatch '^[A-Za-z]:\\' -or
        $Directory -match '[\x00-\x1f<>"|?*]' -or
        $Directory.Substring(2).Contains(':')) {
        throw 'Use a local absolute directory such as C:\Deploy\IISReports-config (not a URI, UNC path, or drive-relative path).'
    }
    $full = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
    if ($full -eq [IO.Path]::GetPathRoot($full).TrimEnd('\')) {
        throw 'Refusing to change permissions on a drive root.'
    }
    if ([IO.File]::Exists($full)) { throw "Directory is an existing file: $full" }
    # Do not redirect privileged ACL operations through a junction/symlink.
    $cursor = $full
    while ($cursor) {
        if ([IO.Directory]::Exists($cursor)) {
            $attrs = [IO.File]::GetAttributes($cursor)
            if (($attrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing a directory with a reparse-point ancestor: $cursor"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
    return $full
}
function Test-RestrictedDirectoryAcl {
    param([Parameter(Mandatory=$true)][Security.AccessControl.DirectorySecurity]$Acl)
    if (-not $Acl.AreAccessRulesProtected) { return $false }
    $rules = @($Acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    if ($rules.Count -ne 2) { return $false }
    $expected = @('S-1-5-32-544','S-1-5-18')
    $seen = @()
    $inherit = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
               [Security.AccessControl.InheritanceFlags]::ObjectInherit
    foreach ($rule in $rules) {
        $sid = $rule.IdentityReference.Value
        if ($sid -notin $expected -or $sid -in $seen -or $rule.IsInherited -or
            $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl -or
            $rule.InheritanceFlags -ne $inherit -or
            $rule.PropagationFlags -ne [Security.AccessControl.PropagationFlags]::None) { return $false }
        $seen += $sid
    }
    return $true
}
function New-RestrictedDirectory {
    # SETUP-FIX1: no native icacls process; no dependency on its working directory.
    # Only Administrators and SYSTEM get access. Never weaken a populated folder.
    param([Parameter(Mandatory=$true)][string]$Directory)
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
        $PSVersionTable.PSEdition -ne 'Desktop') {
        throw 'Directory ACL setup requires elevated Windows PowerShell 5.1 / .NET Framework.'
    }
    Assert-Administrator
    $full = Get-SetupDirectoryPath -Directory $Directory
    if ([IO.Directory]::Exists($full)) {
        $existing = [IO.Directory]::GetAccessControl($full)
        if (Test-RestrictedDirectoryAcl -Acl $existing) { return }
        if (@(Get-ChildItem -LiteralPath $full -Force -ErrorAction Stop).Count -ne 0) {
            throw "Directory contains files and does not have the expected restricted ACL. Nothing changed. Choose a new dedicated folder: $full"
        }
    }
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    $inherit = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
               [Security.AccessControl.InheritanceFlags]::ObjectInherit
    foreach ($value in @('S-1-5-32-544','S-1-5-18')) {
        $sid = New-Object Security.Principal.SecurityIdentifier -ArgumentList $value
        $rule = New-Object Security.AccessControl.FileSystemAccessRule -ArgumentList @(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inherit,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
        [void]$acl.AddAccessRule($rule)
    }
    try {
        if ([IO.Directory]::Exists($full)) {
            [IO.Directory]::SetAccessControl($full,$acl)
        } else {
            # This .NET Framework overload applies the DACL when creating the directory.
            [void][IO.Directory]::CreateDirectory($full,$acl)
        }
        $actual = [IO.Directory]::GetAccessControl($full)
        if (-not (Test-RestrictedDirectoryAcl -Acl $actual)) {
            throw 'The resulting directory DACL did not pass verification.'
        }
    } catch {
        throw "Cannot secure directory '$full'. No configuration was written by this helper. $($_.Exception.Message)"
    }
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
