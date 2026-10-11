# Windows Server only. Does not download software, install SQL, or reboot automatically.
[CmdletBinding(SupportsShouldProcess=$true)]
param([switch]$InstallMissing)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Setup.Common.ps1"
Assert-Administrator
if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion -lt [version]'5.1' -or -not [Environment]::Is64BitProcess) {
    throw 'Use 64-bit Windows PowerShell 5.1, not pwsh/PowerShell 7.'
}
if (-not (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue)) {
    throw 'Windows Server with the ServerManager module is required. See docs/PREREQUISITES.md.'
}
$names=@('Web-Server','Web-Default-Doc','Web-Static-Content','Web-Http-Errors','Web-Http-Logging',
         'Web-Filtering','Web-Windows-Auth','Web-Net-Ext45','Web-Asp-Net45',
         'Web-ISAPI-Ext','Web-ISAPI-Filter','Web-Mgmt-Tools','Web-Mgmt-Console','Web-Scripting-Tools')
$state=@(Get-WindowsFeature -Name $names)
$missing=@($state | Where-Object { -not $_.Installed } | Select-Object -ExpandProperty Name)
$state | Select-Object Name,Installed | Format-Table -AutoSize
if($missing.Count -gt 0) {
    if(-not $InstallMissing) { throw 'Required IIS components are missing. Review and rerun with -InstallMissing.' }
    if($PSCmdlet.ShouldProcess(($missing -join ', '),'Install Windows Server role services')) {
        $result=Install-WindowsFeature -Name $missing -IncludeManagementTools
        if(-not $result.Success) { throw 'Windows feature installation failed. Check Server Manager/CBS logs.' }
        if([string]$result.RestartNeeded -eq 'Yes') { throw 'A reboot is required. Reboot during maintenance, then rerun this check.' }
    } else { return }
}
$release=Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction SilentlyContinue
if($null -eq $release -or $release -lt 528040) { throw 'Install .NET Framework 4.8 or 4.8.1 from Microsoft, reboot if requested, then retry. See docs/PREREQUISITES.md.' }
$csc=Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not(Test-Path -LiteralPath $csc)) { throw '.NET Framework C# compiler is not present. Use a separate Windows build machine or install the Framework.' }
Write-Host "PASS IIS/.NET prerequisites; Framework release=$release. SQL Server still needs separate provisioning."
