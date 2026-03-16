import fs from 'fs';
import path from 'path';
import { WebSocketServer } from 'ws';
import { handleAdminMessage } from './admin.js';
import { fileURLToPath } from 'url';
import { PhysicsEngine } from '../src/physics.js';
import { AIAgentManager } from './managers/AIAgentManager.js';
import { NPCManager } from './managers/NPCManager.js';
import { MapManager } from './managers/MapManager.js';
import { ChatManager } from './managers/ChatManager.js';
import { ClientManager } from './managers/ClientManager.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const physicsEngine = new PhysicsEngine();



export function setupWebSocket(server, sessionMiddleware) {
  const wss = new WebSocketServer({ server });

  const mapManager = new MapManager();
  const npcManager = new NPCManager(mapManager.mapState);
  const aiAgentManager = new AIAgentManager(mapManager.mapState, npcManager);
  const chatManager = new ChatManager(mapManager, npcManager, aiAgentManager);
  const clientManager = new ClientManager(mapManager, npcManager, aiAgentManager, chatManager);

  mapManager.initializeMaps(npcManager);

  aiAgentManager.startAIAgent();
  npcManager.startPatrolLoop();

  setInterval(() => {
    const updatesBuffer = [];
    for (const mapId in mapManager.mapState) {
      const mapObj = mapManager.mapState[mapId];
      updatesBuffer.length = 0;

      for (const charId in mapObj.dirtyCharacters) {
        updatesBuffer.push(mapObj.dirtyCharacters[charId]);
      }

      if (updatesBuffer.length > 0) {
        const broadcastMsg = JSON.stringify({ type: 'tick', characters: updatesBuffer });
        mapObj.clients.forEach(client => {
          if (client.readyState === 1) client.send(broadcastMsg);
        });
        mapObj.dirtyCharacters = {};
      }
    }
  }, 100);



  wss.on('connection', (ws, req) => {
    clientManager.handleConnection(ws, req, sessionMiddleware, wss);
  });

  return { wss, mapState: mapManager.mapState };
}

