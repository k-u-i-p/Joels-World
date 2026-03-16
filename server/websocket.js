import fs from 'fs';
import path from 'path';
import { WebSocketServer } from 'ws';
import { handleAdminMessage } from './admin.js';
import { fileURLToPath } from 'url';
import { PhysicsEngine } from '../src/physics.js';
import { AIAgentManager } from './managers/AIAgentManager.js';
import { NPCManager } from './managers/NPCManager.js';
import { MapManager } from './managers/MapManager.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const physicsEngine = new PhysicsEngine();



export function setupWebSocket(server, sessionMiddleware) {
  const wss = new WebSocketServer({ server });

  const mapManager = new MapManager();
  const npcManager = new NPCManager(mapManager.mapState);
  const aiAgentManager = new AIAgentManager(mapManager.mapState, npcManager);

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

  const colors = ['#e74c3c', '#8e44ad', '#3498db', '#1abc9c', '#2ecc71', '#f1c40f', '#e67e22', '#34495e'];
  function getRandomColor() {
    return colors[Math.floor(Math.random() * colors.length)];
  }

  const shoeColors = ['#111111', '#5e3a1f', '#7f8c8d']; // Black, Brown, Grey

  function sendError(ws, message) {
    if (ws.readyState === 1) {
      ws.send(JSON.stringify({ type: 'error', message }));
    }
    ws.close();
  }

  let globalPlayerIdCounter = 255;

  wss.on('connection', (ws, req) => {
    console.log('Client connected');

    sessionMiddleware(req, {}, () => {
      const urlParams = new URLSearchParams(req.url.split('?')[1] || "");
      const stateParam = urlParams.get('state') || 'new';
      const session = req.session;

      if (stateParam === 'running' && req.headers.cookie && req.headers.cookie.includes('connect.sid') && (!session || !session.player)) {
        sendError(ws, 'No player session');
        return;
      } else if (session && session.player) {
        console.log(session.player.name + ' has resumed game with valid session');
      }

      ws.isAdmin = session ? session.isAdmin : false;

      const mapIdParam = urlParams.get('mapId');
      let requestedMapId = mapIdParam !== null ? parseInt(mapIdParam, 10) : 0;
      if (session && session.player && session.player.mapId !== undefined) {
        requestedMapId = session.player.mapId;
      }
      
      ws.mapId = mapManager.getMap(requestedMapId) ? requestedMapId : mapManager.getFirstMapId();
      let mapData = mapManager.getMap(ws.mapId);

      if (!mapData) {
        console.error(`No map found to attach client to (requested: ${requestedMapId})`);
        ws.close();
        return;
      }

      mapData.clients.add(ws);

      let currentMaxId = globalPlayerIdCounter - 1;
      for (const mId in mapManager.mapState) {
        const data = mapManager.mapState[mId];
        if (data.characters) {
          for (const charId in data.characters) {
            const char = data.characters[charId];
            if (typeof char.id === 'number' && char.id > currentMaxId) {
              currentMaxId = char.id;
            }
          }
        }
        if (data.npcs) {
          for (const npc of data.npcs) {
            if (typeof npc.id === 'number' && npc.id > currentMaxId) {
              currentMaxId = npc.id;
            }
          }
        }
      }
      globalPlayerIdCounter = currentMaxId + 1;
      if (globalPlayerIdCounter < 255) globalPlayerIdCounter = 255;



      // If the session already has an attached character, boot them into the game instantly.
      if (session && session.player) {
        // Find any existing ghost connection or other window for this session and terminate it
        for (const client of wss.clients) {
          if (client !== ws && client.readyState === 1 && client.clientId === session.player.id) {
            sendError(client, 'Session already active in another window.');
          }
        }

        ws.clientId = session.player.id;

        // Override persistent coordinates with a fresh spawn location dynamically 
        const { spawnX, spawnY } = mapManager.generateSpawnCoords(mapData.id);
        session.player.x = spawnX;
        session.player.y = spawnY;

        mapData.characters[ws.clientId] = session.player;
        mapData.dirtyCharacters[ws.clientId] = session.player;

        console.log(`Resuming session character ${session.player.name} (${ws.clientId})`);
        ws.send(mapManager.getInitPayload(mapData.id, session.player));
      }

      ws.on('message', (message) => {
        try {
          const data = JSON.parse(message);

          if (data.type === 'create_character') {
            // If they already have a session char, ignore
            if (session && session.player) return;

            let playerName = data.name || '';
            if (!playerName && ws.isAdmin) playerName = 'Admin';

            if (!ws.isAdmin && (!playerName || !/^[a-zA-Z]+$/.test(playerName))) {
              sendError(ws, 'Invalid Name. Please use only English letters with no spaces or symbols.');
              return;
            }

            const newPlayerId = globalPlayerIdCounter++;
            ws.clientId = newPlayerId;

            const { spawnX, spawnY } = mapManager.generateSpawnCoords(mapData.id);

            const newChar = {
              id: newPlayerId,
              name: playerName.substring(0, 15),
              x: spawnX,
              y: spawnY,
              width: 40,
              height: 40,
              rotation: 0,
              gender: Math.random() > 0.5 ? 'male' : 'female',
              shirtColor: getRandomColor(),
              pantsColor: getRandomColor(),
              armColor: getRandomColor(),
              shoeColor: shoeColors[Math.floor(Math.random() * shoeColors.length)],
              hairStyle: ['short', 'long', 'ponytail', 'spiky', 'messy', 'bald'][Math.floor(Math.random() * 6)],
              hairColor: ['#f1c40f', '#5c3a21', '#2c3e50', '#000000'][Math.floor(Math.random() * 4)],
              interaction_radius: 150
            };

            if (session) {
              newChar.mapId = ws.mapId;
              session.player = newChar;
              session.save();
            }

            mapData.characters[newPlayerId] = newChar;
            mapData.dirtyCharacters[newPlayerId] = newChar;

            sendInitPayload(mapData, newChar);

            npcManager.logEventToNearbyNPCs(mapData, `${newChar.name || 'Student'} (${newPlayerId}) entered the map`, aiAgentManager);

            return;
          }

          // Drop all standard gameplay packets if they don't have a spawned character yet
          if (!ws.clientId || !mapData.characters[ws.clientId]) return;

          if (data.type === 'update') {
            const char = data.character;

            ws.clientId = char.id;
            mapData.characters[char.id] = char;
            mapData.dirtyCharacters[char.id] = char;
          } else if (data.type === 'log') {
            const now = Date.now();
            if (ws.lastLogTime && now - ws.lastLogTime < 2000) return;
            ws.lastLogTime = now;

            console.log("LOG EVENT: ", data);
            if (typeof data.message !== 'string') return;

            const logMsg = data.message.trim();
            if (!logMsg || logMsg.length > 300) return;

            // Maintain LLM context security against newline injections or HTML markup
            if (/[\r\n\t\\<>]/.test(logMsg)) {
              console.warn(`[Security] Rejected malformed log message from ${ws.clientId}`);
              return;
            }

            npcManager.logEventToNearbyNPCs(mapData, logMsg, aiAgentManager, data.npc_id);
          } else if (data.type === 'chat') {
            const now = Date.now();
            if (ws.lastChatTime && now - ws.lastChatTime < 2000) return;
            ws.lastChatTime = now;

            if (typeof data.message !== 'string') return;

            data.message = data.message.trim();
            if (!data.message || data.message.length > 200) return;

            // Discard if it contains newlines, tabs, escape backslashes, or HTML brackets.
            if (/[\r\n\t\\<>]/.test(data.message)) {
              sendError(ws, 'Invalid message. Please use only English letters with no spaces or symbols.');
              return;
            }

            // Log chat
            const sender = mapData.characters[ws.clientId];
            const name = sender ? sender.name || ws.clientId : ws.clientId;
            if (sender) {
              npcManager.logEventToNearbyNPCs(mapData, `${name} (${ws.clientId}) said: "${data.message}"`, aiAgentManager);
            } else {
              npcManager.logEventToNearbyNPCs(mapData, `${name} (${ws.clientId}) said: "${data.message}"`, aiAgentManager);
            }

            const broadcastMsg = JSON.stringify({ type: 'chat', id: ws.clientId, message: data.message });
            mapData.clients.forEach(client => {
              if (client.readyState === 1) {
                client.send(broadcastMsg);
              }
            });
          } else if (data.type === 'disconnect') {
            const sender = mapData.characters[ws.clientId];

            const name = sender ? sender.name || ws.clientId : ws.clientId;

            npcManager.logEventToNearbyNPCs(mapData, `${name} (${ws.clientId}) left the map`, aiAgentManager);

            const id = data.id;
            delete mapData.characters[id];
            delete mapData.dirtyCharacters[id];
            const broadcastMsg = JSON.stringify({ type: 'disconnect', id });
            mapData.clients.forEach(client => {
              if (client !== ws && client.readyState === 1) {
                client.send(broadcastMsg);
              }
            });
          } else if (data.type === 'change_map') {
            const requestedMapId = Number(data.mapId);
            const newMapData = mapManager.getMap(requestedMapId);

            if (mapData.can_leave === false && data.force !== true && !ws.isAdmin) {
              const charName = (mapData.characters[ws.clientId] && mapData.characters[ws.clientId].name) || (typeof newChar !== 'undefined' ? newChar.name : '') || 'Student';
              npcManager.logEventToNearbyNPCs(mapData, `${charName} (${ws.clientId}) tried to leave ${mapData.name}`, aiAgentManager);
              ws.send(JSON.stringify({ type: 'map_change_rejected' }));
              return;
            }

            if (newMapData && ws.mapId !== requestedMapId) {
              const oldChar = mapData.characters[ws.clientId] || newChar;

              npcManager.logEventToNearbyNPCs(mapData, `${oldChar.name} (${ws.clientId}) left the map`, aiAgentManager);

              delete mapData.characters[ws.clientId];
              delete mapData.dirtyCharacters[ws.clientId];
              const disconnectMsg = JSON.stringify({ type: 'disconnect', id: ws.clientId });
              mapData.clients.forEach(client => {
                if (client !== ws && client.readyState === 1) {
                  client.send(disconnectMsg);
                }
              });
              mapData.clients.delete(ws);

              // Update client reference
              ws.mapId = requestedMapId;
              mapData = newMapData;

              if (session && session.player) {
                session.player.mapId = requestedMapId;
              }

              // Reset position safely using spawn_area if available
              const { spawnX, spawnY } = mapManager.generateSpawnCoords(newMapData.id);

              oldChar.x = spawnX;
              oldChar.y = spawnY;
              oldChar.emote = null;

              if (session && session.player) {
                session.save();
              }

              mapData.characters[ws.clientId] = oldChar;
              mapData.dirtyCharacters[ws.clientId] = oldChar;
              mapData.clients.add(ws);

              npcManager.logEventToNearbyNPCs(mapData, `${oldChar.name || 'Student'} (${ws.clientId}) entered ${mapData.name}`, aiAgentManager);

              // Send init to immediately reset the client seamlessly
              ws.send(mapManager.getInitPayload(mapData.id, oldChar));
            }
          } else {
            handleAdminMessage(ws, data, mapData);
          }
        } catch (err) {
          console.error('Error processing message:', err);
        }
      });

      ws.on('close', () => {
        if (ws.clientId) {
          console.log('Client disconnected', ws.clientId);

          let isReconnected = false;
          for (const client of mapData.clients) {
            if (client !== ws && client.readyState === 1 && client.clientId === ws.clientId) {
              isReconnected = true;
              break;
            }
          }

          if (!isReconnected) {
            delete mapData.characters[ws.clientId];
            delete mapData.dirtyCharacters[ws.clientId];
            const broadcastMsg = JSON.stringify({ type: 'disconnect', id: ws.clientId });
            mapData.clients.forEach(client => {
              if (client !== ws && client.readyState === 1) {
                client.send(broadcastMsg);
              }
            });
          } else {
            console.log(`Client ${ws.clientId} closed, but a new active socket was found. Skipping deletion.`);
          }
        }
        mapData.clients.delete(ws);
      });
    });
  });

  return { wss, mapState: mapManager.mapState };
}

