# IIS Reports v3 Windows Authentication / CSRF smoke test.
# Windows PowerShell 5.1 and .NET Framework 4.8.
# Each request gets its own HttpWebRequest; only cookies are shared.
# Thus a CSRF header from a previous request CANNOT leak into a negative test.
# By default every attempted mutation must be rejected. -QueueScan explicitly queues a job.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [uri] $ApplicationUrl,
    [switch] $QueueScan
)
$ErrorActionPreference = 'Stop'
if ($ApplicationUrl.Scheme -notin @('http', 'https')) {
    throw 'ApplicationUrl must be http:// or https://.'
}
$base = $ApplicationUrl.AbsoluteUri.TrimEnd('/') + '/'
$origin = $ApplicationUrl.GetLeftPart([System.UriPartial]::Authority)
$cookieJar = New-Object System.Net.CookieContainer

function Parse-JsonOrNull([string] $Content) {
    if ([string]::IsNullOrWhiteSpace($Content)) { return $null }
    try { return ConvertFrom-Json -InputObject $Content -ErrorAction Stop }
    catch { return $null }
}

function Send-Request {
    param(
        [Parameter(Mandatory=$true)] [string] $Action,
        [ValidateSet('GET','POST')] [string] $Method = 'GET',
        [hashtable] $Headers = @{},
        [switch] $WithoutCookies
    )
    $url = [uri]($base + 'Reports.ashx?action=' + [uri]::EscapeDataString($Action))
    # Create a NEW request for every call. No shared WebRequestSession or header collection.
    $req = [System.Net.WebRequest]::Create($url)
    $req.Method = $Method
    $req.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
    $req.PreAuthenticate = $true
    $req.AllowAutoRedirect = $false
    $req.Timeout = 20000
    $req.ReadWriteTimeout = 20000
    $req.Accept = 'application/json'
    $req.UserAgent = 'IISReportsV3-CSRF-Test/2'
    $req.CookieContainer = if ($WithoutCookies) { New-Object System.Net.CookieContainer } else { $cookieJar }
    foreach ($headerName in $Headers.Keys) {
        $req.Headers[[string]$headerName] = [string]$Headers[$headerName]
    }
    if ($Method -eq 'POST') {
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes('{}')
        $req.ContentType = 'application/json; charset=utf-8'
        $req.ContentLength = $bodyBytes.Length
        $bodyStream = $req.GetRequestStream()
        try { $bodyStream.Write($bodyBytes, 0, $bodyBytes.Length) }
        finally { $bodyStream.Dispose() }
    }
    $response = $null
    try { $response = $req.GetResponse() }
    catch [System.Net.WebException] {
        $response = $_.Exception.Response
        if ($null -eq $response) { throw }
    }
    try {
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
        try { $raw = $reader.ReadToEnd() }
        finally { $reader.Dispose() }
        return @{
            Status = [int] $response.StatusCode
            Code = $null
            Raw = $raw
            Data = (Parse-JsonOrNull $raw)
            Allow = [string]$response.Headers['Allow']
        }
    }
    finally { $response.Dispose() }
}

function Get-ApiCode($Result) {
    if ($null -eq $Result.Data -or $null -eq $Result.Data.code) { return '' }
    return [string]$Result.Data.code
}

function Require-Response {
    param([string]$Name, $Result, [int]$Status, [string]$ApiCode = '')
    $actualCode = Get-ApiCode $Result
    if ($Result.Status -ne $Status -or ($ApiCode -and $actualCode -ne $ApiCode)) {
        $body = [string]$Result.Raw
        if ($body.Length -gt 600) { $body = $body.Substring(0,600) + '...' }
        throw "$Name FAILED: expected HTTP $Status code=$ApiCode; got HTTP $($Result.Status) code=$actualCode; body=$body"
    }
    Write-Host "PASS $Name"
}

$identity = Send-Request -Action 'whoami'
Require-Response -Name 'Windows identity' -Result $identity -Status 200
$identity.Data | Format-List mode,identity,isAuthenticated,authenticationType,canRead,canEdit,denialCode,processIdentity
if (-not $identity.Data.isAuthenticated -or -not $identity.Data.canEdit) {
    throw 'Run this test as an authenticated, authorized editor.'
}

$csrf = Send-Request -Action 'csrf'
Require-Response -Name 'Token issued' -Result $csrf -Status 200
if ([string]::IsNullOrWhiteSpace([string]$csrf.Data.token)) {
    throw 'CSRF endpoint did not return a token.'
}
$hasCsrfCookie = $false
foreach ($cookie in $cookieJar.GetCookies($ApplicationUrl)) {
    if ($cookie.Name -like 'IISReportsV3_*') { $hasCsrfCookie = $true }
}
if (-not $hasCsrfCookie) {
    throw 'CSRF endpoint did not set its browser cookie. The negative tests would be inconclusive.'
}
Write-Host 'PASS CSRF cookie issued'

$get = Send-Request -Action 'refresh'
if ($get.Status -ne 405) {
    throw "GET cannot mutate FAILED: HTTP $($get.Status); expected 405"
}
$getCode = Get-ApiCode $get
if ($getCode -and $getCode -ne 'post_required') {
    throw "GET cannot mutate FAILED: unexpected code $getCode"
}
Write-Host 'PASS GET cannot mutate (HTTP 405)'

Require-Response -Name 'Origin mismatch denied' -Result (
    Send-Request -Action 'refresh' -Method 'POST' -Headers @{
        'Origin'='https://not-this-origin.invalid';
        'X-IISReports-CSRF'=[string]$csrf.Data.token
    }
) -Status 403 -ApiCode 'csrf_origin'

# Critically: valid cookie, same Origin, but NO CSRF header.
# A previous test's headers CANNOT be inherited by this request.
Require-Response -Name 'Missing CSRF header denied' -Result (
    Send-Request -Action 'refresh' -Method 'POST' -Headers @{ 'Origin'=$origin }
) -Status 403 -ApiCode 'csrf_missing'

Require-Response -Name 'Invalid CSRF token denied' -Result (
    Send-Request -Action 'refresh' -Method 'POST' -Headers @{
        'Origin'=$origin;
        'X-IISReports-CSRF'='not-a-valid-token'
    }
) -Status 403 -ApiCode 'csrf_invalid'

Require-Response -Name 'Missing CSRF cookie denied' -Result (
    Send-Request -Action 'refresh' -Method 'POST' -Headers @{
        'Origin'=$origin;
        'X-IISReports-CSRF'=[string]$csrf.Data.token
    } -WithoutCookies
) -Status 403 -ApiCode 'csrf_missing'

if ($QueueScan) {
    Require-Response -Name 'Valid POST queues scan' -Result (
        Send-Request -Action 'refresh' -Method 'POST' -Headers @{
            'Origin'=$origin;
            'X-IISReports-CSRF'=[string]$csrf.Data.token
        }
    ) -Status 202
}
Write-Host 'DONE: CSRF smoke tests complete. No valid state-changing POST was sent unless -QueueScan was used.'
