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
    Optional Azure subscription ID to target. If omitted and the account has
    access to multiple subscriptions, you must also pass -SelectContext or
    -ConfirmContext to acknowledge which subscription is active.

.PARAMETER TenantId
    Optional Azure tenant (directory) ID to target. Useful when the same
    account has access to multiple tenants (typical for consultants working
    with multiple clients). When specified, the script switches to that tenant
    before resolving the subscription.

.PARAMETER SelectContext
    If specified, presents an interactive picker listing all accessible
    subscriptions across all tenants the account can see. The selected
    subscription becomes the active context for the deployment.

.PARAMETER ConfirmContext
    Explicit acknowledgment that the currently active Az context is the
    intended target. Required when the account has access to multiple
    subscriptions and neither -SubscriptionId nor -SelectContext is supplied.
    This is a deliberate safety gate for multi-tenant consultants.

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

    The running identity needs the following Azure permissions:
        - Contributor at Resource Group scope (to create the vault if needed)
        - Owner or User Access Administrator at vault or RG scope (to assign
          the Key Vault Secrets Officer role to itself for data-plane access).

    If your account has only Contributor, have an Owner/UAA pre-create the
    vault and pre-grant you Key Vault Secrets Officer, then re-run.

.PARAMETER KeyVaultName
    Name of the Azure Key Vault to use when -UseKeyVault is specified. The vault
    will be created with RBAC authorization enabled if it does not exist. The
    script will assign 'Key Vault Secrets Officer' to the running identity if
    that role is not already in place, and wait for RBAC propagation before
    writing secrets.

.PARAMETER SkipInstall
    If specified, provisions the VM but skips ERPNext installation. Useful for
    debugging infrastructure separately from application setup.

.PARAMETER InstallTimeoutMinutes
    Timeout in minutes for the ERPNext installation Run Command. Default: 60.

.PARAMETER PrivateOnly
    Deploy without a public IP. The VM gets only a private NIC and is reachable
    only from within the VNet, peered VNets, or VPN-connected clients. NSG
    rules tighten automatically to allow inbound only from the 'VirtualNetwork'
    service tag. Use this for production deployments accessed via Azure VPN
    Gateway or VNet peering.

.PARAMETER ExistingVNetName
    Name of an existing VNet to join. When set, the script does NOT create
    a new VNet - it adds a subnet to the existing one and places the VM there.
    Use this when ERPNext needs to communicate privately with other services
    (e.g., a WordPress App Service) already running in your Azure environment.

.PARAMETER ExistingVNetResourceGroup
    Resource group containing the existing VNet. Defaults to the deployment
    RG if not specified. VNets often live in shared/infrastructure RGs that
    are separate from the application's RG; this lets you specify that.

.PARAMETER SubnetName
    Name of the subnet to use within the existing VNet. If a subnet with
    this name already exists, the VM joins it. If it doesn't, the script
    creates one at the address prefix specified by -SubnetAddressPrefix.
    Default: erpnext-subnet.

.PARAMETER SubnetAddressPrefix
    CIDR for a newly-created subnet inside the existing VNet. Must not
    overlap any existing subnet in that VNet. The script validates this
    before attempting to create the subnet. Default: 10.0.2.0/27 (32 IPs).

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
    PS> .\Deploy-ERPNextToAzure.ps1 -ConfirmContext `
            -UseKeyVault -KeyVaultName 'JTC-prod-westus2-kv' `
            -Location 'westus2' `
            -PrivateOnly `
            -ExistingVNetName 'jtcustomtr-2e886f0313-vnet' `
            -ExistingVNetResourceGroup 'JTC-Prod-WP-WestUS2-rg'

    Production-style deployment: no public IP, joins an existing VNet
    (e.g., the one hosting your WordPress App Service), NSG locked to the
    VirtualNetwork service tag. Reachable only from VPN-connected clients
    or services running in the same VNet (or peered VNets).

.EXAMPLE
    PS> .\Deploy-ERPNextToAzure.ps1 -SkipInstall

    Provisions infrastructure only. The install script is generated and saved
    locally for manual review/execution.

.EXAMPLE
    PS> .\Deploy-ERPNextToAzure.ps1 -TenantId '11111111-2222-3333-4444-555555555555' `
            -SubscriptionId '66666666-7777-8888-9999-000000000000'

    Multi-tenant scenario: explicitly target a specific client tenant and
    subscription, regardless of the active Az context. Recommended for
    consultants with access to multiple client environments.

.EXAMPLE
    PS> .\Deploy-ERPNextToAzure.ps1 -SelectContext

    Presents an interactive picker showing all accessible subscriptions across
    all tenants. Useful when you want to confirm visually which client
    environment the deployment is targeting before any resources are created.

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
    Version:          1.6.5
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
    1.5.0 - 05/16/2026 - Multi-tenant safety, Key Vault hardening, install reliability

        End-to-end installation is now genuinely reliable. Major capability
        areas added since 1.1.0:

        Multi-tenant safety (was 1.2.0)
        - Added -TenantId, -SubscriptionId, -SelectContext, -ConfirmContext
          parameters for safe operation against multiple Azure AD tenants
        - Active context is displayed before any destructive operation
        - When more than one subscription is accessible and none is pinned,
          the script refuses to proceed without -ConfirmContext
        - Cross-subscription search on resource-not-found

        Key Vault data-plane reliability (was 1.3.0-1.3.3)
        - Auto-grants 'Key Vault Secrets Officer' role to the current
          principal on vault creation when -UseKeyVault is supplied
        - Polls for RBAC propagation before attempting writes
        - Detects pre-existing vaults and verifies access rather than
          re-assigning roles
        - Self-healing for stale Az token cache: when secret write returns
          403 with a different principal OID, the script extracts the OID
          and grants the role to that one as well
        - Retry-with-backoff on Set-Secret as a final safety net
        - Probe secret uses naming-compliant pattern (^[0-9a-zA-Z-]+$)

        Install reliability (was 1.4.0, 1.4.2)
        - Frappe-managed Redis instances (queue, cache, etc.) are now
          started before 'bench new-site' rather than relying on supervisor
          which runs later. Without this, new-site fails with connection
          refused
        - Redis ports are DISCOVERED from config/redis_*.conf rather than
          hardcoded - forward-compatible with Frappe version changes
          (v15 has 2 instances on ports 11000/13000, v14 had 3 instances)
        - Redis startup logic is delivered as an embedded helper script
          (/tmp/start-redis-instances.sh) so the complex bash control flow
          lives in pure bash, not PowerShell strings

        Genuine success detection (was 1.4.0, 1.4.1)
        - Run Command 'Status=Succeeded' only means the bash was delivered
          and ran. Previously the deploy declared success even when the
          install bombed mid-run. Now the bash emits a sentinel line
          'ERPNEXT_INSTALL_STATUS=SUCCESS' only after every step
          completes, and the deploy script scans stdout for that sentinel
          before reporting success
        - On install failure, dumps last 50 lines of stdout, all stderr,
          and the exact Invoke-AzVMRunCommand to retrieve the full log
          from /var/log/erpnext-install.log on the VM
        - Write-LogMessage accepts empty strings via [AllowEmptyString()]
          to prevent diagnostic dumps from breaking when one channel
          (typically stderr) is empty

        Parser/quoting hardening (was 1.4.3-1.4.7)
        - Eliminated PowerShell parser landmines in bash-generation code:
          * <name> placeholder syntax (< is reserved redirection operator)
          * Quad-apostrophe ambiguity in single-quoted strings
          * @' and @" sequences mid-string (here-string opener collision)
          * Orphan backslash-backtick inside double-quoted strings
            (escapes the closing quote and creates runaway string)
        - Complex bash blocks (SQL operations, site creation) now live in
          PowerShell here-strings (@'...'@) which are fully literal

    1.1.0 - 05/15/2026 - End-to-end automation, Key Vault, SSH key support

        First major release after baseline. Made the script production-grade:

        - Added end-to-end installation via Invoke-AzVMRunCommand
        - Added Key Vault integration for secret storage
        - Added SSH key authentication option (-UseSSHKey, -SSHPublicKeyPath)
        - Added source IP restriction for NSG rules (-AllowedSourceCIDR)
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
    [string]$TenantId,

    [Parameter()]
    [switch]$SelectContext,

    [Parameter()]
    [switch]$ConfirmContext,

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
    [int]$InstallTimeoutMinutes = 60,

    [Parameter(HelpMessage='Deploy without a public IP. The VM gets only a private NIC and is reachable only from within the VNet (or peered VNets / VPN-connected clients).')]
    [switch]$PrivateOnly,

    [Parameter(HelpMessage='Name of an existing VNet to join. When set, the script does NOT create a new VNet. Use with -ExistingVNetResourceGroup if the VNet lives in a different RG.')]
    [string]$ExistingVNetName,

    [Parameter(HelpMessage='Resource group containing the existing VNet (defaults to the deployment RG if not set).')]
    [string]$ExistingVNetResourceGroup,

    [Parameter(HelpMessage='Name of the subnet to use within the existing VNet. Created if missing. Default: erpnext-subnet.')]
    [string]$SubnetName = 'erpnext-subnet',

    [Parameter(HelpMessage='CIDR for a newly-created subnet inside the existing VNet. Must not overlap any existing subnet. Default: 10.0.2.0/27.')]
    [ValidatePattern('^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$')]
    [string]$SubnetAddressPrefix = '10.0.2.0/27'
)

#Requires -Version 7.2
#Requires -Modules Az.Accounts, Az.Compute, Az.Network, Az.Resources

# Set strict mode
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# If the user changed -Location but accepted the default RG/VM names (which
# embed "eastus"), substitute the new location into those names so the
# resource names stay consistent with where they actually live. The user
# can still override by passing explicit -ResourceGroupName / -VMName.
if ($Location -ne 'eastus') {
    if ($PSBoundParameters.Keys -notcontains 'ResourceGroupName') {
        $ResourceGroupName = $ResourceGroupName -replace '-eastus-', "-$Location-"
    }
    if ($PSBoundParameters.Keys -notcontains 'VMName') {
        $VMName = $VMName -replace '-eastus-', "-$Location-"
    }
}

# Script configuration
$ScriptVersion = "1.6.5"
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
        [AllowEmptyString()]
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

function Select-AzureContext {
    <#
    .SYNOPSIS
        Resolves and validates the active Azure context for multi-tenant use.

    .DESCRIPTION
        Consultants frequently have access to several tenants and subscriptions
        across client engagements. Get-AzContext returns whatever was last
        selected, which is rarely what you want by default. This function:
            - Verifies a connection exists
            - Optionally switches tenant (-TenantId) and subscription (-SubscriptionId)
            - Optionally offers an interactive picker (-Interactive)
            - Returns the resolved context after switching
            - Logs the resolved account, tenant, and subscription clearly
    #>
    [CmdletBinding()]
    param(
        [Parameter()] [string]$TenantId,
        [Parameter()] [string]$SubscriptionId,
        [Parameter()] [switch]$Interactive
    )

    try {
        $context = Get-AzContext -ErrorAction Stop
        if (-not $context -or -not $context.Account) {
            throw "No active Azure context. Run Connect-AzAccount first."
        }

        # If caller specified a tenant and the active context isn't on it, switch.
        if ($TenantId -and $context.Tenant.Id -ne $TenantId) {
            Write-LogMessage "Switching to tenant: $TenantId" -Level Info
            # Pick any subscription in that tenant to land on; user can refine with -SubscriptionId
            $candidate = Get-AzSubscription -TenantId $TenantId -ErrorAction Stop |
                         Where-Object { $_.State -eq 'Enabled' } |
                         Select-Object -First 1
            if (-not $candidate) {
                throw "No enabled subscriptions found in tenant $TenantId for this account."
            }
            Set-AzContext -TenantId $TenantId -SubscriptionId $candidate.Id -ErrorAction Stop | Out-Null
            $context = Get-AzContext
        }

        # If caller specified a subscription, switch to it.
        if ($SubscriptionId -and $context.Subscription.Id -ne $SubscriptionId) {
            Write-LogMessage "Switching to subscription: $SubscriptionId" -Level Info
            Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
            $context = Get-AzContext
        }

        # Interactive picker - only when no subscription was specified and multiple are available.
        if ($Interactive -and -not $SubscriptionId) {
            $subs = @(Get-AzSubscription -ErrorAction SilentlyContinue -WarningAction SilentlyContinue |
                      Where-Object { $_.State -eq 'Enabled' } |
                      Sort-Object -Property @{Expression='TenantId'},@{Expression='Name'})

            if ($subs.Count -gt 1) {
                Write-Host ""
                Write-Host "Available subscriptions:" -ForegroundColor Cyan
                for ($i = 0; $i -lt $subs.Count; $i++) {
                    $marker = if ($subs[$i].Id -eq $context.Subscription.Id) { '*' } else { ' ' }
                    $line = ('  {0} [{1,2}] {2,-40} {3}  (tenant {4})' -f $marker, ($i+1), $subs[$i].Name, $subs[$i].Id, $subs[$i].TenantId)
                    Write-Host $line
                }
                Write-Host ""
                Write-Host "  * = current" -ForegroundColor DarkGray
                Write-Host ""

                do {
                    $choice = Read-Host "Select subscription (1-$($subs.Count)) or press Enter to keep current"
                    if ([string]::IsNullOrWhiteSpace($choice)) { break }
                } until ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $subs.Count)

                if (-not [string]::IsNullOrWhiteSpace($choice)) {
                    $picked = $subs[[int]$choice - 1]
                    Write-LogMessage "Selected: $($picked.Name) ($($picked.Id))" -Level Info
                    Set-AzContext -TenantId $picked.TenantId -SubscriptionId $picked.Id -ErrorAction Stop | Out-Null
                    $context = Get-AzContext
                }
            }
        }

        Write-Host ""
        Write-Host "ACTIVE AZURE CONTEXT" -ForegroundColor Cyan
        Write-Host "  Account:        $($context.Account.Id)"
        Write-Host "  Tenant:         $($context.Tenant.Id)"
        Write-Host "  Subscription:   $($context.Subscription.Name) ($($context.Subscription.Id))"
        Write-Host ""

        Write-LogMessage "Resolved context: $($context.Account.Id) / $($context.Subscription.Name)" -Level Success
        return $context
    }
    catch {
        Write-LogMessage "Failed to resolve Azure context: $($_.Exception.Message)" -Level Error
        Write-LogMessage "Run Connect-AzAccount before invoking this script." -Level Error
        return $null
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

function Test-CIDROverlap {
    <#
    .SYNOPSIS
        Returns $true if two IPv4 CIDR blocks overlap, $false otherwise.

    .DESCRIPTION
        Used when adding a new subnet to an existing VNet to make sure we
        don't collide with subnets that are already there. The check converts
        each CIDR to a [start, end] range of unsigned 32-bit integers and
        tests for overlap with the standard "start1 <= end2 AND start2 <= end1"
        formula.

    .EXAMPLE
        Test-CIDROverlap -CIDR1 '10.0.2.0/27' -CIDR2 '10.0.0.0/25'
        # Returns False - they don't overlap.

        Test-CIDROverlap -CIDR1 '10.0.0.0/24' -CIDR2 '10.0.0.128/25'
        # Returns True - 10.0.0.128/25 is inside 10.0.0.0/24.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$CIDR1,
        [Parameter(Mandatory)] [string]$CIDR2
    )

    function ConvertTo-Range($cidr) {
        $parts = $cidr -split '/'
        $ipBytes = [System.Net.IPAddress]::Parse($parts[0]).GetAddressBytes()
        # IPv4 bytes come back in network byte order; reverse for proper integer.
        [Array]::Reverse($ipBytes)

        # Convert the four bytes to a uint64-compatible integer directly.
        # We avoid PowerShell hex literals (which parse ambiguously between
        # int/uint32/long) and the -bnot operator entirely. All arithmetic
        # is done with explicit uint64 values, which has plenty of headroom
        # for any 32-bit IPv4 address space math. Cast each byte to uint64
        # FIRST (parens around the cast) so the shift operator works on the
        # already-widened value rather than on a narrower type.
        $b0 = [uint64]$ipBytes[0]
        $b1 = [uint64]$ipBytes[1]
        $b2 = [uint64]$ipBytes[2]
        $b3 = [uint64]$ipBytes[3]
        $ipInt = ($b3 * 16777216) + ($b2 * 65536) + ($b1 * 256) + $b0

        $prefix = [int]$parts[1]
        $hostBits = 32 - $prefix
        # 2^32 = 4294967296 is the size of the whole IPv4 address space.
        # blockSize is the number of addresses in the prefix.
        $blockSize = [uint64][math]::Pow(2, $hostBits)
        $maxAddr = [uint64]4294967295  # 2^32 - 1, written as decimal to avoid hex-literal parsing issues
        $mask = if ($prefix -eq 0) { [uint64]0 } else { $maxAddr - ($blockSize - 1) }
        $start = $ipInt -band $mask
        $end   = $start + $blockSize - 1
        return @($start, $end)
    }

    $r1 = ConvertTo-Range $CIDR1
    $r2 = ConvertTo-Range $CIDR2

    # Overlap iff r1.start <= r2.end AND r2.start <= r1.end
    return ($r1[0] -le $r2[1]) -and ($r2[0] -le $r1[1])
}

function Get-CurrentPrincipalObjectId {
    <#
    .SYNOPSIS
        Returns the AAD object ID of the currently authenticated principal.

    .DESCRIPTION
        RBAC role assignments require the principal's object ID, not the
        UPN/email. This function resolves it correctly across the three
        common cases:
            - Interactive user (UPN)
            - Service principal (ApplicationId)
            - Managed identity (ApplicationId)

        Returns a hashtable with ObjectId, PrincipalType, and DisplayName.
    #>
    [CmdletBinding()]
    param()

    try {
        $context = Get-AzContext -ErrorAction Stop
        $accountType = $context.Account.Type
        $accountId   = $context.Account.Id

        switch ($accountType) {
            'User' {
                $user = Get-AzADUser -UserPrincipalName $accountId -ErrorAction SilentlyContinue
                if (-not $user) {
                    # Some directories require ObjectId/SignInName lookup instead
                    $user = Get-AzADUser -Mail $accountId -ErrorAction SilentlyContinue
                }
                if (-not $user) {
                    throw "Could not resolve user '$accountId' in directory."
                }
                return @{
                    ObjectId      = $user.Id
                    PrincipalType = 'User'
                    DisplayName   = $user.DisplayName
                }
            }
            { $_ -in 'ServicePrincipal','ManagedService' } {
                $sp = Get-AzADServicePrincipal -ApplicationId $accountId -ErrorAction SilentlyContinue
                if (-not $sp) {
                    throw "Could not resolve service principal '$accountId'."
                }
                return @{
                    ObjectId      = $sp.Id
                    PrincipalType = 'ServicePrincipal'
                    DisplayName   = $sp.DisplayName
                }
            }
            default {
                throw "Unsupported principal type '$accountType'. Supported: User, ServicePrincipal, ManagedService."
            }
        }
    }
    catch {
        Write-LogMessage "Failed to resolve current principal: $($_.Exception.Message)" -Level Error
        throw
    }
}

function Test-KeyVaultSecretAccess {
    <#
    .SYNOPSIS
        Tests whether the current principal can WRITE secrets to the vault.

    .DESCRIPTION
        Attempts to write (and immediately delete) a throwaway probe secret.
        This is more reliable than a read probe because:
            1. It exercises the same code path as the real workload
            2. Set and Get can authenticate as different identities under
               some Az.KeyVault token-cache scenarios - testing the actual
               operation we'll perform avoids false positives
            3. RBAC role propagation can complete for Get before Set

        Returns a hashtable with:
            Granted    : $true if access works
            ObjectId   : extracted from 403 error if access is denied (the
                         object ID the call was actually authenticated as)
            Error      : the underlying error message if denied
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$VaultName
    )

    $probeName = 'erpnext-deploy-probe-access'
    $probeValue = ConvertTo-SecureString -String 'probe' -AsPlainText -Force

    try {
        # WRITE probe: same code path as real secret writes
        Set-AzKeyVaultSecret -VaultName $VaultName -Name $probeName -SecretValue $probeValue -ErrorAction Stop | Out-Null
        # Clean up the probe (best-effort)
        try {
            Remove-AzKeyVaultSecret -VaultName $VaultName -Name $probeName -Force -ErrorAction SilentlyContinue | Out-Null
            # Also purge so it doesn't sit in soft-delete state
            Remove-AzKeyVaultSecret -VaultName $VaultName -Name $probeName -InRemovedState -Force -ErrorAction SilentlyContinue | Out-Null
        } catch { }
        return @{ Granted = $true; ObjectId = $null; Error = $null }
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -match 'Forbidden|does not have secrets|AuthorizationFailed|Caller is not authorized') {
            # The 403 response often contains the OID the call was authenticated as.
            # Pattern: oid=<guid>
            $extractedOid = $null
            if ($msg -match 'oid=([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})') {
                $extractedOid = $Matches[1]
            }
            return @{ Granted = $false; ObjectId = $extractedOid; Error = $msg }
        }
        # Anything else - re-raise so the caller can decide
        throw
    }
}

function Grant-KeyVaultSecretsOfficer {
    <#
    .SYNOPSIS
        Assigns the Key Vault Secrets Officer role to a principal at vault scope.

    .DESCRIPTION
        Key Vault Secrets Officer (b86a8fe4-44ce-4948-aee5-eccb2c155cd7) is
        the minimum role for setting and reading secrets on an RBAC-enabled
        vault. Idempotent - skips if the assignment already exists.

        Requires the running identity to have Microsoft.Authorization/
        roleAssignments/write at the vault or higher scope. Owner and User
        Access Administrator have this; Contributor does NOT.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$VaultResourceId,
        [Parameter(Mandatory)] [string]$PrincipalObjectId,
        [Parameter(Mandatory)] [string]$PrincipalType,
        [Parameter()]          [string]$RoleDefinitionName = 'Key Vault Secrets Officer'
    )

    try {
        $existing = Get-AzRoleAssignment -Scope $VaultResourceId `
            -ObjectId $PrincipalObjectId `
            -RoleDefinitionName $RoleDefinitionName `
            -ErrorAction SilentlyContinue

        if ($existing) {
            Write-LogMessage "  Role '$RoleDefinitionName' already assigned." -Level Info
            return $true
        }

        Write-LogMessage "  Assigning '$RoleDefinitionName' to principal $PrincipalObjectId..." -Level Info
        New-AzRoleAssignment -Scope $VaultResourceId `
            -ObjectId $PrincipalObjectId `
            -RoleDefinitionName $RoleDefinitionName `
            -ErrorAction Stop | Out-Null

        Write-LogMessage "  Role assignment created." -Level Success
        return $true
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -match 'AuthorizationFailed|does not have authorization') {
            Write-LogMessage "Cannot assign roles - your account lacks Microsoft.Authorization/roleAssignments/write." -Level Error
            Write-LogMessage "Required Azure role: Owner or User Access Administrator (Contributor is not sufficient)." -Level Error
            Write-LogMessage "Workaround options:" -Level Error
            Write-LogMessage "  1. Have an Owner/UAA pre-grant 'Key Vault Secrets Officer' on the vault to your account" -Level Error
            Write-LogMessage "  2. Have an Owner/UAA pre-create the vault and grant access, then re-run with -KeyVaultName" -Level Error
            Write-LogMessage "  3. Omit -UseKeyVault and accept local JSON secret storage for this deployment" -Level Error
        } else {
            Write-LogMessage "Role assignment failed: $msg" -Level Error
        }
        throw
    }
}

function Initialize-KeyVaultAccess {
    <#
    .SYNOPSIS
        Ensures the running identity can write secrets to the target vault.

    .DESCRIPTION
        Creates the vault if missing, resolves the running principal's
        object ID, assigns Key Vault Secrets Officer if not already present,
        and waits for RBAC propagation by polling the data plane until
        access is confirmed (or until timeout).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$VaultName,
        [Parameter(Mandatory)] [string]$ResourceGroup,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter()]          [int]$PropagationTimeoutSeconds = 180
    )

    # Get or create vault
    $kv = Get-AzKeyVault -VaultName $VaultName -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue
    if (-not $kv) {
        Write-LogMessage "  Creating Key Vault '$VaultName'..." -Level Info

        # Az.KeyVault parameter naming changed in 6.0.0:
        #   <  6.0:  -EnableRbacAuthorization (off by default, must opt in)
        #   >= 6.0:  -DisableRbacAuthorization (on by default, must opt out)
        # Inspect the cmdlet's actual parameter set at runtime rather than checking
        # a version number - more robust across preview builds and custom forks.
        $newVaultParams = @{
            Name              = $VaultName
            ResourceGroupName = $ResourceGroup
            Location          = $Location
            ErrorAction       = 'Stop'
        }

        $cmdInfo = Get-Command -Name New-AzKeyVault -ErrorAction Stop
        $params  = $cmdInfo.Parameters.Keys

        if ($params -contains 'EnableRbacAuthorization') {
            # Older module - must explicitly opt in to RBAC
            $newVaultParams['EnableRbacAuthorization'] = $true
            Write-LogMessage "  Using legacy -EnableRbacAuthorization (Az.KeyVault < 6.0)." -Level Debug
        } elseif ($params -contains 'DisableRbacAuthorization') {
            # Modern module - RBAC is default, just don't disable it
            Write-LogMessage "  Using default RBAC (Az.KeyVault >= 6.0)." -Level Debug
        } else {
            # Unknown shape - try without the flag and hope for the best
            Write-LogMessage "  Az.KeyVault version has neither known RBAC flag; using defaults." -Level Warning
        }

        $kv = New-AzKeyVault @newVaultParams
        Write-LogMessage "  Vault created." -Level Success
    } else {
        Write-LogMessage "  Vault already exists. Verifying access..." -Level Info

        # If the existing vault is not RBAC-enabled, our role-assignment approach won't work
        if ($kv.PSObject.Properties.Name -contains 'EnableRbacAuthorization' -and -not $kv.EnableRbacAuthorization) {
            Write-LogMessage "  WARNING: Existing vault uses legacy access policies, not RBAC." -Level Warning
            Write-LogMessage "  This script grants access via RBAC roles. You may need to either:" -Level Warning
            Write-LogMessage "    1. Migrate the vault to RBAC: Update-AzKeyVault -EnableRbacAuthorization `$true" -Level Warning
            Write-LogMessage "    2. Add an access policy manually granting Get/Set on secrets to your account" -Level Warning
        }
    }

    # Resolve current principal
    $principal = Get-CurrentPrincipalObjectId
    Write-LogMessage "  Current principal: $($principal.DisplayName) [$($principal.PrincipalType)] oid=$($principal.ObjectId)" -Level Info

    # Test if we already have write access using a real-write probe
    $access = Test-KeyVaultSecretAccess -VaultName $VaultName
    if ($access.Granted) {
        Write-LogMessage "  Already have data-plane access to vault." -Level Success
        return $kv
    }

    # Track which object IDs we've granted access to, to avoid duplicate work
    $grantedOids = New-Object System.Collections.Generic.HashSet[string]

    # First grant attempt: use the object ID resolved from the active context
    Grant-KeyVaultSecretsOfficer -VaultResourceId $kv.ResourceId `
        -PrincipalObjectId $principal.ObjectId `
        -PrincipalType $principal.PrincipalType | Out-Null
    [void]$grantedOids.Add($principal.ObjectId)

    # Poll for RBAC propagation
    Write-LogMessage "  Waiting for RBAC propagation (can take 30-90 seconds)..." -Level Info
    $deadline = (Get-Date).AddSeconds($PropagationTimeoutSeconds)
    $attempt  = 0
    $additionalGrantsAttempted = 0
    $maxAdditionalGrants = 2

    while ((Get-Date) -lt $deadline) {
        $attempt++
        Start-Sleep -Seconds 10

        $access = Test-KeyVaultSecretAccess -VaultName $VaultName
        if ($access.Granted) {
            Write-LogMessage "  Access confirmed after $($attempt * 10)s." -Level Success
            return $kv
        }

        # Self-healing: if the 403 reveals a different OID is making the call than
        # the one we granted, this is the token-mismatch case (stale token cache,
        # multi-account session). Grant to that OID too.
        if ($access.ObjectId -and -not $grantedOids.Contains($access.ObjectId) -and $additionalGrantsAttempted -lt $maxAdditionalGrants) {
            Write-LogMessage "  Detected different principal in 403: oid=$($access.ObjectId)" -Level Warning
            Write-LogMessage "  This usually means the Az session has a stale or alternate token." -Level Warning
            Write-LogMessage "  Granting access to the OID actually making the call..." -Level Info
            try {
                Grant-KeyVaultSecretsOfficer -VaultResourceId $kv.ResourceId `
                    -PrincipalObjectId $access.ObjectId `
                    -PrincipalType 'User' | Out-Null
                [void]$grantedOids.Add($access.ObjectId)
                $additionalGrantsAttempted++
            }
            catch {
                Write-LogMessage "  Could not grant role to additional OID: $($_.Exception.Message)" -Level Warning
            }
        }

        Write-LogMessage "    Attempt $attempt - still propagating..." -Level Debug
    }

    # All retries exhausted - give the user actionable next steps
    $oidHint = if ($access.ObjectId) { "Last 403 was authenticated as: $($access.ObjectId)" } else { "" }
    $msg = @"
Key Vault role assignment did not propagate within ${PropagationTimeoutSeconds}s.
This is most often caused by a stale Az token cache when the session has had
multiple Connect-AzAccount runs. Granted to: $($grantedOids -join ', ').
$oidHint

To resolve, run these in order, then re-run the script:

  Disconnect-AzAccount
  Clear-AzContext -Force
  Connect-AzAccount
  Set-AzContext -SubscriptionId <your-subscription-id>

Then re-run the deployment.
"@
    throw $msg
}

function Set-VMKeyVaultSecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$VaultName,
        [Parameter(Mandatory)] [string]$SecretName,
        [Parameter(Mandatory)] [string]$SecretValue,
        [Parameter()]          [string]$ContentType = 'text/plain',
        [Parameter()]          [int]$MaxRetries = 6
    )

    $secure = ConvertTo-SecureString -String $SecretValue -AsPlainText -Force

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $result = Set-AzKeyVaultSecret -VaultName $VaultName -Name $SecretName `
                -SecretValue $secure -ContentType $ContentType -ErrorAction Stop
            Write-LogMessage "  Stored secret: $SecretName -> $($result.Id)" -Level Debug
            return $result.Id
        }
        catch {
            $msg = $_.Exception.Message
            # Retry on RBAC-propagation 403s for a short window even though
            # Initialize-KeyVaultAccess already verified access. Edge cases happen.
            if ($attempt -lt $MaxRetries -and $msg -match 'Forbidden|AuthorizationFailed|does not have secrets set permission') {
                $backoff = [int][Math]::Pow(2, $attempt) * 1000
                Write-LogMessage "  Set-Secret attempt $attempt got 403, retrying in ${backoff}ms..." -Level Debug
                Start-Sleep -Milliseconds $backoff
                continue
            }
            throw
        }
    }
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

    # Run Command's outer Status reports whether the bash script was DELIVERED and
    # EXECUTED, not whether it succeeded. A bash script that exits 1 still returns
    # Status=Succeeded from Run Command's perspective. We must inspect the output
    # for our sentinel line "ERPNEXT_INSTALL_STATUS=SUCCESS" which the script only
    # emits if everything completed.
    if ($result.Status -ne 'Succeeded') {
        Write-LogMessage "Run Command itself failed: $($result.Status)" -Level Error
        if ($result.Value) {
            foreach ($v in $result.Value) {
                Write-LogMessage "[$($v.Code)] $($v.Message)" -Level Error
            }
        }
        throw "ERPNext installation Run Command failed."
    }

    # Concatenate all output channels for sentinel scan and diagnostic dumping.
    # Run Command returns output structured as: a single Value entry with
    # Code='ProvisioningState/succeeded' and Message containing the entire
    # script output, with literal "[stdout]" and "[stderr]" markers separating
    # the two streams inside the Message. We must parse this format, not
    # filter Value entries by Code.
    $fullOutput = ""
    $stdoutText = ""
    $stderrText = ""
    if ($result.Value) {
        foreach ($v in $result.Value) {
            if ($v.Message) {
                $fullOutput += $v.Message + "`n"
            }
        }
    }

    # Split out stdout / stderr sections from the combined output.
    # Pattern: "[stdout]\n<stdout content>\n[stderr]\n<stderr content>"
    if ($fullOutput) {
        $stdoutMatch = [regex]::Match($fullOutput, '(?s)\[stdout\](.*?)(?:\[stderr\]|\z)')
        if ($stdoutMatch.Success) {
            $stdoutText = $stdoutMatch.Groups[1].Value.Trim()
        }
        $stderrMatch = [regex]::Match($fullOutput, '(?s)\[stderr\](.*?)\z')
        if ($stderrMatch.Success) {
            $stderrText = $stderrMatch.Groups[1].Value.Trim()
        }
        # If neither marker was found, treat the whole thing as stdout
        if (-not $stdoutText -and -not $stderrText) {
            $stdoutText = $fullOutput.Trim()
        }
    }

    if ($stdoutText -notmatch 'ERPNEXT_INSTALL_STATUS=SUCCESS') {
        Write-LogMessage "Installation did NOT reach the success sentinel." -Level Error
        Write-LogMessage "This means the bash script exited before completing all steps." -Level Error

        # Dump tail of stdout (guard against empty output)
        if ($stdoutText.Trim()) {
            Write-LogMessage "=== Last 80 lines of stdout from the VM: ===" -Level Error
            $tailLines = $stdoutText -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 80
            foreach ($line in $tailLines) {
                Write-LogMessage $line -Level Error
            }
        } else {
            Write-LogMessage "(stdout was empty)" -Level Error
        }

        # Dump stderr (guard against empty)
        if ($stderrText.Trim()) {
            Write-LogMessage "=== Stderr from the VM: ===" -Level Error
            $errLines = $stderrText -split "`n" | Where-Object { $_.Trim() }
            foreach ($line in $errLines) {
                Write-LogMessage $line -Level Error
            }
        } else {
            Write-LogMessage "(stderr was empty)" -Level Error
        }

        Write-LogMessage "Full install log on the VM: /var/log/erpnext-install.log" -Level Error
        Write-LogMessage "Retrieve with:" -Level Error
        Write-LogMessage "  Invoke-AzVMRunCommand -ResourceGroupName '$ResourceGroup' -VMName '$VMName' \" -Level Error
        Write-LogMessage "    -CommandId RunShellScript -ScriptString 'tail -300 /var/log/erpnext-install.log'" -Level Error
        throw "ERPNext installation did not complete - sentinel not found in output."
    }

    Write-LogMessage "Installation completed successfully (sentinel confirmed)." -Level Success
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

    $context = Select-AzureContext -TenantId $TenantId -SubscriptionId $SubscriptionId -Interactive:$SelectContext
    if (-not $context) { exit 1 }

    # Multi-tenant safety: if more than one subscription is accessible and the
    # caller didn't explicitly pin one, require -ConfirmContext to proceed.
    # This prevents accidentally deploying into the wrong client's tenant.
    if (-not $SubscriptionId -and -not $SelectContext) {
        # WarningAction SilentlyContinue: Get-AzSubscription emits warnings when it
        # encounters tenants requiring fresh MFA. Those warnings are not failures
        # and they pollute the output. Subscriptions we CAN see still come back.
        $accessibleSubs = @(Get-AzSubscription -ErrorAction SilentlyContinue -WarningAction SilentlyContinue |
                            Where-Object { $_.State -eq 'Enabled' })
        if ($accessibleSubs.Count -gt 1 -and -not $ConfirmContext) {
            Write-LogMessage "Account has access to $($accessibleSubs.Count) subscriptions but none was pinned." -Level Error
            Write-LogMessage "Multi-tenant safety: pass one of the following to proceed:" -Level Error
            Write-LogMessage "  -SubscriptionId [id]     (explicit target)" -Level Error
            Write-LogMessage "  -SelectContext           (interactive picker)" -Level Error
            Write-LogMessage "  -ConfirmContext          (accept current context)" -Level Error
            exit 1
        }
    }

    foreach ($p in @('Microsoft.Compute', 'Microsoft.Network', 'Microsoft.Storage')) {
        if (-not (Test-AzureProvider -ProviderNamespace $p)) {
            throw "Required resource provider $p is not available."
        }
    }

    # Validate region supports requested VM size
    Write-LogMessage "Verifying VM size $VMSize is available in $Location..." -Level Info
    try {
        $sizeAvailable = Get-AzComputeResourceSku -Location $Location -ErrorAction Stop |
                         Where-Object { $_.ResourceType -eq 'virtualMachines' -and $_.Name -eq $VMSize } |
                         Select-Object -First 1

        if (-not $sizeAvailable) {
            throw "VM size $VMSize is not available in region $Location."
        }

        # Check if size has any restrictions in this region (e.g., quota, zone restrictions)
        if ($sizeAvailable.Restrictions -and $sizeAvailable.Restrictions.Count -gt 0) {
            $restrictionReasons = $sizeAvailable.Restrictions | ForEach-Object {
                "$($_.Type): $($_.ReasonCode)"
            }
            Write-LogMessage "VM size $VMSize has restrictions in $Location : $($restrictionReasons -join '; ')" -Level Warning
            Write-LogMessage "Provisioning may fail. Common fix: request quota increase in this region." -Level Warning
        }
    }
    catch {
        # If the SKU query itself fails (network, permissions), fall back to a more
        # permissive approach: don't block deployment on this check.
        Write-LogMessage "Could not verify VM size availability ($($_.Exception.Message)). Proceeding optimistically." -Level Warning
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
        $kv = Initialize-KeyVaultAccess -VaultName $KeyVaultName `
            -ResourceGroup $ResourceGroupName `
            -Location $Location

        $secretReferences['vm-admin-password']     = Set-VMKeyVaultSecret -VaultName $KeyVaultName -SecretName "$VMName-vm-admin-password"     -SecretValue $vmPassword
        $secretReferences['mariadb-root-password'] = Set-VMKeyVaultSecret -VaultName $KeyVaultName -SecretName "$VMName-mariadb-root-password" -SecretValue $mariadbPassword
        $secretReferences['erpnext-admin-password']= Set-VMKeyVaultSecret -VaultName $KeyVaultName -SecretName "$VMName-erpnext-admin-password" -SecretValue $erpAdminPassword
    }

    # ---- Network: NSG ----
    # NSG rules tighten dramatically in PrivateOnly mode: source becomes the
    # VirtualNetwork service tag which only includes the VNet's own address
    # space, peered VNets, and VPN client pools. No public ingress allowed.
    Write-LogMessage "Network Security Group: $VMName-nsg" -Level Info
    $nsgName = "$VMName-nsg"
    $nsg = Get-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $nsg) {
        if ($PrivateOnly) {
            $nsgRules = New-NSGRuleSet -SourcePrefix 'VirtualNetwork'
            $nsgSourceLabel = 'VirtualNetwork (private only)'
        } else {
            $nsgRules = New-NSGRuleSet -SourcePrefix $AllowedSourceCIDR
            $nsgSourceLabel = $AllowedSourceCIDR
        }
        $nsg = New-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName `
            -Location $Location -Name $nsgName -SecurityRules $nsgRules
        Write-LogMessage "  Created. Source: $nsgSourceLabel" -Level Success
    } else {
        Write-LogMessage "  Already exists." -Level Info
    }

    # ---- Network: Public IP (only in public-access mode) ----
    $publicIp = $null
    if (-not $PrivateOnly) {
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
    } else {
        Write-LogMessage "Public IP: skipped (-PrivateOnly mode)" -Level Info
    }

    # ---- Network: VNet + Subnet ----
    # Two modes:
    #   1. Existing-VNet: join a VNet the user already has. Create just a subnet inside it.
    #   2. Standalone: create a fresh isolated VNet just for this deployment.
    $targetSubnetId = $null

    if ($ExistingVNetName) {
        $vnetRG = if ($ExistingVNetResourceGroup) { $ExistingVNetResourceGroup } else { $ResourceGroupName }
        Write-LogMessage "Joining existing VNet: $ExistingVNetName (RG: $vnetRG)" -Level Info

        $existingVNet = Get-AzVirtualNetwork -Name $ExistingVNetName -ResourceGroupName $vnetRG -ErrorAction SilentlyContinue
        if (-not $existingVNet) {
            throw "ExistingVNetName '$ExistingVNetName' not found in resource group '$vnetRG'."
        }

        # Region must match - VMs and VNets must be in the same region.
        if ($existingVNet.Location -ne $Location) {
            throw "VNet '$ExistingVNetName' is in region '$($existingVNet.Location)' but the deployment is targeting '$Location'. They must match. Re-run with -Region '$($existingVNet.Location)'."
        }

        # Look for existing subnet with our target name; create it if missing.
        $existingSubnet = $existingVNet.Subnets | Where-Object { $_.Name -eq $SubnetName }
        if ($existingSubnet) {
            Write-LogMessage "  Subnet '$SubnetName' already exists at $($existingSubnet.AddressPrefix)" -Level Info
            $targetSubnetId = $existingSubnet.Id
        } else {
            Write-LogMessage "  Creating subnet '$SubnetName' at $SubnetAddressPrefix in $ExistingVNetName..." -Level Info

            # Pre-flight: verify the requested subnet CIDR fits inside the VNet's
            # address space. Azure returns a confusing NetcfgSubnetRangeOutsideVnet
            # error if it doesn't, and we'd rather catch it here with actionable
            # guidance. The VNet may have multiple address prefixes (it's a list,
            # not a single value), so we check the requested CIDR against each
            # prefix and only fail if it doesn't fit any of them.
            $vnetPrefixes = @($existingVNet.AddressSpace.AddressPrefixes)
            $fitsInVNet = $false
            foreach ($vp in $vnetPrefixes) {
                try {
                    # If requested CIDR is fully contained in a VNet prefix, that
                    # means: subnet start >= prefix start AND subnet end <= prefix end.
                    # We can determine "contained" using the overlap check: if the
                    # subnet overlaps the prefix AND the prefix's bits are <= subnet's
                    # bits (i.e., prefix is a superset).
                    $subnetParts = $SubnetAddressPrefix -split '/'
                    $vnetParts   = $vp -split '/'
                    $subnetMaskBits = [int]$subnetParts[1]
                    $vnetMaskBits   = [int]$vnetParts[1]
                    if ($vnetMaskBits -le $subnetMaskBits) {
                        # VNet prefix is equal or larger than subnet (i.e., could contain it).
                        # Now check that the subnet's network address actually falls inside.
                        if (Test-CIDROverlap -CIDR1 $SubnetAddressPrefix -CIDR2 $vp) {
                            $fitsInVNet = $true
                            break
                        }
                    }
                } catch {
                    # Math helper failed - just defer to Azure for the real check.
                    Write-LogMessage "  (Pre-flight VNet-fit check failed: $($_.Exception.Message). Proceeding to Azure API.)" -Level Debug
                    $fitsInVNet = $true  # don't block on helper failure
                    break
                }
            }

            if (-not $fitsInVNet) {
                $vnetSpaceList = $vnetPrefixes -join ', '
                throw "Requested subnet $SubnetAddressPrefix does not fit inside the VNet's address space ($vnetSpaceList). Either pass -SubnetAddressPrefix with a CIDR inside that range, or expand the VNet's address space first with:`n`n  `$vnet = Get-AzVirtualNetwork -Name '$ExistingVNetName' -ResourceGroupName '$vnetRG'`n  `$vnet.AddressSpace.AddressPrefixes.Add('10.0.2.0/24')`n  `$vnet | Set-AzVirtualNetwork`n`nThen re-run this deploy. Expanding a VNet's address space is non-disruptive - existing subnets and resources are unaffected."
            }

            # Check that the requested CIDR doesn't overlap any existing subnet.
            # The check is a safety net, not a hard requirement - if our math
            # fails for any reason, Azure's API will still catch a real overlap
            # when we try to add the subnet. So we log a warning and proceed
            # rather than aborting deployment on a CIDR-helper bug.
            foreach ($s in $existingVNet.Subnets) {
                $existingPrefix = if ($s.AddressPrefix -is [array]) { $s.AddressPrefix[0] } else { $s.AddressPrefix }
                try {
                    if (Test-CIDROverlap -CIDR1 $SubnetAddressPrefix -CIDR2 $existingPrefix) {
                        throw "Requested subnet $SubnetAddressPrefix overlaps existing subnet '$($s.Name)' at $existingPrefix. Choose a different -SubnetAddressPrefix."
                    }
                } catch {
                    # If the error is our own overlap-detection throw, re-raise it.
                    # Otherwise (math failure, parse error, etc.), warn and continue.
                    if ($_.Exception.Message -like '*overlaps existing subnet*') { throw }
                    Write-LogMessage "  (CIDR overlap helper failed for '$existingPrefix': $($_.Exception.Message). Skipping pre-check; Azure API will validate.)" -Level Warning
                }
            }

            # Add the subnet. We pass the NSG so it's bound at creation.
            Add-AzVirtualNetworkSubnetConfig -Name $SubnetName -VirtualNetwork $existingVNet `
                -AddressPrefix $SubnetAddressPrefix -NetworkSecurityGroup $nsg | Out-Null
            $existingVNet | Set-AzVirtualNetwork | Out-Null

            # Re-fetch to pick up the new subnet's ID
            $existingVNet = Get-AzVirtualNetwork -Name $ExistingVNetName -ResourceGroupName $vnetRG
            $newSubnet = $existingVNet.Subnets | Where-Object { $_.Name -eq $SubnetName }
            $targetSubnetId = $newSubnet.Id
            Write-LogMessage "  Subnet created. Note: this subnet lives in RG '$vnetRG', not the ERPNext RG." -Level Success
        }
    } else {
        Write-LogMessage "Virtual Network: $VMName-vnet" -Level Info
        $vnetName = "$VMName-vnet"
        $standaloneSubnetName = "$VMName-subnet"
        $vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        if (-not $vnet) {
            $subnetConfig = New-AzVirtualNetworkSubnetConfig -Name $standaloneSubnetName `
                -AddressPrefix "10.0.1.0/24" -NetworkSecurityGroup $nsg
            $vnet = New-AzVirtualNetwork -Name $vnetName -ResourceGroupName $ResourceGroupName `
                -Location $Location -AddressPrefix "10.0.0.0/16" -Subnet $subnetConfig
            Write-LogMessage "  Created." -Level Success
        } else {
            Write-LogMessage "  Already exists." -Level Info
        }
        $targetSubnetId = $vnet.Subnets[0].Id
    }

    # ---- Network: NIC ----
    # In PrivateOnly mode, no public IP is associated with the NIC.
    Write-LogMessage "Network Interface: $VMName-nic" -Level Info
    $nicName = "$VMName-nic"
    $nic = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $nic) {
        $nicParams = @{
            Name                   = $nicName
            ResourceGroupName      = $ResourceGroupName
            Location               = $Location
            SubnetId               = $targetSubnetId
            NetworkSecurityGroupId = $nsg.Id
        }
        if ($publicIp) {
            $nicParams['PublicIpAddressId'] = $publicIp.Id
        }
        $nic = New-AzNetworkInterface @nicParams
        Write-LogMessage "  Created$(if ($PrivateOnly) { ' (private IP only)' })." -Level Success
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

    # Resolve the VM's primary access IP. In PrivateOnly mode this is the
    # private IP from the NIC; otherwise it's the public IP.
    if ($PrivateOnly) {
        $nicResolved = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $ResourceGroupName
        $vmAccessIp = $nicResolved.IpConfigurations[0].PrivateIpAddress
        Write-LogMessage "Private IP: $vmAccessIp" -Level Success
        # Keep variable name for backward-compat with downstream code, but log
        # accurately. $publicIpAddress used to mean "the IP people use to reach
        # ERPNext"; in PrivateOnly mode it's the private IP.
        $publicIpAddress = $vmAccessIp
        $vmAccessIpKind = 'Private'
    } else {
        $publicIpAddress = (Get-AzPublicIpAddress -Name $pipName -ResourceGroupName $ResourceGroupName).IpAddress
        Write-LogMessage "Public IP: $publicIpAddress" -Level Success
        $vmAccessIpKind = 'Public'
    }

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
        'echo "[1/10] Updating system packages..."',
        'export DEBIAN_FRONTEND=noninteractive',
        'sudo -E apt-get update',
        'sudo -E apt-get upgrade -y',
        '',
        'echo "[2/10] Installing prerequisites..."',
        'sudo -E apt-get install -y git python3-dev python3-pip python3-venv python3-setuptools \',
        '    redis-server mariadb-server mariadb-client libmariadb-dev \',
        '    nginx supervisor curl wget xvfb libfontconfig xfonts-75dpi xfonts-base \',
        '    software-properties-common build-essential',
        '',
        'echo "[3/10] Securing MariaDB..."'
    )

    # Use a PowerShell here-string for the SQL block. Inside @' ... '@,
    # NOTHING is parsed - no $ expansion, no @' confusion, no quote ambiguity.
    # We split the install script construction into multiple array pieces to
    # isolate the SQL block in its own here-string.
    $sqlBlockLines = (@'
sudo mysql <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MARIADB_ROOT_PW}';
EOF
sudo mysql -u root -p"${MARIADB_ROOT_PW}" <<EOF
DELETE FROM mysql.user WHERE User = '';
DELETE FROM mysql.user WHERE User = 'root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
EOF
'@) -split "`n"

    $installLines += $sqlBlockLines
    $installLines += @(
        '',
        'echo "[4/10] Tuning MariaDB for ERPNext..."',
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
        'echo "[5/10] Installing Node.js 20 LTS and Yarn..."',
        'curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -',
        'sudo -E apt-get install -y nodejs',
        'sudo npm install -g yarn',
        '',
        'echo "[6/10] Installing wkhtmltopdf (Ubuntu 24.04 noble build)..."',
        'WKHTMLTOPDF_DEB=wkhtmltox_0.12.6.1-3.jammy_amd64.deb',
        'cd /tmp',
        'wget -q "https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/${WKHTMLTOPDF_DEB}"',
        'sudo apt-get install -y "./${WKHTMLTOPDF_DEB}"',
        'rm -f "${WKHTMLTOPDF_DEB}"',
        '',
        'echo "[7/10] Installing Frappe Bench..."',
        'sudo pip3 install --break-system-packages frappe-bench',
        '',
        'echo "[8/10] Initializing Frappe Bench and pulling apps..."',
        'sudo -u "${ADMIN_USER}" bash -c "cd /home/${ADMIN_USER} && bench init --frappe-branch version-15 frappe-bench"',
        'sudo -u "${ADMIN_USER}" bash -c "cd /home/${ADMIN_USER}/frappe-bench && bench get-app erpnext --branch version-15"',
        'sudo -u "${ADMIN_USER}" bash -c "cd /home/${ADMIN_USER}/frappe-bench && bench get-app hrms --branch version-15"',
        '',
        '# CRITICAL: Frappe needs its private Redis instances running before',
        '# "bench new-site" can succeed. Frappe v15 uses two by default:',
        '#   redis_queue.conf (default port 11000)',
        '#   redis_cache.conf (default port 13000)',
        '# Older versions also had redis_socketio.conf on port 12000, dropped in v15.',
        '# Port assignments and config files are subject to change between Frappe',
        '# versions, so we discover them dynamically from the generated configs',
        '# rather than hardcoding.',
        'echo "[8a/10] Starting Frappe-managed Redis instances..."',
        '',
        '# Embedded helper script (avoids PowerShell-to-bash quoting hell for the complex',
        '# control flow below). Written as a heredoc so PowerShell never tries to parse',
        '# the bash variables/operators.',
        'cat > /tmp/start-redis-instances.sh <<''REDIS_HELPER_EOF''',
        '#!/bin/bash',
        'set -e',
        'BENCH_DIR="$1"',
        'ADMIN_USER="$2"',
        'OUT_PORTS_FILE="$3"',
        '',
        'cd "$BENCH_DIR"',
        'CONFIGS=$(ls config/redis_*.conf 2>/dev/null)',
        'if [ -z "$CONFIGS" ]; then',
        '    echo "  ERROR: No redis_*.conf files found" >&2',
        '    exit 1',
        'fi',
        'echo "  Found Redis configs:"',
        'echo "$CONFIGS" | sed "s/^/    /"',
        '',
        '> "$OUT_PORTS_FILE"',
        'for conf in $CONFIGS; do',
        '    conf_basename=$(basename "$conf" .conf)',
        '    port=$(grep -E "^port " "$conf" | awk "{print \$2}" | head -1)',
        '    if [ -z "$port" ]; then',
        '        echo "  WARNING: no port directive in $conf, skipping" >&2',
        '        continue',
        '    fi',
        '    echo "  Starting $conf_basename on port $port..."',
        '    sudo -u "$ADMIN_USER" bash -c "cd $BENCH_DIR && nohup redis-server $conf >/tmp/$conf_basename.log 2>&1 &"',
        '    echo "$port" >> "$OUT_PORTS_FILE"',
        'done',
        '',
        'echo "  Waiting for Redis instances to be ready..."',
        'while read -r port; do',
        '    for i in $(seq 1 30); do',
        '        if redis-cli -p "$port" ping 2>/dev/null | grep -q PONG; then',
        '            echo "    Redis on port $port is up."',
        '            break',
        '        fi',
        '        sleep 1',
        '        if [ "$i" -eq 30 ]; then',
        '            echo "    ERROR: Redis on port $port did not start within 30s." >&2',
        '            cat /tmp/redis_*.log >&2 2>/dev/null || true',
        '            exit 1',
        '        fi',
        '    done',
        'done < "$OUT_PORTS_FILE"',
        'REDIS_HELPER_EOF',
        '',
        'chmod +x /tmp/start-redis-instances.sh',
        '/tmp/start-redis-instances.sh /home/${ADMIN_USER}/frappe-bench ${ADMIN_USER} /tmp/redis-ports.list',
        'REDIS_PORTS=$(tr "\n" " " < /tmp/redis-ports.list)',
        'echo "[8b/10] Redis startup complete. Ports: $REDIS_PORTS"',
        '',
        'echo "[9/10] Creating site and installing apps..."'
    )

    # Site creation needs the passwords as bash variables interpolated into
    # quoted shell arguments. Using a here-string here avoids the PS quad-quote
    # ambiguity and the @' here-string opener confusion.
    $siteCreationLines = (@'
sudo -u "${ADMIN_USER}" bash <<NEWSITE_EOF
cd /home/${ADMIN_USER}/frappe-bench
bench new-site jtcustomtrailers.local --mariadb-root-password "${MARIADB_ROOT_PW}" --admin-password "${ERPNEXT_ADMIN_PW}"
bench --site jtcustomtrailers.local install-app erpnext
bench --site jtcustomtrailers.local install-app hrms
NEWSITE_EOF
'@) -split "`n"

    $installLines += $siteCreationLines
    $installLines += @(
        '',
        '# Stop the standalone Redis instances we started - they will be replaced',
        '# by supervisor-managed ones in the next step.',
        'echo "[9a/10] Stopping standalone Redis (will be replaced by supervisor)..."',
        'for port in $REDIS_PORTS; do',
        '    redis-cli -p $port shutdown nosave 2>/dev/null || true',
        'done',
        '',
        'echo "[10/10] Configuring production (Nginx + Supervisor)..."',
        '',
        '# Pre-install Ansible via apt to bypass Ubuntu 24.04 PEP 668 enforcement.',
        '# Frappe Bench v15+ calls "sudo pip install ansible" during setup production',
        '# without --break-system-packages, which fails on Ubuntu 24.04 with the',
        '# "externally-managed-environment" error. Installing via apt first means',
        '# bench will then find it already present and skip its broken pip-install.',
        'echo "  Pre-installing Ansible via apt (Ubuntu 24.04 PEP 668 workaround)..."',
        'sudo -E apt-get install -y ansible',
        '',
        '# bench setup production has to run TWICE on Ubuntu 24.04. The first',
        '# invocation generates the supervisor and nginx config files in the bench',
        '# config/ directory but returns exit 0 before actually creating the',
        '# /etc/supervisor/conf.d symlink and reloading supervisor. The second',
        '# invocation picks up where the first left off and completes the symlink,',
        '# supervisor reread/update, and nginx reload. Without the second run,',
        '# supervisor has no idea the frappe-bench groups exist and nginx serves',
        '# a 502 indefinitely. Both runs return exit 0 so set -e cannot catch this.',
        'echo "  Running bench setup production (first pass: generates configs)..."',
        "sudo bash -c `"cd /home/${AdminUsername}/frappe-bench && bench setup production ${AdminUsername} --yes`"",
        '',
        '# Ubuntu 24.04 ships home directories with mode 750 by default (Canonical',
        '# tightened this in noble vs jammy). Nginx runs as www-data and cannot',
        '# traverse a 750 directory owned by another user. Apply 755 here before',
        '# the second bench setup so nginx-related reloads work first try.',
        'echo "  Adjusting home directory permissions for nginx access..."',
        'sudo chmod 755 /home/${ADMIN_USER}',
        '',
        'echo "  Running bench setup production (second pass: activates configs)..."',
        "sudo bash -c `"cd /home/${AdminUsername}/frappe-bench && bench setup production ${AdminUsername} --yes`"",
        '',
        '# Verify gunicorn is listening on port 8000 before declaring success.',
        '# Without this we can emit the success sentinel while nginx 502s in production.',
        'echo "  Verifying Frappe web worker is listening on port 8000..."',
        'for i in $(seq 1 30); do',
        '    if sudo ss -tlnp | grep -q ":8000"; then',
        '        echo "    Port 8000 is up."',
        '        break',
        '    fi',
        '    sleep 2',
        '    if [ $i -eq 30 ]; then',
        '        echo "    ERROR: Frappe web worker did not start within 60s." >&2',
        '        echo "    Supervisor status:" >&2',
        '        sudo supervisorctl status >&2 || true',
        '        echo "    Nginx config test:" >&2',
        '        sudo nginx -t 2>&1 >&2 || true',
        '        exit 1',
        '    fi',
        'done',
        '',
        '# Final nginx reload to ensure the new config (generated in pass 2) is live.',
        'sudo systemctl reload nginx',
        '',
        '# Sentinel: this exact line is parsed by the deploy script to confirm real success.',
        '# If the install bombed earlier, set -euo pipefail will have exited before reaching here.',
        'echo "ERPNEXT_INSTALL_STATUS=SUCCESS"',
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
        IPAddressKind        = $vmAccessIpKind  # 'Public' or 'Private'
        IPAddress            = $publicIpAddress  # The actual IP (private or public)
        PublicIP             = $publicIpAddress  # Kept for backward-compat with v1.5.x consumers
        AdminUsername        = $AdminUsername
        SSHCommand           = "ssh ${AdminUsername}@${publicIpAddress}"
        ERPNextURL           = "http://${publicIpAddress}"
        ERPNextUsername      = "Administrator"
        InstallScriptPath    = $scriptPath
        LogFile               = $LogFile
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
    if ($vmAccessIpKind -eq 'Public') {
        Write-Host "  Public IP:        $publicIpAddress"
    } else {
        Write-Host "  Private IP:       $publicIpAddress (no public IP - VPN/VNet access only)"
    }
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
    if ($vmAccessIpKind -eq 'Private') {
        Write-Host "        (reachable from VPN-connected clients or VNet-attached services)" -ForegroundColor DarkGray
    }
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
