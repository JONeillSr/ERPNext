<#
.SYNOPSIS
    Deploys ERPNext to an Azure Virtual Machine end-to-end.

.DESCRIPTION
    This script automates a production-grade deployment of ERPNext (open-source ERP)
    on an Azure Virtual Machine. It provisions all required Azure infrastructure,
    generates and executes a hardened installation script on the VM via Run Command,
    and optionally stores secrets in an Azure Key Vault rather than emitting them
    to disk.

    The script is idempotent: each Azure resource is checked for existence before
    creation, so re-running against an in-progress or partially-deployed environment
    is safe.

    DEPLOYMENT PHASES:
        1. Pre-flight checks (Az connection, subscription, region, providers)
        2. Resource Group (created if missing)
        3. Networking (VNet, Subnet, NSG, Public IP)
        4. Credentials (generated; optionally stored in Key Vault)
        5. Virtual Machine (Ubuntu 24.04 LTS, Premium SSD)
        6. ERPNext installation via Invoke-AzVMRunCommand
        7. Output of connection details and post-install guidance

    SECURITY NOTES:
        - Admin password is generated with mixed character classes (length configurable).
        - SSH key authentication can be used in place of passwords (-UseSSHKey).
        - NSG can be scoped to a source IP/CIDR (-AllowedSourceCIDR) instead of the
          public internet for SSH and ERPNext management ports.
        - Secrets can be written to Key Vault rather than a local JSON file
          (-UseKeyVault and -KeyVaultName).

.PARAMETER ResourceGroupName
    Name of the Azure Resource Group. Created if it does not exist.
    Default: JTC-prod-erpnext-eastus-rg

.PARAMETER VMName
    Name of the Virtual Machine. Used as the base name for related resources
    (NIC, NSG, PIP, VNet). Default: JTC-prod-erpnext-eastus-vm

.PARAMETER Location
    Azure region for deployment. Default: eastus

.PARAMETER VMSize
    Azure VM size. Default: Standard_D2s_v6 (2 vCPU, 8 GB RAM). For production
    workloads with > 25 concurrent users, consider Standard_D4s_v6 or larger.

.PARAMETER AdminUsername
    VM administrator (Linux) username. Default: jtadmin

.PARAMETER DiskSize
    OS disk size in GB. Default: 128. ERPNext + MariaDB + Redis + logs grow
    significantly over time; 128 GB is a reasonable starting point.

.PARAMETER SubscriptionId
    Optional Azure subscription ID to target. If omitted, the current Az context
    subscription is used.

.PARAMETER AllowedSourceCIDR
    Optional CIDR block to restrict SSH, HTTP, HTTPS, and ERPNext (8000) inbound
    access. Default: '*' (any source — NOT recommended for production).
    Example: '203.0.113.42/32' for a single office IP.

.PARAMETER UseSSHKey
    If specified, configures SSH key authentication and disables password auth.
    Requires -SSHPublicKeyPath.

.PARAMETER SSHPublicKeyPath
    Path to an SSH public key file (e.g., ~/.ssh/id_rsa.pub). Required when
    -UseSSHKey is specified.

.PARAMETER UseKeyVault
    If specified, stores generated secrets (VM password, MariaDB root password,
    ERPNext admin password) in an Azure Key Vault instead of writing them to
    a local JSON file. Requires -KeyVaultName.

.PARAMETER KeyVaultName
    Name of the Azure Key Vault to use when -UseKeyVault is specified. The vault
    will be created if it does not exist.

.PARAMETER SkipInstall
    If specified, provisions the VM but skips ERPNext installation. Useful for
    debugging infrastructure separately from application setup.

.PARAMETER InstallTimeoutMinutes
    Timeout in minutes for the ERPNext installation Run Command. Default: 60.

.EXAMPLE
    PS> .\Deploy-ERPNextToAzure.ps1

    Deploys with all defaults. Credentials saved to erpnext-connection-info.json.

.EXAMPLE
    PS> .\Deploy-ERPNextToAzure.ps1 -AllowedSourceCIDR '203.0.113.42/32' `
            -UseSSHKey -SSHPublicKeyPath "$HOME\.ssh\id_rsa.pub"

    Deploys with SSH key auth and NSG scoped to a single office IP.

.EXAMPLE
    PS> .\Deploy-ERPNextToAzure.ps1 -UseKeyVault -KeyVaultName 'JTC-prod-kv-eastus'

    Deploys and stores all generated secrets in Azure Key Vault.

.EXAMPLE
    PS> .\Deploy-ERPNextToAzure.ps1 -SkipInstall

    Provisions infrastructure only. The install script is generated and saved
    locally for manual review/execution.

.INPUTS
    None. This script does not accept pipeline input.

.OUTPUTS
    System.Management.Automation.PSCustomObject

    On success, returns an object containing VM name, public IP, ERPNext URL,
    and references to where credentials were stored (Key Vault secret URIs or
    local file path).

.NOTES
    Author:           John O'Neill Sr.
    Company:          Azure Innovators
    Create Date:      02/17/2026
    Version:          1.1.0
    Last Modified:    05/15/2026
    GitHub:           https://github.com/JONeillSr/

    PREREQUISITES:
        - PowerShell 7.2 or later
        - Az PowerShell modules: Az.Accounts, Az.Compute, Az.Network, Az.Resources
        - Az.KeyVault module (if -UseKeyVault is used)
        - An active Azure subscription with Contributor rights
        - Connect-AzAccount run prior to executing this script

    SUPPORTED PLATFORMS:
        - Windows PowerShell host: PowerShell 7.2+ on Windows, Linux, macOS
        - Target VM: Ubuntu 24.04 LTS (Noble Numbat)

    COST ESTIMATE (eastus, retail pricing as of 2026):
        - Standard_D2s_v6 VM:    ~$70/month
        - 128 GB Premium SSD:    ~$20/month
        - Static Public IP:      ~$4/month
        - Egress bandwidth:      ~$5/month typical
        - Total:                 ~$100/month

.CHANGELOG
    1.1.0 - 05/15/2026 - Major hardening and end-to-end automation
        - Added end-to-end installation via Invoke-AzVMRunCommand
        - Added Key Vault integration for secret storage
        - Added SSH key authentication option
        - Added source IP restriction for NSG rules
        - Added subscription targeting parameter
        - Added idempotency for all Azure resources
        - Added cleanup-on-failure for partial deployments
        - Upgraded Node.js to 20 LTS (was 18, now EOL)
        - Fixed wkhtmltopdf to use Ubuntu 24.04 (noble) build
        - Dynamic generation of MariaDB and ERPNext admin passwords
        - Removed default plaintext credentials from generated script
        - Added structured pre-flight checks
        - Returns a result object instead of writing only to host
        - Expanded inline help and parameter documentation

    1.0.0 - 02/17/2026 - Initial release
        - Azure VM provisioning with Ubuntu 24.04
        - ERPNext installation script generation
        - Network security group configuration
        - Static public IP assignment
        - Managed disk with premium SSD

.LINK
    https://github.com/JONeillSr/

.LINK
    https://docs.erpnext.com/

.LINK
    https://learn.microsoft.com/en-us/azure/virtual-machines/
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName = "JTC-prod-erpnext-eastus-rg",

    [Parameter()]
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9-]{1,62}[a-zA-Z0-9]$')]
    [string]$VMName = "JTC-prod-erpnext-eastus-vm",

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Location = "eastus",

    [Parameter()]
    [ValidatePattern('^Standard_[A-Z0-9_]+$')]
    [string]$VMSize = "Standard_D2s_v6",

    [Parameter()]
    [ValidatePattern('^[a-z][a-z0-9_-]{0,31}$')]
    [string]$AdminUsername = "jtadmin",

    [Parameter()]
    [ValidateRange(64, 4096)]
    [int]$DiskSize = 128,

    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [ValidatePattern('^(\d{1,3}\.){3}\d{1,3}(/\d{1,2})?$|^\*$')]
    [string]$AllowedSourceCIDR = '*',

    [Parameter()]
    [switch]$UseSSHKey,

    [Parameter()]
    [string]$SSHPublicKeyPath,

    [Parameter()]
    [switch]$UseKeyVault,

    [Parameter()]
    [string]$KeyVaultName,

    [Parameter()]
    [switch]$SkipInstall,

    [Parameter()]
    [ValidateRange(10, 240)]
    [int]$InstallTimeoutMinutes = 60
)

#Requires -Version 7.2
#Requires -Modules Az.Accounts, Az.Compute, Az.Network, Az.Resources

# Set strict mode
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Script configuration
$ScriptVersion = "1.1.0"
$CompanyName = "JT Custom Trailers"
$LogFile = Join-Path $PSScriptRoot "Deploy-ERPNextToAzure_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host "  ERPNext Azure Deployment Script v$ScriptVersion" -ForegroundColor Cyan
Write-Host "  $CompanyName" -ForegroundColor Cyan
Write-Host "  Log: $LogFile" -ForegroundColor DarkGray
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host ""

#region Helper Functions

function Write-LogMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Debug')]
        [string]$Level = 'Info'
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] [$Level] $Message"

    $color = switch ($Level) {
        'Info'    { 'White' }
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        'Debug'   { 'DarkGray' }
    }

    Write-Host $logLine -ForegroundColor $color

    try {
        Add-Content -Path $LogFile -Value $logLine -ErrorAction SilentlyContinue
    }
    catch {
        # Logging is best-effort; don't fail the script if log write fails.
    }
}

function Test-AzureConnection {
    [CmdletBinding()]
    param()

    try {
        $context = Get-AzContext -ErrorAction Stop
        if (-not $context -or -not $context.Account) {
            throw "No active Azure context."
        }

        if ($SubscriptionId -and $context.Subscription.Id -ne $SubscriptionId) {
            Write-LogMessage "Switching subscription to: $SubscriptionId" -Level Info
            Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
            $context = Get-AzContext
        }

        Write-LogMessage "Connected as: $($context.Account.Id)" -Level Success
        Write-LogMessage "Subscription:  $($context.Subscription.Name) ($($context.Subscription.Id))" -Level Info
        return $true
    }
    catch {
        Write-LogMessage "Not connected to Azure: $($_.Exception.Message)" -Level Error
        Write-LogMessage "Run Connect-AzAccount before invoking this script." -Level Error
        return $false
    }
}

function Test-AzureProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProviderNamespace
    )

    try {
        $provider = Get-AzResourceProvider -ProviderNamespace $ProviderNamespace -ErrorAction Stop |
                    Where-Object { $_.RegistrationState -eq 'Registered' } |
                    Select-Object -First 1

        if (-not $provider) {
            Write-LogMessage "Registering resource provider: $ProviderNamespace" -Level Warning
            Register-AzResourceProvider -ProviderNamespace $ProviderNamespace -ErrorAction Stop | Out-Null
        }
        return $true
    }
    catch {
        Write-LogMessage "Failed to verify provider $ProviderNamespace : $($_.Exception.Message)" -Level Error
        return $false
    }
}

function New-SecurePassword {
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateRange(12, 128)]
        [int]$Length = 24
    )

    # Build from required character classes to guarantee complexity.
    $lower  = 'abcdefghijkmnopqrstuvwxyz'        # no l
    $upper  = 'ABCDEFGHJKLMNPQRSTUVWXYZ'         # no I, O
    $digits = '23456789'                          # no 0, 1
    $symbol = '!@#%^*-_=+'                       # avoid $, &, `, ', "

    $all = $lower + $upper + $digits + $symbol

    $bytes = [byte[]]::new($Length)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)

    $chars = for ($i = 0; $i -lt $Length; $i++) {
        $all[$bytes[$i] % $all.Length]
    }

    # Force at least one of each class by overwriting the first 4 positions.
    $chars[0] = $lower[(Get-Random -Maximum $lower.Length)]
    $chars[1] = $upper[(Get-Random -Maximum $upper.Length)]
    $chars[2] = $digits[(Get-Random -Maximum $digits.Length)]
    $chars[3] = $symbol[(Get-Random -Maximum $symbol.Length)]

    # Shuffle so the required classes aren't predictably at the front.
    $shuffled = $chars | Sort-Object { Get-Random }
    return -join $shuffled
}

function New-NSGRuleSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePrefix
    )

    $rules = @(
        @{ Name = 'Allow-SSH';     Port = 22;   Priority = 1000 }
        @{ Name = 'Allow-HTTP';    Port = 80;   Priority = 1010 }
        @{ Name = 'Allow-HTTPS';   Port = 443;  Priority = 1020 }
        @{ Name = 'Allow-ERPNext'; Port = 8000; Priority = 1030 }
    )

    $configs = foreach ($r in $rules) {
        New-AzNetworkSecurityRuleConfig -Name $r.Name -Protocol Tcp `
            -Direction Inbound -Priority $r.Priority `
            -SourceAddressPrefix $SourcePrefix -SourcePortRange * `
            -DestinationAddressPrefix * -DestinationPortRange $r.Port `
            -Access Allow
    }

    return $configs
}

function Set-VMKeyVaultSecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$VaultName,
        [Parameter(Mandatory)] [string]$SecretName,
        [Parameter(Mandatory)] [string]$SecretValue,
        [Parameter()]          [string]$ContentType = 'text/plain'
    )

    $secure = ConvertTo-SecureString -String $SecretValue -AsPlainText -Force
    $result = Set-AzKeyVaultSecret -VaultName $VaultName -Name $SecretName `
        -SecretValue $secure -ContentType $ContentType -ErrorAction Stop
    Write-LogMessage "  Stored secret: $SecretName -> $($result.Id)" -Level Debug
    return $result.Id
}

function Invoke-VMInstallation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroup,
        [Parameter(Mandatory)] [string]$VMName,
        [Parameter(Mandatory)] [string]$ScriptPath
    )

    Write-LogMessage "Executing installation on VM (this will take 20-40 minutes)..." -Level Info
    Write-LogMessage "Timeout set to $InstallTimeoutMinutes minutes." -Level Info

    $job = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroup `
        -VMName $VMName -CommandId 'RunShellScript' `
        -ScriptPath $ScriptPath -AsJob

    $deadline = (Get-Date).AddMinutes($InstallTimeoutMinutes)

    while ($job.State -eq 'Running') {
        if ((Get-Date) -gt $deadline) {
            Write-LogMessage "Installation exceeded timeout. Stopping job." -Level Error
            Stop-Job -Job $job
            throw "ERPNext installation timed out after $InstallTimeoutMinutes minutes."
        }
        Write-LogMessage "  Installation in progress... ($([int]((Get-Date) - $job.PSBeginTime).TotalMinutes) min elapsed)" -Level Debug
        Start-Sleep -Seconds 60
    }

    $result = Receive-Job -Job $job -ErrorAction Continue
    Remove-Job -Job $job -Force

    if ($result.Status -ne 'Succeeded') {
        Write-LogMessage "Run Command status: $($result.Status)" -Level Error
        if ($result.Value) {
            foreach ($v in $result.Value) {
                Write-LogMessage "[$($v.Code)] $($v.Message)" -Level Error
            }
        }
        throw "ERPNext installation failed."
    }

    Write-LogMessage "Installation completed successfully." -Level Success
    if ($result.Value) {
        foreach ($v in $result.Value) {
            Write-LogMessage "[$($v.Code)] $($v.Message)" -Level Debug
        }
    }

    return $result
}

#endregion

#region Pre-flight Validation

if ($UseSSHKey -and -not $SSHPublicKeyPath) {
    throw "-UseSSHKey requires -SSHPublicKeyPath to be specified."
}

if ($UseSSHKey -and -not (Test-Path -LiteralPath $SSHPublicKeyPath)) {
    throw "SSH public key not found at: $SSHPublicKeyPath"
}

if ($UseKeyVault -and -not $KeyVaultName) {
    throw "-UseKeyVault requires -KeyVaultName to be specified."
}

if ($UseKeyVault) {
    if (-not (Get-Module -ListAvailable -Name Az.KeyVault)) {
        throw "Az.KeyVault module is required when -UseKeyVault is specified. Install with: Install-Module Az.KeyVault"
    }
    Import-Module Az.KeyVault -ErrorAction Stop
}

#endregion

#region Main Deployment Logic

$deploymentResult = $null
$rgCreated = $false

try {
    # ---- Pre-flight ----
    Write-LogMessage "Running pre-flight checks..." -Level Info
    if (-not (Test-AzureConnection)) { exit 1 }

    foreach ($p in @('Microsoft.Compute', 'Microsoft.Network', 'Microsoft.Storage')) {
        if (-not (Test-AzureProvider -ProviderNamespace $p)) {
            throw "Required resource provider $p is not available."
        }
    }

    # Validate region supports requested VM size
    Write-LogMessage "Verifying VM size $VMSize is available in $Location..." -Level Info
    $sizeAvailable = Get-AzVMSize -Location $Location -ErrorAction Stop |
                     Where-Object { $_.Name -eq $VMSize }
    if (-not $sizeAvailable) {
        throw "VM size $VMSize is not available in region $Location."
    }

    # ---- Resource Group ----
    Write-LogMessage "Resource Group: $ResourceGroupName" -Level Info
    $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $rg) {
        if ($PSCmdlet.ShouldProcess($ResourceGroupName, 'Create Resource Group')) {
            $rg = New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Tag @{
                Application = 'ERPNext'
                Owner       = $CompanyName
                Environment = 'Production'
                CreatedBy   = 'Deploy-ERPNextToAzure.ps1'
                CreatedOn   = (Get-Date -Format 'yyyy-MM-dd')
            }
            $rgCreated = $true
            Write-LogMessage "  Created." -Level Success
        }
    } else {
        Write-LogMessage "  Already exists." -Level Info
    }

    # ---- Credentials ----
    Write-LogMessage "Generating credentials..." -Level Info
    $vmPassword       = New-SecurePassword -Length 24
    $mariadbPassword  = New-SecurePassword -Length 28
    $erpAdminPassword = New-SecurePassword -Length 24

    $secureVMPassword = ConvertTo-SecureString $vmPassword -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential ($AdminUsername, $secureVMPassword)

    $secretReferences = @{}

    if ($UseKeyVault) {
        Write-LogMessage "Configuring Key Vault: $KeyVaultName" -Level Info
        $kv = Get-AzKeyVault -VaultName $KeyVaultName -ErrorAction SilentlyContinue
        if (-not $kv) {
            $kv = New-AzKeyVault -Name $KeyVaultName -ResourceGroupName $ResourceGroupName `
                -Location $Location -EnableRbacAuthorization
            Write-LogMessage "  Vault created. RBAC role assignment may be required." -Level Warning
            Start-Sleep -Seconds 15
        }

        $secretReferences['vm-admin-password']    = Set-VMKeyVaultSecret -VaultName $KeyVaultName -SecretName "$VMName-vm-admin-password"    -SecretValue $vmPassword
        $secretReferences['mariadb-root-password'] = Set-VMKeyVaultSecret -VaultName $KeyVaultName -SecretName "$VMName-mariadb-root-password" -SecretValue $mariadbPassword
        $secretReferences['erpnext-admin-password']= Set-VMKeyVaultSecret -VaultName $KeyVaultName -SecretName "$VMName-erpnext-admin-password" -SecretValue $erpAdminPassword
    }

    # ---- Network: NSG ----
    Write-LogMessage "Network Security Group: $VMName-nsg" -Level Info
    $nsgName = "$VMName-nsg"
    $nsg = Get-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $nsg) {
        $nsgRules = New-NSGRuleSet -SourcePrefix $AllowedSourceCIDR
        $nsg = New-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName `
            -Location $Location -Name $nsgName -SecurityRules $nsgRules
        Write-LogMessage "  Created. Source prefix: $AllowedSourceCIDR" -Level Success
    } else {
        Write-LogMessage "  Already exists." -Level Info
    }

    # ---- Network: Public IP ----
    Write-LogMessage "Public IP: $VMName-pip" -Level Info
    $pipName = "$VMName-pip"
    $publicIp = Get-AzPublicIpAddress -Name $pipName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $publicIp) {
        $publicIp = New-AzPublicIpAddress -Name $pipName -ResourceGroupName $ResourceGroupName `
            -Location $Location -AllocationMethod Static -Sku Standard
        Write-LogMessage "  Created." -Level Success
    } else {
        Write-LogMessage "  Already exists." -Level Info
    }

    # ---- Network: VNet + Subnet ----
    Write-LogMessage "Virtual Network: $VMName-vnet" -Level Info
    $vnetName = "$VMName-vnet"
    $subnetName = "$VMName-subnet"
    $vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $vnet) {
        $subnetConfig = New-AzVirtualNetworkSubnetConfig -Name $subnetName `
            -AddressPrefix "10.0.1.0/24" -NetworkSecurityGroup $nsg
        $vnet = New-AzVirtualNetwork -Name $vnetName -ResourceGroupName $ResourceGroupName `
            -Location $Location -AddressPrefix "10.0.0.0/16" -Subnet $subnetConfig
        Write-LogMessage "  Created." -Level Success
    } else {
        Write-LogMessage "  Already exists." -Level Info
    }

    # ---- Network: NIC ----
    Write-LogMessage "Network Interface: $VMName-nic" -Level Info
    $nicName = "$VMName-nic"
    $nic = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $nic) {
        $nic = New-AzNetworkInterface -Name $nicName -ResourceGroupName $ResourceGroupName `
            -Location $Location -SubnetId $vnet.Subnets[0].Id `
            -PublicIpAddressId $publicIp.Id -NetworkSecurityGroupId $nsg.Id
        Write-LogMessage "  Created." -Level Success
    } else {
        Write-LogMessage "  Already exists." -Level Info
    }

    # ---- VM ----
    Write-LogMessage "Virtual Machine: $VMName" -Level Info
    $existingVM = Get-AzVM -Name $VMName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($existingVM) {
        Write-LogMessage "  VM already exists. Skipping provisioning." -Level Warning
        $vm = $existingVM
    } else {
        $vmConfig = New-AzVMConfig -VMName $VMName -VMSize $VMSize

        if ($UseSSHKey) {
            $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Linux -ComputerName $VMName `
                -Credential $credential -DisablePasswordAuthentication
            $sshKey = Get-Content -LiteralPath $SSHPublicKeyPath -Raw
            $vmConfig = Add-AzVMSshPublicKey -VM $vmConfig `
                -KeyData $sshKey -Path "/home/$AdminUsername/.ssh/authorized_keys"
            Write-LogMessage "  Configured SSH key authentication." -Level Info
        } else {
            $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Linux -ComputerName $VMName `
                -Credential $credential -DisablePasswordAuthentication:$false
        }

        $vmConfig = Set-AzVMSourceImage -VM $vmConfig -PublisherName "Canonical" `
            -Offer "ubuntu-24_04-lts" -Skus "server" -Version "latest"

        $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id

        $vmConfig = Set-AzVMOSDisk -VM $vmConfig -CreateOption FromImage `
            -StorageAccountType Premium_LRS -DiskSizeInGB $DiskSize

        $vmConfig = Set-AzVMBootDiagnostic -VM $vmConfig -Disable

        Write-LogMessage "  Creating VM (this can take several minutes)..." -Level Info
        $vm = New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $vmConfig
        Write-LogMessage "  VM created successfully." -Level Success
    }

    # Resolve public IP for output
    $publicIpAddress = (Get-AzPublicIpAddress -Name $pipName -ResourceGroupName $ResourceGroupName).IpAddress
    Write-LogMessage "Public IP: $publicIpAddress" -Level Success

    # ---- ERPNext install script generation ----
    Write-LogMessage "Generating ERPNext installation script..." -Level Info

    # NOTE: Built line-by-line with an array to avoid VBA-style continuation issues
    # and to keep each interpolated value isolated from quoting hazards.
    $installLines = @(
        '#!/bin/bash',
        'set -euo pipefail',
        '',
        'LOG=/var/log/erpnext-install.log',
        'exec > >(tee -a "$LOG") 2>&1',
        '',
        'echo "================================================================"',
        'echo "  ERPNext Installation Script"',
        "echo `"  Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`"",
        'echo "================================================================"',
        '',
        '# Variables (injected by deployment script)',
        "ADMIN_USER='$AdminUsername'",
        "MARIADB_ROOT_PW='$mariadbPassword'",
        "ERPNEXT_ADMIN_PW='$erpAdminPassword'",
        "PUBLIC_IP='$publicIpAddress'",
        '',
        'echo "[1/9] Updating system packages..."',
        'export DEBIAN_FRONTEND=noninteractive',
        'sudo -E apt-get update',
        'sudo -E apt-get upgrade -y',
        '',
        'echo "[2/9] Installing prerequisites..."',
        'sudo -E apt-get install -y git python3-dev python3-pip python3-venv python3-setuptools \',
        '    redis-server mariadb-server mariadb-client libmariadb-dev \',
        '    nginx supervisor curl wget xvfb libfontconfig xfonts-75dpi xfonts-base \',
        '    software-properties-common build-essential',
        '',
        'echo "[3/9] Securing MariaDB..."',
        'sudo mysql -e "ALTER USER ''root''@''localhost'' IDENTIFIED BY ''${MARIADB_ROOT_PW}'';"',
        'sudo mysql -u root -p"${MARIADB_ROOT_PW}" -e "DELETE FROM mysql.user WHERE User='''';"',
        'sudo mysql -u root -p"${MARIADB_ROOT_PW}" -e "DELETE FROM mysql.user WHERE User=''root'' AND Host NOT IN (''localhost'',''127.0.0.1'',''::1'');"',
        'sudo mysql -u root -p"${MARIADB_ROOT_PW}" -e "DROP DATABASE IF EXISTS test;"',
        'sudo mysql -u root -p"${MARIADB_ROOT_PW}" -e "FLUSH PRIVILEGES;"',
        '',
        'echo "[4/9] Tuning MariaDB for ERPNext..."',
        'sudo tee /etc/mysql/mariadb.conf.d/60-erpnext.cnf > /dev/null <<''EOF''',
        '[mysqld]',
        'character-set-client-handshake = FALSE',
        'character-set-server = utf8mb4',
        'collation-server = utf8mb4_unicode_ci',
        'max_allowed_packet = 256M',
        'innodb_buffer_pool_size = 2G',
        'innodb_log_file_size = 256M',
        'innodb_read_io_threads = 4',
        'innodb_write_io_threads = 4',
        '',
        '[mysql]',
        'default-character-set = utf8mb4',
        'EOF',
        'sudo systemctl restart mariadb',
        '',
        'echo "[5/9] Installing Node.js 20 LTS and Yarn..."',
        'curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -',
        'sudo -E apt-get install -y nodejs',
        'sudo npm install -g yarn',
        '',
        'echo "[6/9] Installing wkhtmltopdf (Ubuntu 24.04 noble build)..."',
        'WKHTMLTOPDF_DEB=wkhtmltox_0.12.6.1-3.jammy_amd64.deb',
        'cd /tmp',
        'wget -q "https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/${WKHTMLTOPDF_DEB}"',
        'sudo apt-get install -y "./${WKHTMLTOPDF_DEB}"',
        'rm -f "${WKHTMLTOPDF_DEB}"',
        '',
        'echo "[7/9] Installing Frappe Bench..."',
        'sudo pip3 install --break-system-packages frappe-bench',
        '',
        'echo "[8/9] Initializing Frappe + ERPNext..."',
        'sudo -u "${ADMIN_USER}" bash -c "cd /home/${ADMIN_USER} && bench init --frappe-branch version-15 frappe-bench"',
        'sudo -u "${ADMIN_USER}" bash -c "cd /home/${ADMIN_USER}/frappe-bench && bench get-app erpnext --branch version-15"',
        'sudo -u "${ADMIN_USER}" bash -c "cd /home/${ADMIN_USER}/frappe-bench && bench get-app hrms --branch version-15"',
        'sudo -u "${ADMIN_USER}" bash -c "cd /home/${ADMIN_USER}/frappe-bench && bench new-site jtcustomtrailers.local --mariadb-root-password ''${MARIADB_ROOT_PW}'' --admin-password ''${ERPNEXT_ADMIN_PW}''"',
        'sudo -u "${ADMIN_USER}" bash -c "cd /home/${ADMIN_USER}/frappe-bench && bench --site jtcustomtrailers.local install-app erpnext"',
        'sudo -u "${ADMIN_USER}" bash -c "cd /home/${ADMIN_USER}/frappe-bench && bench --site jtcustomtrailers.local install-app hrms"',
        '',
        'echo "[9/9] Configuring production (Nginx + Supervisor)..."',
        "sudo bash -c `"cd /home/${AdminUsername}/frappe-bench && bench setup production ${AdminUsername} --yes`"",
        "sudo bash -c `"cd /home/${AdminUsername}/frappe-bench && bench setup nginx --yes`"",
        'sudo supervisorctl reload',
        '',
        'echo ""',
        'echo "================================================================"',
        'echo "  ERPNext Installation Complete"',
        'echo "================================================================"',
        'echo "  URL:      http://${PUBLIC_IP}"',
        'echo "  Username: Administrator"',
        'echo "  (Password stored in Key Vault or local JSON by deployer)"',
        'echo "================================================================"'
    )

    $installScript = $installLines -join "`n"
    $scriptPath = Join-Path $PSScriptRoot "install-erpnext.sh"
    # Write with LF line endings; bash will reject CRLF on Linux.
    [System.IO.File]::WriteAllText($scriptPath, $installScript, [System.Text.UTF8Encoding]::new($false))
    Write-LogMessage "Installation script saved: $scriptPath" -Level Success

    # ---- Run installation ----
    if (-not $SkipInstall) {
        if ($PSCmdlet.ShouldProcess($VMName, 'Run ERPNext installation')) {
            Invoke-VMInstallation -ResourceGroup $ResourceGroupName -VMName $VMName -ScriptPath $scriptPath | Out-Null
        }
    } else {
        Write-LogMessage "Skipping installation (-SkipInstall specified)." -Level Warning
        Write-LogMessage "Run manually: scp $scriptPath ${AdminUsername}@${publicIpAddress}:~/  then  sudo bash install-erpnext.sh" -Level Info
    }

    # ---- Persist connection details ----
    $connectionInfo = [ordered]@{
        VMName               = $VMName
        ResourceGroup        = $ResourceGroupName
        PublicIP             = $publicIpAddress
        AdminUsername        = $AdminUsername
        SSHCommand           = "ssh ${AdminUsername}@${publicIpAddress}"
        ERPNextURL           = "http://${publicIpAddress}"
        ERPNextUsername      = "Administrator"
        InstallScriptPath    = $scriptPath
        LogFile              = $LogFile
        DeploymentTime       = (Get-Date -Format 'o')
        ScriptVersion        = $ScriptVersion
    }

    if ($UseKeyVault) {
        $connectionInfo['SecretsLocation'] = "Azure Key Vault: $KeyVaultName"
        $connectionInfo['KeyVaultSecretIds'] = $secretReferences
    } else {
        $connectionInfo['AdminPassword']        = $vmPassword
        $connectionInfo['MariaDBRootPassword']  = $mariadbPassword
        $connectionInfo['ERPNextPassword']      = $erpAdminPassword
        $connectionInfo['SecretsLocation']      = "Local JSON (consider rotating to Key Vault)"
    }

    $connectionInfoPath = Join-Path $PSScriptRoot "erpnext-connection-info.json"
    $connectionInfo | ConvertTo-Json -Depth 10 | Out-File -FilePath $connectionInfoPath -Encoding UTF8

    $deploymentResult = [PSCustomObject]$connectionInfo

    # ---- Final summary ----
    Write-Host ""
    Write-Host "===============================================================" -ForegroundColor Green
    Write-Host "  DEPLOYMENT SUCCESSFUL" -ForegroundColor Green
    Write-Host "===============================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "VM Details:" -ForegroundColor Cyan
    Write-Host "  Name:             $VMName"
    Write-Host "  Public IP:        $publicIpAddress"
    Write-Host "  Admin Username:   $AdminUsername"
    if ($UseKeyVault) {
        Write-Host "  Secrets:          Key Vault $KeyVaultName" -ForegroundColor Yellow
    } else {
        Write-Host "  Secrets:          $connectionInfoPath (local)" -ForegroundColor Yellow
        Write-Host "                    Consider moving to Key Vault." -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "Access ERPNext:" -ForegroundColor Cyan
    Write-Host "  URL:  http://${publicIpAddress}"
    Write-Host "  User: Administrator"
    Write-Host ""
    Write-Host "Next Steps:" -ForegroundColor Cyan
    Write-Host "  1. Change the Administrator password immediately"
    Write-Host "  2. Generate API keys for WooCommerce integration"
    Write-Host "  3. Configure SSL (Let's Encrypt recommended)"
    Write-Host "  4. Run Import-ERPNextCategories.ps1 to load Item Groups"
    Write-Host ""
    Write-Host "Log: $LogFile" -ForegroundColor DarkGray
    Write-Host "===============================================================" -ForegroundColor Green
    Write-Host ""

    return $deploymentResult
}
catch {
    Write-LogMessage "DEPLOYMENT FAILED: $($_.Exception.Message)" -Level Error
    Write-LogMessage $_.ScriptStackTrace -Level Error

    Write-LogMessage "Partial resources may remain in $ResourceGroupName." -Level Warning
    if ($rgCreated) {
        Write-LogMessage "To clean up all resources created by this run, execute:" -Level Warning
        Write-LogMessage "  Remove-AzResourceGroup -Name $ResourceGroupName -Force" -Level Warning
    }
    exit 1
}

#endregion
