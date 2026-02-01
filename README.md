# Lokalise .resx Synchronization Script

A lightweight PowerShell wrapper script for uploading .NET `.resx` resource files to Lokalise and downloading translated locale-specific files.

## Features

- Recursive discovery of neutral `.resx` files
- Automatic locale validation against Lokalise project
- Machine translation for missing translations (preserves human translations)
- Exponential backoff polling for exports
- Content-aware writes (only updates changed files)
- Dry run mode for safe testing
- Detailed logging with verbose option

## Quick Start

### 1. Configure the Script

Open `lokalise-resx.ps1` and set the following constants near the top of the file:

```powershell
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
```

### 2. Run the Script

```powershell
# Basic usage (requires ProjectId)
.\lokalise-resx.ps1 -ProjectId "your-project-id-here"

# With custom locales
.\lokalise-resx.ps1 -ProjectId "abc123.456" -Locales @("fr-CA", "es-MX")

# Dry run (no API calls or file writes)
.\lokalise-resx.ps1 -ProjectId "abc123.456" -DryRun

# Verbose logging
.\lokalise-resx.ps1 -ProjectId "abc123.456" -VerboseLogging
```

## Configuration

### API Token

The API token can be configured in two ways:

1. **Hardcoded (recommended for automation):** Edit the `$script:DEFAULT_API_TOKEN` constant in the script
2. **Parameter override:** Use the `-ApiToken` parameter when running the script

Get your API token from: Lokalise Dashboard > Settings > API Tokens

### Project ID

The Lokalise Project ID is required and can be found in your project settings. It's in hash format (e.g., `abc123def.456789`).

### Default Locale List

The `$script:DEFAULT_LOCALES` array defines which locales to translate to by default. Modify this list to match your project needs:

```powershell
$script:DEFAULT_LOCALES = @(
    "fr-CA",      # French (Canada)
    "es-MX",      # Spanish (Mexico)
    "de-DE",      # German (Germany)
    "ja-JP",      # Japanese
    "zh-Hans"     # Chinese (Simplified)
)
```

Override at runtime with `-Locales @("locale1", "locale2")`.

## Locale Validation

Before uploading or exporting, the script:

1. Queries the Lokalise project's configured languages
2. Validates all requested locales exist in the project
3. If ANY locale is invalid:
   - Stops execution immediately
   - Displays invalid locale(s)
   - Lists all supported locales from the project

This prevents wasted API calls and ensures translations exist for requested locales.

## Machine Translation Behavior

**MT is enabled by default** and runs after uploading files:

- Triggers MT for all target locales
- **Only fills missing translations**
- **Never overwrites existing human translations**
- Uses Lokalise's MT service (requires appropriate plan)

MT failures are logged as warnings but don't stop execution.

## File Discovery Rules

### Neutral Files (uploaded)
Files matching: `*.resx` WITHOUT a locale suffix

Examples:
- `Strings.resx` ✓ (neutral)
- `Resources.resx` ✓ (neutral)
- `Labels.resx` ✓ (neutral)

### Locale-Specific Files (excluded from upload)
Files matching: `*.<locale>.resx`

Locale patterns detected:
- Two-letter code: `*.en.resx`, `*.fr.resx`
- Two-letter + region: `*.en-US.resx`, `*.fr-CA.resx`
- Script variants: `*.zh-Hant.resx`, `*.zh-Hans.resx`

Examples:
- `Strings.fr-CA.resx` ✗ (locale-specific)
- `Resources.ja.resx` ✗ (locale-specific)

### Excluded Folders
The following directories are always skipped:
- `.git`
- `bin`
- `obj`
- `packages`

### Output Naming Convention
Translated files are saved alongside neutral files:
```
/Project
  /Resources
    Strings.resx          (neutral - uploaded)
    Strings.fr-CA.resx    (generated)
    Strings.es-MX.resx    (generated)
```

## Example Usage Scenarios

### Scenario 1: Initial Setup
First-time synchronization with all default locales:
```powershell
.\lokalise-resx.ps1 -ProjectId "abc123.456" -VerboseLogging
```

### Scenario 2: CI/CD Pipeline
Automated sync with specific locales and custom token:
```powershell
.\lokalise-resx.ps1 `
    -ProjectId $env:LOKALISE_PROJECT_ID `
    -ApiToken $env:LOKALISE_API_TOKEN `
    -Locales @("fr-CA", "es-MX") `
    -TimeoutMinutes 15
```

### Scenario 3: Preview Changes
Check what would happen without making changes:
```powershell
.\lokalise-resx.ps1 -ProjectId "abc123.456" -DryRun -VerboseLogging
```

### Scenario 4: Different Repository Root
Sync files from a specific directory:
```powershell
.\lokalise-resx.ps1 `
    -ProjectId "abc123.456" `
    -RootPath "C:\Projects\MyApp\src"
```

## Parameter Reference

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `-RootPath` | string | No | Current directory | Root directory to scan for .resx files |
| `-ProjectId` | string | **Yes** | - | Lokalise project ID (hash format) |
| `-ApiToken` | string | No | Hardcoded constant | Lokalise API token (overrides constant) |
| `-Locales` | string[] | No | `$DEFAULT_LOCALES` | Target locales to translate |
| `-TimeoutMinutes` | int | No | 10 | Max wait time per locale export |
| `-DryRun` | switch | No | false | Simulate without API calls or writes |
| `-VerboseLogging` | switch | No | false | Enable detailed debug output |

## Output Summary

At completion, the script displays:

```
============================================================
                    EXECUTION SUMMARY
============================================================

  Neutral .resx files found:    5
  Files uploaded:               5
  Locales processed:            3
  Localized files created:      12
  Localized files updated:      3
  Failures:                     0

============================================================
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Failure (invalid locales, API errors, or file errors) |

## Requirements

- PowerShell 7.0 or later
- No external dependencies (uses built-in .NET classes)
- Valid Lokalise API token with read/write permissions
- Lokalise project with target languages configured

## Troubleshooting

### "Invalid locale(s) detected"
The requested locale isn't configured in your Lokalise project. Add the language in Lokalise Dashboard > Project Settings > Languages.

### "API token not configured"
Set the `$script:DEFAULT_API_TOKEN` constant or use the `-ApiToken` parameter.

### "No neutral .resx files found"
Ensure you're running from the correct directory or specify `-RootPath`. Check that files aren't in excluded folders (bin, obj, etc.).

### Rate Limiting
The script uses exponential backoff (5s → 30s) when rate limited. For large projects, consider running during off-peak hours.

## License

MIT License - See LICENSE file for details.
