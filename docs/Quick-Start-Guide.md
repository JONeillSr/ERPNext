# ERPNext Deployment - Quick Start Guide
## AWS Solutions LLC dba JT Custom Trailers

**Author:** John O'Neill Sr.
**Company:** Azure Innovators
**Original Create Date:** 02/17/2026
**Last Updated:** 05/16/2026
**Script Version:** 1.6.4 (deploy) / 1.3.1 (teardown)

---

## What You Have

A complete ERPNext deployment and WooCommerce integration package:

### Files in this package

1. **Deploy-ERPNextToAzure.ps1** v1.6.4 — End-to-end Azure VM deployment + ERPNext install
2. **Remove-ERPNextAzureDeployment.ps1** v1.3.1 — Teardown with KV purge and external subnet cleanup
3. **Select-AzureContext.ps1** v1.1.0 — Interactive tenant/subscription selector
4. **Import-ERPNextCategories.ps1** v1.1.0 — Category import from WooCommerce Excel export
5. **WooCommerce-Integration-Guide.md** v2.0.0 — Full integration documentation
6. **Data-Structure-Plan.md** v1.0.1 — Detailed data migration plan
7. **Quick-Start-Guide.md** v1.6.4 — This file
8. **README.md** — GitHub project overview
9. **CHANGELOG.md** — Version history

---

## What's New Since 1.5.0

### Private-network deployment is now first-class

**v1.6.x added** the ability to deploy ERPNext as a private-only VM with no public IP, designed for production access via VPN or VNet peering. The deploy script can now:
- Skip public IP creation (`-PrivateOnly`)
- Join an existing VNet rather than creating a fresh one (`-ExistingVNetName`)
- Create a subnet in that existing VNet at a CIDR you specify
- Tighten NSG rules to allow inbound only from the `VirtualNetwork` service tag

The matching teardown handles the corresponding subnet cleanup when ERPNext is removed.

### Ubuntu 24.04 install fixes

Multiple Frappe v15 / Ubuntu 24.04 compatibility issues were resolved across the 1.5.x series — PEP 668 enforcement requiring apt-installed Ansible, the supervisor handoff requiring two passes of `bench setup production`, and home directory permissions blocking nginx traversal. End-to-end deployment now completes reliably in 8-10 minutes on a fresh Ubuntu 24.04 image.

### Auto-renaming defaults

When you specify `-Location 'westus2'` (or any region other than eastus), the default RG and VM names automatically substitute the new region: `JTC-prod-erpnext-eastus-rg` becomes `JTC-prod-erpnext-westus2-rg`. Resources stay consistently named with where they actually live.

### Teardown reliability

The 1.2.x → 1.3.x series fixed two real bugs in the teardown script:
- Polling for the wrong job state (`Running` instead of waiting for terminal state) caused the script to silently exit in 0 seconds while reporting success
- Confirmation prompts inside the background-job runspace could leave the script `Blocked` forever; the runspace now has explicit `ConfirmPreference` suppression
- New orphaned-soft-deleted-vault warning surfaces when teardown leaves a Key Vault that wasn't purged

See [CHANGELOG.md](CHANGELOG.md) for the full history.

---

## Quick Start Steps

### Step 1: Deploy ERPNext to Azure (10-15 minutes)

**Prerequisites:**

```powershell
# PowerShell 7.2+ with Az modules installed
Connect-AzAccount

# If you have access to multiple tenants, select explicitly:
.\Select-AzureContext.ps1   # interactive picker
```

**Production deployment (recommended pattern):**

```powershell
.\Deploy-ERPNextToAzure.ps1 -ConfirmContext `
    -UseKeyVault -KeyVaultName 'JTC-prod-westus2-kv' `
    -Location 'westus2' `
    -PrivateOnly `
    -ExistingVNetName 'jtcustomtr-2e886f0313-vnet' `
    -ExistingVNetResourceGroup 'JTC-Prod-WP-WestUS2-rg'
```

**What this does (automatically):**

1. Pre-flight context check — you must confirm the target tenant/subscription
2. Verifies VM size availability in your chosen region
3. Creates `JTC-prod-erpnext-westus2-rg`
4. Creates Key Vault `JTC-prod-westus2-kv`, grants you Secrets Officer role, waits for RBAC propagation
5. Generates secure random passwords (24-28 chars) and stores in Key Vault
6. Creates NSG with VirtualNetwork-only rules — NO public ingress
7. Joins existing VNet, creates `erpnext-subnet` at `10.0.2.0/27`
8. Creates NIC with private IP only — no public IP
9. Provisions Ubuntu 24.04 VM (Standard_D2s_v6, Premium SSD)
10. Generates the install script and executes via Run Command (8-10 minutes)
11. Verifies port 8000 is listening before declaring success
12. Returns a structured result with private IP, KV references, and connection info

**Alternative: public IP deployment** (faster iteration, less secure):

```powershell
.\Deploy-ERPNextToAzure.ps1 -ConfirmContext `
    -UseKeyVault -KeyVaultName 'JTC-prod-eastus-kv' `
    -AllowedSourceCIDR '203.0.113.42/32'
```

Use this for dev/test only — never for production with customer data.

### Step 2: Access ERPNext

Output from the deploy script:

```
Private IP: 10.0.2.4 (no public IP - VPN/VNet access only)
Access ERPNext:
  URL:  http://10.0.2.4
        (reachable from VPN-connected clients or VNet-attached services)
  User: Administrator
```

**To reach it from your laptop**, you need one of:

| Option | How |
|---|---|
| **From your WordPress App Service** | Open Kudu console: `https://<wp-app>.scm.azurewebsites.net` → Debug Console → CMD → `curl http://10.0.2.4/` |
| **Azure VPN Gateway** | Set up P2S VPN to the VNet (one-time, separate work) — once connected, browse `http://10.0.2.4` directly |
| **Temporarily add public IP** | Portal → VM → Networking → Add public IP for one-time testing, then detach |
| **Azure Bastion** | If you have one in the VNet, use Bastion's tunnel feature |

**Pull the Administrator password from Key Vault:**

```powershell
$pw = Get-AzKeyVaultSecret `
    -VaultName 'JTC-prod-westus2-kv' `
    -Name 'JTC-prod-erpnext-westus2-vm-erpnext-admin-password' `
    -AsPlainText
$pw | Set-Clipboard
# Password is now in your clipboard, ready to paste into ERPNext login
```

**IMPORTANT:** Change the Administrator password immediately on first login (in ERPNext: My Settings → Change Password).

### Step 2.5: Add Let's Encrypt SSL (10 minutes — optional but recommended)

At this point you can log into ERPNext over plain HTTP at the VM's private IP. That works, but two reasons to upgrade to HTTPS at a proper hostname before going further:

1. **Browsers warn loudly about plain HTTP for form input.** Once you start configuring real user accounts and entering data, the "Not Secure" banner gets old fast.
2. **Bookmarks and integrations should point at a stable hostname**, not a private IP that could change if the VM is rebuilt.

The `Add-LetsEncryptSSL.ps1` script handles end-to-end SSL provisioning using a Let's Encrypt wildcard cert obtained via DNS-01 challenge. Because the ERPNext VM has no public IP (it's reached over VPN), HTTP-01 challenges won't work — but DNS-01 only needs the ability to write TXT records into your public DNS zone, which the script automates via a User-Assigned Managed Identity.

**Prerequisites for this step:**

- A **public DNS zone** for your domain hosted in Azure DNS (e.g., `awesomewildstuff.com` in resource group `AWS-Prod-EastUS-rg`)
- **VPN access to the ERPNext VM** for browser verification at the end (the script itself runs over Azure Run Command and doesn't need VPN)
- VPN-connected clients need a way to resolve your public FQDN to the VM's private IP — split-horizon DNS + a DNS forwarder. The [Setup-AzureP2SVPN repo](https://github.com/JONeillSr/Setup-AzureP2SVPN) has `Add-AzureSplitHorizonDNS.ps1` and `Add-AzureDNSForwarder.ps1` that handle this.

**The two-pass flow (recommended):**

```powershell
# Pass 1: Test with Let's Encrypt staging (no rate limits, untrusted cert, easy reset)
.\Add-LetsEncryptSSL.ps1 -ConfirmContext `
    -ERPNextVMName 'JTC-prod-erpnext-westus2-vm' `
    -ERPNextVMResourceGroup 'JTC-prod-erpnext-westus2-rg' `
    -PublicZoneName 'awesomewildstuff.com' `
    -PublicZoneResourceGroup 'AWS-Prod-EastUS-rg' `
    -PublicFQDN 'erpnext.awesomewildstuff.com' `
    -FrappeSiteDir 'jtcustomtrailers.local' `
    -ContactEmail 'admin@awesomewildstuff.com' `
    -UseStaging
```

After this completes, browse to `https://erpnext.awesomewildstuff.com` over VPN. You'll see a certificate warning because staging certs aren't publicly trusted — that's expected. Click through and you should see the ERPNext login screen served over HTTPS.

If everything looks right:

```powershell
# Pass 2: Re-run for a real, publicly-trusted production cert
.\Add-LetsEncryptSSL.ps1 -ConfirmContext `
    -ERPNextVMName 'JTC-prod-erpnext-westus2-vm' `
    -ERPNextVMResourceGroup 'JTC-prod-erpnext-westus2-rg' `
    -PublicZoneName 'awesomewildstuff.com' `
    -PublicZoneResourceGroup 'AWS-Prod-EastUS-rg' `
    -PublicFQDN 'erpnext.awesomewildstuff.com' `
    -FrappeSiteDir 'jtcustomtrailers.local' `
    -ContactEmail 'admin@awesomewildstuff.com'
```

The script detects the existing managed identity and just re-issues the cert against Let's Encrypt's production endpoint. After this completes, browse to `https://erpnext.awesomewildstuff.com` again — **green padlock, no warning**.

**What the script does (high level):**

1. Creates a User-Assigned Managed Identity in your subscription, attached to the ERPNext VM
2. Grants the identity **DNS Zone Contributor** on the public DNS zone (least privilege — only the specific zone, not the whole RG)
3. Installs certbot + the certbot-dns-azure plugin into a venv at `/opt/certbot` on the VM
4. Requests a wildcard cert for `*.<zone>` and `<zone>`
5. Updates `site_config.json` with the cert paths plus `host_name` and `domains` arrays
6. Switches Frappe to `dns_multitenant` mode (required for SSL listener generation)
7. Patches `/etc/nginx/nginx.conf` to define the `log_format main` that Frappe's generated config references
8. Runs `bench setup nginx --yes` to regenerate the nginx config with SSL listeners
9. Reloads nginx
10. Installs a systemd timer + deploy hook for automatic twice-daily renewal checks

The script is idempotent — safe to re-run if interrupted, and the renewal timer takes care of the cert lifecycle from this point on (90-day validity, auto-renewed at 60 days).

**Verification after Step 2.5:**

```powershell
# From your VPN-connected laptop:
Resolve-DnsName erpnext.awesomewildstuff.com
# Should return the private IP (e.g., 10.0.2.4)

# Browser test:
Start-Process 'https://erpnext.awesomewildstuff.com'
# Should load ERPNext login with green padlock - no warning, no fuss
```

If `Resolve-DnsName` returns the public IP or NXDOMAIN, that's a DNS issue — confirm split-horizon DNS + forwarder are set up (see the [Setup-AzureP2SVPN USER-GUIDE](https://github.com/JONeillSr/Setup-AzureP2SVPN/blob/main/USER-GUIDE.md#dns-for-vpn-clients)).

### Step 3: Initial ERPNext Configuration (15 minutes)

1. **Company Setup Wizard:**
   - Company Name: AWS Solutions LLC dba JT Custom Trailers
   - Country: United States
   - Currency: USD
   - Fiscal Year: January to December
   - Chart of Accounts: Standard USA

2. **Create API Keys:**
   - User avatar → My Settings → API Access → Generate Keys
   - Save the Key and Secret **immediately** — Secret is only displayed once
   - Store in Key Vault rather than a config file:
     ```powershell
     Set-AzKeyVaultSecret -VaultName 'JTC-prod-westus2-kv' `
         -Name 'erpnext-wc-integration-api-key' `
         -SecretValue (ConvertTo-SecureString 'YOUR_KEY' -AsPlainText -Force)
     # (and same for the secret)
     ```

3. **Basic Settings:**
   - System Settings → Time Zone: America/New_York
   - Date Format: MM/DD/YYYY
   - Enable email notifications

### Step 4: WooCommerce Integration Setup

> **Heads up:** The integration approach changed in late 2025 — the old `bench get-app woocommerceconnector` pattern is no longer recommended. ERPNext's built-in WooCommerce integration was deprecated in v15.
>
> **New approach:** Install the ERPNext Integration plugin in WordPress (it calls ERPNext, rather than the other way around). See `WooCommerce-Integration-Guide.md` v2.0.0 for the full procedure.

Quick version:

1. WordPress Admin → **Plugins → Add New** → search "ERPNext Integration" → Install + Activate
2. **ERPNext Integration → API Settings**:
   - Host URL: `http://10.0.2.4` (your private ERPNext IP)
   - API Key + Secret from Step 3
3. Test Connection → should show **Connected** (green)
4. **ERPNext Integration → Configurations**:
   - Company: AWS Solutions LLC dba JT Custom Trailers
   - Default Warehouse: Main Warehouse
   - Default Customer Group: Individual

### Step 5: Import Categories (15 minutes)

```powershell
Install-Module -Name ImportExcel -Force -Scope CurrentUser  # if not already installed

# Pull API credentials from Key Vault
$apiKey    = Get-AzKeyVaultSecret -VaultName 'JTC-prod-westus2-kv' -Name 'erpnext-wc-integration-api-key' -AsPlainText
$apiSecret = Get-AzKeyVaultSecret -VaultName 'JTC-prod-westus2-kv' -Name 'erpnext-wc-integration-api-secret' -AsPlainText

# Dry run first
.\Import-ERPNextCategories.ps1 `
    -ProductCategoriesPath .\ProductCategories.xlsx `
    -ERPNextURL "http://10.0.2.4" `
    -APIKey $apiKey -APISecret $apiSecret `
    -DryRun

# Real import
.\Import-ERPNextCategories.ps1 `
    -ProductCategoriesPath .\ProductCategories.xlsx `
    -ERPNextURL "http://10.0.2.4" `
    -APIKey $apiKey -APISecret $apiSecret
```

**Note:** The import must run from a machine that can reach `10.0.2.4` — either VPN-connected, or from inside the VNet.

### Step 6: Create Warehouses (5 minutes)

In ERPNext → Stock → Warehouse → New:

```
Warehouse Name:   Main Warehouse
Parent:           All Warehouses
Type:             Manufacturing
Address:          1214 Lake Avenue, Ashtabula, OH 44004

Warehouse Name:   Showroom - Jefferson
Parent:           All Warehouses
Type:             Retail
Address:          PO Box 348, Jefferson, OH 44047
```

### Step 7: Test Product Sync (10 minutes)

1. Create a test item in ERPNext:
   ```
   Item Code:       TEST-SYNC-001
   Item Name:       Test Product Sync
   Item Group:      Interior
   Standard Rate:   99.99
   Maintain Stock:  ✓
   Show in Website: ✓
   ```

2. Add opening stock (Stock → Stock Entry → Material Receipt) so the item has inventory

3. In WordPress: ERPNext Integration → Sync → Sync Now

4. Verify the product appears in WooCommerce → Products

5. Delete the test item from both systems

---

## Tearing Down

### Use the wrapper script, not raw cmdlets

```powershell
# Full teardown of the v1.6.x private-network deployment
.\Remove-ERPNextAzureDeployment.ps1 -Force -RemoveLocalArtifacts `
    -ResourceGroupName 'JTC-prod-erpnext-westus2-rg' `
    -KeyVaultName 'JTC-prod-westus2-kv' -PurgeKeyVault `
    -ExternalVNetName 'jtcustomtr-2e886f0313-vnet' `
    -ExternalVNetResourceGroup 'JTC-Prod-WP-WestUS2-rg'
```

This:
1. Deletes the ERPNext RG with proper progress polling (3-5 minutes)
2. Purges the soft-deleted Key Vault (otherwise the name is reserved 90 days)
3. Removes `erpnext-subnet` from the shared WordPress VNet
4. Cleans up local artifacts (install-erpnext.sh, old logs)
5. Shows a summary

### Without `-PurgeKeyVault`

If you forget `-PurgeKeyVault`, the vault is soft-deleted and reserved for 90 days. The teardown script will **warn you** at the end with the exact command to purge it:

```
---------------------------------------------------------------
NOTE: Soft-deleted Key Vault(s) remain
---------------------------------------------------------------
  JTC-prod-westus2-kv

  These vault names are reserved for 90 days by Azure's soft-delete.
  Re-deploying with the same name will fail until they are purged.

  To purge, re-run this script with:
    .\Remove-ERPNextAzureDeployment.ps1 -Force `
        -KeyVaultName 'JTC-prod-westus2-kv' -PurgeKeyVault
---------------------------------------------------------------
```

---

## Troubleshooting

### Deploy script fails before VM is created

The diagnostic dump in v1.5.1+ surfaces install errors directly. For network/resource-level failures, the error message is usually clear in the script output. Most common:

- **Wrong tenant/subscription** — re-run `Select-AzureContext.ps1` and pass `-ConfirmContext`
- **Key Vault name collision** — someone else (anywhere in Azure globally) took the name. Try a more specific name with your company/region.
- **Region/SKU not available** — try `-VMSize 'Standard_D2s_v5'` if D2s_v6 isn't in your region

### Deploy script fails during install (sentinel not found)

Look at the diagnostic dump in the script output. v1.5.1+ surfaces the actual bash error inline. If the dump is empty for some reason, pull the install log directly from the VM:

```powershell
Invoke-AzVMRunCommand -ResourceGroupName 'JTC-prod-erpnext-westus2-rg' `
    -VMName 'JTC-prod-erpnext-westus2-vm' `
    -CommandId RunShellScript `
    -ScriptString 'tail -200 /var/log/erpnext-install.log'
```

This works without network access — Run Command goes through Azure's control plane.

### Can't reach the VM after successful deploy

Since there's no public IP in `-PrivateOnly` mode:

1. **Verify the VM is healthy** via Run Command:
   ```powershell
   Invoke-AzVMRunCommand -ResourceGroupName 'JTC-prod-erpnext-westus2-rg' `
       -VMName 'JTC-prod-erpnext-westus2-vm' `
       -CommandId RunShellScript `
       -ScriptString 'curl -sI http://localhost/'
   ```
   Should return HTTP/200 or similar.

2. **From your WordPress App Service Kudu** (Debug Console → CMD):
   ```
   curl -v http://10.0.2.4/
   ```

3. **From your laptop**: need VPN connection to the VNet, or temporarily add a public IP via the portal for testing.

### Teardown reports "0 deleted" or hangs in Blocked state

You're running an older teardown script. Make sure you have **v1.3.1 or later** of `Remove-ERPNextAzureDeployment.ps1`. v1.2.0 had the polling bug (silent 0-second false success), v1.2.2 had the Blocked-state hang. Both are fixed in 1.3.1.

If you're truly stuck and need to nuke an RG right now, the emergency synchronous cleanup is:

```powershell
Remove-AzResourceGroup -Name 'JTC-prod-erpnext-westus2-rg' -Force -Confirm:$false
Remove-AzKeyVault -VaultName 'JTC-prod-westus2-kv' -Location 'westus2' -InRemovedState -Force
```

### WooCommerce integration not syncing

See **WooCommerce-Integration-Guide.md** § Troubleshooting. Common: API credentials incorrect, App Service can't reach the private IP (VNet integration not enabled), or background WP cron not running.

---

## Post-Installation Checklist

- [ ] ERPNext accessible at private IP (from VPN/VNet)
- [ ] Administrator password changed from the generated one
- [ ] Company information configured
- [ ] API keys generated and stored in Key Vault (never in config files)
- [ ] ERPNext Integration plugin installed and connected in WordPress
- [ ] Categories imported (200+ Item Groups)
- [ ] Warehouses created with correct addresses
- [ ] Test product syncs ERPNext → WooCommerce successfully
- [ ] Test order syncs WooCommerce → ERPNext successfully
- [ ] Backups configured (`bench backup` cron + Azure Backup for the VM)
- [ ] SSL configured if you need encrypted traffic even over the private VNet (Let's Encrypt with internal DNS, or front with App Gateway)
- [ ] Daily/weekly/monthly monitoring routine established

---

## Security Recommendations

**Immediate (during initial setup):**

- Change Administrator password
- Create per-user accounts in ERPNext — don't use Administrator for daily work
- Enable two-factor authentication on Administrator
- Store all credentials in Key Vault, not in config files

**Within the first week:**

- Set up automated daily backups to Azure Blob Storage
- **Configure SSL via `Add-LetsEncryptSSL.ps1`** — even over private VNet, encryption-in-transit is good practice; see Step 2.5 above for the full flow
- Consider Azure Backup for the VM (snapshots + retention)

**Ongoing:**

- Monthly `apt update && apt upgrade -y` on the VM
- Quarterly backup restore test (do a real restore to a throwaway environment)
- Review ERPNext Error Log weekly
- Rotate API keys yearly (or after any suspected credential exposure)

---

## Cost Estimate

| Item | Monthly |
|---|---|
| Standard_D2s_v6 VM (westus2) | ~$70 |
| 128 GB Premium SSD | ~$20 |
| Key Vault | ~$1 + minimal per-operation |
| Bandwidth (typical) | ~$5 |
| **Subtotal — ERPNext only** | **~$95** |

If you add an Azure VPN Gateway for access (separate concern):

| Item | Monthly |
|---|---|
| VPN Gateway Basic SKU | ~$30 |
| Or VpnGw1 SKU (better) | ~$140 |

**Versus QuickBooks Online Plus** ($100-$200/month + $11-30/user): ERPNext is cost-equivalent at the application layer and provides inventory, manufacturing, CRM, and HR included. Total cost-of-ownership wins meaningfully at scale.

---

## Important Locations

### On your local machine
```
Deploy-ERPNextToAzure.ps1                  Deployment script
Remove-ERPNextAzureDeployment.ps1          Teardown script
Select-AzureContext.ps1                    Interactive context selector
install-erpnext.sh                         Generated install script (per deploy)
Deploy-ERPNextToAzure_*.log                Deployment logs
Import-ERPNextCategories.ps1               Category import script
```

### On the Azure VM
```
/home/jtadmin/frappe-bench/                Main ERPNext directory
/home/jtadmin/frappe-bench/sites/          Site configurations
/home/jtadmin/frappe-bench/logs/           Application logs
/var/log/erpnext-install.log               Install log (this deployment)
/etc/nginx/                                Web server config
/etc/supervisor/conf.d/                    Process management
/etc/supervisor/conf.d/frappe-bench.conf  → ~/frappe-bench/config/supervisor.conf
```

### In Azure
```
RG: JTC-prod-erpnext-westus2-rg            Everything ERPNext-specific
VNet: jtcustomtr-2e886f0313-vnet            Shared (lives in WP RG)
Subnet: erpnext-subnet                     Inside shared VNet at 10.0.2.0/27
KV: JTC-prod-westus2-kv                    All ERPNext secrets
```

---

## Getting Help

- ERPNext Docs: https://docs.erpnext.com/
- Frappe Framework: https://frappeframework.com/docs
- WooCommerce REST API: https://woocommerce.github.io/woocommerce-rest-api-docs/
- ERPNext Forum: https://discuss.erpnext.com/
- Frappe Forum: https://discuss.frappe.io/
- GitHub: https://github.com/JONeillSr/

**Contact:** John O'Neill Sr. — JONeillSr@jtcustomtrailers.com — (440) 813-6695

---

**Quick Start Guide Version:** 1.6.4
**Last Updated:** 05/16/2026
