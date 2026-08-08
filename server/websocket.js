import crypto from 'crypto';
import fs from 'fs';
import path from 'path';
import { WebSocketServer } from 'ws';
import { handleAdminMessage } from './admin.js';
import { fileURLToPath } from 'url';
import { PhysicsEngine } from './physics.js';
import { AIAgentManager } from './managers/AIAgentManager.js';
import { NPCManager } from './managers/NPCManager.js';
import { MapManager } from './managers/MapManager.js';
import { ChatManager } from './managers/ChatManager.js';
import { ClientManager } from './managers/ClientManager.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const physicsEngine = new PhysicsEngine();

const LOOPBACK_ADDRESSES = new Set(['127.0.0.1', '::1', '::ffff:127.0.0.1']);

function timingSafeMatch(a, b) {
  const left = Buffer.from(String(a));
  const right = Buffer.from(String(b));
  if (left.length !== right.length) return false;
  return crypto.timingSafeEqual(left, right);
}

/**
 * The native macOS admin editor has no browser session to carry the `isAdmin` flag the old
 * web page set by visiting `/admin.html?admin=true`, so it presents `?adminKey=` on the
 * socket handshake instead. Since the web client was retired this is the only way in.
 *
 * With `ADMIN_KEY` set, the key must match. Without it, only loopback connections are
 * granted — so `npm run dev` needs no configuration while production has to opt in.
 */
export function grantsAdmin(urlParams, req) {
  const presented = urlParams.get('adminKey');
  if (!presented) return false;

  const expected = process.env.ADMIN_KEY;
  if (expected) return timingSafeMatch(presented, expected);

  const address = req.socket ? req.socket.remoteAddress : null;
  if (LOOPBACK_ADDRESSES.has(address)) return true;

  console.warn(`[admin] Rejected adminKey from ${address}: ADMIN_KEY is not set on this server`);
  return false;
}



export function setupWebSocket(server, sessionManager) {
  const wss = new WebSocketServer({ server });

  const mapManager = new MapManager();
  const npcManager = new NPCManager(mapManager);
  const aiAgentManager = new AIAgentManager(mapManager, npcManager);
  const chatManager = new ChatManager(mapManager, npcManager, aiAgentManager);
  const clientManager = new ClientManager(mapManager, npcManager, aiAgentManager, chatManager);

  mapManager.initializeMaps(npcManager);

  aiAgentManager.startAIAgent();

  //Server tick loop. Updates clients with character positions
  setInterval(() => {
    for (const mapObj of mapManager.getAllMaps()) {
      const updatesBuffer = mapManager.getDirtyCharacters(mapObj.id);

      if (updatesBuffer.length > 0) {
        const broadcastMsg = JSON.stringify({ type: 'tick', characters: updatesBuffer });
        mapManager.broadcastMessage(mapObj.id, broadcastMsg);
        mapManager.clearDirtyCharacters(mapObj.id);
      }
    }
  }, 200);

  wss.on('connection', async (ws, req) => {
    const urlParams = new URLSearchParams(req.url.split('?')[1] || "");
    const token = urlParams.get('token');

    let session = await sessionManager.get(token);
    let sessionID = session ? session.id : null;

    if (!session) {
      session = await sessionManager.create();
      sessionID = session.id;
    }

    if (grantsAdmin(urlParams, req) && !session.isAdmin) {
      session.isAdmin = true;
      await session.save();
      console.log(`[admin] Session ${sessionID} promoted to admin via adminKey`);
    }

    clientManager.handleConnection(ws, wss, session, urlParams, sessionID);
  });

  return { wss };
}

