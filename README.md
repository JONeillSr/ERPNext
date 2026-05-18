# ERPNext Azure Deployment Toolkit

End-to-end PowerShell automation for deploying [ERPNext](https://erpnext.com/) on Microsoft Azure, with WooCommerce category import and integration guidance.
[![PSScriptAnalyzer](https://github.com/JONeillSr/ERPNext/actions/workflows/lint.yml/badge.svg)](https://github.com/JONeillSr/ERPNext/actions/workflows/lint.yml)
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
| **Add-LetsEncryptSSL.ps1** | Adds Let's Encrypt wildcard SSL via DNS-01 + managed identity |
| **Import-ERPNextCategories.ps1** | Imports WooCommerce category hierarchy into ERPNext Item Groups |
| **Select-AzureContext.ps1** | Helper for switching Azure contexts across tenants/subscriptions |
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

**`Add-LetsEncryptSSL.ps1`** adds production-grade SSL to a deployed ERPNext instance using a Let's Encrypt wildcard certificate. Because the typical Azure Innovators deployment puts ERPNext on a private IP behind a VPN (not the public internet), HTTP-01 challenges aren't viable. The script uses the DNS-01 challenge with Azure DNS, authenticated via a User-Assigned Managed Identity attached to the ERPNext VM — no service principal secrets to manage. After provisioning the cert, the script configures Frappe's `site_config.json`, regenerates nginx, and installs a systemd timer for automatic twice-daily renewal checks. Run it once after the initial deployment.

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

# 4. (Optional) Add Let's Encrypt SSL after deployment
.\Add-LetsEncryptSSL.ps1 -ConfirmContext `
    -ERPNextVMName 'JTC-prod-erpnext-eastus-vm' `
    -ERPNextVMResourceGroup 'JTC-prod-erpnext-eastus-rg' `
    -PublicZoneName 'contoso.com' `
    -PublicZoneResourceGroup 'contoso-dns-rg' `
    -PublicFQDN 'erpnext.contoso.com' `
    -ContactEmail 'admin@contoso.com'
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

### `Add-LetsEncryptSSL.ps1`

| Parameter | Default | Notes |
|---|---|---|
| `-ERPNextVMName` | (required) | Name of the ERPNext VM to add SSL to |
| `-ERPNextVMResourceGroup` | (required) | RG containing the ERPNext VM |
| `-PublicZoneName` | (required) | Public DNS zone in Azure DNS (e.g., `contoso.com`) |
| `-PublicZoneResourceGroup` | (required) | RG containing the public DNS zone |
| `-ContactEmail` | (required) | Email Let's Encrypt associates with the account |
| `-PublicFQDN` | (required) | Public hostname users will type (e.g., `erpnext.contoso.com`) |
| `-FrappeSiteDir` | auto-detect | Frappe site directory under `frappe-bench/sites/` (often differs from FQDN) |
| `-FrappeAdminUser` | `jtadmin` | Linux user that owns `frappe-bench` |
| `-FrappeBenchPath` | `/home/<user>/frappe-bench` | Override if your install is elsewhere |
| `-ManagedIdentityName` | derived | Name for the auto-created User-Assigned Managed Identity |
| `-ManagedIdentityResourceGroup` | = ERPNextVMResourceGroup | RG for the managed identity |
| `-UseStaging` | off | Use Let's Encrypt staging (untrusted certs, no rate limits) |
| `-ForceRenewal` | off | Force re-issue of existing certificate |
| `-NamePrefix` | derived from VM | Prefix for derived resource names |
| `-ConfirmContext` | off | Multi-tenant safety bypass |
| `-TenantId`, `-SubscriptionId` | current | Override Azure context |

**Common SSL provisioning flow:**

```powershell
# Step 1: Test with Let's Encrypt staging first (avoids burning prod rate limits)
.\Add-LetsEncryptSSL.ps1 -ConfirmContext `
    -ERPNextVMName 'JTC-prod-erpnext-westus2-vm' `
    -ERPNextVMResourceGroup 'JTC-prod-erpnext-westus2-rg' `
    -PublicZoneName 'awesomewildstuff.com' `
    -PublicZoneResourceGroup 'AWS-Prod-EastUS-rg' `
    -PublicFQDN 'erpnext.awesomewildstuff.com' `
    -FrappeSiteDir 'jtcustomtrailers.local' `
    -ContactEmail 'admin@awesomewildstuff.com' `
    -UseStaging

# Step 2: Once verified, re-run for a real production cert
# (drop -UseStaging; the script will detect existing identity and just re-issue)
.\Add-LetsEncryptSSL.ps1 -ConfirmContext `
    -ERPNextVMName 'JTC-prod-erpnext-westus2-vm' `
    -ERPNextVMResourceGroup 'JTC-prod-erpnext-westus2-rg' `
    -PublicZoneName 'awesomewildstuff.com' `
    -PublicZoneResourceGroup 'AWS-Prod-EastUS-rg' `
    -PublicFQDN 'erpnext.awesomewildstuff.com' `
    -FrappeSiteDir 'jtcustomtrailers.local' `
    -ContactEmail 'admin@awesomewildstuff.com'
```

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

## Multi-tenant / consultant workflow

If you're a consultant or MSP engineer with access to multiple Azure tenants and subscriptions, the scripts include several safeguards to keep client environments from getting mixed up:

**Display context before action.** Every script prints the resolved account, tenant, and subscription in a banner before any resource operation. Wrong-tenant runs are obvious immediately.

**Explicit targeting parameters:**

```powershell
# Pin to a specific tenant and subscription regardless of active context
.\Deploy-ERPNextToAzure.ps1 `
    -TenantId       '11111111-2222-3333-4444-555555555555' `
    -SubscriptionId '66666666-7777-8888-9999-000000000000'
```

**Interactive subscription picker.** Pass `-SelectContext` to any of the deploy or teardown scripts and you'll get a numbered list of accessible subscriptions across all tenants — choose one before the script proceeds.

**Multi-tenant safety gate (deploy script).** If your account has access to more than one subscription and you don't pin one with `-SubscriptionId` or `-SelectContext`, the deploy script refuses to run unless you pass `-ConfirmContext`. This prevents silently provisioning into the wrong client's tenant when your default context isn't what you think it is.

**Cross-subscription RG search (teardown script).** If the teardown can't find the target Resource Group in the active subscription, it automatically searches all your accessible subscriptions and reports exactly which one contains the RG, with the precise `-SubscriptionId` command to re-run.

**Standalone context helper:**

```powershell
# List all accessible subscriptions
.\Select-AzureContext.ps1 -ListOnly

# Interactive picker
.\Select-AzureContext.ps1

# Search by partial name
.\Select-AzureContext.ps1 -SearchName 'JT Custom'

# Switch and save for one-line restore later
.\Select-AzureContext.ps1 -SubscriptionId 'f9c9501f-...' -SaveAs 'JTCustomTrailers-Prod'
# Later: Select-AzContext -Name 'JTCustomTrailers-Prod'
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
- **Key Vault requires role-assignment rights.** When `-UseKeyVault` is used, the running identity needs **Owner** or **User Access Administrator** on the Resource Group (not just Contributor) so the script can grant itself the *Key Vault Secrets Officer* role on the vault for data-plane access. The script detects insufficient permissions and provides clear remediation steps if this is missing.
- **Default access is HTTP only (no TLS).** For any non-throwaway deployment, run `Add-LetsEncryptSSL.ps1` after the initial install. The script provisions a Let's Encrypt wildcard cert via DNS-01 challenge (works behind a VPN where HTTP-01 isn't viable), configures Frappe's `site_config.json`, regenerates nginx, and installs a systemd timer for automatic renewal. Authentication to Azure DNS uses a User-Assigned Managed Identity scoped to the zone — no service principal secrets to manage.
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
