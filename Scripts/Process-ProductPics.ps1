<#
.SYNOPSIS
    Removes backgrounds from product images using AI-powered rembg tool with
    post-processing for color correction and SEO-friendly file naming.

.DESCRIPTION
    This script provides batch background removal for product photography using the rembg
    Python library. It supports single image processing, batch folder processing, and a
    file watcher mode for automated processing of new images. Output images are saved as
    transparent PNGs ready for WooCommerce and eBay upload.

    Version 2.1 adds:
    - Advanced 4-pass spill removal that handles dark products (rubber, black plastic,
      dark metal) where the original single-pass approach missed subtle green fringe
    - Edge-proximity weighting using SciPy so corrections are strongest at product
      boundaries where spill is concentrated
    - Automatic detection of solid-background vs transparent images — works correctly
      whether rembg outputs true transparency or a solid black background
    - SciPy added as a dependency for edge erosion calculations
    - Pillow 14 forward compatibility

    Version 2.0 adds:
    - Post-processing pipeline: brightness, contrast, shadow adjustment, and color
      spill removal (green/blue/red screen fringing) using a companion Python script
    - SEO-friendly file naming for e-commerce platforms (hyphens, lowercase, keywords)
    - CSV-based product naming via a mapping file for batch SEO renaming
    - Metadata stripping (EXIF, GPS, ICC profiles, PNG text chunks)
    - Pillow and NumPy dependency management alongside rembg

    After processing, source images are moved to a "Processed" subfolder and a detailed
    CSV report is generated for tracking purposes.

.PARAMETER InputPath
    Path to a single image file or folder containing images to process.

.PARAMETER OutputPath
    Path to the output folder for processed images. Created if it doesn't exist.

.PARAMETER Watch
    Enable file watcher mode to automatically process new images added to InputPath.

.PARAMETER Model
    The rembg model to use for background removal. Default is 'u2net'.
    Available models: u2net, u2netp, u2net_human_seg, u2net_cloth_seg, silueta,
    isnet-general-use, isnet-anime, sam, birefnet-general

.PARAMETER InstallRembg
    Install or update rembg, Pillow, NumPy, and dependencies before processing.

.PARAMETER AlphaMatting
    Apply alpha matting for improved edge quality (slower but better results).

.PARAMETER Recursive
    Process subfolders recursively when InputPath is a folder.

.PARAMETER NoMove
    Do not move source images to the Processed folder after processing.

.PARAMETER NoPostProcess
    Skip the post-processing pipeline (brightness, contrast, shadows, spill removal).
    Use this if you want raw background-removed images without color correction.

.PARAMETER NoStripMetadata
    Keep image metadata intact. By default, ALL metadata is stripped from output
    images: EXIF data (camera model, GPS coordinates, timestamps, software tags),
    ICC color profiles, PNG text chunks (tEXt, iTXt, zTXt), and XMP data.
    Stripping metadata is recommended for e-commerce listings to prevent leaking
    studio/warehouse GPS coordinates and to reduce file size. Use this switch
    only when you need to preserve color profiles or other embedded data.

.PARAMETER Brightness
    Brightness adjustment factor. Default 1.03 (equivalent to Canva Brightness +5).
    Values above 1.0 increase brightness, below 1.0 decrease it. Range: 0.5 to 2.0.

.PARAMETER Contrast
    Contrast adjustment factor. Default 1.05 (equivalent to Canva Contrast +5).
    Values above 1.0 increase contrast, below 1.0 decrease it. Range: 0.5 to 2.0.

.PARAMETER Shadows
    Shadow lightening amount. Default 15 (equivalent to Canva Shadows +15).
    Range: 0 to 100. Higher values lighten dark areas more aggressively.

.PARAMETER SpillColor
    The chroma key color to remove spill from. Default is 'green'.
    Use 'blue' for blue screen setups, 'red' for red screen setups.
    Use 'none' to skip spill removal while keeping other adjustments.

.PARAMETER SpillStrength
    Strength of spill color removal. Default 0.85.
    Range: 0.0 (no removal) to 1.0 (maximum removal).

.PARAMETER SEOName
    SEO-friendly base name for output files. Applied to all processed images.
    Spaces and underscores are converted to hyphens, text is lowercased,
    and special characters are removed for Google-friendly filenames.
    Example: -SEOName "check valve 2 inch" produces "check-valve-2-inch.png"

.PARAMETER SEOPrefix
    Optional prefix added before the SEO name for branding or categorization.
    Example: -SEOPrefix "jt-custom" -SEOName "check valve" produces
    "jt-custom-check-valve.png"

.PARAMETER SEOSuffix
    Optional suffix added after the SEO name.
    Example: -SEOName "check valve" -SEOSuffix "transparent" produces
    "check-valve-transparent.png"

.PARAMETER SEOMappingFile
    Path to a CSV file mapping source filenames to SEO names for batch renaming.
    CSV format: SourceFileName,SEOName,SEOPrefix,SEOSuffix
    Example row: IMG_0001.jpg,check-valve-2-inch,jt-custom,transparent

.PARAMETER RenameCSV
    Path to a CSV file for standalone SEO rename mode. This mode does NOT process
    images (no background removal or post-processing). It simply copies and renames
    files according to the CSV mapping and optionally embeds alt text metadata.
    CSV format: SourceFileName,SEOFileName,AltText
    Example row: IMG_0001.png,check-valve-2-inch-abs-transparent.png,2 inch ABS check valve

.PARAMETER RenameInputPath
    Path to the folder containing source images for rename mode.

.PARAMETER RenameOutputPath
    Path to the output folder for renamed images. Defaults to a "SEO-Renamed"
    subfolder inside RenameInputPath if not specified.

.PARAMETER EmbedAltText
    When used with -RenameCSV, embeds the AltText value from the CSV as PNG
    tEXt metadata (Alt, Description, and Comment chunks). Requires Python and
    Pillow. Only applies to .png files; other formats are renamed without
    alt text embedding.

.PARAMETER LogPath
    Path for the log file. Defaults to InputPath\BackgroundRemoval.log

.PARAMETER ReportPath
    Path for the CSV report. Defaults to InputPath\BackgroundRemoval-Report.csv

.EXAMPLE
    .\Process-ProductPics.ps1 -RenameCSV "C:\Photos\seo-names.csv" -RenameInputPath "C:\Photos\Transparent"
    Standalone SEO rename: copies and renames images per the CSV mapping to a
    "SEO-Renamed" subfolder. No image processing is performed.

.EXAMPLE
    .\Process-ProductPics.ps1 -RenameCSV "C:\Photos\seo-names.csv" -RenameInputPath "C:\Photos\Transparent" -RenameOutputPath "C:\Photos\Ready" -EmbedAltText
    Renames images AND embeds alt text as PNG metadata for accessibility and SEO.

.EXAMPLE
    .\Process-ProductPics.ps1 -InputPath "C:\Photos\Products" -OutputPath "C:\Photos\Transparent"
    Processes all images with default post-processing (brightness, contrast, shadows,
    green spill removal). Moves originals to Products\Processed, generates report.

.EXAMPLE
    .\Process-ProductPics.ps1 -InputPath "C:\Photos\Products" -OutputPath "C:\Photos\Transparent" -NoPostProcess
    Processes all images with background removal only, no color correction.

.EXAMPLE
    .\Process-ProductPics.ps1 -InputPath "C:\Photos\valve.jpg" -OutputPath "C:\Photos\Ready" -SEOName "check valve 2 inch" -SEOPrefix "jt-custom" -SEOSuffix "transparent"
    Produces: jt-custom-check-valve-2-inch-transparent.png

.EXAMPLE
    .\Process-ProductPics.ps1 -InputPath "C:\Photos\Products" -OutputPath "C:\Photos\Ready" -SEOMappingFile "C:\Photos\seo-names.csv"
    Batch processes using a CSV mapping file for SEO names.

.EXAMPLE
    .\Process-ProductPics.ps1 -InputPath "C:\Photos\Products" -OutputPath "C:\Photos\Ready" -SpillColor "blue" -SpillStrength 0.9
    Processes with blue screen spill removal at 90% strength.

.EXAMPLE
    .\Process-ProductPics.ps1 -InputPath "C:\Photos\Products" -OutputPath "C:\Photos\Ready" -Brightness 1.08 -Contrast 1.10 -Shadows 25
    Custom brightness/contrast/shadow values for darker product photos.

.EXAMPLE
    .\Process-ProductPics.ps1 -InputPath "C:\Photos\Incoming" -OutputPath "C:\Photos\Ready" -Watch
    Watches the Incoming folder and automatically processes new images with
    default post-processing and green spill removal.

.EXAMPLE
    .\Process-ProductPics.ps1 -InstallRembg
    Installs rembg, Pillow, NumPy, SciPy, and required dependencies using pip.

.NOTES
    Author: John O'Neill Sr.
    Company: Azure Innovators
    GitHub: https://github.com/JONeillSr/
    Create Date: 12/14/2024
    Version: 2.1.0
    Change Date: 05/07/2026
    Change Purpose: Advanced 4-pass spill removal for dark products, edge-proximity
                    weighting, solid-background detection, SciPy dependency

    Requirements:
    - Python 3.10 or higher
    - pip (Python package manager)
    - rembg Python package (can be installed via -InstallRembg parameter)
    - Pillow Python package (installed automatically with -InstallRembg)
    - NumPy Python package (installed automatically with -InstallRembg)
    - SciPy Python package (installed automatically with -InstallRembg)
    - postprocess_image.py companion script (must be in same directory as this script)

    Supported image formats: JPG, JPEG, PNG, WEBP, BMP, TIFF

    Post-Processing Defaults (matching Canva adjustments):
    - Brightness: 1.03 (Canva +5)
    - Contrast: 1.05 (Canva +5)
    - Shadows: 15 (Canva +15)
    - Spill Color: green (Hue/Sat/Brightness all -100 equivalent)
    - Spill Strength: 0.85

    SEO File Naming Guidelines:
    - Use hyphens between words (Google treats hyphens as word separators)
    - Keep filenames lowercase
    - Front-load primary keywords
    - Include product-specific terms (size, type, material)
    - Avoid special characters, underscores, and spaces

.CHANGELOG
    Version 2.1.0 - 05/07/2026
    - Rewrote spill removal with 4-pass approach for dark products (rubber, black
      plastic, dark metal) where v2.0 single-pass missed subtle green fringe
    - Pass 1: Absolute excess detection with lowered threshold (10 -> 2)
    - Pass 2: Ratio-based detection for dark pixels (max channel < 80)
    - Pass 3: Edge desaturation within 16px of product boundary
    - Pass 4: Hard edge clamp for stubborn fringe at outermost boundary pixels
    - Added edge-proximity weighting via SciPy binary erosion so corrections are
      strongest at product edges where spill concentrates
    - Added automatic detection of solid-background vs transparent images — spill
      removal now works correctly whether background is transparent or solid black
    - Added standalone SEO rename mode via -RenameCSV parameter with 3-column CSV
      format (SourceFileName, SEOFileName, AltText) for renaming without processing
    - Added -EmbedAltText switch to embed alt text as PNG tEXt metadata (Alt,
      Description, Comment chunks) for accessibility and image search SEO
    - Added -RenameInputPath and -RenameOutputPath parameters for rename mode
    - Added SciPy to dependency installation (-InstallRembg) and prerequisite checks
    - Added Pillow 14 forward compatibility (get_flattened_data with getdata fallback)
    - Refactored spill correction into generic channel-based function supporting
      green, blue, and red with identical multi-pass logic

    Version 2.0.0 - 05/02/2026
    - Added post-processing pipeline with brightness, contrast, and shadow adjustment
    - Added green/blue/red screen color spill removal
    - Added SEO-friendly file naming with -SEOName, -SEOPrefix, -SEOSuffix parameters
    - Added CSV-based batch SEO naming via -SEOMappingFile parameter
    - Added -NoPostProcess parameter to skip color correction
    - Added -Brightness, -Contrast, -Shadows parameters for custom values
    - Added -SpillColor and -SpillStrength parameters for spill configuration
    - Added metadata stripping (EXIF, ICC profiles, PNG text chunks) on by default
    - Added -NoStripMetadata parameter to preserve metadata when needed
    - Added Pillow and NumPy to dependency installation
    - Added postprocess_image.py companion script requirement
    - Updated watcher mode to include post-processing
    - Enhanced CSV report with post-processing details and SEO filename

    Version 1.1.0 - 12/15/2024
    - Added automatic movement of processed source images to "Processed" subfolder
    - Added CSV report generation with processing details
    - Added detailed log file creation
    - Added -NoMove parameter to optionally keep source files in place
    - Added -LogPath and -ReportPath parameters for custom locations
    - Improved watcher mode to move files after processing
    - Added processing statistics to report summary

    Version 1.0.0 - 12/14/2024
    - Initial release
    - Single image processing support
    - Batch folder processing support
    - File watcher mode for automated processing
    - Multiple AI model support
    - Alpha matting option for improved edges
    - Recursive folder processing option
    - Automatic rembg installation option
    - Progress tracking and detailed logging
    - Error handling with detailed messages
#>

[CmdletBinding(DefaultParameterSetName = 'Process')]
param(
    [Parameter(ParameterSetName = 'Process', Mandatory = $true, Position = 0)]
    [Parameter(ParameterSetName = 'Watch', Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$InputPath,

    [Parameter(ParameterSetName = 'Process', Mandatory = $true, Position = 1)]
    [Parameter(ParameterSetName = 'Watch', Mandatory = $true, Position = 1)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [Parameter(ParameterSetName = 'Watch')]
    [switch]$Watch,

    [Parameter(ParameterSetName = 'Process')]
    [Parameter(ParameterSetName = 'Watch')]
    [ValidateSet('u2net', 'u2netp', 'u2net_human_seg', 'u2net_cloth_seg',
        'silueta', 'isnet-general-use', 'isnet-anime', 'sam', 'birefnet-general')]
    [string]$Model = 'u2net',

    [Parameter(ParameterSetName = 'Install')]
    [switch]$InstallRembg,

    [Parameter(ParameterSetName = 'Process')]
    [Parameter(ParameterSetName = 'Watch')]
    [switch]$AlphaMatting,

    [Parameter(ParameterSetName = 'Process')]
    [switch]$Recursive,

    [Parameter(ParameterSetName = 'Process')]
    [Parameter(ParameterSetName = 'Watch')]
    [switch]$NoMove,

    [Parameter(ParameterSetName = 'Process')]
    [Parameter(ParameterSetName = 'Watch')]
    [switch]$NoPostProcess,

    [Parameter(ParameterSetName = 'Process')]
    [Parameter(ParameterSetName = 'Watch')]
    [switch]$NoStripMetadata,

    [Parameter(ParameterSetName = 'Process')]
    [Parameter(ParameterSetName = 'Watch')]
    [ValidateRange(0.5, 2.0)]
    [double]$Brightness = 1.03,

    [Parameter(ParameterSetName = 'Process')]
    [Parameter(ParameterSetName = 'Watch')]
    [ValidateRange(0.5, 2.0)]
    [double]$Contrast = 1.05,

    [Parameter(ParameterSetName = 'Process')]
    [Parameter(ParameterSetName = 'Watch')]
    [ValidateRange(0, 100)]
    [int]$Shadows = 15,

    [Parameter(ParameterSetName = 'Process')]
    [Parameter(ParameterSetName = 'Watch')]
    [ValidateSet('green', 'blue', 'red', 'none')]
    [string]$SpillColor = 'green',

    [Parameter(ParameterSetName = 'Process')]
    [Parameter(ParameterSetName = 'Watch')]
    [ValidateRange(0.0, 1.0)]
    [double]$SpillStrength = 0.85,

    [Parameter(ParameterSetName = 'Process')]
    [Parameter(ParameterSetName = 'Watch')]
    [string]$SEOName,

    [Parameter(ParameterSetName = 'Process')]
    [Parameter(ParameterSetName = 'Watch')]
    [string]$SEOPrefix,

    [Parameter(ParameterSetName = 'Process')]
    [Parameter(ParameterSetName = 'Watch')]
    [string]$SEOSuffix,

    [Parameter(ParameterSetName = 'Process')]
    [string]$SEOMappingFile,

    [Parameter(ParameterSetName = 'Rename', Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$RenameCSV,

    [Parameter(ParameterSetName = 'Rename', Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$RenameInputPath,

    [Parameter(ParameterSetName = 'Rename')]
    [ValidateNotNullOrEmpty()]
    [string]$RenameOutputPath,

    [Parameter(ParameterSetName = 'Rename')]
    [switch]$EmbedAltText,

    [Parameter(ParameterSetName = 'Process')]
    [Parameter(ParameterSetName = 'Watch')]
    [string]$LogPath,

    [Parameter(ParameterSetName = 'Process')]
    [Parameter(ParameterSetName = 'Watch')]
    [string]$ReportPath
)

#region Configuration
$script:SupportedExtensions = @('.jpg', '.jpeg', '.png', '.webp', '.bmp', '.tiff', '.tif')
$script:ProcessedCount = 0
$script:ErrorCount = 0
$script:SkippedCount = 0
$script:PostProcessedCount = 0
$script:StartTime = Get-Date
$script:ProcessingResults = [System.Collections.ArrayList]::new()
$script:LogFile = $null
$script:ReportFile = $null
$script:ProcessedFolder = $null
$script:SEOMappings = @{}
$script:PostProcessScript = $null
$script:SEOCounter = @{}
#endregion

#region Functions

function Initialize-Logging {
    <#
    .SYNOPSIS
        Initializes log file and report file paths.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    $logFolder = if (Test-Path $BasePath -PathType Container) {
        $BasePath
    }
    else {
        Split-Path $BasePath -Parent
    }

    if ([string]::IsNullOrEmpty($script:LogPath)) {
        $script:LogFile = Join-Path $logFolder "BackgroundRemoval.log"
    }
    else {
        $script:LogFile = $LogPath
    }

    if ([string]::IsNullOrEmpty($script:ReportPath)) {
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $script:ReportFile = Join-Path $logFolder "BackgroundRemoval-Report-$timestamp.csv"
    }
    else {
        $script:ReportFile = $ReportPath
    }

    $script:ProcessedFolder = Join-Path $logFolder "Processed"

    if (-not $NoMove -and -not (Test-Path $script:ProcessedFolder)) {
        New-Item -ItemType Directory -Path $script:ProcessedFolder -Force | Out-Null
    }

    $headerLines = @(
        "=" * 80
        "Azure Innovators - AI Background Remover v2.0 Log"
        "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "Input: $InputPath"
        "Output: $OutputPath"
        "Model: $Model"
        "Post-Processing: $(if ($NoPostProcess) { 'Disabled' } else { 'Enabled' })"
    )

    if (-not $NoPostProcess) {
        $headerLines += "  Brightness: $Brightness | Contrast: $Contrast | Shadows: $Shadows"
        $headerLines += "  Spill Color: $SpillColor | Spill Strength: $SpillStrength"
    }

    if ($SEOName -or $SEOMappingFile) {
        $headerLines += "SEO Naming: Enabled"
        if ($SEOName) { $headerLines += "  Base Name: $SEOName" }
        if ($SEOPrefix) { $headerLines += "  Prefix: $SEOPrefix" }
        if ($SEOSuffix) { $headerLines += "  Suffix: $SEOSuffix" }
        if ($SEOMappingFile) { $headerLines += "  Mapping File: $SEOMappingFile" }
    }

    $headerLines += "=" * 80
    $headerLines += ""

    $logHeader = $headerLines -join "`r`n"
    Add-Content -Path $script:LogFile -Value $logHeader -Encoding UTF8
}

function Write-LogMessage {
    <#
    .SYNOPSIS
        Writes a formatted log message to the console and log file.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        'Info'    { 'Cyan' }
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
    }

    Write-Host "[$timestamp] " -NoNewline -ForegroundColor Gray
    Write-Host "[$Level] " -NoNewline -ForegroundColor $color
    Write-Host $Message

    if ($script:LogFile) {
        $logEntry = "[$timestamp] [$Level] $Message"
        Add-Content -Path $script:LogFile -Value $logEntry -Encoding UTF8
    }
}

function Add-ProcessingResult {
    <#
    .SYNOPSIS
        Adds a processing result to the results collection.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceFile,

        [Parameter(Mandatory = $true)]
        [string]$OutputFile,

        [Parameter(Mandatory = $true)]
        [string]$Status,

        [Parameter()]
        [double]$ProcessingTime = 0,

        [Parameter()]
        [long]$SourceSize = 0,

        [Parameter()]
        [long]$OutputSize = 0,

        [Parameter()]
        [string]$MovedTo = "",

        [Parameter()]
        [string]$ErrorMessage = "",

        [Parameter()]
        [bool]$PostProcessed = $false,

        [Parameter()]
        [string]$SEOFileName = ""
    )

    $result = [PSCustomObject]@{
        Timestamp         = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        SourceFile        = $SourceFile
        SourceFileName    = [System.IO.Path]::GetFileName($SourceFile)
        OutputFile        = $OutputFile
        OutputFileName    = [System.IO.Path]::GetFileName($OutputFile)
        SEOFileName       = $SEOFileName
        Status            = $Status
        PostProcessed     = $PostProcessed
        ProcessingTime    = [math]::Round($ProcessingTime, 2)
        SourceSizeKB      = [math]::Round($SourceSize / 1KB, 2)
        OutputSizeKB      = [math]::Round($OutputSize / 1KB, 2)
        SizeReduction     = if ($SourceSize -gt 0 -and $OutputSize -gt 0) {
            [math]::Round((1 - ($OutputSize / $SourceSize)) * 100, 1)
        }
        else { 0 }
        MovedTo           = $MovedTo
        ErrorMessage      = $ErrorMessage
        Model             = $Model
        BrightnessSetting = if (-not $NoPostProcess) { $Brightness } else { "N/A" }
        ContrastSetting   = if (-not $NoPostProcess) { $Contrast } else { "N/A" }
        ShadowsSetting    = if (-not $NoPostProcess) { $Shadows } else { "N/A" }
        SpillColor        = if (-not $NoPostProcess) { $SpillColor } else { "N/A" }
        MetadataStripped  = if (-not $NoPostProcess -and -not $NoStripMetadata) { $true } else { $false }
    }

    $null = $script:ProcessingResults.Add($result)
}

function Export-ProcessingReport {
    <#
    .SYNOPSIS
        Exports the processing results to a CSV report.
    #>
    if ($script:ProcessingResults.Count -eq 0) {
        Write-LogMessage "No results to export" -Level Warning
        return
    }

    try {
        $script:ProcessingResults |
            Export-Csv -Path $script:ReportFile -NoTypeInformation -Encoding UTF8
        Write-LogMessage "Report saved: $($script:ReportFile)" -Level Success
    }
    catch {
        Write-LogMessage "Failed to save report: $_" -Level Error
    }
}

function Test-PythonInstalled {
    <#
    .SYNOPSIS
        Checks if Python is installed and accessible.
    #>
    try {
        $pythonVersion = & python --version 2>&1
        if ($pythonVersion -match 'Python (\d+)\.(\d+)') {
            $major = [int]$Matches[1]
            $minor = [int]$Matches[2]
            if ($major -ge 3 -and $minor -ge 10) {
                Write-LogMessage "Python $major.$minor detected" -Level Success
                return $true
            }
            else {
                Write-LogMessage "Python 3.10 or higher required. Found: Python $major.$minor" -Level Error
                return $false
            }
        }
    }
    catch {
        Write-LogMessage "Python is not installed or not in PATH" -Level Error
        Write-LogMessage "Install Python using: winget install Python.Python.3.12" -Level Info
        return $false
    }
    return $false
}

function Test-RembgInstalled {
    <#
    .SYNOPSIS
        Checks if rembg is installed.
    #>
    try {
        $null = & rembg --version 2>&1
        return $true
    }
    catch {
        return $false
    }
}

function Test-PillowInstalled {
    <#
    .SYNOPSIS
        Checks if Pillow, NumPy, and SciPy are installed for post-processing.
    #>
    try {
        $result = & python -c "import PIL; import numpy; import scipy; print('OK')" 2>&1
        return ($result -eq 'OK')
    }
    catch {
        return $false
    }
}

function Install-Rembg {
    <#
    .SYNOPSIS
        Installs rembg, Pillow, NumPy using pip.
    #>
    Write-LogMessage "Installing rembg with CPU support, CLI, Pillow, NumPy, and SciPy..." -Level Info

    try {
        Write-LogMessage "Upgrading pip..." -Level Info
        & python -m pip install --upgrade pip 2>&1 | Out-Null

        Write-LogMessage "Installing rembg[cpu,cli]..." -Level Info
        $installOutput = & pip install "rembg[cpu,cli]" 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-LogMessage "Failed to install rembg: $installOutput" -Level Error
            return $false
        }

        Write-LogMessage "rembg installed successfully!" -Level Success

        Write-LogMessage "Installing Pillow, NumPy, and SciPy for post-processing..." -Level Info
        $pillowOutput = & pip install Pillow numpy scipy 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-LogMessage "Failed to install Pillow/NumPy/SciPy: $pillowOutput" -Level Error
            Write-LogMessage "Post-processing will not be available. Use -NoPostProcess to skip." -Level Warning
            return $true
        }

        Write-LogMessage "Pillow, NumPy, and SciPy installed successfully!" -Level Success
        Write-LogMessage "Note: The AI model will download automatically on first use." -Level Info
        return $true
    }
    catch {
        Write-LogMessage "Error installing dependencies: $_" -Level Error
        return $false
    }
}

function Initialize-PostProcessing {
    <#
    .SYNOPSIS
        Locates the postprocess_image.py companion script.
    #>
    $scriptDir = $PSScriptRoot
    if ([string]::IsNullOrEmpty($scriptDir)) {
        $scriptDir = Split-Path -Parent $MyInvocation.ScriptName
    }
    if ([string]::IsNullOrEmpty($scriptDir)) {
        $scriptDir = Get-Location
    }

    $postProcessPath = Join-Path $scriptDir "postprocess_image.py"

    if (-not (Test-Path $postProcessPath)) {
        $postProcessPath = Join-Path (Get-Location) "postprocess_image.py"
    }

    if (-not (Test-Path $postProcessPath)) {
        Write-LogMessage "postprocess_image.py not found in script directory or current directory." -Level Error
        Write-LogMessage "Expected location: $scriptDir\postprocess_image.py" -Level Info
        Write-LogMessage "Download it from: https://github.com/JONeillSr/" -Level Info
        return $false
    }

    if (-not (Test-PillowInstalled)) {
        Write-LogMessage "Pillow and/or NumPy not installed. Run with -InstallRembg to install dependencies." -Level Error
        Write-LogMessage "Or install manually: pip install Pillow numpy scipy" -Level Info
        return $false
    }

    $script:PostProcessScript = $postProcessPath
    Write-LogMessage "Post-processing script loaded: $postProcessPath" -Level Success
    return $true
}

function Import-SEOMappings {
    <#
    .SYNOPSIS
        Imports SEO name mappings from a CSV file.
    .DESCRIPTION
        CSV format: SourceFileName,SEOName,SEOPrefix,SEOSuffix
        Example: IMG_0001.jpg,check-valve-2-inch,jt-custom,transparent
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$MappingFile
    )

    if (-not (Test-Path $MappingFile)) {
        Write-LogMessage "SEO mapping file not found: $MappingFile" -Level Error
        return $false
    }

    try {
        $mappings = Import-Csv -Path $MappingFile -Encoding UTF8

        $requiredColumns = @('SourceFileName', 'SEOName')
        $csvColumns = $mappings[0].PSObject.Properties.Name
        foreach ($col in $requiredColumns) {
            if ($col -notin $csvColumns) {
                Write-LogMessage "SEO mapping file missing required column: $col" -Level Error
                Write-LogMessage "Required columns: SourceFileName, SEOName" -Level Info
                Write-LogMessage "Optional columns: SEOPrefix, SEOSuffix" -Level Info
                return $false
            }
        }

        foreach ($mapping in $mappings) {
            $key = $mapping.SourceFileName.Trim()
            $script:SEOMappings[$key] = @{
                SEOName   = $mapping.SEOName.Trim()
                SEOPrefix = if ($mapping.PSObject.Properties['SEOPrefix']) {
                    $mapping.SEOPrefix.Trim()
                }
                else { "" }
                SEOSuffix = if ($mapping.PSObject.Properties['SEOSuffix']) {
                    $mapping.SEOSuffix.Trim()
                }
                else { "" }
            }
        }

        Write-LogMessage "Loaded $($script:SEOMappings.Count) SEO mapping(s) from: $MappingFile" -Level Success
        return $true
    }
    catch {
        Write-LogMessage "Error reading SEO mapping file: $_" -Level Error
        return $false
    }
}

function ConvertTo-SEOFileName {
    <#
    .SYNOPSIS
        Converts a product name into an SEO-friendly filename.
    .DESCRIPTION
        Applies SEO best practices for Google image indexing:
        - Lowercase for consistency
        - Hyphens as word separators (Google treats hyphens as spaces)
        - Removes special characters
        - Trims excessive hyphens
        - Appends numeric suffix for duplicates in batch processing
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter()]
        [string]$Prefix = "",

        [Parameter()]
        [string]$Suffix = "",

        [Parameter()]
        [string]$Extension = ".png"
    )

    $parts = @()
    if (-not [string]::IsNullOrWhiteSpace($Prefix)) { $parts += $Prefix }
    $parts += $Name
    if (-not [string]::IsNullOrWhiteSpace($Suffix)) { $parts += $Suffix }

    $combined = $parts -join " "

    # Convert to SEO-friendly format
    $seoName = $combined.ToLower()
    $seoName = $seoName -replace '[\s_\.]+', '-'
    $seoName = $seoName -replace '[^a-z0-9\-]', ''
    $seoName = $seoName -replace '-{2,}', '-'
    $seoName = $seoName.Trim('-')

    # Handle duplicate names by appending a counter
    if ($script:SEOCounter.ContainsKey($seoName)) {
        $script:SEOCounter[$seoName]++
        $counter = $script:SEOCounter[$seoName]
        return "$seoName-$counter$Extension"
    }
    else {
        $script:SEOCounter[$seoName] = 1
        return "$seoName$Extension"
    }
}

function Get-OutputFileName {
    <#
    .SYNOPSIS
        Generates the output file path for a processed image with optional SEO naming.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputFile,

        [Parameter(Mandatory = $true)]
        [string]$OutputFolder,

        [Parameter()]
        [string]$RelativePath = ""
    )

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
    $sourceFileName = [System.IO.Path]::GetFileName($InputFile)
    $outputSubfolder = Join-Path $OutputFolder $RelativePath

    if (-not (Test-Path $outputSubfolder)) {
        New-Item -ItemType Directory -Path $outputSubfolder -Force | Out-Null
    }

    $outputFileName = "$baseName.png"

    # Priority 1: SEO mapping file
    if ($script:SEOMappings.ContainsKey($sourceFileName)) {
        $mapping = $script:SEOMappings[$sourceFileName]
        $outputFileName = ConvertTo-SEOFileName -Name $mapping.SEOName `
            -Prefix $mapping.SEOPrefix `
            -Suffix $mapping.SEOSuffix
    }
    # Priority 2: Command-line SEO parameters
    elseif (-not [string]::IsNullOrEmpty($SEOName)) {
        $outputFileName = ConvertTo-SEOFileName -Name $SEOName `
            -Prefix $SEOPrefix `
            -Suffix $SEOSuffix
    }

    return Join-Path $outputSubfolder $outputFileName
}

function Invoke-PostProcessing {
    <#
    .SYNOPSIS
        Runs the post-processing Python script on a transparent PNG.
    .DESCRIPTION
        Applies brightness, contrast, shadow adjustments, and color spill
        removal. Processes in-place (overwrites the input file).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImageFile
    )

    if ($NoPostProcess -or -not $script:PostProcessScript) {
        return $true
    }

    try {
        $pyArgs = @(
            "`"$($script:PostProcessScript)`""
            "`"$ImageFile`""
            "`"$ImageFile`""
            "--brightness"
            $Brightness.ToString()
            "--contrast"
            $Contrast.ToString()
            "--shadows"
            $Shadows.ToString()
        )

        if ($SpillColor -eq 'none') {
            $pyArgs += "--no-spill"
        }
        else {
            $pyArgs += "--spill-color"
            $pyArgs += $SpillColor
            $pyArgs += "--spill-strength"
            $pyArgs += $SpillStrength.ToString()
        }

        if ($NoStripMetadata) {
            $pyArgs += "--no-strip-metadata"
        }

        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = 'python'
        $processInfo.Arguments = $pyArgs -join ' '
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        $process.Start() | Out-Null
        $process.WaitForExit()

        if ($process.ExitCode -eq 0) {
            $script:PostProcessedCount++
            return $true
        }
        else {
            $stderr = $process.StandardError.ReadToEnd()
            Write-LogMessage "Post-processing error: $stderr" -Level Warning
            return $false
        }
    }
    catch {
        Write-LogMessage "Post-processing failed: $_" -Level Warning
        return $false
    }
}

function Move-ToProcessedFolder {
    <#
    .SYNOPSIS
        Moves a processed source file to the Processed folder.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceFile,

        [Parameter()]
        [string]$RelativePath = ""
    )

    if ($NoMove) { return "" }

    try {
        $destinationFolder = if ($RelativePath) {
            Join-Path $script:ProcessedFolder $RelativePath
        }
        else {
            $script:ProcessedFolder
        }

        if (-not (Test-Path $destinationFolder)) {
            New-Item -ItemType Directory -Path $destinationFolder -Force | Out-Null
        }

        $fileName = [System.IO.Path]::GetFileName($SourceFile)
        $destinationFile = Join-Path $destinationFolder $fileName

        if (Test-Path $destinationFile) {
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($SourceFile)
            $extension = [System.IO.Path]::GetExtension($SourceFile)
            $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
            $destinationFile = Join-Path $destinationFolder "$baseName-$timestamp$extension"
        }

        Move-Item -Path $SourceFile -Destination $destinationFile -Force
        return $destinationFile
    }
    catch {
        Write-LogMessage "Failed to move file: $_" -Level Warning
        return ""
    }
}

function Remove-ImageBackgroundSingle {
    <#
    .SYNOPSIS
        Removes the background from a single image using rembg.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputFile,

        [Parameter(Mandatory = $true)]
        [string]$OutputFile,

        [Parameter()]
        [string]$ModelName = 'u2net',

        [Parameter()]
        [switch]$UseAlphaMatting
    )

    $arguments = @('i')
    $arguments += '-m'
    $arguments += $ModelName

    if ($UseAlphaMatting) {
        $arguments += '-a'
        $arguments += '-ae'
        $arguments += '15'
        $arguments += '-af'
        $arguments += '240'
    }

    $arguments += "`"$InputFile`""
    $arguments += "`"$OutputFile`""

    try {
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = 'rembg'
        $processInfo.Arguments = $arguments -join ' '
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        $process.Start() | Out-Null
        $process.WaitForExit()

        if ($process.ExitCode -eq 0 -and (Test-Path $OutputFile)) {
            return $true
        }
        else {
            $stderr = $process.StandardError.ReadToEnd()
            Write-LogMessage "rembg error: $stderr" -Level Error
            return $false
        }
    }
    catch {
        Write-LogMessage "Error processing image: $_" -Level Error
        return $false
    }
}

function Process-ImageFile {
    <#
    .SYNOPSIS
        Full pipeline: background removal -> post-processing -> SEO naming.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputFile,

        [Parameter(Mandatory = $true)]
        [string]$OutputFolder,

        [Parameter()]
        [string]$RelativePath = "",

        [Parameter()]
        [string]$ModelName = 'u2net',

        [Parameter()]
        [switch]$UseAlphaMatting,

        [Parameter()]
        [int]$Current = 0,

        [Parameter()]
        [int]$Total = 0
    )

    $fileName = [System.IO.Path]::GetFileName($InputFile)

    if ($Total -gt 0) {
        $progress = [math]::Round(($Current / $Total) * 100)
        Write-Progress -Activity "Processing Product Images" `
            -Status "Processing: $fileName ($Current of $Total)" `
            -PercentComplete $progress
    }

    $outputFile = Get-OutputFileName -InputFile $InputFile `
        -OutputFolder $OutputFolder `
        -RelativePath $RelativePath

    $seoFileName = [System.IO.Path]::GetFileName($outputFile)

    if (Test-Path $outputFile) {
        Write-LogMessage "Skipping (already exists): $fileName" -Level Warning
        $script:SkippedCount++
        Add-ProcessingResult -SourceFile $InputFile `
            -OutputFile $outputFile `
            -Status "Skipped" `
            -ErrorMessage "Output file already exists" `
            -SEOFileName $seoFileName
        return
    }

    Write-LogMessage "Processing: $fileName" -Level Info
    $originalBase = "$([System.IO.Path]::GetFileNameWithoutExtension($InputFile)).png"
    if ($seoFileName -ne $originalBase) {
        Write-LogMessage "  SEO Name: $seoFileName" -Level Info
    }

    $sourceSize = (Get-Item $InputFile).Length
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # Step 1: Background removal
    $success = Remove-ImageBackgroundSingle -InputFile $InputFile `
        -OutputFile $outputFile `
        -ModelName $ModelName `
        -UseAlphaMatting:$UseAlphaMatting

    if ($success) {
        # Step 2: Post-processing
        $postProcessed = $false
        if (-not $NoPostProcess) {
            $postProcessed = Invoke-PostProcessing -ImageFile $outputFile
            if ($postProcessed) {
                $metaStatus = if ($NoStripMetadata) { "metadata=kept" } else { "metadata=stripped" }
                Write-LogMessage "  -> Post-processed: brightness=$Brightness, contrast=$Contrast, shadows=$Shadows, spill=$SpillColor, $metaStatus" -Level Info
            }
            else {
                Write-LogMessage "  -> Post-processing skipped (error occurred, raw image retained)" -Level Warning
            }
        }

        $stopwatch.Stop()
        $script:ProcessedCount++
        $outputSize = (Get-Item $outputFile).Length
        $inputSizeKB = [math]::Round($sourceSize / 1KB, 1)
        $outputSizeKB = [math]::Round($outputSize / 1KB, 1)

        $movedTo = Move-ToProcessedFolder -SourceFile $InputFile -RelativePath $RelativePath

        $moveStatus = if ($movedTo) { " -> Moved to Processed" } else { "" }
        $ppStatus = if ($postProcessed) { " [PP]" } else { "" }
        $elapsed = $stopwatch.Elapsed.TotalSeconds.ToString('F1')
        Write-LogMessage "  -> Saved: $seoFileName (${inputSizeKB}KB -> ${outputSizeKB}KB) [${elapsed}s]$ppStatus$moveStatus" -Level Success

        Add-ProcessingResult -SourceFile $InputFile `
            -OutputFile $outputFile `
            -Status "Success" `
            -ProcessingTime $stopwatch.Elapsed.TotalSeconds `
            -SourceSize $sourceSize `
            -OutputSize $outputSize `
            -MovedTo $movedTo `
            -PostProcessed $postProcessed `
            -SEOFileName $seoFileName
    }
    else {
        $stopwatch.Stop()
        $script:ErrorCount++
        Write-LogMessage "  -> Failed to process: $fileName" -Level Error

        Add-ProcessingResult -SourceFile $InputFile `
            -OutputFile $outputFile `
            -Status "Failed" `
            -ProcessingTime $stopwatch.Elapsed.TotalSeconds `
            -SourceSize $sourceSize `
            -ErrorMessage "rembg processing failed" `
            -SEOFileName $seoFileName
    }
}

function Process-ImageFolder {
    <#
    .SYNOPSIS
        Processes all images in a folder.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputFolder,

        [Parameter(Mandatory = $true)]
        [string]$OutputFolder,

        [Parameter()]
        [string]$ModelName = 'u2net',

        [Parameter()]
        [switch]$UseAlphaMatting,

        [Parameter()]
        [switch]$ProcessRecursive
    )

    $imageFiles = Get-ChildItem -Path $InputFolder -File -Recurse:$ProcessRecursive |
        Where-Object {
            $script:SupportedExtensions -contains $_.Extension.ToLower() -and
            $_.DirectoryName -notlike "*\Processed*"
        }

    if ($imageFiles.Count -eq 0) {
        Write-LogMessage "No supported image files found in: $InputFolder" -Level Warning
        Write-LogMessage "Supported formats: $($script:SupportedExtensions -join ', ')" -Level Info
        return
    }

    Write-LogMessage "Found $($imageFiles.Count) image(s) to process" -Level Info
    Write-LogMessage "Output folder: $OutputFolder" -Level Info
    Write-LogMessage "Model: $ModelName" -Level Info

    if (-not $NoPostProcess) {
        Write-LogMessage "Post-processing: Enabled (brightness=$Brightness, contrast=$Contrast, shadows=$Shadows, spill=$SpillColor)" -Level Info
    }
    else {
        Write-LogMessage "Post-processing: Disabled" -Level Info
    }

    if (-not $NoMove) {
        Write-LogMessage "Processed sources will be moved to: $($script:ProcessedFolder)" -Level Info
    }

    if ($UseAlphaMatting) {
        Write-LogMessage "Alpha matting: Enabled" -Level Info
    }

    if (-not (Test-Path $OutputFolder)) {
        New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
        Write-LogMessage "Created output folder: $OutputFolder" -Level Info
    }

    $current = 0
    foreach ($imageFile in $imageFiles) {
        $current++

        $relativePath = ""
        if ($ProcessRecursive) {
            $relativePath = $imageFile.DirectoryName.Replace($InputFolder, "").TrimStart('\', '/')
        }

        Process-ImageFile -InputFile $imageFile.FullName `
            -OutputFolder $OutputFolder `
            -RelativePath $relativePath `
            -ModelName $ModelName `
            -UseAlphaMatting:$UseAlphaMatting `
            -Current $current `
            -Total $imageFiles.Count
    }

    Write-Progress -Activity "Processing Product Images" -Completed
}

function Start-ImageWatcher {
    <#
    .SYNOPSIS
        Starts a file system watcher with automatic post-processing.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$WatchFolder,

        [Parameter(Mandatory = $true)]
        [string]$OutputFolder,

        [Parameter()]
        [string]$ModelName = 'u2net',

        [Parameter()]
        [switch]$UseAlphaMatting
    )

    Write-LogMessage "Starting file watcher on: $WatchFolder" -Level Info
    Write-LogMessage "Output folder: $OutputFolder" -Level Info

    if (-not $NoPostProcess) {
        Write-LogMessage "Post-processing: Enabled" -Level Info
    }

    if (-not $NoMove) {
        Write-LogMessage "Processed sources will be moved to: $($script:ProcessedFolder)" -Level Info
    }
    Write-LogMessage "Press Ctrl+C to stop watching" -Level Info
    Write-Host ""

    if (-not (Test-Path $OutputFolder)) {
        New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
    }

    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = $WatchFolder
    $watcher.Filter = "*.*"
    $watcher.IncludeSubdirectories = $false
    $watcher.EnableRaisingEvents = $true
    $watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor `
        [System.IO.NotifyFilters]::LastWrite

    $action = {
        $filePath = $Event.SourceEventArgs.FullPath
        $fileName = $Event.SourceEventArgs.Name
        $extension = [System.IO.Path]::GetExtension($filePath).ToLower()

        $supportedExtensions = @('.jpg', '.jpeg', '.png', '.webp', '.bmp', '.tiff', '.tif')

        if ($filePath -like "*\Processed\*") { return }

        if ($supportedExtensions -contains $extension) {
            Start-Sleep -Milliseconds 1000

            $retries = 0
            while ($retries -lt 10) {
                try {
                    $null = [System.IO.File]::Open(
                        $filePath, 'Open', 'Read', 'None'
                    ).Close()
                    break
                }
                catch {
                    $retries++
                    Start-Sleep -Milliseconds 500
                }
            }

            if ($retries -lt 10) {
                $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                Write-Host "[$timestamp] [Info] New image detected: $fileName" -ForegroundColor Cyan

                $baseName = [System.IO.Path]::GetFileNameWithoutExtension($filePath)
                $outputFile = Join-Path $Event.MessageData.OutputFolder "$baseName.png"

                $arguments = "i -m $($Event.MessageData.Model)"
                if ($Event.MessageData.AlphaMatting) {
                    $arguments += " -a -ae 15 -af 240"
                }
                $arguments += " `"$filePath`" `"$outputFile`""

                $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                $result = Start-Process -FilePath "rembg" `
                    -ArgumentList $arguments `
                    -Wait -NoNewWindow -PassThru
                $stopwatch.Stop()

                $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                if ($result.ExitCode -eq 0 -and (Test-Path $outputFile)) {
                    # Post-process if enabled
                    $ppStatus = ""
                    if (-not $Event.MessageData.NoPostProcess -and
                        $Event.MessageData.PostProcessScript) {
                        $ppArgs = @(
                            "`"$($Event.MessageData.PostProcessScript)`""
                            "`"$outputFile`""
                            "`"$outputFile`""
                            "--brightness"
                            $Event.MessageData.Brightness
                            "--contrast"
                            $Event.MessageData.Contrast
                            "--shadows"
                            $Event.MessageData.Shadows
                        )

                        if ($Event.MessageData.SpillColor -eq 'none') {
                            $ppArgs += "--no-spill"
                        }
                        else {
                            $ppArgs += "--spill-color"
                            $ppArgs += $Event.MessageData.SpillColor
                            $ppArgs += "--spill-strength"
                            $ppArgs += $Event.MessageData.SpillStrength
                        }

                        if ($Event.MessageData.NoStripMetadata) {
                            $ppArgs += "--no-strip-metadata"
                        }

                        $ppResult = Start-Process -FilePath "python" `
                            -ArgumentList ($ppArgs -join ' ') `
                            -Wait -NoNewWindow -PassThru

                        if ($ppResult.ExitCode -eq 0) {
                            $ppStatus = " [PP]"
                        }
                    }

                    # Move to processed folder
                    $moveStatus = ""
                    if (-not $Event.MessageData.NoMove) {
                        $processedFolder = $Event.MessageData.ProcessedFolder
                        if (-not (Test-Path $processedFolder)) {
                            New-Item -ItemType Directory -Path $processedFolder -Force | Out-Null
                        }
                        $destFile = Join-Path $processedFolder $fileName
                        if (Test-Path $destFile) {
                            $ts = Get-Date -Format "yyyyMMdd-HHmmss"
                            $bn = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
                            $ext = [System.IO.Path]::GetExtension($fileName)
                            $destFile = Join-Path $processedFolder "$bn-$ts$ext"
                        }
                        Move-Item -Path $filePath -Destination $destFile -Force
                        $moveStatus = " -> Moved to Processed"
                    }

                    $elapsed = $stopwatch.Elapsed.TotalSeconds.ToString('F1')
                    Write-Host "[$timestamp] [Success] Processed: $fileName -> $baseName.png [${elapsed}s]$ppStatus$moveStatus" -ForegroundColor Green

                    $logEntry = [PSCustomObject]@{
                        Timestamp      = $timestamp
                        SourceFile     = $filePath
                        OutputFile     = $outputFile
                        Status         = "Success"
                        ProcessingTime = [math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
                        Model          = $Event.MessageData.Model
                        PostProcessed  = ($ppStatus -ne "")
                    }
                    $logEntry | Export-Csv -Path $Event.MessageData.ReportFile `
                        -Append -NoTypeInformation
                }
                else {
                    Write-Host "[$timestamp] [Error] Failed to process: $fileName" -ForegroundColor Red
                }
            }
        }
    }

    $messageData = @{
        OutputFolder      = $OutputFolder
        Model             = $ModelName
        AlphaMatting      = $UseAlphaMatting.IsPresent
        NoMove            = $NoMove.IsPresent
        NoPostProcess     = $NoPostProcess.IsPresent
        NoStripMetadata   = $NoStripMetadata.IsPresent
        ProcessedFolder   = $script:ProcessedFolder
        ReportFile        = $script:ReportFile
        PostProcessScript = $script:PostProcessScript
        Brightness        = $Brightness.ToString()
        Contrast          = $Contrast.ToString()
        Shadows           = $Shadows.ToString()
        SpillColor        = $SpillColor
        SpillStrength     = $SpillStrength.ToString()
    }

    $created = Register-ObjectEvent -InputObject $watcher `
        -EventName Created -Action $action -MessageData $messageData

    try {
        $existingImages = Get-ChildItem -Path $WatchFolder -File |
            Where-Object {
                $script:SupportedExtensions -contains $_.Extension.ToLower() -and
                $_.DirectoryName -notlike "*\Processed*"
            }

        if ($existingImages.Count -gt 0) {
            Write-LogMessage "Processing $($existingImages.Count) existing image(s)..." -Level Info

            foreach ($image in $existingImages) {
                Process-ImageFile -InputFile $image.FullName `
                    -OutputFolder $OutputFolder `
                    -ModelName $ModelName `
                    -UseAlphaMatting:$UseAlphaMatting
            }

            Export-ProcessingReport
        }

        Write-LogMessage "Watching for new images... (Press Ctrl+C to stop)" -Level Info

        while ($true) {
            Start-Sleep -Seconds 1
        }
    }
    finally {
        Unregister-Event -SourceIdentifier $created.Name
        $watcher.EnableRaisingEvents = $false
        $watcher.Dispose()
        Write-LogMessage "File watcher stopped" -Level Info
        Export-ProcessingReport
    }
}

function Show-Summary {
    <#
    .SYNOPSIS
        Displays processing summary with post-processing statistics.
    #>
    $elapsed = (Get-Date) - $script:StartTime
    $elapsedFormatted = "{0:mm\:ss}" -f $elapsed

    $successResults = $script:ProcessingResults | Where-Object Status -eq 'Success'
    $totalSourceKB = ($successResults | Measure-Object -Property SourceSizeKB -Sum).Sum
    $totalOutputKB = ($successResults | Measure-Object -Property OutputSizeKB -Sum).Sum
    $avgProcessingTime = ($successResults | Measure-Object -Property ProcessingTime -Average).Average

    Write-Host ""
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-LogMessage "Processing Complete!" -Level Success
    Write-Host "  Processed successfully: $($script:ProcessedCount)" -ForegroundColor Green
    Write-Host "  Post-processed:         $($script:PostProcessedCount)" -ForegroundColor Green
    Write-Host "  Skipped (existing):     $($script:SkippedCount)" -ForegroundColor Yellow

    $errorColor = if ($script:ErrorCount -gt 0) { 'Red' } else { 'Green' }
    Write-Host "  Errors:                 $($script:ErrorCount)" -ForegroundColor $errorColor
    Write-Host "  Total elapsed time:     $elapsedFormatted" -ForegroundColor Cyan

    if ($script:ProcessedCount -gt 0) {
        Write-Host ""
        Write-Host "  Total source size:      $([math]::Round($totalSourceKB / 1024, 2)) MB" -ForegroundColor Gray
        Write-Host "  Total output size:      $([math]::Round($totalOutputKB / 1024, 2)) MB" -ForegroundColor Gray
        $avgTime = [math]::Round($avgProcessingTime, 1)
        Write-Host "  Avg processing time:    $avgTime seconds" -ForegroundColor Gray
    }

    if (-not $NoPostProcess) {
        Write-Host ""
        Write-Host "  Post-Processing Settings:" -ForegroundColor Gray
        Write-Host "    Brightness: $Brightness | Contrast: $Contrast | Shadows: $Shadows" -ForegroundColor Gray
        Write-Host "    Spill Color: $SpillColor | Strength: $SpillStrength" -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host "  Log file:    $($script:LogFile)" -ForegroundColor Gray
    Write-Host "  Report file: $($script:ReportFile)" -ForegroundColor Gray
    if (-not $NoMove) {
        Write-Host "  Processed folder: $($script:ProcessedFolder)" -ForegroundColor Gray
    }
    Write-Host "=" * 60 -ForegroundColor Cyan

    $summaryLines = @(
        ""
        "=" * 80
        "Processing Summary"
        "=" * 80
        "Completed: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "Processed: $($script:ProcessedCount)"
        "Post-Processed: $($script:PostProcessedCount)"
        "Skipped: $($script:SkippedCount)"
        "Errors: $($script:ErrorCount)"
        "Elapsed: $elapsedFormatted"
    )

    if (-not $NoPostProcess) {
        $summaryLines += "Post-Processing: brightness=$Brightness, contrast=$Contrast, shadows=$Shadows, spill=$SpillColor"
    }

    $summaryLines += "=" * 80

    $logSummary = $summaryLines -join "`r`n"
    Add-Content -Path $script:LogFile -Value $logSummary -Encoding UTF8
}

function Invoke-SEORename {
    <#
    .SYNOPSIS
        Standalone SEO rename mode. Reads a CSV mapping file and renames
        images with SEO-friendly filenames, optionally embedding alt text
        as PNG tEXt metadata.
    .DESCRIPTION
        CSV format: SourceFileName,SEOFileName,AltText
        Example: IMG_0001.png,check-valve-2-inch-abs-transparent.png,2 inch ABS check valve for plumbing
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$CSVPath,

        [Parameter(Mandatory = $true)]
        [string]$InputFolder,

        [Parameter()]
        [string]$OutputFolder,

        [Parameter()]
        [switch]$DoEmbedAltText
    )

    # Validate CSV exists
    if (-not (Test-Path $CSVPath)) {
        Write-Host "[Error] CSV file not found: $CSVPath" -ForegroundColor Red
        exit 1
    }

    # Validate input folder exists
    if (-not (Test-Path $InputFolder -PathType Container)) {
        Write-Host "[Error] Input folder not found: $InputFolder" -ForegroundColor Red
        exit 1
    }

    # Default output to a subfolder of input
    if ([string]::IsNullOrEmpty($OutputFolder)) {
        $OutputFolder = Join-Path $InputFolder "SEO-Renamed"
    }

    # Create output folder
    if (-not (Test-Path $OutputFolder)) {
        New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
    }

    Write-Host ""
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host "  Azure Innovators - SEO Rename Mode" -ForegroundColor White
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host ""

    # Import CSV
    try {
        $mappings = Import-Csv -Path $CSVPath -Encoding UTF8
    }
    catch {
        Write-Host "[Error] Failed to read CSV: $_" -ForegroundColor Red
        exit 1
    }

    # Validate required columns
    $csvColumns = $mappings[0].PSObject.Properties.Name
    $requiredColumns = @('SourceFileName', 'SEOFileName')
    foreach ($col in $requiredColumns) {
        if ($col -notin $csvColumns) {
            Write-Host "[Error] CSV missing required column: $col" -ForegroundColor Red
            Write-Host "Required columns: SourceFileName, SEOFileName" -ForegroundColor Yellow
            Write-Host "Optional columns: AltText" -ForegroundColor Yellow
            exit 1
        }
    }

    $hasAltText = 'AltText' -in $csvColumns

    if ($DoEmbedAltText -and -not $hasAltText) {
        Write-Host "[Warning] -EmbedAltText specified but CSV has no AltText column. Skipping alt text embedding." -ForegroundColor Yellow
        $DoEmbedAltText = $false
    }

    if ($DoEmbedAltText) {
        # Verify Python and Pillow are available for alt text embedding
        try {
            $result = & python -c "import PIL; print('OK')" 2>&1
            if ($result -ne 'OK') {
                Write-Host "[Warning] Pillow not available. Alt text embedding requires Pillow. Skipping." -ForegroundColor Yellow
                $DoEmbedAltText = $false
            }
        }
        catch {
            Write-Host "[Warning] Python not available. Alt text embedding requires Python + Pillow. Skipping." -ForegroundColor Yellow
            $DoEmbedAltText = $false
        }
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [Info] CSV: $CSVPath ($($mappings.Count) entries)" -ForegroundColor Cyan
    Write-Host "[$timestamp] [Info] Input: $InputFolder" -ForegroundColor Cyan
    Write-Host "[$timestamp] [Info] Output: $OutputFolder" -ForegroundColor Cyan
    if ($DoEmbedAltText) {
        Write-Host "[$timestamp] [Info] Alt text embedding: Enabled" -ForegroundColor Cyan
    }
    Write-Host ""

    $renamed = 0
    $skipped = 0
    $errors = 0
    $results = [System.Collections.ArrayList]::new()

    foreach ($mapping in $mappings) {
        $sourceName = $mapping.SourceFileName.Trim()
        $seoName = $mapping.SEOFileName.Trim()
        $altText = if ($hasAltText) { $mapping.AltText.Trim() } else { "" }

        # Sanitize SEO filename
        $seoName = $seoName.ToLower()
        $seoName = $seoName -replace '[\s_]+', '-'
        $seoName = $seoName -replace '[^a-z0-9\-\.]', ''
        $seoName = $seoName -replace '-{2,}', '-'
        $seoName = $seoName.Trim('-')

        # Ensure it has an extension
        if (-not [System.IO.Path]::HasExtension($seoName)) {
            $sourceExt = [System.IO.Path]::GetExtension($sourceName)
            $seoName = "$seoName$sourceExt"
        }

        $sourcePath = Join-Path $InputFolder $sourceName
        $destPath = Join-Path $OutputFolder $seoName

        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

        if (-not (Test-Path $sourcePath)) {
            Write-Host "[$timestamp] [Warning] Source not found: $sourceName" -ForegroundColor Yellow
            $skipped++
            $null = $results.Add([PSCustomObject]@{
                SourceFileName = $sourceName
                SEOFileName    = $seoName
                AltText        = $altText
                Status         = "Skipped"
                Reason         = "Source file not found"
            })
            continue
        }

        if (Test-Path $destPath) {
            Write-Host "[$timestamp] [Warning] Destination exists, skipping: $seoName" -ForegroundColor Yellow
            $skipped++
            $null = $results.Add([PSCustomObject]@{
                SourceFileName = $sourceName
                SEOFileName    = $seoName
                AltText        = $altText
                Status         = "Skipped"
                Reason         = "Destination file already exists"
            })
            continue
        }

        try {
            # Copy with new name
            Copy-Item -Path $sourcePath -Destination $destPath -Force

            # Embed alt text as PNG tEXt chunk if requested
            $altStatus = ""
            if ($DoEmbedAltText -and $altText -and
                [System.IO.Path]::GetExtension($destPath).ToLower() -eq '.png') {

                $escapedPath = $destPath -replace "'", "''"
                $escapedAlt = $altText -replace "'", "''"
                $pyCode = @(
                    "from PIL import Image"
                    "from PIL.PngImagePlugin import PngInfo"
                    "img = Image.open('$escapedPath')"
                    "meta = PngInfo()"
                    "meta.add_text('Alt', '$escapedAlt')"
                    "meta.add_text('Description', '$escapedAlt')"
                    "meta.add_text('Comment', '$escapedAlt')"
                    "img.save('$escapedPath', pnginfo=meta)"
                ) -join "; "

                $pyResult = & python -c $pyCode 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $altStatus = " [Alt: embedded]"
                }
                else {
                    $altStatus = " [Alt: failed]"
                }
            }

            Write-Host "[$timestamp] [Success] $sourceName -> $seoName$altStatus" -ForegroundColor Green
            $renamed++
            $null = $results.Add([PSCustomObject]@{
                SourceFileName = $sourceName
                SEOFileName    = $seoName
                AltText        = $altText
                Status         = "Renamed"
                Reason         = ""
            })
        }
        catch {
            Write-Host "[$timestamp] [Error] Failed: $sourceName -> $seoName ($_)" -ForegroundColor Red
            $errors++
            $null = $results.Add([PSCustomObject]@{
                SourceFileName = $sourceName
                SEOFileName    = $seoName
                AltText        = $altText
                Status         = "Failed"
                Reason         = $_.ToString()
            })
        }
    }

    # Export report
    $reportPath = Join-Path $OutputFolder "SEO-Rename-Report.csv"
    try {
        $results | Export-Csv -Path $reportPath -NoTypeInformation -Encoding UTF8
    }
    catch {
        Write-Host "[Warning] Failed to save report: $_" -ForegroundColor Yellow
    }

    # Summary
    Write-Host ""
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host "  Rename Complete!" -ForegroundColor Green
    Write-Host "  Renamed:  $renamed" -ForegroundColor Green
    Write-Host "  Skipped:  $skipped" -ForegroundColor Yellow
    $errorColor = if ($errors -gt 0) { 'Red' } else { 'Green' }
    Write-Host "  Errors:   $errors" -ForegroundColor $errorColor
    Write-Host "  Output:   $OutputFolder" -ForegroundColor Gray
    Write-Host "  Report:   $reportPath" -ForegroundColor Gray
    Write-Host "=" * 60 -ForegroundColor Cyan
}

#endregion

#region Main Execution

# Handle install mode
if ($InstallRembg) {
    Write-Host ""
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host "  Azure Innovators - Background Remover Setup v2.1" -ForegroundColor White
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host ""

    if (-not (Test-PythonInstalled)) {
        Write-LogMessage "Please install Python 3.10+ first using:" -Level Info
        Write-Host "  winget install Python.Python.3.12" -ForegroundColor Yellow
        exit 1
    }

    if (Install-Rembg) {
        Write-Host ""
        Write-LogMessage "Setup complete! You can now use the script to process images." -Level Success
        Write-Host ""
        Write-Host "Examples:" -ForegroundColor Cyan
        Write-Host "  # Basic processing with post-processing" -ForegroundColor Gray
        Write-Host "  .\Process-ProductPics.ps1 -InputPath 'C:\Photos' -OutputPath 'C:\Processed'" -ForegroundColor White
        Write-Host ""
        Write-Host "  # With SEO naming for e-commerce" -ForegroundColor Gray
        Write-Host "  .\Process-ProductPics.ps1 -InputPath 'C:\Photos\valve.jpg' -OutputPath 'C:\Ready' -SEOName 'check valve 2 inch' -SEOPrefix 'jt-custom'" -ForegroundColor White
        Write-Host ""
        Write-Host "  # Watch mode with blue screen" -ForegroundColor Gray
        Write-Host "  .\Process-ProductPics.ps1 -InputPath 'C:\Watch' -OutputPath 'C:\Ready' -Watch -SpillColor blue" -ForegroundColor White
    }
    exit 0
}

# Handle rename mode
if ($RenameCSV) {
    $RenameInputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RenameInputPath)
    $RenameCSV = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RenameCSV)

    $renameOutPath = if ($RenameOutputPath) {
        $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RenameOutputPath)
    }
    else { "" }

    Invoke-SEORename -CSVPath $RenameCSV `
        -InputFolder $RenameInputPath `
        -OutputFolder $renameOutPath `
        -DoEmbedAltText:$EmbedAltText
    exit 0
}

# Validate rembg is installed
if (-not (Test-RembgInstalled)) {
    Write-LogMessage "rembg is not installed. Run with -InstallRembg to install it." -Level Error
    Write-Host "  .\Process-ProductPics.ps1 -InstallRembg" -ForegroundColor Yellow
    exit 1
}

# Display header
Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "  Azure Innovators - AI Background Remover v2.1" -ForegroundColor White
Write-Host "  Powered by rembg + Pillow post-processing" -ForegroundColor Gray
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""

# Validate input path
$InputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InputPath)
$OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)

if (-not (Test-Path $InputPath)) {
    Write-LogMessage "Input path does not exist: $InputPath" -Level Error
    exit 1
}

# Initialize logging
Initialize-Logging -BasePath $InputPath

# Initialize post-processing if enabled
if (-not $NoPostProcess) {
    $ppReady = Initialize-PostProcessing
    if (-not $ppReady) {
        Write-LogMessage "Post-processing initialization failed. Use -NoPostProcess to skip, or fix the issue above." -Level Error
        exit 1
    }
}

# Load SEO mapping file if specified
if ($SEOMappingFile) {
    $mappingLoaded = Import-SEOMappings -MappingFile $SEOMappingFile
    if (-not $mappingLoaded) {
        Write-LogMessage "Failed to load SEO mappings. Continuing with default naming." -Level Warning
    }
}

# Handle watch mode
if ($Watch) {
    if (-not (Test-Path $InputPath -PathType Container)) {
        Write-LogMessage "Watch mode requires InputPath to be a folder" -Level Error
        exit 1
    }

    Start-ImageWatcher -WatchFolder $InputPath `
        -OutputFolder $OutputPath `
        -ModelName $Model `
        -UseAlphaMatting:$AlphaMatting
}
# Handle single file
elseif (Test-Path $InputPath -PathType Leaf) {
    $extension = [System.IO.Path]::GetExtension($InputPath).ToLower()

    if ($script:SupportedExtensions -notcontains $extension) {
        Write-LogMessage "Unsupported file format: $extension" -Level Error
        Write-LogMessage "Supported formats: $($script:SupportedExtensions -join ', ')" -Level Info
        exit 1
    }

    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    Process-ImageFile -InputFile $InputPath `
        -OutputFolder $OutputPath `
        -ModelName $Model `
        -UseAlphaMatting:$AlphaMatting

    Export-ProcessingReport
    Show-Summary
}
# Handle folder
else {
    Process-ImageFolder -InputFolder $InputPath `
        -OutputFolder $OutputPath `
        -ModelName $Model `
        -UseAlphaMatting:$AlphaMatting `
        -ProcessRecursive:$Recursive

    Export-ProcessingReport
    Show-Summary
}

#endregion
