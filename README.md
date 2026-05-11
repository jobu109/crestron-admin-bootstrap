# Crestron 4-Series Admin Bootstrap

Bulk-provision the initial admin account on Crestron 4-Series devices stuck on the `/createUser.html` first-boot page. Scan subnets, review what's found, push a single set of admin credentials to every device, and verify the change took.

```powershell
# One-line install (PowerShell 7, no admin)
iex (irm https://raw.githubusercontent.com/jobu109/crestron-admin-bootstrap/main/install.ps1)

# Use it
Find-CrestronBootup -CidrFile .\subnets.txt
Set-CrestronAdmin   -InputCsv .\crestron-bootup.csv
Test-CrestronAdmin  -InputCsv .\crestron-provisioned.csv
```

---

## What it does

- **`Find-CrestronBootup`** — scans CIDRs in parallel, returns devices whose `/createUser.html` matches the 4-Series first-boot signatures. Read-only.
- **`Set-CrestronAdmin`** — prompts for one admin username/password, asks for a YES confirmation, then `POST`s `/Device/Authentication` on every device in parallel.
- **`Test-CrestronAdmin`** — rescans previously-provisioned IPs and confirms `/createUser.html` no longer matches the bootup signatures.

## Requirements

- **PowerShell 7+** (PS 5.1 will not work — TLS handshake to Crestron's web server fails)
- **`curl.exe`** (bundled with Windows 10/11)
- Network access to TCP 443 on target devices

## Install

### Quick install (recommended)

In PowerShell 7:

```powershell
iex (irm https://raw.githubusercontent.com/jobu109/crestron-admin-bootstrap/main/install.ps1)
```

The installer:
1. Confirms PowerShell 7 is present (offers to install via winget if not)
2. Downloads the latest release
3. Drops the module under `~\Documents\PowerShell\Modules\CrestronAdminBootstrap\<version>\`
4. Imports the module and lists the exported commands

### Install options

```powershell
# Pin to a specific release tag
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/jobu109/crestron-admin-bootstrap/main/install.ps1))) -Version v0.1.0

# Track the main branch (unreleased changes)
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/jobu109/crestron-admin-bootstrap/main/install.ps1))) -Branch main

# Install for all users (requires admin)
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/jobu109/crestron-admin-bootstrap/main/install.ps1))) -Scope AllUsers
```

### Manual install

Clone the repo, copy `src\CrestronAdminBootstrap\` into your PowerShell modules path, run `Import-Module CrestronAdminBootstrap`.

### .exe distribution (for techs)

A pre-built **signed** `CrestronBootstrap.exe` is attached to each GitHub release. It's a menu-driven wrapper around the same module — no PowerShell knowledge required. Drop the .exe in a folder, drop a `subnets.txt` next to it, double-click.

**One-time setup per machine:** install the signing certificate (`jobu109-codesigning.cer`, also on the release) into Trusted Publishers so Windows trusts the signature. See [INSTALL-CERT.md](INSTALL-CERT.md) for instructions.

Note that the .exe still requires PowerShell 7 + the module on the target machine — it'll detect missing pieces and offer to install them the first time you run it.

## Usage

### 1. Build a subnets list

`subnets.txt`, one CIDR per line:

```
10.10.20.0/24
10.10.21.0/24
# 192.168.0.0/22   # uncomment to include
```

See [`examples/subnets.example.txt`](examples/subnets.example.txt).

### 2. Scan

```powershell
Find-CrestronBootup -CidrFile .\subnets.txt -OutputCsv .\crestron-bootup.csv
```

| Parameter | Default | Notes |
|---|---|---|
| `-CidrFile` | *(required)* | Path to subnets list |
| `-TimeoutSec` | 4 | Per-host timeout |
| `-Throttle` | 64 | Parallel workers |
| `-OutputCsv` | none | Optional CSV path |

Returns one row per device on the bootup page. **Review the CSV before proceeding.**

### 3. Provision

```powershell
Set-CrestronAdmin -InputCsv .\crestron-bootup.csv -ResultsCsv .\crestron-provisioned.csv
```

You'll be prompted for:
- Username (applies to **every** device in the run)
- Password (twice, masked)
- Final confirmation — type `YES` (uppercase) to proceed

Or pass IPs directly without a CSV:

```powershell
Set-CrestronAdmin -IP 10.10.20.21,10.10.20.22
```

Or non-interactively with `-Credential` and `-Force` (for scripted runs — be careful):

```powershell
$cred = Get-Credential
Set-CrestronAdmin -InputCsv .\crestron-bootup.csv -Credential $cred -Force
```

### 4. Verify

```powershell
Test-CrestronAdmin -InputCsv .\crestron-provisioned.csv -OutputCsv .\crestron-verified.csv
```

For each IP, confirms `/createUser.html` no longer matches the bootup signatures. Reports `Verified=True` (provisioning stuck) or `Verified=False` (still on bootup page — investigate).

## How provisioning works

POSTs the following JSON to `https://<ip>/Device/Authentication`:

```json
{
  "Device": {
    "Authentication": {
      "AuthenticationState": {
        "AdminUsername": "<user>",
        "AdminPassword": "<pass>",
        "IsEnabled": true
      }
    }
  }
}
```

The password is written to a temp file and passed to `curl` via `--data-binary @file`, never via the command line, so it doesn't appear in process listings.

## Safety

- Always run **`Find-CrestronBootup` first**. It's read-only and produces the audit trail of what's about to change.
- **Spot-check the scan CSV.** Anything unexpected? Stop and investigate.
- **The same credentials apply to every device in a run by design.** Use a password manager — losing them means a hardware factory reset on each affected unit.
- Test on one device before bulk-running:

```powershell
  Set-CrestronAdmin -IP 10.10.20.21
  Test-CrestronAdmin -IP 10.10.20.21
```

## Troubleshooting

### Scanner returns nothing

- Verify PS 7: `$PSVersionTable.PSVersion` → Major should be `7`
- Manually probe one known device:
```powershell
  curl.exe -k -s https://<ip>/createUser.html | findstr cred_createuser_btn
```
  If no match, your firmware serves a different create-admin page. Open an issue with the page contents and the signatures in `src\CrestronAdminBootstrap\Private\Test-CrestronBootupPage.ps1` can be updated.

### Provisioning returns non-200

- **400 / 401** — payload format may have changed in newer firmware. Re-capture in Chrome DevTools → Network → POST to `/Device/Authentication` → Payload → view source.
- **403** — the device already has an admin. The scanner shouldn't have flagged it; rerun `Find-CrestronBootup` to refresh the CSV.
- **Timeouts** — raise `-TimeoutSec`, lower `-Throttle`.

### `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED` over SSH

Expected after a device factory reset. Clear the stale key:

```powershell
ssh-keygen -R <ip>
```

### Factory-reset a 4-Series device (for testing)

```
ssh admin@<ip>
restoretofactorydefaults
y
```

## Repo layout

```
crestron-admin-bootstrap/
├─ install.ps1                       # One-liner installer target
├─ src/CrestronAdminBootstrap/
│  ├─ CrestronAdminBootstrap.psd1    # Module manifest
│  ├─ CrestronAdminBootstrap.psm1    # Loader (dot-sources Public + Private)
│  ├─ Public/                        # Exported cmdlets
│  │  ├─ Find-CrestronBootup.ps1
│  │  ├─ Set-CrestronAdmin.ps1
│  │  └─ Test-CrestronAdmin.ps1
│  └─ Private/                       # Internal helpers
│     ├─ Expand-Cidr.ps1
│     └─ Test-CrestronBootupPage.ps1
├─ wrapper/
│  ├─ CrestronBootstrap.Launcher.ps1 # Menu-driven UI
│  └─ Build-Exe.ps1                  # PS2EXE build (run once per release)
└─ examples/
   ├─ subnets.example.txt
   └─ full-workflow.ps1
```

## Versioning

[Semantic Versioning](https://semver.org/). See [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE).