# Installing the Signing Certificate

`CrestronBootstrap.exe` is signed with a self-signed code-signing certificate
(`CN=jobu109 Code Signing`). For Windows and Microsoft Defender to trust it
without warnings, install the public certificate (`jobu109-codesigning.cer`)
into the **Trusted Publishers** store. Optionally also install it into
**Trusted Root Certification Authorities** for a fully-trusted signature
(green checkmark in file properties).

You only need to do this once per machine.

## Files you need

- `CrestronBootstrap.exe` — the signed executable
- `jobu109-codesigning.cer` — the public certificate (no private key)

Both are attached to the GitHub release.

## Option 1 — PowerShell (recommended)

Open PowerShell **as the current user** (no admin needed for per-user trust):

```powershell
# Adjust the path to wherever you saved the .cer
$cer = 'C:\path\to\jobu109-codesigning.cer'
$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $cer

# Trusted Publishers — required so Defender stops complaining
$store = New-Object System.Security.Cryptography.X509Certificates.X509Store('TrustedPublisher','CurrentUser')
$store.Open('ReadWrite'); $store.Add($cert); $store.Close()

# Trusted Root — optional, gives the .exe a valid signature chain
$store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root','CurrentUser')
$store.Open('ReadWrite'); $store.Add($cert); $store.Close()
```

Windows will pop a confirmation dialog the first time you add to Root —
click **Yes**.

## Option 2 — Double-click the .cer

1. Double-click `jobu109-codesigning.cer`
2. Click **Install Certificate...**
3. Store location: **Current User** → Next
4. Choose **Place all certificates in the following store** → **Browse** →
   pick **Trusted Publishers** → OK → Next → Finish
5. Repeat the wizard, picking **Trusted Root Certification Authorities** the
   second time

## Verify

```powershell
Get-ChildItem Cert:\CurrentUser\TrustedPublisher |
  Where-Object Subject -eq 'CN=jobu109 Code Signing'
```

If that returns a row, you're set.

## Run the .exe

```powershell
.\CrestronBootstrap.exe
```

The first run launches the menu. Drop a `subnets.txt` next to the .exe before
selecting option 1.

## Removing the trust later

```powershell
Get-ChildItem Cert:\CurrentUser\TrustedPublisher |
  Where-Object Subject -eq 'CN=jobu109 Code Signing' | Remove-Item

Get-ChildItem Cert:\CurrentUser\Root |
  Where-Object Subject -eq 'CN=jobu109 Code Signing' | Remove-Item
```

## Why self-signed?

A commercial code-signing certificate (DigiCert, Sectigo, etc.) is $200-700
per year. For internal/team distribution, a self-signed cert that techs
install once is the standard tradeoff. If you encounter this tool in a
corporate environment where self-signed certs are blocked by policy, install
the module via the one-liner instead and skip the .exe entirely:

```powershell
iex (irm https://raw.githubusercontent.com/jobu109/crestron-admin-bootstrap/main/install.ps1)
```