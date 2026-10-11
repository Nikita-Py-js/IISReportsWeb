# IIS Reports v3: set the exact public browser origin without weakening CSRF.
# Windows PowerShell 5.1 / .NET Framework 4.8. Administrator privileges may be required.
# Examples:
#   .\Set-IISReportsPublicOrigin.ps1 -ShowOnly
#   .\Set-IISReportsPublicOrigin.ps1 -PublicUrl 'http://reports.example.test:801/'
#   .\Set-IISReportsPublicOrigin.ps1 -PublicUrl 'https://reports.example.test/IISReportsV3/'
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string] $WebConfig = 'C:\inetpub\wwwroot\IISReportsV3\Web.config',
    [string] $PublicUrl,
    [switch] $ShowOnly,
    [string] $BackupDirectory = "$env:ProgramData\IISReportsBackups"
)
$ErrorActionPreference = 'Stop'

$fullConfig = [System.IO.Path]::GetFullPath($WebConfig)
if (-not [System.IO.File]::Exists($fullConfig)) {
    throw "Web.config not found: $fullConfig"
}

# Load without printing SQL connection strings, secrets, or CSRF tokens.
$doc = New-Object System.Xml.XmlDocument
$doc.PreserveWhitespace = $true
$doc.Load($fullConfig)
$appSettings = $doc.SelectSingleNode('/configuration/appSettings')
if ($null -eq $appSettings) {
    throw 'Web.config has no /configuration/appSettings element.'
}
$setting = $appSettings.SelectSingleNode('add[@key="IISReportsPublicOrigin"]')
$current = if ($null -ne $setting) { [string] $setting.GetAttribute('value') } else { '' }
if ([string]::IsNullOrWhiteSpace($current)) { $current = '(empty: IIS uses the request origin)' }
Write-Host "Web.config: $fullConfig"
Write-Host "Current IISReportsPublicOrigin: $current"

if ($ShowOnly) { return }
if ([string]::IsNullOrWhiteSpace($PublicUrl)) {
    throw 'Pass -PublicUrl with the actual browser address, e.g. http://reports.example.test:801/. To inspect only, use -ShowOnly.'
}

$inputUrl = $PublicUrl.Trim()
$uri = $null
if (-not [System.Uri]::TryCreate($inputUrl, [System.UriKind]::Absolute, [ref] $uri)) {
    throw 'PublicUrl must be an absolute HTTP(S) URL.'
}
if ($uri.Scheme -notin @('http', 'https') -or
    [string]::IsNullOrWhiteSpace($uri.Host) -or
    -not [string]::IsNullOrEmpty($uri.UserInfo) -or
    -not [string]::IsNullOrEmpty($uri.Query) -or
    -not [string]::IsNullOrEmpty($uri.Fragment)) {
    throw 'PublicUrl must be an HTTP(S) page address without username, password, query, or #fragment.'
}
$origin = $uri.GetLeftPart([System.UriPartial]::Authority)
Write-Host "New expected browser Origin: $origin"
if ($null -ne $setting -and $setting.GetAttribute('value') -eq $origin) {
    Write-Host 'Already configured. No changes required.'
    return
}

if ($PSCmdlet.ShouldProcess($fullConfig, "Back up Web.config and set IISReportsPublicOrigin to $origin")) {
    $backupRoot = [IO.Path]::GetFullPath($BackupDirectory).TrimEnd('\')
    $webRoot = [IO.Path]::GetDirectoryName($fullConfig).TrimEnd('\')
    if (($backupRoot+'\').StartsWith($webRoot+'\',[StringComparison]::OrdinalIgnoreCase)) {
        throw 'BackupDirectory must be outside the served website.'
    }
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    & icacls.exe $backupRoot /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)(F)' '*S-1-5-18:(OI)(CI)(F)' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot restrict the configuration backup directory.' }
    $backup = Join-Path $backupRoot ('Web-origin-' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '.config')
    Copy-Item -LiteralPath $fullConfig -Destination $backup -ErrorAction Stop
    if ($null -eq $setting) {
        $setting = $doc.CreateElement('add')
        $setting.SetAttribute('key', 'IISReportsPublicOrigin')
        [void] $appSettings.AppendChild($setting)
    }
    $setting.SetAttribute('value', $origin)
    try {
        $doc.Save($fullConfig)
    } catch {
        Copy-Item -LiteralPath $backup -Destination $fullConfig -Force
        throw
    }
    Write-Host "Backup: $backup"
    Write-Host "Updated IISReportsPublicOrigin: $origin"
    Write-Host 'The ASP.NET application will restart because Web.config changed.'
    Write-Host 'Reload the site and request a fresh CSRF token before retrying Refresh.'
}
