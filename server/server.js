import express from 'express';
import http from 'http';
import cookieParser from 'cookie-parser';
import { setupWebSocket } from './websocket.js';
import { setupStatic } from './static.js';
import { ensureMapChunks } from '../scripts/slice_maps.js';
import { processOverlays } from '../scripts/create_overlays.js';

const port = process.env.PORT || 80;
const app = express();
const server = http.createServer(app);

app.use(cookieParser());

setupWebSocket(server);

// Generate clip mask overlays locally FIRST
await processOverlays();

// Ensure ALL map layers (including new overlays) are sliced and generated before binding the port
await ensureMapChunks();

setupStatic(app, server, port);
