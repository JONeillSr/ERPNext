# ERPNext Deployment - Quick Start Guide
## AWS Solutions LLC dba JT Custom Trailers

**Author:** John O'Neill Sr. 

**Date:** 02/17/2026

---

## What You Have

A complete ERPNext deployment and WooCommerce integration package:

### 📁 Files Created

1. **Deploy-ERPNextToAzure.ps1** - Azure VM deployment script
2. **WooCommerce-Integration-Guide.md** - Complete integration documentation
3. **Import-ERPNextCategories.ps1** - Category import automation
4. **Data-Structure-Plan.md** - Detailed data migration plan
5. **Quick-Start-Guide.md** - This file

---

## Quick Start Steps

### Step 1: Deploy ERPNext to Azure (30-45 minutes)

```powershell
# From PowerShell 7.x with Azure modules installed

# Connect to Azure
Connect-AzAccount

# Run deployment (customize parameters as desired)
.\Deploy-ERPNextToAzure.ps1 -ResourceGroupName "JTC-prod-erpnext-eastus-rg" `
                            -VMName "JTC-prod-erpnext-eastus-vm"`
                            -Location "eastus" `
                            -AdminUsername "jtadmin"
```

**What this does:**
- Creates Azure Resource Group
- Provisions Ubuntu 24.04 VM (Standard_D2s_v6)
- Configures networking and firewall
- Generates installation script
- Saves connection details to `erpnext-connection-info.json`

**You'll receive:**

- VM public IP address
- Admin credentials
- SSH connection command
- Installation script location

### Step 2: Install ERPNext on VM (20-30 minutes)

After deployment completes:

```powershell
# Get connection info
$connInfo = Get-Content .\erpnext-connection-info.json | ConvertFrom-Json

# Copy installation script to VM
scp .\install-erpnext.sh "$($connInfo.AdminUsername)@$($connInfo.PublicIP):~/"

# SSH into VM
ssh "$($connInfo.AdminUsername)@$($connInfo.PublicIP)"
```

On the VM:
```bash
# Make script executable
chmod +x install-erpnext.sh

# Run installation (takes 20-30 minutes)
sudo ./install-erpnext.sh
```

**Installation includes:**
- MariaDB database
- Redis cache
- Nginx web server
- Python dependencies
- Node.js and Yarn
- Frappe Framework
- ERPNext application
- HRMS module
- Production setup

### Step 3: Access ERPNext

After installation completes:

```
URL: http://[YOUR-VM-IP]
Username: JTCAdmin
Password: Admin@JTCustom2026!
```

**IMPORTANT:** Change the administrator password immediately!

### Step 4: Initial ERPNext Configuration (15 minutes)

1. **Company Setup Wizard:**
   - Company Name: AWS Solutions LLC dba JT Custom Trailers
   - Country: United States
   - Currency: USD
   - Fiscal Year: January to December
   - Chart of Accounts: Standard USA

2. **Create API Keys:**
   - User → Administrator → API Access
   - Generate API Key and Secret
   - Save these securely for WooCommerce integration

3. **Basic Settings:**
   - System Settings → Set timezone to America/New_York
   - Set date format to MM/DD/YYYY
   - Enable email notifications

### Step 5: WooCommerce API Setup (10 minutes)

1. **In WordPress Admin:**
   - WooCommerce → Settings → Advanced → REST API
   - Add Key:
     - Description: ERPNext Integration
     - User: Your admin user
     - Permissions: Read/Write
   - Save Consumer Key and Secret

2. **Test API Connection:**
   ```powershell
   # Test from PowerShell
   $apiUrl = "https://www.jtcustomtrailers.com/wp-json/wc/v3/products"
   $cred = "ck_YOUR_KEY:cs_YOUR_SECRET"
   $encodedCred = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($cred))
   
   $headers = @{
       Authorization = "Basic $encodedCred"
   }
   
   Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Get
   ```

### Step 6: Install WooCommerce Connector (5 minutes)

SSH back into your ERPNext VM:

```bash
cd /home/jtadmin/frappe-bench

# Get WooCommerce connector app
bench get-app woocommerceconnector

# Install on site
bench --site jtcustomtrailers.local install-app woocommerceconnector

# Restart
bench restart
```

### Step 7: Configure WooCommerce Integration (10 minutes)

In ERPNext:

1. **Search:** "WooCommerce Settings"
2. **Configure:**
   ```
   Enable Sync: ✓
   WooCommerce Server URL: https://www.jtcustomtrailers.com
   API Consumer Key: [From WordPress]
   API Consumer Secret: [From WordPress]
   Enable Item Sync: ✓
   Enable Order Sync: ✓
   Warehouse: Main Warehouse
   Company: JT Custom Trailers
   ```
3. **Save**

### Step 8: Import Categories (15 minutes)

Use the category import script:

```powershell
# Install required PowerShell module if not already installed
Install-Module -Name ImportExcel -Force

# Get API credentials from ERPNext
$apiKey = "YOUR_API_KEY"
$apiSecret = "YOUR_API_SECRET"

# Run import
.\Import-ERPNextCategories.ps1 -ProductCategoriesPath ".\ProductCategories.xlsx" `
                                -ERPNextURL "http://YOUR-VM-IP" `
                                -APIKey $apiKey `
                                -APISecret $apiSecret
```

**Optional - Dry Run First:**
```powershell
.\Import-ERPNextCategories.ps1 -ProductCategoriesPath ".\ProductCategories.xlsx" `
                                -ERPNextURL "http://YOUR-VM-IP" `
                                -APIKey $apiKey `
                                -APISecret $apiSecret `
                                -DryRun
```

### Step 9: Create Warehouses (5 minutes)

In ERPNext:

1. **Stock → Warehouse → New**
2. **Create:**
   ```
   Warehouse Name: Main Warehouse
   Parent Warehouse: All Warehouses
   Warehouse Type: Manufacturing
   Address: 1214 Lake Avenue, Ashtabula, OH 44004
   ```
3. **Repeat for Showroom:**
   ```
   Warehouse Name: Showroom - Jefferson
   Parent Warehouse: All Warehouses
   Warehouse Type: Retail
   Address: PO Box 348, Jefferson, OH 44047
   ```

### Step 10: Test Product Sync (10 minutes)

1. **Create Test Item in ERPNext:**
   ```
   Item Code: TEST-SYNC-001
   Item Name: Test Product Sync
   Item Group: Interior
   Standard Rate: 99.99
   Show in Website: ✓
   Opening Stock: 10 (in Main Warehouse)
   ```

2. **Manually Trigger Sync:**
   - WooCommerce Settings → Sync Now

3. **Verify in WooCommerce:**
   - Products → Check for TEST-SYNC-001

4. **Clean Up:**
   - Delete test item from both systems

---

## Troubleshooting Common Issues

### Issue: Can't connect to VM

**Check:**
```powershell
# Test if VM is running
Get-AzVM -ResourceGroupName "rg-jtcustomtrailers-erpnext" -Name "vm-erpnext-prod"

# Test network connectivity
Test-NetConnection -ComputerName YOUR-VM-IP -Port 22
Test-NetConnection -ComputerName YOUR-VM-IP -Port 80
```

**Solution:**
- Verify NSG rules allow ports 22, 80, 443, 8000
- Check VM is running
- Verify public IP is correct

### Issue: ERPNext installation fails

**Check logs:**
```bash
# On the VM
tail -f /var/log/syslog
cd /home/jtadmin/frappe-bench
bench logs
```

**Common fixes:**
```bash
# Restart services
sudo systemctl restart mariadb
sudo systemctl restart redis
sudo supervisorctl restart all

# Reinstall bench
cd /home/jtadmin
rm -rf frappe-bench
bench init frappe-bench --frappe-branch version-15
```

### Issue: WooCommerce API not connecting

**Test API manually:**
```bash
# From VM or local machine
curl -u "ck_YOUR_KEY:cs_YOUR_SECRET" \
     https://www.jtcustomtrailers.com/wp-json/wc/v3/products
```

**Check:**
- SSL certificate is valid on WordPress site
- API keys are correct
- Firewall allows outbound HTTPS from ERPNext VM
- WordPress WooCommerce is active

### Issue: Categories not importing

**Check:**
```powershell
# Verify Excel file is accessible
Test-Path ".\ProductCategories.xlsx"

# Verify ImportExcel module
Get-Module -Name ImportExcel -ListAvailable

# Test ERPNext API
Invoke-RestMethod -Uri "http://YOUR-VM-IP/api/method/frappe.auth.get_logged_user" `
                  -Headers @{Authorization = "token $apiKey`:$apiSecret"}
```

---

## Post-Installation Checklist

- [ ] ERPNext accessible at VM IP
- [ ] Administrator password changed
- [ ] Company information configured
- [ ] API keys generated and saved
- [ ] WooCommerce API connected
- [ ] WooCommerce Connector installed
- [ ] Categories imported (200+ item groups)
- [ ] Warehouses created
- [ ] Test product syncs successfully
- [ ] Test order processes
- [ ] Backups configured
- [ ] SSL certificate installed (optional but recommended)

---

## Next Steps

### Immediate (This Week)
1. Import product catalog from WooCommerce
2. Verify inventory levels
3. Enable order synchronization
4. Train staff on basic ERPNext functions

### Short Term (Next 2 Weeks)
1. Set up supplier records
2. Configure purchase workflows
3. Create BOMs for standard trailer builds
4. Implement work order tracking

### Medium Term (Next Month)
1. Generate custom reports
2. Optimize sync schedules
3. Implement quality checks
4. Full manufacturing integration

### Long Term (Next Quarter)
1. Advanced analytics and dashboards
2. Mobile app deployment
3. Custom integrations (if needed)
4. Process automation

---

## Important Files and Locations

### On Your Local Machine
```
Deploy-ERPNextToAzure.ps1           - Deployment script
install-erpnext.sh                  - Generated install script
erpnext-connection-info.json        - Connection credentials
Import-ERPNextCategories.ps1        - Category import script
ProductCategories.xlsx              - Your category data
WooCommerce-Integration-Guide.md    - Full integration docs
Data-Structure-Plan.md              - Migration planning
```

### On Azure VM
```
/home/jtadmin/frappe-bench/                    - Main ERPNext directory
/home/jtadmin/frappe-bench/sites/              - Site configurations
/home/jtadmin/frappe-bench/logs/               - Application logs
/etc/nginx/                                    - Web server config
/etc/supervisor/conf.d/                        - Process management
```

### Backup Locations
```
ERPNext Backups: /home/jtadmin/frappe-bench/sites/jtcustomtrailers.local/private/backups/
Database Backups: /var/lib/mysql/
```

---

## Getting Help

### Documentation
- **ERPNext Docs:** https://docs.erpnext.com/
- **Frappe Framework:** https://frappeframework.com/docs
- **WooCommerce API:** https://woocommerce.github.io/woocommerce-rest-api-docs/

### Community Support
- **ERPNext Forum:** https://discuss.erpnext.com/
- **Frappe GitHub:** https://github.com/frappe/erpnext

### Your Contact
- **John O'Neill Sr.**
- JONeillSr@jtcustomtrailers.com
- (440) 813-6695

---

## Security Recommendations

### Immediate
1. Change default ERPNext Administrator password
2. Create user accounts (don't use Administrator for daily work)
3. Configure firewall to restrict SSH access
4. Enable two-factor authentication

### Soon
1. Install SSL certificate (Let's Encrypt)
2. Set up automated backups to Azure Blob Storage
3. Configure database backup encryption
4. Implement IP whitelisting for admin access

### Best Practices
1. Regular security updates: `apt update && apt upgrade`
2. Monitor logs for suspicious activity
3. Use strong passwords (20+ characters)
4. Regular backup testing (monthly)

---

## Cost Estimate

### Azure VM (Standard_D2s_v3)
- **Compute:** ~$70/month (2 vCPU, 8GB RAM)
- **Storage:** ~$10/month (128GB Premium SSD)
- **Bandwidth:** ~$5/month (typical e-commerce traffic)
- **Total:** ~$85/month

### vs QuickBooks Online Plus
- **QuickBooks:** $100-200/month + $4-20/user
- **ERPNext:** FREE software + ~$85 infrastructure
- **Savings:** $15-135/month + unlimited users

### ROI
- **Break-even:** Immediate (vs QuickBooks)
- **Additional value:** Inventory, manufacturing, CRM included
- **Scalability:** Same cost for 1 or 100 users

---

## Success Metrics

Track these to measure implementation success:

### Week 1
- [ ] ERPNext deployed and accessible
- [ ] Categories imported
- [ ] 10 test products syncing

### Week 2
- [ ] Full product catalog imported
- [ ] Orders syncing from WooCommerce
- [ ] Staff trained on basics

### Month 1
- [ ] 100% of online orders processed through ERPNext
- [ ] Inventory accuracy >95%
- [ ] First custom trailer work order completed

### Month 3
- [ ] Complete migration from QuickBooks
- [ ] Manufacturing workflows optimized
- [ ] Reporting dashboards created
- [ ] Time savings: 10+ hours/week

---

## Ready to Begin?

You have everything you need to deploy ERPNext for JT Custom Trailers:

1. **Infrastructure:** Azure deployment script
2. **Installation:** Automated ERPNext setup
3. **Integration:** WooCommerce connector ready
4. **Data:** Category structure preserved
5. **Documentation:** Complete guides and plans

**Start with Step 1 above and work through the process. Each step builds on the previous one.**

Good luck with your ERPNext implementation!

---

**Quick Start Guide Version:** 1.0.0  
**Last Updated:** 02/17/2026
