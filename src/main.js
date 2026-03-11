import './style.css'
import { emotes } from './emotes.js';

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
      if (typeof handleInitData === 'function') {
        handleInitData(data);
      }
    } else if (data.type === 'update') {
      const serverChar = data.character;
      if (serverChar.id === player.id) return; // Prevent echoing our own state
      const localCharIndex = characters.findIndex(c => c.id === serverChar.id);
      if (localCharIndex > -1) {
        const localChar = characters[localCharIndex];
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
        characters.push(serverChar);
      }
    } else if (data.type === 'disconnect') {
      characters = characters.filter(c => c.id !== data.id);
    } else if (data.type === 'chat') {
      const charIndex = characters.findIndex(c => c.id === data.id);
      if (charIndex > -1) {
        characters[charIndex].chatMessage = data.message;
        characters[charIndex].chatTime = Date.now();
      } else if (player.id === data.id) {
        player.chatMessage = data.message;
        player.chatTime = Date.now();
      }
    } else if (data.type === 'collision_objects_update') {
      collisionObjects = data.collisionObjects || [];
      window.collisionObjects = collisionObjects;
    } else if (data.type === 'buildings_update') {
      buildings = data.buildings || [];
      window.buildings = buildings;
    }
  } catch (e) {
    console.error(e);
  }
};

// Resize canvas to fill window
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

  if (e.code === 'Space') {
    const hector = characters.find(c => c.name === 'Hector');
    if (hector) {
      const dist = Math.hypot(hector.x - player.x, hector.y - player.y);
      if (dist < 80) { // Interaction distance
        hector.chatMessage = "today we shall play a good game";
        hector.chatTime = Date.now();
      }
    }

    const poop = characters.find(c => c.name === 'Talking Poop');
    if (poop) {
      const dist = Math.hypot(poop.x - player.x, poop.y - player.y);
      if (dist < 80) {
        poop.chatMessage = "god i am poo forever";
        poop.chatTime = Date.now();
      }
    }
    e.preventDefault();
  }

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
  rotationSpeed: 0.05,
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

// Map Objects
let collisionObjects = [];
window.collisionObjects = collisionObjects;
let buildings = [];
window.buildings = buildings;
let characters = [];
let lastSyncTime = 0;

window.mapImage = new Image();
window.mapImage.src = '/grounds/background.png'; // default fallback

function syncPlayerToJSON() {
  const charIndex = characters.findIndex(c => c.id === player.id);
  if (charIndex > -1) {
    characters[charIndex].x = player.x;
    characters[charIndex].y = player.y;
    characters[charIndex].rotation = player.rotation;
    characters[charIndex].name = player.name; // Keep name synced
    characters[charIndex].emote = player.emote;

    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'update', character: characters[charIndex] }));
    }
  }
}

// Game Loop
function gameLoop() {
  update();
  draw();
  if (isAdmin && window.adminDraw) {
    window.adminDraw();
  }
  requestAnimationFrame(gameLoop);
}
window.gameLoop = gameLoop;

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
    const scale = window.characterScale || 1;
    dx += Math.round(Math.cos(player.rotation) * (player.moveSpeed || 3) * scale);
    dy += Math.round(Math.sin(player.rotation) * (player.moveSpeed || 3) * scale);
  }
  if (keys.ArrowDown) {
    const scale = window.characterScale || 1;
    dx -= Math.round(Math.cos(player.rotation) * (player.moveSpeed || 3) * scale);
    dy -= Math.round(Math.sin(player.rotation) * (player.moveSpeed || 3) * scale);
  }

  let isMoving = false;
  if (dx !== 0 || dy !== 0) {
    isMoving = true;

    const scale = window.characterScale || 1;
    const playerRadius = 15 * scale; // slightly smaller than half width for smooth collisions

    const canMoveTo = (newX, newY) => {
      // Check map boundaries
      const mapW = window.mapWidth || (window.mapImage && window.mapImage.complete ? window.mapImage.width : 0);
      const mapH = window.mapHeight || (window.mapImage && window.mapImage.complete ? window.mapImage.height : 0);
      if (mapW && mapH) {
        const halfMapW = mapW / 2;
        const halfMapH = mapH / 2;
        if (newX - playerRadius < -halfMapW || newX + playerRadius > halfMapW ||
          newY - playerRadius < -halfMapH || newY + playerRadius > halfMapH) {
          return false;
        }
      }

      // Check collision objects
      for (const obj of collisionObjects) {
        if (obj.shape === 'circle') {
          const distSq = (newX - obj.x) ** 2 + (newY - obj.y) ** 2;
          const r = Math.max(obj.width, obj.length) / 2;
          const minD = r + playerRadius;
          if (distSq < minD * minD) {
            return false;
          }
        } else if (obj.shape === 'rect') {
          const halfW = obj.width / 2;
          const halfL = obj.length / 2;
          const rectLeft = obj.x - halfW;
          const rectRight = obj.x + halfW;
          const rectTop = obj.y - halfL;
          const rectBottom = obj.y + halfL;

          // closest point on rect to player
          const closestX = Math.max(rectLeft, Math.min(newX, rectRight));
          const closestY = Math.max(rectTop, Math.min(newY, rectBottom));

          const distSq = (newX - closestX) ** 2 + (newY - closestY) ** 2;
          if (distSq < playerRadius * playerRadius) {
            return false;
          }
        }
      }

      // Check building walls
      for (const building of buildings) {
        if (!building.walls) continue;

        const bdx = newX - building.x;
        const bdy = newY - building.y;
        const angle = -(building.rotation || 0) * Math.PI / 180;

        // Inverse rotation to get local coordinates relative to center
        const localX = bdx * Math.cos(angle) - bdy * Math.sin(angle);
        const localY = bdx * Math.sin(angle) + bdy * Math.cos(angle);

        // Offset so (0,0) is top-left
        const tlX = localX + building.width / 2;
        const tlY = localY + building.height / 2;

        for (const wall of building.walls) {
          const wStartX = wall.x;
          const wStartY = wall.y;
          let wEndX = wStartX;
          let wEndY = wStartY;

          if (wall.endX !== undefined && wall.endY !== undefined) {
            wEndX = wall.endX;
            wEndY = wall.endY;
          } else if (wall.height !== undefined) {
            // Vertical wall
            wEndY = wStartY + wall.height;
          } else {
            // Horizontal wall
            wEndX = wStartX + (wall.length || wall.width || 0);
          }

          let checkDistSq;
          const l2 = (wEndX - wStartX) ** 2 + (wEndY - wStartY) ** 2;

          if (l2 === 0) {
            checkDistSq = (tlX - wStartX) ** 2 + (tlY - wStartY) ** 2;
          } else {
            let t = ((tlX - wStartX) * (wEndX - wStartX) + (tlY - wStartY) * (wEndY - wStartY)) / l2;
            t = Math.max(0, Math.min(1, t));
            checkDistSq = (tlX - (wStartX + t * (wEndX - wStartX))) ** 2 + (tlY - (wStartY + t * (wEndY - wStartY))) ** 2;
          }

          if (checkDistSq < playerRadius * playerRadius) {
            return false;
          }
        }
      }

      return true;
    };

    // Try moving in both axes, then X only, then Y only (sliding against walls)
    if (canMoveTo(player.x + dx, player.y + dy)) {
      player.x += dx;
      player.y += dy;
    } else if (canMoveTo(player.x + dx, player.y)) {
      player.x += dx;
    } else if (canMoveTo(player.x, player.y + dy)) {
      player.y += dy;
    }
  }

  // Animation
  if (isMoving) {
    player.legAnimationTime += 0.2;
    if (player.emote) {
      player.emote = null;
      syncPlayerToJSON();
    }
  } else {
    // Smoother stop: reset animation to neutral when stopped
    player.legAnimationTime = 0;
  }

  // Smoothly interpolate other characters to their server positions
  for (const c of characters) {
    if (c.id === player.id) continue;

    if (c.targetX !== undefined && c.targetY !== undefined) {
      const cdx = c.targetX - c.x;
      const cdy = c.targetY - c.y;
      const dist = Math.hypot(cdx, cdy);

      // Snap if teleported really far
      if (dist > 100) {
        c.x = c.targetX;
        c.y = c.targetY;
        c.rotation = c.targetRotation;
      } else if (dist > 0.5) {
        // Walk towards the target position at character's walking speed, or slightly faster if lagging far behind
        const scale = window.characterScale || 1;
        const speed = (c.moveSpeed || 3) * scale;
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
        while (rotDiff > Math.PI) rotDiff -= Math.PI * 2;
        while (rotDiff < -Math.PI) rotDiff += Math.PI * 2;

        if (Math.abs(rotDiff) > 0.01) {
          const rotSpeed = c.rotationSpeed || 0.15;
          const rotStep = Math.min(Math.abs(rotDiff), rotSpeed);
          c.rotation = (c.rotation || 0) + Math.sign(rotDiff) * rotStep;
        } else {
          c.rotation = c.targetRotation;
        }
      }
    }
  }

  // (Basic screen boundaries removed to allow world movement)

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

function draw() {
  window.cameraX = player.x;
  window.cameraY = player.y;

  if (window.mapWidth && window.mapHeight) {
    const halfMapW = window.mapWidth / 2;
    const halfMapH = window.mapHeight / 2;
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

  if (window.mapImage && window.mapImage.complete) {
    const drawW = window.mapWidth || window.mapImage.width;
    const drawH = window.mapHeight || window.mapImage.height;
    ctx.drawImage(window.mapImage, -drawW / 2, -drawH / 2, drawW, drawH);
  }


  // Draw Characters
  characters.forEach(char => {
    // Current player might have updated legAnimationTime / x / y locally
    const c = (char.id === player.id) ? player : char;

    ctx.save();
    ctx.translate(c.x, c.y);
    ctx.rotate(c.rotation);

    const scale = window.characterScale || 1;
    ctx.scale(scale, scale);

    if (c.name === 'Talking Poop') {
      ctx.font = '60px sans-serif';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.rotate(-c.rotation); // keep it upright
      ctx.fillText('💩', 0, 0);
    } else if (c.name === 'Dancing Toilet') {
      ctx.font = '60px sans-serif';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.rotate(-c.rotation); // keep it upright

      // Make the toilet dance (bounce and tilt)
      const danceTime = Date.now() / 150;
      const bounce = Math.abs(Math.sin(danceTime)) * -15;
      const tilt = Math.sin(danceTime * 0.8) * 0.3;

      ctx.translate(0, bounce);
      ctx.rotate(tilt);

      ctx.fillText('🚽', 0, 0);
    } else {
      let currentEmote = c.emote;
      let emoteDef = null;
      if (currentEmote && emotes[currentEmote.name]) {
        emoteDef = emotes[currentEmote.name];
        if (Date.now() - currentEmote.startTime > emoteDef.duration) {
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

      // --- LEGS ---
      ctx.lineWidth = 7;
      ctx.lineCap = 'round';
      ctx.strokeStyle = c.pantsColor || '#2c3e50';

      // Left Leg
      ctx.beginPath();
      ctx.moveTo(limbs.leftLegStartX, limbs.leftLegStartY);
      ctx.lineTo(limbs.leftLegEndX, limbs.leftLegEndY);
      ctx.stroke();

      // Right Leg
      ctx.beginPath();
      ctx.moveTo(limbs.rightLegStartX, limbs.rightLegStartY);
      ctx.lineTo(limbs.rightLegEndX, limbs.rightLegEndY);
      ctx.stroke();

      // --- ARMS ---
      ctx.lineWidth = 5;
      ctx.strokeStyle = c.armColor || '#3498db';

      // Left Arm
      ctx.beginPath();
      ctx.moveTo(0, -11);
      ctx.lineTo(limbs.leftArmX, limbs.leftArmY);
      ctx.stroke();

      // Right Arm
      ctx.beginPath();
      ctx.moveTo(0, 11);
      ctx.lineTo(limbs.rightArmX, limbs.rightArmY);
      ctx.stroke();

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

      const scale = window.characterScale || 1;
      ctx.fillText(c.name, 0, 15 + 15 * scale);
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
      const scale = window.characterScale || 1;
      const bubbleY = -(20 + 15 * scale);

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
  });

  // Restore camera translation
  ctx.restore();
}





// Start By Fetching Data

let isDataLoaded = false;
const nameDialog = document.getElementById('name-dialog');
const nameInput = document.getElementById('player-name-input');
const startBtn = document.getElementById('start-game-btn');

function attemptStartGame() {
  if (isDataLoaded) {
    if (nameInput && nameInput.value.trim() !== '') {
      player.name = nameInput.value.trim();
      syncPlayerToJSON(); // Save the new name right away
    }
    if (nameDialog) nameDialog.style.display = 'none';
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

function handleInitData(data) {
  isDataLoaded = false;
  collisionObjects = data.collisionObjects || [];
  buildings = data.buildings || [];
  window.collisionObjects = collisionObjects;
  window.buildings = buildings;
  characters = [...(data.npcs || []), ...(data.characters || [])];

  const myCharacter = data.myCharacter;
  const mapMetadata = data.mapData;
  const mapsList = data.mapsList;

  if (myCharacter) {
    Object.assign(player, myCharacter);
  } else {
    const playerConfig = characters.find(c => c.id === player.id);
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
    window.mapWidth = mapMetadata.width;
    window.mapHeight = mapMetadata.height;
    window.currentMapId = mapMetadata.id;
    window.characterScale = mapMetadata.character_scale || 1;
  }

  console.log(mapsList)
  console.log(window.mapsList)
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
    isDataLoaded = true;
    if (startBtn) {
      startBtn.textContent = 'Start Game';
      startBtn.disabled = false;
    }
    if (nameInput && nameInput.value.trim() !== '') {
      nameInput.focus();
    }
  }).catch(err => {
    // Allow trying to start despite errors
    isDataLoaded = true;
    if (startBtn) {
      startBtn.textContent = 'Start Game';
      startBtn.disabled = false;
    }
  });
}

// --- VIRTUAL JOYSTICK & MOBILE CONTROLS ---
const moveContainer = document.getElementById('joystick-move-container');
const moveKnob = document.getElementById('joystick-move-knob');
const turnContainer = document.getElementById('joystick-turn-container');
const turnKnob = document.getElementById('joystick-turn-knob');
const actionButton = document.getElementById('action-button');

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

if (actionButton) {
  const triggerAction = (e) => {
    if (e.cancelable) e.preventDefault();
    // Simulate Spacebar press for Hector to speak
    const hector = characters.find(c => c.name === 'Hector');
    if (hector) {
      const dist = Math.hypot(hector.x - player.x, hector.y - player.y);
      if (dist < 80) {
        hector.chatMessage = "today we shall play a good game";
        hector.chatTime = Date.now();
      }
    }
    const poop = characters.find(c => c.name === 'Talking Poop');
    if (poop) {
      const dist = Math.hypot(poop.x - player.x, poop.y - player.y);
      if (dist < 80) {
        poop.chatMessage = "god i am poo forever";
        poop.chatTime = Date.now();
      }
    }
  };
  actionButton.addEventListener('mousedown', triggerAction);
  actionButton.addEventListener('touchstart', triggerAction, { passive: false });
}

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
