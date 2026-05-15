<#
.SYNOPSIS
    Deploys ERPNext to an Azure Virtual Machine.

.DESCRIPTION
    This script automates the deployment of ERPNext (open-source ERP) on an Azure VM.
    It creates the VM, installs all prerequisites, and sets up ERPNext with recommended
    configurations for a manufacturing and retail business.

.PARAMETER ResourceGroupName
    Name of the Azure Resource Group (default: JTC-prod-erpnext-eastus-rg)

.PARAMETER VMName
    Name of the Virtual Machine (default: JTC-prod-erpnext-eastus-vm)

.PARAMETER Location
    Azure region for deployment (default: eastus)

.PARAMETER VMSize
    Azure VM size (default: Standard_D2s_v6 - 2 vCPU, 8GB RAM)

.PARAMETER AdminUsername
    VM administrator username (default: jtadmin)

.PARAMETER DiskSize
    OS disk size in GB (default: 128)

.EXAMPLE
    .\Deploy-ERPNextToAzure.ps1 -AdminUsername "someadmin"

.NOTES
    Author: John O'Neill Sr.
    Company: Azure Innovators
    Create Date: 02/17/2026
    Version: 1.0.0
    Change Date:
    Change Purpose:

.CHANGELOG
    1.0.0 - 02/17/2026 - Initial release
        - Azure VM provisioning with Ubuntu 24.04
        - ERPNext installation script generation
        - Network security group configuration
        - Static public IP assignment
        - Managed disk with premium SSD
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ResourceGroupName = "JTC-prod-erpnext-eastus-rg",

    [Parameter()]
    [string]$VMName = "JTC-prod-erpnext-eastus-vm",

    [Parameter()]
    [string]$Location = "eastus",

    [Parameter()]
    [string]$VMSize = "Standard_D2s_v6",

    [Parameter()]
    [string]$AdminUsername = "jtadmin",

    [Parameter()]
    [int]$DiskSize = 128
)

#Requires -Modules Az.Accounts, Az.Compute, Az.Network, Az.Resources

# Set strict mode
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Script configuration
$ScriptVersion = "1.0.0"
$CompanyName = "JT Custom Trailers"

Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  ERPNext Azure Deployment Script v$ScriptVersion" -ForegroundColor Cyan
Write-Host "  $CompanyName" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

#region Helper Functions

function Write-LogMessage {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        'Info'    { 'White' }
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
    }

    Write-Host "[$timestamp] $Message" -ForegroundColor $color
}

function Test-AzureConnection {
    try {
        $context = Get-AzContext
        if (-not $context) {
            throw "Not connected to Azure"
        }
        Write-LogMessage "Connected to Azure subscription: $($context.Subscription.Name)" -Level Success
        return $true
    }
    catch {
        Write-LogMessage "Not connected to Azure. Please run Connect-AzAccount first." -Level Error
        return $false
    }
}

#endregion

#region Main Deployment Logic

try {
    # Verify Azure connection
    Write-LogMessage "Verifying Azure connection..." -Level Info
    if (-not (Test-AzureConnection)) {
        exit 1
    }

    # Create Resource Group
    Write-LogMessage "Creating or verifying Resource Group: $ResourceGroupName" -Level Info
    $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $rg) {
        $rg = New-AzResourceGroup -Name $ResourceGroupName -Location $Location
        Write-LogMessage "Resource Group created successfully" -Level Success
    }
    else {
        Write-LogMessage "Resource Group already exists" -Level Info
    }

    # Generate secure password for VM
    Write-LogMessage "Generating secure administrator password..." -Level Info
    $passwordChars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()"
    $password = -join ((1..20) | ForEach-Object { $passwordChars[(Get-Random -Maximum $passwordChars.Length)] })
    $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential ($AdminUsername, $securePassword)

    # Create Network Security Group
    Write-LogMessage "Creating Network Security Group..." -Level Info
    $nsgRules = @(
        New-AzNetworkSecurityRuleConfig -Name "Allow-SSH" -Protocol Tcp `
            -Direction Inbound -Priority 1000 -SourceAddressPrefix * `
            -SourcePortRange * -DestinationAddressPrefix * `
            -DestinationPortRange 22 -Access Allow

        New-AzNetworkSecurityRuleConfig -Name "Allow-HTTP" -Protocol Tcp `
            -Direction Inbound -Priority 1010 -SourceAddressPrefix * `
            -SourcePortRange * -DestinationAddressPrefix * `
            -DestinationPortRange 80 -Access Allow

        New-AzNetworkSecurityRuleConfig -Name "Allow-HTTPS" -Protocol Tcp `
            -Direction Inbound -Priority 1020 -SourceAddressPrefix * `
            -SourcePortRange * -DestinationAddressPrefix * `
            -DestinationPortRange 443 -Access Allow

        New-AzNetworkSecurityRuleConfig -Name "Allow-ERPNext" -Protocol Tcp `
            -Direction Inbound -Priority 1030 -SourceAddressPrefix * `
            -SourcePortRange * -DestinationAddressPrefix * `
            -DestinationPortRange 8000 -Access Allow
    )

    $nsgName = "$VMName-nsg"
    $nsg = New-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName `
        -Location $Location -Name $nsgName -SecurityRules $nsgRules

    # Create Public IP
    Write-LogMessage "Creating Public IP address..." -Level Info
    $pipName = "$VMName-pip"
    $publicIp = New-AzPublicIpAddress -Name $pipName -ResourceGroupName $ResourceGroupName `
        -Location $Location -AllocationMethod Static -Sku Standard

    # Create Virtual Network and Subnet
    Write-LogMessage "Creating Virtual Network..." -Level Info
    $vnetName = "$VMName-vnet"
    $subnetName = "$VMName-subnet"

    $subnetConfig = New-AzVirtualNetworkSubnetConfig -Name $subnetName `
        -AddressPrefix "10.0.1.0/24" -NetworkSecurityGroup $nsg

    $vnet = New-AzVirtualNetwork -Name $vnetName -ResourceGroupName $ResourceGroupName `
        -Location $Location -AddressPrefix "10.0.0.0/16" -Subnet $subnetConfig

    # Create Network Interface
    Write-LogMessage "Creating Network Interface..." -Level Info
    $nicName = "$VMName-nic"
    $nic = New-AzNetworkInterface -Name $nicName -ResourceGroupName $ResourceGroupName `
        -Location $Location -SubnetId $vnet.Subnets[0].Id -PublicIpAddressId $publicIp.Id `
        -NetworkSecurityGroupId $nsg.Id

    # Create VM Configuration
    Write-LogMessage "Configuring Virtual Machine..." -Level Info
    $vmConfig = New-AzVMConfig -VMName $VMName -VMSize $VMSize

    # Set OS configuration
    $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Linux -ComputerName $VMName `
        -Credential $credential -DisablePasswordAuthentication:$false

    # Set source image (Ubuntu 24.04 LTS)
    $vmConfig = Set-AzVMSourceImage -VM $vmConfig -PublisherName "Canonical" `
        -Offer "ubuntu-24_04-lts" -Skus "server" -Version "latest"

    # Add network interface
    $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id

    # Set OS disk
    $vmConfig = Set-AzVMOSDisk -VM $vmConfig -CreateOption FromImage `
        -StorageAccountType Premium_LRS -DiskSizeInGB $DiskSize

    # Disable boot diagnostics (optional, enable if needed for troubleshooting)
    $vmConfig = Set-AzVMBootDiagnostic -VM $vmConfig -Disable

    # Create the VM
    Write-LogMessage "Creating Virtual Machine (this may take several minutes)..." -Level Info
    $vm = New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $vmConfig

    Write-LogMessage "Virtual Machine created successfully!" -Level Success

    # Get the public IP address
    $publicIpAddress = (Get-AzPublicIpAddress -Name $pipName -ResourceGroupName $ResourceGroupName).IpAddress

    # Create ERPNext installation script
    Write-LogMessage "Generating ERPNext installation script..." -Level Info

    $installScript = @"
#!/bin/bash
set -e

echo "════════════════════════════════════════════════════════════"
echo "  ERPNext Installation Script for JT Custom Trailers"
echo "  Generated: $(date)"
echo "════════════════════════════════════════════════════════════"
echo ""

# Update system
echo "[1/8] Updating system packages..."
sudo apt-get update
sudo apt-get upgrade -y

# Install prerequisites
echo "[2/8] Installing prerequisites..."
sudo apt-get install -y git python3-dev python3-pip python3-venv \
    redis-server mariadb-server nginx supervisor curl wget

# Secure MariaDB
echo "[3/8] Configuring MariaDB..."
sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY 'jtcustomtrailers2026!ERPNext';"
sudo mysql -e "DELETE FROM mysql.user WHERE User='';"
sudo mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
sudo mysql -e "DROP DATABASE IF EXISTS test;"
sudo mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
sudo mysql -e "FLUSH PRIVILEGES;"

# Configure MariaDB for ERPNext
echo "[4/8] Optimizing MariaDB configuration..."
sudo tee -a /etc/mysql/mariadb.conf.d/50-server.cnf > /dev/null <<EOF

[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
max_allowed_packet = 256M
innodb_buffer_pool_size = 2G
innodb_log_file_size = 256M
innodb_read_io_threads = 4
innodb_write_io_threads = 4
EOF

sudo systemctl restart mariadb

# Install Node.js and Yarn
echo "[5/8] Installing Node.js and Yarn..."
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs
sudo npm install -g yarn

# Install wkhtmltopdf (for PDF generation)
echo "[6/8] Installing wkhtmltopdf..."
wget https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb
sudo apt-get install -y ./wkhtmltox_0.12.6.1-2.jammy_amd64.deb
rm wkhtmltox_0.12.6.1-2.jammy_amd64.deb

# Install Frappe Bench
echo "[7/8] Installing Frappe Bench..."
sudo pip3 install frappe-bench

# Initialize bench
echo "[8/8] Initializing ERPNext..."
cd /home/$AdminUsername
bench init frappe-bench --frappe-branch version-15
cd frappe-bench

# Get ERPNext
bench get-app erpnext --branch version-15
bench get-app hrms --branch version-15

# Create site
bench new-site jtcustomtrailers.local \
    --mariadb-root-password 'jtcustomtrailers2026!ERPNext' \
    --admin-password 'Admin@JTCustom2026!'

# Install ERPNext
bench --site jtcustomtrailers.local install-app erpnext
bench --site jtcustomtrailers.local install-app hrms

# Setup production
sudo bench setup production $AdminUsername
bench setup nginx
sudo supervisorctl reload

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  ERPNext Installation Complete!"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "Access ERPNext at: http://$publicIpAddress"
echo "Username: Administrator"
echo "Password: Admin@JTCustom2026!"
echo ""
echo "IMPORTANT: Change the administrator password immediately!"
echo "════════════════════════════════════════════════════════════"
"@

    # Save installation script
    $scriptPath = Join-Path $PSScriptRoot "install-erpnext.sh"
    $installScript | Out-File -FilePath $scriptPath -Encoding UTF8 -NoNewline

    # Save connection details
    $connectionInfo = @{
        VMName = $VMName
        PublicIP = $publicIpAddress
        AdminUsername = $AdminUsername
        AdminPassword = $password
        SSHCommand = "ssh ${AdminUsername}@${publicIpAddress}"
        ERPNextURL = "http://${publicIpAddress}"
        ERPNextUsername = "JTCAdmin"
        ERPNextPassword = "Admin@JTCustom2026!"
        MariaDBRootPassword = "jtcustomtrailers2026!ERPNext"
        InstallScriptPath = $scriptPath
    }

    $connectionInfoPath = Join-Path $PSScriptRoot "erpnext-connection-info.json"
    $connectionInfo | ConvertTo-Json -Depth 10 | Out-File -FilePath $connectionInfoPath -Encoding UTF8

    # Display deployment summary
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "  DEPLOYMENT SUCCESSFUL!" -ForegroundColor Green
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host ""
    Write-Host "VM Details:" -ForegroundColor Cyan
    Write-Host "  Name:              $VMName"
    Write-Host "  Public IP:         $publicIpAddress"
    Write-Host "  Admin Username:    $AdminUsername"
    Write-Host "  Admin Password:    $password" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Next Steps:" -ForegroundColor Cyan
    Write-Host "  1. Copy the installation script to the VM:"
    Write-Host "     scp $scriptPath ${AdminUsername}@${publicIpAddress}:~/" -ForegroundColor White
    Write-Host ""
    Write-Host "  2. SSH into the VM:"
    Write-Host "     ssh ${AdminUsername}@${publicIpAddress}" -ForegroundColor White
    Write-Host ""
    Write-Host "  3. Run the installation script:"
    Write-Host "     chmod +x install-erpnext.sh" -ForegroundColor White
    Write-Host "     sudo ./install-erpnext.sh" -ForegroundColor White
    Write-Host ""
    Write-Host "  4. After installation completes (20-30 minutes), access ERPNext:"
    Write-Host "     http://${publicIpAddress}" -ForegroundColor White
    Write-Host ""
    Write-Host "Connection details saved to: $connectionInfoPath" -ForegroundColor Cyan
    Write-Host "Installation script saved to: $scriptPath" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "IMPORTANT: Store the admin password securely!" -ForegroundColor Yellow
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host ""

}
catch {
    Write-LogMessage "Deployment failed: $_" -Level Error
    Write-LogMessage $_.ScriptStackTrace -Level Error
    exit 1
}

#endregion
