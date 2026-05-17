<#
.SYNOPSIS
    Removes Azure resources created by Deploy-ERPNextToAzure.ps1.

.DESCRIPTION
    Tears down the resources provisioned by Deploy-ERPNextToAzure.ps1 so an
    environment can be cleanly rebuilt for further testing. Operates in two
    modes:

        ResourceGroup mode (default) - Deletes the entire Resource Group and
            every resource within it. Fastest and most thorough.

        Selective mode (-Selective) - Deletes only the resources this deploy
            script creates (VM, NIC, NSG, PIP, VNet, optional Key Vault),
            leaving the Resource Group intact. Use when the RG contains other
            workloads you want to preserve.

    Key behaviors:
        - Idempotent: missing resources are reported and skipped, not failed.
        - Detects and (with -RemoveLocks) removes delete/read locks.
        - Properly orders deletion to satisfy Azure dependency rules
          (VM > NIC > PIP/NSG > VNet).
        - Handles Key Vault soft-delete: with -PurgeKeyVault, the vault is
          purged so its name becomes available for reuse immediately.
        - Optionally removes local artifacts (connection info JSON, logs,
          generated install-erpnext.sh).
        - Supports -WhatIf and -Confirm for dry-run rehearsal.

    SAFETY:
        - Prompts for confirmation by default unless -Force is supplied.
        - Refuses to run against subscriptions tagged Production unless
          -AcknowledgeProductionRisk is supplied.

.PARAMETER ResourceGroupName
    Name of the Azure Resource Group to tear down.
    Default: JTC-prod-erpnext-eastus-rg

.PARAMETER VMName
    Name of the VM. Used to derive related resource names (NIC, NSG, PIP, VNet)
    when running in -Selective mode. Default: JTC-prod-erpnext-eastus-vm

.PARAMETER SubscriptionId
    Optional Azure subscription ID to target. If omitted, the current Az context
    subscription is used. Recommended in multi-tenant scenarios to avoid
    accidentally targeting the wrong client.

.PARAMETER TenantId
    Optional Azure tenant (directory) ID to target. Useful when the same account
    has access to multiple tenants (typical for consultants working with
    multiple clients). When specified, the script switches to that tenant
    before resolving the subscription.

.PARAMETER SelectContext
    If specified, presents an interactive picker listing all accessible
    subscriptions across all tenants the account can see. The selected
    subscription becomes the active context for the teardown.

.PARAMETER Selective
    If specified, deletes only resources matching this deployment's naming
    convention (based on -VMName) instead of the entire Resource Group.
    Useful when the RG hosts other resources you want to preserve.

.PARAMETER KeyVaultName
    Name of the Key Vault to remove. Required only if the original deployment
    used -UseKeyVault. Without this, Key Vaults are left untouched.

.PARAMETER PurgeKeyVault
    If specified, purges the Key Vault after deletion so its name is freed
    immediately. Without this, the vault remains soft-deleted (default retention
    is 7-90 days depending on tenant policy) and its name cannot be reused.

.PARAMETER RemoveLocks
    If specified, automatically removes any delete or read locks found on the
    target Resource Group or its resources. Without this, the script reports
    locks and exits with an error rather than deleting locked resources.

.PARAMETER RemoveLocalArtifacts
    If specified, also removes local files created by the deployment script:
        - erpnext-connection-info.json
        - install-erpnext.sh
        - Deploy-ERPNextToAzure_*.log (all matching timestamped logs)
    Files are removed from the directory this script runs from.

.PARAMETER Force
    Bypass interactive confirmation. Use with caution - especially destructive
    in combination with -PurgeKeyVault.

.PARAMETER AcknowledgeProductionRisk
    Required to run against a subscription with the tag Environment=Production.
    This is a deliberate seatbelt; do not bypass casually.

.PARAMETER TimeoutMinutes
    Maximum time in minutes to wait for the Resource Group deletion to finish
    when running in ResourceGroup mode. Default: 30.

.EXAMPLE
    PS> .\Remove-ERPNextAzureDeployment.ps1 -WhatIf

    Shows what would be deleted without making changes.

.EXAMPLE
    PS> .\Remove-ERPNextAzureDeployment.ps1

    Interactive teardown of the entire default Resource Group, with
    confirmation prompt.

.EXAMPLE
    PS> .\Remove-ERPNextAzureDeployment.ps1 -Force `
            -KeyVaultName 'JTC-prod-kv-eastus' -PurgeKeyVault `
            -RemoveLocalArtifacts

    Full teardown with no prompts, purges the Key Vault so its name can be
    reused immediately, and removes local connection info and logs.

.EXAMPLE
    PS> .\Remove-ERPNextAzureDeployment.ps1 -Selective -Force

    Removes only the ERPNext VM and its directly associated resources, leaving
    the Resource Group and any other resources in it untouched.

.EXAMPLE
    PS> .\Remove-ERPNextAzureDeployment.ps1 -ResourceGroupName 'JTC-test-rg' `
            -RemoveLocks -Force

    Tears down a test RG, removing any delete locks that would otherwise block
    deletion.

.EXAMPLE
    PS> .\Remove-ERPNextAzureDeployment.ps1 -SelectContext -WhatIf

    Presents an interactive subscription picker, then shows the teardown plan
    without making changes. Useful when working across multiple client tenants.

.EXAMPLE
    PS> .\Remove-ERPNextAzureDeployment.ps1 `
            -TenantId '11111111-2222-3333-4444-555555555555' `
            -SubscriptionId '66666666-7777-8888-9999-000000000000' `
            -Force

    Explicitly targets a specific tenant and subscription regardless of the
    active Az context.

.INPUTS
    None.

.OUTPUTS
    System.Management.Automation.PSCustomObject

    Returns a summary of what was deleted, skipped, or failed.

.NOTES
    Author:           John O'Neill Sr.
    Company:          Azure Innovators
    Create Date:      05/15/2026
    Version:          1.3.1
    GitHub:           https://github.com/JONeillSr/

    PREREQUISITES:
        - PowerShell 7.2 or later
        - Az modules: Az.Accounts, Az.Resources
        - Az.Compute, Az.Network (for -Selective mode)
        - Az.KeyVault (when -KeyVaultName or -PurgeKeyVault is used)
        - Contributor or Owner role on the target Resource Group
        - For -PurgeKeyVault: Key Vault Contributor + the
          "Purge Soft-Deleted Vaults" right (commonly granted via the
          built-in Key Vault Contributor role at subscription scope)

    KEY VAULT SOFT-DELETE NOTES:
        Azure Key Vault enables soft-delete on all new vaults and the setting
        cannot be disabled. After a vault is deleted, it remains recoverable
        (and its name reserved) for the configured retention period. To reuse
        the same vault name in a re-test, you must purge it. See:
        https://learn.microsoft.com/azure/key-vault/general/soft-delete-overview

.CHANGELOG
    1.2.2 - 05/16/2026 - Warn about orphaned soft-deleted Key Vaults
        - After deleting a Resource Group, the script now scans for Key
          Vaults from that RG that are now in the soft-deleted state. If
          any are found AND the user didn't pass -PurgeKeyVault, a clearly
          formatted yellow warning block is shown in the summary explaining:
            * The vault names are reserved for 90 days
            * Re-deploying with the same name will fail until purged
            * The exact command to purge them
            * The Azure portal alternative
        - This prevents the surprising "why does my next deploy fail with
          vault-name-already-exists?" question.

    1.2.1 - 05/16/2026 - Critical: RG deletion polling fix
        - The poll loop checked "while $rgJob.State -eq 'Running'" but the
          job starts in 'NotStarted' state. The loop exited immediately
          without waiting, the script reported success in zero seconds, and
          the Resource Group remained intact. This wasted no resources but
          was deeply misleading.
        - Now waits while state is in any non-terminal state (anything
          other than Completed/Failed/Stopped), explicitly handles Failed
          state by surfacing job errors, and verifies the RG is actually
          gone via Get-AzResourceGroup before reporting success.

    1.2.0 - 05/16/2026 - Multi-tenant safety, robust Key Vault purge

        Consolidated changes from 1.1.1-1.1.4. Major capability areas:

        Multi-tenant safety (parity with deploy script)
        - Added -TenantId, -SubscriptionId, -SelectContext, -ConfirmContext
        - When resource group is not in the active subscription, the script
          now searches accessible subscriptions and reports where it lives
          rather than failing with 'not found'
        - Active context displayed before any destructive operation

        Key Vault purge reliability
        - The -PurgeKeyVault path handles soft-deleted vaults outside the
          target RG (the RG is gone but the vault name is reserved)
        - Active polling: checks soft-deleted vault list every 30 seconds.
          The vault disappearing from the list confirms purge regardless of
          whether the cmdlet has returned. 20-minute total timeout
        - Periodic progress messages so the operator knows the script is
          alive during the slow Azure backend operation
        - On purge timeout: clear remediation steps (Az session reset,
          Azure portal 'Manage deleted vaults' workaround)

        -Force flag now actually suppresses ALL prompts
        - Previously Remove-AzResourceGroup showed its own confirmation
          prompt mid-teardown despite -Force. The script now sets
          $ConfirmPreference = 'None' and
          $PSDefaultParameterValues['*:Confirm'] = $false when -Force is
          passed, suppressing all downstream prompts globally
        - Belt-and-suspenders -Confirm:$false on Remove-AzResourceGroup

        Diagnostic improvements
        - Write-LogMessage accepts empty strings via [AllowEmptyString()]
          for consistent behavior with the deploy script

    1.1.0 - 05/15/2026 - Initial release
        - Full resource-group teardown
        - Selective per-resource teardown via -Selective
        - Key Vault soft-delete handling and optional purge
        - Resource lock detection and optional removal via -RemoveLocks
        - Production subscription gate via -AcknowledgeProductionRisk
        - Local artifact cleanup via -RemoveLocalArtifacts
        - Async resource group deletion with progress polling

.LINK
    https://github.com/JONeillSr/

.LINK
    https://learn.microsoft.com/azure/key-vault/general/soft-delete-overview

.LINK
    https://learn.microsoft.com/azure/azure-resource-manager/management/lock-resources
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName = "JTC-prod-erpnext-eastus-rg",

    [Parameter()]
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9-]{1,62}[a-zA-Z0-9]$')]
    [string]$VMName = "JTC-prod-erpnext-eastus-vm",

    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$TenantId,

    [Parameter()]
    [switch]$SelectContext,

    [Parameter()]
    [switch]$Selective,

    [Parameter()]
    [string]$KeyVaultName,

    [Parameter()]
    [switch]$PurgeKeyVault,

    [Parameter()]
    [switch]$RemoveLocks,

    [Parameter()]
    [switch]$RemoveLocalArtifacts,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [switch]$AcknowledgeProductionRisk,

    [Parameter()]
    [ValidateRange(5, 240)]
    [int]$TimeoutMinutes = 30,

    [Parameter(HelpMessage='Name of an external VNet (in this subscription) from which to remove a subnet. Use when the ERPNext VM was deployed with -ExistingVNetName so its subnet lives outside the ERPNext RG.')]
    [string]$ExternalVNetName,

    [Parameter(HelpMessage='Resource group containing the external VNet.')]
    [string]$ExternalVNetResourceGroup,

    [Parameter(HelpMessage='Name of the subnet to remove from the external VNet. Default: erpnext-subnet.')]
    [string]$ExternalSubnetName = 'erpnext-subnet'
)

#Requires -Version 7.2
#Requires -Modules Az.Accounts, Az.Resources

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptVersion = "1.3.1"
$LogFile = Join-Path $PSScriptRoot "Remove-ERPNextAzureDeployment_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

Write-Host "===============================================================" -ForegroundColor Yellow
Write-Host "  ERPNext Azure Teardown Script v$ScriptVersion" -ForegroundColor Yellow
Write-Host "  Azure Innovators" -ForegroundColor Yellow
Write-Host "  Log: $LogFile" -ForegroundColor DarkGray
Write-Host "===============================================================" -ForegroundColor Yellow
Write-Host ""

#region Helpers

function Write-LogMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Message,
        [Parameter()] [ValidateSet('Info','Success','Warning','Error','Debug')] [string]$Level = 'Info'
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    $color = switch ($Level) {
        'Info'    { 'White' }
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        'Debug'   { 'DarkGray' }
    }
    Write-Host $line -ForegroundColor $color
    try { Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false } catch { Write-Verbose "Suppressed (non-fatal): $_" }
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

        if ($TenantId -and $context.Tenant.Id -ne $TenantId) {
            Write-LogMessage "Switching to tenant: $TenantId" -Level Info
            $candidate = Get-AzSubscription -TenantId $TenantId -ErrorAction Stop |
                         Where-Object { $_.State -eq 'Enabled' } |
                         Select-Object -First 1
            if (-not $candidate) {
                throw "No enabled subscriptions found in tenant $TenantId for this account."
            }
            Set-AzContext -TenantId $TenantId -SubscriptionId $candidate.Id -ErrorAction Stop -WhatIf:$false | Out-Null
            $context = Get-AzContext
        }

        if ($SubscriptionId -and $context.Subscription.Id -ne $SubscriptionId) {
            Write-LogMessage "Switching to subscription: $SubscriptionId" -Level Info
            Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop -WhatIf:$false | Out-Null
            $context = Get-AzContext
        }

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
                    Set-AzContext -TenantId $picked.TenantId -SubscriptionId $picked.Id -ErrorAction Stop -WhatIf:$false | Out-Null
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

function Test-ProductionSubscription {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context)

    try {
        $sub = Get-AzSubscription -SubscriptionId $Context.Subscription.Id -ErrorAction Stop
        $tags = $sub.Tags
        if ($tags -and $tags.ContainsKey('Environment') -and $tags['Environment'] -eq 'Production') {
            return $true
        }
    } catch {
        Write-LogMessage "Could not read subscription tags: $($_.Exception.Message)" -Level Debug
    }
    return $false
}

function Remove-ResourceLock {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroup
    )

    try {
        $locks = @(Get-AzResourceLock -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue)
        if ($locks.Count -eq 0) {
            Write-LogMessage "No resource locks found on $ResourceGroup." -Level Debug
            return $true
        }

        Write-LogMessage "Found $($locks.Count) resource lock(s) on $ResourceGroup." -Level Warning
        foreach ($lock in $locks) {
            Write-LogMessage "  Lock: $($lock.Name) ($($lock.Properties.level)) on $($lock.ResourceType)/$($lock.ResourceName)" -Level Warning
        }

        if (-not $RemoveLocks) {
            Write-LogMessage "Locks present and -RemoveLocks not specified. Aborting." -Level Error
            return $false
        }

        foreach ($lock in $locks) {
            if ($PSCmdlet.ShouldProcess($lock.Name, 'Remove resource lock')) {
                Remove-AzResourceLock -LockId $lock.LockId -Force | Out-Null
                Write-LogMessage "  Removed lock: $($lock.Name)" -Level Success
            }
        }
        return $true
    }
    catch {
        Write-LogMessage "Failed to inspect/remove locks: $($_.Exception.Message)" -Level Error
        return $false
    }
}

function Remove-ResourceIfExists {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$ResourceType,   # display label only
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [scriptblock]$GetCommand,
        [Parameter(Mandatory)] [scriptblock]$RemoveCommand
    )

    try {
        $exists = & $GetCommand
        if (-not $exists) {
            Write-LogMessage "  ${ResourceType}: $Name (not found, skipping)" -Level Debug
            return @{ Status = 'Skipped'; Type = $ResourceType; Name = $Name }
        }

        if ($PSCmdlet.ShouldProcess("$ResourceType : $Name", 'Delete')) {
            & $RemoveCommand
            Write-LogMessage "  Deleted ${ResourceType}: $Name" -Level Success
            return @{ Status = 'Deleted'; Type = $ResourceType; Name = $Name }
        } else {
            return @{ Status = 'WhatIf'; Type = $ResourceType; Name = $Name }
        }
    }
    catch {
        Write-LogMessage "  Failed to delete ${ResourceType} '$Name': $($_.Exception.Message)" -Level Error
        return @{ Status = 'Failed'; Type = $ResourceType; Name = $Name; Error = $_.Exception.Message }
    }
}

function Invoke-SelectiveTeardown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ResourceGroup,
        [Parameter(Mandatory)] [string]$VM
    )

    Write-LogMessage "Selective teardown for VM '$VM' in RG '$ResourceGroup'." -Level Info

    # Import Compute/Network modules only when needed
    foreach ($mod in 'Az.Compute','Az.Network') {
        if (-not (Get-Module -ListAvailable -Name $mod)) {
            throw "Module $mod is required for -Selective mode. Install with: Install-Module $mod"
        }
        Import-Module $mod -ErrorAction Stop
    }

    $nicName  = "$VM-nic"
    $nsgName  = "$VM-nsg"
    $pipName  = "$VM-pip"
    $vnetName = "$VM-vnet"

    $results = @()

    # Order matters: VM > NIC > (NSG, PIP) > VNet
    $results += Remove-ResourceIfExists -ResourceType 'Virtual Machine' -Name $VM `
        -GetCommand    { Get-AzVM -Name $VM -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue } `
        -RemoveCommand { Remove-AzVM -Name $VM -ResourceGroupName $ResourceGroup -Force | Out-Null }

    # The VM may have left its OS disk behind. Find any unattached disks tagged to this VM and remove them.
    try {
        $orphanDisks = @(Get-AzDisk -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "$VM*" -and (-not $_.ManagedBy) })
        foreach ($disk in $orphanDisks) {
            $results += Remove-ResourceIfExists -ResourceType 'Managed Disk' -Name $disk.Name `
                -GetCommand    { Get-AzDisk -ResourceGroupName $ResourceGroup -DiskName $disk.Name -ErrorAction SilentlyContinue } `
                -RemoveCommand { Remove-AzDisk -ResourceGroupName $ResourceGroup -DiskName $disk.Name -Force | Out-Null }
        }
    } catch {
        Write-LogMessage "Disk cleanup pass skipped: $($_.Exception.Message)" -Level Debug
    }

    $results += Remove-ResourceIfExists -ResourceType 'Network Interface' -Name $nicName `
        -GetCommand    { Get-AzNetworkInterface -Name $nicName -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue } `
        -RemoveCommand { Remove-AzNetworkInterface -Name $nicName -ResourceGroupName $ResourceGroup -Force | Out-Null }

    $results += Remove-ResourceIfExists -ResourceType 'Public IP' -Name $pipName `
        -GetCommand    { Get-AzPublicIpAddress -Name $pipName -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue } `
        -RemoveCommand { Remove-AzPublicIpAddress -Name $pipName -ResourceGroupName $ResourceGroup -Force | Out-Null }

    $results += Remove-ResourceIfExists -ResourceType 'Virtual Network' -Name $vnetName `
        -GetCommand    { Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue } `
        -RemoveCommand { Remove-AzVirtualNetwork -Name $vnetName -ResourceGroupName $ResourceGroup -Force | Out-Null }

    $results += Remove-ResourceIfExists -ResourceType 'Network Security Group' -Name $nsgName `
        -GetCommand    { Get-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue } `
        -RemoveCommand { Remove-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $ResourceGroup -Force | Out-Null }

    return $results
}

function Remove-KeyVaultWithOptionalPurge {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$VaultName,
        [Parameter(Mandatory)] [string]$ResourceGroup
    )

    if (-not (Get-Module -ListAvailable -Name Az.KeyVault)) {
        throw "Az.KeyVault module is required when -KeyVaultName is specified. Install with: Install-Module Az.KeyVault"
    }
    Import-Module Az.KeyVault -ErrorAction Stop

    $results = @()
    $vaultLocation = $null

    try {
        $vault = Get-AzKeyVault -VaultName $VaultName -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue
        if ($vault) {
            # Capture the location BEFORE deletion - we'll need it to query the soft-deleted vault later
            $vaultLocation = $vault.Location
            if ($PSCmdlet.ShouldProcess("Key Vault: $VaultName", 'Delete')) {
                Remove-AzKeyVault -VaultName $VaultName -ResourceGroupName $ResourceGroup -Force | Out-Null
                Write-LogMessage "  Deleted Key Vault: $VaultName (was in $vaultLocation)" -Level Success
                $results += @{ Status = 'Deleted'; Type = 'Key Vault'; Name = $VaultName }
            }
        } else {
            Write-LogMessage "  Key Vault: $VaultName (not found in RG, checking soft-deleted)" -Level Debug
            $results += @{ Status = 'Skipped'; Type = 'Key Vault'; Name = $VaultName }
        }
    } catch {
        Write-LogMessage "  Failed to delete Key Vault '$VaultName': $($_.Exception.Message)" -Level Error
        $results += @{ Status = 'Failed'; Type = 'Key Vault'; Name = $VaultName; Error = $_.Exception.Message }
    }

    if ($PurgeKeyVault) {
        try {
            # If we already know the location from the pre-delete query, use it directly.
            # Otherwise, fall back to listing all soft-deleted vaults in the subscription
            # and finding ours - slower but doesn't require interactive Location prompt.
            if ($vaultLocation) {
                $softDeleted = Get-AzKeyVault -VaultName $VaultName -Location $vaultLocation -InRemovedState -ErrorAction SilentlyContinue
            } else {
                $allDeleted = @(Get-AzKeyVault -InRemovedState -ErrorAction SilentlyContinue)
                $softDeleted = $allDeleted | Where-Object { $_.VaultName -eq $VaultName } | Select-Object -First 1
            }

            if ($softDeleted) {
                Write-LogMessage "  Found soft-deleted Key Vault '$VaultName' in $($softDeleted.Location)." -Level Warning
                if ($PSCmdlet.ShouldProcess("Soft-deleted Key Vault: $VaultName", 'Purge')) {
                    # Key Vault purge is a slow, multi-stage backend operation. In practice
                    # we've observed it taking anywhere from 30 seconds to 15+ minutes,
                    # especially in busy regions. The cmdlet itself doesn't time out and
                    # can appear to hang while the operation is actually progressing.
                    #
                    # Strategy: kick off the purge in a background job, then actively poll
                    # the soft-deleted vault list every 30 seconds. The vault disappearing
                    # from that list is the definitive sign the purge succeeded, regardless
                    # of whether the cmdlet has returned. We give it a generous timeout so
                    # we don't kill a legitimately slow operation.

                    $purgeTimeoutSeconds = 1200  # 20 minutes
                    $pollIntervalSeconds = 30
                    $purgeVaultLocation = $softDeleted.Location

                    Write-LogMessage "  Initiating purge (timeout: $($purgeTimeoutSeconds / 60) min, polling every ${pollIntervalSeconds}s)..." -Level Info
                    Write-LogMessage "  Note: Key Vault purge typically takes 1-15 minutes depending on region load." -Level Info

                    $purgeJob = Start-Job -ScriptBlock {
                        param($VaultName, $Location, $SubId, $TenantId)
                        Import-Module Az.KeyVault -ErrorAction Stop
                        Import-Module Az.Accounts -ErrorAction Stop
                        # Az background jobs need their own context; copy from parent token cache
                        try {
                            $null = Set-AzContext -Tenant $TenantId -SubscriptionId $SubId -ErrorAction SilentlyContinue
                        } catch { Write-Verbose "Suppressed (non-fatal): $_" }
                        Remove-AzKeyVault -VaultName $VaultName -Location $Location -InRemovedState -Force
                    } -ArgumentList $VaultName, $purgeVaultLocation, (Get-AzContext).Subscription.Id, (Get-AzContext).Tenant.Id

                    $deadline = (Get-Date).AddSeconds($purgeTimeoutSeconds)
                    $purgeSucceeded = $false
                    $elapsedSeconds = 0

                    while ((Get-Date) -lt $deadline) {
                        Start-Sleep -Seconds $pollIntervalSeconds
                        $elapsedSeconds += $pollIntervalSeconds

                        # Check if the vault is still soft-deleted
                        try {
                            $stillDeleted = Get-AzKeyVault -InRemovedState -ErrorAction SilentlyContinue |
                                            Where-Object { $_.VaultName -eq $VaultName }
                            if (-not $stillDeleted) {
                                $purgeSucceeded = $true
                                Write-LogMessage "  Purge confirmed after $([int]($elapsedSeconds / 60))m $($elapsedSeconds % 60)s (vault no longer in soft-deleted list)." -Level Success
                                break
                            }
                        } catch {
                            # Don't fail the loop on a transient polling error - keep waiting
                            Write-LogMessage "  Polling check failed (transient): $($_.Exception.Message)" -Level Debug
                        }

                        # Also check whether the background job finished with an error
                        if ($purgeJob.State -in 'Failed','Stopped') {
                            Write-LogMessage "  Purge job exited with state: $($purgeJob.State)" -Level Warning
                            break
                        }

                        Write-LogMessage "    Still purging... ($([int]($elapsedSeconds / 60))m $($elapsedSeconds % 60)s elapsed, job state: $($purgeJob.State))" -Level Info
                    }

                    # Clean up the job
                    if ($purgeJob.State -eq 'Running') {
                        Stop-Job -Job $purgeJob -ErrorAction SilentlyContinue
                    }

                    $jobError = $null
                    try {
                        Receive-Job -Job $purgeJob -ErrorAction Stop | Out-Null
                    } catch {
                        $jobError = $_.Exception.Message
                    }
                    Remove-Job -Job $purgeJob -Force -ErrorAction SilentlyContinue

                    if ($purgeSucceeded) {
                        Write-LogMessage "  Purged Key Vault: $VaultName (name now available for reuse)" -Level Success
                        $results += @{ Status = 'Purged'; Type = 'Key Vault (soft-deleted)'; Name = $VaultName }
                    } else {
                        Write-LogMessage "  Purge did not complete within $([int]($purgeTimeoutSeconds / 60)) minutes." -Level Error
                        if ($jobError) {
                            Write-LogMessage "  Background job error: $jobError" -Level Error
                        }
                        Write-LogMessage "  Common causes and remediation:" -Level Warning
                        Write-LogMessage "    Stale Az token cache: Disconnect-AzAccount; Clear-AzContext -Force; Connect-AzAccount" -Level Warning
                        Write-LogMessage "    Missing permission: caller needs Microsoft.KeyVault/locations/deletedVaults/purge/action" -Level Warning
                        Write-LogMessage "    Manual purge via portal: Key Vaults service > Manage deleted vaults > select > Purge" -Level Warning
                        $results += @{ Status = 'Failed'; Type = 'Key Vault Purge'; Name = $VaultName; Error = "Did not complete within $([int]($purgeTimeoutSeconds / 60)) min" }
                    }
                }
            } else {
                Write-LogMessage "  No soft-deleted vault named '$VaultName' to purge." -Level Debug
            }
        } catch {
            Write-LogMessage "  Failed to purge Key Vault '$VaultName': $($_.Exception.Message)" -Level Error
            Write-LogMessage "  You may lack 'Purge Soft-Deleted Vaults' permission. Tenant policy may also forbid purge." -Level Warning
            $results += @{ Status = 'Failed'; Type = 'Key Vault Purge'; Name = $VaultName; Error = $_.Exception.Message }
        }
    } else {
        Write-LogMessage "  Key Vault is soft-deleted. Use -PurgeKeyVault to free the name immediately." -Level Info
    }

    return $results
}

function Remove-LocalArtifacts {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $results = @()
    $baseDir = $PSScriptRoot
    $patterns = @(
        'erpnext-connection-info.json',
        'install-erpnext.sh',
        'Deploy-ERPNextToAzure_*.log'
    )

    foreach ($pattern in $patterns) {
        $files = @(Get-ChildItem -Path $baseDir -Filter $pattern -File -ErrorAction SilentlyContinue)
        if ($files.Count -eq 0) {
            Write-LogMessage "  No local files match '$pattern'" -Level Debug
            continue
        }
        foreach ($file in $files) {
            try {
                if ($PSCmdlet.ShouldProcess($file.FullName, 'Delete local file')) {
                    Remove-Item -Path $file.FullName -Force
                    Write-LogMessage "  Deleted local file: $($file.Name)" -Level Success
                    $results += @{ Status = 'Deleted'; Type = 'Local File'; Name = $file.Name }
                }
            } catch {
                Write-LogMessage "  Failed to delete '$($file.Name)': $($_.Exception.Message)" -Level Error
                $results += @{ Status = 'Failed'; Type = 'Local File'; Name = $file.Name; Error = $_.Exception.Message }
            }
        }
    }

    return $results
}

#endregion

#region Main

$allResults = @()
$script:softDeletedFromThisRun = @()

# When the user invokes with -Force, suppress ALL downstream confirmation
# prompts (including those from Az cmdlets like Remove-AzResourceGroup which
# show their own "Are you sure?" prompt even when -Force is passed to them).
# Setting these here means we don't have to remember -Confirm:$false on
# every individual destructive call below.
if ($Force) {
    $ConfirmPreference = 'None'
    $PSDefaultParameterValues['*:Confirm'] = $false
}

try {
    $context = Select-AzureContext -TenantId $TenantId -SubscriptionId $SubscriptionId -Interactive:$SelectContext
    if (-not $context) { exit 1 }

    # Production safety check
    if ((Test-ProductionSubscription -Context $context) -and (-not $AcknowledgeProductionRisk)) {
        Write-LogMessage "Target subscription is tagged as Production." -Level Error
        Write-LogMessage "Pass -AcknowledgeProductionRisk to proceed. Aborting." -Level Error
        exit 2
    }

    # Show plan before touching anything
    Write-Host ""
    Write-Host "TEARDOWN PLAN" -ForegroundColor Cyan
    Write-Host "  Account:            $($context.Account.Id)"
    Write-Host "  Tenant:             $($context.Tenant.Id)"
    Write-Host "  Subscription:       $($context.Subscription.Name) ($($context.Subscription.Id))"
    Write-Host "  Mode:               $(if ($Selective) { 'Selective (per-resource)' } else { 'ResourceGroup (entire RG)' })"
    Write-Host "  Resource Group:     $ResourceGroupName"
    if ($Selective) {
        Write-Host "  VM Name:            $VMName"
    }
    if ($KeyVaultName) {
        Write-Host "  Key Vault:          $KeyVaultName  (purge: $($PurgeKeyVault.IsPresent))"
    }
    if ($ExternalVNetName) {
        Write-Host "  External Subnet:    $ExternalSubnetName in $ExternalVNetName"
    }
    Write-Host "  Remove locks:       $($RemoveLocks.IsPresent)"
    Write-Host "  Local artifacts:    $($RemoveLocalArtifacts.IsPresent)"
    Write-Host "  WhatIf:             $($WhatIfPreference)"
    Write-Host ""

    # Verify RG exists
    $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $rg) {
        Write-LogMessage "Resource Group '$ResourceGroupName' not found in current subscription." -Level Warning
        Write-LogMessage "  Current context: $($context.Account.Id) -> $($context.Subscription.Name) ($($context.Subscription.Id))" -Level Info

        # Search other subscriptions this account can see, in case the RG lives elsewhere
        try {
            Write-LogMessage "Searching other accessible subscriptions for '$ResourceGroupName'..." -Level Info
            $otherSubs = @(Get-AzSubscription -ErrorAction SilentlyContinue -WarningAction SilentlyContinue |
                Where-Object { $_.Id -ne $context.Subscription.Id -and $_.State -eq 'Enabled' })

            $found = @()
            foreach ($sub in $otherSubs) {
                try {
                    $null = Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop -WhatIf:$false
                    $candidate = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
                    if ($candidate) {
                        $found += [PSCustomObject]@{ Subscription = $sub.Name; SubscriptionId = $sub.Id; Location = $candidate.Location }
                    }
                } catch {
                    Write-LogMessage "  Could not check subscription '$($sub.Name)': $($_.Exception.Message)" -Level Debug
                }
            }

            # Restore original context regardless of search outcome
            $null = Set-AzContext -SubscriptionId $context.Subscription.Id -ErrorAction SilentlyContinue -WhatIf:$false

            if ($found.Count -gt 0) {
                Write-LogMessage "Found '$ResourceGroupName' in $($found.Count) other subscription(s):" -Level Warning
                foreach ($f in $found) {
                    Write-LogMessage "  -> $($f.Subscription) ($($f.SubscriptionId))  Location: $($f.Location)" -Level Warning
                }
                Write-LogMessage "Re-run with -SubscriptionId to target the correct subscription, e.g.:" -Level Warning
                Write-LogMessage "  .\Remove-ERPNextAzureDeployment.ps1 -SubscriptionId $($found[0].SubscriptionId) ..." -Level Warning
                exit 4
            } else {
                Write-LogMessage "Resource Group not found in any accessible subscription." -Level Warning
            }
        } catch {
            Write-LogMessage "Cross-subscription search failed: $($_.Exception.Message)" -Level Debug
        }

        if (-not $RemoveLocalArtifacts) {
            exit 0
        }
        # Otherwise fall through to local artifact cleanup
    }

    # Confirmation gate (unless -Force or -WhatIf)
    if (-not $Force -and -not $WhatIfPreference) {
        $prompt = if ($Selective) {
            "This will DELETE the VM '$VMName' and its networking resources in '$ResourceGroupName'. Continue?"
        } else {
            "This will DELETE the ENTIRE Resource Group '$ResourceGroupName' and EVERYTHING in it. Continue?"
        }
        if (-not $PSCmdlet.ShouldContinue($prompt, 'Confirm teardown')) {
            Write-LogMessage "Aborted by user." -Level Warning
            exit 0
        }
    }

    # Lock handling (only meaningful if RG exists)
    if ($rg) {
        if (-not (Remove-ResourceLock -ResourceGroup $ResourceGroupName)) {
            exit 3
        }
    }

    # Execute teardown
    if ($Selective) {
        if ($rg) {
            $allResults += Invoke-SelectiveTeardown -ResourceGroup $ResourceGroupName -VM $VMName
        }

        if ($KeyVaultName) {
            $allResults += Remove-KeyVaultWithOptionalPurge -VaultName $KeyVaultName -ResourceGroup $ResourceGroupName
        }
    }
    else {
        # ResourceGroup mode
        if ($rg) {
            # If Key Vault should be purged, we have to delete it explicitly first to capture the soft-deleted reference,
            # because Remove-AzResourceGroup will not give us a chance to purge afterward.
            if ($KeyVaultName -and $PurgeKeyVault) {
                Write-LogMessage "Pre-deleting Key Vault for purge handling..." -Level Info
                $allResults += Remove-KeyVaultWithOptionalPurge -VaultName $KeyVaultName -ResourceGroup $ResourceGroupName
            }

            Write-LogMessage "Deleting Resource Group '$ResourceGroupName' (this may take several minutes)..." -Level Info
            if ($PSCmdlet.ShouldProcess("Resource Group: $ResourceGroupName", 'Delete')) {
                # Background-job runspaces don't inherit $ConfirmPreference or
                # $PSDefaultParameterValues from the parent session. If we just
                # called "Remove-AzResourceGroup -Force -Confirm:$false -AsJob",
                # the job would launch a fresh runspace where ConfirmPreference
                # is 'High' by default, the cmdlet would prompt for confirmation,
                # the prompt would have no console to talk to, and the job would
                # sit in 'Blocked' state forever.
                #
                # The fix: launch the deletion via Start-Job with an explicit
                # script block that sets ConfirmPreference INSIDE the runspace
                # before invoking the cmdlet. We also re-import Az.Resources
                # because the new runspace doesn't have our modules loaded.
                $rgJob = Start-Job -ScriptBlock {
                    param($RGName, $SubId, $TenantId)
                    $ConfirmPreference = 'None'
                    $PSDefaultParameterValues['*:Confirm'] = $false
                    Import-Module Az.Resources -ErrorAction Stop
                    Import-Module Az.Accounts -ErrorAction Stop
                    # The job runspace also has its own (empty) Az context.
                    # Set it before calling cmdlets that need authentication.
                    try {
                        $null = Set-AzContext -Tenant $TenantId -SubscriptionId $SubId -ErrorAction SilentlyContinue
                    } catch { Write-Verbose "Suppressed (non-fatal): $_" }
                    Remove-AzResourceGroup -Name $RGName -Force -Confirm:$false
                } -ArgumentList $ResourceGroupName, $context.Subscription.Id, $context.Tenant.Id

                $deadline = (Get-Date).AddMinutes($TimeoutMinutes)

                # Wait while the job is in any non-terminal state. The job starts in
                # 'NotStarted' and transitions through 'Running' to a terminal state
                # ('Completed', 'Failed', 'Stopped'). 'Blocked' would indicate the
                # job is waiting for an unanswerable prompt - the fix above prevents
                # that, but we still don't want an infinite loop, so 'Blocked' for
                # more than 2 minutes triggers an explicit failure.
                $terminalStates = @('Completed', 'Failed', 'Stopped')
                $firstBlockedAt = $null
                while ($rgJob.State -notin $terminalStates) {
                    if ((Get-Date) -gt $deadline) {
                        Write-LogMessage "RG deletion exceeded $TimeoutMinutes minute timeout." -Level Error
                        Stop-Job $rgJob
                        throw "Timeout deleting Resource Group."
                    }
                    if ($rgJob.State -eq 'Blocked') {
                        if (-not $firstBlockedAt) { $firstBlockedAt = Get-Date }
                        elseif (((Get-Date) - $firstBlockedAt).TotalMinutes -gt 2) {
                            Write-LogMessage "Job has been 'Blocked' for over 2 minutes - aborting." -Level Error
                            Write-LogMessage "This typically indicates an unanswerable confirmation prompt inside the job runspace." -Level Error
                            Write-LogMessage "Workaround: run synchronously instead:" -Level Warning
                            Write-LogMessage "  Remove-AzResourceGroup -Name '$ResourceGroupName' -Force -Confirm:`$false" -Level Warning
                            Stop-Job $rgJob
                            Remove-Job $rgJob -Force
                            throw "Background-job runspace blocked on prompt."
                        }
                    } else {
                        $firstBlockedAt = $null
                    }
                    Write-LogMessage "  RG deletion in progress... ($([int]((Get-Date) - $rgJob.PSBeginTime).TotalMinutes) min, state: $($rgJob.State))" -Level Debug
                    Start-Sleep -Seconds 30
                }

                if ($rgJob.State -eq 'Failed') {
                    $jobErrors = Receive-Job $rgJob -ErrorAction Continue 2>&1
                    Remove-Job $rgJob -Force
                    Write-LogMessage "Resource Group deletion failed:" -Level Error
                    foreach ($e in $jobErrors) {
                        Write-LogMessage "  $e" -Level Error
                    }
                    throw "Resource Group deletion failed. Check Azure activity log."
                }

                Receive-Job $rgJob | Out-Null
                Remove-Job $rgJob -Force

                # Verify the RG is actually gone before reporting success.
                # Belt-and-suspenders against any future cmdlet quirks where the job
                # reports Completed without having actually deleted anything.
                $stillThere = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
                if ($stillThere) {
                    Write-LogMessage "Job reported Completed but Resource Group still exists." -Level Error
                    throw "Resource Group deletion did not actually delete the resource group."
                }

                Write-LogMessage "Resource Group '$ResourceGroupName' deleted." -Level Success
                $allResults += @{ Status = 'Deleted'; Type = 'Resource Group'; Name = $ResourceGroupName }

                # If a Key Vault was in the deleted RG, it's now soft-deleted and the name
                # is reserved. Detect this so we can warn the user at summary time if they
                # didn't ask for a purge - prevents the surprising "why does my next deploy
                # fail with vault-name-already-exists?" question.
                if (-not $PurgeKeyVault) {
                    try {
                        $newlySoftDeleted = @(Get-AzKeyVault -InRemovedState -ErrorAction SilentlyContinue |
                            Where-Object {
                                $_.ResourceId -like "*/resourceGroups/$ResourceGroupName/*" -and
                                $_.DeletionDate -gt (Get-Date).AddMinutes(-30)
                            })
                        foreach ($v in $newlySoftDeleted) {
                            $script:softDeletedFromThisRun += $v.VaultName
                        }
                    } catch {
                        Write-LogMessage "  (Could not scan for soft-deleted vaults: $($_.Exception.Message))" -Level Debug
                    }
                }
            }
        }

        # Handle Key Vault purge if requested and not already handled above
        if ($KeyVaultName -and $PurgeKeyVault -and (-not $rg)) {
            # RG was already gone but caller may still want to purge a soft-deleted vault
            Write-LogMessage "Checking for orphaned soft-deleted Key Vault..." -Level Info
            if (-not (Get-Module -ListAvailable -Name Az.KeyVault)) {
                Write-LogMessage "Az.KeyVault not available; cannot purge." -Level Warning
            } else {
                Import-Module Az.KeyVault -ErrorAction Stop
                try {
                    # No location known here - use the list-all parameter set instead of the
                    # single-vault parameter set which would prompt for Location.
                    $allDeleted = @(Get-AzKeyVault -InRemovedState -ErrorAction SilentlyContinue)
                    $softDeleted = $allDeleted | Where-Object { $_.VaultName -eq $KeyVaultName } | Select-Object -First 1

                    if ($softDeleted -and $PSCmdlet.ShouldProcess("Soft-deleted Key Vault: $KeyVaultName", 'Purge')) {
                        Remove-AzKeyVault -VaultName $KeyVaultName -Location $softDeleted.Location -InRemovedState -Force | Out-Null
                        Write-LogMessage "Purged orphaned Key Vault: $KeyVaultName (was in $($softDeleted.Location))" -Level Success
                        $allResults += @{ Status = 'Purged'; Type = 'Key Vault (soft-deleted)'; Name = $KeyVaultName }
                    } elseif (-not $softDeleted) {
                        Write-LogMessage "No soft-deleted vault named '$KeyVaultName' found." -Level Debug
                    }
                } catch {
                    Write-LogMessage "Failed to purge orphaned vault: $($_.Exception.Message)" -Level Error
                }
            }
        }
    }

    # External-VNet subnet cleanup. When ERPNext was deployed into an existing
    # (shared) VNet via Deploy's -ExistingVNetName, the subnet lives in that
    # VNet's resource group - NOT the ERPNext RG. Resource Group deletion of
    # the ERPNext RG leaves the subnet behind. This block removes it.
    if ($ExternalVNetName) {
        Write-LogMessage "External VNet subnet cleanup: $ExternalSubnetName in $ExternalVNetName" -Level Info
        $extVnetRG = if ($ExternalVNetResourceGroup) { $ExternalVNetResourceGroup } else { $ResourceGroupName }

        try {
            $extVnet = Get-AzVirtualNetwork -Name $ExternalVNetName -ResourceGroupName $extVnetRG -ErrorAction SilentlyContinue
            if (-not $extVnet) {
                Write-LogMessage "  External VNet '$ExternalVNetName' not found in RG '$extVnetRG'. Skipping." -Level Warning
            } else {
                $targetSubnet = $extVnet.Subnets | Where-Object { $_.Name -eq $ExternalSubnetName }
                if (-not $targetSubnet) {
                    Write-LogMessage "  Subnet '$ExternalSubnetName' not found in VNet. Skipping." -Level Info
                } elseif ($targetSubnet.IpConfigurations.Count -gt 0) {
                    Write-LogMessage "  Subnet '$ExternalSubnetName' still has $($targetSubnet.IpConfigurations.Count) IP configuration(s) attached. Refusing to delete." -Level Warning
                    Write-LogMessage "  This usually means the RG deletion above didn't actually remove the NIC. Investigate before retrying." -Level Warning
                    $allResults += @{ Status = 'Failed'; Type = 'Subnet'; Name = $ExternalSubnetName; Error = 'Subnet still has IP configs attached' }
                } else {
                    if ($PSCmdlet.ShouldProcess("Subnet: $ExternalSubnetName in $ExternalVNetName", 'Delete')) {
                        Remove-AzVirtualNetworkSubnetConfig -Name $ExternalSubnetName -VirtualNetwork $extVnet | Out-Null
                        $extVnet | Set-AzVirtualNetwork | Out-Null
                        Write-LogMessage "  Removed subnet '$ExternalSubnetName' from VNet '$ExternalVNetName'." -Level Success
                        $allResults += @{ Status = 'Deleted'; Type = 'Subnet'; Name = "$ExternalVNetName/$ExternalSubnetName" }
                    }
                }
            }
        } catch {
            Write-LogMessage "  Failed to remove external subnet: $($_.Exception.Message)" -Level Error
            $allResults += @{ Status = 'Failed'; Type = 'Subnet'; Name = $ExternalSubnetName; Error = $_.Exception.Message }
        }
    }

    # Local artifact cleanup
    if ($RemoveLocalArtifacts) {
        Write-LogMessage "Cleaning up local artifacts..." -Level Info
        $allResults += Remove-LocalArtifacts
    }

    # Summary
    $deleted = @($allResults | Where-Object { $_.Status -eq 'Deleted' }).Count
    $purged  = @($allResults | Where-Object { $_.Status -eq 'Purged' }).Count
    $skipped = @($allResults | Where-Object { $_.Status -eq 'Skipped' }).Count
    $failed  = @($allResults | Where-Object { $_.Status -eq 'Failed' }).Count
    $whatif  = @($allResults | Where-Object { $_.Status -eq 'WhatIf' }).Count

    Write-Host ""
    Write-Host "===============================================================" -ForegroundColor Green
    Write-Host "  TEARDOWN COMPLETE" -ForegroundColor Green
    Write-Host "===============================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Summary:" -ForegroundColor Cyan
    Write-Host "  Deleted:           $deleted" -ForegroundColor Green
    if ($purged -gt 0) {
        Write-Host "  Purged:            $purged" -ForegroundColor Green
    }
    Write-Host "  Skipped (absent):  $skipped" -ForegroundColor DarkGray
    if ($whatif -gt 0) {
        Write-Host "  Would delete:      $whatif (WhatIf mode)" -ForegroundColor Yellow
    }
    Write-Host "  Failed:            $failed" -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'White' })
    Write-Host ""

    if ($failed -gt 0) {
        Write-Host "Failures:" -ForegroundColor Red
        foreach ($f in $allResults | Where-Object { $_.Status -eq 'Failed' }) {
            Write-Host "  - [$($f.Type)] $($f.Name): $($f.Error)" -ForegroundColor Red
        }
        Write-Host ""
    }

    Write-Host "Log: $LogFile" -ForegroundColor DarkGray
    Write-Host ""

    # Warn about soft-deleted Key Vaults that were in the deleted RG.
    # Without an explicit -PurgeKeyVault flag, the vault names are reserved
    # for 90 days and re-deploying with the same name will fail.
    if ($script:softDeletedFromThisRun.Count -gt 0) {
        Write-Host "---------------------------------------------------------------" -ForegroundColor Yellow
        Write-Host "NOTE: Soft-deleted Key Vault(s) remain" -ForegroundColor Yellow
        Write-Host "---------------------------------------------------------------" -ForegroundColor Yellow
        foreach ($vname in $script:softDeletedFromThisRun) {
            Write-Host "  $vname" -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "  These vault names are reserved for 90 days by Azure's soft-delete." -ForegroundColor Yellow
        Write-Host "  Re-deploying with the same name will fail until they are purged." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  To purge, re-run this script with:" -ForegroundColor Yellow
        $firstVault = $script:softDeletedFromThisRun[0]
        Write-Host "    .\Remove-ERPNextAzureDeployment.ps1 -Force ``" -ForegroundColor White
        Write-Host "        -KeyVaultName '$firstVault' -PurgeKeyVault" -ForegroundColor White
        Write-Host ""
        Write-Host "  Or via Azure portal: Key Vault service > Manage deleted vaults" -ForegroundColor Yellow
        Write-Host "---------------------------------------------------------------" -ForegroundColor Yellow
        Write-Host ""
    }

    return [PSCustomObject]@{
        ResourceGroup = $ResourceGroupName
        Mode          = if ($Selective) { 'Selective' } else { 'ResourceGroup' }
        Deleted       = $deleted
        Purged        = $purged
        Skipped       = $skipped
        Failed        = $failed
        Details       = $allResults
        LogFile       = $LogFile
    }
}
catch {
    Write-LogMessage "Teardown failed: $($_.Exception.Message)" -Level Error
    Write-LogMessage $_.ScriptStackTrace -Level Error
    exit 1
}

#endregion
