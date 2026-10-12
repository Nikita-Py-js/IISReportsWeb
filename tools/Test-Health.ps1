#requires -Version 5.1
# Read-only HTTP check. Does not start the service or create jobs.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][uri]$ApplicationUrl)
$ErrorActionPreference='Stop'
if($ApplicationUrl.Scheme -notin @('http','https') -or $ApplicationUrl.UserInfo -or $ApplicationUrl.Query -or $ApplicationUrl.Fragment){throw 'Use a plain HTTP(S) application URL.'}
$url=$ApplicationUrl.AbsoluteUri.TrimEnd('/')+'/Reports.ashx?action=health'
$req=[Net.WebRequest]::Create($url)
$req.Credentials=[Net.CredentialCache]::DefaultNetworkCredentials
$req.AllowAutoRedirect=$false;$req.Timeout=20000;$req.Accept='application/json'
$response=$null
try{
 $response=$req.GetResponse()
 if([int]$response.StatusCode -ne 200){throw 'Health returned a non-200 status. Inspect the public URL and authentication.'}
 $reader=New-Object IO.StreamReader($response.GetResponseStream())
 try{$result=ConvertFrom-Json -InputObject $reader.ReadToEnd()}finally{$reader.Dispose()}
 $required=@('dbConnected','schemaInitialized','agentOnline','discoveryHealthy','healthy','status')
 foreach($name in $required){if($null -eq $result.PSObject.Properties[$name]){throw "Health JSON is missing $name. Check the deployed version."}}
 $result | Select-Object version,status,healthy,dbConnected,schemaInitialized,agentOnline,discoveryHealthy,dbEntries,queuedJobs,lastParsed | Format-List | Out-Host
 if(-not $result.dbConnected -or -not $result.schemaInitialized){throw 'Web process cannot use the expected SQL schema. Inspect action=diag and application SQL permissions.'}
 if(-not $result.agentOnline){throw 'No fresh agent heartbeat. Inspect service status and agent logs. After initial start, wait for its first pass and repeat Verify.'}
 if(-not $result.discoveryHealthy -or -not $result.healthy){throw 'Agent/discovery/import requires attention. Inspect Sources and agent logs; verification is not successful yet.'}
 Write-Host 'PASS live health. This checks current service health, not completeness of historical data or webhook delivery.'
}finally{if($null -ne $response){$response.Dispose()}}
