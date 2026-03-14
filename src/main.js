import { initSound, soundManager } from './sound.js';
import { emotes } from './emotes.js';
import { processEvents } from './events.js';
import { mapManager } from './maps.js';
import { characterManager } from './characters.js';
import { physicsEngine } from './physics.js';
import { inputManager } from './input.js';
import { networkClient } from './network.js';
import { uiManager } from './ui.js';
import { gameLoop } from './gameloop.js';

const canvas = document.getElementById('gameCanvas');
const ctx = canvas.getContext('2d');
window.cameraZoom = 1;

// --- WEBSOCKET CLIENT ---
networkClient.connect((data) => {
  handleInitData(data);
});

let viewportWidth = window.innerWidth;
let viewportHeight = window.innerHeight;

function resize() {
  viewportWidth = window.visualViewport ? window.visualViewport.width : window.innerWidth;
  viewportHeight = window.visualViewport ? window.visualViewport.height : window.innerHeight;
  canvas.width = window.innerWidth;
  canvas.height = window.innerHeight;
  canvas.style.width = window.innerWidth + 'px';
  canvas.style.height = window.innerHeight + 'px';
}
window.addEventListener('resize', resize);
window.addEventListener('orientationchange', resize);
if (window.visualViewport) {
  window.visualViewport.addEventListener('resize', resize);
  window.visualViewport.addEventListener('scroll', resize);
}
resize();

const chatInput = document.getElementById('chat-input');
const mapNameDisplay = document.getElementById('map-name-display');

window.addEventListener('chatSubmit', (e) => {
  const msg = e.detail.message;
  if (msg[0] === '/') {
    const command = msg.toLowerCase().substring(1);
    if (emotes[command]) {
      player.emote = { name: command, startTime: Date.now() };
      if (emotes[command].message) {
        const msgText = emotes[command].message.replace('{name}', player.name || 'Someone');
        networkClient.sendChat(msgText);
        player.chatMessage = msgText;
        player.chatTime = Date.now();
      }
      networkClient.syncPlayerToJSON();
    }
  } else {
    networkClient.sendChat(msg);
    // Optimistic local update
    player.chatMessage = msg;
    player.chatTime = Date.now();
  }
});

// Start sound system
initSound();

// Player Entity
let player = {
  id: 0,
  moveSpeed: 3,
  rotationSpeed: 3,
  legAnimationTime: 0,
  emote: null,
  _lastSentX: null,
  _lastSentY: null,
  _lastSentRotation: null,
  _lastSentEmoteString: null,
  x: window.innerWidth / 2,
  y: window.innerHeight / 2,
  width: 40,
  height: 40,
  rotation: 0
};
window.player = player;

// Initialization Object
window.init = null;
let lastSyncTime = 0;
let activeNpc = null;

export const footprints = [];
/**
 * Global gameLoop system is now handled by our GameLoop class in gameloop.js.
 * We register our main update and draw callbacks natively once init executes.
 */



const movementCoords = [{ x: 0, y: 0 }, { x: 0, y: 0 }, { x: 0, y: 0 }];
const exactCoords = [{ x: 0, y: 0 }];

uiManager.initHelpDialog();

/**
 * Processes all user inputs, updates the player coordinates, evaluates collisions,
 * triggers object entry/exit logics, and interpolates remote entity positions.
 */
function update() {
  // Rotation (tank controls)
  if (inputManager.isPressed('ArrowLeft')) {
    player.rotation -= player.rotationSpeed;
  }
  if (inputManager.isPressed('ArrowRight')) {
    player.rotation += player.rotationSpeed;
  }

  // Movement
  let dx = 0;
  let dy = 0;

  let emoteForcedMove = false;
  if (player.emote && player.emote.name === 'jump') {
    const jumpAge = Date.now() - player.emote.startTime;
    if (jumpAge < 800) {
      emoteForcedMove = true;
      const progress = jumpAge / 800;
      // Burst of speed tapering down as they hit the ground
      const jumpVel = (player.moveSpeed || 3) * 1.0 * (1 - progress);
      dx += Math.cos(player.rotation * Math.PI / 180) * jumpVel;
      dy += Math.sin(player.rotation * Math.PI / 180) * jumpVel;
    }
  }

  if (!emoteForcedMove) {
    const intent = inputManager.getDemandedMovementVector(player.moveSpeed || 3, player.rotation);
    dx += intent.dx;
    dy += intent.dy;
  }

  let isMoving = false;
  if (dx !== 0 || dy !== 0) {
    const result = physicsEngine.processMovement(
      player,
      dx,
      dy,
      window.init?.objects,
      window.init?.mapData,
      emoteForcedMove
    );

    isMoving = result.isMoving;
    player.x = result.newX;
    player.y = result.newY;

    if (result.emoteCanceled) {
      player.emote = null;
      networkClient.syncPlayerToJSON();
    }

    const newBuilding = result.actuallyInObject ? result.actuallyInObject.id : null;

    if (player.activeBuilding !== newBuilding) {
      if (player.activeBuilding) {
        const oldObj = window.init?.objects?.find(o => o.id === player.activeBuilding);
        if (oldObj && oldObj.activeAudio) {
          oldObj.activeAudio.pause();
          oldObj.activeAudio.currentTime = 0;
          oldObj.activeAudio = null;
        }
        if (oldObj && oldObj.on_exit && (typeof oldObj.on_exit === 'number' || oldObj.on_exit.length > 0)) {
          executeEvents(oldObj, oldObj.on_exit, 'on_exit');
        }
      }
      player.activeBuilding = newBuilding;
      if (newBuilding) {
        const matchedObj = result.actuallyInObject;
        if (matchedObj.on_enter && (typeof matchedObj.on_enter === 'number' || matchedObj.on_enter.length > 0)) {
          executeEvents(matchedObj, matchedObj.on_enter);
        }
      } else {
        // Exited building
        const dialogOverlay = uiManager.dialogOverlay;
        if (dialogOverlay) dialogOverlay.style.display = 'none';
      }
    }
  }

  // Animation
  if (isMoving) {
    player.legAnimationTime += 0.2;
    if (player.emote) {
      let shouldCancel = true;
      if (player.emote.name === 'jump' || player.emote.name === 'wet') {
        shouldCancel = false;
      }
      if (player.activeBuilding) {
        const activeObj = window.init?.objects?.find(o => o.id === player.activeBuilding);
        if (activeObj && activeObj.on_enter) {
          let actions = activeObj.on_enter;
          if (typeof actions === 'number') {
            const parentObj = window.init?.objects?.find(o => o.id === actions);
            if (parentObj && parentObj.on_enter) actions = parentObj.on_enter;
          }
          if (Array.isArray(actions)) {
            const envEmote = actions.find(a => a.emote === player.emote.name);
            if (envEmote) shouldCancel = false;
          }
        }
      }
      if (shouldCancel) {
        player.emote = null;
        networkClient.syncPlayerToJSON();
      }
    }
  } else {
    // Smoother stop: reset animation to neutral when stopped
    player.legAnimationTime = 0;
  }

  // Smoothly interpolate other characters to their server positions
  if (window.init?.characters) {
    for (let i = 0; i < window.init.characters.length; i++) {
      physicsEngine.processInterpolation(window.init.characters[i], player.id);
    }
  }
  if (window.init?.npcs) {
    for (let i = 0; i < window.init.npcs.length; i++) {
      physicsEngine.processInterpolation(window.init.npcs[i], player.id);
    }
  }

  // Check NPC radius interactions
  activeNpc = physicsEngine.processInteractions(player, window.init, activeNpc, uiManager, executeEvents);

  // Sync back via websocket 10 times a second if moved
  const now = Date.now();
  if (now - lastSyncTime > 100) {
    const currentEmoteStr = player.emote ? JSON.stringify(player.emote) : null;
    if (player.x !== player._lastSentX || player.y !== player._lastSentY || player.rotation !== player._lastSentRotation || currentEmoteStr !== player._lastSentEmoteString) {
      player._lastSentEmoteString = currentEmoteStr;
      player._lastSentX = player.x;
      player._lastSentY = player.y;
      player._lastSentRotation = player.rotation;
      lastSyncTime = now;
      networkClient.syncPlayerToJSON();
    }
  }
}

function executeEvents(sourceObj, rawActions, eventType = 'on_enter') {
  processEvents(sourceObj, rawActions, eventType, {
    UI: uiManager,
    player,
    syncPlayerToJSON: () => networkClient.syncPlayerToJSON()
  });
}

/**
 * Master rendering function. Clears the canvas, applies camera transformations, 
 * draws the map, all visible characters, and user interface elements.
 */
function draw() {
  window.cameraX = player.x;
  window.cameraY = player.y;

  let yOffset = window.visualViewport ? window.visualViewport.offsetTop : 0;
  let xOffset = window.visualViewport ? window.visualViewport.offsetLeft : 0;

  if (window.init?.mapData?.width && window.init?.mapData?.height) {
    const halfMapW = window.init.mapData.width / 2;
    const halfMapH = window.init.mapData.height / 2;
    const viewHalfW = (viewportWidth / window.cameraZoom) / 2;
    const viewHalfH = (viewportHeight / window.cameraZoom) / 2;

    const minX = -halfMapW + viewHalfW;
    const maxX = halfMapW - viewHalfW;
    const minY = -halfMapH + viewHalfH;
    const maxY = halfMapH - viewHalfH;

    if (minX <= maxX) {
      window.cameraX = Math.max(minX, Math.min(maxX, window.cameraX));
    } else {
      window.cameraX = 0;
    }

    if (minY <= maxY) {
      window.cameraY = Math.max(minY, Math.min(maxY, window.cameraY));
    } else {
      window.cameraY = 0;
    }
  }

  // Clear screen (fixed to screen coordinates)
  ctx.fillStyle = '#7bed9f'; // Grass green color
  ctx.fillRect(0, 0, canvas.width, canvas.height);

  // Camera translation (Centers the world on the player)
  ctx.save();
  ctx.translate(viewportWidth / 2 + xOffset, viewportHeight / 2 + yOffset);
  ctx.scale(window.cameraZoom, window.cameraZoom);
  ctx.translate(-window.cameraX, -window.cameraY);

  mapManager.drawLayer(0, ctx, canvas, window.cameraX, window.cameraY, window.cameraZoom);

  // Render global footprints underneath characters
  const now = Date.now();
  for (let i = footprints.length - 1; i >= 0; i--) {
    const f = footprints[i];
    const age = now - f.time;
    if (age > 10000) {
      footprints.splice(i, 1);
      continue;
    }
    ctx.save();
    ctx.globalAlpha = Math.max(0, 0.6 * (1 - age / 10000));
    ctx.translate(f.x, f.y);
    ctx.rotate(f.rot * Math.PI / 180);

    ctx.fillStyle = '#74b9ff'; // wet footprint color

    const offsetX = f.isLeft ? -5 : 5;

    ctx.beginPath();
    if (ctx.ellipse) {
      ctx.ellipse(offsetX, -4, 2.5, 4.5, 0, 0, Math.PI * 2);
    } else {
      ctx.arc(offsetX, -4, 3, 0, Math.PI * 2);
    }
    ctx.fill();
    ctx.restore();
  }

  characterManager.drawCharacters('base', ctx, canvas, player, () => networkClient.syncPlayerToJSON(), window.cameraX, window.cameraY, window.cameraZoom);

  mapManager.drawLayer(1, ctx, canvas, window.cameraX, window.cameraY, window.cameraZoom);

  characterManager.drawCharacters('overlay', ctx, canvas, player, () => networkClient.syncPlayerToJSON(), window.cameraX, window.cameraY, window.cameraZoom);

  // Restore camera translation
  ctx.restore();
}





// Start By Fetching Data
const { nameDialog, nameInput, startBtn } = uiManager.initLobby((playerName) => {
  console.log('[Main] onStartGame callback received playerName:', playerName);
  if (playerName) {
    player.name = playerName;
    networkClient.sendCreateCharacter(playerName);
  }
});

/**
 * Intercepts the `init` payload from the WebSocket server after joining or mapping 
 * into a new world. Prepares and overwrites all lists of loaded NPCs, objects, 
 * background environments, and schedules the start of rendering logic.
 * @param {Object} data - The map's initialization data payload structured by the server.
 */
function handleInitData(data) {
  console.log(`[Main] handleInitData triggered. Loaded Map: ${data?.mapData?.name}`);
  try {
    window.init = data;
    if (!window.init.characters) window.init.characters = [];
    if (!window.init.npcs) window.init.npcs = [];
    activeNpc = null;
    if (window.selectedObject) window.selectedObject.set(null);

    // Bypassing the local UI lobby if a session successfully resumed
    const nameDialog = document.getElementById('name-dialog');
    if (nameDialog) nameDialog.style.display = 'none';

    const topUi = document.getElementById('top-center-ui');
    if (topUi) topUi.style.display = 'flex';

    const wasRunning = gameLoop.isRunning();

    if (!wasRunning) {
      if (window.init.mapData && window.init.mapData.on_enter) {
        executeEvents(window.init.mapData, window.init.mapData.on_enter);
      }
      checkInitialSpawn();
      console.log('[Main] Game loop rendering started for the first time.');
      gameLoop.registerFunction(update);
      gameLoop.registerFunction(draw);
      gameLoop.start();
    }

    const avatarsContainer = uiManager.avatarsContainer;
    if (avatarsContainer) {
      avatarsContainer.innerHTML = '';
      const actionDialog = document.getElementById('top-center-ui');
      if (actionDialog) actionDialog.classList.remove('avatar-active');
      const mapNameDisplay = uiManager.mapNameDisplay;
      if (mapNameDisplay && mapNameDisplay.dataset.originalName) {
        delete mapNameDisplay.dataset.originalName;
      }
    }

    const myCharacter = data.myCharacter;
    const mapMetadata = data.mapData;
    const mapsList = data.mapsList;

    if (myCharacter) {
      Object.assign(player, myCharacter);
    } else {
      const playerConfig = window.init?.characters?.find(c => c.id === player.id);
      if (playerConfig) {
        Object.assign(player, playerConfig);
      }
    }

    // Auto-fill if name exists
    if (player.name && nameInput) {
      nameInput.value = player.name;
    }

    if (mapMetadata) {
      if (mapNameDisplay && mapMetadata.name) {
        mapNameDisplay.textContent = mapMetadata.name;
      }

      window.cameraZoom = mapMetadata.default_zoom || 1;

      mapManager.init(mapMetadata);

      // Initialize the physics clip mask for this map if it has one
      physicsEngine.loadClipMask(mapMetadata.clip_mask, mapMetadata.width, mapMetadata.height);

      // Handle dynamic map audio swapping if already playing
      if (wasRunning) {
        if (mapMetadata.on_enter) {
          executeEvents(mapMetadata, mapMetadata.on_enter);
        } else {
          soundManager.stopBackground();
        }
        setTimeout(checkInitialSpawn, 100);
      }
    }

    if (mapsList) {
      window.mapsList = mapsList;
      if (window.populateAdminMaps) window.populateAdminMaps();
    }

    if (nameInput && nameInput.value.trim() !== '') {
      console.log('Focusing name input');
      nameInput.focus();
    }
  } catch (err) {
    if (startBtn) {
      startBtn.textContent = "Err2: " + err.name + " " + err.message;
      startBtn.style.color = "red";
    }
    console.error(err);
  }
}

/**
 * Verifies upon map initialization whether the player's initial coordinate payload
 * places them directly over overlapping trigger zones like a Spawn Area. Instantly 
 * initiates any actions on their entries if so.
 */
function checkInitialSpawn() {
  if (!gameLoop.isRunning() || !window.init) return;
  const playerRadius = 15;
  const possibleOverlaps = window.init.objects ? window.init.objects.filter(o =>
    Math.hypot(player.x - o.x, player.y - o.y) < Math.max(o.width, o.length) + playerRadius
  ) : [];
  if (possibleOverlaps.length > 0) {
    exactCoords[0].x = player.x;
    exactCoords[0].y = player.y;
    const actuallyInObject = physicsEngine.findObjectsAt(possibleOverlaps, exactCoords, 0);
    const newBuilding = actuallyInObject.length > 0 ? actuallyInObject[0].id : null;
    if (newBuilding) {
      player.activeBuilding = newBuilding;
      const matchedObj = actuallyInObject[0];
      if (matchedObj.on_enter && (typeof matchedObj.on_enter === 'number' || matchedObj.on_enter.length > 0)) {
        executeEvents(matchedObj, matchedObj.on_enter);
      }
    }
  }
}
