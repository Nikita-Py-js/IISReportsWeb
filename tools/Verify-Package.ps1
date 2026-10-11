# Integrity check, not a cryptographic publisher signature.
[CmdletBinding()]
param([string]$Root=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$rootPath=(Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
$manifest=Join-Path $rootPath 'SHA256SUMS.txt'
$count=0
foreach($line in [IO.File]::ReadAllLines($manifest)) {
    if([string]::IsNullOrWhiteSpace($line)){continue}
    if($line -notmatch '^([A-Fa-f0-9]{64})  (.+)$'){throw 'Malformed SHA256SUMS.txt'}
    $expected=$Matches[1];$relative=$Matches[2]
    $path=[IO.Path]::GetFullPath((Join-Path $rootPath $relative))
    if(-not $path.StartsWith($rootPath+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Path escapes the package root.'}
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Missing package file: $relative"}
    if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $expected){throw "Hash mismatch: $relative"}
    $count++
}
Write-Host "PASS SHA256: $count files. This validates integrity, not the publisher's identity."
