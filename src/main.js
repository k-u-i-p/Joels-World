import './style.css'
import { emotes } from './emotes.js';
import { EventHandlers } from './events.js';

const canvas = document.getElementById('gameCanvas');
const ctx = canvas.getContext('2d');
window.cameraZoom = 1;

// --- WEBSOCKET CLIENT ---
const isAdmin = window.isAdmin === true;
const wsUrl = `ws://${window.location.host}`;
const ws = new WebSocket(wsUrl);
window.ws = ws;

ws.onopen = () => {
  console.log('Connected to WebSocket server');
};

ws.onmessage = (event) => {
  try {
    const data = JSON.parse(event.data);
    if (data.type === 'init') {
      handleInitData(data);
    } else if (data.type === 'update' || data.type === 'tick') {
      const charactersToUpdate = data.type === 'tick' ? data.characters : [data.character];
      charactersToUpdate.forEach(serverChar => {
        if (serverChar.id === player.id) return; // Prevent echoing our own state
        const localCharIndex = (window.init?.characters || []).findIndex(c => c.id === serverChar.id);
        if (localCharIndex > -1) {
          const localChar = window.init.characters[localCharIndex];
          // Set targets for interpolation
          localChar.targetX = serverChar.x;
          localChar.targetY = serverChar.y;
          localChar.targetRotation = serverChar.rotation;

          // Directly sync visual properties
          localChar.name = serverChar.name;
          localChar.pantsColor = serverChar.pantsColor;
          localChar.armColor = serverChar.armColor;
          localChar.emote = serverChar.emote;
        } else {
          serverChar.targetX = serverChar.x;
          serverChar.targetY = serverChar.y;
          serverChar.targetRotation = serverChar.rotation;
          if (!window.init) return;
          if (!window.init.characters) window.init.characters = [];
          window.init.characters.push(serverChar);
        }
      });
    } else if (data.type === 'disconnect') {
      if (window.init?.characters) window.init.characters = window.init.characters.filter(c => c.id !== data.id);
    } else if (data.type === 'chat') {
      const charIndex = (window.init?.characters || []).findIndex(c => c.id === data.id);
      if (charIndex > -1) {
        window.init.characters[charIndex].chatMessage = data.message;
        window.init.characters[charIndex].chatTime = Date.now();
      } else if (player.id === data.id) {
        player.chatMessage = data.message;
        player.chatTime = Date.now();
      }
    } else if (data.type === 'objects_update') {
      if (window.init) {
        window.init.objects = data.objects || [];
      } else {
        window.init = { objects: data.objects || [] };
      }
    } else if (data.type === 'npcs_update') {
      if (window.init) {
        window.init.npcs = data.npcs || [];
      } else {
        window.init = { npcs: data.npcs || [] };
      }
    }
  } catch (e) {
    console.error(e);
  }
};

// Resize canvas to fill window
/**
 * Resizes the canvas dimensions to match the current window inner width and height.
 */
function resize() {
  canvas.width = window.innerWidth;
  canvas.height = window.innerHeight;
}
window.addEventListener('resize', resize);
resize();

// Input State
const keys = {
  ArrowUp: false,
  ArrowDown: false,
  ArrowLeft: false,
  ArrowRight: false
};

const chatInput = document.getElementById('chat-input');
let isChatFocused = false;

chatInput.addEventListener('focus', () => { isChatFocused = true; });
chatInput.addEventListener('blur', () => { isChatFocused = false; });

const UI = {
  get avatarsContainer() { return this._ac || (this._ac = document.getElementById('avatars-container')); },
  get dialogOverlay() { return this._do || (this._do = document.getElementById('action-dialog-content')); },
  get dialogText() { return this._dt || (this._dt = document.getElementById('action-dialog-text')); },
  get btnYes() { return this._by || (this._by = document.getElementById('action-dialog-yes')); },
  get btnNo() { return this._bn || (this._bn = document.getElementById('action-dialog-no')); }
};

const movementCoords = [{ x: 0, y: 0 }, { x: 0, y: 0 }, { x: 0, y: 0 }];
const exactCoords = [{ x: 0, y: 0 }];

window.addEventListener('keydown', (e) => {
  const nameDialog = document.getElementById('name-dialog');
  if (nameDialog && nameDialog.style.display !== 'none') return;

  if (e.code === 'Enter') {
    if (isChatFocused) {
      if (chatInput.value.trim() !== '') {
        const msg = chatInput.value.trim();
        chatInput.value = '';

        if (msg[0] === '/') {
          const command = msg.toLowerCase().substring(1);
          if (emotes[command]) {
            player.emote = { name: command, startTime: Date.now() };
            if (emotes[command].message) {
              const msgText = emotes[command].message.replace('{name}', player.name || 'Someone');
              if (ws.readyState === WebSocket.OPEN) {
                ws.send(JSON.stringify({ type: 'chat', message: msgText }));
              }
              player.chatMessage = msgText;
              player.chatTime = Date.now();
            }
            syncPlayerToJSON();
          }
        } else {
          if (ws.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify({ type: 'chat', message: msg }));
          }
          // Optimistic local update
          player.chatMessage = msg;
          player.chatTime = Date.now();
        }
      }
      chatInput.blur();
    } else {
      chatInput.focus();
      e.preventDefault();
    }
    return;
  }

  if (isChatFocused || e.target.tagName === 'INPUT') return;

  if (keys.hasOwnProperty(e.code)) {
    keys[e.code] = true;
  }
});

window.addEventListener('keyup', (e) => {
  if (e.target.tagName === 'INPUT') return;
  if (keys.hasOwnProperty(e.code)) {
    keys[e.code] = false;
  }
});



// Player Entity
let player = {
  id: 'player1',
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

window.mapImage = new Image();
window.mapImage.src = '/grounds/background.png'; // default fallback

let syncTimeout = null;
let lastSyncCallTime = 0;
const SYNC_THROTTLE_MS = 50;

/**
 * Throttles the synchronization of the player's state (position, rotation, etc.)
 * to the server via WebSocket. Ensures a maximum of one payload sent every SYNC_THROTTLE_MS.
 */
function syncPlayerToJSON() {
  const now = Date.now();
  if (now - lastSyncCallTime >= SYNC_THROTTLE_MS) {
    lastSyncCallTime = now;
    if (syncTimeout) {
      clearTimeout(syncTimeout);
      syncTimeout = null;
    }
    doSyncPlayerToJSON();
  } else {
    if (!syncTimeout) {
      syncTimeout = setTimeout(() => {
        lastSyncCallTime = Date.now();
        syncTimeout = null;
        doSyncPlayerToJSON();
      }, SYNC_THROTTLE_MS - (now - lastSyncCallTime));
    }
  }
}

/**
 * Executes the actual payload construction and WebSocket transmission for the player's 
 * synchronized state towards the server.
 */
function doSyncPlayerToJSON() {
  const charIndex = (window.init?.characters || []).findIndex(c => c.id === player.id);
  if (charIndex > -1) {
    window.init.characters[charIndex].x = player.x;
    window.init.characters[charIndex].y = player.y;
    window.init.characters[charIndex].rotation = player.rotation;
    window.init.characters[charIndex].name = player.name; // Keep name synced
    window.init.characters[charIndex].emote = player.emote;

    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'update', character: window.init.characters[charIndex] }));
    }
  }
}

// Game Loop
/**
 * The main render and update loop handling user movement inputs, drawing operations,
 * and next frame scheduling.
 */
function gameLoop() {
  update();
  draw();
  if (isAdmin && window.adminDraw) {
    window.adminDraw();
  }

  requestAnimationFrame(gameLoop);
}
window.gameLoop = gameLoop;

/**
 * Helper function to detect if a specific coordinate and radius overlaps with a collision object.
 * Applies rotated rectangle math and bounding circle math.
 * @param {Object} obj - The map object to test against.
 * @param {number} x - The target X coordinate.
 * @param {number} y - The target Y coordinate.
 * @param {number} radius - The collision radius around the coords.
 * @param {number} [clipOverlapAllowed=0] - How much overlap is allowed (for clipping calculations).
 * @returns {boolean} True if the entity point overlaps the object bounds.
 */
function checkObjectOverlap(obj, x, y, radius, clipOverlapAllowed = 0) {
  // Broad-phase AABB rejection
  const maxDim = Math.max(obj.width || 0, obj.length || 0) / 2;
  // Account for diagonal/rotation loosely in broad phase by multiplying by sqrt(2) approx 1.5
  const broadRadius = maxDim * 1.5 + radius;
  if (Math.abs(obj.x - x) > broadRadius || Math.abs(obj.y - y) > broadRadius) {
    return false;
  }

  if (obj.shape === 'circle') {
    const distSq = (x - obj.x) ** 2 + (y - obj.y) ** 2;
    const r = Math.max(obj.width, obj.length) / 2;
    const effectiveR = Math.max(0, r - clipOverlapAllowed);
    return distSq <= (effectiveR + radius) ** 2;
  } else if (obj.shape === 'rect') {
    let testX = x;
    let testY = y;

    if (obj.rotation) {
      const angle = -obj.rotation * Math.PI / 180;
      const bdx = x - obj.x;
      const bdy = y - obj.y;
      testX = obj.x + bdx * Math.cos(angle) - bdy * Math.sin(angle);
      testY = obj.y + bdx * Math.sin(angle) + bdy * Math.cos(angle);
    }

    const halfW = Math.max(0, (obj.width / 2) - clipOverlapAllowed);
    const halfL = Math.max(0, (obj.length / 2) - clipOverlapAllowed);
    const rectLeft = obj.x - halfW;
    const rectRight = obj.x + halfW;
    const rectTop = obj.y - halfL;
    const rectBottom = obj.y + halfL;

    const closestX = Math.max(rectLeft, Math.min(testX, rectRight));
    const closestY = Math.max(rectTop, Math.min(testY, rectBottom));

    const distSq = (testX - closestX) ** 2 + (testY - closestY) ** 2;
    return distSq <= radius * radius;
  }
  return false;
}

/**
 * Detects which collision objects in the given list overlap with the specified coordinates and radius.
 * @param {Array} objectsList - List of collision/interactive objects to check against.
 * @param {Array} coordsArray - Array of {x, y} coordinate objects to test for overlaps.
 * @param {number} [radius=0] - The collision radius around the coords to expand testing bounds.
 * @returns {Array} List of objects that intersect with the given coordinates.
 */
function findObjectsAt(objectsList, coordsArray, radius = 0) {
  const foundObjects = [];
  for (const obj of (objectsList || [])) {
    for (const { x, y } of coordsArray) {
      if (checkObjectOverlap(obj, x, y, radius, 0)) {
        foundObjects.push(obj);
        break; // Avoid pushing same object multiple times if large radius intersects multiple coords
      }
    }
  }
  return foundObjects;
}

/**
 * Evaluates whether a certain movement displacement is valid, factoring in map boundaries
 * and the `clip` permissions of all collision shapes in the world.
 * @param {Array} objectsList - List of map objects to test clipping against.
 * @param {number} newX - The target X coordinate.
 * @param {number} newY - The target Y coordinate.
 * @param {number} playerRadius - The collision radius of the moving entity.
 * @returns {boolean} True if the entity can move to the new coordinates, otherwise false.
 */
function canMoveTo(objectsList, newX, newY, playerRadius) {
  // Check map boundaries
  const mapW = window.init?.mapData?.width || (window.mapImage && window.mapImage.complete ? window.mapImage.width : 0);
  const mapH = window.init?.mapData?.height || (window.mapImage && window.mapImage.complete ? window.mapImage.height : 0);
  if (mapW && mapH) {
    const halfMapW = mapW / 2;
    const halfMapH = mapH / 2;
    if (newX - playerRadius < -halfMapW || newX + playerRadius > halfMapW ||
      newY - playerRadius < -halfMapH || newY + playerRadius > halfMapH) {
      return false;
    }
  }

  // Check clipping
  for (const obj of objectsList) {
    if (obj.clip === undefined) obj.clip = 10;
    const clipOverlapAllowed = obj.clip;

    if (clipOverlapAllowed === -1) continue; // Completely noclip

    // Because checkObjectOverlap uses strictly <= for radius evaluation, and canMoveTo was using < for radius * radius,
    // we do not need to alter our radius here.
    if (checkObjectOverlap(obj, newX, newY, playerRadius - 0.0001, clipOverlapAllowed)) {
      return false; // Point inside collision object
    }
  }

  return true;
}

/**
 * Processes all user inputs, updates the player coordinates, evaluates collisions,
 * triggers object entry/exit logics, and interpolates remote entity positions.
 */
function update() {
  // Rotation (tank controls)
  if (keys.ArrowLeft) {
    player.rotation -= player.rotationSpeed;
  }
  if (keys.ArrowRight) {
    player.rotation += player.rotationSpeed;
  }

  // Movement (tank controls)
  let dx = 0;
  let dy = 0;

  if (keys.ArrowUp) {
    dx += Math.round(Math.cos(player.rotation * Math.PI / 180) * (player.moveSpeed || 3));
    dy += Math.round(Math.sin(player.rotation * Math.PI / 180) * (player.moveSpeed || 3));
  }
  if (keys.ArrowDown) {
    dx -= Math.round(Math.cos(player.rotation * Math.PI / 180) * (player.moveSpeed || 3));
    dy -= Math.round(Math.sin(player.rotation * Math.PI / 180) * (player.moveSpeed || 3));
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

    const possibleOverlaps = findObjectsAt(window.init?.objects, movementCoords, playerRadius);

    // Try moving in both axes, then X only, then Y only (sliding against walls)
    if (canMoveTo(possibleOverlaps, player.x + dx, player.y + dy, playerRadius)) {
      player.x += dx;
      player.y += dy;
    } else if (canMoveTo(possibleOverlaps, player.x + dx, player.y, playerRadius)) {
      player.x += dx;
    } else if (canMoveTo(possibleOverlaps, player.x, player.y + dy, playerRadius)) {
      player.y += dy;
    }

    if (possibleOverlaps.length > 0) {
      exactCoords[0].x = player.x;
      exactCoords[0].y = player.y;
      const actuallyInObject = findObjectsAt(possibleOverlaps, exactCoords, 0);
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
            executeEvents(oldObj, oldObj.on_exit);
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
          const dialogOverlay = UI.dialogOverlay;
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
          executeEvents(oldObj, oldObj.on_exit);
        }
        player.activeBuilding = null;
        const dialogOverlay = UI.dialogOverlay;
        if (dialogOverlay) dialogOverlay.style.display = 'none';
      }
    }
  }

  // Animation
  if (isMoving) {
    player.legAnimationTime += 0.2;
    if (player.emote) {
      let shouldCancel = true;
      if (player.activeBuilding) {
        const activeObj = window.init?.objects?.find(o => o.id === player.activeBuilding);
        if (activeObj && activeObj.on_enter) {
          const envEmote = activeObj.on_enter.find(a => a.emote === player.emote.name);
          if (envEmote) shouldCancel = false;
        }
      }
      if (shouldCancel) {
        player.emote = null;
        syncPlayerToJSON();
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
      } else if (distSq > 0.25) { // 0.5^2 = 0.25
        const dist = Math.sqrt(distSq); // Only do square root if we actually need to walk
        // Walk towards the target position at character's walking speed, or slightly faster if lagging far behind
        const speed = c.moveSpeed || 3;
        const moveStep = Math.max(speed, dist * 0.1);
        const step = Math.min(dist, moveStep);

        c.x += (cdx / dist) * step;
        c.y += (cdy / dist) * step;
        c.legAnimationTime = (c.legAnimationTime || 0) + 0.2;

      } else {
        c.x = c.targetX;
        c.y = c.targetY;
        c.legAnimationTime = 0; // stop moving legs
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
      if (prevNpc.on_exit && (typeof prevNpc.on_exit === 'number' || prevNpc.on_exit.length > 0)) {
        executeEvents(prevNpc, prevNpc.on_exit);
      }
      // Auto-clear avatar when walking away from an NPC
      const container = UI.avatarsContainer;
      if (container) {
        const el = container.querySelector(`[data-npc-id="${prevNpc.id}"]`);
        if (el) el.remove();
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
      syncPlayerToJSON();
    }
  }
}

function executeEvents(sourceObj, rawActions) {
  let actions = rawActions;
  if (typeof rawActions === 'number') {
    const parentObj = window.init?.objects?.find(o => o.id === rawActions);
    if (!parentObj || !parentObj.on_enter) return;
    actions = parentObj.on_enter;
  }

  if (!actions || !Array.isArray(actions)) return;

  const context = {
    UI,
    player,
    syncPlayerToJSON
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

  if (window.init?.mapData?.width && window.init?.mapData?.height) {
    const halfMapW = window.init.mapData.width / 2;
    const halfMapH = window.init.mapData.height / 2;
    const viewHalfW = (canvas.width / window.cameraZoom) / 2;
    const viewHalfH = (canvas.height / window.cameraZoom) / 2;

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
  ctx.translate(canvas.width / 2, canvas.height / 2);
  ctx.scale(window.cameraZoom, window.cameraZoom);
  ctx.translate(-window.cameraX, -window.cameraY);

  drawMap();
  drawCharacters();

  // Restore camera translation
  ctx.restore();
}

/**
 * Renders the static background image of the map onto the canvas given current scaling.
 */
function drawMap() {
  if (window.mapImage && window.mapImage.complete) {
    const drawW = window.init?.mapData?.width || window.mapImage.width;
    const drawH = window.init?.mapData?.height || window.mapImage.height;
    ctx.drawImage(window.mapImage, -drawW / 2, -drawH / 2, drawW, drawH);
  }
}

/**
 * Iterates through all players and NPCs and renders the ones currently visible
 * within the camera bounds.
 */
function drawCharacters() {
  const viewHalfW = (canvas.width / window.cameraZoom) / 2;
  const viewHalfH = (canvas.height / window.cameraZoom) / 2;

  // Add some margin for character width/height and name tag
  const margin = 100;
  const minX = window.cameraX - viewHalfW - margin;
  const maxX = window.cameraX + viewHalfW + margin;
  const minY = window.cameraY - viewHalfH - margin;
  const maxY = window.cameraY + viewHalfH + margin;

  const processDraw = (char) => {
    // Current player might have updated legAnimationTime / x / y locally
    const c = (char.id === player.id) ? player : char;

    if (c.x >= minX && c.x <= maxX && c.y >= minY && c.y <= maxY) {
      drawCharacter(c);
    }
  };

  if (window.init?.characters) {
    for (let i = 0; i < window.init.characters.length; i++) processDraw(window.init.characters[i]);
  }
  if (window.init?.npcs) {
    for (let i = 0; i < window.init.npcs.length; i++) processDraw(window.init.npcs[i]);
  }
}

/**
 * Optimizes static NPC rendering by painting them onto an OffscreenCanvas once, 
 * then returning that canvas to be cheaply drawn each frame.
 * @param {Object} c - The character object data.
 * @param {number} scaleX - The character horizontal scale multiplier.
 * @param {number} scaleY - The character vertical scale multiplier.
 * @returns {HTMLCanvasElement|OffscreenCanvas} Prerendered graphics context instance.
 */
function getPrerenderedNpc(c, scaleX = 1, scaleY = 1) {
  if (c.prerenderedCanvas && c.prerenderedScaleX === scaleX && c.prerenderedScaleY === scaleY) {
    return c.prerenderedCanvas;
  }

  const baseSize = 100;
  const width = baseSize * scaleX;
  const height = baseSize * scaleY;
  const canvas = window.OffscreenCanvas ? new OffscreenCanvas(width, height) : document.createElement('canvas');
  if (!window.OffscreenCanvas) {
    canvas.width = width;
    canvas.height = height;
  }
  const octx = canvas.getContext('2d');

  octx.translate(width / 2, height / 2);
  octx.scale(scaleX, scaleY);

  const limbs = {
    leftArmX: 4, leftArmY: -14,
    rightArmX: 4, rightArmY: 14,
    leftLegStartX: -2, leftLegStartY: -6,
    leftLegEndX: 8, leftLegEndY: -6,
    rightLegStartX: -2, rightLegStartY: 6,
    rightLegEndX: 8, rightLegEndY: 6
  };

  const drawLine = (ctxObj, sx, sy, ex, ey) => {
    ctxObj.beginPath();
    ctxObj.moveTo(sx, sy);
    ctxObj.lineTo(ex, ey);
    ctxObj.stroke();
  };

  octx.lineWidth = 7;
  octx.lineCap = 'round';
  octx.strokeStyle = c.pantsColor || '#2c3e50';

  drawLine(octx, limbs.leftLegStartX, limbs.leftLegStartY, limbs.leftLegEndX, limbs.leftLegEndY);
  drawLine(octx, limbs.rightLegStartX, limbs.rightLegStartY, limbs.rightLegEndX, limbs.rightLegEndY);

  octx.lineWidth = 5;
  octx.strokeStyle = c.armColor || '#3498db';

  drawLine(octx, 0, -11, limbs.leftArmX, limbs.leftArmY);
  drawLine(octx, 0, 11, limbs.rightArmX, limbs.rightArmY);

  octx.fillStyle = '#f1c27d';
  octx.beginPath();
  octx.arc(limbs.leftArmX, limbs.leftArmY, 3, 0, Math.PI * 2);
  octx.fill();

  octx.beginPath();
  octx.arc(limbs.rightArmX, limbs.rightArmY, 3, 0, Math.PI * 2);
  octx.fill();

  octx.fillStyle = c.shirtColor || '#3498db';
  if (octx.roundRect) {
    octx.beginPath();
    octx.roundRect(-8, -12, 16, 24, 6);
    octx.fill();
  } else {
    octx.fillRect(-8, -12, 16, 24);
  }

  octx.beginPath();
  octx.arc(2, 0, 8, 0, Math.PI * 2);
  octx.fillStyle = '#f1c27d';
  octx.fill();

  if (c.gender === 'female') {
    octx.fillStyle = '#e67e22';
    octx.beginPath();
    octx.arc(1, 0, 7, Math.PI / 2, Math.PI * 1.5, true);
    octx.fill();
  }

  octx.lineWidth = 2;
  octx.strokeStyle = 'rgba(0,0,0,0.4)';
  octx.stroke();

  c.prerenderedScaleX = scaleX;
  c.prerenderedScaleY = scaleY;
  c.prerenderedCanvas = canvas;
  return canvas;
}

/**
 * Master rendering component for an individual character. Translates the canvas 
 * matrices, evaluates what type of drawing logic applies (emoji, skeleton drawing,
 * or prerendered canvas), and then draws the limbs, torsos, and nameplates.
 * @param {Object} c - The character data including positions, colors, and roles.
 */
function drawCharacter(c) {
  ctx.save();
  ctx.translate(c.x, c.y);
  ctx.rotate(c.rotation * Math.PI / 180);

  const baseScale = window.init?.mapData?.character_scale || 1;
  const widthScale = (c.width || 40) / 40;
  const heightScale = (c.height || 40) / 40;
  const scaleX = baseScale * widthScale;
  const scaleY = baseScale * heightScale;
  ctx.scale(scaleX, scaleY);

  if (c.emoji) {
    ctx.font = '60px sans-serif';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.rotate(-c.rotation * Math.PI / 180); // keep it upright

    let currentEmote = c.emote;
    let emoteDef = null;
    if (currentEmote && emotes[currentEmote.name]) {
      emoteDef = emotes[currentEmote.name];
      // Note: for emoji objects we ignore duration drops as they are likely permanent configs for NPCs like toilets, 
      // but if a player managed to become an emoji, it would respect standard emote durations in the other branch.
      // Simply applying setup here:
      if (emoteDef.setup) {
        emoteDef.setup(ctx, currentEmote, c);
      }
    }

    ctx.fillText(c.emoji, 0, 0);
  } else {
    const isActualNpc = window.init?.npcs && window.init.npcs.some(n => n.id === c.id);
    const hasMovement = c.legAnimationTime && c.legAnimationTime > 0;

    if (isActualNpc && !hasMovement && !c.emote) {
      const prCnv = getPrerenderedNpc(c, scaleX, scaleY);
      // We pass the unscaled width/height because the prerendered canvas already baked the scale in.
      // But we still need to offset by its raw dimensions.
      // Reset the main context scale temporarily because the cache already has it applied
      ctx.save();
      ctx.scale(1 / scaleX, 1 / scaleY);
      ctx.drawImage(prCnv, -prCnv.width / 2, -prCnv.height / 2);
      ctx.restore();
    } else {
      let currentEmote = c.emote;
      let emoteDef = null;
      if (currentEmote && emotes[currentEmote.name]) {
        emoteDef = emotes[currentEmote.name];
        if (currentEmote.startTime !== 0 && Date.now() - currentEmote.startTime > emoteDef.duration) {
          c.emote = null;
          currentEmote = null;
          if (c === player) syncPlayerToJSON();
          emoteDef = null;
        } else if (emoteDef.setup) {
          emoteDef.setup(ctx, currentEmote, c);
        }
      }

      const legSwing = Math.sin(c.legAnimationTime || 0);
      const legStride = 15;
      const armStride = 8;

      let limbs = {
        leftArmX: 4 - legSwing * armStride,
        leftArmY: -14,
        rightArmX: 4 + legSwing * armStride,
        rightArmY: 14,
        leftLegStartX: -2,
        leftLegStartY: -6,
        leftLegEndX: -2 + 10 + legSwing * legStride,
        leftLegEndY: -6,
        rightLegStartX: -2,
        rightLegStartY: 6,
        rightLegEndX: -2 + 10 - legSwing * legStride,
        rightLegEndY: 6
      };

      if (emoteDef && emoteDef.updateLimbs) {
        emoteDef.updateLimbs(limbs, currentEmote);
      }

      const drawLine = (ctxObj, sx, sy, ex, ey) => {
        ctxObj.beginPath();
        ctxObj.moveTo(sx, sy);
        ctxObj.lineTo(ex, ey);
        ctxObj.stroke();
      };

      // --- LEGS ---
      ctx.lineWidth = 7;
      ctx.lineCap = 'round';
      ctx.strokeStyle = c.pantsColor || '#2c3e50';

      drawLine(ctx, limbs.leftLegStartX, limbs.leftLegStartY, limbs.leftLegEndX, limbs.leftLegEndY);
      drawLine(ctx, limbs.rightLegStartX, limbs.rightLegStartY, limbs.rightLegEndX, limbs.rightLegEndY);

      // --- ARMS ---
      ctx.lineWidth = 5;
      ctx.strokeStyle = c.armColor || '#3498db';

      drawLine(ctx, 0, -11, limbs.leftArmX, limbs.leftArmY);
      drawLine(ctx, 0, 11, limbs.rightArmX, limbs.rightArmY);

      // Hands
      ctx.fillStyle = '#f1c27d'; // Skin tone
      ctx.beginPath();
      ctx.arc(limbs.leftArmX, limbs.leftArmY, 3, 0, Math.PI * 2);
      ctx.fill();

      ctx.beginPath();
      ctx.arc(limbs.rightArmX, limbs.rightArmY, 3, 0, Math.PI * 2);
      ctx.fill();

      // --- TORSO ---
      ctx.fillStyle = c.shirtColor || '#3498db';
      if (ctx.roundRect) {
        ctx.beginPath();
        ctx.roundRect(-8, -12, 16, 24, 6);
        ctx.fill();
      } else {
        ctx.fillRect(-8, -12, 16, 24);
      }

      // --- HEAD ---
      ctx.beginPath();
      ctx.arc(2, 0, 8, 0, Math.PI * 2);
      ctx.fillStyle = '#f1c27d'; // Skin tone
      ctx.fill();

      // If gender modifies appearance
      if (c.gender === 'female') {
        ctx.fillStyle = '#e67e22'; // Default hair color example
        ctx.beginPath();
        // Draw simple curved hair
        ctx.arc(1, 0, 7, Math.PI / 2, Math.PI * 1.5, true);
        ctx.fill();
      }

      ctx.lineWidth = 2;
      ctx.strokeStyle = 'rgba(0,0,0,0.4)';
      ctx.stroke();

      // Draw X eyes if dead or tears or apply other custom drawing
      if (emoteDef && emoteDef.draw) {
        emoteDef.draw(ctx, currentEmote);
      }
    } // End of prerender else branch
  }

  ctx.restore();

  // --- NAME TAG ---
  // Drawn after restore so it does not rotate with the character
  if (c.name) {
    ctx.save();
    ctx.translate(c.x, c.y);
    ctx.fillStyle = 'rgba(255, 255, 255, 0.9)';
    ctx.font = 'bold 12px "Segoe UI", Tahoma, Geneva, Verdana, sans-serif';
    ctx.textAlign = 'center';

    // Draw name with a slight shadow for readability
    ctx.shadowColor = 'rgba(0, 0, 0, 0.8)';
    ctx.shadowBlur = 3;
    ctx.shadowOffsetX = 1;
    ctx.shadowOffsetY = 1;

    const baseScale = window.init?.mapData?.character_scale || 1;
    const nameYOffset = ((c.height || 40) / 2) * baseScale + 15;
    // Names should only scale uniformly with baseScale, not with character stretching, to keep text readable
    ctx.fillText(c.name, 0, nameYOffset);
    ctx.restore();
  }

  // --- SPEECH BUBBLE ---
  if (c.chatMessage && Date.now() - (c.chatTime || 0) < 5000) {
    ctx.save();
    ctx.translate(c.x, c.y);

    ctx.font = '14px "Segoe UI", Tahoma, Geneva, Verdana, sans-serif';
    const textWidth = ctx.measureText(c.chatMessage).width;
    const bubbleWidth = textWidth + 24;
    const bubbleHeight = 32;
    const baseScale = window.init?.mapData?.character_scale || 1;
    const bubbleY = -(((c.height || 40) / 2) * baseScale + 10);

    ctx.shadowColor = 'rgba(0, 0, 0, 0.25)';
    ctx.shadowBlur = 6;
    ctx.shadowOffsetY = 3;

    ctx.fillStyle = '#ffffff';
    ctx.beginPath();
    if (ctx.roundRect) {
      ctx.roundRect(-bubbleWidth / 2, bubbleY - bubbleHeight, bubbleWidth, bubbleHeight, 8);
    } else {
      ctx.rect(-bubbleWidth / 2, bubbleY - bubbleHeight, bubbleWidth, bubbleHeight);
    }
    ctx.fill();

    ctx.beginPath();
    ctx.moveTo(-6, bubbleY);
    ctx.lineTo(6, bubbleY);
    ctx.lineTo(0, bubbleY + 8);
    ctx.fill();

    ctx.shadowColor = 'transparent';
    ctx.shadowBlur = 0;
    ctx.shadowOffsetY = 0;

    ctx.fillStyle = '#2c3e50';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText(c.chatMessage, 0, bubbleY - bubbleHeight / 2);

    ctx.restore();
  }
}





// Start By Fetching Data

const nameDialog = document.getElementById('name-dialog');
const nameInput = document.getElementById('player-name-input');
const startBtn = document.getElementById('start-game-btn');

window.bgAudio = new Audio();
window.bgAudio.loop = true;
window.gameStarted = window.isAdmin || false;

/**
 * Fired when the user clicks 'Start Game' or presses Enter. Evaluates whether
 * they have entered an appropriate name, assigns it, and transitions visual UI
 * state into active gameplay loops.
 */
function attemptStartGame() {
  if (window.init !== null) {
    if (nameInput && nameInput.value.trim() !== '') {
      player.name = nameInput.value.trim();
      syncPlayerToJSON(); // Save the new name right away
    }
    if (nameDialog) nameDialog.style.display = 'none';
    window.gameStarted = true;

    // Initial load map events
    if (window.init.mapData && window.init.mapData.on_enter) {
      executeEvents(window.init.mapData, window.init.mapData.on_enter);
    }

    checkInitialSpawn();
    requestAnimationFrame(gameLoop); // Kick off the game loop
  }
}

if (startBtn) {
  startBtn.addEventListener('click', attemptStartGame);
}
if (nameInput) {
  nameInput.addEventListener('keypress', (e) => {
    if (e.key === 'Enter') attemptStartGame();
  });
}

/**
 * Intercepts the `init` payload from the WebSocket server after joining or mapping 
 * into a new world. Prepares and overwrites all lists of loaded NPCs, objects, 
 * background environments, and schedules the start of rendering logic.
 * @param {Object} data - The map's initialization data payload structured by the server.
 */
function handleInitData(data) {
  window.init = data;
  if (!window.init.characters) window.init.characters = [];
  if (!window.init.npcs) window.init.npcs = [];
  activeNpc = null;
  if (window.selectedObject) window.selectedObject.set(null);

  const avatarsContainer = UI.avatarsContainer;
  if (avatarsContainer) {
    avatarsContainer.innerHTML = '';
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
    if (mapMetadata.background) {
      window.mapImage.src = mapMetadata.background;
    }

    // Handle dynamic map audio swapping if already playing
    if (window.gameStarted) {
      if (mapMetadata.on_enter) {
        executeEvents(mapMetadata, mapMetadata.on_enter);
      } else {
        window.bgAudio.pause();
        window.bgAudio.src = "";
      }
      setTimeout(checkInitialSpawn, 100);
    }
  }

  if (mapsList) {
    window.mapsList = mapsList;
    if (window.populateAdminMaps) window.populateAdminMaps();
  }

  const mapPromise = new Promise((resolve) => {
    if (window.mapImage && window.mapImage.complete) {
      resolve();
    } else if (window.mapImage) {
      window.mapImage.onload = () => resolve();
      window.mapImage.onerror = () => {
        console.warn('Failed to load map background image');
        resolve();
      };
    } else {
      resolve();
    }
  });

  Promise.all([mapPromise]).then(() => {
    if (startBtn) {
      startBtn.textContent = 'Start Game';
      startBtn.disabled = false;
    }
    if (nameInput && nameInput.value.trim() !== '') {
      nameInput.focus();
    }
  }).catch(err => {
    // Allow trying to start despite errors
    if (startBtn) {
      startBtn.textContent = 'Start Game';
      startBtn.disabled = false;
    }
  });
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
    const actuallyInObject = findObjectsAt(possibleOverlaps, exactCoords, 0);
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

// --- VIRTUAL JOYSTICK & MOBILE CONTROLS ---
const moveContainer = document.getElementById('joystick-move-container');
const moveKnob = document.getElementById('joystick-move-knob');
const turnContainer = document.getElementById('joystick-turn-container');
const turnKnob = document.getElementById('joystick-turn-knob');

const maxRadius = 40;

const setupJoystick = (container, knob, axis) => {
  if (!container || !knob) return;

  let activeTouchId = null;
  let origin = { x: 0, y: 0 };

  const handleStart = (e) => {
    if (activeTouchId !== null) return; // Already active

    let clientX, clientY;
    if (e.changedTouches) {
      const touch = e.changedTouches[0];
      activeTouchId = touch.identifier;
      clientX = touch.clientX;
      clientY = touch.clientY;
    } else {
      activeTouchId = 'mouse';
      clientX = e.clientX;
      clientY = e.clientY;
    }

    const rect = container.getBoundingClientRect();
    origin = {
      x: rect.left + rect.width / 2,
      y: rect.top + rect.height / 2
    };
    handleMove(e);
  };

  const handleMove = (e) => {
    if (activeTouchId === null) return;
    if (e.cancelable) e.preventDefault();

    let clientX, clientY;
    if (e.changedTouches) {
      let found = false;
      for (let i = 0; i < e.changedTouches.length; i++) {
        if (e.changedTouches[i].identifier === activeTouchId) {
          clientX = e.changedTouches[i].clientX;
          clientY = e.changedTouches[i].clientY;
          found = true;
          break;
        }
      }
      if (!found) return; // This touch isn't ours
    } else {
      clientX = e.clientX;
      clientY = e.clientY;
    }

    const dx = clientX - origin.x;
    const dy = clientY - origin.y;
    const distance = Math.min(maxRadius, Math.hypot(dx, dy));
    const angle = Math.atan2(dy, dx);

    const knobX = distance * Math.cos(angle);
    const knobY = distance * Math.sin(angle);
    knob.style.transform = `translate(${knobX}px, ${knobY}px)`;

    if (axis === 'move') {
      keys.ArrowUp = false;
      keys.ArrowDown = false;
      if (distance > 10) {
        if (knobY < -15) keys.ArrowUp = true;
        if (knobY > 15) keys.ArrowDown = true;
      }
    } else if (axis === 'turn') {
      keys.ArrowLeft = false;
      keys.ArrowRight = false;
      if (distance > 10) {
        if (knobX < -15) keys.ArrowLeft = true;
        if (knobX > 15) keys.ArrowRight = true;
      }
    }
  };

  const handleEnd = (e) => {
    if (activeTouchId === null) return;

    if (e.changedTouches) {
      let found = false;
      for (let i = 0; i < e.changedTouches.length; i++) {
        if (e.changedTouches[i].identifier === activeTouchId) {
          found = true;
          break;
        }
      }
      if (!found) return; // This touch isn't ours
    }

    activeTouchId = null;
    knob.style.transform = `translate(0px, 0px)`;

    if (axis === 'move') {
      keys.ArrowUp = false;
      keys.ArrowDown = false;
    } else if (axis === 'turn') {
      keys.ArrowLeft = false;
      keys.ArrowRight = false;
    }
  };

  container.addEventListener('mousedown', handleStart);
  window.addEventListener('mousemove', handleMove, { passive: false });
  window.addEventListener('mouseup', handleEnd);

  container.addEventListener('touchstart', handleStart, { passive: false });
  window.addEventListener('touchmove', handleMove, { passive: false });
  window.addEventListener('touchend', handleEnd);
  window.addEventListener('touchcancel', handleEnd);
};

setupJoystick(moveContainer, moveKnob, 'move');
setupJoystick(turnContainer, turnKnob, 'turn');

// Help Dialog Logic
const helpButton = document.getElementById('help-button');
const helpDialog = document.getElementById('help-dialog');
const closeHelpBtn = document.getElementById('close-help-btn');

if (helpButton && helpDialog && closeHelpBtn) {
  helpButton.addEventListener('click', () => {
    helpDialog.style.display = 'flex';
  });

  closeHelpBtn.addEventListener('click', () => {
    helpDialog.style.display = 'none';
  });

  // Close when clicking outside of the dialog box
  helpDialog.addEventListener('click', (e) => {
    if (e.target === helpDialog) {
      helpDialog.style.display = 'none';
    }
  });
}
