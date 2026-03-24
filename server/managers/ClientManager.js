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
    for (const data of this.mapManager.getAllMaps()) {
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

  handleConnection(ws, wss, session, urlParams, sessionID) {
    console.log('Client connected');

    const stateParam = urlParams.get('state') || 'new';
    const token = urlParams.get('token');

        if (stateParam === 'running' && token && (!session || !session.player)) {
          this.sendError(ws, 'No player session');
          return;
        } else if (session && session.player) {
          console.log(session.player.name + ' has resumed game with valid session token');
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

        this.mapManager.addClient(mapData.id, ws);
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
          session.player.z = 0;

          this.mapManager.addCharacter(mapData.id, session.player);

          console.log(`Resuming session character ${session.player.name} (${ws.clientId})`);
          ws.send(this.mapManager.getInitPayload(mapData.id, session.player));

          ws.send(JSON.stringify({ type: 'session_token', token: sessionID }));
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
                ws.send(JSON.stringify({ type: 'session_token', token: sessionID }));
              }

              this.mapManager.addCharacter(mapData.id, newChar);

              ws.send(this.mapManager.getInitPayload(mapData.id, newChar));

              this.npcManager.logEventToNearbyNPCs(mapData, `${newChar.name || 'Student'} (${newPlayerId}) entered the map`, this.aiAgentManager);

              return;
            }

            // Drop all standard gameplay packets if they don't have a spawned character yet
            if (!ws.clientId || !this.mapManager.getCharacter(mapData.id, ws.clientId)) return;

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
            } else if (data.type === 'award_badge') {
              if (session && session.player) {
                if (!session.player.badges) {
                  session.player.badges = [];
                }
                if (!session.player.badges.includes(data.badge)) {
                  session.player.badges.push(data.badge);
                  session.save();
                  ws.send(JSON.stringify({ type: 'badge_earned', badge: data.badge }));
                }
              }
            } else {
              handleAdminMessage(ws, data, mapData);
            }
          } catch (err) {
            console.error('Error processing message:', err);
          }
        }); // end ws.on('message')

        ws.on('close', () => {
          if (ws.clientId) {
            console.log('Client disconnected', ws.clientId);

            let isReconnected = this.mapManager.hasActiveClient(mapData.id, ws.clientId, ws);

            if (!isReconnected) {
              this.mapManager.removeCharacter(mapData.id, ws.clientId);
              const broadcastMsg = JSON.stringify({ type: 'disconnect', id: ws.clientId });
              this.mapManager.broadcastToAllExcept(mapData.id, broadcastMsg, ws.clientId);
            } else {
              console.log(`Client ${ws.clientId} closed, but a new active socket was found. Skipping deletion.`);
            }
          }
          this.mapManager.removeClient(mapData.id, ws);
        });
  }

  handleDisconnect(ws, data, mapData) {
    const sender = this.mapManager.getCharacter(mapData.id, ws.clientId);

    const name = sender ? sender.name || ws.clientId : ws.clientId;

    this.npcManager.logEventToNearbyNPCs(mapData, `${name} (${ws.clientId}) left the map`, this.aiAgentManager);

    const id = data.id;
    this.mapManager.removeCharacter(mapData.id, id);
    const broadcastMsg = JSON.stringify({ type: 'disconnect', id });
    this.mapManager.broadcastToAllExcept(mapData.id, broadcastMsg, ws.clientId);
  }

  handleChangeMap(ws, data, mapData, session) {
    const requestedMapId = Number(data.mapId);
    const newMapData = this.mapManager.getMap(requestedMapId);

    if (mapData.can_leave === false && data.force !== true && !ws.isAdmin) {
      const sender = this.mapManager.getCharacter(mapData.id, ws.clientId);
      const charName = (sender && sender.name) || 'Student';
      this.npcManager.logEventToNearbyNPCs(mapData, `${charName} (${ws.clientId}) tried to leave ${mapData.name}`, this.aiAgentManager);
      ws.send(JSON.stringify({ type: 'map_change_rejected' }));
      return mapData;
    }

    if (newMapData && ws.mapId !== requestedMapId) {
      const oldChar = this.mapManager.getCharacter(mapData.id, ws.clientId);

      this.npcManager.logEventToNearbyNPCs(mapData, `${oldChar.name} (${ws.clientId}) left the map`, this.aiAgentManager);

      this.mapManager.removeCharacter(mapData.id, ws.clientId);
      const disconnectMsg = JSON.stringify({ type: 'disconnect', id: ws.clientId });
      this.mapManager.broadcastToAllExcept(mapData.id, disconnectMsg, ws.clientId);
      this.mapManager.removeClient(mapData.id, ws);

      // Update client reference
      ws.mapId = requestedMapId;

      if (session && session.player) {
        session.player.mapId = requestedMapId;
      }

      // Reset position safely using spawn_area if available
      const { spawnX, spawnY } = this.mapManager.generateSpawnCoords(newMapData.id);

      oldChar.x = spawnX;
      oldChar.y = spawnY;
      oldChar.z = 0;
      oldChar.emote = null;


      if (session && session.player) {

        console.log(`Saving session`, session.player);

        session.save();
      }

      this.mapManager.addCharacter(newMapData.id, oldChar);
      this.mapManager.addClient(newMapData.id, ws);

      this.npcManager.logEventToNearbyNPCs(newMapData, `${oldChar.name || 'Student'} (${ws.clientId}) entered ${newMapData.name}`, this.aiAgentManager);

      // Send init to immediately reset the client seamlessly
      ws.send(this.mapManager.getInitPayload(newMapData.id, oldChar));
      return newMapData;
    }
    return mapData;
  }
}
