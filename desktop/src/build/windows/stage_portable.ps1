param(
    [Parameter(Mandatory = $true)]
    [string]$Zip
)

$ErrorActionPreference = "Stop"
if (-not [System.IO.Path]::IsPathRooted($Zip)) {
    $Zip = Join-Path (Get-Location) $Zip
}
if (-not (Test-Path -LiteralPath $Zip)) {
    throw "portable zip not found: $Zip"
}
$len = (Get-Item -LiteralPath $Zip).Length
if ($len -lt 50MB) {
    throw "portable zip too small ($len bytes): $Zip"
}
New-Item -ItemType Directory -Force bundled | Out-Null
Copy-Item -LiteralPath $Zip -Destination (Join-Path (Get-Location) "bundled\portable.zip") -Force
$copied = (Get-Item -LiteralPath "bundled\portable.zip").Length
if ($copied -lt 50MB) {
    throw "staged portable.zip too small: $copied bytes"
}
Write-Host "staged portable.zip $copied bytes"
$nsh = Join-Path $PSScriptRoot "nsis\portable_file.nsh"
$full = (Resolve-Path -LiteralPath $Zip).Path
Set-Content -LiteralPath $nsh -Value "!define ARG_PORTABLE_ZIP `"$full`"" -Encoding ASCII
Write-Host "wrote $nsh"
