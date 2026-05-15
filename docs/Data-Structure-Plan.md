# ERPNext Data Structure Plan
## JT Custom Trailers - WooCommerce to ERPNext Migration

**Author:** John O'Neill Sr.  
**Company:** Azure Innovators  
**Create Date:** 02/17/2026  
**Version:** 1.0.0

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Current WooCommerce Structure](#current-woocommerce-structure)
3. [ERPNext Data Model](#erpnext-data-model)
4. [Category Mapping](#category-mapping)
5. [Product/Item Structure](#product-item-structure)
6. [Custom Fields Required](#custom-fields-required)
7. [Warehouse Configuration](#warehouse-configuration)
8. [Customer Data Structure](#customer-data-structure)
9. [Order Processing Structure](#order-processing-structure)
10. [Inventory Tracking](#inventory-tracking)
11. [Custom Trailer Build Tracking](#custom-trailer-build-tracking)
12. [Migration Timeline](#migration-timeline)

---

## Executive Summary

This document outlines the complete data structure migration from your existing WooCommerce e-commerce platform to ERPNext ERP system. The goal is to maintain your current 16 parent categories with 200+ subcategories while adding manufacturing, inventory, and accounting capabilities.

### Key Benefits

- **Single Source of Truth:** All data managed centrally in ERPNext
- **Real-time Inventory:** Across warehouse, showroom, and online
- **Manufacturing Integration:** Track custom trailer builds with work orders
- **Accounting Integration:** No double-entry, automated financial tracking
- **Serial Number Tracking:** VINs and MCOs for trailers
- **Batch Tracking:** For parts with lot numbers
- **Multi-location:** Support for multiple warehouse locations

---

## Current WooCommerce Structure

### Existing Category Hierarchy (from ProductCategories.xlsx)

Based on your Excel file analysis, you have:

**Total Structure:**
- 16 Parent Categories (Level 0)
- 200+ Total Categories (including all levels)
- Maximum Depth: 3 levels (Parent > Child > Grandchild)

**Parent Categories:**

1. **Uncategorized** (1 item)
2. **General** (1 item)
3. **Audio and Entertainment** (2 items)
4. **Interior** (33 items) - Largest category
   - Bedding & Sleeping
   - Dinettes & Tables
   - Entertainment & Electronics
   - Kitchen & Galley
   - Lighting
   - Seating & Furniture
   - Storage & Organization
   - Window Treatments

5. **Exterior** (26 items)
   - Awnings & Shades
   - Body & Panels
   - Doors & Entry
   - Graphics & Decals
   - Ladders & Steps
   - Roof Components
   - Windows & Vents

6. **Electrical & Solar** (23 items)
   - Batteries & Charging
   - Lighting
   - Shore Power & Cords
   - Solar Systems
   - Wiring & Components

7. **Plumbing & Tanks** (16 items)
   - Fresh Water System
   - Waste Water System
   - Water Heaters

8. **Climate Control** (12 items)
   - Cooling
   - Heating
   - Ventilation

9. **Towing, Chassis & Running Gear** (16 items)
   - Brakes & Hubs
   - Couplers & Jacks
   - Suspension & Axles
   - Tires & Wheels

10. **Hardware, Construction, & Materials** (12 items)
    - Fasteners & Hardware
    - Insulation & Barriers
    - Sealants & Adhesives

11. **Accessories & Lifestyle** (15 items)
    - Camping & Outdoor
    - Covers & Protection
    - Maintenance & Care

12. **Tools & Install Supplies** (5 items)
    - Electrical Tools & Testers
    - Plumbing Tools
    - Sealant & Caulking Tools
    - Specialty Tools

13. **Condition** (6 items)
    - New
    - New Take-Off
    - Refurbished
    - Scratch & Dent
    - Used - Excellent
    - Used - Good

14. **Specials** (4 items)
    - Clearance
    - Limited Stock
    - Rare Finds

15. **Construction Equipment** (91 items) - Second largest
    - Compact Construction Attachments
    - Compact Machines
    - Construction Parts & Accessories

16. **Trailers** (27 items)
    - Enclosed Trailers
      - Bumper Pull
      - Gooseneck and Fifth-Wheel
    - Open Trailers
      - Equipment Trailers
      - Landscape & Utility
    - Specialty Trailers

### WooCommerce Product Attributes

Your products likely have these standard WooCommerce fields:
- SKU
- Product Name
- Description
- Short Description
- Regular Price
- Sale Price
- Categories
- Tags
- Images
- Stock Status
- Stock Quantity
- Weight
- Dimensions (Length, Width, Height)
- Manufacturer/Brand
- Condition

---

## ERPNext Data Model

### Core Document Types We'll Use

**Master Data:**
- **Item** - Your products (parts, trailers, accessories)
- **Item Group** - Categories (maps to WooCommerce categories)
- **Customer** - Buyers (synced from WooCommerce)
- **Supplier** - Your vendors (Wells Cargo, Lippert, Dometic, etc.)
- **Warehouse** - Your physical locations
- **Price List** - Retail, wholesale, contractor pricing

**Transactions:**
- **Sales Order** - From WooCommerce orders
- **Delivery Note** - When shipping
- **Sales Invoice** - Billing
- **Payment Entry** - Payments received
- **Stock Entry** - Inventory adjustments
- **Work Order** - For custom trailer builds
- **Purchase Order** - Ordering from suppliers
- **Purchase Receipt** - Receiving inventory

**Manufacturing:**
- **BOM (Bill of Materials)** - Parts list for trailer builds
- **Work Order** - Production tracking
- **Job Card** - Individual build tasks

---

## Category Mapping

### ERPNext Item Group Structure

ERPNext uses "Item Groups" which are hierarchical, exactly like WooCommerce categories.

**Mapping Strategy:**

| WooCommerce | ERPNext | Notes |
|-------------|---------|-------|
| Product Category | Item Group | Direct 1:1 mapping |
| Category Name | Item Group Name | Keep identical |
| Category Slug | N/A | ERPNext auto-generates |
| Category Description | Description | Copied over |
| Parent Category | Parent Item Group | Hierarchy maintained |

**Root Item Group:**

All your categories will be children of "All Item Groups" (ERPNext's root).

```
All Item Groups (ERPNext Root)
├── Uncategorized
├── General
├── Audio and Entertainment
│   └── Speakers
├── Interior
│   ├── Bedding & Sleeping
│   │   ├── Bedding Sets & Linens
│   │   ├── Mattress Toppers & Pads
│   │   └── Mattresses & Bunk Mattresses
│   ├── Dinettes & Tables
│   └── (etc.)
├── Exterior
├── Electrical & Solar
├── Plumbing & Tanks
├── Climate Control
├── Towing, Chassis & Running Gear
├── Hardware, Construction, & Materials
├── Accessories & Lifestyle
├── Tools & Install Supplies
├── Condition
├── Specials
├── Construction Equipment
└── Trailers
```

**Implementation:**

The provided `Import-ERPNextCategories.ps1` script will:
1. Read your ProductCategories.xlsx
2. Create all Item Groups in ERPNext
3. Maintain parent-child relationships
4. Preserve descriptions

---

## Product/Item Structure

### ERPNext Item Doctype Fields

**Basic Information:**
```
Item Code: [Your SKU] - Primary identifier
Item Name: [Product Name]
Item Group: [Category from mapping above]
Description: [Full description from WooCommerce]
```

**Inventory:**
```
Maintain Stock: ✓ (for physical products)
Default Warehouse: Main Warehouse
Stock UOM: Nos (or Kg, M, etc.)
Opening Stock: [Current WooCommerce inventory]
Valuation Rate: [Cost price]
```

**Sales:**
```
Allow Customer to Edit Selling Price: ✗
Standard Selling Rate: [Regular Price]
Price List: Standard Selling
```

**Purchase:**
```
Is Purchase Item: ✓ (for items you buy)
Default Supplier: [Your vendor]
Standard Buying Rate: [Cost]
```

**Manufacturing:**
```
Is Stock Item: ✓
Include in Manufacturing: ✓ (for trailer parts)
Supply Raw Materials: ✓ (if applicable)
```

**Website:**
```
Show in Website: ✓ (to sync to WooCommerce)
Website Warehouse: Main Warehouse
```

### Product Type Mapping

| WooCommerce Product Type | ERPNext Item Type | Notes |
|--------------------------|-------------------|-------|
| Simple Product | Stock Item | Most common |
| Variable Product | Item with Variants | Use Item Attributes |
| Grouped Product | Bundle | Use Product Bundle |
| External/Affiliate | Non-Stock Item | Don't maintain stock |

---

## Custom Fields Required

ERPNext allows custom fields. Here's what you'll need for your business:

### Item Custom Fields

**Trailer-Specific Fields:**
```
Custom Field Name: trailer_type
Type: Select
Options: Enclosed, Open, Specialty, Fifth-Wheel, Gooseneck, Bumper Pull
---
Custom Field Name: trailer_length
Type: Float
Description: Length in feet
---
Custom Field Name: trailer_width
Type: Float
Description: Width in feet
---
Custom Field Name: trailer_height
Type: Float
Description: Height in feet
---
Custom Field Name: gvwr
Type: Int
Description: Gross Vehicle Weight Rating
---
Custom Field Name: axle_configuration
Type: Select
Options: Single Axle, Tandem Axle, Triple Axle
---
Custom Field Name: wells_cargo_model
Type: Data
Description: Wells Cargo model number
---
Custom Field Name: has_ramp
Type: Check
---
Custom Field Name: has_side_door
Type: Check
---
Custom Field Name: interior_height
Type: Float
```

**Parts-Specific Fields:**
```
Custom Field Name: oem_part_number
Type: Data
Description: Manufacturer part number
---
Custom Field Name: manufacturer
Type: Link
Options: Supplier
---
Custom Field Name: fits_trailer_types
Type: Small Text
Description: Compatible trailer types
---
Custom Field Name: lippert_part_number
Type: Data
---
Custom Field Name: dometic_part_number
Type: Data
---
Custom Field Name: condition
Type: Select
Options: New, New Take-Off, Refurbished, Scratch & Dent, Used - Excellent, Used - Good
---
Custom Field Name: warranty_months
Type: Int
```

**WooCommerce Sync Fields:**
```
Custom Field Name: woocommerce_id
Type: Data
Description: WooCommerce product ID
---
Custom Field Name: last_woo_sync
Type: Datetime
---
Custom Field Name: woo_permalink
Type: Data
```

### Serial Number Custom Fields

For trailers with VINs:
```
Custom Field Name: vin_number
Type: Data
In: Serial No doctype
---
Custom Field Name: mco_number
Type: Data
Description: Manufacturer Certificate of Origin
---
Custom Field Name: build_date
Type: Date
---
Custom Field Name: original_build_sheet
Type: Attach
```

---

## Warehouse Configuration

### Warehouse Structure

Based on your locations:

**Warehouses to Create:**

1. **Main Warehouse - Ashtabula**
   ```
   Warehouse Name: Main Warehouse
   Warehouse Type: Manufacturing
   Address: 1214 Lake Avenue, Ashtabula, OH 44004
   Contact: (440) 813-6695
   ```

2. **Showroom - Jefferson**
   ```
   Warehouse Name: Showroom - Jefferson
   Warehouse Type: Retail
   Address: PO Box 348, Jefferson, OH 44047
   Contact: (440) 209-2866
   ```

3. **Online/Web Inventory** (Virtual)
   ```
   Warehouse Name: Web Inventory
   Warehouse Type: E-commerce
   Note: Reserved for online sales
   ```

**Warehouse Hierarchy:**
```
All Warehouses
├── Main Warehouse
│   ├── Finished Goods
│   ├── Raw Materials
│   └── Work in Progress
├── Showroom - Jefferson
└── Web Inventory
```

### Stock Allocation

**Strategy:**
- WooCommerce pulls from "Web Inventory"
- Stock transfers from Main Warehouse to Web Inventory
- Showroom has display units (not for online sale)

---

## Customer Data Structure

### ERPNext Customer Doctype

**From WooCommerce:**
```
Customer Name: [First Last from WooCommerce]
Customer Type: Individual / Company
Customer Group: WooCommerce Customers
Territory: (Based on shipping address)
Default Currency: USD
```

**Address Links:**
```
Billing Address: From WooCommerce billing
Shipping Address: From WooCommerce shipping
```

**Contact Links:**
```
Contact Name: [Customer Name]
Email: [From WooCommerce]
Phone: [From WooCommerce]
```

**Custom Fields:**
```
woocommerce_customer_id: [WooCommerce user ID]
last_order_date: [Auto-updated]
total_orders: [Count]
lifetime_value: [Sum of invoices]
```

---

## Order Processing Structure

### Sales Order Flow

**When WooCommerce order is placed:**

1. **Sales Order Created in ERPNext:**
   ```
   Customer: [Synced customer]
   Order Date: [WooCommerce order date]
   Delivery Date: [Estimated ship date]
   Items: [From order line items]
   Taxes: [From WooCommerce tax]
   Shipping Charges: [From WooCommerce]
   Payment Status: Paid (if paid online)
   ```

2. **Custom Fields on Sales Order:**
   ```
   woocommerce_order_id: [WooCommerce order number]
   woocommerce_order_key: [WooCommerce order key]
   payment_method: [From WooCommerce]
   customer_note: [From order notes]
   ```

3. **Processing Steps:**
   - Sales Order created (automatic)
   - Pick List generated (for warehouse)
   - Delivery Note created (when shipped)
   - Sales Invoice created (for accounting)
   - Payment Entry (if not already paid)

### Custom Trailer Orders

**For custom builds:**

1. **Sales Order** - Initial order
2. **Work Order** - Manufacturing
3. **BOM** - Parts needed
4. **Stock Entry** - Material issue
5. **Job Cards** - Build tasks
6. **Quality Inspection** - Pre-delivery check
7. **Delivery Note** - Ship to customer
8. **Sales Invoice** - Final billing

---

## Inventory Tracking

### Stock Entry Types

**Receipts:**
```
Material Receipt: Receiving from suppliers
Manufacturing: Finished goods from work orders
```

**Issues:**
```
Material Issue: For manufacturing
Material Transfer: Between warehouses
```

**Adjustments:**
```
Material Transfer for Manufacture
Repack: Bundling items
Send to Subcontractor
```

### Valuation Methods

**For JT Custom Trailers:**
- **FIFO** (First In, First Out) - Recommended for parts
- **Moving Average** - For consumables
- **Serialized** - For individual trailers (VINs)

### Reorder Levels

Set on each Item:
```
Minimum Qty: [Trigger reorder at this level]
Reorder Qty: [Order this amount]
Lead Time Days: [Days to receive]
```

---

## Custom Trailer Build Tracking

### Bill of Materials (BOM)

For standard configurations:

**Example: 7x14 Enclosed Trailer BOM**
```
Item: 7x14 Enclosed Trailer - Standard
Quantity: 1

Operations:
- Frame Assembly (4 hours)
- Wall Installation (6 hours)
- Roof Installation (3 hours)
- Door Installation (2 hours)
- Interior Finishing (4 hours)
- Electrical (3 hours)
- Final Inspection (1 hour)

Materials:
- Steel Frame Kit (1 ea)
- Aluminum Side Panels (14 pc)
- Aluminum Roof Panels (7 pc)
- LED Interior Lights (4 ea)
- 36" Side Door (1 ea)
- Rear Ramp Door (1 ea)
- Wiring Harness (1 ea)
- Floor Decking (1 kit)
- Screws/Rivets (1 kit)
- (etc.)
```

### Work Order Process

1. **Create Work Order from Sales Order**
2. **Set Production Item** (the trailer)
3. **Planned Start/End Dates**
4. **Reserve Materials** (from BOM)
5. **Generate Job Cards** (individual tasks)
6. **Material Transfer** (issue parts)
7. **Complete Job Cards** (track progress)
8. **Finish Work Order** (complete production)
9. **Stock Entry** (trailer now in finished goods)

### Integration with Build Tracking Worksheet

Your Build_Tracking_Worksheet.pdf shows:
- Customer info
- Trailer specs
- Build checklist
- Completion dates

**In ERPNext:**
- **Work Order** handles production tracking
- **Job Cards** handle individual tasks
- **Custom Print Format** can replicate your PDF
- **Attachments** for photos/documentation

---

## Migration Timeline

### Phase 1: Setup and Configuration (Week 1-2)

**Week 1:**
- Day 1-2: Deploy ERPNext to Azure VM
- Day 3-4: Install WooCommerce Connector
- Day 5-7: Create custom fields and configure

**Week 2:**
- Day 1-2: Import categories (use script)
- Day 3-4: Configure warehouses
- Day 5-7: Set up suppliers, customers

### Phase 2: Data Migration (Week 3-4)

**Week 3:**
- Day 1-3: Import product data
- Day 4-5: Verify product sync to WooCommerce
- Day 6-7: Import opening stock balances

**Week 4:**
- Day 1-2: Import customer data
- Day 3-4: Historical order import (optional)
- Day 5-7: Testing and validation

### Phase 3: Go-Live (Week 5)

**Week 5:**
- Day 1-2: Enable WooCommerce order sync
- Day 3-4: Monitor synchronization
- Day 5: Train staff
- Day 6-7: Full operation

### Phase 4: Optimization (Week 6+)

- Fine-tune sync intervals
- Optimize workflows
- Create custom reports
- Implement manufacturing BOMs
- Roll out work order tracking

---

## Data Validation Checklist

Before go-live, verify:

- [ ] All categories imported correctly
- [ ] Sample products sync to WooCommerce
- [ ] Inventory levels match between systems
- [ ] Test order processes successfully
- [ ] Customer data imports without errors
- [ ] Warehouse locations configured
- [ ] Supplier data entered
- [ ] Price lists set up
- [ ] Tax templates configured
- [ ] Payment gateways tested
- [ ] Staff trained on ERPNext
- [ ] Backup strategy in place

---

## Appendix A: Field Mapping Reference

### WooCommerce to ERPNext Item Mapping

| WooCommerce Field | ERPNext Field | Type | Notes |
|-------------------|---------------|------|-------|
| ID | woocommerce_id | Custom | Track sync |
| Name | item_name | Standard | Product name |
| SKU | item_code | Standard | Unique ID |
| Description | description | Standard | Full description |
| Short Description | N/A | - | Use in web description |
| Regular Price | standard_rate | Standard | In Price List |
| Sale Price | N/A | - | Use Price List discount |
| Categories | item_group | Standard | Primary category |
| Tags | N/A | - | Optional custom field |
| Stock Status | N/A | - | Calculated from stock |
| Stock Quantity | opening_stock | Standard | Initial qty |
| Weight | weight_per_unit | Standard | Physical weight |
| Length | length | Standard | Dimensions |
| Width | width | Standard | Dimensions |
| Height | height | Standard | Dimensions |
| Images | image | Standard | Primary image |
| Gallery Images | website_image | Standard | Additional |

---

## Appendix B: API Endpoints Reference

### ERPNext REST API

**Authentication:**
```
POST /api/method/login
Headers: Content-Type: application/json
Body: {"usr": "user", "pwd": "password"}
```

**Get Item:**
```
GET /api/resource/Item/{item_code}
Headers: Authorization: token {api_key}:{api_secret}
```

**Create Item:**
```
POST /api/resource/Item
Headers: Authorization: token {api_key}:{api_secret}
Body: {item data as JSON}
```

**Update Stock:**
```
POST /api/resource/Stock Entry
Headers: Authorization: token {api_key}:{api_secret}
Body: {stock entry data}
```

### WooCommerce REST API

**Get Products:**
```
GET /wp-json/wc/v3/products
Auth: Consumer Key and Secret (Basic Auth)
```

**Get Orders:**
```
GET /wp-json/wc/v3/orders
Auth: Consumer Key and Secret (Basic Auth)
```

**Update Order Status:**
```
PUT /wp-json/wc/v3/orders/{id}
Body: {"status": "completed"}
```

---

## Support and Next Steps

For assistance with this migration:

**Technical Support:**
- John O'Neill Sr.
- JONeillSr@jtcustomtrailers.com
- (440) 813-6695

**ERPNext Community:**
- https://discuss.erpnext.com/

**Documentation:**
- ERPNext: https://docs.erpnext.com/
- WooCommerce: https://woocommerce.github.io/woocommerce-rest-api-docs/

---

**Document Version:** 1.0.0  
**Last Updated:** 02/17/2026  
**Next Review:** 03/17/2026
