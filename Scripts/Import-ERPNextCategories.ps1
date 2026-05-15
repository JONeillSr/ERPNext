<#
.SYNOPSIS
    Imports WooCommerce product categories from Excel into ERPNext Item Groups.

.DESCRIPTION
    This script reads the ProductCategories.xlsx file and creates the complete
    category hierarchy in ERPNext as Item Groups. It maintains parent-child
    relationships and includes all metadata.

.PARAMETER ProductCategoriesPath
    Path to the ProductCategories.xlsx file

.PARAMETER ERPNextURL
    Base URL of your ERPNext installation (e.g., http://your-erpnext-ip)

.PARAMETER APIKey
    ERPNext API Key for authentication

.PARAMETER APISecret
    ERPNext API Secret for authentication

.PARAMETER DryRun
    If specified, shows what would be created without actually creating it

.EXAMPLE
    .\Import-ERPNextCategories.ps1 -ProductCategoriesPath ".\ProductCategories.xlsx" -ERPNextURL "http://20.85.123.45" -APIKey "abc123" -APISecret "xyz789"

.EXAMPLE
    .\Import-ERPNextCategories.ps1 -ProductCategoriesPath ".\ProductCategories.xlsx" -ERPNextURL "http://20.85.123.45" -APIKey "abc123" -APISecret "xyz789" -DryRun

.NOTES
    Author: John O'Neill Sr.
    Company: Azure Innovators
    Create Date: 02/17/2026
    Version: 1.0.0
    Change Date: 
    Change Purpose:

.CHANGELOG
    1.0.0 - 02/17/2026 - Initial release
        - Parse ProductCategories.xlsx hierarchy
        - Create ERPNext Item Groups via REST API
        - Maintain parent-child relationships
        - Dry-run mode for testing
        - Progress reporting and error handling
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ })]
    [string]$ProductCategoriesPath,
    
    [Parameter(Mandatory)]
    [string]$ERPNextURL,
    
    [Parameter(Mandatory)]
    [string]$APIKey,
    
    [Parameter(Mandatory)]
    [string]$APISecret,
    
    [Parameter()]
    [switch]$DryRun
)

#Requires -Modules ImportExcel

# Set strict mode
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Script configuration
$ScriptVersion = "1.0.0"

Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  ERPNext Category Import Script v$ScriptVersion" -ForegroundColor Cyan
Write-Host "  JT Custom Trailers" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

if ($DryRun) {
    Write-Host "  DRY RUN MODE - No changes will be made" -ForegroundColor Yellow
    Write-Host ""
}

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

function Invoke-ERPNextAPI {
    param(
        [Parameter(Mandatory)]
        [string]$Endpoint,
        
        [Parameter()]
        [ValidateSet('GET', 'POST', 'PUT', 'DELETE')]
        [string]$Method = 'GET',
        
        [Parameter()]
        [hashtable]$Body
    )
    
    $uri = "$ERPNextURL$Endpoint"
    
    $headers = @{
        'Authorization' = "token $APIKey`:$APISecret"
        'Content-Type'  = 'application/json'
        'Accept'        = 'application/json'
    }
    
    $params = @{
        Uri     = $uri
        Method  = $Method
        Headers = $headers
    }
    
    if ($Body) {
        $params['Body'] = ($Body | ConvertTo-Json -Depth 10)
    }
    
    try {
        $response = Invoke-RestMethod @params
        return $response
    }
    catch {
        Write-LogMessage "API Error: $($_.Exception.Message)" -Level Error
        Write-LogMessage "URI: $uri" -Level Error
        if ($_.ErrorDetails) {
            Write-LogMessage "Details: $($_.ErrorDetails.Message)" -Level Error
        }
        throw
    }
}

function Test-ERPNextConnection {
    try {
        Write-LogMessage "Testing connection to ERPNext..." -Level Info
        $response = Invoke-ERPNextAPI -Endpoint "/api/method/frappe.auth.get_logged_user"
        Write-LogMessage "Connected to ERPNext as: $($response.message)" -Level Success
        return $true
    }
    catch {
        Write-LogMessage "Failed to connect to ERPNext" -Level Error
        return $false
    }
}

function Get-ERPNextItemGroup {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )
    
    try {
        $endpoint = "/api/resource/Item Group/$([System.Web.HttpUtility]::UrlEncode($Name))"
        $response = Invoke-ERPNextAPI -Endpoint $endpoint
        return $response.data
    }
    catch {
        if ($_.Exception.Response.StatusCode -eq 404) {
            return $null
        }
        throw
    }
}

function New-ERPNextItemGroup {
    param(
        [Parameter(Mandatory)]
        [hashtable]$ItemGroup
    )
    
    if ($DryRun) {
        Write-LogMessage "  [DRY RUN] Would create: $($ItemGroup.item_group_name)" -Level Warning
        return @{ name = $ItemGroup.item_group_name }
    }
    
    try {
        $endpoint = "/api/resource/Item Group"
        $response = Invoke-ERPNextAPI -Endpoint $endpoint -Method POST -Body $ItemGroup
        Write-LogMessage "  Created: $($ItemGroup.item_group_name)" -Level Success
        return $response.data
    }
    catch {
        Write-LogMessage "  Failed to create: $($ItemGroup.item_group_name)" -Level Error
        throw
    }
}

#endregion

#region Main Script Logic

try {
    # Test connection
    if (-not (Test-ERPNextConnection)) {
        exit 1
    }
    
    # Load Excel file
    Write-LogMessage "Loading ProductCategories.xlsx..." -Level Info
    
    # Get all sheet names
    $excel = Open-ExcelPackage -Path $ProductCategoriesPath
    $sheetNames = $excel.Workbook.Worksheets | Select-Object -ExpandProperty Name
    Close-ExcelPackage $excel
    
    Write-LogMessage "Found $($sheetNames.Count) category sheets" -Level Info
    
    # Process each sheet to build category hierarchy
    $allCategories = @()
    $categoryCount = 0
    
    foreach ($sheetName in $sheetNames) {
        Write-LogMessage "Processing sheet: $sheetName" -Level Info
        
        # Import data from sheet
        $categories = Import-Excel -Path $ProductCategoriesPath -WorksheetName $sheetName
        
        foreach ($category in $categories) {
            if ($category.name) {
                $categoryCount++
                
                $categoryObj = [PSCustomObject]@{
                    term_id       = $category.term_id
                    name          = $category.name
                    slug          = $category.slug
                    description   = $category.description
                    parent_id     = $category.parent
                    parent_name   = $null  # Will be resolved later
                    full_path     = $category.full_path
                    level         = ($category.full_path -split ' > ').Count - 1
                }
                
                $allCategories += $categoryObj
            }
        }
    }
    
    Write-LogMessage "Loaded $categoryCount total categories" -Level Success
    
    # Build parent name lookup
    Write-LogMessage "Building parent relationships..." -Level Info
    $categoryLookup = @{}
    foreach ($cat in $allCategories) {
        $categoryLookup[$cat.term_id] = $cat
    }
    
    # Resolve parent names
    foreach ($cat in $allCategories) {
        if ($cat.parent_id -and $cat.parent_id -ne 0) {
            $parent = $categoryLookup[$cat.parent_id]
            if ($parent) {
                $cat.parent_name = $parent.name
            }
        }
    }
    
    # Sort by level (parents before children)
    $sortedCategories = $allCategories | Sort-Object -Property level, term_id
    
    Write-LogMessage "Creating Item Groups in ERPNext..." -Level Info
    Write-Host ""
    
    $created = 0
    $skipped = 0
    $failed = 0
    
    foreach ($category in $sortedCategories) {
        try {
            # Check if already exists
            $existing = Get-ERPNextItemGroup -Name $category.name
            
            if ($existing) {
                Write-LogMessage "  Skipped (exists): $($category.name)" -Level Warning
                $skipped++
                continue
            }
            
            # Prepare Item Group data
            $itemGroup = @{
                doctype         = "Item Group"
                item_group_name = $category.name
                parent_item_group = if ($category.parent_name) { $category.parent_name } else { "All Item Groups" }
                is_group        = if ($category.level -lt 2) { 1 } else { 0 }
            }
            
            # Add description if available
            if ($category.description) {
                $itemGroup['description'] = $category.description
            }
            
            # Create the item group
            $result = New-ERPNextItemGroup -ItemGroup $itemGroup
            $created++
            
            # Add a small delay to avoid overwhelming the API
            Start-Sleep -Milliseconds 100
        }
        catch {
            Write-LogMessage "  Error processing: $($category.name) - $($_.Exception.Message)" -Level Error
            $failed++
        }
    }
    
    # Summary
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "  Import Complete!" -ForegroundColor Green
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host ""
    Write-Host "Summary:" -ForegroundColor Cyan
    Write-Host "  Total Categories:  $categoryCount"
    Write-Host "  Created:           $created" -ForegroundColor Green
    Write-Host "  Skipped (exist):   $skipped" -ForegroundColor Yellow
    Write-Host "  Failed:            $failed" -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'White' })
    Write-Host ""
    
    if (-not $DryRun) {
        Write-Host "Next Steps:" -ForegroundColor Cyan
        Write-Host "  1. Log into ERPNext and verify Item Groups"
        Write-Host "  2. Configure WooCommerce integration"
        Write-Host "  3. Begin syncing products"
        Write-Host ""
    }
}
catch {
    Write-LogMessage "Script failed: $_" -Level Error
    Write-LogMessage $_.ScriptStackTrace -Level Error
    exit 1
}

#endregion
