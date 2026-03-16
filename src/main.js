import { initSound, soundManager } from './sound.js';
import { emotes, getEmoteMessage } from './emotes.js';
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
export const camera = {
  x: 0,
  y: 0,
  zoom: 1
};

// --- WEBSOCKET CLIENT ---
networkClient.connect((data) => {
  handleInitData(data);
});

let viewportWidth = 0;
let viewportHeight = 0;
let maxViewportHeight = 0;

function resizeCanvas() {
  const dpr = window.devicePixelRatio || 1;
  const targetW = window.innerWidth;
  const targetH = window.visualViewport ? window.visualViewport.height : window.innerHeight;

  // On iOS, opening the virtual keyboard aggressively shrinks window.innerHeight.
  // We want to cache the maximum height and ignore the shrink to prevent the game canvas from squashing.
  // However, if the width changes (orientation change), we MUST recalculate the new hardware height bound.
  let isOrientationChange = Math.abs(viewportWidth - targetW) > 50;

  if (isOrientationChange || targetH > maxViewportHeight) {
    maxViewportHeight = targetH;
  }

  // Use the cached maximum height, unless the current height is somehow larger
  const renderHeight = Math.max(targetH, maxViewportHeight);

  if (viewportWidth !== targetW || viewportHeight !== renderHeight) {
    viewportWidth = targetW;
    viewportHeight = renderHeight;
    canvas.width = viewportWidth * dpr;
    canvas.height = viewportHeight * dpr;
    canvas.style.width = viewportWidth + 'px';
    canvas.style.height = viewportHeight + 'px';
  }
}

// Create layout cache variables
let cachedViewportOffsetX = 0;
let cachedViewportOffsetY = 0;

if (window.visualViewport) {
  window.visualViewport.addEventListener('resize', resizeCanvas);
  window.visualViewport.addEventListener('scroll', () => {
    cachedViewportOffsetX = window.visualViewport.offsetLeft;
    cachedViewportOffsetY = window.visualViewport.offsetTop;
  });
  // Initial fill
  cachedViewportOffsetX = window.visualViewport.offsetLeft;
  cachedViewportOffsetY = window.visualViewport.offsetTop;
} else {
  window.addEventListener('resize', resizeCanvas);
}
window.addEventListener('orientationchange', resizeCanvas); // Use the new resizeCanvas function
resizeCanvas(); // Initial call to set up canvas dimensions

const chatInput = document.getElementById('chat-input');
const mapNameDisplay = document.getElementById('map-name-display');

window.addEventListener('chatSubmit', (e) => {
  const msg = e.detail.message;
  if (msg[0] === '/') {
    const command = msg.toLowerCase().substring(1);
    if (emotes[command]) {
      if (player.activeEmoteAudio) {
        player.activeEmoteAudio.pause();
        player.activeEmoteAudio = null;
      }
      player.emote = { name: command, startTime: Date.now() };
      const emoteObj = emotes[command];
      const msgText = getEmoteMessage(command, player.name || 'Someone', player.x, player.y, player.id, null);

      if (msgText) {
        networkClient.sendChat(msgText);
        player.chatMessage = msgText;
        player.chatTime = Date.now();
      }

      if (emoteObj.sound) {
        player.activeEmoteAudio = soundManager.playPooled(emoteObj.sound, 1);
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
export const player = {
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
uiManager.initEmotesDialog();
uiManager.initMinimapDialog();

/**
 * Processes all user inputs, updates the player coordinates, evaluates collisions,
 * triggers object entry/exit logics, and interpolates remote entity positions.
 */
function update(dt = 0.016) {
  const timeScale = (dt * 60) || 1;

  // Rotation (tank controls)
  if (!uiManager.isMinimapOpen) {
    if (inputManager.isPressed('ArrowLeft')) {
      player.rotation -= player.rotationSpeed * timeScale;
    }
    if (inputManager.isPressed('ArrowRight')) {
      player.rotation += player.rotationSpeed * timeScale;
    }
  }

  // Trigger jump via spacebar
  if (inputManager.isPressed('Space') && !uiManager.isMinimapOpen) {
    if (!player.emote || player.emote.name !== 'jump') {
      player.emote = { name: 'jump', startTime: Date.now() };
      if (player.activeEmoteAudio) {
        player.activeEmoteAudio.pause();
        player.activeEmoteAudio = null;
      }
      if (emotes['jump'].sound) {
        player.activeEmoteAudio = soundManager.playPooled(emotes['jump'].sound, 1);
      }
      networkClient.syncPlayerToJSON();
    }
  }

  // Movement
  let dx = 0;
  let dy = 0;

  let emoteForcedMove = false;
  if (player.emote && player.emote.name === 'jump') {
    const jumpAge = Date.now() - player.emote.startTime;
    if (jumpAge < 800) {
      emoteForcedMove = true;
      // Stop moving while jumping
      dx = 0;
      dy = 0;
    }
  }

  if (!emoteForcedMove) {
    const rawIntent = inputManager.getDemandedMovementVector(1, player.rotation);
    if (rawIntent.dx !== 0 || rawIntent.dy !== 0) {
      if (!player.runDirectionTimer) {
        player.runDirectionTimer = Date.now();
      }
    } else {
      player.runDirectionTimer = null;
    }

    player.isRunning = player.runDirectionTimer && (Date.now() - player.runDirectionTimer >= 2500);
    const currentSpeed = player.isRunning ? (player.moveSpeed || 3) * 1.2 : (player.moveSpeed || 3);
    const scaledSpeed = currentSpeed * timeScale;
    const intent = inputManager.getDemandedMovementVector(scaledSpeed, player.rotation);

    if (!uiManager.isMinimapOpen) {
      dx += intent.dx;
      dy += intent.dy;
    }
  } else {
    player.runDirectionTimer = null;
    player.isRunning = false;
  }

  let isMoving = false;
  if (dx !== 0 || dy !== 0) {
    const result = physicsEngine.processMovement(
      player,
      dx,
      dy,
      window.init?.objects,
      window.init?.mapData,
      emoteForcedMove,
      window.init?.npcs
    );

    isMoving = result.isMoving;
    player.x = result.newX;
    player.y = result.newY;

    if (result.emoteCanceled) {
      if (player.activeEmoteAudio) {
        player.activeEmoteAudio.pause();
        player.activeEmoteAudio = null;
      }
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
    const legRate = player.isRunning ? 0.26 : 0.2;
    player.legAnimationTime += legRate * timeScale;

    if (!emoteForcedMove) {
      if (!player.walkingAudio) {
        player.walkingAudio = soundManager.playPooled('/media/walking.mp3', 1, true);
      }
      if (player.walkingAudio && player.walkingAudio.setRate) {
        player.walkingAudio.setRate(player.isRunning ? 1.3 : 1.0);
      }
    } else {
      if (player.walkingAudio) {
        player.walkingAudio.pause();
        player.walkingAudio = null;
      }
    }

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
        if (player.activeEmoteAudio) {
          player.activeEmoteAudio.pause();
          player.activeEmoteAudio = null;
        }
        player.emote = null;
        networkClient.syncPlayerToJSON();
      }
    }
  } else {
    // Smoother stop: reset animation to neutral when stopped
    player.legAnimationTime = 0;

    if (player.walkingAudio) {
      player.walkingAudio.pause();
      player.walkingAudio = null;
    }
  }

  // Smoothly interpolate other characters to their server positions
  if (window.init?.characters) {
    for (let i = 0; i < window.init.characters.length; i++) {
      physicsEngine.processInterpolation(window.init.characters[i], player.id, timeScale);
    }
  }
  if (window.init?.npcs) {
    for (let i = 0; i < window.init.npcs.length; i++) {
      physicsEngine.processInterpolation(window.init.npcs[i], player.id, timeScale);
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
  camera.x = player.x;
  // Offset camera Y slightly higher so the player renders lower down in the view, leaving more space above them
  camera.y = player.y - (viewportHeight / camera.zoom * 0.15);

  // Read from cached globals instead of forcing aggressive DOM reflow every frame
  let yOffset = window.visualViewport ? cachedViewportOffsetY : 0;
  let xOffset = window.visualViewport ? cachedViewportOffsetX : 0;

  if (window.init?.mapData?.width && window.init?.mapData?.height) {
    const halfMapW = window.init.mapData.width / 2;
    const halfMapH = window.init.mapData.height / 2;
    const viewHalfW = (viewportWidth / camera.zoom) / 2;
    const viewHalfH = (viewportHeight / camera.zoom) / 2;

    const minX = -halfMapW + viewHalfW;
    const maxX = halfMapW - viewHalfW;
    const minY = -halfMapH + viewHalfH;
    const maxY = halfMapH - viewHalfH;

    if (minX <= maxX) {
      camera.x = Math.max(minX, Math.min(maxX, camera.x)) | 0;
    } else {
      camera.x = 0;
    }

    if (minY <= maxY) {
      camera.y = Math.max(minY, Math.min(maxY, camera.y)) | 0;
    } else {
      camera.y = 0;
    }
  }

  const dpr = window.devicePixelRatio || 1;

  // Clear screen (fixed to physical coordinates)
  ctx.fillStyle = '#7bed9f'; // Grass green color
  ctx.fillRect(0, 0, canvas.width, canvas.height);

  // Camera translation (Centers the world on the player)
  ctx.save();
  ctx.scale(dpr, dpr);
  // Truncate translation to integer coordinates to avoid GPU bilinear soft-blur
  ctx.translate(((viewportWidth / 2) + xOffset) | 0, ((viewportHeight / 2) + yOffset) | 0);
  ctx.scale(camera.zoom, camera.zoom);
  ctx.translate(-(camera.x | 0), -(camera.y | 0));

  mapManager.drawLayer(0, ctx, canvas, camera.x, camera.y, camera.zoom, viewportWidth, viewportHeight);

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

  characterManager.drawCharacters('base', ctx, canvas, player, () => networkClient.syncPlayerToJSON(), camera.x, camera.y, camera.zoom, viewportWidth, viewportHeight);

  mapManager.drawLayer(1, ctx, canvas, camera.x, camera.y, camera.zoom, viewportWidth, viewportHeight);

  characterManager.drawCharacters('overlay', ctx, canvas, player, () => networkClient.syncPlayerToJSON(), camera.x, camera.y, camera.zoom, viewportWidth, viewportHeight);
  characterManager.drawCharacters('chat', ctx, canvas, player, () => networkClient.syncPlayerToJSON(), camera.x, camera.y, camera.zoom, viewportWidth, viewportHeight);

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
    if (window.selectedNpc) window.selectedNpc.set(null);

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

      camera.zoom = mapMetadata.default_zoom || 1;

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
