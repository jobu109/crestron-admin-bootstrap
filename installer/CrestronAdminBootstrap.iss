; Inno Setup script for Crestron Admin Bootstrap
; Build with: build\Build-Installer.ps1
; Or manually: ISCC.exe installer\CrestronAdminBootstrap.iss

#ifndef AppVersion
  #define AppVersion "0.13.7"
#endif

#define AppName      "Crestron Admin Bootstrap"
#define AppPublisher "Michael Floyd"
#define AppExeName   "CrestronBootstrap.exe"
#define AppId        "B3F7C0D2-1E4A-4F5B-9C8D-7A2E1F0C4B6D"
#define SourceDir    "..\dist\desktop-win-x64"

[Setup]
AppId={#AppId}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL=https://github.com/jobu109/crestron-admin-bootstrap
AppSupportURL=https://github.com/jobu109/crestron-admin-bootstrap/issues
AppUpdatesURL=https://github.com/jobu109/crestron-admin-bootstrap/releases

; Install per-user by default (no UAC prompt); dialog lets admin install system-wide
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog

DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
AllowNoIcons=yes

OutputDir=..\dist
OutputBaseFilename=CrestronAdminBootstrap-Setup-v{#AppVersion}-win-x64
SetupIconFile=..\src\CrestronAdminBootstrap.Desktop\App.ico
WizardSmallImageFile=..\src\CrestronAdminBootstrap.Desktop\App.png

Compression=lzma2
SolidCompression=yes
WizardStyle=modern

; Minimum OS: Windows 10
MinVersion=10.0.17763

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Main executable
Source: "{#SourceDir}\{#AppExeName}"; DestDir: "{app}"; Flags: ignoreversion

; PowerShell module (required — must be alongside the exe)
Source: "{#SourceDir}\src\*"; DestDir: "{app}\src"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}";                       Filename: "{app}\{#AppExeName}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}";                 Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; \
  Description: "{cm:LaunchProgram,{#AppName}}"; \
  Flags: nowait postinstall skipifsilent
