import { fileURLToPath } from 'url';
import fs from 'fs';
import path from 'path';
import { WebSocketServer } from 'ws';
import { handleAdminMessage } from './admin.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const npcFile = path.resolve(__dirname, 'data/npc.json');
const plantsFile = path.resolve(__dirname, 'data/plants.json');
const buildingsFile = path.resolve(__dirname, 'data/buildings.json');

const port = 8080;
const wss = new WebSocketServer({ port });

let characters = {};

let npcs = [];

// Load existing npcs on start if available
try {
  if (fs.existsSync(npcFile)) {
    npcs = JSON.parse(fs.readFileSync(npcFile, 'utf-8'));
  }
} catch (e) {
  console.error("Error loading initial npcs:", e);
}

let plants = [];
try {
  if (fs.existsSync(plantsFile)) {
    plants = JSON.parse(fs.readFileSync(plantsFile, 'utf-8'));
  }
} catch (e) {
  console.error("Error loading plants:", e);
}

let buildings = [];
try {
  if (fs.existsSync(buildingsFile)) {
    buildings = JSON.parse(fs.readFileSync(buildingsFile, 'utf-8'));
  }
} catch (e) {
  console.error("Error loading buildings:", e);
}

let buildingsTimer;
try {
  fs.watch(buildingsFile, (eventType, filename) => {
    if (buildingsTimer) clearTimeout(buildingsTimer);
    buildingsTimer = setTimeout(() => {
      try {
        if (fs.existsSync(buildingsFile)) {
          buildings = JSON.parse(fs.readFileSync(buildingsFile, 'utf-8'));
          console.log('Buildings file updated, broadcasting to clients...');
          const broadcastMsg = JSON.stringify({ type: 'buildings_update', buildings });
          for (const client of wss.clients) {
            if (client.readyState === 1 && !client.isAdmin) { // OPEN
              client.send(broadcastMsg);
            }
          }
        }
      } catch (e) {
        console.error('Error reloading buildings on watch event:', e);
      }
    }, 100);
  });
} catch (e) {
  console.error('Failed to setup watch on buildings file:', e);
}

let plantsTimer;
try {
  fs.watch(plantsFile, (eventType, filename) => {
    if (plantsTimer) clearTimeout(plantsTimer);
    plantsTimer = setTimeout(() => {
      try {
        if (fs.existsSync(plantsFile)) {
          plants = JSON.parse(fs.readFileSync(plantsFile, 'utf-8'));
          console.log('Plants file updated, broadcasting to clients...');
          const broadcastMsg = JSON.stringify({ type: 'plants_update', plants });
          for (const client of wss.clients) {
            if (client.readyState === 1 && !client.isAdmin) { // OPEN
              client.send(broadcastMsg);
            }
          }
        }
      } catch (e) {
        console.error('Error reloading plants on watch event:', e);
      }
    }, 100);
  });
} catch (e) {
  console.error('Failed to setup watch on plants file:', e);
}



const colors = ['#e74c3c', '#8e44ad', '#3498db', '#1abc9c', '#2ecc71', '#f1c40f', '#e67e22', '#34495e'];
function getRandomColor() {
  return colors[Math.floor(Math.random() * colors.length)];
}

wss.on('connection', (ws, req) => {
  console.log('Client connected');

  const urlParams = new URLSearchParams(req.url.split('?')[1] || "");
  ws.isAdmin = urlParams.get('admin') === 'true';

  const newPlayerId = 'player_' + Math.random().toString(36).substring(2, 9);
  ws.clientId = newPlayerId;

  const newChar = {
    id: newPlayerId,
    name: ws.isAdmin ? 'Admin' : '',
    x: Math.round(Math.random() * 800 + 100),
    y: Math.round(Math.random() * 600 + 100),
    width: 40,
    height: 40,
    rotation: 0,
    gender: Math.random() > 0.5 ? 'male' : 'female',
    shirtColor: getRandomColor(),
    pantsColor: getRandomColor(),
    armColor: getRandomColor()
  };

  characters[newPlayerId] = newChar;

  // Send the current characters, npcs, plants, and buildings to the new client
  ws.send(JSON.stringify({
    type: 'init',
    characters: Object.values(characters),
    npcs: npcs,
    plants: plants,
    buildings: buildings,
    myCharacter: newChar
  }));

  // Broadcast new character to others
  const broadcastMsg = JSON.stringify({ type: 'update', character: newChar });
  for (const client of wss.clients) {
    if (client !== ws && client.readyState === 1) { // OPEN
      client.send(broadcastMsg);
    }
  }

  ws.on('message', (message) => {
    try {
      const data = JSON.parse(message);

      if (data.type === 'update') {
        const char = data.character;
        ws.clientId = char.id;
        characters[char.id] = char;

        // Broadcast to other clients
        const broadcastMsg = JSON.stringify({ type: 'update', character: char });
        for (const client of wss.clients) {
          if (client !== ws && client.readyState === 1) { // OPEN
            client.send(broadcastMsg);
          }
        }
      } else if (data.type === 'chat') {
        const broadcastMsg = JSON.stringify({ type: 'chat', id: ws.clientId, message: data.message });
        for (const client of wss.clients) {
          if (client.readyState === 1) {
            client.send(broadcastMsg);
          }
        }
      } else if (data.type === 'disconnect') {
        const id = data.id;
        delete characters[id];
        const broadcastMsg = JSON.stringify({ type: 'disconnect', id });
        for (const client of wss.clients) {
          if (client !== ws && client.readyState === 1) {
            client.send(broadcastMsg);
          }
        }
      } else if (ws.isAdmin && handleAdminMessage(ws, data, { buildings, buildingsFile, plants, plantsFile, __dirname })) {
        // Handled securely by the admin controller
      }
    } catch (err) {
      console.error('Error processing message:', err);
    }
  });

  ws.on('close', () => {
    console.log('Client disconnected');
    if (ws.clientId) {
      delete characters[ws.clientId];
      const broadcastMsg = JSON.stringify({ type: 'disconnect', id: ws.clientId });
      for (const client of wss.clients) {
        if (client.readyState === 1) {
          client.send(broadcastMsg);
        }
      }
    }
  });
});

console.log(`WebSocket server running on ws://localhost:${port}`);
