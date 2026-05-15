# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.1.0] - 2026-05-15

### Added

- **`Remove-ERPNextAzureDeployment.ps1`** — new teardown script with two modes (whole Resource Group, or selective per-resource), resource-lock detection and optional removal, Key Vault soft-delete handling with optional purge to free the vault name immediately, local-artifact cleanup, production-subscription safety check, and full `-WhatIf`/`-Confirm` support.
- **End-to-end deployment** — `Deploy-ERPNextToAzure.ps1` now runs the ERPNext installation on the VM automatically via `Invoke-AzVMRunCommand`. The manual SCP/SSH step is no longer required.
- **Azure Key Vault integration** — `-UseKeyVault` and `-KeyVaultName` parameters store VM admin, MariaDB root, and ERPNext admin passwords as Key Vault secrets instead of writing them to a local JSON file.
- **SSH key authentication** — `-UseSSHKey` and `-SSHPublicKeyPath` parameters configure SSH key auth and disable password auth on the VM.
- **Source IP restriction** — `-AllowedSourceCIDR` parameter scopes NSG inbound rules to a specific IP or CIDR block.
- **Subscription targeting** — `-SubscriptionId` parameter switches the active Az context to a specific subscription before deploying.
- **Idempotency** — every Azure resource (Resource Group, NSG, Public IP, VNet, NIC, VM, Key Vault) is checked for existence before creation. Re-running after a partial failure is safe.
- **Pre-flight checks** — connection, subscription, resource providers, region/VM SKU availability are all validated before any resources are touched.
- **Structured logging** — both scripts write timestamped log files alongside their output.
- **Result object** — `Deploy-ERPNextToAzure.ps1` returns a `PSCustomObject` containing all deployment metadata, enabling pipeline use.
- **Cleanup guidance on failure** — when deployment fails, the script reports which Resource Group to remove for cleanup.
- **`-SkipInstall` parameter** — provisions infrastructure only; useful for debugging.
- **`-InstallTimeoutMinutes` parameter** — caps the install Run Command wait time.
- **`-ThrottleMilliseconds` parameter** (import script) — configurable API call throttling.
- **`-SkipSSLValidation` parameter** (import script) — for self-signed certificate environments.
- **Retry-on-transient-error** (import script) — exponential backoff for 5xx and 429 responses.
- **`Get-PropertyOrDefault` helper** (import script) — StrictMode-safe property access.
- **README.md** — GitHub project overview.
- **CHANGELOG.md** — this file.
- **Project tags** on the Resource Group for tracking.

### Changed

- **Node.js upgraded from 18 to 20 LTS.** Node 18 reached end-of-life April 2025.
- **wkhtmltopdf** download path corrected to the maintained `0.12.6.1-3` build; install uses `apt-get install -y` to resolve dependencies cleanly on Ubuntu 24.04.
- **Install script construction** rewritten as a PowerShell array joined with `"`n`"` to avoid here-string escaping pitfalls and ensure LF (not CRLF) line endings.
- **Password generation** now uses `System.Security.Cryptography.RandomNumberGenerator` instead of `Get-Random` for cryptographically strong randomness. Excludes visually ambiguous characters (`0`, `1`, `l`, `I`, `O`) and shell-hostile characters (`$`, `` ` ``, `'`, `"`, `&`).
- **MariaDB and ERPNext admin passwords** are now generated per-deployment instead of hardcoded.
- **`is_group` flag** (import script) now derived from actual presence of children in the imported dataset, not a depth heuristic. Categories with zero children become leaf groups regardless of nesting level.
- **404 exception handling** (import script) updated for PowerShell 7's `HttpResponseException` (different shape than 5.1's `WebException`).
- **Parameter validation** added to all parameters: regex patterns for VM names, usernames, CIDR blocks, URLs; range validation for disk size and timeouts.
- **`SupportsShouldProcess`** added to both scripts — `-WhatIf` and `-Confirm` are now supported on destructive operations.
- **Default ERPNext username** in documentation corrected from `JTCAdmin` to `Administrator` (the ERPNext default).
- **VM size in cost estimates** corrected from `Standard_D2s_v3` to `Standard_D2s_v6` to match the actual script default.
- **Quick Start Guide** rewritten to reflect the new end-to-end flow.

### Fixed

- **CRLF line endings** in the generated install script — bash on Linux rejects CRLF. Now explicitly written with UTF-8 (no BOM) and LF endings via `[System.IO.File]::WriteAllText`.
- **MariaDB secure-installation commands** no longer reference the post-password `mysql` invocation without authenticating — subsequent statements now use `mysql -u root -p"${MARIADB_ROOT_PW}"`.
- **StrictMode-safe property access** throughout the import script — previously, `$category.parent` on rows missing the column would throw under `Set-StrictMode -Version Latest`.
- **Trailing slash** on `-ERPNextURL` is now trimmed automatically to prevent doubled slashes in API endpoint paths.
- **API authentication header** generation handles empty or whitespace-padded keys consistently.

### Security

- Default plaintext credentials removed from the generated install script. All credentials are now generated per-deployment.
- Resource Group tagged with creator metadata for auditability.
- Boot diagnostics deliberately disabled by default to avoid creating an additional storage account requiring separate hardening.

---

## [1.0.0] - 2026-02-17

### Added

- Initial release of `Deploy-ERPNextToAzure.ps1`:
  - Azure VM provisioning on Ubuntu 24.04 LTS
  - ERPNext installation bash script generation (manual execution)
  - Network Security Group with rules for ports 22, 80, 443, 8000
  - Static Public IP assignment
  - Premium SSD managed disk
  - JSON connection info file output
- Initial release of `Import-ERPNextCategories.ps1`:
  - WooCommerce category Excel parsing via `ImportExcel`
  - REST API-based Item Group creation in ERPNext
  - Parent-child relationship preservation
  - Dry-run mode
  - Progress reporting and basic error handling
- `WooCommerce-Integration-Guide.md` — full integration reference
- `Data-Structure-Plan.md` — data migration plan
- `Quick-Start-Guide.md` — step-by-step walkthrough

---

[1.1.0]: https://github.com/JONeillSr/erpnext-azure/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/JONeillSr/erpnext-azure/releases/tag/v1.0.0
