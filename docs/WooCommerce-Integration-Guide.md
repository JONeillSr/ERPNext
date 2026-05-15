# ERPNext - WooCommerce Integration Guide
## JT Custom Trailers

**Author:** John O'Neill Sr.  
**Company:** Azure Innovators  
**Create Date:** 02/17/2026  
**Version:** 1.0.0

---

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Integration Methods](#integration-methods)
4. [Recommended Approach: ERPNext WooCommerce Integration](#recommended-approach)
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

This guide explains how to integrate your WordPress/WooCommerce e-commerce site with ERPNext ERP system. The integration will:

- **Sync products** from ERPNext to WooCommerce
- **Sync categories** maintaining your existing hierarchy
- **Update inventory** in real-time across both systems
- **Import orders** from WooCommerce to ERPNext for processing
- **Track customer data** centrally in ERPNext
- **Manage pricing** from ERPNext with sync to WooCommerce

### Benefits for JT Custom Trailers

- Single source of truth for inventory across warehouse, showroom, and online
- Automated order processing from web orders
- Integrated accounting (no double-entry)
- Track custom trailer builds with work orders
- Manage parts inventory with serial/batch tracking
- Centralized customer relationship management

---

## Prerequisites

### On ERPNext Server

- ERPNext v15.x installed and configured
- Administrator access to ERPNext
- Site URL accessible from your WordPress server
- API access enabled in ERPNext

### On WordPress/WooCommerce Server

- WordPress with WooCommerce installed (your Azure App Service)
- WP REST API enabled (default in WordPress)
- Administrator access to WordPress
- SSL certificate (recommended for API security)

### Required Information

From your setup, you have:
- **WordPress Site:** https://www.jtcustomtrailers.com
- **WordPress Admin:** Access to WordPress admin panel
- **ERPNext Site:** http://[YOUR-ERPNEXT-IP] (after deployment)
- **ERPNext Admin:** Administrator / Admin@JTCustom2026!

---

## Integration Methods

### Method 1: ERPNext WooCommerce Integration App (Recommended)

**Pros:**
- Official ERPNext app
- Bidirectional sync
- Maintained by Frappe team
- Built-in mapping tools
- Real-time inventory updates

**Cons:**
- Requires configuration
- May need customization for complex workflows

### Method 2: Custom API Integration

**Pros:**
- Complete control
- Fully customizable
- Can handle complex business logic

**Cons:**
- Requires development
- Maintenance overhead
- Need to handle edge cases

### Method 3: Third-Party Middleware

**Pros:**
- Pre-built connectors
- Visual workflow builders

**Cons:**
- Monthly subscription costs
- Limited customization
- Dependency on third party

**For JT Custom Trailers: Method 1 is recommended** as it provides the best balance of functionality, maintainability, and cost.

---

## Recommended Approach

### ERPNext WooCommerce Integration App

This is the official integration app maintained by Frappe (the company behind ERPNext).

#### Installation

1. **SSH into your ERPNext server:**
   ```bash
   ssh jtadmin@[YOUR-ERPNEXT-IP]
   ```

2. **Navigate to frappe-bench:**
   ```bash
   cd /home/jtadmin/frappe-bench
   ```

3. **Get the WooCommerce integration app:**
   ```bash
   bench get-app woocommerceconnector
   ```

4. **Install on your site:**
   ```bash
   bench --site jtcustomtrailers.local install-app woocommerceconnector
   ```

5. **Restart bench:**
   ```bash
   bench restart
   ```

---

## Setup Instructions

### Step 1: Configure WooCommerce API Keys

1. **Log into WordPress Admin:**
   - Go to https://www.jtcustomtrailers.com/wp-admin

2. **Navigate to WooCommerce Settings:**
   - WooCommerce → Settings → Advanced → REST API

3. **Create API Key:**
   - Click "Add key"
   - Description: "ERPNext Integration"
   - User: (Select your admin user)
   - Permissions: "Read/Write"
   - Click "Generate API key"

4. **Save credentials securely:**
   ```
   Consumer Key: ck_XXXXXXXXXXXXXXXXXXXX
   Consumer Secret: cs_XXXXXXXXXXXXXXXXXXXX
   ```

### Step 2: Configure ERPNext WooCommerce Settings

1. **Log into ERPNext:**
   - Go to http://[YOUR-ERPNEXT-IP]
   - Login as Administrator

2. **Navigate to WooCommerce Settings:**
   - Search for "WooCommerce Settings" in the search bar
   - Or go to: Integrations → WooCommerce Settings

3. **Enter WooCommerce Details:**
   ```
   Enable Sync: ✓ (checked)
   WooCommerce Server URL: https://www.jtcustomtrailers.com
   API Consumer Key: [Your Consumer Key from Step 1]
   API Consumer Secret: [Your Consumer Secret from Step 1]
   ```

4. **Configure Sync Settings:**
   ```
   Enable Item Sync: ✓
   Enable Order Sync: ✓
   Enable Customer Sync: ✓
   Warehouse: Main Warehouse (or your primary warehouse)
   Company: JT Custom Trailers
   ```

5. **Tax Configuration:**
   - Map WooCommerce tax classes to ERPNext tax templates
   - Default Tax Template: (Select your sales tax template)

6. **Save settings**

### Step 3: Initial Category Sync

ERPNext will need to know your category structure. The integration typically creates Item Groups in ERPNext that map to WooCommerce categories.

#### Manual Category Mapping

1. **In ERPNext, go to:** Stock → Item Group
2. **For each major category in your ProductCategories.xlsx:**
   - Create an Item Group (e.g., "Interior", "Exterior", "Electrical & Solar")
   - Set the parent group as needed to mirror your hierarchy
   - Enable "Is Group" for parent categories

See [Category Mapping](#category-mapping) section below for detailed mapping table.

### Step 4: Configure Item Sync

1. **In ERPNext WooCommerce Settings:**
   - Enable "Sync Items from ERPNext to WooCommerce"
   - Set sync frequency (recommended: Every 30 minutes)

2. **Field Mapping (default is usually fine):**
   ```
   ERPNext Item Code → WooCommerce SKU
   ERPNext Item Name → WooCommerce Product Name
   ERPNext Description → WooCommerce Product Description
   ERPNext Standard Rate → WooCommerce Regular Price
   ERPNext Item Group → WooCommerce Product Category
   ```

3. **Image Sync:**
   - Enable "Sync Images"
   - Images in ERPNext will sync to WooCommerce

### Step 5: Test Sync

1. **Create a test item in ERPNext:**
   ```
   Item Code: TEST-001
   Item Name: Test Trailer Part
   Item Group: Interior → Bedding & Sleeping
   Standard Rate: 50.00
   ```

2. **Run sync manually:**
   - In WooCommerce Settings, click "Sync Now"

3. **Verify in WooCommerce:**
   - Check Products in WooCommerce admin
   - Verify the test item appears with correct category

4. **Delete test item** after verification

---

## Data Synchronization

### What Syncs and When

| Data Type | Direction | Frequency | Notes |
|-----------|-----------|-----------|-------|
| Products | ERPNext → WooCommerce | Every 30 min (or manual) | New items, updates, inventory |
| Categories | ERPNext → WooCommerce | Manual/On-demand | Initial setup, then as needed |
| Inventory | ERPNext → WooCommerce | Real-time (on stock change) | Stock levels sync automatically |
| Orders | WooCommerce → ERPNext | Every 15 min | New orders imported |
| Customers | WooCommerce → ERPNext | With orders | Customer created if doesn't exist |
| Order Status | ERPNext → WooCommerce | Manual/On fulfillment | Update shipping status |

### Sync Behavior

**Product Sync:**
- Only items with "Show in Website" enabled will sync to WooCommerce
- ERPNext is the master - changes in WooCommerce may be overwritten
- Images sync from ERPNext attachments

**Inventory Sync:**
- Real-time when stock entry is made in ERPNext
- WooCommerce stock updates immediately
- Out-of-stock items automatically marked in WooCommerce

**Order Sync:**
- WooCommerce orders create Sales Orders in ERPNext
- Payment status synced
- Shipping address mapped
- Customer created/updated

---

## Category Mapping

Based on your ProductCategories.xlsx, here's the recommended ERPNext Item Group structure:

### Parent Categories (Level 0)

| WooCommerce Category | ERPNext Item Group | Term ID |
|----------------------|--------------------|---------|
| Uncategorized | Uncategorized | 15 |
| General | General | 17 |
| Audio and Entertainment | Audio and Entertainment | 41 |
| Interior | Interior | 43 |
| Exterior | Exterior | 44 |
| Electrical & Solar | Electrical & Solar | 45 |
| Plumbing & Tanks | Plumbing & Tanks | 46 |
| Climate Control | Climate Control | 47 |
| Towing, Chassis & Running Gear | Towing, Chassis & Running Gear | 48 |
| Hardware, Construction, & Materials | Hardware, Construction, & Materials | 49 |
| Accessories & Lifestyle | Accessories & Lifestyle | 50 |
| Tools & Install Supplies | Tools & Install Supplies | 51 |
| Condition | Condition | 52 |
| Specials | Specials | 53 |
| Construction Equipment | Construction Equipment | 214 |
| Trailers | Trailers | 311 |

### Example: Interior Category Hierarchy

```
Interior (Parent)
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

### Creating Categories in ERPNext

Use the provided PowerShell script `Import-ERPNextCategories.ps1` (see separate file) to automatically create the full hierarchy.

---

## Product Sync Configuration

### Item Master Setup in ERPNext

For each product you want to sync:

1. **Basic Information:**
   ```
   Item Code: [Your SKU]
   Item Name: [Product Name]
   Item Group: [Select from mapped categories]
   Default Unit of Measure: Nos (or Kg, M, etc.)
   ```

2. **Website Configuration:**
   ```
   Show in Website: ✓ (checked)
   Weightage: [For sorting, optional]
   ```

3. **Pricing:**
   ```
   Standard Selling Rate: [Your price]
   ```

4. **Inventory:**
   ```
   Maintain Stock: ✓ (checked)
   Default Warehouse: Main Warehouse
   ```

5. **Images:**
   - Attach images in the "Image" section
   - These will sync to WooCommerce

### Bulk Import

For your existing WooCommerce products:

1. **Export from WooCommerce:**
   - WooCommerce → Products → Export
   - Save CSV

2. **Transform to ERPNext format:**
   - Use the provided `Transform-WooToERPNext.ps1` script
   - This maps your columns to ERPNext Item format

3. **Import to ERPNext:**
   - ERPNext → Data Import
   - Select "Item" document type
   - Upload transformed CSV
   - Map fields
   - Import

---

## Order Processing Workflow

### When Order is Placed in WooCommerce

1. **Order Sync runs** (every 15 minutes or manual trigger)

2. **ERPNext creates:**
   - **Customer** (if new)
   - **Sales Order** with:
     - Items from WooCommerce order
     - Quantities
     - Prices
     - Shipping address
     - Payment status

3. **You process in ERPNext:**
   - Review Sales Order
   - Create Delivery Note (when shipping)
   - Create Sales Invoice (for accounting)
   - Create Payment Entry (if not already paid online)

4. **Status updates back to WooCommerce:**
   - When Delivery Note is submitted, order marked as "Shipped"
   - Tracking number can be synced

### Custom Trailer Orders

For custom builds that require work orders:

1. **Order syncs from WooCommerce**
2. **In ERPNext:**
   - Sales Order created
   - Create Work Order for manufacturing
   - Use Build Tracking (see Build_Tracking_Worksheet.pdf)
   - Issue materials from stock
   - Complete work order
   - Create Delivery Note
3. **Invoice and ship**

---

## Inventory Management

### Multi-Warehouse Setup

You mentioned warehouse and showroom locations. Set up in ERPNext:

1. **Create Warehouses:**
   ```
   Main Warehouse - Ashtabula (1214 Lake Avenue)
   Showroom - Jefferson (PO Box 348)
   ```

2. **Configure Default:**
   - Set "Main Warehouse" as default for web orders
   - Stock transfers between warehouses as needed

3. **Stock Sync:**
   - WooCommerce shows combined stock across warehouses
   - Or, configure to show only web-available stock

### Serial Number / Batch Tracking

For trailers and high-value items:

1. **Enable Serial No:**
   ```
   Item → Has Serial No: ✓
   ```

2. **When trailer is received:**
   - Stock Entry creates serial number
   - VIN number can be the serial number

3. **WooCommerce:**
   - Doesn't show serial numbers (intentionally)
   - Customer receives serial/VIN with delivery

---

## Troubleshooting

### Common Issues

**Issue: Products not syncing to WooCommerce**

- **Check:** "Show in Website" is enabled on Item
- **Check:** Item has Item Group assigned
- **Check:** WooCommerce API credentials are correct
- **Check:** ERPNext can reach your WooCommerce site (firewall/SSL)

**Issue: Orders not importing from WooCommerce**

- **Check:** Order sync is enabled in WooCommerce Settings
- **Check:** Warehouse is set in WooCommerce Settings
- **Check:** Company is set
- **Check:** Error Log in ERPNext (Setup → Error Log)

**Issue: Inventory not updating**

- **Check:** Stock UOM matches between ERPNext and WooCommerce
- **Check:** Warehouse has stock (Stock Balance Report)
- **Check:** Sync frequency settings

**Issue: Images not syncing**

- **Check:** Image file size (keep under 2MB for web)
- **Check:** Image format (JPG/PNG recommended)
- **Check:** "Sync Images" is enabled

### Logs and Debugging

1. **ERPNext Error Log:**
   - Setup → Error Log
   - Filter by "WooCommerce"

2. **Sync Log:**
   - WooCommerce Settings → View Sync Log

3. **Background Jobs:**
   - Check that background jobs are running
   - `bench doctor` on server

4. **WordPress Debug:**
   - Enable WP_DEBUG in wp-config.php temporarily
   - Check debug.log for API errors

---

## Maintenance and Monitoring

### Daily Tasks

- Monitor order sync (should be automatic)
- Review any failed syncs in Error Log

### Weekly Tasks

- Review inventory accuracy
- Check for unsynchronized items
- Verify pricing consistency

### Monthly Tasks

- Full inventory reconciliation
- Review sync logs for patterns
- Update category mappings if product lines change

### Backup Strategy

**ERPNext:**
- Automated daily backups (configured in bench)
- Download weekly to local storage

**WooCommerce:**
- UpdraftPlus plugin (already installed) handles WordPress backups
- Ensure ERPNext sync means data is duplicated safely

---

## Next Steps

1. **Deploy ERPNext** using the provided `Deploy-ERPNextToAzure.ps1` script
2. **Run installation** on the Azure VM
3. **Install WooCommerce Connector** app in ERPNext
4. **Configure API keys** in WooCommerce
5. **Set up categories** using the category import script
6. **Test sync** with a few sample products
7. **Bulk import** your existing product catalog
8. **Enable order sync** and monitor

---

## Additional Resources

### ERPNext Documentation
- https://docs.erpnext.com/
- https://frappeframework.com/docs

### WooCommerce REST API
- https://woocommerce.github.io/woocommerce-rest-api-docs/

### WooCommerce Connector
- https://github.com/frappe/woocommerceconnector

---

## Support Contacts

**ERPNext Community Forum:**
- https://discuss.erpnext.com/

**Frappe Support:**
- https://frappe.io/support

**Your Implementation:**
- John O'Neill Sr.
- JONeillSr@jtcustomtrailers.com
- (440) 813-6695

---

**Document Version:** 1.0.0  
**Last Updated:** 02/17/2026  
**Next Review:** 03/17/2026
