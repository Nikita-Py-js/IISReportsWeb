#requires -Version 5.1
# Windows-only integration checks for temporary-directory ACLs and XML creation.
# Never touches IIS/SQL/services or an existing configuration directory.
[CmdletBinding()]
param([string]$TestParent='C:\Deploy\IISReports-setup-tests')
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Setup.Common.ps1"
Assert-Administrator
$parent=Get-SetupDirectoryPath -Directory $TestParent
[void][IO.Directory]::CreateDirectory($parent)
$testDir=Join-Path $parent ('case-'+[Guid]::NewGuid().ToString('N'))
$counter=0
function Assert-Test([bool]$Value,[string]$Name) {
    if(-not $Value){throw "FAIL: $Name"}
    $script:counter++
    Write-Host "PASS $Name"
}
function Assert-Rejected([scriptblock]$Action,[string]$Name) {
    $rejected=$false
    try{& $Action}catch{$rejected=$true}
    Assert-Test $rejected $Name
}
# If a native invocation returns here by accident, the test must fail.
function icacls.exe { throw 'Native icacls must not be called by New-RestrictedDirectory.' }
try {
    Assert-Rejected { Get-SetupDirectoryPath -Directory 'C:\' } 'drive root rejected'
    Assert-Rejected { Get-SetupDirectoryPath -Directory '.\relative' } 'relative path rejected'
    Assert-Rejected { Get-SetupDirectoryPath -Directory 'C:relative' } 'drive-relative path rejected'
    Assert-Rejected { Get-SetupDirectoryPath -Directory 'http://localhost/' } 'URL rejected'
    Assert-Rejected { Get-SetupDirectoryPath -Directory ' C:\temp' } 'leading whitespace rejected'
    New-RestrictedDirectory -Directory $testDir
    Assert-Test ([IO.Directory]::Exists($testDir)) 'temporary directory created'
    Assert-Test (Test-RestrictedDirectoryAcl ([IO.Directory]::GetAccessControl($testDir))) 'protected ACL has only Administrators and SYSTEM'
    New-RestrictedDirectory -Directory $testDir
    Assert-Test (Test-RestrictedDirectoryAcl ([IO.Directory]::GetAccessControl($testDir))) 'second call leaves valid ACL intact'
    $name='space '+[char]0x0442+[char]0x0435+[char]0x0441+[char]0x0442
    $child=Join-Path $testDir $name
    New-RestrictedDirectory -Directory $child
    Assert-Test (Test-RestrictedDirectoryAcl ([IO.Directory]::GetAccessControl($child))) 'spaces and Cyrillic path supported'
    $xmlPath=Join-Path $child 'test.config'
    [xml]$doc='<configuration><appSettings><add key="test" value="not-a-secret" /></appSettings></configuration>'
    Save-NewXml -Document $doc -Destination $xmlPath
    [xml]$saved=[IO.File]::ReadAllText($xmlPath)
    Assert-Test ($saved.configuration.appSettings.add.value -eq 'not-a-secret') 'XML saved in restricted folder'
    Assert-Rejected { Save-NewXml -Document $doc -Destination $xmlPath } 'existing XML not overwritten'
    $unsafe=Join-Path $testDir 'populated'
    [void][IO.Directory]::CreateDirectory($unsafe)
    $marker=Join-Path $unsafe 'keep.txt'
    [IO.File]::WriteAllText($marker,'keep')
    Assert-Rejected { New-RestrictedDirectory -Directory $unsafe } 'nonempty folder with other ACL is not rewritten'
    Assert-Test ([IO.File]::ReadAllText($marker) -eq 'keep') 'existing data retained'
    Write-Host "PASS TOTAL $counter. Temporary directory/ACL tests; no SQL/IIS actions."
} finally {
    Remove-Item Function:\icacls.exe -ErrorAction SilentlyContinue
    # Remove only the unique directory created by this test, never TestParent itself.
    if(Test-Path -LiteralPath $testDir){Remove-Item -LiteralPath $testDir -Recurse -Force}
}
