# ERPNext Deployment - Quick Start Guide
## AWS Solutions LLC dba JT Custom Trailers

**Author:** John O'Neill Sr.
**Company:** Azure Innovators
**Updated:** 05/16/2026
**Script Version:** 1.5.0

---

## What You Have

A complete ERPNext deployment and WooCommerce integration package:

### Files in this package

1. **Deploy-ERPNextToAzure.ps1** — End-to-end Azure VM deployment + ERPNext install
2. **Import-ERPNextCategories.ps1** — Category import from WooCommerce Excel export
3. **WooCommerce-Integration-Guide.md** — Full integration documentation
4. **Data-Structure-Plan.md** — Detailed data migration plan
5. **Quick-Start-Guide.md** — This file
6. **README.md** — GitHub project overview
7. **CHANGELOG.md** — Version history

---

## What's New in 1.5.0

End-to-end deployment is now genuinely reliable. Headline changes since 1.1.0:

- **Multi-tenant safety.** New `-TenantId`, `-SubscriptionId`, `-SelectContext`, and `-ConfirmContext` parameters protect you from deploying into the wrong client's tenant when you're authenticated against several. The script will refuse to proceed without explicit confirmation when ambiguity exists.
- **Key Vault auto-RBAC.** When you pass `-UseKeyVault`, the script creates the vault, grants you the Key Vault Secrets Officer role automatically, polls for RBAC propagation, and self-heals from stale Az token cache issues. You no longer need to pre-provision permissions on the vault.
- **Real install success detection.** The bash install on the VM emits a sentinel line only after every step completes. The deploy script scans for that sentinel before declaring success, so silent failures mid-install no longer get reported as "deployed successfully."
- **Diagnostic dumps on failure.** When the install does fail, you get the last 50 lines of stdout, all stderr, and the exact command to retrieve the full log from the VM, all surfaced in the deploy output.
- **Frappe v15 install fixes.** Dynamic Redis discovery (port assignments and config files vary between Frappe versions), proper Redis startup before `bench new-site`, and supervisor handoff after site creation.

See [CHANGELOG.md](CHANGELOG.md) for the full history including the patch-level debugging story that produced these capabilities.

---

## Earlier Highlights (from 1.1.0)

- Deployment is **end-to-end** — no manual SCP/SSH; install runs automatically via `Invoke-AzVMRunCommand`. Use `-SkipInstall` to defer
- All passwords dynamically generated (no hardcoded defaults)
- Optional Azure Key Vault storage for secrets (`-UseKeyVault`)
- Optional SSH key authentication (`-UseSSHKey`)
- Optional source-IP restriction on NSG rules (`-AllowedSourceCIDR`)
- Idempotent — safe to re-run if a deployment fails partway through
- Node.js 20 LTS, Ubuntu 24.04 alignment throughout

---

## Quick Start Steps

### Step 1: Deploy ERPNext to Azure (45-75 minutes total)

```powershell
# From PowerShell 7.2+ with Az modules installed
Connect-AzAccount

# Basic run (defaults: D2s_v6, eastus, password auth, local JSON secrets)
.\Deploy-ERPNextToAzure.ps1
```

**Production-grade run** (recommended):

```powershell
.\Deploy-ERPNextToAzure.ps1 `
    -ResourceGroupName "JTC-prod-erpnext-eastus-rg" `
    -VMName "JTC-prod-erpnext-eastus-vm" `
    -Location "eastus" `
    -AdminUsername "jtadmin" `
    -AllowedSourceCIDR "203.0.113.42/32" `
    -UseSSHKey -SSHPublicKeyPath "$HOME\.ssh\id_rsa.pub" `
    -UseKeyVault -KeyVaultName "JTC-prod-kv-eastus"
```

**What this does (automatically):**

1. Pre-flight checks (Az context, providers, region/size validation)
2. Creates the Resource Group (if missing) with project tags
3. Creates NSG, Public IP, VNet, Subnet, NIC (idempotent — skips if present)
4. Generates secure random passwords (24-28 chars, mixed classes)
5. Provisions Ubuntu 24.04 LTS VM with Premium SSD
6. Stores secrets in Key Vault (or local JSON if not using Key Vault)
7. Generates the install script
8. Executes the install on the VM via Run Command (20-40 minutes)
9. Returns a structured result object and writes `erpnext-connection-info.json`

**Output:** A connection-info file (or Key Vault secrets) containing public IP, admin user, ERPNext URL, and credentials.

### Step 2: Access ERPNext

After the script finishes:

```
URL: http://[YOUR-VM-IP]
Username: Administrator
Password: (from erpnext-connection-info.json or Key Vault)
```

**IMPORTANT:** Change the Administrator password immediately on first login.

### Step 3: Initial ERPNext Configuration (15 minutes)

1. **Company Setup Wizard:**
   - Company Name: AWS Solutions LLC dba JT Custom Trailers
   - Country: United States
   - Currency: USD
   - Fiscal Year: January to December
   - Chart of Accounts: Standard USA

2. **Create API Keys:**
   - Click your user icon → My Settings → API Access → Generate Keys
   - Save the Key and Secret immediately — the Secret is only displayed once

3. **Basic Settings:**
   - System Settings → Time Zone: America/New_York
   - Date Format: MM/DD/YYYY
   - Enable email notifications

### Step 4: WooCommerce API Setup (10 minutes)

1. **In WordPress Admin:**
   - WooCommerce → Settings → Advanced → REST API → Add Key
   - Description: ERPNext Integration
   - User: an admin user
   - Permissions: Read/Write
   - Save Consumer Key and Consumer Secret

2. **Test the connection from PowerShell:**
   ```powershell
   $apiUrl = "https://www.jtcustomtrailers.com/wp-json/wc/v3/products"
   $cred = "ck_YOUR_KEY:cs_YOUR_SECRET"
   $encoded = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($cred))
   Invoke-RestMethod -Uri $apiUrl -Headers @{ Authorization = "Basic $encoded" }
   ```

### Step 5: Install WooCommerce Connector (5 minutes)

SSH into the VM:

```powershell
$info = Get-Content .\erpnext-connection-info.json | ConvertFrom-Json
ssh "$($info.AdminUsername)@$($info.PublicIP)"
```

On the VM:

```bash
cd /home/jtadmin/frappe-bench
bench get-app woocommerceconnector
bench --site jtcustomtrailers.local install-app woocommerceconnector
bench restart
```

### Step 6: Configure WooCommerce Integration (10 minutes)

In ERPNext, search "WooCommerce Settings" and configure:

```
Enable Sync: ✓
WooCommerce Server URL: https://www.jtcustomtrailers.com
API Consumer Key: [from WordPress]
API Consumer Secret: [from WordPress]
Enable Item Sync: ✓
Enable Order Sync: ✓
Warehouse: Main Warehouse
Company: JT Custom Trailers
```

### Step 7: Import Categories (15 minutes)

```powershell
Install-Module -Name ImportExcel -Force  # If not already installed

$apiKey = "YOUR_ERPNEXT_API_KEY"
$apiSecret = "YOUR_ERPNEXT_API_SECRET"

# Dry run first
.\Import-ERPNextCategories.ps1 `
    -ProductCategoriesPath .\ProductCategories.xlsx `
    -ERPNextURL "http://YOUR-VM-IP" `
    -APIKey $apiKey -APISecret $apiSecret `
    -DryRun

# Real import
.\Import-ERPNextCategories.ps1 `
    -ProductCategoriesPath .\ProductCategories.xlsx `
    -ERPNextURL "http://YOUR-VM-IP" `
    -APIKey $apiKey -APISecret $apiSecret
```

### Step 8: Create Warehouses (5 minutes)

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

### Step 9: Test Product Sync (10 minutes)

1. **Create a test item in ERPNext:**
   ```
   Item Code:       TEST-SYNC-001
   Item Name:       Test Product Sync
   Item Group:      Interior
   Standard Rate:   99.99
   Show in Website: ✓
   Opening Stock:   10 (Main Warehouse)
   ```

2. Trigger sync: WooCommerce Settings → Sync Now
3. Verify the product appears in WooCommerce
4. Delete the test item from both systems

---

## Troubleshooting

### Can't connect to the VM

```powershell
Get-AzVM -ResourceGroupName "JTC-prod-erpnext-eastus-rg" -Name "JTC-prod-erpnext-eastus-vm"
Test-NetConnection -ComputerName YOUR-VM-IP -Port 22
Test-NetConnection -ComputerName YOUR-VM-IP -Port 80
```

Check:
- NSG allows 22, 80, 443, 8000 from your source IP
- VM is in `running` state
- If you used `-AllowedSourceCIDR`, your current IP is within that range

### ERPNext installation fails (Run Command path)

```powershell
# Retrieve the install log from the VM
Invoke-AzVMRunCommand -ResourceGroupName "JTC-prod-erpnext-eastus-rg" `
    -VMName "JTC-prod-erpnext-eastus-vm" `
    -CommandId RunShellScript `
    -ScriptString "tail -200 /var/log/erpnext-install.log"
```

Common fixes (on VM):

```bash
sudo systemctl restart mariadb
sudo systemctl restart redis-server
sudo supervisorctl restart all

# Nuclear option — reinstall bench
cd /home/jtadmin
rm -rf frappe-bench
bench init frappe-bench --frappe-branch version-15
```

### WooCommerce API connection issues

```bash
curl -u "ck_KEY:cs_SECRET" https://www.jtcustomtrailers.com/wp-json/wc/v3/products
```

Check:
- WordPress SSL certificate is valid
- API keys correct, with Read/Write permission
- VM outbound to HTTPS allowed (default Azure: yes)

### Category import errors

```powershell
Test-Path .\ProductCategories.xlsx
Get-Module -Name ImportExcel -ListAvailable

Invoke-RestMethod -Uri "http://YOUR-VM-IP/api/method/frappe.auth.get_logged_user" `
    -Headers @{ Authorization = "token $apiKey`:$apiSecret" }
```

---

## Post-Installation Checklist

- [ ] ERPNext accessible at VM IP
- [ ] Administrator password changed
- [ ] Company information configured
- [ ] API keys generated and stored securely
- [ ] WooCommerce API connected
- [ ] WooCommerce Connector installed
- [ ] Categories imported (200+ Item Groups)
- [ ] Warehouses created
- [ ] Test product syncs successfully
- [ ] Test order processes end-to-end
- [ ] Backups configured (`bench backup` cron or Azure Backup)
- [ ] SSL certificate installed (Let's Encrypt or Azure App Gateway)
- [ ] Source IP restriction in place (`-AllowedSourceCIDR`)
- [ ] Secrets moved to Key Vault if not already

---

## Security Recommendations

**Immediate:**
- Change Administrator password
- Create per-user accounts (don't use Administrator for daily work)
- Enable two-factor authentication in ERPNext

**Soon:**
- Install SSL via Let's Encrypt: `sudo -H bench setup lets-encrypt jtcustomtrailers.local`
- Configure automated backups to Azure Blob Storage
- Rotate the credentials in `erpnext-connection-info.json` into Key Vault if you didn't use `-UseKeyVault`

**Ongoing:**
- Monthly `apt update && apt upgrade`
- Monitor `/var/log/erpnext-install.log` and `bench logs`
- Quarterly backup restore test

---

## Cost Estimate

| Item                       | Monthly |
|----------------------------|---------|
| Standard_D2s_v6 VM         | ~$70    |
| 128 GB Premium SSD         | ~$20    |
| Static Public IP           | ~$4     |
| Bandwidth (typical)        | ~$5     |
| **Total**                  | **~$100** |

vs QuickBooks Online Plus ($100-$200/month + per-user): ERPNext is cost-equivalent at scale and includes inventory, manufacturing, CRM, and HR.

---

## Important Locations

### On your local machine
```
Deploy-ERPNextToAzure.ps1                  Deployment script
install-erpnext.sh                          Generated install script
erpnext-connection-info.json                Connection details (if not using Key Vault)
Deploy-ERPNextToAzure_*.log                 Deployment logs
Import-ERPNextCategories.ps1                Category import script
```

### On the Azure VM
```
/home/jtadmin/frappe-bench/                 Main ERPNext directory
/home/jtadmin/frappe-bench/sites/           Site configurations
/home/jtadmin/frappe-bench/logs/            Application logs
/var/log/erpnext-install.log                Install log (this deployment)
/etc/nginx/                                 Web server config
/etc/supervisor/conf.d/                     Process management
```

---

## Getting Help

- ERPNext Docs: https://docs.erpnext.com/
- Frappe Framework: https://frappeframework.com/docs
- WooCommerce REST API: https://woocommerce.github.io/woocommerce-rest-api-docs/
- ERPNext Forum: https://discuss.erpnext.com/
- GitHub: https://github.com/JONeillSr/

**Contact:** John O'Neill Sr. — JONeillSr@jtcustomtrailers.com — (440) 813-6695

---

**Quick Start Guide Version:** 1.5.0
**Last Updated:** 05/15/2026
