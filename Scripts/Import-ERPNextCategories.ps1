<#
.SYNOPSIS
    Imports WooCommerce product categories from Excel into ERPNext as Item Groups.

.DESCRIPTION
    Reads a WooCommerce category export (ProductCategories.xlsx) and creates the
    complete category hierarchy in ERPNext as Item Groups via the REST API.

    Key behaviors:
        - Preserves parent-child relationships across the full tree
        - Determines is_group from actual presence of children (not depth heuristic)
        - Idempotent: skips Item Groups that already exist
        - Dry-run mode prints the plan without making changes
        - Throttles requests with a configurable delay
        - Compatible with PowerShell 7 exception model (HttpResponseException)

.PARAMETER ProductCategoriesPath
    Path to the ProductCategories.xlsx file. Each worksheet is processed as a
    flat list of category rows with columns: term_id, name, slug, description,
    parent, full_path.

.PARAMETER ERPNextURL
    Base URL of your ERPNext installation. Examples:
        http://20.85.123.45
        https://erp.azureinnovators.com

.PARAMETER APIKey
    ERPNext API Key. Generate via: User Account > API Access > Generate Keys.

.PARAMETER APISecret
    ERPNext API Secret returned alongside the API Key. Save this immediately;
    ERPNext only displays it once at generation time.

.PARAMETER DryRun
    Print the import plan without making any changes. Useful before a real run
    against production.

.PARAMETER ThrottleMilliseconds
    Delay between API calls in milliseconds. Default: 100. Increase if you see
    rate-limiting (HTTP 429) responses.

.PARAMETER SkipSSLValidation
    Skip TLS certificate validation. Use only for development/lab environments
    with self-signed certificates. Default: disabled.

.EXAMPLE
    PS> .\Import-ERPNextCategories.ps1 `
            -ProductCategoriesPath .\ProductCategories.xlsx `
            -ERPNextURL http://20.85.123.45 `
            -APIKey abc123 -APISecret xyz789

    Imports categories with default settings.

.EXAMPLE
    PS> .\Import-ERPNextCategories.ps1 `
            -ProductCategoriesPath .\ProductCategories.xlsx `
            -ERPNextURL http://20.85.123.45 `
            -APIKey abc123 -APISecret xyz789 -DryRun

    Shows what would be created without making changes.

.INPUTS
    None.

.OUTPUTS
    System.Management.Automation.PSCustomObject

    Returns a summary object with Created, Skipped, and Failed counts.

.NOTES
    Author:           John O'Neill Sr.
    Company:          Azure Innovators
    Create Date:      02/17/2026
    Version:          1.1.0
    Last Modified:    05/15/2026
    GitHub:           https://github.com/JONeillSr/

    PREREQUISITES:
        - PowerShell 7.2 or later
        - ImportExcel module (Install-Module -Name ImportExcel)
        - A reachable ERPNext instance with API access enabled
        - A user account with rights to create Item Groups

    INPUT FILE FORMAT:
        Each worksheet should contain rows with the following columns:
            term_id      - WooCommerce term ID (numeric)
            name         - Display name of the category
            slug         - URL slug
            description  - Optional category description
            parent       - term_id of the parent category, or 0 for root
            full_path    - Human-readable breadcrumb path (e.g., "Parts > Lights")

.CHANGELOG
    1.1.0 - 05/15/2026 - Reliability and correctness improvements
        - is_group now derived from actual presence of children
        - PS7-compatible exception handling for 404 (HttpResponseException)
        - StrictMode-safe property access throughout
        - Added ThrottleMilliseconds and SkipSSLValidation parameters
        - Added retry-on-transient-error for API calls
        - Returns a structured summary object
        - Added structured file-based logging
        - Expanded inline help

    1.0.0 - 02/17/2026 - Initial release
        - Parse ProductCategories.xlsx hierarchy
        - Create ERPNext Item Groups via REST API
        - Maintain parent-child relationships
        - Dry-run mode for testing
        - Progress reporting and error handling

.LINK
    https://github.com/JONeillSr/

.LINK
    https://docs.erpnext.com/docs/user/manual/en/stock/item-group
#>

[CmdletBinding(SupportsShouldProcess)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'These script-scope parameters (APIKey, APISecret, SkipSSLValidation) are used by Invoke-ERPNextAPI via script-scope reference; PSScriptAnalyzer does not trace script-scope parameter usage from within nested functions.')]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ProductCategoriesPath,

    [Parameter(Mandatory)]
    [ValidatePattern('^https?://.+')]
    [string]$ERPNextURL,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$APIKey,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$APISecret,

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [ValidateRange(0, 5000)]
    [int]$ThrottleMilliseconds = 100,

    [Parameter()]
    [switch]$SkipSSLValidation
)

#Requires -Version 7.2
#Requires -Modules ImportExcel

# Strict mode but be deliberate about property access
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Trim trailing slash from URL
$ERPNextURL = $ERPNextURL.TrimEnd('/')

$ScriptVersion = "1.1.0"
$LogFile = Join-Path $PSScriptRoot "Import-ERPNextCategories_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host "  ERPNext Category Import Script v$ScriptVersion" -ForegroundColor Cyan
Write-Host "  JT Custom Trailers" -ForegroundColor Cyan
Write-Host "  Log: $LogFile" -ForegroundColor DarkGray
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host ""

if ($DryRun) {
    Write-Host "  DRY RUN MODE - No changes will be made" -ForegroundColor Yellow
    Write-Host ""
}

#region Helper Functions

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

    try { Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue } catch { Write-Verbose "Suppressed (non-fatal): $_" }
}

function Get-PropertyOrDefault {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$InputObject,
        [Parameter(Mandatory)] [string]$PropertyName,
        [Parameter()] $Default = $null
    )

    # StrictMode-safe property access on PSCustomObject
    if ($null -eq $InputObject) { return $Default }
    if ($InputObject.PSObject.Properties.Name -contains $PropertyName) {
        $val = $InputObject.$PropertyName
        if ($null -ne $val -and -not [string]::IsNullOrWhiteSpace([string]$val)) {
            return $val
        }
    }
    return $Default
}

function Invoke-ERPNextAPI {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Endpoint,
        [Parameter()] [ValidateSet('GET','POST','PUT','DELETE')] [string]$Method = 'GET',
        [Parameter()] [hashtable]$Body,
        [Parameter()] [int]$MaxRetries = 3
    )

    $uri = "$ERPNextURL$Endpoint"
    $headers = @{
        'Authorization' = "token $APIKey`:$APISecret"
        'Content-Type'  = 'application/json'
        'Accept'        = 'application/json'
    }

    $params = @{
        Uri               = $uri
        Method            = $Method
        Headers           = $headers
        UseBasicParsing   = $true
        SkipHttpErrorCheck = $false
    }
    if ($SkipSSLValidation) { $params['SkipCertificateCheck'] = $true }
    if ($Body) { $params['Body'] = ($Body | ConvertTo-Json -Depth 10 -Compress) }

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return Invoke-RestMethod @params
        }
        catch {
            $statusCode = $null

            # PowerShell 7 throws Microsoft.PowerShell.Commands.HttpResponseException
            if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            } elseif ($_.Exception.PSObject.Properties.Name -contains 'StatusCode') {
                $statusCode = [int]$_.Exception.StatusCode
            }

            # Don't retry on 4xx (except 429)
            if ($statusCode -and $statusCode -ge 400 -and $statusCode -lt 500 -and $statusCode -ne 429) {
                throw
            }

            if ($attempt -ge $MaxRetries) {
                Write-LogMessage "API call failed after $MaxRetries attempts: $uri" -Level Error
                throw
            }

            $backoff = [int][Math]::Pow(2, $attempt) * 500
            Write-LogMessage "  Transient error (status=$statusCode), retry $attempt/$MaxRetries in ${backoff}ms..." -Level Debug
            Start-Sleep -Milliseconds $backoff
        }
    }
}

function Test-ERPNextConnection {
    try {
        Write-LogMessage "Testing connection to ERPNext..." -Level Info
        $response = Invoke-ERPNextAPI -Endpoint "/api/method/frappe.auth.get_logged_user"
        $user = Get-PropertyOrDefault -InputObject $response -PropertyName 'message' -Default 'unknown'
        Write-LogMessage "Connected to ERPNext as: $user" -Level Success
        return $true
    }
    catch {
        Write-LogMessage "Failed to connect to ERPNext: $($_.Exception.Message)" -Level Error
        return $false
    }
}

function Get-ERPNextItemGroup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Name
    )

    try {
        Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
        $encodedName = [System.Web.HttpUtility]::UrlEncode($Name)
        $endpoint = "/api/resource/Item Group/$encodedName"
        $response = Invoke-ERPNextAPI -Endpoint $endpoint
        return Get-PropertyOrDefault -InputObject $response -PropertyName 'data' -Default $null
    }
    catch {
        # PS7: HttpResponseException carries the status code on .Response.StatusCode
        $statusCode = $null
        if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        if ($statusCode -eq 404) {
            return $null
        }
        throw
    }
}

function New-ERPNextItemGroup {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [hashtable]$ItemGroup
    )

    if ($DryRun) {
        $parentInfo = if ($ItemGroup.ContainsKey('parent_item_group')) { $ItemGroup['parent_item_group'] } else { '(none)' }
        $isGroupInfo = if ($ItemGroup.ContainsKey('is_group')) { $ItemGroup['is_group'] } else { 0 }
        Write-LogMessage "  [DRY RUN] Would create: $($ItemGroup['item_group_name'])  parent=$parentInfo  is_group=$isGroupInfo" -Level Warning
        return @{ name = $ItemGroup['item_group_name'] }
    }

    try {
        $endpoint = "/api/resource/Item Group"
        $response = Invoke-ERPNextAPI -Endpoint $endpoint -Method POST -Body $ItemGroup
        Write-LogMessage "  Created: $($ItemGroup['item_group_name'])" -Level Success
        return Get-PropertyOrDefault -InputObject $response -PropertyName 'data' -Default $null
    }
    catch {
        Write-LogMessage "  Failed to create: $($ItemGroup['item_group_name']) - $($_.Exception.Message)" -Level Error
        throw
    }
}

#endregion

#region Main Logic

try {
    if (-not (Test-ERPNextConnection)) { exit 1 }

    Write-LogMessage "Loading $ProductCategoriesPath..." -Level Info

    $excel = Open-ExcelPackage -Path $ProductCategoriesPath
    $sheetNames = @($excel.Workbook.Worksheets | Select-Object -ExpandProperty Name)
    Close-ExcelPackage $excel

    Write-LogMessage "Found $($sheetNames.Count) worksheet(s)." -Level Info

    $allCategories = New-Object System.Collections.Generic.List[object]
    $categoryCount = 0

    foreach ($sheetName in $sheetNames) {
        Write-LogMessage "Processing sheet: $sheetName" -Level Info
        $rows = @(Import-Excel -Path $ProductCategoriesPath -WorksheetName $sheetName)
        foreach ($row in $rows) {
            $name = Get-PropertyOrDefault -InputObject $row -PropertyName 'name'
            if (-not $name) { continue }

            $termId   = Get-PropertyOrDefault -InputObject $row -PropertyName 'term_id'
            $parentId = Get-PropertyOrDefault -InputObject $row -PropertyName 'parent' -Default 0
            $fullPath = Get-PropertyOrDefault -InputObject $row -PropertyName 'full_path' -Default $name
            $description = Get-PropertyOrDefault -InputObject $row -PropertyName 'description'
            $slug = Get-PropertyOrDefault -InputObject $row -PropertyName 'slug'

            $level = ($fullPath -split ' > ').Count - 1

            $allCategories.Add([PSCustomObject]@{
                term_id      = $termId
                name         = $name
                slug         = $slug
                description  = $description
                parent_id    = $parentId
                parent_name  = $null
                full_path    = $fullPath
                level        = $level
            }) | Out-Null

            $categoryCount++
        }
    }

    Write-LogMessage "Loaded $categoryCount total categories." -Level Success

    # Build term_id -> category lookup
    Write-LogMessage "Resolving parent relationships..." -Level Info
    $categoryByTermId = @{}
    foreach ($cat in $allCategories) {
        if ($cat.term_id) {
            $categoryByTermId[[string]$cat.term_id] = $cat
        }
    }

    # Resolve parent names
    foreach ($cat in $allCategories) {
        if ($cat.parent_id -and ([string]$cat.parent_id) -ne '0') {
            $parent = $categoryByTermId[[string]$cat.parent_id]
            if ($parent) { $cat.parent_name = $parent.name }
        }
    }

    # Determine is_group from actual presence of children
    $childCounts = @{}
    foreach ($cat in $allCategories) {
        if ($cat.parent_id -and ([string]$cat.parent_id) -ne '0') {
            $key = [string]$cat.parent_id
            if (-not $childCounts.ContainsKey($key)) { $childCounts[$key] = 0 }
            $childCounts[$key]++
        }
    }

    foreach ($cat in $allCategories) {
        $key = [string]$cat.term_id
        $isGroup = if ($childCounts.ContainsKey($key) -and $childCounts[$key] -gt 0) { 1 } else { 0 }
        $cat | Add-Member -NotePropertyName 'is_group' -NotePropertyValue $isGroup -Force
    }

    # Sort: parents before children (by level, then name for stability)
    $sortedCategories = $allCategories | Sort-Object -Property level, name

    Write-LogMessage "Creating Item Groups in ERPNext..." -Level Info
    Write-Host ""

    $created = 0
    $skipped = 0
    $failed  = 0

    foreach ($category in $sortedCategories) {
        try {
            $existing = Get-ERPNextItemGroup -Name $category.name
            if ($existing) {
                Write-LogMessage "  Skipped (exists): $($category.name)" -Level Warning
                $skipped++
                continue
            }

            $parentName = if ($category.parent_name) { $category.parent_name } else { 'All Item Groups' }

            $itemGroup = @{
                doctype           = 'Item Group'
                item_group_name   = $category.name
                parent_item_group = $parentName
                is_group          = $category.is_group
            }

            if ($category.description) { $itemGroup['description'] = $category.description }

            if ($PSCmdlet.ShouldProcess($category.name, 'Create Item Group')) {
                New-ERPNextItemGroup -ItemGroup $itemGroup | Out-Null
                $created++
            }

            if ($ThrottleMilliseconds -gt 0) {
                Start-Sleep -Milliseconds $ThrottleMilliseconds
            }
        }
        catch {
            Write-LogMessage "  Error processing $($category.name): $($_.Exception.Message)" -Level Error
            $failed++
        }
    }

    Write-Host ""
    Write-Host "===============================================================" -ForegroundColor Green
    Write-Host "  Import Complete" -ForegroundColor Green
    Write-Host "===============================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Summary:" -ForegroundColor Cyan
    Write-Host "  Total Categories:  $categoryCount"
    Write-Host "  Created:           $created" -ForegroundColor Green
    Write-Host "  Skipped (exist):   $skipped" -ForegroundColor Yellow
    Write-Host "  Failed:            $failed" -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'White' })
    Write-Host ""
    Write-Host "Log: $LogFile" -ForegroundColor DarkGray
    Write-Host ""

    return [PSCustomObject]@{
        TotalCategories = $categoryCount
        Created         = $created
        Skipped         = $skipped
        Failed          = $failed
        DryRun          = $DryRun.IsPresent
        LogFile         = $LogFile
    }
}
catch {
    Write-LogMessage "Script failed: $($_.Exception.Message)" -Level Error
    Write-LogMessage $_.ScriptStackTrace -Level Error
    exit 1
}

#endregion
