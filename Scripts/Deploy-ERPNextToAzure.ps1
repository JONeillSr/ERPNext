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
    Version:          1.4.0
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
    1.4.0 - 05/16/2026 - Fixed install failure + silent-success detection
        - Fixed Redis connection refused during bench new-site. Frappe needs
          three private Redis instances (ports 11000/12000/13000 for queue,
          cache, and socketio) running before new-site can succeed. These
          are NOT the system-level redis-server on 6379. The install script
          now starts them in the background between bench init and new-site,
          waits for them to actually accept connections, then hands them
          off to supervisor management via bench setup production.
        - Fixed silent install failures being reported as success. Run
          Command's outer Status only reports whether the bash script was
          delivered and executed, not its exit code. The install script
          now emits a sentinel line "ERPNEXT_INSTALL_STATUS=SUCCESS" only
          if every step completed, and the deploy script scans stdout for
          that sentinel before reporting success.
        - On install failure, the deploy now dumps the last 50 lines of
          stdout plus all stderr, and shows the exact Invoke-AzVMRunCommand
          to retrieve the full install log from the VM.

    1.3.4 - 05/15/2026 - Probe secret name compliance
        - Fixed: probe secret name contained underscores, which Key Vault
          rejects. Secret names must match ^[0-9a-zA-Z-]+$ (alphanumerics
          and hyphens only). Renamed to 'erpnext-deploy-probe-access'.

    1.3.3 - 05/15/2026 - Key Vault token-mismatch self-healing
        - Probe rewritten to use Set-AzKeyVaultSecret instead of
          Get-AzKeyVaultSecret. Different Az.KeyVault cmdlets can authenticate
          as different identities when the token cache has stale entries from
          prior Connect-AzAccount calls, so testing the actual write operation
          is the only reliable way to verify access
        - On RBAC propagation failures, the script now extracts the calling
          object ID from the 403 error message and grants the role to that
          OID too (up to 2 additional grants per run)
        - Detailed remediation guidance when all retries fail - tells the user
          to Disconnect-AzAccount, Clear-AzContext, and reconnect cleanly

    1.3.2 - 05/15/2026 - Az.KeyVault 6.x compatibility
        - New-AzKeyVault parameter for RBAC is now selected at runtime based
          on the installed module version (Az.KeyVault 6.0 replaced
          -EnableRbacAuthorization with -DisableRbacAuthorization and made
          RBAC the default)
        - Detects existing vaults using legacy access policies and warns
          that the script's RBAC-based access approach won't work without
          either migrating the vault or adding an access policy manually

    1.3.1 - 05/15/2026 - Az.Compute 10+ compatibility fixes
        - Replaced Get-AzVMSize -Location (deprecated in Az.Compute 10.0.1)
          with Get-AzComputeResourceSku
        - Added detection of region-specific VM size restrictions
        - Made size verification non-blocking on lookup errors (proceeds with
          a warning instead of failing the deployment)
        - Suppressed cross-tenant token acquisition warnings from
          Get-AzSubscription when enumerating accessible subscriptions

    1.3.0 - 05/15/2026 - Key Vault RBAC handling
        - Key Vault now properly grants Key Vault Secrets Officer role to the
          running identity on creation (previously failed with 403 on first
          secret write)
        - Polls for RBAC propagation before attempting secret writes
        - Detects pre-existing vaults and verifies access rather than blindly
          re-assigning roles
        - Resolves principal object ID correctly for User, ServicePrincipal,
          and ManagedService account types
        - Detects insufficient permissions (Contributor-only) and provides
          clear remediation guidance
        - Retry-with-backoff on the actual Set-Secret call as a final
          safety net for slow RBAC propagation

    1.2.0 - 05/15/2026 - Multi-tenant support for consultants
        - Added -TenantId parameter to target a specific Azure AD tenant
        - Added -SelectContext for interactive subscription picker
        - Added -ConfirmContext safety gate when multiple subscriptions are
          accessible and none is pinned
        - Active context (account, tenant, subscription) is now displayed
          prominently before any resource operation
        - Replaced Test-AzureConnection with richer Select-AzureContext function

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
    [int]$InstallTimeoutMinutes = 60
)

#Requires -Version 7.2
#Requires -Modules Az.Accounts, Az.Compute, Az.Network, Az.Resources

# Set strict mode
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Script configuration
$ScriptVersion = "1.4.0"
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
            Write-LogMessage "    1. Migrate the vault to RBAC: Update-AzKeyVault -EnableRbacAuthorization \$true" -Level Warning
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
    $stdoutText = ""
    $stderrText = ""
    if ($result.Value) {
        foreach ($v in $result.Value) {
            if ($v.Code -like '*StdOut*') { $stdoutText += $v.Message }
            elseif ($v.Code -like '*StdErr*') { $stderrText += $v.Message }
        }
    }

    if ($stdoutText -notmatch 'ERPNEXT_INSTALL_STATUS=SUCCESS') {
        Write-LogMessage "Installation did NOT reach the success sentinel." -Level Error
        Write-LogMessage "This means the bash script exited before completing all steps." -Level Error
        Write-LogMessage "" -Level Error
        Write-LogMessage "=== Last 50 lines of stdout from the VM: ===" -Level Error
        $tailOut = ($stdoutText -split "`n" | Where-Object { $_ } | Select-Object -Last 50) -join "`n"
        Write-LogMessage $tailOut -Level Error
        if ($stderrText.Trim()) {
            Write-LogMessage "" -Level Error
            Write-LogMessage "=== Stderr from the VM: ===" -Level Error
            Write-LogMessage $stderrText -Level Error
        }
        Write-LogMessage "" -Level Error
        Write-LogMessage "Full install log on the VM: /var/log/erpnext-install.log" -Level Error
        Write-LogMessage "Retrieve with:" -Level Error
        Write-LogMessage "  Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroup -VMName $VMName ``" -Level Error
        Write-LogMessage "    -CommandId RunShellScript -ScriptString 'tail -200 /var/log/erpnext-install.log'" -Level Error
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
            Write-LogMessage "  -SubscriptionId <id>     (explicit target)" -Level Error
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
        'echo "[3/10] Securing MariaDB..."',
        'sudo mysql -e "ALTER USER ''root''@''localhost'' IDENTIFIED BY ''${MARIADB_ROOT_PW}'';"',
        'sudo mysql -u root -p"${MARIADB_ROOT_PW}" -e "DELETE FROM mysql.user WHERE User='''';"',
        'sudo mysql -u root -p"${MARIADB_ROOT_PW}" -e "DELETE FROM mysql.user WHERE User=''root'' AND Host NOT IN (''localhost'',''127.0.0.1'',''::1'');"',
        'sudo mysql -u root -p"${MARIADB_ROOT_PW}" -e "DROP DATABASE IF EXISTS test;"',
        'sudo mysql -u root -p"${MARIADB_ROOT_PW}" -e "FLUSH PRIVILEGES;"',
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
        '# CRITICAL: Frappe needs three Redis instances running on ports 11000, 12000, 13000',
        '# (queue, cache, socketio) before "bench new-site" can succeed. These are NOT the',
        '# system-level redis-server on port 6379 - they are bench-managed instances whose',
        '# configs are generated by "bench init" in config/redis_*.conf.',
        '# We start them in the background here, run new-site, then they will be migrated',
        '# to supervisor management by "bench setup production" at the end.',
        'echo "[8a/10] Starting Frappe-managed Redis instances..."',
        'sudo -u "${ADMIN_USER}" bash -c "cd /home/${ADMIN_USER}/frappe-bench && nohup redis-server config/redis_queue.conf >/tmp/redis_queue.log 2>&1 &"',
        'sudo -u "${ADMIN_USER}" bash -c "cd /home/${ADMIN_USER}/frappe-bench && nohup redis-server config/redis_cache.conf >/tmp/redis_cache.log 2>&1 &"',
        'sudo -u "${ADMIN_USER}" bash -c "cd /home/${ADMIN_USER}/frappe-bench && nohup redis-server config/redis_socketio.conf >/tmp/redis_socketio.log 2>&1 &"',
        '',
        '# Wait for the Redis instances to actually accept connections before proceeding.',
        '# Without this we hit Connection refused errors in bench new-site.',
        'echo "[8b/10] Waiting for Redis instances to be ready..."',
        'for port in 11000 12000 13000; do',
        '    for i in $(seq 1 30); do',
        '        if redis-cli -p $port ping 2>/dev/null | grep -q PONG; then',
        '            echo "  Redis on port $port is up."',
        '            break',
        '        fi',
        '        sleep 1',
        '        if [ $i -eq 30 ]; then',
        '            echo "  ERROR: Redis on port $port did not start within 30s." >&2',
        '            exit 1',
        '        fi',
        '    done',
        'done',
        '',
        'echo "[9/10] Creating site and installing apps..."',
        'sudo -u "${ADMIN_USER}" bash -c "cd /home/${ADMIN_USER}/frappe-bench && bench new-site jtcustomtrailers.local --mariadb-root-password ''${MARIADB_ROOT_PW}'' --admin-password ''${ERPNEXT_ADMIN_PW}''"',
        'sudo -u "${ADMIN_USER}" bash -c "cd /home/${ADMIN_USER}/frappe-bench && bench --site jtcustomtrailers.local install-app erpnext"',
        'sudo -u "${ADMIN_USER}" bash -c "cd /home/${ADMIN_USER}/frappe-bench && bench --site jtcustomtrailers.local install-app hrms"',
        '',
        '# Stop the standalone Redis instances - they will be replaced by supervisor-managed ones.',
        'echo "[9a/10] Stopping standalone Redis (will be replaced by supervisor)..."',
        'for port in 11000 12000 13000; do',
        '    redis-cli -p $port shutdown nosave 2>/dev/null || true',
        'done',
        '',
        'echo "[10/10] Configuring production (Nginx + Supervisor)..."',
        "sudo bash -c `"cd /home/${AdminUsername}/frappe-bench && bench setup production ${AdminUsername} --yes`"",
        "sudo bash -c `"cd /home/${AdminUsername}/frappe-bench && bench setup nginx --yes`"",
        'sudo supervisorctl reload',
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
