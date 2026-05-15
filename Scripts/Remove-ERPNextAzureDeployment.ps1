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
    subscription is used.

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

.INPUTS
    None.

.OUTPUTS
    System.Management.Automation.PSCustomObject

    Returns a summary of what was deleted, skipped, or failed.

.NOTES
    Author:           John O'Neill Sr.
    Company:          Azure Innovators
    Create Date:      05/15/2026
    Version:          1.0.0
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
    1.0.0 - 05/15/2026 - Initial release
        - ResourceGroup and Selective teardown modes
        - Resource lock detection and optional removal
        - Key Vault soft-delete handling and purge support
        - Local artifact cleanup
        - Production subscription safety check
        - WhatIf/Confirm support
        - Structured logging

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
    [int]$TimeoutMinutes = 30
)

#Requires -Version 7.2
#Requires -Modules Az.Accounts, Az.Resources

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptVersion = "1.0.0"
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
        [Parameter(Mandatory)] [string]$Message,
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
    try { Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue } catch { }
}

function Test-AzureConnection {
    try {
        $context = Get-AzContext -ErrorAction Stop
        if (-not $context -or -not $context.Account) { throw "No active Azure context." }

        if ($SubscriptionId -and $context.Subscription.Id -ne $SubscriptionId) {
            Write-LogMessage "Switching subscription to: $SubscriptionId" -Level Info
            Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
            $context = Get-AzContext
        }

        Write-LogMessage "Connected as: $($context.Account.Id)" -Level Success
        Write-LogMessage "Subscription:  $($context.Subscription.Name) ($($context.Subscription.Id))" -Level Info
        return $context
    }
    catch {
        Write-LogMessage "Not connected to Azure: $($_.Exception.Message)" -Level Error
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
    [CmdletBinding()]
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
    [CmdletBinding()]
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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$VaultName,
        [Parameter(Mandatory)] [string]$ResourceGroup
    )

    if (-not (Get-Module -ListAvailable -Name Az.KeyVault)) {
        throw "Az.KeyVault module is required when -KeyVaultName is specified. Install with: Install-Module Az.KeyVault"
    }
    Import-Module Az.KeyVault -ErrorAction Stop

    $results = @()

    try {
        $vault = Get-AzKeyVault -VaultName $VaultName -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue
        if ($vault) {
            if ($PSCmdlet.ShouldProcess("Key Vault: $VaultName", 'Delete')) {
                Remove-AzKeyVault -VaultName $VaultName -ResourceGroupName $ResourceGroup -Force | Out-Null
                Write-LogMessage "  Deleted Key Vault: $VaultName" -Level Success
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
            $softDeleted = Get-AzKeyVault -VaultName $VaultName -InRemovedState -ErrorAction SilentlyContinue
            if ($softDeleted) {
                Write-LogMessage "  Found soft-deleted Key Vault '$VaultName' in $($softDeleted.Location)." -Level Warning
                if ($PSCmdlet.ShouldProcess("Soft-deleted Key Vault: $VaultName", 'Purge')) {
                    Remove-AzKeyVault -VaultName $VaultName -Location $softDeleted.Location -InRemovedState -Force | Out-Null
                    Write-LogMessage "  Purged Key Vault: $VaultName (name now available for reuse)" -Level Success
                    $results += @{ Status = 'Purged'; Type = 'Key Vault (soft-deleted)'; Name = $VaultName }
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
    [CmdletBinding()]
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

try {
    $context = Test-AzureConnection
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
    Write-Host "  Mode:               $(if ($Selective) { 'Selective (per-resource)' } else { 'ResourceGroup (entire RG)' })"
    Write-Host "  Resource Group:     $ResourceGroupName"
    if ($Selective) {
        Write-Host "  VM Name:            $VMName"
    }
    if ($KeyVaultName) {
        Write-Host "  Key Vault:          $KeyVaultName  (purge: $($PurgeKeyVault.IsPresent))"
    }
    Write-Host "  Remove locks:       $($RemoveLocks.IsPresent)"
    Write-Host "  Local artifacts:    $($RemoveLocalArtifacts.IsPresent)"
    Write-Host "  WhatIf:             $($WhatIfPreference)"
    Write-Host ""

    # Verify RG exists
    $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $rg -and -not $RemoveLocalArtifacts) {
        Write-LogMessage "Resource Group '$ResourceGroupName' not found. Nothing to do." -Level Warning
        if ($RemoveLocalArtifacts) {
            # Fall through to clean up local files even if cloud RG is gone
        } else {
            exit 0
        }
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
                $rgJob = Remove-AzResourceGroup -Name $ResourceGroupName -Force -AsJob
                $deadline = (Get-Date).AddMinutes($TimeoutMinutes)

                while ($rgJob.State -eq 'Running') {
                    if ((Get-Date) -gt $deadline) {
                        Write-LogMessage "RG deletion exceeded $TimeoutMinutes minute timeout." -Level Error
                        Stop-Job $rgJob
                        throw "Timeout deleting Resource Group."
                    }
                    Write-LogMessage "  RG deletion in progress... ($([int]((Get-Date) - $rgJob.PSBeginTime).TotalMinutes) min)" -Level Debug
                    Start-Sleep -Seconds 30
                }

                Receive-Job $rgJob | Out-Null
                Remove-Job $rgJob -Force

                Write-LogMessage "Resource Group '$ResourceGroupName' deleted." -Level Success
                $allResults += @{ Status = 'Deleted'; Type = 'Resource Group'; Name = $ResourceGroupName }
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
                    $softDeleted = Get-AzKeyVault -VaultName $KeyVaultName -InRemovedState -ErrorAction SilentlyContinue
                    if ($softDeleted -and $PSCmdlet.ShouldProcess("Soft-deleted Key Vault: $KeyVaultName", 'Purge')) {
                        Remove-AzKeyVault -VaultName $KeyVaultName -Location $softDeleted.Location -InRemovedState -Force | Out-Null
                        Write-LogMessage "Purged orphaned Key Vault: $KeyVaultName" -Level Success
                        $allResults += @{ Status = 'Purged'; Type = 'Key Vault (soft-deleted)'; Name = $KeyVaultName }
                    }
                } catch {
                    Write-LogMessage "Failed to purge orphaned vault: $($_.Exception.Message)" -Level Error
                }
            }
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
