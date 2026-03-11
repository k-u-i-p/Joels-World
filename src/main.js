import './style.css'

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
        handleInitData(data.plants || [], data.buildings || [], data.characters || [], data.npcs || [], data.myCharacter);
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
        localChar.isDancing = serverChar.isDancing;
        localChar.fartTime = serverChar.fartTime;
        localChar.isDead = serverChar.isDead;
        localChar.isCrying = serverChar.isCrying;
        localChar.isGritty = serverChar.isGritty;
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
    } else if (data.type === 'plants_update') {
      plants = data.plants || [];
      window.plants = plants;
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

        if (msg.toLowerCase() === '/dance') {
          player.isDancing = true;
          player.isDead = false;
          player.isCrying = false;
          player.isGritty = false;
          syncPlayerToJSON();
        } else if (msg.toLowerCase() === '/fart') {
          player.fartTime = Date.now();
          syncPlayerToJSON();
        } else if (msg.toLowerCase() === '/dead') {
          player.isDead = true;
          player.isDancing = false;
          player.isCrying = false;
          player.isGritty = false;
          syncPlayerToJSON();
        } else if (msg.toLowerCase() === '/cry') {
          player.isCrying = true;
          player.isDancing = false;
          player.isDead = false;
          player.isGritty = false;
          syncPlayerToJSON();
        } else if (msg.toLowerCase() === '/gritty' || msg.toLowerCase() === 'daning gritty' || msg.toLowerCase() === 'dancing gritty') {
          player.isGritty = true;
          player.isCrying = false;
          player.isDancing = false;
          player.isDead = false;
          syncPlayerToJSON();
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
  isDancing: false,
  isDead: false,
  isCrying: false,
  isGritty: false,
  fartTime: 0,
  _lastSentX: null,
  _lastSentY: null,
  _lastSentRotation: null,
  _lastSentDancing: false,
  _lastSentDead: false,
  _lastSentCrying: false,
  _lastSentGritty: false,
  _lastSentFartTime: 0,
  x: window.innerWidth / 2,
  y: window.innerHeight / 2,
  width: 40,
  height: 40,
  rotation: 0
};
window.player = player;

// Map Objects
let plants = [];
window.plants = plants;
let buildings = [];
window.buildings = buildings;
let characters = [];
let lastSyncTime = 0;

window.mapImage = new Image();
window.mapImage.src = '/map.png';

function syncPlayerToJSON() {
  const charIndex = characters.findIndex(c => c.id === player.id);
  if (charIndex > -1) {
    characters[charIndex].x = player.x;
    characters[charIndex].y = player.y;
    characters[charIndex].rotation = player.rotation;
    characters[charIndex].name = player.name; // Keep name synced
    characters[charIndex].isDancing = player.isDancing;
    characters[charIndex].isDead = player.isDead;
    characters[charIndex].isCrying = player.isCrying;
    characters[charIndex].isGritty = player.isGritty;
    characters[charIndex].fartTime = player.fartTime;

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
      // Check map boundaries
      if (window.mapImage && window.mapImage.complete) {
        const halfMapW = window.mapImage.width / 2;
        const halfMapH = window.mapImage.height / 2;
        if (newX - playerRadius < -halfMapW || newX + playerRadius > halfMapW ||
          newY - playerRadius < -halfMapH || newY + playerRadius > halfMapH) {
          return false;
        }
      }

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
    if (player.isDancing || player.isDead || player.isCrying || player.isGritty) {
      player.isDancing = false;
      player.isDead = false;
      player.isCrying = false;
      player.isGritty = false;
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
    if (player.x !== player._lastSentX || player.y !== player._lastSentY || player.rotation !== player._lastSentRotation || player.isDancing !== player._lastSentDancing || player.fartTime !== player._lastSentFartTime || player.isDead !== player._lastSentDead || player.isCrying !== player._lastSentCrying || player.isGritty !== player._lastSentGritty) {
      player._lastSentDancing = player.isDancing;
      player._lastSentDead = player.isDead;
      player._lastSentCrying = player.isCrying;
      player._lastSentGritty = player.isGritty;
      player._lastSentFartTime = player.fartTime;
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

  if (window.mapImage && window.mapImage.complete) {
    const halfMapW = window.mapImage.width / 2;
    const halfMapH = window.mapImage.height / 2;
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
    ctx.drawImage(window.mapImage, -window.mapImage.width / 2, -window.mapImage.height / 2);
  }

  // --- BUILDINGS --- // (Admin draw moved to adminDraw)


  // Draw Characters
  characters.forEach(char => {
    // Current player might have updated legAnimationTime / x / y locally
    const c = (char.id === player.id) ? player : char;

    ctx.save();
    ctx.translate(c.x, c.y);
    ctx.rotate(c.rotation);

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
      if (c.isDead) {
        ctx.globalAlpha = 0.5;
      }

      const legSwing = Math.sin(c.legAnimationTime || 0);
      const legStride = 15;
      const armStride = 8;

      let leftArmX = 4 - legSwing * armStride;
      let leftArmY = -14;
      let rightArmX = 4 + legSwing * armStride;
      let rightArmY = 14;

      let leftLegStartX = -2;
      let leftLegStartY = -6;
      let leftLegEndX = -2 + 10 + legSwing * legStride;
      let leftLegEndY = -6;

      let rightLegStartX = -2;
      let rightLegStartY = 6;
      let rightLegEndX = -2 + 10 - legSwing * legStride;
      let rightLegEndY = 6;

      if (c.isDead) {
        // Starfish/Lying down pose
        // Arms splayed out
        leftArmX = -4; leftArmY = -22;
        rightArmX = -4; rightArmY = 22;
        // Legs stretched backwards
        leftLegStartX = -8; leftLegStartY = -4;
        leftLegEndX = -22; leftLegEndY = -10;
        rightLegStartX = -8; rightLegStartY = 4;
        rightLegEndX = -22; rightLegEndY = 10;
      } else if (c.isDancing) {
        // Floss dance animation
        const danceTime = Date.now() / 100;
        const swing = Math.sin(danceTime) * 12;
        const hipSwing = -swing * 0.4;

        leftLegStartY = -6 + hipSwing;
        leftLegEndY = -6 + hipSwing + 10;
        leftLegEndX = -2;
        rightLegStartY = 6 + hipSwing;
        rightLegEndY = 6 + hipSwing + 10;
        rightLegEndX = -2;

        leftArmX = 0; leftArmY = -14 + swing;
        rightArmX = 0; rightArmY = 14 + swing;
      } else if (c.isGritty) {
        // The Gritty dance
        const danceTime = Date.now() / 150;
        const swing = Math.sin(danceTime);
        const fastSwing = Math.sin(danceTime * 2);

        ctx.translate(fastSwing * 2, -Math.abs(fastSwing * 4)); // bobbing

        // Alternating heel taps
        if (swing > 0) {
          leftLegStartY = -6; leftLegEndY = -2; leftLegEndX = -4; // Tap forward
          rightLegStartY = 6; rightLegEndY = 6 + 10; rightLegEndX = -2; // Stand straight
        } else {
          leftLegStartY = -6; leftLegEndY = -6 + 10; leftLegEndX = -2; // Stand straight
          rightLegStartY = 6; rightLegEndY = 2; rightLegEndX = -4; // Tap forward
        }

        // Arms swinging back and forth in front
        leftArmX = 10 + swing * 8; leftArmY = -6;
        rightArmX = 10 - swing * 8; rightArmY = 6;
      }

      // --- LEGS ---
      ctx.lineWidth = 7;
      ctx.lineCap = 'round';
      ctx.strokeStyle = c.pantsColor || '#2c3e50';

      // Left Leg
      ctx.beginPath();
      ctx.moveTo(leftLegStartX, leftLegStartY);
      ctx.lineTo(leftLegEndX, leftLegEndY);
      ctx.stroke();

      // Right Leg
      ctx.beginPath();
      ctx.moveTo(rightLegStartX, rightLegStartY);
      ctx.lineTo(rightLegEndX, rightLegEndY);
      ctx.stroke();

      // --- ARMS ---
      ctx.lineWidth = 5;
      ctx.strokeStyle = c.armColor || '#3498db';

      // Left Arm
      ctx.beginPath();
      ctx.moveTo(0, -11);
      ctx.lineTo(leftArmX, leftArmY);
      ctx.stroke();

      // Right Arm
      ctx.beginPath();
      ctx.moveTo(0, 11);
      ctx.lineTo(rightArmX, rightArmY);
      ctx.stroke();

      // Hands
      ctx.fillStyle = '#f1c27d'; // Skin tone
      ctx.beginPath();
      ctx.arc(leftArmX, leftArmY, 3, 0, Math.PI * 2);
      ctx.fill();

      ctx.beginPath();
      ctx.arc(rightArmX, rightArmY, 3, 0, Math.PI * 2);
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

      // Draw X eyes if dead
      if (c.isDead) {
        ctx.beginPath();
        // Left eye X
        ctx.moveTo(3, -3); ctx.lineTo(7, 1);
        ctx.moveTo(7, -3); ctx.lineTo(3, 1);
        // Right eye X
        ctx.moveTo(3, -1); ctx.lineTo(7, 3);
        ctx.moveTo(7, -1); ctx.lineTo(3, 3);
        ctx.strokeStyle = 'rgba(0,0,0,0.8)';
        ctx.lineWidth = 1;
        ctx.stroke();
      } else if (c.isCrying) {
        // Draw eyes
        ctx.fillStyle = '#111';
        ctx.beginPath(); ctx.arc(5, -1, 1, 0, Math.PI * 2); ctx.fill();
        ctx.beginPath(); ctx.arc(5, 1, 1, 0, Math.PI * 2); ctx.fill();

        // Animated tears
        const tearProgress1 = (Date.now() % 1000) / 1000;
        const tearProgress2 = ((Date.now() + 500) % 1000) / 1000;

        ctx.fillStyle = '#3498db'; // blue tear

        // Left cheek tears
        ctx.beginPath(); ctx.arc(4 - tearProgress1 * 6, -2 - tearProgress1 * 2, 1.5, 0, Math.PI * 2); ctx.fill();
        ctx.beginPath(); ctx.arc(4 - tearProgress2 * 6, -2 - tearProgress2 * 2, 1.5, 0, Math.PI * 2); ctx.fill();

        // Right cheek tears
        ctx.beginPath(); ctx.arc(4 - tearProgress1 * 6, 2 + tearProgress1 * 2, 1.5, 0, Math.PI * 2); ctx.fill();
        ctx.beginPath(); ctx.arc(4 - tearProgress2 * 6, 2 + tearProgress2 * 2, 1.5, 0, Math.PI * 2); ctx.fill();
      }
    }

    ctx.restore();

    // --- FART CLOUD ---
    if (c.fartTime && Date.now() - c.fartTime < 1000) {
      const fartAge = Date.now() - c.fartTime;
      ctx.save();
      ctx.translate(c.x, c.y);
      ctx.rotate(c.rotation);
      ctx.globalAlpha = Math.max(0, 1 - (fartAge / 1000));
      ctx.fillStyle = '#2ecc71'; // Greenish cloud
      ctx.beginPath();
      ctx.arc(-20 - (fartAge / 50), 0, 10 + (fartAge / 30), 0, Math.PI * 2);
      ctx.fill();

      ctx.beginPath();
      ctx.arc(-15 - (fartAge / 40), 10, 6 + (fartAge / 40), 0, Math.PI * 2);
      ctx.fill();

      ctx.beginPath();
      ctx.arc(-15 - (fartAge / 40), -10, 6 + (fartAge / 40), 0, Math.PI * 2);
      ctx.fill();

      ctx.restore();
    }

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

  // Restore camera translation
  ctx.restore();
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
  window.plants = plants;
  window.buildings = buildings;
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

  const mapPromise = new Promise((resolve) => {
    if (window.mapImage && window.mapImage.complete) {
      resolve();
    } else if (window.mapImage) {
      window.mapImage.onload = () => resolve();
      window.mapImage.onerror = () => {
        console.warn('Failed to load map.png');
        resolve();
      };
    } else {
      resolve();
    }
  });

  Promise.all([mapPromise]).then(() => {
    isDataLoaded = true;
    startBtn.textContent = 'Start Game';
    startBtn.disabled = false;
    if (isAdmin) {
      attemptStartGame();
    } else if (nameInput.value.trim() !== '') {
      nameInput.focus();
    }
  }).catch(err => {
    // Allow trying to start despite errors
    isDataLoaded = true;
    startBtn.textContent = 'Start Game';
    startBtn.disabled = false;
    if (isAdmin) {
      attemptStartGame();
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
