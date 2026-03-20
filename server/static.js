import express from 'express';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export function setupStatic(app, server, port) {
  let cachedEmotes = [];
  let cachedHairStyles = [];

  // Parse emotes once on boot
  try {
    const emotesPath = path.resolve(__dirname, '../src/emotes.js');
    const emotesCode = fs.readFileSync(emotesPath, 'utf8');
    const regex = /^  ([a-zA-Z0-9_]+): \{/gm;
    let m;
    while ((m = regex.exec(emotesCode)) !== null) {
      cachedEmotes.push(m[1]);
    }
    cachedEmotes.sort();
  } catch (e) {
    console.error("Failed to parse emotes during boot cache:", e);
  }

  // Parse hairstyles once on boot
  try {
    const charsPath = path.resolve(__dirname, '../src/characters.js');
    const charsCode = fs.readFileSync(charsPath, 'utf8');
    const regex = /style === '([a-zA-Z0-9_]+)'/g;
    let m;
    while ((m = regex.exec(charsCode)) !== null) {
      if (!cachedHairStyles.includes(m[1])) {
        cachedHairStyles.push(m[1]);
      }
    }
    // Add fallback default cases that are implicit or explicitly returned inside defaults
    if (!cachedHairStyles.includes('long')) cachedHairStyles.push('long');
    if (!cachedHairStyles.includes('bald')) cachedHairStyles.push('bald');
    cachedHairStyles.sort();
  } catch (e) {
    console.error("Failed to parse hairstyles during boot cache:", e);
  }

  // Allow CORS specifically for media/assets so the iOS client can fetch audio without Access Control checks failing.
  app.use((req, res, next) => {
    res.header("Access-Control-Allow-Origin", "*");
    res.header("Access-Control-Allow-Headers", "Origin, X-Requested-With, Content-Type, Accept");
    next();
  });

  // Serve static assets natively
  app.use('/src', express.static(path.resolve(__dirname, '../src')));
  app.use('/public', express.static(path.resolve(__dirname, '../public')));
  app.use('/', express.static(path.resolve(__dirname, '../public'))); // Catch-all for assets at root like /grounds/

  app.use(async (req, res, next) => {
    if (req.path === '/' || req.path === '/index.html') {
      if (req.query.admin === 'true') {
        req.session.isAdmin = true;
      } else if (req.query.admin === 'false') {
        req.session.isAdmin = false;
      }
    }

    // Only serve HTML files for the root or exact paths to prevent catching /api or /ws traffic
    if (req.path === '/' || req.path === '/index.html' || req.path === '/admin.html') {
      try {
        const isAdminSession = req.session && req.session.isAdmin;

        return res.render('index', {
          isAdmin: isAdminSession,
          validEmotes: cachedEmotes,
          validHairStyles: cachedHairStyles
        });
      } catch (e) {
        return next(e);
      }
    }

    // Pass other non-static requests through
    next();
  });

  server.listen(port, () => {
    console.log(`Server & WebSocket running natively on http://localhost:${port}`);
  });
}
