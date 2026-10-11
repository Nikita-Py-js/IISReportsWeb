[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$AgentConfig,
 [Parameter(Mandatory=$true)][switch]$EmptyTestDatabase,
 [string]$BuildDirectory=''
)
$ErrorActionPreference='Stop'
if(-not $EmptyTestDatabase){throw 'This test requires explicit -EmptyTestDatabase acknowledgement.'}
if(-not $BuildDirectory){$BuildDirectory=Join-Path (Split-Path $PSScriptRoot -Parent) 'build'}
[xml]$cfg=[IO.File]::ReadAllText((Resolve-Path -LiteralPath $AgentConfig).Path)
$node=$cfg.SelectSingleNode('/configuration/appSettings/add[@key="ConnStr"]')
if($null -eq $node){throw 'ConnStr missing.'}
$old=$env:IISREPORTS_TEST_CONNSTR
try {
 $env:IISREPORTS_TEST_CONNSTR=$node.value
 & (Join-Path $BuildDirectory 'DiscoverySqlTests.exe')
 if($LASTEXITCODE -ne 0){throw 'Discovery SQL tests failed. Review output; nonempty databases are refused.'}
} finally {$env:IISREPORTS_TEST_CONNSTR=$old}
