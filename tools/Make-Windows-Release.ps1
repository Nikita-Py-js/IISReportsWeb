# Only manifest-listed source files and named build artifacts are packaged.
# Local configs, local databases, logs and arbitrary files are never collected.
[CmdletBinding()]
param([string]$OutputDirectory='', [switch]$SkipBuild)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$version=([IO.File]::ReadAllText((Join-Path $root 'VERSION'))).Trim()
if(-not $OutputDirectory){$OutputDirectory=Join-Path $root 'release'}
if(-not $SkipBuild){& "$PSScriptRoot\Build-And-Test.ps1"}
$build=Join-Path $root 'build'
$info=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $build 'BUILDINFO.json')))
if(-not $info.unitTestsPassed -or $info.version -ne $version){throw 'Build metadata does not match this release. Run Build-And-Test.ps1.'}
if(-not $info.artifacts){throw 'Build artifact hashes are missing. Run Build-And-Test.ps1 from this release.'}
foreach($artifact in $info.artifacts){
    if((Get-FileHash -LiteralPath (Join-Path $build $artifact.name) -Algorithm SHA256).Hash -ne $artifact.sha256){throw "Build artifact changed: $($artifact.name). Rebuild."}
}
foreach($source in $info.sources){
    if((Get-FileHash -LiteralPath (Join-Path $root $source.path) -Algorithm SHA256).Hash -ne $source.sha256){throw "Source changed since compilation: $($source.path). Rebuild."}
}
$stage=Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) ('IISReports-'+$version+'-windows-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
if(Test-Path -LiteralPath $stage){throw 'Release staging folder already exists.'}
[void][IO.Directory]::CreateDirectory($stage)
$manifest=[IO.File]::ReadAllLines((Join-Path $root 'SOURCE-MANIFEST.txt'))
foreach($relative in $manifest){
    if(-not $relative -or $relative.StartsWith('#')){continue}
    if($relative.Contains('..') -or [IO.Path]::IsPathRooted($relative)){throw 'Unsafe path in source manifest.'}
    $from=Join-Path $root $relative; $to=Join-Path $stage $relative
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($to))
    Copy-Item -LiteralPath $from -Destination $to
}
foreach($name in @('IISReports.Agent.exe','IISReports.WebCore.dll','IISReports.HandlerTest.dll','UnitTests.exe','SqlIntegrationTests.exe','DiscoverySqlTests.exe','BUILDINFO.json')){
    Copy-Item -LiteralPath (Join-Path $build $name) -Destination (Join-Path $stage ('build\'+$name))
}
$sumLines=@(Get-ChildItem -LiteralPath $stage -Recurse -File | Where-Object {$_.Name -ne 'SHA256SUMS.txt'} | Sort-Object FullName | ForEach-Object {
    (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()+'  '+$_.FullName.Substring($stage.Length+1).Replace('\','/')
})
[IO.File]::WriteAllLines((Join-Path $stage 'SHA256SUMS.txt'),$sumLines,(New-Object Text.UTF8Encoding($false)))
# .NET ZipFile also preserves dot-directories such as .github.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=$stage+'.zip'
[IO.Compression.ZipFile]::CreateFromDirectory($stage,$zip,[IO.Compression.CompressionLevel]::Optimal,$true)
Write-Host "Created Windows release: $zip"
Write-Host ('SHA256: '+(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash)
