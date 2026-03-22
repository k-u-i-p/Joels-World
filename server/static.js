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
    const emotesPath = path.resolve(__dirname, '../client/public/src/emotes.js');
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
    const charsPath = path.resolve(__dirname, '../client/public/src/characters.js');
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
    res.header("Access-Control-Allow-Headers", "Origin, X-Requested-With, Content-Type, Accept, Authorization");
    if (req.method === "OPTIONS") {
      return res.sendStatus(200);
    }
    next();
  });

  // Serve static assets natively
  app.use('/src', express.static(path.resolve(__dirname, '../client/public/src')));
  app.use('/public', express.static(path.resolve(__dirname, '../client/public')));

  app.get('/api/config', (req, res) => {
    res.json({
      validEmotes: cachedEmotes,
      validHairStyles: cachedHairStyles
    });
  });

  app.use('/', express.static(path.resolve(__dirname, '../client/public'))); // Catch-all for assets at root like /grounds/

  app.use(async (req, res, next) => {
    if (req.path === '/admin.html') {

      if (req.query.admin === 'true') {
        if (req.session) {
          req.session.isAdmin = true;
          await req.session.save();
        }
      } else if (req.query.admin === 'false') {
        if (req.session) {
          req.session.isAdmin = false;
          await req.session.save();
        }
      }

      const isAdminSession = req.session && req.session.isAdmin;

      return res.render('index', {
        isAdmin: isAdminSession,
        validEmotes: cachedEmotes,
        validHairStyles: cachedHairStyles
      });
    }

    // Pass other non-static requests through
    next();
  });

  server.listen(port, '0.0.0.0', () => {
    console.log(`Server & WebSocket running natively on http://0.0.0.0:${port}`);
  });
}
