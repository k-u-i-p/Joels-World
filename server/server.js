import { fileURLToPath } from 'url';
import fs from 'fs';
import path from 'path';
import { WebSocketServer } from 'ws';

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



const colors = ['#e74c3c', '#8e44ad', '#3498db', '#1abc9c', '#2ecc71', '#f1c40f', '#e67e22', '#34495e'];
function getRandomColor() {
  return colors[Math.floor(Math.random() * colors.length)];
}

wss.on('connection', (ws) => {
  console.log('Client connected');

  const newPlayerId = 'player_' + Math.random().toString(36).substring(2, 9);
  ws.clientId = newPlayerId;

  const newChar = {
    id: newPlayerId,
    name: '',
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
        console.log('Got update');

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
      } else if (data.type === 'disconnect') {
        const id = data.id;
        delete characters[id];
        const broadcastMsg = JSON.stringify({ type: 'disconnect', id });
        for (const client of wss.clients) {
          if (client !== ws && client.readyState === 1) {
            client.send(broadcastMsg);
          }
        }
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
