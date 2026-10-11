# Parse all packaged PowerShell scripts without executing their installation actions.
[CmdletBinding()]
param([string]$Root=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$failures=@()
$files=@(Get-ChildItem -LiteralPath $Root -Recurse -Filter '*.ps1' -File |
    Where-Object {$_.FullName -notmatch '\\(release|local|build)\\'})
foreach($file in $files) {
    $tokens=$null; $errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if($errors.Count -gt 0) {$failures+=@($errors | ForEach-Object { "$($file.FullName): $($_.Message)" })}
}
if($failures.Count -gt 0){throw ($failures -join [Environment]::NewLine)}
Write-Host "PASS PowerShell syntax: $($files.Count) scripts. No install actions executed."
