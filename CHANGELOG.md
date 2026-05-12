# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.0] - 2026-05-11

### Added
- `Connect-CrestronDevice` — authenticates against a Crestron 4-Series device
  and returns a session object (cookies + XSRF token) usable by other
  authenticated cmdlets. Follows the documented CWS auth flow: GET / for
  TRACKID, POST `/userlogin.html` with credentials, capture
  `CREST-XSRF-TOKEN` response header.
- `Disconnect-CrestronDevice` — cleans up the on-disk cookie jar for a session.
- `Set-CrestronSettings` — applies blanket post-provisioning configuration.
  Supports any combination of:
    - `-Ntp` (server + 3-digit Crestron timezone code, enabled flag)
    - `-Cloud` (XiO Cloud on/off)
    - `-AutoUpdate` (Avf auto-update schedule + manifest URL)
  Combines selected sections into a single CresNext partial-object POST to
  `/Device` to minimize round-trips.
- Private `Invoke-CrestronApi` helper for authenticated CresNext calls (cookie
  jar persistence + XSRF token injection + status/body parsing).
- Private `Get-CrestronTimeZones` returning a curated 30-entry table of common
  US/EU/AU/AS Crestron timezone codes for use in the launcher picker.
- Launcher option `[5] Configure settings on provisioned devices` — reads
  `crestron-provisioned.csv`, prompts for credentials and per-section config,
  shows a summary, requires YES confirmation, applies in parallel, writes
  `crestron-settings.csv`.

### Changed
- `Connect-CrestronDevice` now probes `/Device/DeviceInfo` post-login and
  records `DeviceFamily`, `Model`, `Hostname`, and `Firmware` on the session
  object. Used to select the correct payload shape per device family.
- `Set-CrestronSettings` auto-routes the auto-update payload by family:
  TouchPanel uses the simple `Device.AutoUpdateMaster.IsEnabled` shape;
  other families use the richer `Device.FeatureConfig.Avf.AvfAutoUpdate`
  shape with schedule/manifest fields.
- `Set-CrestronSettings` now parses the CresNext response body and inspects
  `Actions[].Results[].StatusId` for each section. `StatusId 0` = OK,
  `StatusId 1` = OK (reboot required), anything else is reported as a
  failure. Previously a "HTTP 200 + unsupported property" body was reported
  as Success — no longer.
- The result object adds a `SectionResults` array (Path/StatusId/StatusInfo/Ok)
  for fine-grained per-section diagnostics.

### Known limitations
- TouchPanel devices accept only the on/off auto-update toggle; the launcher
  warns when ManifestUrl/schedule fields are supplied for a TouchPanel and
  silently ignores them.
- `AuthByPasswd` cookie rotates per request. Curl handles this automatically
  on the same cookie jar; bypassing curl requires manual cookie merging.

## [0.3.0] - 2026-05-11

### Added
- Launcher now prompts the tech for CIDRs at scan time instead of requiring a
  pre-existing `subnets.txt`. The first CIDR prompt pre-fills `172.22.0.0/24`
  as the default — press Enter to accept.
- New menu option `[E] Edit subnets list` for updating saved CIDRs without
  opening a text editor.
- Launcher normalizes `-WorkingDirectory` to an absolute path before resolving
  any working files, so relative paths passed by the bootstrapper or tests
  don't double-resolve.

## [0.2.0] - 2026-05-11

### Added
- Signed `CrestronBootstrap.exe` distribution for techs who shouldn't have to
  touch PowerShell. Menu-driven wrapper around the module.
- Self-signed code-signing certificate (`CN=jobu109 Code Signing`); public
  `.cer` ships in `signing/` for end-user trust installation.
- Bootstrapper architecture: PS 5.1-compiled .exe detects PowerShell 7 and
  the module, offers to install them, and hands off to a `pwsh`-hosted menu.
- `INSTALL-CERT.md` — one-time per-machine trust-install instructions for the
  signing certificate.
- `wrapper\Build-Exe.ps1` enhanced to:
  - Embed the launcher script into the bootstrapper at build time
  - Apply a temporary Defender exclusion during build (requires elevation)
  - Sign the resulting .exe with the configured code-signing cert
  - Verify the signature

## [0.1.0] - 2026-05-11

### Added
- Initial release.
- `Find-CrestronBootup` — parallel subnet scanner that identifies 4-Series
  Crestron devices stuck on the initial create-admin page (`/createUser.html`).
- `Set-CrestronAdmin` — bulk-provisions the initial admin account via
  `POST /Device/Authentication` with a one-time credential prompt and a
  YES-to-proceed confirmation gate.
- `Test-CrestronAdmin` — rescans previously-provisioned IPs to verify the
  bootup page is gone (positive confirmation that provisioning stuck).
- Module structure (Public/Private split) with shared probe helper
  (`Test-CrestronBootupPage`).
- Uses `curl.exe` for HTTPS instead of .NET `HttpClient` to avoid TLS callback
  failures in parallel runspaces.
- MIT License.

### Known limitations
- Requires PowerShell 7+ (uses `ForEach-Object -Parallel`).
- Signatures tuned to current 4-Series firmware (`cred_createuser_btn` etc.);
  may need adjustment for older or future firmware.
- Same admin credentials applied to every device in a single run by design.

[Unreleased]: https://github.com/jobu109/crestron-admin-bootstrap/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/jobu109/crestron-admin-bootstrap/releases/tag/v0.4.0
[0.3.0]: https://github.com/jobu109/crestron-admin-bootstrap/releases/tag/v0.3.0
[0.2.0]: https://github.com/jobu109/crestron-admin-bootstrap/releases/tag/v0.2.0
[0.1.0]: https://github.com/jobu109/crestron-admin-bootstrap/releases/tag/v0.1.0