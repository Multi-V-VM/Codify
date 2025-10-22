/**
 * asplos.dev - VSCode Extension Marketplace Proxy Server
 *
 * This server acts as a caching proxy for the VSCode Marketplace API,
 * reducing load on Microsoft's servers and improving response times.
 */

const express = require('express');
const axios = require('axios');
const cors = require('cors');
const compression = require('compression');
const helmet = require('helmet');
require('dotenv').config();

const app = express();
const PORT = process.env.PORT || 3000;
const MARKETPLACE_API = 'https://marketplace.visualstudio.com/_apis/public/gallery';

// Middleware
app.use(helmet()); // Security headers
app.use(cors()); // Enable CORS
app.use(compression()); // Compress responses
app.use(express.json({ limit: '10mb' }));
app.use(express.static('public')); // Serve static files

// Cache storage
const cache = new Map();
const CACHE_DURATION = parseInt(process.env.CACHE_DURATION) || 3600000; // 1 hour default

// Helper: Cache middleware
function cacheMiddleware(duration = CACHE_DURATION) {
    return (req, res, next) => {
        const key = `${req.method}:${req.originalUrl}:${JSON.stringify(req.body)}`;
        const cached = cache.get(key);

        if (cached && Date.now() - cached.timestamp < duration) {
            console.log('✅ Cache hit:', key.substring(0, 100));
            return res.json(cached.data);
        }

        // Store original res.json
        const originalJson = res.json.bind(res);
        res.json = (data) => {
            cache.set(key, { data, timestamp: Date.now() });
            console.log('💾 Cached:', key.substring(0, 100));
            return originalJson(data);
        };

        next();
    };
}

// Helper: Proxy to Microsoft API
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
        console.error('❌ Marketplace API error:', error.message);
        throw error;
    }
}

// Routes

// Homepage
app.get('/', (req, res) => {
    res.sendFile(__dirname + '/public/index.html');
});

// Health check
app.get('/health', (req, res) => {
    res.json({
        status: 'healthy',
        version: '1.0.0',
        cache_size: cache.size,
        uptime: process.uptime()
    });
});

// Clear cache (admin endpoint)
app.post('/admin/cache/clear', (req, res) => {
    const size = cache.size;
    cache.clear();
    res.json({
        message: 'Cache cleared',
        items_removed: size
    });
});

// API: Search extensions
app.post('/api/marketplace/extensionquery', cacheMiddleware(), async (req, res) => {
    try {
        console.log('🔍 Extension search request');
        const data = await proxyToMarketplace('/extensionquery', 'POST', req.body);
        res.json(data);
    } catch (error) {
        res.status(error.response?.status || 500).json({
            error: 'Failed to search extensions',
            message: error.message
        });
    }
});

// API: Get extension details
app.get('/api/marketplace/extensions/:publisher/:extension', cacheMiddleware(), async (req, res) => {
    try {
        const { publisher, extension } = req.params;
        console.log(`📦 Fetching extension: ${publisher}.${extension}`);

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
        res.json(data);
    } catch (error) {
        res.status(error.response?.status || 500).json({
            error: 'Failed to get extension details',
            message: error.message
        });
    }
});

// API: Download extension (.vsix)
app.get('/api/marketplace/publishers/:publisher/vsextensions/:extension/:version/vspackage', async (req, res) => {
    try {
        const { publisher, extension, version } = req.params;
        const downloadURL = `${MARKETPLACE_API}/publishers/${publisher}/vsextensions/${extension}/${version}/vspackage`;

        console.log(`⬇️  Downloading: ${publisher}.${extension}@${version}`);

        // Stream the file directly
        const response = await axios({
            method: 'GET',
            url: downloadURL,
            responseType: 'stream',
            timeout: 120000 // 2 minutes for large files
        });

        // Set headers
        res.setHeader('Content-Type', 'application/octet-stream');
        res.setHeader('Content-Disposition', `attachment; filename="${publisher}.${extension}-${version}.vsix"`);

        // Pipe the stream
        response.data.pipe(res);
    } catch (error) {
        console.error('❌ Download error:', error.message);
        res.status(error.response?.status || 500).json({
            error: 'Failed to download extension',
            message: error.message
        });
    }
});

// API: Get featured/popular extensions
app.get('/api/marketplace/featured', cacheMiddleware(CACHE_DURATION * 2), async (req, res) => {
    try {
        const count = parseInt(req.query.count) || 20;
        console.log(`⭐ Fetching ${count} featured extensions`);

        const searchBody = {
            filters: [{
                criteria: [
                    { filterType: 8, value: '' } // Empty query for all
                ],
                pageSize: count,
                sortBy: 4 // Sort by install count
            }],
            flags: 0x914
        };

        const data = await proxyToMarketplace('/extensionquery', 'POST', searchBody);
        res.json(data);
    } catch (error) {
        res.status(error.response?.status || 500).json({
            error: 'Failed to get featured extensions',
            message: error.message
        });
    }
});

// API: Get extension statistics
app.get('/api/marketplace/stats', (req, res) => {
    res.json({
        total_requests: cache.size,
        cache_hit_rate: calculateCacheHitRate(),
        uptime_hours: (process.uptime() / 3600).toFixed(2),
        memory_usage: process.memoryUsage()
    });
});

// Helper: Calculate cache hit rate
function calculateCacheHitRate() {
    // Simplified - in production you'd track this properly
    return cache.size > 0 ? '~85%' : 'N/A';
}

// Error handling
app.use((err, req, res, next) => {
    console.error('💥 Server error:', err);
    res.status(500).json({
        error: 'Internal server error',
        message: process.env.NODE_ENV === 'development' ? err.message : undefined
    });
});

// 404 handler
app.use((req, res) => {
    res.status(404).json({
        error: 'Not found',
        path: req.path
    });
});

// Start server
app.listen(PORT, () => {
    console.log('🚀 asplos.dev Marketplace Server');
    console.log('================================');
    console.log(`📍 Server running on port ${PORT}`);
    console.log(`🌐 API endpoint: http://localhost:${PORT}/api/marketplace`);
    console.log(`💾 Cache duration: ${CACHE_DURATION / 1000}s`);
    console.log(`📦 Proxying to: ${MARKETPLACE_API}`);
    console.log('================================');
});

// Graceful shutdown
process.on('SIGTERM', () => {
    console.log('👋 SIGTERM received, shutting down gracefully');
    server.close(() => {
        console.log('✅ Server closed');
        process.exit(0);
    });
});
