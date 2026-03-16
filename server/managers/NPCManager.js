import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { PhysicsEngine } from '../../src/physics.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export class NPCManager {
  constructor(mapManager) {
    this.mapManager = mapManager;
    this.physicsEngine = new PhysicsEngine();
  }

  logEventToNearbyNPCs(mapData, logEntry, aiAgentManager, specificNpcId = null) {
    if (!mapData.npcs) return;

    const logLine = typeof logEntry === 'string' ? logEntry : logEntry.message;
    if (!logLine) return; // Drop empty logs

    const targetNpcs = new Set();

    if (specificNpcId) {
      const npc = mapData.npcs.find(n => n.id === specificNpcId);
      if (npc) targetNpcs.add(npc);
    } else {
      // Proximity scan for all nearby NPCs
      if (mapData.characters) {
        Object.values(mapData.characters).forEach(player => {
          const npcs = this.physicsEngine.findCharacters(mapData.npcs, player.x, player.y);
          npcs.forEach(n => targetNpcs.add(n));
        });
      }
    }

    targetNpcs.forEach(npc => {
      if (npc.agent && npc.agent.log_file) {
        const logPath = path.resolve(__dirname, '..', 'data', npc.agent.log_file);
        let logArr = [];
        try {
          if (fs.existsSync(logPath)) {
            const raw = fs.readFileSync(logPath, 'utf8');
            logArr = raw.split('\n').filter(line => line.trim().length > 0);
          }
        } catch (e) {
          console.error('Error reading log array:', e);
        }

        logArr.push(logLine);

        if (logArr.length > 50) {
          logArr = logArr.slice(logArr.length - 50);
        }

        try {
          fs.writeFileSync(logPath, logArr.join('\n') + '\n', 'utf8');
        } catch (e) {
          console.error('Error writing log array:', e);
        }

        if (aiAgentManager) {
          aiAgentManager.pulseAgent(mapData.id, npc.id);
        }
      }
    });
  }

  initializeMapNPCs(mapDef, mapObj) {
    if (!mapDef.npcs) return;

    const npcPath = path.resolve(__dirname, '..', 'data', mapDef.npcs);
    try {
      if (fs.existsSync(npcPath)) {
        mapObj.npcs = JSON.parse(fs.readFileSync(npcPath, 'utf-8'));

        // Initialize/clear log files for agent NPCs
        mapObj.npcs.forEach(npc => {
          npc._startX = npc.x;
          npc._startY = npc.y;
          npc.rotation = npc.rotation || 0;
          npc._startRotation = npc.rotation;

          if (npc.agent && npc.agent.log_file) {
            const logPath = path.resolve(__dirname, '..', 'data', npc.agent.log_file);
            try {
              fs.writeFileSync(logPath, '', 'utf8');
            } catch (e) {
              console.error(`[NPCManager] Error clearing log configuration for npc ${npc.id}:`, e);
            }
          }
        });
      }
    } catch (e) {
      console.error(`[NPCManager] Error loading npcs for map ${mapDef.id}:`, e);
    }

    try {
      if (fs.existsSync(npcPath)) {
        let npcTimer;
        fs.watch(npcPath, (eventType, filename) => {
          if (npcTimer) clearTimeout(npcTimer);
          npcTimer = setTimeout(() => {
            try {
              if (fs.existsSync(npcPath)) {
                mapObj.npcs = JSON.parse(fs.readFileSync(npcPath, 'utf-8'));
                mapObj.npcs.forEach(npc => {
                  npc._startX = npc.x;
                  npc._startY = npc.y;
                  npc.rotation = npc.rotation || 0;
                  npc._startRotation = npc.rotation;
                });
                console.log(`[NPCManager] NPCs updated for map ${mapDef.id}, broadcasting...`);
                const broadcastMsg = JSON.stringify({ type: 'npcs_update', npcs: mapObj.npcs });
                mapObj.clients.forEach(client => {
                  if (client.readyState === 1) client.send(broadcastMsg);
                });
              }
            } catch (e) {
              console.error(`[NPCManager] Error on npc config watch rebuild:`, e);
            }
          }, 50);
        });
      }
    } catch (e) {
      console.error(`[NPCManager] Error setting up watch for npcs on map ${mapDef.id}:`, e);
    }
  }

}
