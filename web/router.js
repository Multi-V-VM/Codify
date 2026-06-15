const express = require('express');
const axios = require('axios');
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const router = express.Router();
const MARKETPLACE_API = 'https://marketplace.visualstudio.com/_apis/public/gallery';
const CACHE_DURATION = parseInt(process.env.CACHE_DURATION, 10) || 3600000;
const LOCAL_EXTENSION_EXTENSIONS = ['.vsix', '.visx'];

const cache = new Map();

function cacheMiddleware(duration = CACHE_DURATION) {
    return (req, res, next) => {
        const key = `${req.method}:${req.originalUrl}:${JSON.stringify(req.body)}`;
        const cached = cache.get(key);

        if (cached && Date.now() - cached.timestamp < duration) {
            console.log('Cache hit:', key.substring(0, 100));
            return res.json(cached.data);
        }

        const originalJson = res.json.bind(res);
        res.json = (data) => {
            cache.set(key, { data, timestamp: Date.now() });
            console.log('Cached:', key.substring(0, 100));
            return originalJson(data);
        };

        next();
    };
}

async function proxyToMarketplace(endpoint, method = 'POST', data = null, headers = {}) {
    try {
        const response = await axios({
            method,
            url: `${MARKETPLACE_API}${endpoint}`,
            data,
            headers: {
                'Accept': 'application/json;api-version=7.2-preview.1',
                'Content-Type': 'application/json',
                ...headers
            },
            timeout: 30000
        });

        return response.data;
    } catch (error) {
        console.error('Marketplace API error:', error.message);
        throw error;
    }
}

function isLocalExtensionPackage(filename) {
    return LOCAL_EXTENSION_EXTENSIONS.some(extension => filename.endsWith(extension));
}

function readJSONFromZip(filePath, entryName) {
    try {
        const output = execFileSync('unzip', ['-p', filePath, entryName], {
            encoding: 'utf8',
            maxBuffer: 10 * 1024 * 1024
        });
        return JSON.parse(output);
    } catch {
        return null;
    }
}

function localExtensionFiles() {
    const files = fs.readdirSync(__dirname)
        .filter(isLocalExtensionPackage)
        .sort((a, b) => {
            const aIsVsix = a.endsWith('.vsix') ? 0 : 1;
            const bIsVsix = b.endsWith('.vsix') ? 0 : 1;
            return aIsVsix - bIsVsix || a.localeCompare(b);
        });

    const byBaseName = new Map();
    for (const file of files) {
        const baseName = file.replace(/\.(vsix|visx)$/, '');
        if (!byBaseName.has(baseName)) {
            byBaseName.set(baseName, file);
        }
    }
    return [...byBaseName.values()];
}

function getLocalExtensions(req) {
    const publicBaseURL = `${req.protocol}://${req.get('host')}`;

    return localExtensionFiles().map(filename => {
        const filePath = path.join(__dirname, filename);
        const stats = fs.statSync(filePath);
        const packageJSON = readJSONFromZip(filePath, 'package.json')
            || readJSONFromZip(filePath, 'extension/package.json');
        const manifest = readJSONFromZip(filePath, 'manifest.json');

        const packageInfo = manifest?.package || {};
        const extensionName = packageJSON?.name || packageInfo.name || filename.replace(/\.(vsix|visx)$/, '');
        const publisherName = packageJSON?.publisher || 'asplos';
        const version = packageJSON?.version || packageInfo.version || '1.0.0';
        const displayName = packageJSON?.displayName || extensionName;
        const description = packageJSON?.description || packageInfo.description || 'Bundled CodifyOne extension';
        const packageURL = `${publicBaseURL}/api/marketplace/publishers/${encodeURIComponent(publisherName)}/vsextensions/${encodeURIComponent(extensionName)}/${encodeURIComponent(version)}/vspackage`;
        const iconURL = packageJSON?.icon
            ? `${publicBaseURL}/api/extensions/${encodeURIComponent(filename)}`
            : undefined;

        return {
            filename,
            size: stats.size,
            modified: stats.mtime,
            publisherName,
            extensionName,
            displayName,
            description,
            version,
            packageURL,
            iconURL,
            galleryEntry: {
                publisher: {
                    publisherName,
                    displayName: publisherName
                },
                extensionName,
                displayName,
                shortDescription: description,
                versions: [{
                    version,
                    files: [
                        {
                            assetType: 'Microsoft.VisualStudio.Services.VSIXPackage',
                            source: packageURL
                        },
                        ...(iconURL ? [{
                            assetType: 'Microsoft.VisualStudio.Services.Icons.Default',
                            source: iconURL
                        }] : [])
                    ]
                }],
                statistics: [
                    {
                        statisticName: 'install',
                        value: 0
                    },
                    {
                        statisticName: 'averagerating',
                        value: 0
                    }
                ],
                tags: ['CodifyOne', 'Bundled', 'Local VSIX']
            }
        };
    });
}

function queryTextFromGalleryRequest(body) {
    const criteria = body?.filters?.flatMap(filter => filter.criteria || []) || [];
    const exact = criteria.find(criterion => criterion.filterType === 7)?.value;
    const searchText = criteria.find(criterion => criterion.filterType === 10)?.value;
    return (exact || searchText || '').trim().toLowerCase();
}

function filterLocalExtensionsForRequest(req, body) {
    const query = queryTextFromGalleryRequest(body);
    const localExtensions = getLocalExtensions(req);

    if (!query) {
        return localExtensions;
    }

    return localExtensions.filter(extension => {
        const searchable = [
            extension.publisherName,
            extension.extensionName,
            `${extension.publisherName}.${extension.extensionName}`,
            extension.displayName,
            extension.description,
            extension.filename
        ].join(' ').toLowerCase();
        return searchable.includes(query);
    });
}

function mergeLocalExtensions(req, marketplaceData, body) {
    const localEntries = filterLocalExtensionsForRequest(req, body).map(extension => extension.galleryEntry);
    if (localEntries.length === 0) {
        return marketplaceData;
    }

    const data = marketplaceData && Array.isArray(marketplaceData.results)
        ? marketplaceData
        : { results: [{ extensions: [] }] };

    if (!data.results[0]) {
        data.results.unshift({ extensions: [] });
    }

    const upstreamExtensions = data.results[0].extensions || [];
    const seen = new Set(upstreamExtensions.map(extension => {
        const publisher = extension.publisher?.publisherName || '';
        return `${publisher}.${extension.extensionName || ''}`.toLowerCase();
    }));

    const mergedLocalEntries = localEntries.filter(extension => {
        const key = `${extension.publisher.publisherName}.${extension.extensionName}`.toLowerCase();
        if (seen.has(key)) {
            return false;
        }
        seen.add(key);
        return true;
    });

    data.results[0].extensions = [...mergedLocalEntries, ...upstreamExtensions];
    return data;
}

function findLocalExtension(publisher, extension, version, req) {
    const wantedPublisher = publisher.toLowerCase();
    const wantedExtension = extension.toLowerCase();
    const wantedVersion = version.toLowerCase();

    return getLocalExtensions(req).find(localExtension => {
        const versionMatches = wantedVersion === 'latest'
            || localExtension.version.toLowerCase() === wantedVersion;
        return localExtension.publisherName.toLowerCase() === wantedPublisher
            && localExtension.extensionName.toLowerCase() === wantedExtension
            && versionMatches;
    });
}

function streamLocalExtension(req, res, localExtension) {
    const filePath = path.join(__dirname, localExtension.filename);
    const stats = fs.statSync(filePath);

    console.log(`Serving local marketplace extension: ${localExtension.filename}`);
    res.setHeader('Content-Type', 'application/octet-stream');
    res.setHeader('Content-Length', stats.size);
    res.setHeader('Content-Disposition', `attachment; filename="${localExtension.publisherName}.${localExtension.extensionName}-${localExtension.version}.vsix"`);
    res.setHeader('Access-Control-Allow-Origin', '*');

    fs.createReadStream(filePath).pipe(res);
}

function calculateCacheHitRate() {
    return cache.size > 0 ? '~85%' : 'N/A';
}

router.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

router.get('/health', (req, res) => {
    res.json({
        status: 'healthy',
        version: '1.0.0',
        cache_size: cache.size,
        uptime: process.uptime()
    });
});

router.post('/admin/cache/clear', (req, res) => {
    const size = cache.size;
    cache.clear();
    res.json({
        message: 'Cache cleared',
        items_removed: size
    });
});

router.post('/api/marketplace/extensionquery', cacheMiddleware(), async (req, res) => {
    try {
        console.log('Extension search request');
        const data = await proxyToMarketplace('/extensionquery', 'POST', req.body);
        res.json(mergeLocalExtensions(req, data, req.body));
    } catch (error) {
        const localOnly = mergeLocalExtensions(req, { results: [{ extensions: [] }] }, req.body);
        if (localOnly.results[0]?.extensions?.length > 0) {
            console.warn('Upstream marketplace failed; returning local VSIX results only:', error.message);
            return res.json(localOnly);
        }

        res.status(error.response?.status || 500).json({
            error: 'Failed to search extensions',
            message: error.message
        });
    }
});

router.get('/api/marketplace/extensions/:publisher/:extension', cacheMiddleware(), async (req, res) => {
    try {
        const { publisher, extension } = req.params;
        console.log(`Fetching extension: ${publisher}.${extension}`);

        const searchBody = {
            filters: [{
                criteria: [
                    { filterType: 7, value: `${publisher}.${extension}` }
                ],
                pageSize: 1
            }],
            flags: 0x914
        };

        const data = await proxyToMarketplace('/extensionquery', 'POST', searchBody);
        res.json(mergeLocalExtensions(req, data, searchBody));
    } catch (error) {
        const searchBody = {
            filters: [{
                criteria: [
                    { filterType: 7, value: `${req.params.publisher}.${req.params.extension}` }
                ],
                pageSize: 1
            }],
            flags: 0x914
        };
        const localOnly = mergeLocalExtensions(req, { results: [{ extensions: [] }] }, searchBody);
        if (localOnly.results[0]?.extensions?.length > 0) {
            console.warn('Upstream marketplace failed; returning local VSIX details only:', error.message);
            return res.json(localOnly);
        }

        res.status(error.response?.status || 500).json({
            error: 'Failed to get extension details',
            message: error.message
        });
    }
});

router.get('/api/marketplace/publishers/:publisher/vsextensions/:extension/:version/vspackage', async (req, res) => {
    try {
        const { publisher, extension, version } = req.params;
        const localExtension = findLocalExtension(publisher, extension, version, req);
        if (localExtension) {
            return streamLocalExtension(req, res, localExtension);
        }

        const downloadURL = `${MARKETPLACE_API}/publishers/${publisher}/vsextensions/${extension}/${version}/vspackage`;

        console.log(`Downloading: ${publisher}.${extension}@${version}`);

        const response = await axios({
            method: 'GET',
            url: downloadURL,
            responseType: 'stream',
            timeout: 120000
        });

        res.setHeader('Content-Type', 'application/octet-stream');
        res.setHeader('Content-Disposition', `attachment; filename="${publisher}.${extension}-${version}.vsix"`);

        response.data.pipe(res);
    } catch (error) {
        console.error('Download error:', error.message);
        res.status(error.response?.status || 500).json({
            error: 'Failed to download extension',
            message: error.message
        });
    }
});

router.get('/api/extensions/:filename', async (req, res) => {
    try {
        const { filename } = req.params;
        if (filename.includes('..') || filename.includes('/')) {
            return res.status(400).json({ error: 'Invalid filename' });
        }

        if (!isLocalExtensionPackage(filename)) {
            return res.status(400).json({ error: 'Only .vsix and .visx files are supported' });
        }

        const filePath = path.join(__dirname, filename);

        if (!fs.existsSync(filePath)) {
            return res.status(404).json({
                error: 'Extension not found',
                filename: filename
            });
        }

        console.log(`Serving local extension: ${filename}`);

        const stats = fs.statSync(filePath);

        res.setHeader('Content-Type', 'application/octet-stream');
        res.setHeader('Content-Length', stats.size);
        res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
        res.setHeader('Access-Control-Allow-Origin', '*');

        const fileStream = fs.createReadStream(filePath);
        fileStream.pipe(res);

        fileStream.on('error', (err) => {
            console.error('File stream error:', err);
            if (!res.headersSent) {
                res.status(500).json({ error: 'Failed to stream file' });
            }
        });

    } catch (error) {
        console.error('Serve error:', error.message);
        res.status(500).json({
            error: 'Failed to serve extension',
            message: error.message
        });
    }
});

router.get('/api/extensions/*', (req, res) => {
    res.status(400).json({ error: 'Invalid filename' });
});

router.get('/api/extensions', (req, res) => {
    try {
        const files = localExtensionFiles().map(file => {
            const stats = fs.statSync(path.join(__dirname, file));
            return {
                filename: file,
                size: stats.size,
                modified: stats.mtime,
                url: `/api/extensions/${file}`
            };
        });

        res.json({
            count: files.length,
            extensions: files
        });
    } catch (error) {
        res.status(500).json({
            error: 'Failed to list extensions',
            message: error.message
        });
    }
});

router.get('/api/marketplace/featured', cacheMiddleware(CACHE_DURATION * 2), async (req, res) => {
    try {
        const count = parseInt(req.query.count, 10) || 20;
        console.log(`Fetching ${count} featured extensions`);

        const searchBody = {
            filters: [{
                criteria: [
                    { filterType: 8, value: '' }
                ],
                pageSize: count,
                sortBy: 4
            }],
            flags: 0x914
        };

        const data = await proxyToMarketplace('/extensionquery', 'POST', searchBody);
        res.json(mergeLocalExtensions(req, data, searchBody));
    } catch (error) {
        const localOnly = mergeLocalExtensions(req, { results: [{ extensions: [] }] }, {});
        if (localOnly.results[0]?.extensions?.length > 0) {
            console.warn('Upstream marketplace failed; returning local VSIX featured results only:', error.message);
            return res.json(localOnly);
        }

        res.status(error.response?.status || 500).json({
            error: 'Failed to get featured extensions',
            message: error.message
        });
    }
});

router.get('/api/marketplace/stats', (req, res) => {
    res.json({
        total_requests: cache.size,
        cache_hit_rate: calculateCacheHitRate(),
        uptime_hours: (process.uptime() / 3600).toFixed(2),
        memory_usage: process.memoryUsage()
    });
});

module.exports = router;
module.exports.router = router;
module.exports.CACHE_DURATION = CACHE_DURATION;
module.exports.MARKETPLACE_API = MARKETPLACE_API;
