<#
.SYNOPSIS
    Lokalise .resx file synchronization script for .NET projects.

.DESCRIPTION
    Uploads neutral .resx files to Lokalise, triggers machine translation for missing
    translations, and downloads locale-specific .resx files.

.EXAMPLE
    .\lokalise-resx.ps1 -ProjectId "your-project-id"

.EXAMPLE
    .\lokalise-resx.ps1 -ProjectId "your-project-id" -Locales @("fr-CA", "es-MX") -VerboseLogging

.EXAMPLE
    .\lokalise-resx.ps1 -ProjectId "your-project-id" -DryRun
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$RootPath = (Get-Location).Path,

    [Parameter(Mandatory = $true)]
    [string]$ProjectId,

    [Parameter(Mandatory = $false)]
    [string]$ApiToken,

    [Parameter(Mandatory = $false)]
    [string[]]$Locales,

    [Parameter(Mandatory = $false)]
    [int]$TimeoutMinutes = 10,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [switch]$VerboseLogging
)

#region ============== CONFIGURATION CONSTANTS ==============
# HARDCODED API TOKEN - Replace with your Lokalise API token
$script:DEFAULT_API_TOKEN = "YOUR_LOKALISE_API_TOKEN_HERE"

# DEFAULT TARGET LOCALES - Modify this list as needed
$script:DEFAULT_LOCALES = @(
    "fr-CA",
    "es-MX",
    "de-DE",
    "ja-JP",
    "zh-Hans"
)

# API BASE URL
$script:LOKALISE_API_BASE = "https://api.lokalise.com/api2"

# EXCLUDED FOLDERS
$script:EXCLUDED_FOLDERS = @(".git", "bin", "obj", "packages")

# LOCALE PATTERN - Matches files like *.en.resx, *.fr-CA.resx
$script:LOCALE_PATTERN = "^.+\.([a-z]{2}(-[a-zA-Z]{2,4})?|[a-z]{2}-[A-Z][a-z]{3})\.resx$"
#endregion

#region ============== GLOBAL STATE ==============
$script:Stats = @{
    NeutralFilesFound = 0
    FilesUploaded = 0
    LocalesProcessed = 0
    FilesCreated = 0
    FilesUpdated = 0
    Failures = [System.Collections.ArrayList]::new()
}
#endregion

#region ============== LOGGING FUNCTIONS ==============
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS", "DEBUG")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "INFO"    { "White" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        "SUCCESS" { "Green" }
        "DEBUG"   { "Cyan" }
    }

    if ($Level -eq "DEBUG" -and -not $VerboseLogging) {
        return
    }

    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Write-LogError {
    param([string]$Message, [string]$Context = "")
    Write-Log -Message $Message -Level "ERROR"
    [void]$script:Stats.Failures.Add(@{ Context = $Context; Message = $Message })
}
#endregion

#region ============== API HELPER FUNCTIONS ==============
function Get-ApiHeaders {
    param([string]$Token)

    return @{
        "X-Api-Token" = $Token
        "Content-Type" = "application/json"
    }
}

function Invoke-LokaliseApi {
    param(
        [string]$Endpoint,
        [string]$Method = "GET",
        [object]$Body = $null,
        [string]$Token,
        [string]$ContentType = "application/json"
    )

    $uri = "$script:LOKALISE_API_BASE$Endpoint"
    $headers = Get-ApiHeaders -Token $Token
    $headers["Content-Type"] = $ContentType

    $params = @{
        Uri = $uri
        Method = $Method
        Headers = $headers
        ErrorAction = "Stop"
    }

    if ($Body -and $Method -ne "GET") {
        if ($ContentType -eq "application/json") {
            $params.Body = ($Body | ConvertTo-Json -Depth 10 -Compress)
        } else {
            $params.Body = $Body
        }
    }

    Write-Log -Message "API $Method $Endpoint" -Level "DEBUG"

    try {
        $response = Invoke-RestMethod @params
        return $response
    }
    catch {
        $errorMessage = $_.Exception.Message
        if ($_.ErrorDetails.Message) {
            try {
                $errorDetails = $_.ErrorDetails.Message | ConvertFrom-Json
                $errorMessage = $errorDetails.error.message
            } catch {
                $errorMessage = $_.ErrorDetails.Message
            }
        }
        throw "API Error: $errorMessage"
    }
}
#endregion

#region ============== FILE DISCOVERY ==============
function Find-NeutralResxFiles {
    param([string]$RootPath)

    Write-Log -Message "Scanning for neutral .resx files in: $RootPath" -Level "INFO"

    $allResxFiles = Get-ChildItem -Path $RootPath -Filter "*.resx" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $relativePath = $_.FullName.Substring($RootPath.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
            $pathParts = $relativePath -split [regex]::Escape([IO.Path]::DirectorySeparatorChar)

            # Check if any folder in path is excluded
            $isExcluded = $false
            foreach ($part in $pathParts) {
                if ($script:EXCLUDED_FOLDERS -contains $part) {
                    $isExcluded = $true
                    break
                }
            }
            -not $isExcluded
        }

    # Filter out locale-specific files
    $neutralFiles = $allResxFiles | Where-Object {
        $_.Name -notmatch $script:LOCALE_PATTERN
    }

    $script:Stats.NeutralFilesFound = $neutralFiles.Count

    Write-Log -Message "Found $($neutralFiles.Count) neutral .resx file(s)" -Level "INFO"

    if ($VerboseLogging) {
        foreach ($file in $neutralFiles) {
            $relativePath = $file.FullName.Substring($RootPath.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
            Write-Log -Message "  - $relativePath" -Level "DEBUG"
        }
    }

    return $neutralFiles
}
#endregion

#region ============== LOCALE VALIDATION ==============
function Get-ProjectLanguages {
    param([string]$ProjectId, [string]$Token)

    Write-Log -Message "Fetching project languages from Lokalise..." -Level "INFO"

    if ($DryRun) {
        Write-Log -Message "[DRY RUN] Would fetch project languages" -Level "DEBUG"
        return @()
    }

    try {
        $response = Invoke-LokaliseApi -Endpoint "/projects/$ProjectId/languages" -Token $Token
        $languages = $response.languages | ForEach-Object { $_.lang_iso }
        Write-Log -Message "Project has $($languages.Count) language(s) configured" -Level "DEBUG"
        return $languages
    }
    catch {
        throw "Failed to fetch project languages: $_"
    }
}

function Test-LocalesValid {
    param(
        [string[]]$RequestedLocales,
        [string[]]$ProjectLocales
    )

    Write-Log -Message "Validating requested locales..." -Level "INFO"

    $invalidLocales = @()
    foreach ($locale in $RequestedLocales) {
        if ($locale -notin $ProjectLocales) {
            $invalidLocales += $locale
        }
    }

    if ($invalidLocales.Count -gt 0) {
        Write-Log -Message "VALIDATION FAILED: Invalid locale(s) detected" -Level "ERROR"
        Write-Log -Message "Invalid locales: $($invalidLocales -join ', ')" -Level "ERROR"
        Write-Log -Message "Supported locales in Lokalise project:" -Level "INFO"
        foreach ($locale in $ProjectLocales | Sort-Object) {
            Write-Host "  - $locale" -ForegroundColor Cyan
        }
        return $false
    }

    Write-Log -Message "All $($RequestedLocales.Count) locale(s) are valid" -Level "SUCCESS"
    return $true
}
#endregion

#region ============== FILE UPLOAD ==============
function Upload-ResxFile {
    param(
        [System.IO.FileInfo]$File,
        [string]$RootPath,
        [string]$ProjectId,
        [string]$Token
    )

    $relativePath = $File.FullName.Substring($RootPath.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
    # Normalize to forward slashes for Lokalise
    $lokaliseFilename = $relativePath -replace '\\', '/'

    Write-Log -Message "Uploading: $relativePath" -Level "INFO"

    if ($DryRun) {
        Write-Log -Message "[DRY RUN] Would upload: $relativePath" -Level "DEBUG"
        $script:Stats.FilesUploaded++
        return $true
    }

    try {
        # Read file content and convert to Base64
        $fileBytes = [System.IO.File]::ReadAllBytes($File.FullName)
        $base64Content = [Convert]::ToBase64String($fileBytes)

        $body = @{
            data = $base64Content
            filename = $lokaliseFilename
            lang_iso = "en"  # Source language
            convert_placeholders = $false
            replace_modified = $false
            skip_detect_lang = $true
            tags = @("auto-upload")
            tag_inserted_keys = $true
            tag_updated_keys = $true
        }

        $response = Invoke-LokaliseApi -Endpoint "/projects/$ProjectId/files/upload" -Method "POST" -Body $body -Token $Token

        # Check if upload was queued (async) or completed
        if ($response.process) {
            Write-Log -Message "Upload queued (Process ID: $($response.process.process_id))" -Level "DEBUG"
            # Wait for upload to complete
            $processComplete = Wait-ForProcess -ProjectId $ProjectId -ProcessId $response.process.process_id -Token $Token
            if (-not $processComplete) {
                throw "Upload process did not complete in time"
            }
        }

        $script:Stats.FilesUploaded++
        Write-Log -Message "Uploaded successfully: $relativePath" -Level "SUCCESS"
        return $true
    }
    catch {
        Write-LogError -Message "Failed to upload $relativePath`: $_" -Context "Upload"
        return $false
    }
}

function Wait-ForProcess {
    param(
        [string]$ProjectId,
        [string]$ProcessId,
        [string]$Token,
        [int]$TimeoutSeconds = 300
    )

    $startTime = Get-Date
    $pollInterval = 2

    while ((Get-Date) -lt $startTime.AddSeconds($TimeoutSeconds)) {
        try {
            $response = Invoke-LokaliseApi -Endpoint "/projects/$ProjectId/processes/$ProcessId" -Token $Token

            if ($response.process.status -eq "finished") {
                return $true
            }
            elseif ($response.process.status -eq "failed") {
                Write-Log -Message "Process failed: $($response.process.message)" -Level "ERROR"
                return $false
            }

            Start-Sleep -Seconds $pollInterval
        }
        catch {
            Write-Log -Message "Error checking process status: $_" -Level "WARN"
            Start-Sleep -Seconds $pollInterval
        }
    }

    Write-Log -Message "Process timed out after $TimeoutSeconds seconds" -Level "WARN"
    return $false
}
#endregion

#region ============== MACHINE TRANSLATION ==============
function Invoke-MachineTranslation {
    param(
        [string]$ProjectId,
        [string[]]$Locales,
        [string]$Token
    )

    Write-Log -Message "Triggering machine translation for missing translations..." -Level "INFO"

    if ($DryRun) {
        Write-Log -Message "[DRY RUN] Would trigger MT for locales: $($Locales -join ', ')" -Level "DEBUG"
        return $true
    }

    $success = $true

    foreach ($locale in $Locales) {
        Write-Log -Message "Triggering MT for locale: $locale" -Level "INFO"

        try {
            # Get all keys that need translation for this locale
            $body = @{
                use_translation_memory = $true
                # Only translate keys without translations (missing)
            }

            # Trigger MT for all keys - Lokalise will only translate missing ones
            $mtBody = @{
                keys = @()  # Empty means all keys
                language_iso = $locale
                pre_translate_mode = "missing_only"  # Only missing translations
            }

            # Use bulk machine translate endpoint
            $response = Invoke-LokaliseApi -Endpoint "/projects/$ProjectId/keys/bulk/machine-translate" -Method "POST" -Body $mtBody -Token $Token

            if ($response.process) {
                Write-Log -Message "MT queued for $locale (Process ID: $($response.process.process_id))" -Level "DEBUG"
                $processComplete = Wait-ForProcess -ProjectId $ProjectId -ProcessId $response.process.process_id -Token $Token -TimeoutSeconds ($TimeoutMinutes * 60)
                if (-not $processComplete) {
                    Write-Log -Message "MT process for $locale did not complete in time" -Level "WARN"
                    $success = $false
                }
            }

            Write-Log -Message "MT completed for locale: $locale" -Level "SUCCESS"
        }
        catch {
            Write-Log -Message "MT failed for locale $locale`: $_" -Level "WARN"
            # Don't fail entirely - MT is optional enhancement
        }
    }

    return $success
}
#endregion

#region ============== FILE EXPORT AND DOWNLOAD ==============
function Export-LocaleFiles {
    param(
        [string]$ProjectId,
        [string]$Locale,
        [string]$Token
    )

    Write-Log -Message "Requesting export for locale: $Locale" -Level "INFO"

    if ($DryRun) {
        Write-Log -Message "[DRY RUN] Would export locale: $Locale" -Level "DEBUG"
        return $null
    }

    try {
        $body = @{
            format = "resx"
            original_filenames = $true
            directory_prefix = ""
            filter_langs = @($Locale)
            replace_breaks = $false
            include_comments = $true
            include_description = $true
            export_empty_as = "skip"
        }

        $response = Invoke-LokaliseApi -Endpoint "/projects/$ProjectId/files/download" -Method "POST" -Body $body -Token $Token

        if ($response.bundle_url) {
            Write-Log -Message "Export bundle ready for $Locale" -Level "DEBUG"
            return $response.bundle_url
        }
        else {
            throw "No bundle URL returned"
        }
    }
    catch {
        throw "Export failed for locale $Locale`: $_"
    }
}

function Download-AndExtractBundle {
    param(
        [string]$BundleUrl,
        [string]$Locale,
        [string]$RootPath,
        [System.IO.FileInfo[]]$NeutralFiles
    )

    Write-Log -Message "Downloading bundle for locale: $Locale" -Level "INFO"

    $tempZipPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "lokalise_$Locale`_$(Get-Date -Format 'yyyyMMddHHmmss').zip")
    $tempExtractPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "lokalise_$Locale`_$(Get-Date -Format 'yyyyMMddHHmmss')")

    try {
        # Download the zip file
        Invoke-WebRequest -Uri $BundleUrl -OutFile $tempZipPath -ErrorAction Stop
        Write-Log -Message "Bundle downloaded: $tempZipPath" -Level "DEBUG"

        # Extract the zip file
        if (Test-Path $tempExtractPath) {
            Remove-Item $tempExtractPath -Recurse -Force
        }

        [System.IO.Compression.ZipFile]::ExtractToDirectory($tempZipPath, $tempExtractPath)
        Write-Log -Message "Bundle extracted to: $tempExtractPath" -Level "DEBUG"

        # Process extracted files
        $extractedFiles = Get-ChildItem -Path $tempExtractPath -Filter "*.resx" -Recurse -File

        foreach ($extractedFile in $extractedFiles) {
            Process-ExtractedFile -ExtractedFile $extractedFile -Locale ${Locale} -RootPath $RootPath -NeutralFiles $NeutralFiles -ExtractPath $tempExtractPath
        }

        $script:Stats.LocalesProcessed++
    }
    catch {
        Write-LogError -Message "Failed to download/extract bundle for ${Locale}: $_" -Context "Download"
    }
    finally {
        # Cleanup temp files
        if (Test-Path $tempZipPath) {
            Remove-Item $tempZipPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $tempExtractPath) {
            Remove-Item $tempExtractPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-ResxKeysComplete {
    param(
        [string]$NeutralFilePath,
        [string]$LocalizedFilePath,
        [string]$Locale
    )

    try {
        $neutralXml = [xml](Get-Content -Path $NeutralFilePath -Raw)
        $localizedXml = [xml](Get-Content -Path $LocalizedFilePath -Raw)

        $neutralKeys = @($neutralXml.root.data | Where-Object { $_.name } | ForEach-Object { $_.name })
        $localizedKeys = @($localizedXml.root.data | Where-Object { $_.name } | ForEach-Object { $_.name })

        $missingKeys = $neutralKeys | Where-Object { $_ -notin $localizedKeys }

        if ($missingKeys.Count -gt 0) {
            Write-LogError -Message "Missing keys for locale $Locale: $($missingKeys -join ', ')" -Context "KeyCheck"
            return $false
        }

        return $true
    }
    catch {
        Write-LogError -Message "Failed to validate keys for locale $Locale`: $_" -Context "KeyCheck"
        return $false
    }
}

function Process-ExtractedFile {
    param(
        [System.IO.FileInfo]$ExtractedFile,
        [string]$Locale,
        [string]$RootPath,
        [System.IO.FileInfo[]]$NeutralFiles,
        [string]$ExtractPath
    )

    # Get the relative path from the extract directory
    $relativeFromExtract = $ExtractedFile.FullName.Substring($ExtractPath.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
    # Normalize separators
    $relativeFromExtract = $relativeFromExtract -replace '/', [IO.Path]::DirectorySeparatorChar

    # Find matching neutral file
    $matchingNeutral = $null
    foreach ($neutralFile in $NeutralFiles) {
        $neutralRelative = $neutralFile.FullName.Substring($RootPath.Length).TrimStart([IO.Path]::DirectorySeparatorChar)

        # Check if the extracted file matches this neutral file path
        if ($relativeFromExtract -eq $neutralRelative -or
            $ExtractedFile.Name -eq $neutralFile.Name) {
            $matchingNeutral = $neutralFile
            break
        }
    }

    if (-not $matchingNeutral) {
        Write-Log -Message "No matching neutral file for: $relativeFromExtract" -Level "DEBUG"
        return
    }

    if (-not (Test-ResxKeysComplete -NeutralFilePath $matchingNeutral.FullName -LocalizedFilePath $ExtractedFile.FullName -Locale $Locale)) {
        Write-Log -Message "Skipping write for $($matchingNeutral.Name) in locale $Locale due to missing keys" -Level "WARN"
        return
    }

    # Compute destination filename
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($matchingNeutral.Name)
    $destFileName = "$baseName.$Locale.resx"
    $destPath = [System.IO.Path]::Combine($matchingNeutral.DirectoryName, $destFileName)

    # Read extracted file content
    $newContent = [System.IO.File]::ReadAllBytes($ExtractedFile.FullName)

    # Compare with existing file if it exists
    $shouldWrite = $true
    $isUpdate = $false

    if (Test-Path $destPath) {
        $existingContent = [System.IO.File]::ReadAllBytes($destPath)
        $existingHash = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($existingContent))
        $newHash = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($newContent))

        if ($existingHash -eq $newHash) {
            Write-Log -Message "No changes for: $destFileName" -Level "DEBUG"
            $shouldWrite = $false
        }
        else {
            $isUpdate = $true
        }
    }

    if ($shouldWrite) {
        if ($DryRun) {
            $action = if ($isUpdate) { "update" } else { "create" }
            Write-Log -Message "[DRY RUN] Would $action`: $destPath" -Level "DEBUG"
        }
        else {
            # Write with UTF-8 BOM (typical for .resx files)
            $utf8BOM = [System.Text.Encoding]::UTF8.GetPreamble()

            # Check if content already has BOM
            $hasBom = $false
            if ($newContent.Length -ge 3) {
                $hasBom = ($newContent[0] -eq 0xEF -and $newContent[1] -eq 0xBB -and $newContent[2] -eq 0xBF)
            }

            if (-not $hasBom) {
                $contentWithBom = $utf8BOM + $newContent
                [System.IO.File]::WriteAllBytes($destPath, $contentWithBom)
            }
            else {
                [System.IO.File]::WriteAllBytes($destPath, $newContent)
            }

            Write-Log -Message "Written: $destFileName" -Level "SUCCESS"
        }

        if ($isUpdate) {
            $script:Stats.FilesUpdated++
        }
        else {
            $script:Stats.FilesCreated++
        }
    }
}

function Export-WithExponentialBackoff {
    param(
        [string]$ProjectId,
        [string]$Locale,
        [string]$Token,
        [int]$TimeoutMinutes
    )

    $startTime = Get-Date
    $pollInterval = 5  # Start at 5 seconds
    $maxPollInterval = 30  # Max 30 seconds
    $timeoutTime = $startTime.AddMinutes($TimeoutMinutes)

    while ((Get-Date) -lt $timeoutTime) {
        try {
            $bundleUrl = Export-LocaleFiles -ProjectId $ProjectId -Locale $Locale -Token $Token
            return $bundleUrl
        }
        catch {
            $errorMessage = $_.Exception.Message

            # Check if it's a rate limit or temporary error
            if ($errorMessage -match "rate" -or $errorMessage -match "429" -or $errorMessage -match "too many") {
                Write-Log -Message "Rate limited, waiting $pollInterval seconds..." -Level "WARN"
                Start-Sleep -Seconds $pollInterval

                # Exponential backoff
                $pollInterval = [Math]::Min($pollInterval * 2, $maxPollInterval)
            }
            else {
                throw
            }
        }
    }

    throw "Export timed out after $TimeoutMinutes minutes"
}
#endregion

#region ============== MAIN EXECUTION ==============
function Show-Summary {
    Write-Host ""
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host "                    EXECUTION SUMMARY" -ForegroundColor Cyan
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Neutral .resx files found:    $($script:Stats.NeutralFilesFound)" -ForegroundColor White
    Write-Host "  Files uploaded:               $($script:Stats.FilesUploaded)" -ForegroundColor White
    Write-Host "  Locales processed:            $($script:Stats.LocalesProcessed)" -ForegroundColor White
    Write-Host "  Localized files created:      $($script:Stats.FilesCreated)" -ForegroundColor Green
    Write-Host "  Localized files updated:      $($script:Stats.FilesUpdated)" -ForegroundColor Yellow
    Write-Host "  Failures:                     $($script:Stats.Failures.Count)" -ForegroundColor $(if ($script:Stats.Failures.Count -gt 0) { "Red" } else { "Green" })

    if ($script:Stats.Failures.Count -gt 0) {
        Write-Host ""
        Write-Host "  Failure Details:" -ForegroundColor Red
        foreach ($failure in $script:Stats.Failures) {
            Write-Host "    - [$($failure.Context)] $($failure.Message)" -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host "=" * 60 -ForegroundColor Cyan
}

function Main {
    Write-Host ""
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host "       LOKALISE .RESX SYNCHRONIZATION SCRIPT" -ForegroundColor Cyan
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host ""

    if ($DryRun) {
        Write-Log -Message "DRY RUN MODE - No changes will be made" -Level "WARN"
    }

    # Resolve root path
    $RootPath = (Resolve-Path $RootPath).Path
    Write-Log -Message "Root path: $RootPath" -Level "INFO"

    # Determine API token
    $effectiveToken = if ($ApiToken) { $ApiToken } else { $script:DEFAULT_API_TOKEN }
    if ($effectiveToken -eq "YOUR_LOKALISE_API_TOKEN_HERE") {
        Write-Log -Message "API token not configured. Please set the DEFAULT_API_TOKEN constant or use -ApiToken parameter." -Level "ERROR"
        exit 1
    }

    # Determine target locales
    $targetLocales = if ($Locales -and $Locales.Count -gt 0) { $Locales } else { $script:DEFAULT_LOCALES }
    Write-Log -Message "Target locales: $($targetLocales -join ', ')" -Level "INFO"

    # Step 1: Find neutral .resx files
    Write-Host ""
    Write-Log -Message "STEP 1: Discovering neutral .resx files..." -Level "INFO"
    $neutralFiles = Find-NeutralResxFiles -RootPath $RootPath

    if ($neutralFiles.Count -eq 0) {
        Write-Log -Message "No neutral .resx files found. Nothing to do." -Level "WARN"
        Show-Summary
        exit 0
    }

    # Step 2: Validate locales
    Write-Host ""
    Write-Log -Message "STEP 2: Validating locales..." -Level "INFO"

    if (-not $DryRun) {
        $projectLocales = Get-ProjectLanguages -ProjectId $ProjectId -Token $effectiveToken

        if ($projectLocales.Count -eq 0) {
            Write-Log -Message "No languages configured in Lokalise project or failed to fetch." -Level "WARN"
            Write-Log -Message "Proceeding with requested locales..." -Level "INFO"
        }
        else {
            $valid = Test-LocalesValid -RequestedLocales $targetLocales -ProjectLocales $projectLocales
            if (-not $valid) {
                Write-Log -Message "Execution stopped due to invalid locales." -Level "ERROR"
                exit 1
            }
        }
    }
    else {
        Write-Log -Message "[DRY RUN] Would validate locales: $($targetLocales -join ', ')" -Level "DEBUG"
    }

    # Step 3: Upload files
    Write-Host ""
    Write-Log -Message "STEP 3: Uploading neutral .resx files..." -Level "INFO"

    foreach ($file in $neutralFiles) {
        $uploaded = Upload-ResxFile -File $file -RootPath $RootPath -ProjectId $ProjectId -Token $effectiveToken
    }

    # Step 4: Trigger Machine Translation
    Write-Host ""
    Write-Log -Message "STEP 4: Triggering machine translation..." -Level "INFO"
    Invoke-MachineTranslation -ProjectId $ProjectId -Locales $targetLocales -Token $effectiveToken

    # Step 5: Export and download for each locale
    Write-Host ""
    Write-Log -Message "STEP 5: Exporting and downloading localized files..." -Level "INFO"

    # Add required assembly for zip handling
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    foreach ($locale in $targetLocales) {
        try {
            $bundleUrl = Export-WithExponentialBackoff -ProjectId $ProjectId -Locale $locale -Token $effectiveToken -TimeoutMinutes $TimeoutMinutes

            if ($bundleUrl) {
                Download-AndExtractBundle -BundleUrl $bundleUrl -Locale $locale -RootPath $RootPath -NeutralFiles $neutralFiles
            }
        }
        catch {
            Write-LogError -Message "Failed to process locale $locale`: $_" -Context "Export/Download"
        }
    }

    # Show summary
    Show-Summary

    # Exit with appropriate code
    if ($script:Stats.Failures.Count -gt 0) {
        exit 1
    }
    exit 0
}

# Run main
Main
#endregion
