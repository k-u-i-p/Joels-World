import express from 'express';
import path from 'path';
import { fileURLToPath } from 'url';
import { VALID_EMOTES } from './emotes.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export function setupStatic(app, server, port) {
  // The list used to be scraped out of the retired web client's `emotes.js`; it now lives in
  // `server/emotes.js` (PLAN.md §8). The poses themselves are in `Engine/Entity/Emotes.swift`.
  const cachedEmotes = [...VALID_EMOTES].sort();

  // Allow CORS specifically for media/assets so the iOS client can fetch audio without Access Control checks failing.
  app.use((req, res, next) => {
    res.header("Access-Control-Allow-Origin", "*");
    res.header("Access-Control-Allow-Headers", "Origin, X-Requested-With, Content-Type, Accept, Authorization");
    if (req.method === "OPTIONS") {
      return res.sendStatus(200);
    }
    next();
  });

  app.get('/api/config', (req, res) => {
    res.json({
      validEmotes: cachedEmotes
    });
  });

  // The whole asset tree — map tiles, models, audio, avatars, minimaps, minigame art — is
  // served from the root, which is the URL shape the native clients were written against
  // (`/media/laser.mp3`, `/minimaps/0.png`, `/junior_school/chunks/...`). It moved here from
  // `client/public` when the web client was retired; the URLs did not change.
  app.use('/', express.static(path.resolve(__dirname, './assets')));

  server.listen(port, '0.0.0.0', () => {
    console.log(`Server & WebSocket running natively on http://0.0.0.0:${port}`);
  });
}
