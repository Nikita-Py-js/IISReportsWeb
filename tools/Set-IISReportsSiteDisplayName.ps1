# Windows PowerShell 5.1
# Adds or changes a human-readable IIS site label in the IIS Reports dashboard.
# Does not change IIS bindings, DNS, SQL or application security settings.
# Example:
#   .\Set-IISReportsSiteDisplayName.ps1 -SiteId 1 -DisplayName 'my-site.example'
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(1,2147483647)]
    [int] $SiteId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $DisplayName,

    [string] $WebRoot = 'C:\inetpub\wwwroot\IISReportsV3'
)
$ErrorActionPreference = 'Stop'
$DisplayName = $DisplayName.Trim()
if ($DisplayName.Length -lt 1 -or $DisplayName.Length -gt 120) {
    throw 'DisplayName must contain between 1 and 120 characters.'
}
if ($DisplayName -match '[\x00-\x1F]') {
    throw 'DisplayName must not contain control characters.'
}

$root = [System.IO.Path]::GetFullPath($WebRoot).TrimEnd('\')
if (-not (Test-Path -LiteralPath (Join-Path $root 'Reports.ashx') -PathType Leaf)) {
    throw "IIS Reports handler not found under: $root"
}
$jsonFile = Join-Path $root 'sites.json'
$siteMap = New-Object 'System.Collections.Generic.SortedDictionary[string,string]'
if (Test-Path -LiteralPath $jsonFile -PathType Leaf) {
    try {
        $source = [System.IO.File]::ReadAllText($jsonFile, [System.Text.Encoding]::UTF8)
        $existing = ConvertFrom-Json -InputObject $source -ErrorAction Stop
        if ($null -eq $existing -or $existing -isnot [pscustomobject]) {
            throw 'sites.json must be an object of SiteId-to-name entries.'
        }
        foreach ($p in $existing.PSObject.Properties) {
            $parsedId = 0
            if (-not [int]::TryParse($p.Name, [ref]$parsedId) -or $parsedId -le 0 -or
                $p.Value -isnot [string]) {
                throw "Unexpected sites.json entry: $($p.Name)"
            }
            $siteMap[[string]$parsedId] = [string]$p.Value
        }
    } catch {
        throw "Cannot safely parse $jsonFile; original file was not changed. $($_.Exception.Message)"
    }
}
$siteMap[[string]$SiteId] = $DisplayName
$ordered = [ordered]@{}
foreach ($key in ($siteMap.Keys | Sort-Object { [long]$_ })) {
    $ordered[$key] = $siteMap[$key]
}
$encoded = ConvertTo-Json -InputObject $ordered -Depth 2

if ($PSCmdlet.ShouldProcess($jsonFile, "Set SiteId $SiteId to '$DisplayName'")) {
    $backupPath = $null
    if (Test-Path -LiteralPath $jsonFile -PathType Leaf) {
        $backupDir = Join-Path $env:ProgramData 'IISReports\Backups'
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
        $backupPath = Join-Path $backupDir "sites.json.$stamp.bak"
        Copy-Item -LiteralPath $jsonFile -Destination $backupPath -ErrorAction Stop
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($jsonFile, $encoded + [Environment]::NewLine, $utf8)
    Write-Host "Updated: $jsonFile"
    if ($backupPath) { Write-Host "Backup: $backupPath" }
    Write-Host "IIS Site ID $SiteId => $DisplayName"
    Write-Host 'Refresh the dashboard to display the new name.'
}
