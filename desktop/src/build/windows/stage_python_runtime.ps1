param(
    [string]$Arch = "amd64",
    [string]$Dest = ""
)

$ErrorActionPreference = "Stop"
if (-not $Dest) {
    $Dest = Join-Path $PSScriptRoot "python-runtime"
}

$pyExe = Join-Path $Dest "python.exe"
$marker = Join-Path $Dest "Lib\site-packages\pypdf"
if ((Test-Path -LiteralPath $pyExe) -and (Test-Path -LiteralPath $marker)) {
    Write-Host "python-runtime already ready: $Dest"
    exit 0
}

if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    throw "uv is required to stage python-runtime"
}

Write-Host "installing CPython 3.12 via uv ($Arch)"
& uv python install 3.12
if ($LASTEXITCODE -ne 0) {
    throw "uv python install 3.12 failed"
}
$found = (& uv python find 3.12 --managed-python --no-project | Select-Object -Last 1).Trim()
if (-not $found -or -not (Test-Path -LiteralPath $found)) {
    throw "uv python find 3.12 --managed-python failed"
}
$src = Split-Path -Parent $found
if ((Split-Path -Leaf $src) -ieq "Scripts") {
    throw "uv python find returned a venv, not a standalone CPython: $found"
}
if (Test-Path -LiteralPath $Dest) {
    Remove-Item -LiteralPath $Dest -Recurse -Force
}
Write-Host "copy $src -> $Dest"
Copy-Item -LiteralPath $src -Destination $Dest -Recurse
Get-ChildItem -LiteralPath $Dest -Recurse -Filter "EXTERNALLY-MANAGED" -ErrorAction SilentlyContinue |
    Remove-Item -Force

$pth = Get-ChildItem -LiteralPath $Dest -Filter "python*._pth" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pth) {
    $text = Get-Content -LiteralPath $pth.FullName -Raw
    if ($text -notmatch '(?m)^import site') {
        Add-Content -LiteralPath $pth.FullName -Value "`nimport site`n"
    }
}

if (-not $env:UV_INDEX_URL) {
    $env:UV_INDEX_URL = "https://mirrors.cloud.tencent.com/pypi/simple"
    $env:UV_INSECURE_HOST = "mirrors.cloud.tencent.com"
}
Write-Host "installing office dump packages into $Dest"
& uv pip install --python $pyExe --quiet openpyxl "xlrd>=2" python-docx python-pptx pypdf pillow
if ($LASTEXITCODE -ne 0) {
    throw "uv pip install office dump packages failed"
}
& $pyExe -c "import openpyxl, xlrd, docx, pptx, pypdf, sys; print(sys.executable); print(openpyxl.__version__)"
