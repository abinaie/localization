# Lokalise .resx Synchronization Scripts

Lightweight scripts for uploading .NET `.resx` resource files to Lokalise and downloading translated locale-specific files.

**Available in two versions:**
- **PowerShell** (`lokalise-resx.ps1`) - For Windows/.NET environments
- **Node.js** (`lokalise-resx.js`) - Cross-platform, no external dependencies

## Features

- Recursive discovery of neutral `.resx` files
- Automatic locale validation against Lokalise project
- Machine translation for missing translations (preserves human translations)
- **Key completeness validation** (prevents incomplete translations from being saved)
- Exponential backoff polling for exports
- Content-aware writes (only updates changed files)
- Dry run mode for safe testing
- Detailed logging with verbose option

---

## Quick Start

### PowerShell Version

**1. Configure:**
```powershell
# Edit lokalise-resx.ps1 and set:
$script:DEFAULT_API_TOKEN = "your-api-token"
```

**2. Run:**
```powershell
.\lokalise-resx.ps1 -ProjectId "abc123.456"
```

### Node.js Version

**1. Configure:**
```javascript
// Edit lokalise-resx.js and set:
const DEFAULT_API_TOKEN = 'your-api-token';
```

**2. Run:**
```bash
node lokalise-resx.js --project-id abc123.456
```

---

## Configuration

### API Token

Get your API token from: **Lokalise Dashboard > Settings > API Tokens**

Configure in two ways:
1. **Hardcoded:** Edit the constant in the script (recommended for automation)
2. **Parameter:** Pass at runtime (see parameter reference below)

### Project ID

The Lokalise Project ID is required. Find it in your project settings (hash format, e.g., `abc123def.456789`).

### Default Locales

Both scripts include a default locale list. Modify in the script:

**PowerShell:**
```powershell
$script:DEFAULT_LOCALES = @("fr-CA", "es-MX", "de-DE", "ja-JP", "zh-Hans")
```

**Node.js:**
```javascript
const DEFAULT_LOCALES = ['fr-CA', 'es-MX', 'de-DE', 'ja-JP', 'zh-Hans'];
```

---

## Parameter Reference

### PowerShell

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `-ProjectId` | string | **Yes** | - | Lokalise project ID |
| `-ApiToken` | string | No | Constant | API token override |
| `-RootPath` | string | No | Current dir | Directory to scan |
| `-Locales` | string[] | No | Default list | Target locales |
| `-TimeoutMinutes` | int | No | 10 | Export timeout |
| `-DryRun` | switch | No | false | Simulate only |
| `-VerboseLogging` | switch | No | false | Detailed output |

### Node.js

| Parameter | Short | Required | Default | Description |
|-----------|-------|----------|---------|-------------|
| `--project-id` | `-p` | **Yes** | - | Lokalise project ID |
| `--api-token` | `-t` | No | Constant | API token override |
| `--root-path` | `-r` | No | Current dir | Directory to scan |
| `--locales` | `-l` | No | Default list | Comma-separated locales |
| `--timeout` | - | No | 10 | Export timeout (minutes) |
| `--dry-run` | `-d` | No | false | Simulate only |
| `--verbose` | `-v` | No | false | Detailed output |

---

## Usage Examples

### PowerShell

```powershell
# Basic usage
.\lokalise-resx.ps1 -ProjectId "abc123.456"

# Custom locales
.\lokalise-resx.ps1 -ProjectId "abc123.456" -Locales @("fr-CA", "es-MX")

# Dry run with verbose output
.\lokalise-resx.ps1 -ProjectId "abc123.456" -DryRun -VerboseLogging

# CI/CD with environment variables
.\lokalise-resx.ps1 -ProjectId $env:LOKALISE_PROJECT_ID -ApiToken $env:LOKALISE_API_TOKEN
```

### Node.js

```bash
# Basic usage
node lokalise-resx.js --project-id abc123.456

# Custom locales
node lokalise-resx.js -p abc123.456 -l fr-CA,es-MX

# Dry run with verbose output
node lokalise-resx.js -p abc123.456 --dry-run --verbose

# CI/CD with environment variables
node lokalise-resx.js -p $LOKALISE_PROJECT_ID -t $LOKALISE_API_TOKEN
```

---

## Locale Validation

Before uploading or exporting, both scripts:

1. Query the Lokalise project's configured languages
2. Validate all requested locales exist in the project
3. If ANY locale is invalid:
   - Stop execution immediately
   - Display invalid locale(s)
   - List all supported locales from the project

---

## Machine Translation Behavior

**MT is enabled by default** and runs after uploading files:

- Triggers MT for all target locales
- **Only fills missing translations**
- **Never overwrites existing human translations**
- Uses Lokalise's MT service (requires appropriate plan)

MT failures are logged as warnings but don't stop execution.

---

## Key Completeness Validation

Before writing any localized file, both scripts validate that all keys from the neutral file exist in the translated file:

1. Extract all `<data name="...">` keys from the neutral `.resx` file
2. Extract all keys from the downloaded localized file
3. Compare the key sets
4. If any keys are missing:
   - Log an error with the specific missing key names
   - **Skip writing that localized file**
   - Continue processing other files/locales

This prevents incomplete translations from being saved to disk, which could cause runtime errors or display untranslated content.

**Example log output:**
```
[ERROR] Missing keys for locale fr-CA: WelcomeMessage, ErrorTitle
[WARN] Skipping write for Strings.resx in locale fr-CA due to missing keys
```

---

## File Discovery Rules

### Neutral Files (uploaded)

Files matching `*.resx` WITHOUT a locale suffix:
- `Strings.resx` - uploaded
- `Resources.resx` - uploaded

### Locale-Specific Files (excluded)

Files matching `*.<locale>.resx`:
- `Strings.fr-CA.resx` - skipped
- `Resources.en.resx` - skipped

### Excluded Folders

- `.git`, `bin`, `obj`, `packages`, `node_modules`

### Output Naming

```
/Project
  /Resources
    Strings.resx          (neutral - uploaded)
    Strings.fr-CA.resx    (downloaded)
    Strings.es-MX.resx    (downloaded)
```

---

## Output Summary

Both scripts display a summary on completion:

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

---

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Failure (invalid locales, API errors, or file errors) |

---

## Requirements

### PowerShell Version
- PowerShell 7.0 or later
- No external dependencies

### Node.js Version
- Node.js 14.0 or later
- No external dependencies (uses built-in modules only)

### Both Versions
- Valid Lokalise API token with read/write permissions
- Lokalise project with target languages configured

---

## Troubleshooting

### "Invalid locale(s) detected"
Add the language in Lokalise Dashboard > Project Settings > Languages.

### "API token not configured"
Set the token constant in the script or pass via parameter.

### "No neutral .resx files found"
Check you're in the correct directory and files aren't in excluded folders.

### Rate Limiting
Scripts use exponential backoff (5s to 30s). For large projects, run during off-peak hours.

### "Missing keys for locale X"
The localized file from Lokalise doesn't contain all keys from the neutral file. This can happen when:
- New keys were just added and MT hasn't completed
- Some keys were deleted in Lokalise
- Export filters excluded certain keys

Re-run the script after ensuring all keys are translated in Lokalise.

---

## License

MIT License
