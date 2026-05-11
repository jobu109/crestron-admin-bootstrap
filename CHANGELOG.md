# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/jobu109/crestron-admin-bootstrap/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/jobu109/crestron-admin-bootstrap/releases/tag/v0.2.0
[0.1.0]: https://github.com/jobu109/crestron-admin-bootstrap/releases/tag/v0.1.0