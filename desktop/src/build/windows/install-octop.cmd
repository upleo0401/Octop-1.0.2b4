@echo off
setlocal
cd /d "%~dp0"

set "INSTALLER="
for %%F in ("Octop-desktop-windows-amd64-*.exe") do set "INSTALLER=%%~fF"
if not defined INSTALLER (
    echo 未找到安装包 Octop-desktop-windows-amd64-*.exe
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile','-ExecutionPolicy Bypass','-Command','Add-MpPreference -ExclusionPath ''%~dp0''; Add-MpPreference -ExclusionPath ''%LOCALAPPDATA%\Programs\Octop''; Add-MpPreference -ExclusionProcess ''Octop.exe'''"

if exist "%INSTALLER%" (
    start "" "%INSTALLER%"
) else (
    echo 安装包已被安全中心隔离，请把本文件夹加入 Windows 安全中心排除项后再试。
    pause
)
endlocal
