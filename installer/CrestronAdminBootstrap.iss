; Inno Setup script for Crestron Admin Bootstrap
; Build with: build\Build-Installer.ps1
; Or manually: ISCC.exe installer\CrestronAdminBootstrap.iss

#ifndef AppVersion
  #define AppVersion "1.0.0.0"
#endif

#define AppName      "Crestron Admin Bootstrap"
#define AppPublisher "Michael Floyd"
#define AppExeName   "CrestronBootstrap.exe"
#define AppId        "B3F7C0D2-1E4A-4F5B-9C8D-7A2E1F0C4B6D"
#define SourceDir    "..\dist\desktop-win-x64"

#ifndef PowerShellVersion
  #define PowerShellVersion "7.6.3"
#endif

#define PowerShellMsiName "PowerShell-" + PowerShellVersion + "-win-x64.msi"
#define PrereqDir         "..\dist\prerequisites"

[Setup]
AppId={#AppId}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL=https://github.com/jobu109/crestron-admin-bootstrap
AppSupportURL=https://github.com/jobu109/crestron-admin-bootstrap/issues
AppUpdatesURL=https://github.com/jobu109/crestron-admin-bootstrap/releases

; PowerShell 7 is installed machine-wide when missing, so setup needs elevation.
PrivilegesRequired=admin

ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

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

; PowerShell 7 prerequisite
Source: "{#PrereqDir}\{#PowerShellMsiName}"; DestDir: "{tmp}"; Flags: deleteafterinstall; Check: NeedsPowerShell7

[Icons]
Name: "{group}\{#AppName}";                       Filename: "{app}\{#AppExeName}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}";                 Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Code]
function HasPowerShell7: Boolean;
begin
  Result :=
    FileExists(ExpandConstant('{pf64}\PowerShell\7\pwsh.exe')) or
    FileExists(ExpandConstant('{localappdata}\Microsoft\PowerShell\7\pwsh.exe')) or
    FileExists(ExpandConstant('{localappdata}\Programs\PowerShell\7\pwsh.exe'));
end;

function NeedsPowerShell7: Boolean;
begin
  Result := not HasPowerShell7;
end;

[Run]
Filename: "msiexec.exe"; \
  Parameters: "/package ""{tmp}\{#PowerShellMsiName}"" /quiet /norestart ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=0 ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL=0 ENABLE_PSREMOTING=0 REGISTER_MANIFEST=1 USE_MU=1 ENABLE_MU=1 ADD_PATH=1"; \
  StatusMsg: "Installing PowerShell {#PowerShellVersion}..."; \
  Flags: runhidden waituntilterminated; \
  Check: NeedsPowerShell7

Filename: "{app}\{#AppExeName}"; \
  Description: "{cm:LaunchProgram,{#AppName}}"; \
  Flags: nowait postinstall skipifsilent
