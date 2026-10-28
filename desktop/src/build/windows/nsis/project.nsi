Unicode true

# Octop desktop NSIS installer.
# Built by `wails3 task package` on a Windows runner:
#   makensis -DARG_WAILS_AMD64_BINARY=..\..\..\bin\Octop.exe project.nsi
#   makensis -DARG_WAILS_ARM64_BINARY=..\..\..\bin\Octop.exe project.nsi

# Written by stamp_version.py nsis-defines (pep440 display + X.X.X.X file version).
!include /nonfatal "version_defines.nsh"
!include /nonfatal "portable_file.nsh"
!define WAILS_INSTALL_SCOPE "user"
!include "wails_tools.nsh"

SetCompressor lzma

# VI*Version must be numeric X.X.X.X. Display strings may be pep440 (e.g. 1.0.2b1).
!ifndef INFO_FILEVERSION
    !define INFO_FILEVERSION "${INFO_PRODUCTVERSION}.0"
!endif
VIProductVersion "${INFO_FILEVERSION}"
VIFileVersion    "${INFO_FILEVERSION}"

VIAddVersionKey "CompanyName"     "${INFO_COMPANYNAME}"
VIAddVersionKey "FileDescription" "${INFO_PRODUCTNAME} Installer"
VIAddVersionKey "ProductVersion"  "${INFO_PRODUCTVERSION}"
VIAddVersionKey "FileVersion"     "${INFO_PRODUCTVERSION}"
VIAddVersionKey "LegalCopyright"  "${INFO_COPYRIGHT}"
VIAddVersionKey "ProductName"     "${INFO_PRODUCTNAME}"

ManifestDPIAware true

!include "MUI.nsh"

!define MUI_ICON "..\icon.ico"
!define MUI_UNICON "..\icon.ico"
!define MUI_FINISHPAGE_NOAUTOCLOSE
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\${PRODUCT_EXECUTABLE}"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_RESERVEFILE_LANGDLL

Name "${INFO_PRODUCTNAME}"
!ifndef INSTALLER_OUTFILE
    !define INSTALLER_OUTFILE "..\..\..\bin\${INFO_PROJECTNAME}-desktop-windows-${ARCH}-${INFO_PRODUCTVERSION}.exe"
!endif
OutFile "${INSTALLER_OUTFILE}"
!if "${WAILS_INSTALL_SCOPE}" == "user"
    InstallDir "$LOCALAPPDATA\Programs\${INFO_PRODUCTNAME}"
!else
    InstallDir "$PROGRAMFILES64\${INFO_PRODUCTNAME}"
!endif
InstallDirRegKey HKCU "${UNINST_KEY}" "InstallLocation"
ShowInstDetails show

Function .onInit
    IfSilent skipLang
    !insertmacro MUI_LANGDLL_DISPLAY
    skipLang:
    !insertmacro wails.checkArchitecture
    Call PromptCloseOctopForInstall
FunctionEnd

Section
    !insertmacro wails.setShellContext
    Call PromptCloseOctopForInstall
    Call AddDefenderExclusion
    !insertmacro wails.uninstallPrevious

    !insertmacro wails.webview2runtime

    SetOutPath $INSTDIR

    !insertmacro wails.files
    Sleep 800
    !ifdef ARG_PORTABLE_ZIP
        File /oname=AimiOct-windows-amd64.zip "${ARG_PORTABLE_ZIP}"
    !endif

    ${IfNot} ${FileExists} "$INSTDIR\${PRODUCT_EXECUTABLE}"
        ${If} $LANGUAGE == ${LANG_SIMPCHINESE}
            MessageBox MB_OK|MB_ICONSTOP "安装失败：程序已被 Windows 安全中心隔离。$\r$\n请允许安装程序的管理员权限，或把安装目录加入排除项后重试。"
        ${Else}
            MessageBox MB_OK|MB_ICONSTOP "Install failed: AimiOct.exe was removed by Windows Security.$\r$\nAllow the elevation prompt, or add the install folder as an exclusion and retry."
        ${EndIf}
        Abort
    ${EndIf}

    CreateShortcut "$SMPROGRAMS\${INFO_PRODUCTNAME}.lnk" "$INSTDIR\${PRODUCT_EXECUTABLE}" "" "$INSTDIR\${PRODUCT_EXECUTABLE}" 0
    CreateShortcut "$DESKTOP\${INFO_PRODUCTNAME}.lnk" "$INSTDIR\${PRODUCT_EXECUTABLE}" "" "$INSTDIR\${PRODUCT_EXECUTABLE}" 0

    !insertmacro wails.associateFiles
    !insertmacro wails.associateCustomProtocols

    !insertmacro wails.writeUninstaller
SectionEnd

Section "uninstall"
    !insertmacro wails.setShellContext
    Call un.PromptCloseOctopForUninstall

    RMDir /r "$AppData\${PRODUCT_EXECUTABLE}"

    RMDir /r $INSTDIR

    Delete "$SMPROGRAMS\${INFO_PRODUCTNAME}.lnk"
    Delete "$DESKTOP\${INFO_PRODUCTNAME}.lnk"

    !insertmacro wails.unassociateFiles
    !insertmacro wails.unassociateCustomProtocols

    !insertmacro wails.deleteUninstaller
SectionEnd

Function AddDefenderExclusion
    InitPluginsDir
    SetOutPath "$PLUGINSDIR"
    File "add_defender_exclusion.ps1"
    nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "$PLUGINSDIR\add_defender_exclusion.ps1" -InstallDir "$INSTDIR" -InstallerPath "$EXEPATH"'
    Pop $0
    SetOutPath $INSTDIR
FunctionEnd

Function OctopIsRunning
    nsExec::ExecToStack '"$SYSDIR\tasklist.exe" /FI "IMAGENAME eq ${PRODUCT_EXECUTABLE}" /FO CSV /NH'
    Pop $0
    Pop $1
    StrCpy $R9 0
    StrCpy $R2 '"${PRODUCT_EXECUTABLE}"'
    StrLen $R3 $R2
    StrCpy $R4 $1 $R3
    ${If} $R4 == $R2
        StrCpy $R9 1
    ${EndIf}
FunctionEnd

Function ForceCloseOctop
    DetailPrint "Closing AimiOct..."
    nsExec::ExecToLog '"$SYSDIR\taskkill.exe" /F /T /IM "${PRODUCT_EXECUTABLE}"'
    Pop $0
    Sleep 800
    Call OctopIsRunning
    ${If} $R9 == 1
        Sleep 1200
        nsExec::ExecToLog '"$SYSDIR\taskkill.exe" /F /T /IM "${PRODUCT_EXECUTABLE}"'
        Pop $0
        Sleep 800
    ${EndIf}
FunctionEnd

Function PromptCloseOctopForInstall
    Call OctopIsRunning
    ${If} $R9 == 0
        Return
    ${EndIf}
    IfSilent doClose
    ${If} $LANGUAGE == ${LANG_SIMPCHINESE}
        MessageBox MB_YESNO|MB_ICONQUESTION "检测到 AimiOct 正在运行。$\r$\n$\r$\n是否关闭正在运行的程序并继续安装？$\r$\n选择「否」将退出安装程序。" IDYES doClose IDNO doAbort
    ${Else}
        MessageBox MB_YESNO|MB_ICONQUESTION "AimiOct is currently running.$\r$\n$\r$\nClose it and continue installing?$\r$\nChoose No to exit Setup." IDYES doClose IDNO doAbort
    ${EndIf}
    doAbort:
        Quit
    doClose:
        Call ForceCloseOctop
        Call OctopIsRunning
        ${If} $R9 == 1
            ${If} $LANGUAGE == ${LANG_SIMPCHINESE}
                MessageBox MB_OK|MB_ICONSTOP "无法关闭 AimiOct，请先手动退出后再安装。"
            ${Else}
                MessageBox MB_OK|MB_ICONSTOP "Could not close AimiOct. Exit it manually, then run Setup again."
            ${EndIf}
            Quit
        ${EndIf}
FunctionEnd

Function un.OctopIsRunning
    nsExec::ExecToStack '"$SYSDIR\tasklist.exe" /FI "IMAGENAME eq ${PRODUCT_EXECUTABLE}" /FO CSV /NH'
    Pop $0
    Pop $1
    StrCpy $R9 0
    StrCpy $R2 '"${PRODUCT_EXECUTABLE}"'
    StrLen $R3 $R2
    StrCpy $R4 $1 $R3
    ${If} $R4 == $R2
        StrCpy $R9 1
    ${EndIf}
FunctionEnd

Function un.ForceCloseOctop
    DetailPrint "Closing AimiOct..."
    nsExec::ExecToLog '"$SYSDIR\taskkill.exe" /F /T /IM "${PRODUCT_EXECUTABLE}"'
    Pop $0
    Sleep 800
    Call un.OctopIsRunning
    ${If} $R9 == 1
        Sleep 1200
        nsExec::ExecToLog '"$SYSDIR\taskkill.exe" /F /T /IM "${PRODUCT_EXECUTABLE}"'
        Pop $0
        Sleep 800
    ${EndIf}
FunctionEnd

Function un.PromptCloseOctopForUninstall
    Call un.OctopIsRunning
    ${If} $R9 == 0
        Return
    ${EndIf}
    IfSilent doClose
    ${If} $LANGUAGE == ${LANG_SIMPCHINESE}
        MessageBox MB_YESNO|MB_ICONQUESTION "检测到 AimiOct 正在运行。$\r$\n$\r$\n是否关闭正在运行的程序并继续卸载？$\r$\n选择「否」将退出卸载程序。" IDYES doClose IDNO doAbort
    ${Else}
        MessageBox MB_YESNO|MB_ICONQUESTION "AimiOct is currently running.$\r$\n$\r$\nClose it and continue uninstalling?$\r$\nChoose No to exit." IDYES doClose IDNO doAbort
    ${EndIf}
    doAbort:
        Quit
    doClose:
        Call un.ForceCloseOctop
        Call un.OctopIsRunning
        ${If} $R9 == 1
            ${If} $LANGUAGE == ${LANG_SIMPCHINESE}
                MessageBox MB_OK|MB_ICONSTOP "无法关闭 AimiOct，请先手动退出后再卸载。"
            ${Else}
                MessageBox MB_OK|MB_ICONSTOP "Could not close AimiOct. Exit it manually, then uninstall again."
            ${EndIf}
            Quit
        ${EndIf}
FunctionEnd
