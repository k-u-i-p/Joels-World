import express from 'express';
import http from 'http';
import cookieParser from 'cookie-parser';
import session from 'express-session';
import sessionFileStore from 'session-file-store';
import { setupWebSocket } from './websocket.js';
import { setupStatic } from './static.js';
import { ensureMapChunks } from './scripts/slice_maps.js';
import { processOverlays } from './scripts/create_overlays.js';
import { ensureMinimaps } from './scripts/generate_minimaps.js';

import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const port = process.env.PORT || 80;
const app = express();
const server = http.createServer(app);

app.set('view engine', 'ejs');
app.set('views', path.resolve(__dirname, './views'));

app.use(cookieParser());

const FileStore = sessionFileStore(session);

const sessionMiddleware = session({
  store: new FileStore({ path: path.resolve(__dirname, './sessions') }),
  secret: 'joels-world-secret',
  resave: false,
  saveUninitialized: true
});
app.use(sessionMiddleware);

const { wss, mapState } = setupWebSocket(server, sessionMiddleware);

// Generate clip mask overlays locally FIRST
await processOverlays();

// Ensure ALL map layers (including new overlays) are sliced and generated before binding the port
await ensureMapChunks();
await ensureMinimaps();

setupStatic(app, server, port);
