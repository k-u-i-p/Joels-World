import { initSound, soundManager } from './sound.js';
import { emotes } from './emotes.js';
import { EventHandlers } from './events.js';
import { mapManager } from './maps.js';
import { characterManager } from './characters.js';
import { physicsEngine } from './physics.js';
import { inputManager } from './input.js';
import { networkClient } from './network.js';
import { uiManager } from './ui.js';

const canvas = document.getElementById('gameCanvas');
const ctx = canvas.getContext('2d');
window.cameraZoom = 1;

// --- WEBSOCKET CLIENT ---
// Connection is now deferred until the player chooses a name and clicks Start Game.

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

window.mapLayers = [];



// Game Loop
/**
 * The main render and update loop handling user movement inputs, drawing operations,
 * and next frame scheduling.
 */
let framesThisSecond = 0;
let lastFpsUpdate = performance.now();
let lastFrameTime = performance.now();
const fpsInterval = 1000 / 60; // Target 60 FPS cap

function gameLoop() {
  requestAnimationFrame(gameLoop);

  const now = performance.now();
  const elapsed = now - lastFrameTime;

  if (elapsed > fpsInterval) {
    lastFrameTime = now - (elapsed % fpsInterval);

    framesThisSecond++;
    if (now - lastFpsUpdate >= 1000) {
      if (window.isAdmin && window.updateAdminFps) {
        window.updateAdminFps(framesThisSecond);
      }
      framesThisSecond = 0;
      lastFpsUpdate = now;
    }

    update();
    draw();
    if (window.isAdmin && window.adminDraw) {
      window.adminDraw();
    }
  }
}
window.gameLoop = gameLoop;



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
    if (inputManager.isPressed('TouchMove')) {
      dx += Math.cos(player.rotation * Math.PI / 180) * (player.moveSpeed || 3);
      dy += Math.sin(player.rotation * Math.PI / 180) * (player.moveSpeed || 3);
    } else {
      // Keyboard tank controls
      if (inputManager.isPressed('ArrowUp')) {
        dx += Math.cos(player.rotation * Math.PI / 180) * (player.moveSpeed || 3);
        dy += Math.sin(player.rotation * Math.PI / 180) * (player.moveSpeed || 3);
      }
      if (inputManager.isPressed('ArrowDown')) {
        dx -= Math.cos(player.rotation * Math.PI / 180) * (player.moveSpeed || 3);
        dy -= Math.sin(player.rotation * Math.PI / 180) * (player.moveSpeed || 3);
      }
    }
  }

  let isMoving = false;
  if (dx !== 0 || dy !== 0) {
    isMoving = true;

    const scale = window.init?.mapData?.character_scale || 1;
    const playerRadius = 15 * scale; // slightly smaller than half width for smooth collisions

    movementCoords[0].x = player.x + dx;
    movementCoords[0].y = player.y + dy;
    movementCoords[1].x = player.x + dx;
    movementCoords[1].y = player.y;
    movementCoords[2].x = player.x;
    movementCoords[2].y = player.y + dy;

    const possibleOverlaps = physicsEngine.findObjectsAt(window.init?.objects, movementCoords, playerRadius);

    const mapW = window.init?.mapData?.width;
    const mapH = window.init?.mapData?.height;

    // Try moving in both axes, then X only, then Y only (sliding against walls)
    if (emoteForcedMove) {
      if (physicsEngine.canMoveTo(possibleOverlaps, player.x + dx, player.y + dy, playerRadius, mapW, mapH)) {
        player.x += dx;
        player.y += dy;
      } else {
        // Hit something while jumping! Stop the jump and drop to ground immediately
        player.emote = null;
        networkClient.syncPlayerToJSON();
      }
    } else {
      if (physicsEngine.canMoveTo(possibleOverlaps, player.x + dx, player.y + dy, playerRadius, mapW, mapH)) {
        player.x += dx;
        player.y += dy;
      } else {
        // Attempt Advanced Sliding Mechanism against Rotated Objects
        // 1. Identify which object we hit (if any)
        let hitObj = null;
        for (let i = 0; i < possibleOverlaps.length; i++) {
          const obj = possibleOverlaps[i];
          if (!obj.noclip && obj.clip !== -1 && physicsEngine.checkObjectOverlap(obj, player.x + dx, player.y + dy, playerRadius, obj.clip === undefined ? 10 : obj.clip)) {
            hitObj = obj;
            break;
          }
        }

        if (hitObj && hitObj.shape === 'rect' && hitObj.rotation) {
          // Slide along the rotated edge
          const angle = -hitObj.rotation * (Math.PI / 180);
          const cosA = Math.cos(angle);
          const sinA = Math.sin(angle);

          // Transform intended movement vector into local space of the rotated object
          const localDx = dx * cosA - dy * sinA;
          const localDy = dx * sinA + dy * cosA;

          // For axis-aligned local space, sliding means zeroing out the blocked axis and keeping the unblocked axis.
          // Test local X sliding
          const testLocalDx = localDx;
          const testLocalDy = 0;

          // Transform back to world space
          let slideWorldDx = testLocalDx * cosA + testLocalDy * sinA;
          let slideWorldDy = -testLocalDx * sinA + testLocalDy * cosA;

          if (physicsEngine.canMoveTo(possibleOverlaps, player.x + slideWorldDx, player.y + slideWorldDy, playerRadius, mapW, mapH)) {
            player.x += slideWorldDx;
            player.y += slideWorldDy;
          } else {
            // Test local Y sliding
            const testLocalDx2 = 0;
            const testLocalDy2 = localDy;
            slideWorldDx = testLocalDx2 * cosA + testLocalDy2 * sinA;
            slideWorldDy = -testLocalDx2 * sinA + testLocalDy2 * cosA;

            if (physicsEngine.canMoveTo(possibleOverlaps, player.x + slideWorldDx, player.y + slideWorldDy, playerRadius, mapW, mapH)) {
              player.x += slideWorldDx;
              player.y += slideWorldDy;
            } else if (physicsEngine.canMoveTo(possibleOverlaps, player.x + dx, player.y, playerRadius, mapW, mapH)) {
              // Fallback to pure X
              player.x += dx;
            } else if (physicsEngine.canMoveTo(possibleOverlaps, player.x, player.y + dy, playerRadius, mapW, mapH)) {
              // Fallback to pure Y
              player.y += dy;
            }
          }
        } else {
          // Fallback to standard axis-aligned sliding
          if (physicsEngine.canMoveTo(possibleOverlaps, player.x + dx, player.y, playerRadius, mapW, mapH)) {
            player.x += dx;
          } else if (physicsEngine.canMoveTo(possibleOverlaps, player.x, player.y + dy, playerRadius, mapW, mapH)) {
            player.y += dy;
          }
        }
      }
    }

    if (possibleOverlaps.length > 0) {
      exactCoords[0].x = player.x;
      exactCoords[0].y = player.y;
      const actuallyInObject = physicsEngine.findObjectsAt(possibleOverlaps, exactCoords, 0);
      const newBuilding = actuallyInObject.length > 0 ? actuallyInObject[0].id : null;

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
          const matchedObj = actuallyInObject[0];
          if (matchedObj.on_enter && (typeof matchedObj.on_enter === 'number' || matchedObj.on_enter.length > 0)) {
            executeEvents(matchedObj, matchedObj.on_enter);
          }
        } else {
          // Exited building
          const dialogOverlay = uiManager.dialogOverlay;
          if (dialogOverlay) dialogOverlay.style.display = 'none';
        }
      }
    } else {
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
        player.activeBuilding = null;
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
  const processInterp = (c) => {
    if (c.id === player.id) return;

    if (c.targetX !== undefined && c.targetY !== undefined) {
      const cdx = c.targetX - c.x;
      const cdy = c.targetY - c.y;
      const distSq = cdx * cdx + cdy * cdy;

      // Snap if teleported really far (100^2 = 10000)
      if (distSq > 10000) {
        c.x = c.targetX;
        c.y = c.targetY;
        c.rotation = c.targetRotation;
        c.startX = c.targetX;
        c.startY = c.targetY;
      } else if (c.targetStartTime !== undefined && c.startX !== undefined && c.startY !== undefined) {
        // True time-based network interpolation
        // Standard server tick rate is 100ms
        let t = (Date.now() - c.targetStartTime) / 100;

        // Allow up to 20% extrapolation into the future for packet latency jitter!
        // This prevents the character from artificially stopping if the packet is delayed by a few ms.
        if (t > 1.2) t = 1.2;

        const newX = c.startX + (c.targetX - c.startX) * t;
        const newY = c.startY + (c.targetY - c.startY) * t;

        const stepDist = Math.hypot(newX - c.x, newY - c.y);

        c.x = newX;
        c.y = newY;

        if (stepDist > 0.05 && t < 1.2) {
          c.legAnimationTime = (c.legAnimationTime || 0) + 0.2;
        } else {
          c.legAnimationTime = 0; // stop moving legs when we catch up
        }
      } else {
        c.x = c.targetX;
        c.y = c.targetY;
        c.legAnimationTime = 0;
      }

      // Interpolate rotation efficiently via shortest angle (even if not moving XY)
      if (c.targetRotation !== undefined) {
        let rotDiff = c.targetRotation - (c.rotation || 0);
        while (rotDiff > 180) rotDiff -= 360;
        while (rotDiff < -180) rotDiff += 360;

        if (Math.abs(rotDiff) > 1) {
          const rotSpeed = c.rotationSpeed || 5;
          const rotStep = Math.min(Math.abs(rotDiff), rotSpeed);
          c.rotation = (c.rotation || 0) + Math.sign(rotDiff) * rotStep;
        } else {
          c.rotation = c.targetRotation;
        }
      }
    }
  };

  if (window.init?.characters) {
    for (let i = 0; i < window.init.characters.length; i++) processInterp(window.init.characters[i]);
  }
  if (window.init?.npcs) {
    for (let i = 0; i < window.init.npcs.length; i++) processInterp(window.init.npcs[i]);
  }

  // Check NPC radius interactions
  const interactionRadius = 80 * (window.init?.mapData?.character_scale || 1);
  const interactionRadiusSq = interactionRadius * interactionRadius;
  let closestNpc = null;
  let minNpcDistSq = interactionRadiusSq + 1;

  const processProximity = (c) => {
    if (c.id === player.id) return;
    if (!c.isNpc && (c.on_enter === undefined && c.on_exit === undefined)) return;

    const dx = player.x - c.x;
    const dy = player.y - c.y;
    const distSq = dx * dx + dy * dy;

    if (distSq <= interactionRadiusSq && distSq < minNpcDistSq) {
      minNpcDistSq = distSq;
      closestNpc = c;
    }
  };

  if (window.init?.characters) {
    for (let i = 0; i < window.init.characters.length; i++) processProximity(window.init.characters[i]);
  }
  if (window.init?.npcs) {
    for (let i = 0; i < window.init.npcs.length; i++) processProximity(window.init.npcs[i]);
  }

  if (activeNpc && (!closestNpc || activeNpc !== closestNpc.id)) {
    const prevNpc = [...(window.init?.characters || []), ...(window.init?.npcs || [])].find(c => c.id === activeNpc);
    if (prevNpc) {
      if (prevNpc.activeAudio) {
        prevNpc.activeAudio.pause();
        prevNpc.activeAudio.currentTime = 0;
        prevNpc.activeAudio = null;
      }
      if (prevNpc && prevNpc.on_exit && (typeof prevNpc.on_exit === 'number' || prevNpc.on_exit.length > 0)) {
        executeEvents(prevNpc, prevNpc.on_exit, 'on_exit');
      }
      // Auto-clear avatar when walking away from an NPC
      const container = uiManager.avatarsContainer;
      if (container) {
        const el = container.querySelector(`[data-npc-id="${prevNpc.id}"]`);
        if (el) el.remove();
        if (container.children.length === 0) {
          const actionDialog = document.getElementById('top-center-ui');
          if (actionDialog) actionDialog.classList.remove('avatar-active');
          const mapNameDisplay = uiManager.mapNameDisplay;
          if (mapNameDisplay && mapNameDisplay.dataset.originalName) {
            mapNameDisplay.textContent = mapNameDisplay.dataset.originalName;
            delete mapNameDisplay.dataset.originalName;
          }
        }
      }
    }
    activeNpc = null;
  }

  if (closestNpc && activeNpc !== closestNpc.id) {
    activeNpc = closestNpc.id;
    if (closestNpc.on_enter && (typeof closestNpc.on_enter === 'number' || closestNpc.on_enter.length > 0)) {
      executeEvents(closestNpc, closestNpc.on_enter);
    }
  }

  // Sync back via websocket 20 times a second if moved
  const now = Date.now();
  if (now - lastSyncTime > 50) {
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
  let actions = rawActions;
  if (typeof rawActions === 'number') {
    const parentObj = window.init?.objects?.find(o => o.id === rawActions);
    if (!parentObj || !parentObj[eventType]) return;
    actions = parentObj[eventType];
  }

  if (!actions || !Array.isArray(actions)) return;

  const context = {
    UI: uiManager,
    player,
    syncPlayerToJSON: () => networkClient.syncPlayerToJSON()
  };

  for (const action of actions) {
    for (const [key, payload] of Object.entries(action)) {
      if (EventHandlers[key]) {
        EventHandlers[key](sourceObj, payload, context);
      }
    }
  }
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
  if (window.footprints) {
    const now = Date.now();
    for (let i = window.footprints.length - 1; i >= 0; i--) {
      const f = window.footprints[i];
      const age = now - f.time;
      if (age > 10000) {
        window.footprints.splice(i, 1);
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
  }

  characterManager.drawCharacters('base', ctx, canvas, player, () => networkClient.syncPlayerToJSON(), window.cameraX, window.cameraY, window.cameraZoom);

  mapManager.drawLayer(1, ctx, canvas, window.cameraX, window.cameraY, window.cameraZoom);

  characterManager.drawCharacters('overlay', ctx, canvas, player, () => networkClient.syncPlayerToJSON(), window.cameraX, window.cameraY, window.cameraZoom);

  // Restore camera translation
  ctx.restore();
}





// Start By Fetching Data
window.gameStarted = window.isAdmin || false;

const { nameDialog, nameInput, startBtn } = uiManager.initLobby((playerName) => {
  if (playerName) {
    player.name = playerName;
  }
  
  // Initiate network connection now that we have a name
  networkClient.connect((data) => {
    handleInitData(data);
    
    // Now that we have the init payload, setup the game loop
    window.gameStarted = true;
    if (window.init.mapData && window.init.mapData.on_enter) {
      executeEvents(window.init.mapData, window.init.mapData.on_enter);
    }
    checkInitialSpawn();
    requestAnimationFrame(gameLoop); // Kick off the game loop
  }, player.name);
});

/**
 * Intercepts the `init` payload from the WebSocket server after joining or mapping 
 * into a new world. Prepares and overwrites all lists of loaded NPCs, objects, 
 * background environments, and schedules the start of rendering logic.
 * @param {Object} data - The map's initialization data payload structured by the server.
 */
function handleInitData(data) {
  try {
    window.init = data;
    if (!window.init.characters) window.init.characters = [];
    if (!window.init.npcs) window.init.npcs = [];
    activeNpc = null;
    if (window.selectedObject) window.selectedObject.set(null);

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
      if (window.gameStarted) {
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
  if (!window.gameStarted || !window.init) return;
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
