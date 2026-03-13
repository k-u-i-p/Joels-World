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

// Ensure map chunks are fully sliced and generated before binding the main port
await ensureMapChunks();

// Generate clip mask overlays locally
await processOverlays();

setupStatic(app, server, port);
