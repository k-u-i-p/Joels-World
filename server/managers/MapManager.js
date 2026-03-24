import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const colors = ['#e74c3c', '#8e44ad', '#3498db', '#1abc9c', '#2ecc71', '#f1c40f', '#e67e22', '#34495e'];
const shoeColors = ['#111111', '#5e3a1f', '#7f8c8d']; // Black, Brown, Grey

export class MapManager {
  constructor() {
    this.mapState = {};
    this.mapsData = [];
    this.mapsList = []; // For init payload mapsList
  }

  initializeMaps(npcManager) {
    const mapsFile = path.resolve(__dirname, '..', 'data', 'maps.json');
    try {
      if (fs.existsSync(mapsFile)) {
        this.mapsData = JSON.parse(fs.readFileSync(mapsFile, 'utf-8'));
        this.mapsList = this.mapsData.map(m => ({ id: m.id, name: m.name }));
      }
    } catch (e) {
      console.error("[MapManager] Error loading maps.json:", e);
    }

    this.mapsData.forEach(mapDef => {
      const mapObj = {
        ...mapDef,
        clients: new Set(),
        characters: {},
        dirtyCharacters: {},
        npcs: [],
        objects: [],
        objectsFile: mapDef.objects ? path.resolve(__dirname, '..', 'data', mapDef.objects) : null,
        npcsFile: mapDef.npcs ? path.resolve(__dirname, '..', 'data', mapDef.npcs) : null,
        logFile: mapDef.logFile ? path.resolve(__dirname, '..', 'data', mapDef.logFile) : null
      };

      if (npcManager) {
        npcManager.initializeMapNPCs(mapDef, mapObj);
      }

      if (mapObj.objectsFile) {
        try {
          if (fs.existsSync(mapObj.objectsFile)) mapObj.objects = JSON.parse(fs.readFileSync(mapObj.objectsFile, 'utf-8'));
        } catch (e) { console.error(`[MapManager] Error loading objects for map ${mapDef.id}:`, e); }

        let objTimer;
        fs.watch(mapObj.objectsFile, (eventType, filename) => {
          if (objTimer) clearTimeout(objTimer);
          objTimer = setTimeout(() => {
            try {
              if (fs.existsSync(mapObj.objectsFile)) {
                mapObj.objects = JSON.parse(fs.readFileSync(mapObj.objectsFile, 'utf-8'));
                console.log(`[MapManager] Objects updated for map ${mapDef.id}, broadcasting...`);
                this.broadcastMessage(mapDef.id, JSON.stringify({ type: 'objects_update', objects: mapObj.objects }));
              }
            } catch (e) { console.error('[MapManager] Error on obj watch:', e); }
          }, 50);
        });
      }

      this.mapState[mapDef.id] = mapObj;
    });
  }

  getMap(mapId) {
    return this.mapState[mapId];
  }

  getAllMaps() {
    return Object.values(this.mapState);
  }

  getCharacters(mapId) {
    const mapData = this.mapState[mapId];
    return mapData ? Object.values(mapData.characters) : [];
  }

  getCharacter(mapId, characterId) {
    const mapData = this.mapState[mapId];
    return mapData ? mapData.characters[characterId] : null;
  }

  getNpcs(mapId) {
    const mapData = this.mapState[mapId];
    return mapData ? mapData.npcs : [];
  }

  getDirtyCharacters(mapId) {
    const mapData = this.mapState[mapId];
    return mapData ? Object.values(mapData.dirtyCharacters) : [];
  }

  clearDirtyCharacters(mapId) {
    const mapData = this.mapState[mapId];
    if (mapData) mapData.dirtyCharacters = {};
  }

  addClient(mapId, ws) {
    const mapData = this.mapState[mapId];
    if (mapData) mapData.clients.add(ws);
  }

  removeClient(mapId, ws) {
    const mapData = this.mapState[mapId];
    if (mapData) mapData.clients.delete(ws);
  }

  hasActiveClient(mapId, clientId, excludeWs) {
    const mapData = this.mapState[mapId];
    if (!mapData) return false;
    for (const client of mapData.clients) {
      if (client !== excludeWs && client.readyState === 1 && client.clientId === clientId) return true;
    }
    return false;
  }

  getFirstMapId() {
    const mapKeys = Object.keys(this.mapState);
    if (this.mapState[0]) return 0;
    if (mapKeys.length > 0) return Number(mapKeys[0]);
    return null;
  }

  broadcastMessage(mapId, messageStr) {
    const mapData = this.mapState[mapId];
    if (!mapData) return;
    mapData.clients.forEach(client => {
      if (client.readyState === 1) client.send(messageStr);
    });
  }

  broadcastToAllExcept(mapId, messageStr, excludeClientId) {
    const mapData = this.mapState[mapId];
    if (!mapData) return;
    mapData.clients.forEach(client => {
      if (client.clientId !== excludeClientId && client.readyState === 1) {
        client.send(messageStr);
      }
    });
  }

  generateSpawnCoords(mapId) {
    const mapData = this.mapState[mapId];
    let spawnX = Math.round(Math.random() * 800 + 100);
    let spawnY = Math.round(Math.random() * 600 + 100);

    if (mapData && mapData.spawn_area && mapData.objects) {
      const spawnObj = mapData.objects.find(o => o.id === mapData.spawn_area);
      if (spawnObj && spawnObj.shape === 'rect') {
        const halfW = spawnObj.width / 2;
        const halfL = spawnObj.length / 2;
        spawnX = Math.round(spawnObj.x - halfW + Math.random() * spawnObj.width);
        spawnY = Math.round(spawnObj.y - halfL + Math.random() * spawnObj.length);
      }
    }
    return { spawnX, spawnY };
  }

  generateNewCharacter(mapId, playerId, playerName) {
    const { spawnX, spawnY } = this.generateSpawnCoords(mapId);

    const skinColor = '#f1c40f'; // Default character canvas skin-tone (Lego Yellow)

    // Mathematically filter the active skin color out of the available wardrobe selection arrays to prevent "naked" overlap
    const availableClothes = colors.filter(c => c !== skinColor);
    const availableShoes = shoeColors.filter(c => c !== skinColor);
    const availableHair = ['#f1c40f', '#5c3a21', '#2c3e50', '#000000'].filter(c => c !== skinColor);

    return {
      id: playerId,
      name: playerName.substring(0, 15),
      x: spawnX,
      y: spawnY,
      width: 40,
      height: 40,
      rotation: 0,
      gender: Math.random() > 0.5 ? 'male' : 'female',
      color: skinColor,
      shirtColor: availableClothes[Math.floor(Math.random() * availableClothes.length)],
      pantsColor: availableClothes[Math.floor(Math.random() * availableClothes.length)],
      armColor: availableClothes[Math.floor(Math.random() * availableClothes.length)],
      shoeColor: availableShoes[Math.floor(Math.random() * availableShoes.length)],
      head: ['male_hair_short', 'female_hair_long', 'female_hair_ponytail', 'male_hair_spiky', 'male_hair_messy', 'male_hair_bald'][Math.floor(Math.random() * 6)],
      hair_color: availableHair[Math.floor(Math.random() * availableHair.length)],
      interaction_radius: 150
    };
  }

  addCharacter(mapId, character) {
    const mapData = this.mapState[mapId];
    if (!mapData) return;
    mapData.characters[character.id] = character;
    mapData.dirtyCharacters[character.id] = character;
  }

  removeCharacter(mapId, characterId) {
    const mapData = this.mapState[mapId];
    if (!mapData) return;
    delete mapData.characters[characterId];
    delete mapData.dirtyCharacters[characterId];
  }

  markCharacterDirty(mapId, character) {
    const mapData = this.mapState[mapId];
    if (!mapData) return;
    mapData.characters[character.id] = character;
    mapData.dirtyCharacters[character.id] = character;
  }

  getInitPayload(mapId, myChar) {
    const mapData = this.mapState[mapId];
    if (!mapData) return null;

    return JSON.stringify({
      type: 'init',
      characters: Object.values(mapData.characters),
      npcs: mapData.npcs,
      objects: mapData.objects,
      myCharacter: myChar,
      mapData: {
        id: mapData.id,
        name: mapData.name,
        width: mapData.width,
        height: mapData.height,
        layers: mapData.layers,
        clip_mask: mapData.clip_mask,
        character_scale: mapData.character_scale || 1,
        default_zoom: mapData.default_zoom || 1,
        on_enter: mapData.on_enter,
        import: mapData.import,
        models: mapData.models,
        background_color: mapData.background_color,
        spring: mapData.spring
      },
      mapsList: this.mapsList
    });
  }
}
