import { createServer as createViteServer } from 'vite';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { createSession, getSession } from './session.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export async function setupVite(app, server, port) {
  const vite = await createViteServer({
    server: { middlewareMode: true },
    appType: 'custom'
  });

  app.use(vite.middlewares);

  app.use(async (req, res, next) => {
    const cookies = req.cookies || {};
    let sessionId = cookies.SSID;
    let session = sessionId ? getSession(sessionId) : null;

    if (!session) {
      sessionId = createSession();
      res.cookie('SSID', sessionId, { httpOnly: true, path: '/' });
      session = getSession(sessionId);
    }

    if (req.path === '/' || req.path === '/index.html') {
      const hasAdminQuery = req.query.admin === 'true';

      if (hasAdminQuery) {
        session.isAdmin = true;
      }
    }

    const url = req.originalUrl;
    try {
      let index;

      if (session && session.isAdmin) {
        index = fs.readFileSync(path.resolve(__dirname, '../admin.html'), 'utf-8');
      } else {
        index = fs.readFileSync(path.resolve(__dirname, '../index.html'), 'utf-8');
      }

      res.status(200).set({ 'Content-Type': 'text/html' }).end(index);
    } catch (e) {
      vite.ssrFixStacktrace(e);
      next(e);
    }
  });

  server.listen(port, () => {
    console.log(`Server & WebSocket running on http://localhost:${port}`);
  });
}
