import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export class NPCManager {
  constructor(mapState) {
    this.mapState = mapState;
  }

  initializeMapNPCs(mapDef, mapObj) {
    if (!mapDef.npcs) return;

    const npcPath = path.resolve(__dirname, '..', 'data', mapDef.npcs);
    try {
      if (fs.existsSync(npcPath)) {
        mapObj.npcs = JSON.parse(fs.readFileSync(npcPath, 'utf-8'));

        // Initialize/clear log files for agent NPCs
        mapObj.npcs.forEach(npc => {
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

  startPatrolLoop() {
    setInterval(() => {
      const now = Date.now();
      const updatesDictionary = {}; // MapID -> array of dirty characters
      let hasUpdates = false;

      for (const mapId in this.mapState) {
        const mapObj = this.mapState[mapId];

        if (mapObj.npcs && mapObj.npcs.length > 0) {
          for (let i = 0; i < mapObj.npcs.length; i++) {
            const npc = mapObj.npcs[i];
            
            if (npc.waypoints && Array.isArray(npc.waypoints) && npc.waypoints.length > 0) {
              if (npc._startX === undefined) {
                npc._startX = npc.x;
                npc._startY = npc.y;
                npc._startRotation = npc.rotation || 0;
                npc._moveIdx = 0;
                npc._lastMoveTime = now;
              }

              let currentWaitTime = npc.move_time || 3000;
              if (npc._moveIdx > 0 && npc._moveIdx <= npc.waypoints.length) {
                const activeWaypoint = npc.waypoints[npc._moveIdx - 1];
                if (activeWaypoint && activeWaypoint.move_time !== undefined) {
                  currentWaitTime = activeWaypoint.move_time;
                }
              }

              if (now - npc._lastMoveTime >= currentWaitTime) {
                npc._lastMoveTime = now;
                npc._moveIdx = (npc._moveIdx + 1) % (npc.waypoints.length + 2);

                npc._currentOffsetX = npc._currentOffsetX || 0;
                npc._currentOffsetY = npc._currentOffsetY || 0;
                npc._currentOffsetRotation = npc._currentOffsetRotation || 0;

                let offset = { x: 0, y: 0, rotation: 0 };
                
                if (npc._moveIdx > 0 && npc._moveIdx <= npc.waypoints.length) {
                  offset = npc.waypoints[npc._moveIdx - 1];
                } else if (npc._moveIdx === npc.waypoints.length + 1) {
                  offset = { x: -npc._currentOffsetX, y: -npc._currentOffsetY };
                } else if (npc._moveIdx === 0) {
                  offset = { rotation: -npc._currentOffsetRotation };
                }

                if (offset.x !== undefined) npc._currentOffsetX += offset.x;
                if (offset.y !== undefined) npc._currentOffsetY += offset.y;
                if (offset.rotation !== undefined) npc._currentOffsetRotation += offset.rotation;

                if (npc._moveIdx === 0) {
                   npc._currentOffsetX = 0;
                   npc._currentOffsetY = 0;
                   npc._currentOffsetRotation = 0;
                }

                npc.x = npc._startX + npc._currentOffsetX;
                npc.y = npc._startY + npc._currentOffsetY;
                npc.rotation = npc._startRotation + npc._currentOffsetRotation;

                mapObj.dirtyCharacters[npc.id] = npc;
                hasUpdates = true;
              }
            }
          }
        }
      }
    }, 100);
  }
}
