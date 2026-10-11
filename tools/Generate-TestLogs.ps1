[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Destination,[ValidateRange(1,50000)][int]$Rows=2000)
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $Destination){throw 'Use a NEW test directory. Existing IIS logs will never be overwritten.'}
New-Item -ItemType Directory -Path $Destination | Out-Null
$sb=New-Object Text.StringBuilder
$null=$sb.AppendLine('#Fields: date time s-ip cs-method cs-uri-stem cs-uri-query s-port cs-username c-ip sc-status sc-substatus sc-win32-status time-taken cs(User-Agent) cs(Referer)')
$begin=[DateTime]::UtcNow.AddMinutes(-10)
for($i=0;$i -lt $Rows;$i++){
 $date=$begin.AddSeconds($i % 600).ToString('yyyy-MM-dd HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture)
 $status=if($i % 17 -eq 0){500}elseif($i % 11 -eq 0){404}else{200}
 $null=$sb.AppendLine("$date 127.0.0.1 GET /test/$($i % 9) - 80 - 192.0.2.1 $status 0 0 $($i % 1500) synthetic-test -")
}
# Two identical real events must both survive.
$duplicate=$begin.ToString('yyyy-MM-dd HH:mm:ss')+' 127.0.0.1 GET /duplicate - 80 - 192.0.2.2 200 0 0 5 synthetic-test -'
$null=$sb.AppendLine($duplicate);$null=$sb.AppendLine($duplicate)
$null=$sb.AppendLine('malformed synthetic row')
$null=$sb.Append('#Fields: incomplete-final-header')
$path=Join-Path $Destination 'u_ex_synthetic.log'
[IO.File]::WriteAllText($path,$sb.ToString(),(New-Object Text.UTF8Encoding($false)))
Write-Host "Fixture: $path. Expected Requests=$($Rows+2), quarantined=1; final partial header deferred."
Write-Host 'Register this NEW folder in ir3.Sources with a separate test SiteId. No SQL was changed by this script.'
