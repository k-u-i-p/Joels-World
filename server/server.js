import express from 'express';
import http from 'http';
import cookieParser from 'cookie-parser';
import { SessionManager } from './managers/SessionManager.js';
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

const sessionManager = new SessionManager(path.resolve(__dirname, './sessions'));

// Custom unified session middleware to manually load the session either via Authorization Bearer token OR cookie
// Since iOS Safari CORS drops cookies, Capacitor explicit headers bypass it gracefully, while native browser users still lean on cookies.
app.use(async (req, res, next) => {
  const authHeader = req.headers.authorization;
  let token = null;

  if (authHeader && authHeader.startsWith('Bearer ')) {
    token = authHeader.slice(7);
  } else if (req.cookies && req.cookies.sid) {
    token = req.cookies.sid;
  }

  req.session = await sessionManager.get(token);

  if (!req.session) {
    req.session = await sessionManager.create();
    // Re-issue cookie so web browsers keep it seamlessly
    res.cookie('sid', req.session.id, { httpOnly: true, sameSite: 'lax' });
  }

  next();
});

const { wss, mapState } = setupWebSocket(server, sessionManager);

// Generate clip mask overlays locally FIRST
await processOverlays();

// Ensure ALL map layers (including new overlays) are sliced and generated before binding the port
await ensureMapChunks();
await ensureMinimaps();

setupStatic(app, server, port);
