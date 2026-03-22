import fs from 'fs';
import path from 'path';
import { WebSocketServer } from 'ws';
import { handleAdminMessage } from './admin.js';
import { fileURLToPath } from 'url';
import { PhysicsEngine } from '../client/public/src/physics.js';
import { AIAgentManager } from './managers/AIAgentManager.js';
import { NPCManager } from './managers/NPCManager.js';
import { MapManager } from './managers/MapManager.js';
import { ChatManager } from './managers/ChatManager.js';
import { ClientManager } from './managers/ClientManager.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const physicsEngine = new PhysicsEngine();



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

    clientManager.handleConnection(ws, wss, session, urlParams, sessionID);
  });

  return { wss };
}

