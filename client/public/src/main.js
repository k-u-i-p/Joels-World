import { initSound, soundManager } from './sound.js';
import { emotes, getEmoteMessage } from './emotes.js';
import { processEvents } from './events.js';
import { mapManager } from './maps.js';
import { characterManager, updateLocalNPCs } from './characters.js';
import { physicsEngine } from './physics.js';
import { inputManager } from './input.js';
import { networkClient } from './network.js';
import { uiManager } from './ui.js';
import { gameLoop } from './gameloop.js';

import * as THREE from 'three';

const MAX_SPRING = 100;
const SPRING_SPEED = 1.0;

const canvas = document.getElementById('gameCanvas');
export const renderer = new THREE.WebGLRenderer({ canvas: document.getElementById('gameCanvas'), antialias: false });
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.setPixelRatio(window.devicePixelRatio);
renderer.setClearColor(0x7bed9f); // Grass green color
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
export const scene = new THREE.Scene();

const ambientLight = new THREE.AmbientLight(0xffffff, 0.7); // Base visibility
scene.add(ambientLight);

const dirLight = new THREE.DirectionalLight(0xffffff, 0.6);
dirLight.position.set(50, -100, 150); // Angled down from top-front
dirLight.castShadow = true;
dirLight.shadow.mapSize.width = 1024;
dirLight.shadow.mapSize.height = 1024;
dirLight.shadow.camera.near = 0.5;
dirLight.shadow.camera.far = 1500;
dirLight.shadow.camera.left = -500;
dirLight.shadow.camera.right = 500;
dirLight.shadow.camera.top = -500;
dirLight.shadow.camera.bottom = 500;
dirLight.shadow.bias = -0.001;
scene.add(dirLight);
scene.add(dirLight.target); // Expose the light target to the engine scene graph for dynamic viewport tracking

// Invisible Plane to catch the geometric shadows
const shadowPlane = new THREE.Mesh(
    new THREE.PlaneGeometry(10000, 10000),
    new THREE.ShadowMaterial({ opacity: 0.3 })
);
shadowPlane.position.z = 0.5;
shadowPlane.receiveShadow = true;
scene.add(shadowPlane);
export const threeCamera = new THREE.OrthographicCamera(-1, 1, -1, 1, -1000, 1000);

// We invert the Y frustum to match HTML5 Canvas standard coordinates (Y-down)
threeCamera.up.set(0, -1, 0);
export const camera = {
  x: 0,
  y: 0,
  zoom: 1,
  springX: 0,
  springY: 0
};

// --- WEBSOCKET CLIENT ---
networkClient.connect((data) => {
  handleInitData(data);
});

function clamp(number, min, max) {
  return Math.max(min, Math.min(number, max));
}

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
    renderer.setSize(viewportWidth, viewportHeight, true);
    renderer.setPixelRatio(dpr);

    const aspectOffsetW = viewportWidth / 2;
    const aspectOffsetH = viewportHeight / 2;
    threeCamera.left = -aspectOffsetW;
    threeCamera.right = aspectOffsetW;
    threeCamera.top = aspectOffsetH;   // HTML5 is Y-Down, so frustum must flip mapping
    threeCamera.bottom = -aspectOffsetH;
    threeCamera.updateProjectionMatrix();
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
        player.activeEmoteAudio.fadeOut(500);
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

window.adminCameraConfig = {
    setPitch: (val) => { camera.pitch = Math.max(0, Math.min(Math.PI / 2.1, (camera.pitch || 0) + val)); },
    setYaw: (val) => { camera.yaw = (camera.yaw || 0) + val; }
};

export const footprints = [];

uiManager.initHelpDialog();
uiManager.initEmotesDialog();
uiManager.initBadgesDialog();
uiManager.initMinimapDialog();

/**
 * Processes all user inputs, updates the player coordinates, evaluates collisions,
 * triggers object entry/exit logics, and interpolates remote entity positions.
 */
function update(dt = 0.016) {
  const timeScale = (dt * 60) || 1;

  // Spring setup
  camera.springX = camera.springX || 0;
  camera.springY = camera.springY || 0;
  const decay = Math.pow(0.001 * SPRING_SPEED, dt);

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
        player.activeEmoteAudio.fadeOut(500);
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

    const actualDx = result.newX - player.x;
    const actualDy = result.newY - player.y;

    const blockedDx = dx - actualDx;
    const blockedDy = dy - actualDy;

    // Apply tension to camera if pushing into a wall, otherwise decay that axis
    if (Math.abs(blockedDx) > 0.01) {
      camera.springX += blockedDx * SPRING_SPEED;
    } else {
      camera.springX *= decay;
    }

    if (Math.abs(blockedDy) > 0.01) {
      camera.springY += blockedDy * SPRING_SPEED;
    } else {
      camera.springY *= decay;
    }

    const dist = Math.sqrt(camera.springX * camera.springX + camera.springY * camera.springY);
    if (dist > MAX_SPRING) {
      camera.springX = (camera.springX / dist) * MAX_SPRING;
      camera.springY = (camera.springY / dist) * MAX_SPRING;
    }

    isMoving = result.isMoving;
    player.x = result.newX;
    player.y = result.newY;

    if (result.emoteCanceled) {
      if (player.activeEmoteAudio) {
        player.activeEmoteAudio.fadeOut(500);
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
          player.activeEmoteAudio.fadeOut(500);
          player.activeEmoteAudio = null;
        }
        player.emote = null;
        networkClient.syncPlayerToJSON();
      }
    }
  } else {
    // Smoother stop: reset animation to neutral when stopped and snap camera back
    camera.springX *= decay;
    camera.springY *= decay;
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
 * Master rendering function. Updates WebGL camera transformations, 
 * draws the map, all visible characters, and user interface elements.
 */
function draw() {
  camera.x = player.x + (camera.springX || 0);
  // Offset camera Y slightly higher so the player renders lower down in the view, leaving more space above them
  camera.y = player.y - (viewportHeight / camera.zoom * 0.15) + (camera.springY || 0);

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
      camera.x = Math.max(minX, Math.min(maxX, camera.x));
    } else {
      camera.x = 0;
    }

    if (minY <= maxY) {
      camera.y = Math.max(minY, Math.min(maxY, camera.y));
    } else {
      camera.y = 0;
    }
  }

  // Determine dynamic spherical camera positioning using Pitch and Yaw
  const pitch = Math.max(0.001, camera.pitch || 0.001); // Prevent top-down Gimbal Lock collision
  const yaw = camera.yaw || 0;     // Rotation around Z axis
  const orbDistance = 500;

  // Real world coordinates of the focus target (The player)
  const targetX = camera.x - xOffset;
  const targetY = -(camera.y - yOffset);

  // Position camera relative to target
  threeCamera.position.x = targetX + Math.sin(yaw) * Math.sin(pitch) * orbDistance;
  threeCamera.position.y = targetY - Math.cos(yaw) * Math.sin(pitch) * orbDistance;
  threeCamera.position.z = Math.cos(pitch) * orbDistance;

  // Maintain rigid orientation upwards relative to the celestial Z-axis to physically lock the horizontal viewing compass
  threeCamera.up.set(0, 0, 1);
  threeCamera.lookAt(targetX, targetY, 0);

  // Lock the DirectionalLight's orthographic shadow bounds precisely over the camera's focus
  // This computationally guarantees PCFSoftShadowMaps render natively regardless of map traversal!
  dirLight.position.set(targetX + 50, targetY - 100, 150);
  dirLight.target.position.set(targetX, targetY, 0);
  dirLight.target.updateMatrixWorld();

  threeCamera.zoom = camera.zoom;
  threeCamera.updateProjectionMatrix();

  mapManager.drawLayer(0, scene, camera.x, camera.y, camera.zoom, viewportWidth, viewportHeight);

  // TODO: Implement WebGL Footprints

  characterManager.drawCharacters('base', scene, player, () => networkClient.syncPlayerToJSON(), camera.x, camera.y, camera.zoom, viewportWidth, viewportHeight, threeCamera);

  mapManager.drawLayer(1, scene, camera.x, camera.y, camera.zoom, viewportWidth, viewportHeight);

  let layer2SpringOffsetX = clamp(((camera.springX || 0)) * 0.05, -5, 5);
  let layer2SpringOffsetY = clamp(((camera.springY || 0)) * 0.05, -5, 5);
  // Pass spring offsets so mapManager can offset layer 2
  mapManager.drawLayer(2, scene, camera.x, camera.y, camera.zoom, viewportWidth, viewportHeight, layer2SpringOffsetX, layer2SpringOffsetY);

  characterManager.drawCharacters('overlay', scene, player, () => networkClient.syncPlayerToJSON(), camera.x, camera.y, camera.zoom, viewportWidth, viewportHeight, threeCamera);
  characterManager.drawCharacters('chat', scene, player, () => networkClient.syncPlayerToJSON(), camera.x, camera.y, camera.zoom, viewportWidth, viewportHeight, threeCamera);

  renderer.render(scene, threeCamera);
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
  if (data.type === 'init') {
    // Scrub existing WebGL meshes and DOM overlays from the outgoing map's players
    characterManager.clearScene(scene, window.init);
    characterManager.disposeCharacter(player, scene);

    // Deep clean the hybrid 2D proxy canvas to prevent lingering minigame pixel artifacts
    const ui = document.getElementById('uiCanvas');
    if (ui) {
      const uictx = ui.getContext('2d');
      uictx.clearRect(0, 0, ui.width, ui.height);
    }
  }

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

    gameLoop.clear();

    if (window.init.mapData && window.init.mapData.import) {
      console.log('[Main] Importing minigame: ' + window.init.mapData.import);

      const topUi = document.getElementById('top-center-ui');
      if (topUi) topUi.style.display = 'none';

      import(window.init.mapData.import).then(module => {
        module.initMinigame();
      });
    } else {
      if (!wasRunning) {
        console.log('[Main] Game loop rendering started for the first time.');
        if (window.init.mapData && window.init.mapData.on_enter && !window.init.mapData.import) {
          executeEvents(window.init.mapData, window.init.mapData.on_enter);
        }
      }

      const mapBtn = document.getElementById('map-button');
      const exitBtn = document.getElementById('exit-button');
      if (mapBtn) mapBtn.style.display = 'flex';
      if (exitBtn) exitBtn.style.display = 'none';

      const scoreboard = document.getElementById('tennis-scoreboard');
      if (scoreboard) scoreboard.style.display = 'none';

      const topUi = document.getElementById('top-center-ui');
      if (topUi) topUi.style.display = 'flex';

      gameLoop.registerFunction(updateLocalNPCs);
      gameLoop.registerFunction(update);
      gameLoop.registerFunction(draw);
    }

    if (window.isAdmin) {
      import('./admin.js').then(adminModule => {
        gameLoop.registerFunction(adminModule.adminDraw);
      });
    }

    gameLoop.start();

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

      mapManager.init(mapMetadata, scene);

      // Initialize the physics clip mask for this map if it has one
      physicsEngine.loadClipMask(mapMetadata.clip_mask, mapMetadata.width, mapMetadata.height);

      // Handle dynamic map audio swapping if already playing
      if (wasRunning) {
        if (mapMetadata.on_enter) {
          executeEvents(mapMetadata, mapMetadata.on_enter);
        } else {
          soundManager.stopBackground();
        }
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