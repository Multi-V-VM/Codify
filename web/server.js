/**
 * asplos.dev - VSCode Extension Marketplace Proxy Server
 *
 * This file owns process setup and HTTP lifecycle. Request routing lives in
 * router.js so it can be reused and tested without binding a port.
 */

const express = require('express');
const cors = require('cors');
const compression = require('compression');
const helmet = require('helmet');
const path = require('path');
require('dotenv').config();

const { router, CACHE_DURATION, MARKETPLACE_API } = require('./router');

const app = express();
const PORT = process.env.PORT || 3000;

app.use(helmet());
app.use(cors());
app.use(compression());
app.use(express.json({ limit: '10mb' }));
app.use(express.static(path.join(__dirname, 'public')));
app.use(router);

app.use((err, req, res, next) => {
    console.error('Server error:', err);
    res.status(500).json({
        error: 'Internal server error',
        message: process.env.NODE_ENV === 'development' ? err.message : undefined
    });
});

app.use((req, res) => {
    res.status(404).json({
        error: 'Not found',
        path: req.path
    });
});

const server = app.listen(PORT, () => {
    console.log('asplos.dev Marketplace Server');
    console.log('================================');
    console.log(`Server running on port ${PORT}`);
    console.log(`API endpoint: http://localhost:${PORT}/api/marketplace`);
    console.log(`Cache duration: ${CACHE_DURATION / 1000}s`);
    console.log(`Proxying to: ${MARKETPLACE_API}`);
    console.log('================================');
});

function shutdown(signal) {
    console.log(`${signal} received, shutting down gracefully`);
    server.close(() => {
        console.log('Server closed');
        process.exit(0);
    });
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
