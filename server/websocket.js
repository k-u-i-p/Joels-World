import fs from 'fs';
import path from 'path';
import { WebSocketServer } from 'ws';
import { handleAdminMessage } from './admin.js';
import { fileURLToPath } from 'url';
import { getSession } from './session.js';
import cookieParser from 'cookie-parser';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export function setupWebSocket(server) {
  const wss = new WebSocketServer({ server });

  const mapState = {};
  const mapsFile = path.resolve(__dirname, 'data/maps.json');
  let mapsData = [];
  try {
    if (fs.existsSync(mapsFile)) {
      mapsData = JSON.parse(fs.readFileSync(mapsFile, 'utf-8'));
    }
  } catch (e) {
    console.error("Error loading maps.json:", e);
  }

  mapsData.forEach(mapDef => {
    const mapObj = {
      ...mapDef,
      clients: new Set(),
      characters: {},
      dirtyCharacters: {},
      npcs: [],
      objects: [],
      objectsFile: mapDef.objects ? path.resolve(__dirname, 'data', mapDef.objects) : null,
      npcsFile: mapDef.npcs ? path.resolve(__dirname, 'data', mapDef.npcs) : null,
      logFile: mapDef.logFile ? path.resolve(__dirname, 'data', mapDef.logFile) : null
    };

    if (mapDef.npcs) {
      const npcPath = path.resolve(__dirname, 'data', mapDef.npcs);
      try {
        if (fs.existsSync(npcPath)) mapObj.npcs = JSON.parse(fs.readFileSync(npcPath, 'utf-8'));
      } catch (e) { console.error(`Error loading npcs for map ${mapDef.id}:`, e); }

      try {
        if (fs.existsSync(npcPath)) {
          let npcTimer;
          fs.watch(npcPath, (eventType, filename) => {
            if (npcTimer) clearTimeout(npcTimer);
            npcTimer = setTimeout(() => {
              try {
                if (fs.existsSync(npcPath)) {
                  mapObj.npcs = JSON.parse(fs.readFileSync(npcPath, 'utf-8'));
                  console.log(`NPCs updated for map ${mapDef.id}, broadcasting...`);
                  const broadcastMsg = JSON.stringify({ type: 'npcs_update', npcs: mapObj.npcs });
                  mapObj.clients.forEach(client => {
                    if (client.readyState === 1) client.send(broadcastMsg);
                  });
                }
              } catch (e) { console.error('Error on npc watch:', e); }
            }, 50);
          });
        }
      } catch (e) { console.error(`Error setting up watch for npcs on map ${mapDef.id}:`, e); }
    }

    if (mapObj.objectsFile) {
      try {
        if (fs.existsSync(mapObj.objectsFile)) mapObj.objects = JSON.parse(fs.readFileSync(mapObj.objectsFile, 'utf-8'));
      } catch (e) { console.error(`Error loading objects for map ${mapDef.id}:`, e); }

      let objTimer;
      fs.watch(mapObj.objectsFile, (eventType, filename) => {
        if (objTimer) clearTimeout(objTimer);
        objTimer = setTimeout(() => {
          try {
            if (fs.existsSync(mapObj.objectsFile)) {
              mapObj.objects = JSON.parse(fs.readFileSync(mapObj.objectsFile, 'utf-8'));
              console.log(`Objects updated for map ${mapDef.id}, broadcasting...`);
              const broadcastMsg = JSON.stringify({ type: 'objects_update', objects: mapObj.objects });
              mapObj.clients.forEach(client => {
                if (client.readyState === 1) client.send(broadcastMsg);
              });
            }
          } catch (e) { console.error('Error on obj watch:', e); }
        }, 50);
      });
    }

    mapState[mapDef.id] = mapObj;
  });

  setInterval(() => {
    Object.values(mapState).forEach(mapObj => {
      const updates = Object.values(mapObj.dirtyCharacters);
      if (updates.length > 0) {
        const broadcastMsg = JSON.stringify({ type: 'tick', characters: updates });
        mapObj.clients.forEach(client => {
          if (client.readyState === 1) client.send(broadcastMsg);
        });
        mapObj.dirtyCharacters = {};
      }
    });
  }, 100);

  const colors = ['#e74c3c', '#8e44ad', '#3498db', '#1abc9c', '#2ecc71', '#f1c40f', '#e67e22', '#34495e'];
  function getRandomColor() {
    return colors[Math.floor(Math.random() * colors.length)];
  }

  wss.on('connection', (ws, req) => {
    console.log('Client connected');

    cookieParser()(req, {}, () => { });

    const urlParams = new URLSearchParams(req.url.split('?')[1] || "");
    const parsedCookies = req.cookies || {};
    const session = getSession(parsedCookies.SSID);

    ws.isAdmin = session ? session.isAdmin : false;

    const mapIdParam = urlParams.get('mapId');
    const requestedMapId = mapIdParam !== null ? parseInt(mapIdParam, 10) : 0;
    const mapKeys = Object.keys(mapState);
    const mapId = mapState[requestedMapId] ? requestedMapId : (mapState[0] ? 0 : (mapKeys.length > 0 ? mapKeys[0] : null));
    ws.mapId = mapId;

    let mapData = mapState[mapId];

    if (!mapData) {
      console.error(`No map found to attach client to (requested: ${requestedMapId})`);
      ws.close();
      return;
    }

    mapData.clients.add(ws);

    const newPlayerId = Math.floor(Math.random() * 1000000000) + 10000;
    ws.clientId = newPlayerId;

    let spawnX = Math.round(Math.random() * 800 + 100);
    let spawnY = Math.round(Math.random() * 600 + 100);

    if (mapData.spawn_area && mapData.objects) {
      const spawnObj = mapData.objects.find(o => o.id === mapData.spawn_area);
      if (spawnObj && spawnObj.shape === 'rect') {
        const halfW = spawnObj.width / 2;
        const halfL = spawnObj.length / 2;
        spawnX = Math.round(spawnObj.x - halfW + Math.random() * spawnObj.width);
        spawnY = Math.round(spawnObj.y - halfL + Math.random() * spawnObj.length);
      }
    }

    const newChar = {
      id: newPlayerId,
      name: ws.isAdmin ? 'Admin' : '',
      x: spawnX,
      y: spawnY,
      width: 40,
      height: 40,
      rotation: 0,
      gender: Math.random() > 0.5 ? 'male' : 'female',
      shirtColor: getRandomColor(),
      pantsColor: getRandomColor(),
      armColor: getRandomColor()
    };

    mapData.characters[newPlayerId] = newChar;

    ws.send(JSON.stringify({
      type: 'init',
      characters: Object.values(mapData.characters),
      npcs: mapData.npcs,
      objects: mapData.objects,
      myCharacter: newChar,
      mapData: {
        id: mapData.id,
        name: mapData.name,
        width: mapData.width,
        height: mapData.height,
        background: mapData.background,
        character_scale: mapData.character_scale || 1,
        on_enter: mapData.on_enter
      },
      mapsList: mapsData.map(m => ({ id: m.id, name: m.name }))
    }));

    mapData.dirtyCharacters[newPlayerId] = newChar;

    ws.on('message', (message) => {
      try {
        const data = JSON.parse(message);

        if (data.type === 'update') {
          const char = data.character;
          ws.clientId = char.id;
          mapData.characters[char.id] = char;
          mapData.dirtyCharacters[char.id] = char;
        } else if (data.type === 'chat') {
          const broadcastMsg = JSON.stringify({ type: 'chat', id: ws.clientId, message: data.message });
          mapData.clients.forEach(client => {
            if (client.readyState === 1) {
              client.send(broadcastMsg);
            }
          });
        } else if (data.type === 'disconnect') {
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
          const newMapData = mapState[requestedMapId];
          if (newMapData && ws.mapId !== requestedMapId) {
            const oldChar = mapData.characters[ws.clientId] || newChar;
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

            // Reset position safely using spawn_area if available
            let spawnX = Math.round(Math.random() * 800 + 100);
            let spawnY = Math.round(Math.random() * 600 + 100);

            if (newMapData.spawn_area && newMapData.objects) {
              const spawnObj = newMapData.objects.find(o => o.id === newMapData.spawn_area);
              if (spawnObj && spawnObj.shape === 'rect') {
                const halfW = spawnObj.width / 2;
                const halfL = spawnObj.length / 2;
                spawnX = Math.round(spawnObj.x - halfW + Math.random() * spawnObj.width);
                spawnY = Math.round(spawnObj.y - halfL + Math.random() * spawnObj.length);
              }
            }

            oldChar.x = spawnX;
            oldChar.y = spawnY;
            oldChar.emote = null;

            mapData.characters[ws.clientId] = oldChar;
            mapData.dirtyCharacters[ws.clientId] = oldChar;
            mapData.clients.add(ws);

            // Send init to immediately reset the client seamlessly
            ws.send(JSON.stringify({
              type: 'init',
              characters: Object.values(mapData.characters),
              npcs: mapData.npcs,
              objects: mapData.objects,
              myCharacter: oldChar,
              mapData: {
                id: mapData.id,
                name: mapData.name,
                width: mapData.width,
                height: mapData.height,
                background: mapData.background,
                character_scale: mapData.character_scale || 1,
                on_enter: mapData.on_enter
              },
              mapsList: mapsData.map(m => ({ id: m.id, name: m.name }))
            }));
          }
        } else if (data.type === 'log') {
          if (mapData.logFile) {
            let logArr = [];
            try {
              if (fs.existsSync(mapData.logFile)) {
                const raw = fs.readFileSync(mapData.logFile, 'utf8');
                if (raw.trim()) logArr = JSON.parse(raw);
              }
            } catch (e) { console.error('Error reading log array:', e); }

            logArr.push({
              player_id: ws.clientId,
              message: data.message
            });

            try {
              fs.writeFileSync(mapData.logFile, JSON.stringify(logArr, null, 2), 'utf8');
            } catch (e) { console.error('Error writing log array:', e); }
          }
        } else {
          handleAdminMessage(ws, data, mapData);
        }
      } catch (err) {
        console.error('Error processing message:', err);
      }
    });

    ws.on('close', () => {
      console.log('Client disconnected');
      if (ws.clientId) {
        delete mapData.characters[ws.clientId];
        delete mapData.dirtyCharacters[ws.clientId];
        const broadcastMsg = JSON.stringify({ type: 'disconnect', id: ws.clientId });
        mapData.clients.forEach(client => {
          if (client.readyState === 1) {
            client.send(broadcastMsg);
          }
        });
      }
      mapData.clients.delete(ws);
    });
  });

  return wss;
}

