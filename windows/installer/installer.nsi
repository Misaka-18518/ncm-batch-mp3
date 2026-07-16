!include "MUI2.nsh"
!include "FileFunc.nsh"

!ifndef VERSION
  !define VERSION "1.2.0"
!endif
!ifndef PUBLISH_DIR
  !error "PUBLISH_DIR is required"
!endif
!ifndef OUTPUT_FILE
  !error "OUTPUT_FILE is required"
!endif
!ifndef ICON_FILE
  !error "ICON_FILE is required"
!endif

Unicode True
Name "NCM 批量转 MP3"
OutFile "${OUTPUT_FILE}"
InstallDir "$LOCALAPPDATA\Programs\NCM Batch MP3"
InstallDirRegKey HKCU "Software\NCM Batch MP3" "InstallDirectory"
RequestExecutionLevel user
SetCompressor /SOLID lzma
SetCompressorDictSize 64
ShowInstDetails nevershow
ShowUninstDetails nevershow

VIProductVersion "${VERSION}.0"
VIAddVersionKey /LANG=2052 "ProductName" "NCM 批量转 MP3"
VIAddVersionKey /LANG=2052 "FileDescription" "网易云 NCM 批量转换工具"
VIAddVersionKey /LANG=2052 "FileVersion" "${VERSION}"
VIAddVersionKey /LANG=2052 "ProductVersion" "${VERSION}"
VIAddVersionKey /LANG=2052 "LegalCopyright" "GPL-3.0-or-later"

!define MUI_ABORTWARNING
!define MUI_ICON "${ICON_FILE}"
!define MUI_UNICON "${ICON_FILE}"
!define MUI_FINISHPAGE_RUN "$INSTDIR\NCM Batch MP3.exe"
!define MUI_FINISHPAGE_RUN_TEXT "运行 NCM 批量转 MP3"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"

Section "NCM 批量转 MP3" MainSection
  SetShellVarContext current
  SetOutPath "$INSTDIR"
  File /r "${PUBLISH_DIR}\*.*"

  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "Software\NCM Batch MP3" "InstallDirectory" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NCM Batch MP3" "DisplayName" "NCM 批量转 MP3"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NCM Batch MP3" "DisplayIcon" "$INSTDIR\NCM Batch MP3.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NCM Batch MP3" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NCM Batch MP3" "Publisher" "enshuwu46-png"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NCM Batch MP3" "UninstallString" "$\"$INSTDIR\Uninstall.exe$\""
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NCM Batch MP3" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NCM Batch MP3" "NoRepair" 1

  CreateDirectory "$SMPROGRAMS\NCM 批量转 MP3"
  CreateShortcut "$SMPROGRAMS\NCM 批量转 MP3\NCM 批量转 MP3.lnk" "$INSTDIR\NCM Batch MP3.exe"
  CreateShortcut "$DESKTOP\NCM 批量转 MP3.lnk" "$INSTDIR\NCM Batch MP3.exe"
SectionEnd

Section "Uninstall"
  SetShellVarContext current
  Delete "$DESKTOP\NCM 批量转 MP3.lnk"
  Delete "$SMPROGRAMS\NCM 批量转 MP3\NCM 批量转 MP3.lnk"
  RMDir "$SMPROGRAMS\NCM 批量转 MP3"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NCM Batch MP3"
  DeleteRegKey HKCU "Software\NCM Batch MP3"
  RMDir /r "$INSTDIR"
SectionEnd
