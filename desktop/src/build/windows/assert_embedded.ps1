param(
    [Parameter(Mandatory = $true)]
    [string]$Installer
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path -LiteralPath $Installer)) {
    throw "missing installer $Installer"
}
$len = (Get-Item -LiteralPath $Installer).Length
if ($len -lt 8MB) {
    throw "installer is $len bytes; AimiOct.exe or python-runtime was not packed."
}
Write-Host "installer $len bytes"
