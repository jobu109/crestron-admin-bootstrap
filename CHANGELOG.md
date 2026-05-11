# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/jobu109/crestron-admin-bootstrap/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/jobu109/crestron-admin-bootstrap/releases/tag/v0.1.0