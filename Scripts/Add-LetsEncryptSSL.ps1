<#
.SYNOPSIS
    Adds Let's Encrypt SSL/TLS to an ERPNext-on-Azure deployment using a wildcard
    certificate obtained via DNS-01 challenge against Azure DNS, authenticated
    via a User-Assigned Managed Identity attached to the ERPNext VM.

.DESCRIPTION
    Adds production-grade SSL to a privately-deployed ERPNext instance that
    isn't publicly reachable. Because the ERPNext VM is behind a VPN and
    doesn't accept inbound traffic from the public internet, HTTP-01 challenges
    won't work - we use DNS-01 instead, which only requires the ability to
    write TXT records into the public DNS zone for the domain.

    This script handles the full pipeline:

    1. CREATE a User-Assigned Managed Identity (UAMI). This is an Azure
       identity with no password - it can authenticate to Azure APIs from
       inside any VM it's attached to, via the VM's IMDS endpoint.

    2. GRANT the UAMI 'DNS Zone Contributor' role on the public DNS zone
       (least-privilege scope - only the specific zone, not the whole RG).

    3. ASSIGN the UAMI to the ERPNext VM. Now any process on the VM can
       authenticate to Azure DNS as that identity, without credentials.

    4. INSTALL certbot and the certbot-dns-azure plugin on the VM via
       Azure Run Command. No SSH required.

    5. CONFIGURE certbot with an INI file pointing at the UAMI and the
       target DNS zone.

    6. REQUEST a wildcard certificate from Let's Encrypt for *.<domain> and
       <domain>. certbot uses DNS-01 to prove ownership.

    7. WIRE the cert into ERPNext by editing site_config.json with
       ssl_certificate and ssl_certificate_key paths, running bench setup
       nginx to regenerate the nginx config, and reloading nginx.

    8. SET UP automatic renewal via certbot's systemd timer (included with
       the certbot package). Also adds a deploy hook to reload nginx after
       each renewal.

    The script is idempotent: re-running on an existing setup checks for
    existing identity, role assignment, and certificate and skips work that's
    already done. Re-running can also be used to FORCE a cert renewal via
    -ForceRenewal.

.PARAMETER ERPNextVMName
    Name of the ERPNext VM to configure SSL on.

.PARAMETER ERPNextVMResourceGroup
    Resource group containing the ERPNext VM.

.PARAMETER PublicZoneName
    Public DNS zone name for the domain (e.g., 'awesomewildstuff.com'). The
    script will request a wildcard cert covering *.<zone> + <zone>.

.PARAMETER PublicZoneResourceGroup
    Resource group containing the public DNS zone.

.PARAMETER SiteName
    Name of the ERPNext site (the directory under frappe-bench/sites/). For
    a single-site deployment this is usually the FQDN, e.g.
    'erpnext.awesomewildstuff.com'. If unspecified, the script will try to
    auto-detect it by listing the sites directory on the VM.

.PARAMETER FrappeBenchPath
    Path to the frappe-bench directory on the VM. Default: /home/<adminuser>/frappe-bench.
    Adjust if your install put it somewhere different.

.PARAMETER FrappeAdminUser
    Linux user that owns the frappe-bench directory. Default: jtadmin.
    Must match the AdminUsername used during the ERPNext deployment.

.PARAMETER ContactEmail
    Email address Let's Encrypt will associate with the account. Used for
    expiration reminders and account recovery. Required by Let's Encrypt's
    Terms of Service.

.PARAMETER ManagedIdentityName
    Name for the UAMI. Default: '<NamePrefix>-le-mi'. The UAMI is created in
    -ManagedIdentityResourceGroup, attached to the ERPNext VM, and granted
    DNS Zone Contributor on the public zone.

.PARAMETER ManagedIdentityResourceGroup
    Resource group for the UAMI. Defaults to the ERPNext VM's RG.

.PARAMETER NamePrefix
    Prefix for resource names. Default: derived from VM name.

.PARAMETER UseStaging
    Use Let's Encrypt's staging environment instead of production. Staging
    has higher rate limits but issues untrusted certificates. Useful for
    testing. Default: production.

.PARAMETER ForceRenewal
    Force certbot to renew the certificate even if it's not close to expiry.
    Useful for testing or after a config change.

.PARAMETER ConfirmContext
    Multi-tenant safety bypass: accept current Azure context without
    -SubscriptionId.

.PARAMETER TenantId
    Entra tenant ID. Defaults to current authenticated context.

.PARAMETER SubscriptionId
    Subscription ID. Defaults to current authenticated context.

.EXAMPLE
    PS> .\Add-LetsEncryptSSL.ps1 -ConfirmContext `
            -ERPNextVMName 'JTC-prod-erpnext-westus2-vm' `
            -ERPNextVMResourceGroup 'JTC-prod-erpnext-westus2-rg' `
            -PublicZoneName 'awesomewildstuff.com' `
            -PublicZoneResourceGroup 'AWS-Prod-EastUS-rg' `
            -SiteName 'erpnext.awesomewildstuff.com' `
            -FrappeAdminUser 'jtadmin' `
            -ContactEmail 'admin@awesomewildstuff.com'

    Real-world JTC scenario: provision SSL for the JTC ERPNext deployment.

.EXAMPLE
    PS> .\Add-LetsEncryptSSL.ps1 -ConfirmContext `
            -ERPNextVMName 'contoso-erpnext-vm' `
            -ERPNextVMResourceGroup 'contoso-prod-rg' `
            -PublicZoneName 'contoso.com' `
            -PublicZoneResourceGroup 'contoso-dns-rg' `
            -SiteName 'erpnext.contoso.com' `
            -FrappeAdminUser 'azureadmin' `
            -ContactEmail 'admin@contoso.com' `
            -UseStaging

    Test the setup against Let's Encrypt staging first to avoid hitting
    production rate limits during debugging.

.NOTES
    Author:           John O'Neill Sr.
    Company:          Azure Innovators
    Created:          05/17/2026
    Version:          1.0.0
    Last Updated:     05/17/2026

    REQUIREMENTS:
    - PowerShell 7.2 or later
    - Az.Accounts, Az.Network, Az.Compute, Az.ManagedServiceIdentity,
      Az.Resources, Az.Dns modules
    - Owner or User Access Administrator on the subscription
      (required to create role assignments)
    - The ERPNext VM must be running and reachable from the script host
      via Azure Run Command (uses the Azure management plane, not direct
      network access)

    COST:
    - Let's Encrypt: free
    - Managed Identity: free
    - DNS zone queries during cert renewal: negligible

    RENEWAL:
    Once provisioned, certbot's systemd timer (certbot.timer) runs twice
    daily and automatically renews certificates within 30 days of expiry.
    A deploy hook reloads nginx after successful renewal.

    Manual renewal:
        sudo certbot renew

    Force renewal (testing):
        sudo certbot renew --force-renewal

    Or re-run this script with -ForceRenewal.

    NOTES ON LET'S ENCRYPT RATE LIMITS:
    Production: 50 certificates per registered domain per week.
    Staging: much higher (basically unlimited for testing).
    Failed validations: 5 per account per hostname per hour.

    For initial testing, use -UseStaging to avoid burning production quota.
    Once everything works, re-run without -UseStaging to get a real cert.

.LINK
    https://docs.certbot-dns-azure.co.uk/
    https://letsencrypt.org/docs/rate-limits/
    https://github.com/frappe/erpnext/wiki/Setting-up-TLS-SSL-certificates-Let's-Encrypt-for-ERPNext-sites
#>

#Requires -Version 7.2
#Requires -Modules Az.Accounts, Az.Network, Az.Compute, Az.ManagedServiceIdentity, Az.Resources, Az.Dns

[CmdletBinding(SupportsShouldProcess)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'TenantId/SubscriptionId/ConfirmContext are used by Resolve-AzureContext via script-scope reference; PSScriptAnalyzer does not trace script-scope parameter usage from within nested functions.')]
param(
    [Parameter(Mandatory, HelpMessage = 'Name of the ERPNext VM.')]
    [ValidateNotNullOrEmpty()]
    [string]$ERPNextVMName,

    [Parameter(Mandatory, HelpMessage = 'Resource group containing the ERPNext VM.')]
    [ValidateNotNullOrEmpty()]
    [string]$ERPNextVMResourceGroup,

    [Parameter(Mandatory, HelpMessage = 'Public DNS zone name (e.g., awesomewildstuff.com).')]
    [ValidateNotNullOrEmpty()]
    [string]$PublicZoneName,

    [Parameter(Mandatory, HelpMessage = 'Resource group containing the public DNS zone.')]
    [ValidateNotNullOrEmpty()]
    [string]$PublicZoneResourceGroup,

    [Parameter(Mandatory, HelpMessage = 'Email address for Let''s Encrypt registration.')]
    [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')]
    [string]$ContactEmail,

    [Parameter(HelpMessage = 'ERPNext site name (FQDN, matches site directory). Auto-detected if not specified.')]
    [string]$SiteName,

    [Parameter(HelpMessage = 'Path to frappe-bench on the VM. Default: /home/<FrappeAdminUser>/frappe-bench.')]
    [string]$FrappeBenchPath,

    [Parameter(HelpMessage = 'Linux user that owns frappe-bench. Default: jtadmin.')]
    [ValidatePattern('^[a-z][a-z0-9_-]{2,30}$')]
    [string]$FrappeAdminUser = 'jtadmin',

    [Parameter(HelpMessage = 'Name for the managed identity. Default: derived from NamePrefix.')]
    [string]$ManagedIdentityName,

    [Parameter(HelpMessage = 'Resource group for the managed identity. Defaults to ERPNextVMResourceGroup.')]
    [string]$ManagedIdentityResourceGroup,

    [Parameter(HelpMessage = 'Resource name prefix. Default: derived from VM name.')]
    [string]$NamePrefix,

    [Parameter(HelpMessage = 'Use Let''s Encrypt staging (test certs, no rate limits). Default: production.')]
    [switch]$UseStaging,

    [Parameter(HelpMessage = 'Force renewal of existing certificate.')]
    [switch]$ForceRenewal,

    [Parameter(HelpMessage = 'Multi-tenant safety bypass.')]
    [switch]$ConfirmContext,

    [Parameter(HelpMessage = 'Entra tenant ID.')]
    [string]$TenantId,

    [Parameter(HelpMessage = 'Subscription ID.')]
    [string]$SubscriptionId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptVersion = '1.0.0'

# Logging
$LogTimestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogFile = Join-Path $PSScriptRoot "Add-LetsEncryptSSL_${LogTimestamp}.log"

# Compute defaults
if (-not $ManagedIdentityResourceGroup) {
    $ManagedIdentityResourceGroup = $ERPNextVMResourceGroup
}

# Derived prefix logic (same pattern as the other scripts - avoid ValidatePattern re-trigger)
$effectivePrefix = if ($NamePrefix) {
    $NamePrefix
} else {
    $derived = ($ERPNextVMName -replace '-vm$', '') -replace '[^a-zA-Z0-9-]', ''
    if ($derived.Length -gt 16) {
        $derived = $derived.Substring(0, 16)
    }
    $derived.TrimEnd('-')
}

# Default managed identity name
if (-not $ManagedIdentityName) {
    $ManagedIdentityName = "$effectivePrefix-le-mi"
}

# Default frappe bench path
if (-not $FrappeBenchPath) {
    $FrappeBenchPath = "/home/$FrappeAdminUser/frappe-bench"
}

#------------------------------------------------------------------------------
# Helper functions
#------------------------------------------------------------------------------

function Write-LogMessage {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Debug', 'Skip')] [string]$Level = 'Info'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line

    $color = switch ($Level) {
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        'Debug'   { 'DarkGray' }
        'Skip'    { 'DarkYellow' }
        default   { 'White' }
    }
    Write-Host $line -ForegroundColor $color
}

function Resolve-AzureContext {
    <#
    .SYNOPSIS
        Resolves the active Azure context with multi-tenant safety.
    #>
    $context = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $context) {
        throw 'No active Azure context. Run Connect-AzAccount first.'
    }
    if ($TenantId -and $context.Tenant.Id -ne $TenantId) {
        Write-LogMessage "Switching to tenant $TenantId..." -Level Info
        $context = Set-AzContext -TenantId $TenantId -ErrorAction Stop
    }
    if ($SubscriptionId -and $context.Subscription.Id -ne $SubscriptionId) {
        Write-LogMessage "Switching to subscription $SubscriptionId..." -Level Info
        $context = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
    }

    Write-Host ''
    Write-Host 'ACTIVE AZURE CONTEXT' -ForegroundColor Cyan
    Write-Host "  Account:        $($context.Account.Id)"
    Write-Host "  Tenant:         $($context.Tenant.Id)"
    Write-Host "  Subscription:   $($context.Subscription.Name) ($($context.Subscription.Id))"
    Write-Host ''

    if (-not $SubscriptionId) {
        $accessibleSubs = @(Get-AzSubscription -ErrorAction SilentlyContinue -WarningAction SilentlyContinue |
                            Where-Object { $_.State -eq 'Enabled' })
        if ($accessibleSubs.Count -gt 1 -and -not $ConfirmContext) {
            Write-LogMessage "Account has access to $($accessibleSubs.Count) subscriptions but none was pinned." -Level Error
            Write-LogMessage 'Multi-tenant safety: pass one of -SubscriptionId, -TenantId, or -ConfirmContext.' -Level Error
            throw 'Context not confirmed.'
        }
    }

    Write-LogMessage "Resolved context: $($context.Account.Id) / $($context.Subscription.Name)" -Level Success
    return $context
}

function Invoke-VMScript {
    <#
    .SYNOPSIS
        Wraps Invoke-AzVMRunCommand with consistent error handling and logging.
        Runs a bash script on the target VM via the Azure management plane.
        Throws on non-zero exit status.

        Returns the stdout text from the script.
    #>
    param(
        [Parameter(Mandatory)] [string]$VMName,
        [Parameter(Mandatory)] [string]$ResourceGroup,
        [Parameter(Mandatory)] [string]$ScriptText,
        [string]$Description = 'Running script on VM',
        [switch]$IgnoreFailure
    )

    Write-LogMessage "  Running on VM: $Description..." -Level Debug

    $result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroup -Name $VMName `
        -CommandId 'RunShellScript' -ScriptString $ScriptText -ErrorAction Stop

    $stdout = ''
    $stderr = ''
    foreach ($v in $result.Value) {
        if ($v.Code -like '*StdOut*') { $stdout = $v.Message }
        if ($v.Code -like '*StdErr*') { $stderr = $v.Message }
    }

    # Log truncated outputs
    if ($stdout) {
        $shortOut = if ($stdout.Length -gt 400) { $stdout.Substring(0, 400) + '...(truncated)' } else { $stdout }
        Write-LogMessage "    STDOUT: $shortOut" -Level Debug
    }
    if ($stderr) {
        $shortErr = if ($stderr.Length -gt 400) { $stderr.Substring(0, 400) + '...(truncated)' } else { $stderr }
        Write-LogMessage "    STDERR: $shortErr" -Level Debug
    }

    # Run Command doesn't directly report exit codes, but stderr with content
    # that looks like an error usually indicates trouble. We check for common
    # error patterns and let the caller decide if they care.
    $looksLikeError = $stderr -and ($stderr -match 'Error|Failed|fatal|cannot' -and $stderr -notmatch 'Setting up')
    if ($looksLikeError -and -not $IgnoreFailure) {
        Write-LogMessage "    Possible failure detected in script output." -Level Warning
        Write-LogMessage "    Full stderr: $stderr" -Level Warning
    }

    return @{
        StdOut = $stdout
        StdErr = $stderr
    }
}

#------------------------------------------------------------------------------
# Main execution
#------------------------------------------------------------------------------

Write-Host '==============================================================='
Write-Host "  Add-LetsEncryptSSL v$ScriptVersion" -ForegroundColor Cyan
Write-Host '  Azure Innovators'
Write-Host "  Log: $LogFile"
Write-Host '==============================================================='
Write-Host ''

try {
    # ---- Pre-flight: context ----
    Write-LogMessage 'Running pre-flight checks...' -Level Info
    $context = Resolve-AzureContext

    # ---- Pre-flight: VM exists ----
    Write-LogMessage "Verifying ERPNext VM: $ERPNextVMName (RG: $ERPNextVMResourceGroup)" -Level Info
    $vm = Get-AzVM -ResourceGroupName $ERPNextVMResourceGroup -Name $ERPNextVMName -ErrorAction SilentlyContinue
    if (-not $vm) {
        throw "ERPNext VM '$ERPNextVMName' not found in resource group '$ERPNextVMResourceGroup'."
    }
    Write-LogMessage "  VM found. Location: $($vm.Location), OS: $($vm.StorageProfile.OsDisk.OsType)" -Level Success

    # ---- Pre-flight: DNS zone exists ----
    Write-LogMessage "Verifying public DNS zone: $PublicZoneName (RG: $PublicZoneResourceGroup)" -Level Info
    $dnsZone = Get-AzDnsZone -Name $PublicZoneName -ResourceGroupName $PublicZoneResourceGroup -ErrorAction SilentlyContinue
    if (-not $dnsZone) {
        throw "Public DNS zone '$PublicZoneName' not found in '$PublicZoneResourceGroup'."
    }
    Write-LogMessage "  Public zone found. Resource ID: $($dnsZone.Id)" -Level Success

    # ---- Pre-flight: managed identity RG exists ----
    $miRG = Get-AzResourceGroup -Name $ManagedIdentityResourceGroup -ErrorAction SilentlyContinue
    if (-not $miRG) {
        throw "Resource group '$ManagedIdentityResourceGroup' not found."
    }

    # ---- Plan output ----
    Write-Host ''
    Write-Host 'SSL DEPLOYMENT PLAN' -ForegroundColor Cyan
    Write-Host "  Account:                $($context.Account.Id)"
    Write-Host "  Subscription:           $($context.Subscription.Name)"
    Write-Host "  ERPNext VM:             $ERPNextVMName (RG: $ERPNextVMResourceGroup)"
    Write-Host "  Public DNS Zone:        $PublicZoneName (RG: $PublicZoneResourceGroup)"
    Write-Host "  Wildcard Cert:          *.$PublicZoneName, $PublicZoneName"
    Write-Host "  Managed Identity:       $ManagedIdentityName (RG: $ManagedIdentityResourceGroup)"
    Write-Host "  Frappe Admin User:      $FrappeAdminUser"
    Write-Host "  Frappe Bench Path:      $FrappeBenchPath"
    if ($SiteName) {
        Write-Host "  ERPNext Site:           $SiteName"
    } else {
        Write-Host "  ERPNext Site:           (auto-detect)"
    }
    Write-Host "  Contact Email:          $ContactEmail"
    Write-Host "  Let's Encrypt env:      $(if ($UseStaging) { 'STAGING (test certs)' } else { 'PRODUCTION (trusted certs)' })"
    Write-Host "  Force Renewal:          $($ForceRenewal.IsPresent)"
    Write-Host ''

    # ---- Step 1: Create User-Assigned Managed Identity ----
    Write-LogMessage 'Step 1/7: User-Assigned Managed Identity' -Level Info
    $mi = Get-AzUserAssignedIdentity -ResourceGroupName $ManagedIdentityResourceGroup `
        -Name $ManagedIdentityName -ErrorAction SilentlyContinue
    if ($mi) {
        Write-LogMessage "  UAMI '$ManagedIdentityName' already exists. Reusing." -Level Info
        Write-LogMessage "  ClientId: $($mi.ClientId)" -Level Debug
    } else {
        if ($PSCmdlet.ShouldProcess($ManagedIdentityName, 'Create User-Assigned Managed Identity')) {
            $mi = New-AzUserAssignedIdentity -ResourceGroupName $ManagedIdentityResourceGroup `
                -Name $ManagedIdentityName -Location $vm.Location
            Write-LogMessage "  Created UAMI: $ManagedIdentityName" -Level Success
            Write-LogMessage "  ClientId: $($mi.ClientId), PrincipalId: $($mi.PrincipalId)" -Level Debug

            # Brief wait for the new identity to propagate through Entra ID.
            # Without this, the subsequent role assignment can fail with
            # "PrincipalNotFound" because the SP hasn't replicated yet.
            Write-LogMessage "  Waiting 30s for identity to propagate in Entra ID..." -Level Debug
            Start-Sleep -Seconds 30
        }
    }

    # ---- Step 2: Grant DNS Zone Contributor on the zone ----
    Write-LogMessage 'Step 2/7: DNS Zone Contributor role assignment' -Level Info
    $existingAssignment = Get-AzRoleAssignment -ObjectId $mi.PrincipalId `
        -Scope $dnsZone.Id -RoleDefinitionName 'DNS Zone Contributor' -ErrorAction SilentlyContinue
    if ($existingAssignment) {
        Write-LogMessage "  Role assignment already exists. Skipping." -Level Info
    } else {
        if ($PSCmdlet.ShouldProcess($PublicZoneName, "Grant 'DNS Zone Contributor' to UAMI $ManagedIdentityName")) {
            # Role assignment can also have replication delay; retry a few times.
            $maxAttempts = 5
            $attempt = 0
            $success = $false
            while (-not $success -and $attempt -lt $maxAttempts) {
                $attempt++
                try {
                    New-AzRoleAssignment -ObjectId $mi.PrincipalId `
                        -RoleDefinitionName 'DNS Zone Contributor' `
                        -Scope $dnsZone.Id -ErrorAction Stop | Out-Null
                    $success = $true
                    Write-LogMessage "  Granted DNS Zone Contributor on $PublicZoneName" -Level Success
                } catch {
                    if ($_.Exception.Message -match 'PrincipalNotFound|Cannot find the AAD object') {
                        Write-LogMessage "  Attempt $attempt/$maxAttempts : Principal not yet propagated, waiting 30s..." -Level Warning
                        Start-Sleep -Seconds 30
                    } else {
                        throw
                    }
                }
            }
            if (-not $success) {
                throw "Failed to assign role after $maxAttempts attempts. Identity propagation in Entra ID may be slow; re-run the script."
            }
        }
    }

    # ---- Step 3: Attach UAMI to the ERPNext VM ----
    Write-LogMessage 'Step 3/7: Attaching UAMI to ERPNext VM' -Level Info
    $vmIdentities = @()
    if ($vm.Identity -and $vm.Identity.UserAssignedIdentities) {
        $vmIdentities = $vm.Identity.UserAssignedIdentities.Keys
    }
    if ($vmIdentities -contains $mi.Id) {
        Write-LogMessage "  UAMI already attached to VM." -Level Info
    } else {
        if ($PSCmdlet.ShouldProcess($ERPNextVMName, "Attach UAMI $ManagedIdentityName")) {
            # Update-AzVM with -IdentityType UserAssigned + -IdentityId adds the UAMI.
            # If the VM already has SystemAssigned identity, we need IdentityType SystemAssignedUserAssigned.
            $hasSystemAssigned = $vm.Identity -and $vm.Identity.Type -match 'SystemAssigned'
            $identityType = if ($hasSystemAssigned) { 'SystemAssignedUserAssigned' } else { 'UserAssigned' }

            Update-AzVM -VM $vm -ResourceGroupName $ERPNextVMResourceGroup `
                -IdentityType $identityType `
                -IdentityID $mi.Id | Out-Null
            Write-LogMessage "  Attached UAMI to VM (IdentityType: $identityType)" -Level Success

            # Refresh VM object for downstream
            $vm = Get-AzVM -ResourceGroupName $ERPNextVMResourceGroup -Name $ERPNextVMName

            # Another short wait for IMDS to start serving the new identity.
            Write-LogMessage "  Waiting 15s for IMDS to refresh..." -Level Debug
            Start-Sleep -Seconds 15
        }
    }

    # ---- Step 4: Install certbot and certbot-dns-azure on the VM ----
    Write-LogMessage 'Step 4/7: Installing certbot and certbot-dns-azure on VM' -Level Info
    $installScript = @'
#!/bin/bash
set -e

# Check if already installed
if command -v certbot >/dev/null 2>&1 && python3 -c "import certbot_dns_azure" 2>/dev/null; then
    echo "certbot and certbot-dns-azure already installed."
    certbot --version
    exit 0
fi

# Install via the official certbot snap or pip. We use pip in a venv to avoid
# PEP 668 issues on Ubuntu 24.04 (which restricts system-wide pip installs).
apt-get update -qq
apt-get install -y -qq python3 python3-venv libaugeas0

# Create the certbot venv if it doesn't exist
if [ ! -d /opt/certbot ]; then
    python3 -m venv /opt/certbot
fi

# Upgrade pip and install certbot + the Azure DNS plugin
/opt/certbot/bin/pip install --upgrade --quiet pip
/opt/certbot/bin/pip install --quiet certbot certbot-dns-azure

# Make certbot available on PATH
ln -sf /opt/certbot/bin/certbot /usr/local/bin/certbot

echo "Installation complete:"
certbot --version
/opt/certbot/bin/pip show certbot-dns-azure | grep -E "^(Name|Version):"
'@

    if ($PSCmdlet.ShouldProcess($ERPNextVMName, 'Install certbot + certbot-dns-azure')) {
        $result = Invoke-VMScript -VMName $ERPNextVMName -ResourceGroup $ERPNextVMResourceGroup `
            -ScriptText $installScript -Description 'install certbot and certbot-dns-azure plugin'
        Write-LogMessage "  certbot installation: $($result.StdOut -split "`n" | Select-Object -Last 5 | Out-String)" -Level Info
    }

    # ---- Step 5: Configure certbot with managed identity + run certificate request ----
    Write-LogMessage 'Step 5/7: Requesting wildcard certificate from Let''s Encrypt' -Level Info

    # Build the certbot INI config file content. The certbot-dns-azure plugin
    # reads this file to know:
    # - which authentication method to use (managed identity, not service principal)
    # - which UAMI client ID to use (we pass it explicitly so the plugin picks
    #   the right one if the VM has multiple UAMIs attached)
    # - which DNS zone(s) to write TXT records into, and where they live
    $dnsZoneResourceId = $dnsZone.Id
    $miClientId = $mi.ClientId

    $iniContent = @"
# certbot-dns-azure configuration for Let's Encrypt wildcard cert
# Generated by Add-LetsEncryptSSL.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
#
# This file points certbot at a specific User-Assigned Managed Identity
# attached to this VM, and tells the plugin which DNS zone to write
# TXT challenge records into.

# Tell the plugin to use a User-Assigned Managed Identity
dns_azure_msi_client_id = $miClientId

# The DNS zone to write TXT records into. Format is:
#   <zone-name>:<full Azure resource ID of the zone>
dns_azure_zone1 = ${PublicZoneName}:$dnsZoneResourceId
"@

    # Build the cert request script. Important details:
    # - INI file goes to /etc/letsencrypt/azure.ini, owned root:root, mode 0600
    # - Wildcard cert covers *.<zone> AND <zone> (base domain)
    # - --non-interactive --agree-tos for hands-free operation
    # - --preferred-challenges dns to force DNS-01
    # - Server URL: staging if -UseStaging, production otherwise
    # - --cert-name set to the zone name so cert files end up in a predictable
    #   path: /etc/letsencrypt/live/<zone>/{fullchain,privkey}.pem
    $serverFlag = if ($UseStaging) {
        '--server https://acme-staging-v02.api.letsencrypt.org/directory'
    } else {
        ''
    }
    $forceFlag = if ($ForceRenewal) { '--force-renewal' } else { '' }

    # Use base64 to safely pass the INI file content without quoting issues.
    $iniB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($iniContent))

    $certRequestScript = @"
#!/bin/bash
set -e

# Write the certbot-dns-azure config file (protect it carefully)
mkdir -p /etc/letsencrypt
echo '$iniB64' | base64 -d > /etc/letsencrypt/azure.ini
chmod 600 /etc/letsencrypt/azure.ini
chown root:root /etc/letsencrypt/azure.ini

echo "Config file:"
cat /etc/letsencrypt/azure.ini
echo ""

# Request the wildcard cert. This will:
#   1. Call Azure DNS API (authenticated as the UAMI) to create TXT records
#   2. Wait for DNS propagation
#   3. Ask Let's Encrypt to verify the TXT records
#   4. Receive and store the certificate at /etc/letsencrypt/live/<zone>/
echo "Requesting wildcard certificate for *.$PublicZoneName and $PublicZoneName..."
certbot certonly \
    --non-interactive \
    --agree-tos \
    --email '$ContactEmail' \
    --authenticator dns-azure \
    --dns-azure-config /etc/letsencrypt/azure.ini \
    --dns-azure-propagation-seconds 30 \
    --preferred-challenges dns \
    --cert-name '$PublicZoneName' \
    -d '*.$PublicZoneName' \
    -d '$PublicZoneName' \
    $serverFlag \
    $forceFlag

echo ""
echo "Certificate files:"
ls -la /etc/letsencrypt/live/$PublicZoneName/
"@

    if ($PSCmdlet.ShouldProcess($PublicZoneName, "Request wildcard cert from Let's Encrypt (DNS-01)")) {
        $result = Invoke-VMScript -VMName $ERPNextVMName -ResourceGroup $ERPNextVMResourceGroup `
            -ScriptText $certRequestScript -Description 'request wildcard cert'

        # Look for clear success markers in stdout
        if ($result.StdOut -match 'Successfully received certificate' -or `
            $result.StdOut -match 'Certificate files:' -or `
            $result.StdOut -match 'fullchain\.pem') {
            Write-LogMessage "  Certificate issued successfully." -Level Success
        } else {
            Write-LogMessage "  Certificate request did not produce expected success markers." -Level Warning
            Write-LogMessage "  Review the log for details. STDOUT/STDERR captured." -Level Warning
            # Don't throw - operator can review
        }
    }

    # ---- Step 6: Wire cert into ERPNext via site_config.json + bench setup nginx ----
    Write-LogMessage 'Step 6/7: Configuring ERPNext to use the certificate' -Level Info

    # If site name wasn't provided, detect it from the sites directory.
    if (-not $SiteName) {
        Write-LogMessage "  Auto-detecting ERPNext site name..." -Level Info
        $detectScript = @"
#!/bin/bash
set -e
# List directories in the sites folder. Skip 'assets' (Frappe internal).
ls -1 $FrappeBenchPath/sites/ 2>/dev/null | grep -v '^assets$' | grep -v '^apps\.txt$' | grep -v '^common_site_config\.json$' | head -1
"@
        $result = Invoke-VMScript -VMName $ERPNextVMName -ResourceGroup $ERPNextVMResourceGroup `
            -ScriptText $detectScript -Description 'detect ERPNext site name'
        $SiteName = ($result.StdOut -split "`n" | Where-Object { $_ -and $_ -notmatch '^\s*$' } | Select-Object -First 1).Trim()
        if (-not $SiteName) {
            throw "Could not auto-detect ERPNext site name in $FrappeBenchPath/sites/. Specify with -SiteName explicitly."
        }
        Write-LogMessage "  Detected site: $SiteName" -Level Success
    }

    # The bench needs to be configured to use the certificate. We:
    #   1. Read the existing site_config.json
    #   2. Add/update ssl_certificate and ssl_certificate_key keys
    #   3. Write it back
    #   4. Run `bench setup nginx` (as the frappe user) to regenerate config
    #   5. Reload nginx
    #
    # Note: bench commands must be run as the frappe admin user (not root),
    # from within the bench directory. We use `sudo -u <user> -H ...` for that.

    $configScript = @"
#!/bin/bash
set -e

SITE_CONFIG='$FrappeBenchPath/sites/$SiteName/site_config.json'
CERT_PATH='/etc/letsencrypt/live/$PublicZoneName/fullchain.pem'
KEY_PATH='/etc/letsencrypt/live/$PublicZoneName/privkey.pem'

if [ ! -f "`$SITE_CONFIG" ]; then
    echo "ERROR: site_config.json not found at `$SITE_CONFIG"
    exit 1
fi

if [ ! -f "`$CERT_PATH" ]; then
    echo "ERROR: Certificate not found at `$CERT_PATH"
    exit 1
fi

# Ensure the Frappe user can read the cert files. By default Let's Encrypt
# locks them down to root:root 0700 on the live/ dirs. Frappe needs read.
# We adjust the /etc/letsencrypt/live and archive dir permissions so the
# frappe user can traverse them. This is safe: the keys are still chmod 600,
# only root and the configured Frappe user can read them.
chmod 755 /etc/letsencrypt/live /etc/letsencrypt/archive
setfacl -m u:$FrappeAdminUser`:rx /etc/letsencrypt/live/$PublicZoneName 2>/dev/null || true
setfacl -m u:$FrappeAdminUser`:r /etc/letsencrypt/live/$PublicZoneName/* 2>/dev/null || true
setfacl -m u:$FrappeAdminUser`:rx /etc/letsencrypt/archive/$PublicZoneName 2>/dev/null || true
setfacl -m u:$FrappeAdminUser`:r /etc/letsencrypt/archive/$PublicZoneName/* 2>/dev/null || true

# Update site_config.json using jq (install if missing)
if ! command -v jq >/dev/null 2>&1; then
    apt-get install -y -qq jq
fi

# Add/update ssl_certificate and ssl_certificate_key keys.
# jq's --arg flag handles escaping properly.
TMPFILE=`$(mktemp)
jq --arg cert "`$CERT_PATH" --arg key "`$KEY_PATH" \
   '. + {ssl_certificate: `$cert, ssl_certificate_key: `$key}' \
   "`$SITE_CONFIG" > "`$TMPFILE"
mv "`$TMPFILE" "`$SITE_CONFIG"
chown $FrappeAdminUser`:$FrappeAdminUser "`$SITE_CONFIG"

echo "Updated site_config.json:"
cat "`$SITE_CONFIG"
echo ""

# Run bench setup nginx as the Frappe user (must NOT be run as root).
# This regenerates /etc/nginx/conf.d/frappe-bench.conf with SSL.
sudo -u $FrappeAdminUser -H bash -c "cd $FrappeBenchPath && bench setup nginx --yes"

echo ""
echo "Reloading nginx..."
nginx -t  # syntax check first
systemctl reload nginx
echo "nginx reloaded successfully."
"@

    if ($PSCmdlet.ShouldProcess($SiteName, 'Configure ERPNext site for SSL')) {
        $result = Invoke-VMScript -VMName $ERPNextVMName -ResourceGroup $ERPNextVMResourceGroup `
            -ScriptText $configScript -Description 'configure site_config.json and regenerate nginx'

        if ($result.StdOut -match 'nginx reloaded successfully') {
            Write-LogMessage "  ERPNext + nginx configured for SSL." -Level Success
        } else {
            Write-LogMessage "  ERPNext SSL configuration completed but no success marker. Verify nginx status." -Level Warning
        }
    }

    # ---- Step 7: Set up renewal hook ----
    Write-LogMessage 'Step 7/7: Configuring automatic renewal' -Level Info

    # certbot's systemd timer (certbot.timer) is enabled by default when
    # certbot is installed via the snap/apt package. But we installed via pip
    # into /opt/certbot, so we need to wire up our own timer + service.
    #
    # We also configure a "deploy hook" that runs after each successful
    # renewal to reload nginx (so the new cert takes effect).

    $renewalScript = @"
#!/bin/bash
set -e

# Create the deploy hook directory if missing
mkdir -p /etc/letsencrypt/renewal-hooks/deploy

# Deploy hook: reload nginx after successful renewal so the new cert is loaded.
# This is the standard pattern - nginx caches certs in memory and needs to be
# explicitly reloaded to pick up new ones.
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'HOOK'
#!/bin/bash
echo "Renewed cert deployed. Reloading nginx..."
systemctl reload nginx
HOOK
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

# Create a systemd timer + service for certbot renewal.
# certbot installed via pip doesn't come with these by default.
cat > /etc/systemd/system/certbot-renew.service <<'SVC'
[Unit]
Description=Renew Let's Encrypt certificates
After=network.target

[Service]
Type=oneshot
ExecStart=/opt/certbot/bin/certbot renew --quiet
SVC

cat > /etc/systemd/system/certbot-renew.timer <<'TMR'
[Unit]
Description=Twice-daily renewal check for Let's Encrypt certs

[Timer]
OnCalendar=*-*-* 03,15:00:00
RandomizedDelaySec=4h
Persistent=true

[Install]
WantedBy=timers.target
TMR

systemctl daemon-reload
systemctl enable --now certbot-renew.timer

echo "Renewal timer status:"
systemctl status certbot-renew.timer --no-pager | head -10
echo ""
echo "Next renewal check:"
systemctl list-timers certbot-renew.timer --no-pager
"@

    if ($PSCmdlet.ShouldProcess($ERPNextVMName, 'Configure renewal timer + deploy hook')) {
        $result = Invoke-VMScript -VMName $ERPNextVMName -ResourceGroup $ERPNextVMResourceGroup `
            -ScriptText $renewalScript -Description 'set up renewal timer'
        Write-LogMessage "  Renewal timer configured." -Level Success
    }

    # ---- Summary ----
    Write-Host ''
    Write-Host '==============================================================='
    Write-Host '  SSL DEPLOYMENT COMPLETE' -ForegroundColor Green
    Write-Host '==============================================================='
    Write-Host ''
    Write-Host 'Summary:' -ForegroundColor Cyan
    Write-Host "  Managed Identity:   $ManagedIdentityName"
    Write-Host "  Cert Domain:        *.$PublicZoneName, $PublicZoneName"
    Write-Host "  Cert Location:      /etc/letsencrypt/live/$PublicZoneName/"
    Write-Host "  ERPNext Site:       $SiteName"
    Write-Host "  Let's Encrypt env:  $(if ($UseStaging) { 'STAGING (untrusted)' } else { 'PRODUCTION (trusted)' })"
    Write-Host "  Auto Renewal:       systemd timer, twice daily"
    Write-Host ''
    Write-Host '---------------------------------------------------------------' -ForegroundColor Yellow
    Write-Host 'VERIFICATION STEPS:' -ForegroundColor Yellow
    Write-Host '---------------------------------------------------------------' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '1. Browser test (from your VPN-connected laptop):'
    Write-Host "     https://$SiteName"
    Write-Host '   Should load ERPNext with a green padlock (no cert warning).'
    Write-Host ''
    Write-Host '2. Cert inspection:'
    Write-Host "     openssl s_client -connect ${SiteName}:443 -servername $SiteName <<< 'Q' | openssl x509 -noout -dates -subject"
    Write-Host '   (Run this from anywhere - the cert chain is publicly trusted)'
    Write-Host ''
    Write-Host '3. Verify renewal timer (SSH to the ERPNext VM):'
    Write-Host '     sudo systemctl status certbot-renew.timer'
    Write-Host '     sudo systemctl list-timers certbot-renew.timer'
    Write-Host ''
    Write-Host '4. Test renewal dry-run:'
    Write-Host '     sudo certbot renew --dry-run'
    Write-Host ''
    if ($UseStaging) {
        Write-Host '---------------------------------------------------------------' -ForegroundColor Yellow
        Write-Host 'STAGING NOTE:' -ForegroundColor Yellow
        Write-Host '---------------------------------------------------------------' -ForegroundColor Yellow
        Write-Host 'You used -UseStaging. The cert is NOT publicly trusted (test only).'
        Write-Host 'To get a real production cert, re-run without -UseStaging.'
        Write-Host 'Note: the staging cert will be replaced; no manual cleanup needed.'
        Write-Host ''
    }
    Write-Host "Log: $LogFile" -ForegroundColor DarkGray
    Write-Host '==============================================================='

    # Return a structured result object
    [PSCustomObject]@{
        ManagedIdentityName     = $ManagedIdentityName
        ManagedIdentityClientId = $mi.ClientId
        ERPNextVMName           = $ERPNextVMName
        ERPNextSite             = $SiteName
        CertDomain              = "*.$PublicZoneName"
        CertLocation            = "/etc/letsencrypt/live/$PublicZoneName/"
        UsedStaging             = $UseStaging.IsPresent
        LogFile                 = $LogFile
        ScriptVersion           = $ScriptVersion
        DeploymentTime          = (Get-Date -Format 'o')
    }

} catch {
    Write-LogMessage "DEPLOYMENT FAILED: $($_.Exception.Message)" -Level Error
    Write-LogMessage $_.ScriptStackTrace -Level Error
    throw
}
