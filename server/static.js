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
        return res.render('index', { isAdmin: isAdminSession });
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
