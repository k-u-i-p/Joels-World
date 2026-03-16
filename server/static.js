import express from 'express';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export function setupStatic(app, server, port) {
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
      const hasAdminQuery = req.query.admin === 'true';

      if (hasAdminQuery) {
        req.session.isAdmin = true;
      }
    }

    // Only serve HTML files for the root or exact paths to prevent catching /api or /ws traffic
    if (req.path === '/' || req.path === '/index.html' || req.path === '/admin.html') {
      try {
        const isAdminSession = req.session && req.session.isAdmin;
        let validEmotes = [];
        let validHairStyles = [];

        if (isAdminSession) {
          try {
            const emotesPath = path.resolve(__dirname, '../src/emotes.js');
            const emotesCode = fs.readFileSync(emotesPath, 'utf8');
            const regex = /^  ([a-zA-Z0-9_]+): \{/gm;
            let m;
            while ((m = regex.exec(emotesCode)) !== null) {
              validEmotes.push(m[1]);
            }
            validEmotes.sort();
          } catch (e) {
            console.error("Failed to parse emotes:", e);
          }

          try {
            const charsPath = path.resolve(__dirname, '../src/characters.js');
            const charsCode = fs.readFileSync(charsPath, 'utf8');
            const regex = /style === '([a-zA-Z0-9_]+)'/g;
            let m;
            while ((m = regex.exec(charsCode)) !== null) {
              if (!validHairStyles.includes(m[1])) {
                validHairStyles.push(m[1]);
              }
            }
            // Add fallback default cases that are implicit or explicitly returned inside defaults
            if (!validHairStyles.includes('long')) validHairStyles.push('long');
            if (!validHairStyles.includes('bald')) validHairStyles.push('bald');
            validHairStyles.sort();
          } catch (e) {
            console.error("Failed to parse hairstyles:", e);
          }
        }

        return res.render('index', { 
          isAdmin: isAdminSession,
          validEmotes,
          validHairStyles
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
