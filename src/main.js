import './style.css'

const canvas = document.getElementById('gameCanvas');
const ctx = canvas.getContext('2d');

// --- WEBSOCKET CLIENT ---
const ws = new WebSocket(`ws://${window.location.hostname}:8080`);

ws.onopen = () => {
  console.log('Connected to WebSocket server');
};

ws.onmessage = (event) => {
  try {
    const data = JSON.parse(event.data);
    if (data.type === 'init') {
      if (typeof handleInitData === 'function') {
        handleInitData(data.plants || [], data.buildings || [], data.characters || [], data.npcs || [], data.myCharacter);
      }
    } else if (data.type === 'update') {
      const serverChar = data.character;
      if (serverChar.id === player.id) return; // Prevent echoing our own state
      const localCharIndex = characters.findIndex(c => c.id === serverChar.id);
      if (localCharIndex > -1) {
        Object.assign(characters[localCharIndex], serverChar);
      } else {
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
    } else if (data.type === 'buildings_update') {
      buildings = data.buildings || [];
      // Preload any new SVGs
      buildings.forEach(building => {
        if (!preloadedImages[building.svg]) {
          const img = new Image();
          img.onerror = () => console.error(`Failed to load SVG: ${building.svg}`);
          img.src = `/${building.svg}`;
          preloadedImages[building.svg] = img;
        }
      });
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
        if (ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({ type: 'chat', message: msg }));
        }
        chatInput.value = '';
        
        // Optimistic local update
        player.chatMessage = msg;
        player.chatTime = Date.now();
      }
      chatInput.blur();
    } else {
      chatInput.focus();
      e.preventDefault();
    }
    return;
  }

  if (isChatFocused) return;

  if (keys.hasOwnProperty(e.code)) {
    keys[e.code] = true;
  }
});

window.addEventListener('keyup', (e) => {
  if (keys.hasOwnProperty(e.code)) {
    keys[e.code] = false;
  }
});

// Player Entity
let player = {
  id: 'player1',
  moveSpeed: 5,
  rotationSpeed: 0.05,
  legAnimationTime: 0,
  _lastSentX: null,
  _lastSentY: null,
  _lastSentRotation: null,
  x: window.innerWidth / 2,
  y: window.innerHeight / 2,
  width: 40,
  height: 40,
  rotation: 0
};

// Map Objects
let plants = [];
let buildings = [];
let characters = [];
let preloadedImages = {};
let lastSyncTime = 0;

function syncPlayerToJSON() {
  const charIndex = characters.findIndex(c => c.id === player.id);
  if (charIndex > -1) {
    characters[charIndex].x = player.x;
    characters[charIndex].y = player.y;
    characters[charIndex].rotation = player.rotation;
    characters[charIndex].name = player.name; // Keep name synced

    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'update', character: characters[charIndex] }));
    }
  }
}

// Game Loop
function gameLoop() {
  update();
  draw();
  requestAnimationFrame(gameLoop);
}

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
    dx += Math.round(Math.cos(player.rotation) * player.moveSpeed);
    dy += Math.round(Math.sin(player.rotation) * player.moveSpeed);
  }
  if (keys.ArrowDown) {
    dx -= Math.round(Math.cos(player.rotation) * player.moveSpeed);
    dy -= Math.round(Math.sin(player.rotation) * player.moveSpeed);
  }

  let isMoving = false;
  if (dx !== 0 || dy !== 0) {
    isMoving = true;
    
    const playerRadius = 15; // slightly smaller than half width for smooth collisions

    const canMoveTo = (newX, newY) => {
      // Check plants
      for (const plant of plants) {
        const distSq = (newX - plant.x) ** 2 + (newY - plant.y) ** 2;
        const minD = (plant.size || 20) + playerRadius;
        if (distSq < minD * minD) {
          return false;
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
  } else {
    // Smoother stop: reset animation to neutral when stopped
    player.legAnimationTime = 0;
  }

  // (Basic screen boundaries removed to allow world movement)

  // Sync back via websocket 20 times a second if moved
  const now = Date.now();
  if (now - lastSyncTime > 50) {
    if (player.x !== player._lastSentX || player.y !== player._lastSentY || player.rotation !== player._lastSentRotation) {
      player._lastSentX = player.x;
      player._lastSentY = player.y;
      player._lastSentRotation = player.rotation;
      lastSyncTime = now;
      syncPlayerToJSON();
    }
  }
}

function draw() {
  // Clear screen (fixed to screen coordinates)
  ctx.fillStyle = '#7bed9f'; // Grass green color
  ctx.fillRect(0, 0, canvas.width, canvas.height);

  // Camera translation (Centers the world on the player)
  ctx.save();
  ctx.translate(canvas.width / 2 - player.x, canvas.height / 2 - player.y);

  // --- BUILDINGS ---
  // Drawn first so they appear on the ground beneath the player and plants
  buildings.forEach(building => {
    const img = preloadedImages[building.svg];
    if (img && img.complete) {
      ctx.save();
      ctx.translate(building.x, building.y);
      // Canvas rotate requires radians, so convert from defined degrees
      ctx.rotate(building.rotation * Math.PI / 180);
      ctx.drawImage(img, -building.width / 2, -building.height / 2, building.width, building.height);
      ctx.restore();
    }
  });

  // Draw Characters
  characters.forEach(char => {
    // Current player might have updated legAnimationTime / x / y locally
    const c = (char.id === player.id) ? player : char;

    ctx.save();
    ctx.translate(c.x, c.y);
    ctx.rotate(c.rotation);

    const legSwing = Math.sin(c.legAnimationTime || 0);
    const legStride = 15;
    const armStride = 8;

    // --- LEGS ---
    ctx.lineWidth = 7;
    ctx.lineCap = 'round';
    ctx.strokeStyle = c.pantsColor || '#2c3e50';

    // Left Leg
    ctx.beginPath();
    ctx.moveTo(-2, -6);
    ctx.lineTo(-2 + 10 + legSwing * legStride, -6);
    ctx.stroke();

    // Right Leg
    ctx.beginPath();
    ctx.moveTo(-2, 6);
    ctx.lineTo(-2 + 10 - legSwing * legStride, 6);
    ctx.stroke();

    // --- ARMS ---
    ctx.lineWidth = 5;
    ctx.strokeStyle = c.armColor || '#3498db';

    // Left Arm
    ctx.beginPath();
    ctx.moveTo(0, -11);
    ctx.lineTo(4 - legSwing * armStride, -14);
    ctx.stroke();

    // Right Arm
    ctx.beginPath();
    ctx.moveTo(0, 11);
    ctx.lineTo(4 + legSwing * armStride, 14);
    ctx.stroke();

    // Hands
    ctx.fillStyle = '#f1c27d'; // Skin tone
    ctx.beginPath();
    ctx.arc(4 - legSwing * armStride, -14, 3, 0, Math.PI * 2);
    ctx.fill();

    ctx.beginPath();
    ctx.arc(4 + legSwing * armStride, 14, 3, 0, Math.PI * 2);
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

      ctx.fillText(c.name, 0, 30);
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
      const bubbleY = -35; 
      
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

  // --- PLANTS ---
  // Drawn after the player to act as an overhead canopy. The player walks "under" the leaves.
  plants.forEach(plant => {
    switch (plant.type) {
      case 'oak':
        // Drop shadow (offset to the bottom right)
        ctx.fillStyle = 'rgba(0, 0, 0, 0.3)';
        ctx.beginPath();
        ctx.arc(plant.x + 10, plant.y + 15, plant.size, 0, Math.PI * 2);
        ctx.fill();

        // Main canopy
        ctx.fillStyle = plant.color || '#2ecc71'; // Base green
        ctx.beginPath();
        ctx.arc(plant.x, plant.y, plant.size, 0, Math.PI * 2);
        ctx.fill();

        // Secondary darker layer for depth
        ctx.fillStyle = 'rgba(0,0,0,0.15)';
        ctx.beginPath();
        ctx.arc(plant.x - plant.size * 0.1, plant.y - plant.size * 0.1, plant.size * 0.8, 0, Math.PI * 2);
        ctx.fill();

        // Bright top highlight
        ctx.fillStyle = 'rgba(255,255,255,0.15)';
        ctx.beginPath();
        ctx.arc(plant.x - plant.size * 0.35, plant.y - plant.size * 0.35, plant.size * 0.45, 0, Math.PI * 2);
        ctx.fill();
        break;

      case 'pine':
        // Drop shadow
        ctx.fillStyle = 'rgba(0, 0, 0, 0.3)';
        ctx.beginPath();
        ctx.arc(plant.x + 8, plant.y + 12, plant.size * 0.8, 0, Math.PI * 2);
        ctx.fill();

        ctx.fillStyle = plant.color || '#1e8449';
        const spikes = 8;
        const outerRad = plant.size;
        const innerRad = plant.size * 0.6;

        // Base layer
        drawStar(ctx, plant.x, plant.y, spikes, outerRad, innerRad);
        ctx.fill();

        // Top layer (lighter)
        ctx.fillStyle = 'rgba(255,255,255,0.1)';
        drawStar(ctx, plant.x, plant.y, spikes, outerRad * 0.7, innerRad * 0.7);
        ctx.fill();
        break;

      case 'shrub':
        // A cluster of 3 circles
        ctx.fillStyle = 'rgba(0, 0, 0, 0.3)';
        ctx.beginPath();
        ctx.arc(plant.x + 5, plant.y + 8, plant.size, 0, Math.PI * 2);
        ctx.fill();

        ctx.fillStyle = plant.color || '#7dcea0';
        for (let i = 0; i < 3; i++) {
          const angle = (Math.PI * 2 / 3) * i;
          const px = plant.x + Math.cos(angle) * (plant.size * 0.4);
          const py = plant.y + Math.sin(angle) * (plant.size * 0.4);
          ctx.beginPath();
          ctx.arc(px, py, plant.size * 0.7, 0, Math.PI * 2);
          ctx.fill();
        }
        break;

      case 'flower':
        // Tiny stem
        ctx.fillStyle = '#27ae60';
        ctx.fillRect(plant.x - 1, plant.y, 2, plant.size * 1.5);

        // Petals
        ctx.fillStyle = plant.color || '#e74c3c';
        for (let i = 0; i < 5; i++) {
          const angle = (Math.PI * 2 / 5) * i;
          const px = plant.x + Math.cos(angle) * (plant.size * 0.8);
          const py = plant.y - plant.size * 0.5 + Math.sin(angle) * (plant.size * 0.8);
          ctx.beginPath();
          ctx.arc(px, py, plant.size * 0.6, 0, Math.PI * 2);
          ctx.fill();
        }
        // Center
        ctx.fillStyle = '#f1c40f'; // yellow center
        ctx.beginPath();
        ctx.arc(plant.x, plant.y - plant.size * 0.5, plant.size * 0.5, 0, Math.PI * 2);
        ctx.fill();
        break;
    }
  });

  // Restore camera translation
  ctx.restore();
}

// Helper function for pine stars
function drawStar(ctx, cx, cy, spikes, outerRadius, innerRadius) {
  let rot = Math.PI / 2 * 3;
  let x = cx;
  let y = cy;
  let step = Math.PI / spikes;

  ctx.beginPath();
  ctx.moveTo(cx, cy - outerRadius);
  for (let i = 0; i < spikes; i++) {
    x = cx + Math.cos(rot) * outerRadius;
    y = cy + Math.sin(rot) * outerRadius;
    ctx.lineTo(x, y);
    rot += step;

    x = cx + Math.cos(rot) * innerRadius;
    y = cy + Math.sin(rot) * innerRadius;
    ctx.lineTo(x, y);
    rot += step;
  }
  ctx.lineTo(cx, cy - outerRadius);
  ctx.closePath();
}

// Start By Fetching Data

let isDataLoaded = false;
const nameDialog = document.getElementById('name-dialog');
const nameInput = document.getElementById('player-name-input');
const startBtn = document.getElementById('start-game-btn');

function attemptStartGame() {
  if (isDataLoaded && nameInput.value.trim() !== '') {
    player.name = nameInput.value.trim();
    syncPlayerToJSON(); // Save the new name right away
    nameDialog.style.display = 'none';
    requestAnimationFrame(gameLoop); // Kick off the game loop
  }
}

startBtn.addEventListener('click', attemptStartGame);
nameInput.addEventListener('keypress', (e) => {
  if (e.key === 'Enter') attemptStartGame();
});

function handleInitData(plantsData, buildingsData, charactersData, npcsData, myCharacter) {
  plants = plantsData;
  buildings = buildingsData;
  characters = [...npcsData, ...charactersData];

  if (myCharacter) {
    Object.assign(player, myCharacter);
  } else {
    const playerConfig = characters.find(c => c.id === player.id);
    if (playerConfig) {
      Object.assign(player, playerConfig);
    }
  }

  // Auto-fill if name exists
  if (player.name) {
    nameInput.value = player.name;
  }

  // Preload building SVGs
  const imagePromises = buildingsData.map(building => {
    return new Promise((resolve) => {
      if (preloadedImages[building.svg]) {
        resolve();
        return;
      }
      const img = new Image();
      img.onload = () => resolve();
      img.onerror = () => {
        console.error(`Failed to load SVG: ${building.svg}`);
        resolve();
      };
      img.src = `/${building.svg}`;
      preloadedImages[building.svg] = img;
    });
  });

  Promise.all(imagePromises).then(() => {
    isDataLoaded = true;
    startBtn.textContent = 'Start Game';
    startBtn.disabled = false;
    if (nameInput.value.trim() !== '') nameInput.focus();
  }).catch(err => {
    console.error("Error initializing game data:", err);
    // Allow trying to start despite errors
    isDataLoaded = true;
    startBtn.textContent = 'Start Game';
    startBtn.disabled = false;
  });
}
