#!/usr/bin/env node

/**
 * Lokalise .resx Synchronization Script (Node.js)
 *
 * Uploads neutral .resx files to Lokalise, triggers machine translation
 * for missing translations, and downloads locale-specific .resx files.
 *
 * Usage:
 *   node lokalise-resx.js --project-id <id> [options]
 *
 * No external dependencies - uses only Node.js built-in modules.
 */

const https = require('https');
const http = require('http');
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const { URL } = require('url');
const crypto = require('crypto');

// ============== CONFIGURATION CONSTANTS ==============

// HARDCODED API TOKEN - Replace with your Lokalise API token
const DEFAULT_API_TOKEN = 'YOUR_LOKALISE_API_TOKEN_HERE';

// DEFAULT TARGET LOCALES - Modify this list as needed
const DEFAULT_LOCALES = [
    'fr-CA',
    'es-MX',
    'de-DE',
    'ja-JP',
    'zh-Hans'
];

// API BASE URL
const LOKALISE_API_BASE = 'https://api.lokalise.com/api2';

// EXCLUDED FOLDERS
const EXCLUDED_FOLDERS = ['.git', 'bin', 'obj', 'packages', 'node_modules'];

// LOCALE PATTERN - Matches files like *.en.resx, *.fr-CA.resx
const LOCALE_PATTERN = /^.+\.([a-z]{2}(-[a-zA-Z]{2,4})?|[a-z]{2}-[A-Z][a-z]{3})\.resx$/;

// ============== GLOBAL STATE ==============

const stats = {
    neutralFilesFound: 0,
    filesUploaded: 0,
    localesProcessed: 0,
    filesCreated: 0,
    filesUpdated: 0,
    failures: []
};

let config = {
    rootPath: process.cwd(),
    projectId: null,
    apiToken: null,
    locales: DEFAULT_LOCALES,
    timeoutMinutes: 10,
    dryRun: false,
    verboseLogging: false
};

// ============== LOGGING FUNCTIONS ==============

function log(message, level = 'INFO') {
    const timestamp = new Date().toISOString().replace('T', ' ').substring(0, 19);
    const colors = {
        INFO: '\x1b[37m',
        WARN: '\x1b[33m',
        ERROR: '\x1b[31m',
        SUCCESS: '\x1b[32m',
        DEBUG: '\x1b[36m',
        RESET: '\x1b[0m'
    };

    if (level === 'DEBUG' && !config.verboseLogging) {
        return;
    }

    console.log(`${colors[level] || ''}[${timestamp}] [${level}] ${message}${colors.RESET}`);
}

function logError(message, context = '') {
    log(message, 'ERROR');
    stats.failures.push({ context, message });
}

// ============== API HELPER FUNCTIONS ==============

function makeRequest(endpoint, method = 'GET', body = null, token = null) {
    return new Promise((resolve, reject) => {
        const url = new URL(`${LOKALISE_API_BASE}${endpoint}`);
        const options = {
            hostname: url.hostname,
            port: 443,
            path: url.pathname + url.search,
            method: method,
            headers: {
                'X-Api-Token': token || config.apiToken,
                'Content-Type': 'application/json'
            }
        };

        log(`API ${method} ${endpoint}`, 'DEBUG');

        const req = https.request(options, (res) => {
            let data = '';
            res.on('data', chunk => data += chunk);
            res.on('end', () => {
                try {
                    const parsed = JSON.parse(data);
                    if (res.statusCode >= 400) {
                        const errorMsg = parsed.error?.message || parsed.message || data;
                        reject(new Error(`API Error (${res.statusCode}): ${errorMsg}`));
                    } else {
                        resolve(parsed);
                    }
                } catch (e) {
                    if (res.statusCode >= 400) {
                        reject(new Error(`API Error (${res.statusCode}): ${data}`));
                    } else {
                        resolve(data);
                    }
                }
            });
        });

        req.on('error', reject);

        if (body && method !== 'GET') {
            req.write(JSON.stringify(body));
        }

        req.end();
    });
}

function downloadFile(url) {
    return new Promise((resolve, reject) => {
        const parsedUrl = new URL(url);
        const protocol = parsedUrl.protocol === 'https:' ? https : http;

        protocol.get(url, (res) => {
            if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
                // Follow redirect
                downloadFile(res.headers.location).then(resolve).catch(reject);
                return;
            }

            const chunks = [];
            res.on('data', chunk => chunks.push(chunk));
            res.on('end', () => resolve(Buffer.concat(chunks)));
            res.on('error', reject);
        }).on('error', reject);
    });
}

// ============== FILE DISCOVERY ==============

function findNeutralResxFiles(rootPath) {
    log(`Scanning for neutral .resx files in: ${rootPath}`, 'INFO');

    const neutralFiles = [];

    function scanDirectory(dir) {
        let entries;
        try {
            entries = fs.readdirSync(dir, { withFileTypes: true });
        } catch (e) {
            return;
        }

        for (const entry of entries) {
            const fullPath = path.join(dir, entry.name);

            if (entry.isDirectory()) {
                if (!EXCLUDED_FOLDERS.includes(entry.name)) {
                    scanDirectory(fullPath);
                }
            } else if (entry.isFile() && entry.name.endsWith('.resx')) {
                // Check if it's a neutral file (no locale suffix)
                if (!LOCALE_PATTERN.test(entry.name)) {
                    neutralFiles.push(fullPath);
                }
            }
        }
    }

    scanDirectory(rootPath);

    stats.neutralFilesFound = neutralFiles.length;
    log(`Found ${neutralFiles.length} neutral .resx file(s)`, 'INFO');

    if (config.verboseLogging) {
        for (const file of neutralFiles) {
            const relativePath = path.relative(rootPath, file);
            log(`  - ${relativePath}`, 'DEBUG');
        }
    }

    return neutralFiles;
}

// ============== LOCALE VALIDATION ==============

async function getProjectLanguages(projectId) {
    log('Fetching project languages from Lokalise...', 'INFO');

    if (config.dryRun) {
        log('[DRY RUN] Would fetch project languages', 'DEBUG');
        return [];
    }

    try {
        const response = await makeRequest(`/projects/${projectId}/languages`);
        const languages = response.languages.map(l => l.lang_iso);
        log(`Project has ${languages.length} language(s) configured`, 'DEBUG');
        return languages;
    } catch (e) {
        throw new Error(`Failed to fetch project languages: ${e.message}`);
    }
}

function validateLocales(requestedLocales, projectLocales) {
    log('Validating requested locales...', 'INFO');

    const invalidLocales = requestedLocales.filter(l => !projectLocales.includes(l));

    if (invalidLocales.length > 0) {
        log('VALIDATION FAILED: Invalid locale(s) detected', 'ERROR');
        log(`Invalid locales: ${invalidLocales.join(', ')}`, 'ERROR');
        log('Supported locales in Lokalise project:', 'INFO');
        for (const locale of projectLocales.sort()) {
            console.log(`  - ${locale}`);
        }
        return false;
    }

    log(`All ${requestedLocales.length} locale(s) are valid`, 'SUCCESS');
    return true;
}

// ============== FILE UPLOAD ==============

async function waitForProcess(projectId, processId, timeoutSeconds = 300) {
    const startTime = Date.now();
    let pollInterval = 2000;

    while (Date.now() - startTime < timeoutSeconds * 1000) {
        try {
            const response = await makeRequest(`/projects/${projectId}/processes/${processId}`);

            if (response.process.status === 'finished') {
                return true;
            } else if (response.process.status === 'failed') {
                log(`Process failed: ${response.process.message}`, 'ERROR');
                return false;
            }

            await sleep(pollInterval);
        } catch (e) {
            log(`Error checking process status: ${e.message}`, 'WARN');
            await sleep(pollInterval);
        }
    }

    log(`Process timed out after ${timeoutSeconds} seconds`, 'WARN');
    return false;
}

async function uploadResxFile(filePath, rootPath, projectId) {
    const relativePath = path.relative(rootPath, filePath);
    const lokaliseFilename = relativePath.replace(/\\/g, '/');

    log(`Uploading: ${relativePath}`, 'INFO');

    if (config.dryRun) {
        log(`[DRY RUN] Would upload: ${relativePath}`, 'DEBUG');
        stats.filesUploaded++;
        return true;
    }

    try {
        const fileContent = fs.readFileSync(filePath);
        const base64Content = fileContent.toString('base64');

        const body = {
            data: base64Content,
            filename: lokaliseFilename,
            lang_iso: 'en',
            convert_placeholders: false,
            replace_modified: false,
            skip_detect_lang: true,
            tags: ['auto-upload'],
            tag_inserted_keys: true,
            tag_updated_keys: true
        };

        const response = await makeRequest(`/projects/${projectId}/files/upload`, 'POST', body);

        if (response.process) {
            log(`Upload queued (Process ID: ${response.process.process_id})`, 'DEBUG');
            const processComplete = await waitForProcess(projectId, response.process.process_id);
            if (!processComplete) {
                throw new Error('Upload process did not complete in time');
            }
        }

        stats.filesUploaded++;
        log(`Uploaded successfully: ${relativePath}`, 'SUCCESS');
        return true;
    } catch (e) {
        logError(`Failed to upload ${relativePath}: ${e.message}`, 'Upload');
        return false;
    }
}

// ============== MACHINE TRANSLATION ==============

async function triggerMachineTranslation(projectId, locales) {
    log('Triggering machine translation for missing translations...', 'INFO');

    if (config.dryRun) {
        log(`[DRY RUN] Would trigger MT for locales: ${locales.join(', ')}`, 'DEBUG');
        return true;
    }

    let success = true;

    for (const locale of locales) {
        log(`Triggering MT for locale: ${locale}`, 'INFO');

        try {
            const mtBody = {
                keys: [],
                language_iso: locale,
                pre_translate_mode: 'missing_only'
            };

            const response = await makeRequest(
                `/projects/${projectId}/keys/bulk/machine-translate`,
                'POST',
                mtBody
            );

            if (response.process) {
                log(`MT queued for ${locale} (Process ID: ${response.process.process_id})`, 'DEBUG');
                const processComplete = await waitForProcess(
                    projectId,
                    response.process.process_id,
                    config.timeoutMinutes * 60
                );
                if (!processComplete) {
                    log(`MT process for ${locale} did not complete in time`, 'WARN');
                    success = false;
                }
            }

            log(`MT completed for locale: ${locale}`, 'SUCCESS');
        } catch (e) {
            log(`MT failed for locale ${locale}: ${e.message}`, 'WARN');
        }
    }

    return success;
}

// ============== FILE EXPORT AND DOWNLOAD ==============

async function exportLocaleFiles(projectId, locale) {
    log(`Requesting export for locale: ${locale}`, 'INFO');

    if (config.dryRun) {
        log(`[DRY RUN] Would export locale: ${locale}`, 'DEBUG');
        return null;
    }

    try {
        const body = {
            format: 'resx',
            original_filenames: true,
            directory_prefix: '',
            filter_langs: [locale],
            replace_breaks: false,
            include_comments: true,
            include_description: true,
            export_empty_as: 'skip'
        };

        const response = await makeRequest(`/projects/${projectId}/files/download`, 'POST', body);

        if (response.bundle_url) {
            log(`Export bundle ready for ${locale}`, 'DEBUG');
            return response.bundle_url;
        } else {
            throw new Error('No bundle URL returned');
        }
    } catch (e) {
        throw new Error(`Export failed for locale ${locale}: ${e.message}`);
    }
}

async function exportWithExponentialBackoff(projectId, locale, timeoutMinutes) {
    const startTime = Date.now();
    let pollInterval = 5000;
    const maxPollInterval = 30000;
    const timeoutMs = timeoutMinutes * 60 * 1000;

    while (Date.now() - startTime < timeoutMs) {
        try {
            const bundleUrl = await exportLocaleFiles(projectId, locale);
            return bundleUrl;
        } catch (e) {
            const errorMessage = e.message.toLowerCase();

            if (errorMessage.includes('rate') || errorMessage.includes('429') || errorMessage.includes('too many')) {
                log(`Rate limited, waiting ${pollInterval / 1000} seconds...`, 'WARN');
                await sleep(pollInterval);
                pollInterval = Math.min(pollInterval * 2, maxPollInterval);
            } else {
                throw e;
            }
        }
    }

    throw new Error(`Export timed out after ${timeoutMinutes} minutes`);
}

async function downloadAndExtractBundle(bundleUrl, locale, rootPath, neutralFiles) {
    log(`Downloading bundle for locale: ${locale}`, 'INFO');

    try {
        const zipBuffer = await downloadFile(bundleUrl);
        log(`Bundle downloaded (${zipBuffer.length} bytes)`, 'DEBUG');

        // Parse ZIP file manually (simplified - handles most common cases)
        const extractedFiles = parseZipBuffer(zipBuffer);

        for (const [filename, content] of Object.entries(extractedFiles)) {
            if (filename.endsWith('.resx')) {
                processExtractedFile(filename, content, locale, rootPath, neutralFiles);
            }
        }

        stats.localesProcessed++;
    } catch (e) {
        logError(`Failed to download/extract bundle for ${locale}: ${e.message}`, 'Download');
    }
}

function parseZipBuffer(buffer) {
    const files = {};
    let offset = 0;

    while (offset < buffer.length - 4) {
        const signature = buffer.readUInt32LE(offset);

        if (signature !== 0x04034b50) {
            break; // Not a local file header
        }

        const compressionMethod = buffer.readUInt16LE(offset + 8);
        const compressedSize = buffer.readUInt32LE(offset + 18);
        const uncompressedSize = buffer.readUInt32LE(offset + 22);
        const filenameLength = buffer.readUInt16LE(offset + 26);
        const extraLength = buffer.readUInt16LE(offset + 28);

        const filename = buffer.slice(offset + 30, offset + 30 + filenameLength).toString('utf8');
        const dataStart = offset + 30 + filenameLength + extraLength;
        const compressedData = buffer.slice(dataStart, dataStart + compressedSize);

        if (!filename.endsWith('/')) {
            try {
                if (compressionMethod === 0) {
                    files[filename] = compressedData;
                } else if (compressionMethod === 8) {
                    files[filename] = zlib.inflateRawSync(compressedData);
                }
            } catch (e) {
                log(`Failed to decompress ${filename}: ${e.message}`, 'DEBUG');
            }
        }

        offset = dataStart + compressedSize;
    }

    return files;
}

function processExtractedFile(filename, content, locale, rootPath, neutralFiles) {
    const normalizedFilename = filename.replace(/\\/g, '/');

    // Find matching neutral file
    let matchingNeutral = null;
    for (const neutralPath of neutralFiles) {
        const neutralRelative = path.relative(rootPath, neutralPath).replace(/\\/g, '/');
        const neutralName = path.basename(neutralPath);

        if (normalizedFilename === neutralRelative || path.basename(normalizedFilename) === neutralName) {
            matchingNeutral = neutralPath;
            break;
        }
    }

    if (!matchingNeutral) {
        log(`No matching neutral file for: ${filename}`, 'DEBUG');
        return;
    }

    // Compute destination filename
    const baseName = path.basename(matchingNeutral, '.resx');
    const destFileName = `${baseName}.${locale}.resx`;
    const destPath = path.join(path.dirname(matchingNeutral), destFileName);

    // Compare with existing file
    let shouldWrite = true;
    let isUpdate = false;

    if (fs.existsSync(destPath)) {
        const existingContent = fs.readFileSync(destPath);
        const existingHash = crypto.createHash('sha256').update(existingContent).digest('hex');
        const newHash = crypto.createHash('sha256').update(content).digest('hex');

        if (existingHash === newHash) {
            log(`No changes for: ${destFileName}`, 'DEBUG');
            shouldWrite = false;
        } else {
            isUpdate = true;
        }
    }

    if (shouldWrite) {
        if (config.dryRun) {
            const action = isUpdate ? 'update' : 'create';
            log(`[DRY RUN] Would ${action}: ${destPath}`, 'DEBUG');
        } else {
            // Ensure UTF-8 BOM
            const BOM = Buffer.from([0xEF, 0xBB, 0xBF]);
            const hasBom = content.length >= 3 &&
                content[0] === 0xEF && content[1] === 0xBB && content[2] === 0xBF;

            const finalContent = hasBom ? content : Buffer.concat([BOM, content]);
            fs.writeFileSync(destPath, finalContent);

            log(`Written: ${destFileName}`, 'SUCCESS');
        }

        if (isUpdate) {
            stats.filesUpdated++;
        } else {
            stats.filesCreated++;
        }
    }
}

// ============== UTILITY FUNCTIONS ==============

function sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
}

function parseArgs(args) {
    const result = { ...config };
    let i = 0;

    while (i < args.length) {
        const arg = args[i];

        switch (arg) {
            case '--project-id':
            case '-p':
                result.projectId = args[++i];
                break;
            case '--api-token':
            case '-t':
                result.apiToken = args[++i];
                break;
            case '--root-path':
            case '-r':
                result.rootPath = path.resolve(args[++i]);
                break;
            case '--locales':
            case '-l':
                result.locales = args[++i].split(',').map(l => l.trim());
                break;
            case '--timeout':
                result.timeoutMinutes = parseInt(args[++i], 10);
                break;
            case '--dry-run':
            case '-d':
                result.dryRun = true;
                break;
            case '--verbose':
            case '-v':
                result.verboseLogging = true;
                break;
            case '--help':
            case '-h':
                printHelp();
                process.exit(0);
                break;
            default:
                if (arg.startsWith('-')) {
                    console.error(`Unknown option: ${arg}`);
                    process.exit(1);
                }
        }
        i++;
    }

    return result;
}

function printHelp() {
    console.log(`
Lokalise .resx Synchronization Script (Node.js)

Usage: node lokalise-resx.js --project-id <id> [options]

Required:
  --project-id, -p <id>     Lokalise project ID (hash format)

Options:
  --api-token, -t <token>   Lokalise API token (overrides constant)
  --root-path, -r <path>    Root directory to scan (default: current dir)
  --locales, -l <list>      Comma-separated locales (default: ${DEFAULT_LOCALES.join(',')})
  --timeout <minutes>       Export timeout per locale (default: 10)
  --dry-run, -d             Simulate without making changes
  --verbose, -v             Enable detailed logging
  --help, -h                Show this help message

Examples:
  node lokalise-resx.js --project-id abc123.456
  node lokalise-resx.js -p abc123.456 -l fr-CA,es-MX -v
  node lokalise-resx.js -p abc123.456 --dry-run
`);
}

function showSummary() {
    console.log('\n' + '='.repeat(60));
    console.log('                    EXECUTION SUMMARY');
    console.log('='.repeat(60) + '\n');
    console.log(`  Neutral .resx files found:    ${stats.neutralFilesFound}`);
    console.log(`  Files uploaded:               ${stats.filesUploaded}`);
    console.log(`  Locales processed:            ${stats.localesProcessed}`);
    console.log(`  Localized files created:      ${stats.filesCreated}`);
    console.log(`  Localized files updated:      ${stats.filesUpdated}`);
    console.log(`  Failures:                     ${stats.failures.length}`);

    if (stats.failures.length > 0) {
        console.log('\n  Failure Details:');
        for (const failure of stats.failures) {
            console.log(`    - [${failure.context}] ${failure.message}`);
        }
    }

    console.log('\n' + '='.repeat(60));
}

// ============== MAIN EXECUTION ==============

async function main() {
    console.log('\n' + '='.repeat(60));
    console.log('       LOKALISE .RESX SYNCHRONIZATION SCRIPT (Node.js)');
    console.log('='.repeat(60) + '\n');

    // Parse command line arguments
    config = parseArgs(process.argv.slice(2));

    if (config.dryRun) {
        log('DRY RUN MODE - No changes will be made', 'WARN');
    }

    // Validate required parameters
    if (!config.projectId) {
        log('Project ID is required. Use --project-id or -p', 'ERROR');
        printHelp();
        process.exit(1);
    }

    // Determine API token
    config.apiToken = config.apiToken || DEFAULT_API_TOKEN;
    if (config.apiToken === 'YOUR_LOKALISE_API_TOKEN_HERE') {
        log('API token not configured. Please set DEFAULT_API_TOKEN or use --api-token', 'ERROR');
        process.exit(1);
    }

    log(`Root path: ${config.rootPath}`, 'INFO');
    log(`Target locales: ${config.locales.join(', ')}`, 'INFO');

    // Step 1: Find neutral .resx files
    console.log('');
    log('STEP 1: Discovering neutral .resx files...', 'INFO');
    const neutralFiles = findNeutralResxFiles(config.rootPath);

    if (neutralFiles.length === 0) {
        log('No neutral .resx files found. Nothing to do.', 'WARN');
        showSummary();
        process.exit(0);
    }

    // Step 2: Validate locales
    console.log('');
    log('STEP 2: Validating locales...', 'INFO');

    if (!config.dryRun) {
        const projectLocales = await getProjectLanguages(config.projectId);

        if (projectLocales.length === 0) {
            log('No languages configured in Lokalise project or failed to fetch.', 'WARN');
            log('Proceeding with requested locales...', 'INFO');
        } else {
            const valid = validateLocales(config.locales, projectLocales);
            if (!valid) {
                log('Execution stopped due to invalid locales.', 'ERROR');
                process.exit(1);
            }
        }
    } else {
        log(`[DRY RUN] Would validate locales: ${config.locales.join(', ')}`, 'DEBUG');
    }

    // Step 3: Upload files
    console.log('');
    log('STEP 3: Uploading neutral .resx files...', 'INFO');

    for (const file of neutralFiles) {
        await uploadResxFile(file, config.rootPath, config.projectId);
    }

    // Step 4: Trigger Machine Translation
    console.log('');
    log('STEP 4: Triggering machine translation...', 'INFO');
    await triggerMachineTranslation(config.projectId, config.locales);

    // Step 5: Export and download for each locale
    console.log('');
    log('STEP 5: Exporting and downloading localized files...', 'INFO');

    for (const locale of config.locales) {
        try {
            const bundleUrl = await exportWithExponentialBackoff(
                config.projectId,
                locale,
                config.timeoutMinutes
            );

            if (bundleUrl) {
                await downloadAndExtractBundle(bundleUrl, locale, config.rootPath, neutralFiles);
            }
        } catch (e) {
            logError(`Failed to process locale ${locale}: ${e.message}`, 'Export/Download');
        }
    }

    // Show summary
    showSummary();

    // Exit with appropriate code
    process.exit(stats.failures.length > 0 ? 1 : 0);
}

// Run main
main().catch(e => {
    log(`Fatal error: ${e.message}`, 'ERROR');
    process.exit(1);
});
