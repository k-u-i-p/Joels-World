import { handleAdminMessage } from '../admin.js';

export class ClientManager {
  constructor(mapManager, npcManager, aiAgentManager, chatManager) {
    this.mapManager = mapManager;
    this.npcManager = npcManager;
    this.aiAgentManager = aiAgentManager;
    this.chatManager = chatManager;
    this.globalPlayerIdCounter = 255;
  }

  initializeMaxId() {
    let currentMaxId = this.globalPlayerIdCounter - 1;
    for (const mId in this.mapManager.mapState) {
      const data = this.mapManager.mapState[mId];
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
    this.globalPlayerIdCounter = currentMaxId + 1;
    if (this.globalPlayerIdCounter < 255) this.globalPlayerIdCounter = 255;
  }

  sendError(ws, message) {
    if (ws.readyState === 1) {
      ws.send(JSON.stringify({ type: 'error', message }));
    }
    ws.close();
  }

  handleConnection(ws, req, sessionMiddleware, wss) {
    console.log('Client connected');

    sessionMiddleware(req, {}, () => {
      const urlParams = new URLSearchParams(req.url.split('?')[1] || "");
      const stateParam = urlParams.get('state') || 'new';
      const session = req.session;

      if (stateParam === 'running' && req.headers.cookie && req.headers.cookie.includes('connect.sid') && (!session || !session.player)) {
        this.sendError(ws, 'No player session');
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
      
      ws.mapId = this.mapManager.getMap(requestedMapId) ? requestedMapId : this.mapManager.getFirstMapId();
      let mapData = this.mapManager.getMap(ws.mapId);

      if (!mapData) {
        console.error(`No map found to attach client to (requested: ${requestedMapId})`);
        ws.close();
        return;
      }

      mapData.clients.add(ws);
      this.initializeMaxId();

      // If the session already has an attached character, boot them into the game instantly.
      if (session && session.player) {
        // Find any existing ghost connection or other window for this session and terminate it
        for (const client of wss.clients) {
          if (client !== ws && client.readyState === 1 && client.clientId === session.player.id) {
            this.sendError(client, 'Session already active in another window.');
          }
        }

        ws.clientId = session.player.id;

        // Override persistent coordinates with a fresh spawn location dynamically 
        const { spawnX, spawnY } = this.mapManager.generateSpawnCoords(mapData.id);
        session.player.x = spawnX;
        session.player.y = spawnY;

        this.mapManager.addCharacter(mapData.id, session.player);

        console.log(`Resuming session character ${session.player.name} (${ws.clientId})`);
        ws.send(this.mapManager.getInitPayload(mapData.id, session.player));
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
              this.sendError(ws, 'Invalid Name. Please use only English letters with no spaces or symbols.');
              return;
            }

            const newPlayerId = this.globalPlayerIdCounter++;
            ws.clientId = newPlayerId;

            const newChar = this.mapManager.generateNewCharacter(mapData.id, newPlayerId, playerName);

            if (session) {
              newChar.mapId = ws.mapId;
              session.player = newChar;
              session.save();
            }

            this.mapManager.addCharacter(mapData.id, newChar);

            ws.send(this.mapManager.getInitPayload(mapData.id, newChar));

            this.npcManager.logEventToNearbyNPCs(mapData, `${newChar.name || 'Student'} (${newPlayerId}) entered the map`, this.aiAgentManager);

            return;
          }

          // Drop all standard gameplay packets if they don't have a spawned character yet
          if (!ws.clientId || !mapData.characters[ws.clientId]) return;

          if (data.type === 'update') {
            const char = data.character;

            ws.clientId = char.id;
            this.mapManager.markCharacterDirty(mapData.id, char);
          } else if (data.type === 'log') {
            this.chatManager.handleLogMessage(ws, data, mapData);
          } else if (data.type === 'chat') {
            this.chatManager.handleChatMessage(ws, data, mapData);
          } else if (data.type === 'disconnect') {
            this.handleDisconnect(ws, data, mapData);
          } else if (data.type === 'change_map') {
            mapData = this.handleChangeMap(ws, data, mapData, session);
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
            this.mapManager.removeCharacter(mapData.id, ws.clientId);
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
  }

  handleDisconnect(ws, data, mapData) {
    const sender = mapData.characters[ws.clientId];

    const name = sender ? sender.name || ws.clientId : ws.clientId;

    this.npcManager.logEventToNearbyNPCs(mapData, `${name} (${ws.clientId}) left the map`, this.aiAgentManager);

    const id = data.id;
    this.mapManager.removeCharacter(mapData.id, id);
    const broadcastMsg = JSON.stringify({ type: 'disconnect', id });
    mapData.clients.forEach(client => {
      if (client !== ws && client.readyState === 1) {
        client.send(broadcastMsg);
      }
    });
  }

  handleChangeMap(ws, data, mapData, session) {
    const requestedMapId = Number(data.mapId);
    const newMapData = this.mapManager.getMap(requestedMapId);

    if (mapData.can_leave === false && data.force !== true && !ws.isAdmin) {
      const charName = (mapData.characters[ws.clientId] && mapData.characters[ws.clientId].name) || 'Student';
      this.npcManager.logEventToNearbyNPCs(mapData, `${charName} (${ws.clientId}) tried to leave ${mapData.name}`, this.aiAgentManager);
      ws.send(JSON.stringify({ type: 'map_change_rejected' }));
      return mapData;
    }

    if (newMapData && ws.mapId !== requestedMapId) {
      const oldChar = mapData.characters[ws.clientId];

      this.npcManager.logEventToNearbyNPCs(mapData, `${oldChar.name} (${ws.clientId}) left the map`, this.aiAgentManager);

      this.mapManager.removeCharacter(mapData.id, ws.clientId);
      const disconnectMsg = JSON.stringify({ type: 'disconnect', id: ws.clientId });
      mapData.clients.forEach(client => {
        if (client !== ws && client.readyState === 1) {
          client.send(disconnectMsg);
        }
      });
      mapData.clients.delete(ws);

      // Update client reference
      ws.mapId = requestedMapId;
      
      if (session && session.player) {
        session.player.mapId = requestedMapId;
      }

      // Reset position safely using spawn_area if available
      const { spawnX, spawnY } = this.mapManager.generateSpawnCoords(newMapData.id);

      oldChar.x = spawnX;
      oldChar.y = spawnY;
      oldChar.emote = null;

      if (session && session.player) {
        session.save();
      }

      this.mapManager.addCharacter(newMapData.id, oldChar);
      newMapData.clients.add(ws);

      this.npcManager.logEventToNearbyNPCs(newMapData, `${oldChar.name || 'Student'} (${ws.clientId}) entered ${newMapData.name}`, this.aiAgentManager);

      // Send init to immediately reset the client seamlessly
      ws.send(this.mapManager.getInitPayload(newMapData.id, oldChar));
      return newMapData;
    }
    return mapData;
  }
}
