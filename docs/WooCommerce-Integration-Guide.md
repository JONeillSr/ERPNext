# ERPNext - WooCommerce Integration Guide
## JT Custom Trailers

**Author:** John O'Neill Sr.
**Company:** Azure Innovators
**Original Create Date:** 02/17/2026
**Last Updated:** 05/16/2026
**Version:** 2.0.0

---

## What's new in 2.0

This guide has been substantially rewritten since 1.0.0 to reflect changes in both the ERPNext ecosystem and the deployment architecture.

- **Old built-in WooCommerce integration is deprecated.** The Frappe team officially deprecated the WooCommerce integration that shipped with ERPNext v15. The old `bench get-app woocommerceconnector` pattern is no longer the recommended path.
- **New recommended approach:** the WooCommerce-side ERPNext Integration plugin (installed in WordPress, calls ERPNext via API). This reverses the direction of the integration from how it worked in v14 and earlier — WordPress is now the active party that calls into ERPNext rather than vice versa.
- **Private-network deployment.** This guide now assumes ERPNext is deployed in private-network mode inside your existing Azure VNet (the same VNet hosting WordPress). The integration uses private IPs over VNet integration — no public internet exposure required.
- **Hardcoded admin password removed.** The 1.0.0 version of this doc contained a literal password. That has been removed and the doc now teaches the Key Vault retrieval pattern.

---

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Architecture: Private-network integration](#architecture-private-network-integration)
4. [Integration approach](#integration-approach)
5. [Setup Instructions](#setup-instructions)
6. [Data Synchronization](#data-synchronization)
7. [Category Mapping](#category-mapping)
8. [Product Sync Configuration](#product-sync-configuration)
9. [Order Processing Workflow](#order-processing-workflow)
10. [Inventory Management](#inventory-management)
11. [Troubleshooting](#troubleshooting)
12. [Maintenance and Monitoring](#maintenance-and-monitoring)

---

## Overview

This guide explains how to integrate the JT Custom Trailers WooCommerce site with ERPNext. The integration delivers:

- **Product sync** from ERPNext to WooCommerce (ERPNext is the master)
- **Category sync** maintaining your existing hierarchy
- **Real-time inventory** updates as stock moves in ERPNext
- **Order import** from WooCommerce to ERPNext for fulfillment
- **Customer data** centralized in ERPNext
- **Pricing management** in ERPNext with sync to WooCommerce

### Benefits for JT Custom Trailers

- Single source of truth for inventory across warehouse, showroom, and online
- Automated order processing — no re-keying of web orders
- Integrated accounting — no double-entry between e-commerce and books
- Track custom trailer builds with work orders linked to web sales
- Manage parts inventory with serial/batch tracking (VINs, MCOs, lot numbers)
- Centralized CRM with all customer touchpoints in one place

---

## Prerequisites

### ERPNext side

- ERPNext v15.x deployed and running
- Administrator access
- API key/secret generated (see Setup, Step 1)
- Network reachability from your WordPress App Service (typically via VNet integration)

### WooCommerce side

- WordPress with WooCommerce installed (your existing Azure App Service)
- WooCommerce 5.0 or higher
- PHP 7.4+ (tested up to 8.3)
- WordPress Administrator access
- VNet integration enabled on the App Service so it can reach the private ERPNext VM
- SSL certificate (recommended even for VNet traffic)

### Your environment specifics

- **WordPress site:** https://www.jtcustomtrailers.com
- **WordPress App Service:** in the Azure tenant, joined to `jtcustomtr-2e886f0313-vnet`
- **ERPNext URL (private):** `http://10.0.2.4` (or whatever private IP the deployment script returned)
- **ERPNext admin credentials:** retrieved from Azure Key Vault (see next section)

### Retrieving credentials from Key Vault

Don't store ERPNext admin passwords in documentation or config files. Pull from Key Vault each time:

```powershell
$pw = Get-AzKeyVaultSecret `
    -VaultName 'JTC-prod-westus2-kv' `
    -Name 'JTC-prod-erpnext-westus2-vm-erpnext-admin-password' `
    -AsPlainText
$pw | Set-Clipboard
# Password is now in your clipboard
```

The vault and secret name will match what the deployment script created. The secret naming convention is `<VMName>-erpnext-admin-password`.

---

## Architecture: Private-network integration

```
┌─────────────────────────────────────────────────────────────┐
│           VNet: jtcustomtr-2e886f0313-vnet                  │
│                                                             │
│  ┌──────────────────────┐         ┌──────────────────────┐  │
│  │   WordPress App      │         │   ERPNext VM         │  │
│  │   Service            │  HTTPS  │   (private only)     │  │
│  │   appsubnet          │────────▶│   erpnext-subnet     │  │
│  │   10.0.0.0/25        │ API     │   10.0.2.0/27        │  │
│  │                      │ key/sec │                      │  │
│  └──────────┬───────────┘         └──────────┬───────────┘  │
│             │                                │              │
│             │ (public for shoppers)          │ (private)    │
└─────────────┼────────────────────────────────┼──────────────┘
              │                                │
              ▼                                ▼
       Internet shoppers              You (via VPN)
       buy products on                or peered VNets
       www.jtcustomtrailers.com
```

**Key architectural points:**

- WordPress App Service is publicly accessible (shoppers need to reach it). The WordPress side calls ERPNext over the VNet using its private IP.
- ERPNext VM has **no public IP**. Only resources inside the VNet (or peered VNets / VPN-connected clients) can reach it.
- The WordPress → ERPNext API calls travel over Azure's backbone, never the public internet.
- VNet integration on the App Service is what makes this work — it gives the App Service a NIC in the appsubnet so it can route to other VNet resources.

---

## Integration approach

### WooCommerce-side plugin (recommended)

ERPNext now publishes an integration plugin that runs **inside WordPress** and reaches out to ERPNext. This is the inverse of the deprecated v14 pattern.

**Why this is the right fit for JT Custom Trailers:**

- Doesn't require installing a Frappe app inside ERPNext (which has been a maintenance pain point in the v15 ecosystem)
- Works well with private-network ERPNext — WordPress in the same VNet can reach the private IP
- Configuration lives in WordPress where your admins are already working
- Maintained alongside WooCommerce, so it tracks WC versions cleanly

### Alternatives if the plugin doesn't fit

| Option | When to choose | Notes |
|---|---|---|
| **woocommerce_fusion** (Starktail/dvdl16 fork) | If you need bidirectional sync features the WooCommerce-side plugin doesn't cover | Community-maintained v15 connector; opposite direction (Frappe app calls WC) |
| **Custom API integration** | If your workflow has unusual requirements | Full control, but you own maintenance forever |
| **n8n / Zapier middleware** | If you also need to integrate with other systems (Mailchimp, ShipStation, etc.) | Adds another moving part but central to multi-system flows |

For this guide, we proceed with **the WooCommerce-side plugin**.

---

## Setup Instructions

### Step 1: Generate ERPNext API credentials

In ERPNext:

1. Click your user avatar (top right) → **My Settings**
2. Scroll to **API Access**
3. Click **Generate Keys**
4. Copy and save **both** the API Key and API Secret immediately — the Secret is only displayed once

If you miss the Secret, you'll need to regenerate the keys (which invalidates the previous Secret).

**Store these in Key Vault** rather than a config file:

```powershell
$apiKey    = Read-Host "ERPNext API Key"
$apiSecret = Read-Host "ERPNext API Secret" -AsSecureString | ConvertFrom-SecureString -AsPlainText
Set-AzKeyVaultSecret -VaultName 'JTC-prod-westus2-kv' `
    -Name 'erpnext-wc-integration-api-key'    -SecretValue (ConvertTo-SecureString $apiKey -AsPlainText -Force)
Set-AzKeyVaultSecret -VaultName 'JTC-prod-westus2-kv' `
    -Name 'erpnext-wc-integration-api-secret' -SecretValue (ConvertTo-SecureString $apiSecret -AsPlainText -Force)
```

### Step 2: Install the ERPNext Integration plugin in WordPress

1. In WordPress Admin: **Plugins** → **Add New**
2. Search for "ERPNext Integration" (or upload the plugin zip if installing from a release)
3. Install and **Activate**
4. A new menu item **ERPNext Integration** appears in the WordPress admin sidebar

### Step 3: Configure the API connection

1. **ERPNext Integration → API Settings**
2. Fill in:
   - **Host URL:** `http://10.0.2.4` (the private IP of your ERPNext VM)
     - For SSL eventually, this becomes `https://erpnext.internal.jtcustomtrailers.com` once you set up internal DNS + a certificate
   - **API Key:** the key from Step 1
   - **API Secret:** the secret from Step 1
   - **SSL Verification:** disabled initially (since you're on plain HTTP over private IP). Enable once SSL is in place.
   - **Debug Mode:** enable temporarily during initial setup; disable once stable
3. Click **Test Connection**
4. Verify the dashboard shows **Connected** (green)

### Step 4: Configure foundational settings

**ERPNext Integration → Configurations** in WordPress:

```
Company: AWS Solutions LLC dba JT Custom Trailers
Default Warehouse: Main Warehouse
Default Customer Group: Individual
Default Territory: United States
Tax Template: (your sales tax template)
Default UOM: Nos
```

The Company name here must match exactly what's set up in ERPNext.

### Step 5: Generate the WooCommerce REST API key (for ERPNext-to-WooCommerce direction)

Even though the plugin handles most traffic, some setups also need ERPNext to push updates back to WooCommerce. Generate a WooCommerce REST API key:

1. WordPress Admin → **WooCommerce** → **Settings** → **Advanced** → **REST API**
2. Click **Add Key**
3. Description: `ERPNext Integration`
4. User: pick an admin user
5. Permissions: **Read/Write**
6. Click **Generate API Key**
7. Save both **Consumer Key** (`ck_...`) and **Consumer Secret** (`cs_...`) — Secret is only shown once

Store these in Key Vault too:

```powershell
Set-AzKeyVaultSecret -VaultName 'JTC-prod-westus2-kv' `
    -Name 'wc-api-consumer-key'    -SecretValue (ConvertTo-SecureString 'ck_...' -AsPlainText -Force)
Set-AzKeyVaultSecret -VaultName 'JTC-prod-westus2-kv' `
    -Name 'wc-api-consumer-secret' -SecretValue (ConvertTo-SecureString 'cs_...' -AsPlainText -Force)
```

### Step 6: Initial category sync

Categories need to exist in ERPNext as Item Groups before products can sync. Use the provided PowerShell script to bulk-create the hierarchy:

```powershell
Install-Module -Name ImportExcel -Force -Scope CurrentUser   # if not already installed

$apiKey    = Get-AzKeyVaultSecret -VaultName 'JTC-prod-westus2-kv' -Name 'erpnext-wc-integration-api-key' -AsPlainText
$apiSecret = Get-AzKeyVaultSecret -VaultName 'JTC-prod-westus2-kv' -Name 'erpnext-wc-integration-api-secret' -AsPlainText

# Dry run first to validate
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

This must be run from a machine that can reach the ERPNext private IP — either through VPN or from inside the VNet itself.

### Step 7: Test product sync

1. **Create a test item in ERPNext:**
   ```
   Item Code:        TEST-SYNC-001
   Item Name:        Test Product Sync
   Item Group:       Interior
   Standard Rate:    99.99
   Maintain Stock:   ✓
   Show in Website:  ✓
   Default Warehouse: Main Warehouse
   ```
2. Add an opening stock entry (Stock → Stock Entry → Material Receipt) so the item has inventory
3. In WordPress: **ERPNext Integration → Sync → Sync Now**
4. Verify the item appears in **WooCommerce → Products**
5. Delete the test item from both systems once verified

---

## Data Synchronization

### What syncs and when

| Data Type | Direction | Frequency | Notes |
|---|---|---|---|
| Products | ERPNext → WooCommerce | Every 30 min (configurable) | New items + updates + inventory |
| Categories | ERPNext → WooCommerce | Manual / on-demand | Initial setup, then as needed |
| Inventory | ERPNext → WooCommerce | Real-time on stock change | Out-of-stock items auto-marked |
| Orders | WooCommerce → ERPNext | Every 15 min | New orders create Sales Orders |
| Customers | WooCommerce → ERPNext | With orders | Created if doesn't exist |
| Order Status | ERPNext → WooCommerce | On Delivery Note submission | Tracking number can be synced |

### Sync behavior notes

**Products:** Only items with **Show in Website** enabled sync. ERPNext is master — changes made in WooCommerce will be overwritten on the next sync. Images attached in ERPNext sync to WooCommerce.

**Inventory:** Real-time when stock entries are made in ERPNext. The WooCommerce stock value updates within seconds.

**Orders:** WooCommerce orders create Sales Orders in ERPNext. Payment status, shipping address, and customer information all sync.

---

## Category Mapping

> **Note:** The category list below reflects the WooCommerce category structure as of February 2026. Your current categories may have evolved — verify against your current `ProductCategories.xlsx` before importing.

### Parent Categories (Level 0)

| WooCommerce Category | ERPNext Item Group |
|---|---|
| Uncategorized | Uncategorized |
| General | General |
| Audio and Entertainment | Audio and Entertainment |
| Interior | Interior |
| Exterior | Exterior |
| Electrical & Solar | Electrical & Solar |
| Plumbing & Tanks | Plumbing & Tanks |
| Climate Control | Climate Control |
| Towing, Chassis & Running Gear | Towing, Chassis & Running Gear |
| Hardware, Construction, & Materials | Hardware, Construction, & Materials |
| Accessories & Lifestyle | Accessories & Lifestyle |
| Tools & Install Supplies | Tools & Install Supplies |
| Condition | Condition |
| Specials | Specials |
| Construction Equipment | Construction Equipment |
| Trailers | Trailers |

Use `Import-ERPNextCategories.ps1` to create all of these (and their subcategories) automatically from your live Excel export.

### Example: Interior category hierarchy

```
Interior
├── Bedding & Sleeping
│   ├── Bedding Sets & Linens
│   ├── Mattress Toppers & Pads
│   └── Mattresses & Bunk Mattresses
├── Dinettes & Tables
│   ├── Dinette Cushions
│   ├── Dinette Tables
│   └── Table Hardware
├── Kitchen & Galley
│   ├── Cookware
│   ├── Refrigerators & Coolers
│   └── Sinks & Faucets
└── (etc.)
```

---

## Product Sync Configuration

### Item master setup in ERPNext

For each product that should sync to the website:

```
Item Code:           [SKU - must be unique]
Item Name:           [Customer-facing name]
Item Group:          [Choose from imported categories]
Default UOM:         Nos (or Kg, M, etc.)
Show in Website:     ✓
Standard Rate:       [Price]
Maintain Stock:      ✓
Default Warehouse:   Main Warehouse
```

Attach product images in the **Image** section. These sync to WooCommerce as product gallery images.

### Bulk import from existing WooCommerce

If you're migrating an existing catalog:

1. WordPress: **WooCommerce → Products → Export** (CSV)
2. Transform to ERPNext format using `Transform-WooToERPNext.ps1` (maps WC columns to ERPNext Item fields)
3. ERPNext: **Data Import** → select "Item" doctype → upload the transformed CSV → map fields → run

---

## Order Processing Workflow

### Standard product order

1. **Shopper places order** on www.jtcustomtrailers.com
2. **Order sync runs** (every 15 minutes by default, or manual trigger)
3. **ERPNext creates:**
   - Customer record (if new)
   - Sales Order with line items, quantities, prices, shipping address, payment status
4. **You process in ERPNext:**
   - Review Sales Order
   - Create Delivery Note when shipping
   - Create Sales Invoice for accounting
   - Create Payment Entry if not already paid online
5. **Status flows back to WooCommerce:**
   - Delivery Note submission marks the WC order as Shipped
   - Tracking number can be synced if configured

### Custom trailer order

For custom builds requiring a Work Order:

1. Order syncs from WooCommerce as above
2. In ERPNext:
   - Sales Order is created
   - Create Work Order for manufacturing
   - Use Build Tracking workflow (see `Build_Tracking_Worksheet.pdf`)
   - Issue materials from stock as the build progresses
   - Complete work order when the trailer is finished
   - Create Delivery Note when the customer takes delivery
3. Invoice the customer and update WooCommerce with completion status

---

## Inventory Management

### Multi-warehouse setup

```
Main Warehouse - Ashtabula (1214 Lake Avenue)
Showroom - Jefferson (PO Box 348)
```

Set Main Warehouse as default for web orders. Stock transfers move inventory between locations as needed.

WooCommerce shows combined stock across warehouses by default. To show only web-available stock, restrict the WC sync to a specific "Web Available" warehouse and only stock that warehouse with items you want available for online ordering.

### Serial number / batch tracking

For trailers and high-value items:

```
Item → Has Serial No: ✓
```

When a trailer is received into stock, the Stock Entry creates a serial number record. **Use the VIN as the serial number** so traceability is built in.

WooCommerce doesn't display serial numbers (intentionally — they're issued to the customer with delivery, not advertised on the product page).

---

## Troubleshooting

### Products not syncing to WooCommerce

- Verify **Show in Website** is enabled on the Item
- Verify Item Group is assigned and exists in ERPNext
- Check the API credentials in WordPress: ERPNext Integration → API Settings → Test Connection
- Verify network reachability: from the WordPress App Service Kudu console, run `curl http://10.0.2.4/` — should return ERPNext HTML
- Check ERPNext error log: **Error Log** doctype, filter for "WooCommerce" or "API"

### Orders not importing from WooCommerce

- Verify order sync is enabled in WordPress ERPNext Integration settings
- Verify Default Warehouse and Default Company are set
- Check the WordPress debug.log for API errors (enable WP_DEBUG temporarily if needed)
- Manual trigger: ERPNext Integration → Sync → Sync Orders

### Inventory not updating

- Verify stock UOM matches between ERPNext and WooCommerce
- Confirm the warehouse you're tracking actually has stock (Stock → Stock Balance)
- Real-time sync depends on the WC scheduler running — check WP cron health: `wp cron event list` (or use a WP-Cron plugin to verify)

### Images not syncing

- Image file size should be under 2 MB for web
- Format should be JPG or PNG
- Verify image sync is enabled in WordPress ERPNext Integration settings

### Network connectivity issues

Since ERPNext is on a private IP, network problems are a common source of integration breakage:

```bash
# From WordPress App Service Kudu console (Debug Console > CMD):
curl -v http://10.0.2.4/

# Should return HTML or HTTP 200. Common failures:
# - "Connection refused": Frappe/nginx not running on the VM
# - "Timeout": NSG blocking traffic, or App Service not VNet-integrated
# - "Name or service not known": you used a hostname that doesn't resolve
```

If App Service can't reach the private IP:
1. Verify the App Service has VNet integration enabled
2. Verify the App Service's integrated subnet is in the same VNet as the ERPNext subnet (or peered)
3. Verify the ERPNext VM's NSG allows inbound from the VirtualNetwork service tag

### Logs and debugging

| Log | Location |
|---|---|
| ERPNext error log | ERPNext UI → Error Log doctype |
| WP plugin sync log | ERPNext Integration → Logs |
| WordPress debug log | `wp-content/debug.log` (when WP_DEBUG is on) |
| ERPNext bench logs | `/home/jtadmin/frappe-bench/logs/` on the VM |
| Background job health | `bench doctor` on the VM |

---

## Maintenance and Monitoring

### Daily

- Glance at sync status in WordPress (ERPNext Integration dashboard should show green)
- Review any failed syncs in ERPNext Error Log

### Weekly

- Inventory accuracy spot-check (pick 5 random SKUs, compare ERPNext stock vs. physical count vs. WooCommerce display)
- Check for unsynchronized items (items in ERPNext with Show in Website but missing from WC)
- Verify pricing consistency

### Monthly

- Full inventory reconciliation
- Review sync logs for patterns (recurring errors are easy to dismiss day-to-day but accumulate into real problems)
- Update category mappings if product lines change

### Backup strategy

**ERPNext:**

```bash
# On the VM, set up daily backups
sudo -u jtadmin bash -c 'cd /home/jtadmin/frappe-bench && bench --site jtcustomtrailers.local backup'

# Or schedule via cron:
# Daily backup at 2 AM, with files:
0 2 * * * cd /home/jtadmin/frappe-bench && /usr/local/bin/bench --site jtcustomtrailers.local backup --with-files
```

Pair this with Azure Backup for the VM itself, or sync the backup directory to Azure Blob Storage.

**WordPress:** UpdraftPlus (or whichever plugin you're using) handles the WP side. Ensure both backups are tested quarterly by performing a real restore to a throwaway environment.

---

## Next steps

1. Deploy ERPNext using `Deploy-ERPNextToAzure.ps1` v1.6.4+ in private-only mode
2. Run the post-install setup wizard in ERPNext
3. Generate API credentials and store in Key Vault
4. Install and configure the WordPress ERPNext Integration plugin
5. Run `Import-ERPNextCategories.ps1` to seed Item Groups
6. Test with one or two sample products
7. Bulk import existing catalog
8. Enable order sync and monitor for a week before going fully live

---

## Additional Resources

- ERPNext documentation: https://docs.erpnext.com/
- Frappe framework: https://frappeframework.com/docs
- WooCommerce REST API: https://woocommerce.github.io/woocommerce-rest-api-docs/
- WooCommerce side ERPNext plugin: https://woocommerce.com/document/erpnext-integration/
- ERPNext community forum: https://discuss.erpnext.com/
- Frappe community forum: https://discuss.frappe.io/

---

## Support contacts

**Implementation lead:** John O'Neill Sr. — JONeillSr@jtcustomtrailers.com — (440) 813-6695

**GitHub:** https://github.com/JONeillSr/

---

**Document Version:** 2.0.0
**Last Updated:** 05/16/2026
**Next Review:** 08/16/2026
