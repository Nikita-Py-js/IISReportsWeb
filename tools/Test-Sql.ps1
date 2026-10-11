[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$AgentConfig,[string]$BuildDirectory='')
$ErrorActionPreference='Stop'
if(-not $BuildDirectory){$BuildDirectory=Join-Path (Split-Path $PSScriptRoot -Parent) 'build'}
[xml]$cfg=[IO.File]::ReadAllText((Resolve-Path -LiteralPath $AgentConfig).Path)
$node=$cfg.SelectSingleNode('/configuration/appSettings/add[@key="ConnStr"]')
if($null -eq $node){throw 'ConnStr missing.'}
$old=$env:IISREPORTS_TEST_CONNSTR
try {
 $env:IISREPORTS_TEST_CONNSTR=$node.value
 & (Join-Path $BuildDirectory 'SqlIntegrationTests.exe')
 if($LASTEXITCODE -ne 0){throw 'SQL integration tests failed. See output.'}
} finally {$env:IISREPORTS_TEST_CONNSTR=$old}
