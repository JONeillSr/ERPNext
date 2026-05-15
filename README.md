# ERPNext Azure Deployment Toolkit

End-to-end PowerShell automation for deploying [ERPNext](https://erpnext.com/) on Microsoft Azure, with WooCommerce category import and integration guidance.

[![PowerShell](https://img.shields.io/badge/PowerShell-7.2%2B-5391FE.svg)](https://github.com/PowerShell/PowerShell)
[![Azure](https://img.shields.io/badge/Azure-Compatible-0078D4.svg)](https://azure.microsoft.com/)
[![ERPNext](https://img.shields.io/badge/ERPNext-v15-1F8FE5.svg)](https://erpnext.com/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

---

## What's in this repo

| File | Purpose |
|---|---|
| **Deploy-ERPNextToAzure.ps1** | Provisions an Azure VM and installs ERPNext end-to-end |
| **Remove-ERPNextAzureDeployment.ps1** | Tears down resources for clean re-testing |
| **Import-ERPNextCategories.ps1** | Imports WooCommerce category hierarchy into ERPNext Item Groups |
| **Quick-Start-Guide.md** | Step-by-step deployment walkthrough |
| **WooCommerce-Integration-Guide.md** | Full WooCommerce ↔ ERPNext integration reference |
| **Data-Structure-Plan.md** | Data migration planning document |
| **CHANGELOG.md** | Version history |

---

## What it does

**`Deploy-ERPNextToAzure.ps1`** stands up a production-ready ERPNext instance on a fresh Azure VM in a single command. It:

- Pre-flights your Azure context, region, and VM SKU availability
- Creates (or reuses) the Resource Group, VNet, Subnet, NSG, Public IP, and NIC
- Generates strong random passwords for VM, MariaDB root, and ERPNext admin
- Optionally stores all secrets in **Azure Key Vault** instead of a local JSON file
- Optionally configures **SSH key authentication** in place of passwords
- Optionally scopes NSG rules to a **single source IP/CIDR** instead of the public internet
- Provisions an Ubuntu 24.04 LTS VM with Premium SSD
- Executes the ERPNext install on the VM via `Invoke-AzVMRunCommand` — no manual SCP/SSH needed
- Installs MariaDB, Redis, Nginx, Supervisor, Node.js 20 LTS, Yarn, wkhtmltopdf, Frappe Bench, ERPNext v15, and HRMS
- Returns a structured result object and writes a connection-info file

The script is **idempotent** — safe to re-run after a partial failure. Resources that already exist are detected and skipped.

**`Import-ERPNextCategories.ps1`** reads a WooCommerce category export (Excel) and creates the matching Item Group hierarchy in ERPNext via REST API, preserving parent-child relationships and setting the `is_group` flag based on the actual presence of children.

**`Remove-ERPNextAzureDeployment.ps1`** tears down what the deploy script created so you can re-test from a clean slate. It handles two modes (whole-RG nuke or selective per-resource), detects and optionally removes resource locks, deals correctly with Key Vault soft-delete (including the optional purge step to free the vault name immediately), and can clean up local artifacts (connection-info JSON, generated install script, log files).

---

## Prerequisites

- **PowerShell 7.2 or later** (Windows, Linux, or macOS)
- **Azure PowerShell modules:** `Az.Accounts`, `Az.Compute`, `Az.Network`, `Az.Resources` (and `Az.KeyVault` if using `-UseKeyVault`)
- **An active Azure subscription** with Contributor rights on the target Resource Group
- **`Connect-AzAccount`** run prior to executing the script
- For category import: the **`ImportExcel`** module (`Install-Module -Name ImportExcel`)

---

## Quick start

```powershell
# 1. Connect to Azure
Connect-AzAccount

# 2. Deploy (defaults work for a quick test)
.\Deploy-ERPNextToAzure.ps1

# 3. Production-grade deployment
.\Deploy-ERPNextToAzure.ps1 `
    -ResourceGroupName 'JTC-prod-erpnext-eastus-rg' `
    -VMName            'JTC-prod-erpnext-eastus-vm' `
    -Location          'eastus' `
    -AllowedSourceCIDR '203.0.113.42/32' `
    -UseSSHKey -SSHPublicKeyPath "$HOME/.ssh/id_rsa.pub" `
    -UseKeyVault -KeyVaultName 'JTC-prod-kv-eastus'
```

Full walkthrough: [Quick-Start-Guide.md](Quick-Start-Guide.md).

---

## Parameters at a glance

### `Deploy-ERPNextToAzure.ps1`

| Parameter | Default | Notes |
|---|---|---|
| `-ResourceGroupName` | `JTC-prod-erpnext-eastus-rg` | Created if missing |
| `-VMName` | `JTC-prod-erpnext-eastus-vm` | Used as base for NIC/NSG/PIP/VNet names |
| `-Location` | `eastus` | Any Azure region supporting the VM SKU |
| `-VMSize` | `Standard_D2s_v6` | 2 vCPU, 8 GB — good for up to ~25 users |
| `-AdminUsername` | `jtadmin` | Lowercase, no special chars |
| `-DiskSize` | `128` | GB; Premium SSD |
| `-SubscriptionId` | (current) | Override the active context's subscription |
| `-AllowedSourceCIDR` | `*` | **Set this for production**, e.g. `203.0.113.42/32` |
| `-UseSSHKey` | off | Requires `-SSHPublicKeyPath` |
| `-SSHPublicKeyPath` | — | Path to public key, e.g. `~/.ssh/id_rsa.pub` |
| `-UseKeyVault` | off | Requires `-KeyVaultName` and `Az.KeyVault` module |
| `-KeyVaultName` | — | Vault created if missing |
| `-SkipInstall` | off | Provision infrastructure only |
| `-InstallTimeoutMinutes` | `60` | Run Command timeout |

### `Import-ERPNextCategories.ps1`

| Parameter | Default | Notes |
|---|---|---|
| `-ProductCategoriesPath` | (required) | Excel file with category data |
| `-ERPNextURL` | (required) | e.g. `http://20.85.123.45` |
| `-APIKey` | (required) | From ERPNext User → API Access |
| `-APISecret` | (required) | Shown only once at generation |
| `-DryRun` | off | Print plan without making changes |
| `-ThrottleMilliseconds` | `100` | Delay between API calls |
| `-SkipSSLValidation` | off | Self-signed cert support |

### `Remove-ERPNextAzureDeployment.ps1`

| Parameter | Default | Notes |
|---|---|---|
| `-ResourceGroupName` | `JTC-prod-erpnext-eastus-rg` | RG to remove |
| `-VMName` | `JTC-prod-erpnext-eastus-vm` | Only used in `-Selective` mode |
| `-Selective` | off | Delete only this VM's resources, not the whole RG |
| `-KeyVaultName` | — | Required if the deploy used `-UseKeyVault` |
| `-PurgeKeyVault` | off | Purges soft-deleted vault to free the name |
| `-RemoveLocks` | off | Auto-remove blocking delete/read locks |
| `-RemoveLocalArtifacts` | off | Clean up `*.log`, `*.json`, `*.sh` files |
| `-Force` | off | Skip interactive confirmation |
| `-AcknowledgeProductionRisk` | off | Required for `Environment=Production` subscriptions |
| `-TimeoutMinutes` | `30` | Wait limit for RG deletion |

**Common teardown patterns:**

```powershell
# Dry-run first to see exactly what would be deleted
.\Remove-ERPNextAzureDeployment.ps1 -WhatIf

# Full clean-slate teardown for re-testing (with Key Vault purge)
.\Remove-ERPNextAzureDeployment.ps1 -Force `
    -KeyVaultName 'JTC-prod-kv-eastus' -PurgeKeyVault `
    -RemoveLocalArtifacts

# Selective: just the VM and its networking, leave RG intact
.\Remove-ERPNextAzureDeployment.ps1 -Selective -Force
```

---

## Architecture

```
                    ┌──────────────────────────────────────┐
                    │   Your workstation (PowerShell 7)    │
                    │   Deploy-ERPNextToAzure.ps1          │
                    └────────────────┬─────────────────────┘
                                     │  Az PowerShell + Invoke-AzVMRunCommand
                                     ▼
        ┌────────────────────────────────────────────────────────┐
        │                Azure Resource Group                    │
        │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
        │  │ Public IP    │──│ NSG (scoped) │──│ NIC          │  │
        │  └──────────────┘  └──────────────┘  └──────┬───────┘  │
        │                                             │          │
        │              ┌──────────────────────────────▼───────┐  │
        │              │  Ubuntu 24.04 VM (Standard_D2s_v6)   │  │
        │              │  - MariaDB                            │  │
        │              │  - Redis                              │  │
        │              │  - Nginx + Supervisor                 │  │
        │              │  - Node.js 20, Yarn, wkhtmltopdf      │  │
        │              │  - Frappe Bench + ERPNext v15 + HRMS  │  │
        │              └───────────────────────────────────────┘  │
        │  ┌──────────────────────────────────────────────────┐   │
        │  │  Key Vault (optional)                            │   │
        │  │  - VM admin password                             │   │
        │  │  - MariaDB root password                         │   │
        │  │  - ERPNext admin password                        │   │
        │  └──────────────────────────────────────────────────┘   │
        └────────────────────────────────────────────────────────┘
```

---

## Security notes

- **Default NSG is open to the public internet.** Always set `-AllowedSourceCIDR` for any non-throwaway deployment.
- **Default authentication is password.** Use `-UseSSHKey` for production.
- **Default secret storage is a local JSON file.** Use `-UseKeyVault` to keep secrets in Azure Key Vault.
- The generated install script writes its log to `/var/log/erpnext-install.log` on the VM.
- Default ERPNext admin user is `Administrator`. Change the password on first login and create per-user accounts for daily work.

---

## Cost estimate (eastus, retail pricing)

| Resource | Monthly |
|---|---|
| Standard_D2s_v6 VM (2 vCPU, 8 GB) | ~$70 |
| 128 GB Premium SSD | ~$20 |
| Static Public IP (Standard) | ~$4 |
| Outbound bandwidth (typical) | ~$5 |
| **Total** | **~$100** |

Key Vault adds ~$0.03 per 10,000 operations — effectively free for this use case.

---

## Troubleshooting

The deployment script writes a timestamped log file in the same directory it runs from: `Deploy-ERPNextToAzure_YYYYMMDD_HHMMSS.log`.

Retrieve the install log from the VM after deployment:

```powershell
Invoke-AzVMRunCommand -ResourceGroupName 'JTC-prod-erpnext-eastus-rg' `
    -VMName 'JTC-prod-erpnext-eastus-vm' `
    -CommandId RunShellScript `
    -ScriptString 'tail -200 /var/log/erpnext-install.log'
```

See [Quick-Start-Guide.md](Quick-Start-Guide.md#troubleshooting) for full troubleshooting steps.

---

## Versioning

This project follows [Semantic Versioning](https://semver.org/). See [CHANGELOG.md](CHANGELOG.md) for full history.

---

## Author

**John O'Neill Sr.**
Chief Innovation Officer, Azure Innovators
GitHub: [@JONeillSr](https://github.com/JONeillSr/)

---

## License

MIT — see [LICENSE](LICENSE).
