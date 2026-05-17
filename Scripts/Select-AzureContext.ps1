<#
.SYNOPSIS
    Lists and switches Azure contexts (tenants and subscriptions) for
    consultants working across multiple client environments.

.DESCRIPTION
    A standalone helper for managing Az PowerShell contexts when you have
    access to multiple Azure tenants and subscriptions. Common consultant
    scenarios:

        - Bouncing between client engagements during the day
        - Verifying which client environment is active before destructive work
        - Switching tenants when MFA scope has changed your default context
        - Listing all accessible subscriptions in one view

    The script:
        - Prints the current context (account, tenant, subscription)
        - Lists all enabled subscriptions across all tenants the account
          has access to
        - Switches to a specified target or offers an interactive picker
        - Can search by partial name (e.g. "client-a") rather than full GUID
        - Optionally writes the resolved context to a named context store
          for later quick switching

.PARAMETER ListOnly
    Show all accessible contexts without changing anything.

.PARAMETER SubscriptionId
    GUID of the subscription to switch to.

.PARAMETER TenantId
    GUID of the tenant to switch to. When used alone, the script picks the
    first enabled subscription in that tenant.

.PARAMETER SearchName
    Partial (case-insensitive) name match against subscription names. If
    multiple matches are found, presents a picker.

.PARAMETER SaveAs
    Save the resolved context to the named Az context store. Later, you can
    quickly restore it with: Select-AzContext -Name '<name>'

.PARAMETER Refresh
    If specified, re-authenticates the account before listing contexts.
    Useful when subscription access has changed and the local cache is stale.

.EXAMPLE
    PS> .\Select-AzureContext.ps1 -ListOnly

    Prints the current context and lists all accessible subscriptions.

.EXAMPLE
    PS> .\Select-AzureContext.ps1

    Interactive picker over all accessible subscriptions.

.EXAMPLE
    PS> .\Select-AzureContext.ps1 -SearchName 'JT Custom'

    Switches to a subscription whose name contains "JT Custom". If multiple
    match, presents a picker constrained to those matches.

.EXAMPLE
    PS> .\Select-AzureContext.ps1 -SubscriptionId 'f9c9501f-fbb3-47db-8dd8-a703d12c9c71' `
            -SaveAs 'JTCustomTrailers-Prod'

    Explicitly switch and save the context for later one-line restore.

.EXAMPLE
    PS> .\Select-AzureContext.ps1 -Refresh

    Re-authenticates and lists contexts. Use when subscription access has
    changed and the local cache shows stale results.

.NOTES
    Author:           John O'Neill Sr.
    Company:          Azure Innovators
    Create Date:      05/15/2026
    Version:          1.1.0
    GitHub:           https://github.com/JONeillSr/

    PREREQUISITES:
        - PowerShell 7.2 or later
        - Az.Accounts module
        - At least one authenticated Az context (Connect-AzAccount)

.CHANGELOG
    1.1.0 - 05/16/2026 - Multi-tenant search, location-aware messages
        - Searches all accessible tenants/subscriptions when given a name
          pattern with -SearchName, not just the active subscription
        - Actionable error output when a subscription isn't found:
          shows currently accessible tenants and suggests next steps
          (Connect-AzAccount for additional tenant, -Refresh switch, etc.)
        - Placeholder syntax in error examples uses [name] instead of
          <name> (PowerShell parses < as reserved redirection operator
          inside double-quoted strings)
        - Returns the resolved context for downstream scripts to consume

    1.0.0 - 05/15/2026 - Initial release
        - Interactive subscription picker
        - -ListOnly mode to enumerate without changing context
        - Tenant and subscription pinning via parameters

.LINK
    https://github.com/JONeillSr/

.LINK
    https://learn.microsoft.com/en-us/powershell/module/az.accounts/
#>

[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'SaveAs is used by Set-ContextAndReport via script-scope reference; PSScriptAnalyzer does not trace script-scope parameter usage from within nested functions.')]
param(
    [Parameter()]
    [switch]$ListOnly,

    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$TenantId,

    [Parameter()]
    [string]$SearchName,

    [Parameter()]
    [string]$SaveAs,

    [Parameter()]
    [switch]$Refresh
)

#Requires -Version 7.2
#Requires -Modules Az.Accounts

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-ContextTable {
    param(
        [Parameter(Mandatory)] $Subscriptions,
        [Parameter()] $CurrentSubId
    )

    Write-Host ""
    $header = ('  {0,-4} {1,-40} {2,-36} {3,-36}' -f '#', 'Subscription', 'Subscription ID', 'Tenant ID')
    Write-Host $header -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * ($header.Length - 2))) -ForegroundColor DarkGray

    for ($i = 0; $i -lt $Subscriptions.Count; $i++) {
        $s = $Subscriptions[$i]
        $marker = if ($s.Id -eq $CurrentSubId) { '*' } else { ' ' }
        $nameTrim = if ($s.Name.Length -gt 40) { $s.Name.Substring(0, 37) + '...' } else { $s.Name }
        $line = ('  {0}{1,-3} {2,-40} {3,-36} {4,-36}' -f $marker, ($i + 1), $nameTrim, $s.Id, $s.TenantId)
        if ($s.Id -eq $CurrentSubId) {
            Write-Host $line -ForegroundColor Green
        } else {
            Write-Host $line
        }
    }
    Write-Host ""
    Write-Host "  * = currently active" -ForegroundColor DarkGray
    Write-Host ""
}

function Set-ContextAndReport {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] $TargetSubscription
    )

    Set-AzContext -TenantId $TargetSubscription.TenantId -SubscriptionId $TargetSubscription.Id -ErrorAction Stop | Out-Null
    $new = Get-AzContext

    Write-Host ""
    Write-Host "Context switched:" -ForegroundColor Green
    Write-Host "  Account:        $($new.Account.Id)"
    Write-Host "  Tenant:         $($new.Tenant.Id)"
    Write-Host "  Subscription:   $($new.Subscription.Name) ($($new.Subscription.Id))"
    Write-Host ""

    if ($SaveAs) {
        try {
            Set-AzContext -Name $SaveAs -ErrorAction Stop | Out-Null
            Write-Host "Context saved as '$SaveAs'. Restore later with:" -ForegroundColor Green
            Write-Host "  Select-AzContext -Name '$SaveAs'" -ForegroundColor White
            Write-Host ""
        }
        catch {
            Write-Warning "Could not save context as '$SaveAs': $($_.Exception.Message)"
        }
    }
}

# --- Main ---

try {
    if ($Refresh) {
        Write-Host "Refreshing Azure authentication..." -ForegroundColor Cyan
        Connect-AzAccount -ErrorAction Stop | Out-Null
    }

    $current = Get-AzContext -ErrorAction Stop
    if (-not $current -or -not $current.Account) {
        throw "No active Azure context. Run Connect-AzAccount first."
    }

    Write-Host ""
    Write-Host "Current context:" -ForegroundColor Cyan
    Write-Host "  Account:        $($current.Account.Id)"
    Write-Host "  Tenant:         $($current.Tenant.Id)"
    Write-Host "  Subscription:   $($current.Subscription.Name) ($($current.Subscription.Id))"

    # Enumerate
    $allSubs = @(Get-AzSubscription -ErrorAction SilentlyContinue -WarningAction SilentlyContinue |
                 Where-Object { $_.State -eq 'Enabled' } |
                 Sort-Object -Property @{Expression='TenantId'},@{Expression='Name'})

    if ($allSubs.Count -eq 0) {
        Write-Warning "No enabled subscriptions accessible to this account."
        return
    }

    # List-only path
    if ($ListOnly) {
        Write-ContextTable -Subscriptions $allSubs -CurrentSubId $current.Subscription.Id

        if ($allSubs.Count -eq 1) {
            Write-Host "Only one subscription visible to this account." -ForegroundColor DarkGray
            Write-Host "To access other tenants/subscriptions, authenticate with another account:" -ForegroundColor DarkGray
            Write-Host ""
            Write-Host "  Connect-AzAccount                            # add another account" -ForegroundColor White
            Write-Host "  Connect-AzAccount -TenantId '[tenant-id]'    # sign in to a specific tenant" -ForegroundColor White
            Write-Host "  .\Select-AzureContext.ps1 -Refresh           # re-authenticate and re-list" -ForegroundColor White
            Write-Host ""
        }
        return
    }

    # Direct GUID path
    if ($SubscriptionId) {
        $target = $allSubs | Where-Object { $_.Id -eq $SubscriptionId } | Select-Object -First 1
        if (-not $target) {
            throw "Subscription ID $SubscriptionId not found in accessible subscriptions."
        }
        Set-ContextAndReport -TargetSubscription $target
        return
    }

    # Tenant-only path
    if ($TenantId -and -not $SubscriptionId) {
        $hits = @($allSubs | Where-Object { $_.TenantId -eq $TenantId })
        if ($hits.Count -eq 0) {
            Write-Host ""
            Write-Host "No accessible subscriptions in tenant $TenantId." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "The currently authenticated account ($($current.Account.Id)) does not have" -ForegroundColor DarkGray
            Write-Host "access to that tenant. To gain access, authenticate to it:" -ForegroundColor DarkGray
            Write-Host ""
            Write-Host "  Connect-AzAccount -TenantId '$TenantId'" -ForegroundColor White
            Write-Host ""
            exit 1
        }
        if ($hits.Count -eq 1) {
            Set-ContextAndReport -TargetSubscription $hits[0]
            return
        }
        $allSubs = $hits
    }

    # Search-by-name path
    if ($SearchName) {
        $hits = @($allSubs | Where-Object { $_.Name -like "*$SearchName*" })
        if ($hits.Count -eq 0) {
            Write-Host ""
            Write-Host "No accessible subscriptions match name pattern '$SearchName'." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "The currently authenticated account ($($current.Account.Id))" -ForegroundColor DarkGray
            Write-Host "can see $($allSubs.Count) subscription(s) across $(@($allSubs | Select-Object -ExpandProperty TenantId -Unique).Count) tenant(s)." -ForegroundColor DarkGray
            Write-Host ""
            Write-Host "If you expected to find a subscription in a different tenant, you need to" -ForegroundColor Cyan
            Write-Host "authenticate the account that has access to that tenant. Try one of:" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "  # Add a second account to this session (keeps current account too)" -ForegroundColor White
            Write-Host "  Connect-AzAccount" -ForegroundColor White
            Write-Host ""
            Write-Host "  # Or use the -Refresh switch to re-authenticate" -ForegroundColor White
            Write-Host "  .\Select-AzureContext.ps1 -Refresh" -ForegroundColor White
            Write-Host ""
            Write-Host "  # Or sign in to a specific tenant directly" -ForegroundColor White
            Write-Host "  Connect-AzAccount -TenantId '[tenant-id-or-domain]'" -ForegroundColor White
            Write-Host ""
            exit 1
        }
        if ($hits.Count -eq 1) {
            Set-ContextAndReport -TargetSubscription $hits[0]
            return
        }
        $allSubs = $hits
        Write-Host ""
        Write-Host "$($hits.Count) subscriptions match '$SearchName':" -ForegroundColor Cyan
    }

    # Interactive picker
    Write-ContextTable -Subscriptions $allSubs -CurrentSubId $current.Subscription.Id

    do {
        $choice = Read-Host "Select subscription (1-$($allSubs.Count)) or press Enter to keep current"
        if ([string]::IsNullOrWhiteSpace($choice)) {
            Write-Host "Keeping current context." -ForegroundColor DarkGray
            return
        }
    } until ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $allSubs.Count)

    Set-ContextAndReport -TargetSubscription $allSubs[[int]$choice - 1]
}
catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
