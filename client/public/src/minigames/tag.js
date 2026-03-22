import { gameLoop } from '../gameloop.js';
import { inputManager } from '../input.js';
import { characterManager } from '../characters.js';
import { physicsEngine } from '../physics.js';
import { camera, player } from '../main.js';
import { soundManager } from '../sound.js';

const canvas = document.getElementById('gameCanvas');
const ctx = canvas.getContext('2d');

let minigameActive = false;
let bgImage = new Image();
bgImage.src = '/minigames/tag/map.svg'; // Correct path

let treesImage = new Image();
treesImage.src = '/minigames/tag/trees.svg';

// Map constraints are globally provided by window.init.mapData
const BASE_NPC_SPEED = 140;
const BASE_PLAYER_SPEED = 180;
const ROUND_TIME = 60; // 60 seconds

let state = {
  round: 1,
  timeRemaining: ROUND_TIME,
  lastTime: 0,
  players: [], // Includes player + NPCs
  itId: null,
  invincibleTime: 0 // Cooldown after tag
};

// Smooth shortest-angle interpolator
function lerpRotation(current, target, speedDt) {
  let rotDiff = target - current;
  while (rotDiff > 180) rotDiff -= 360;
  while (rotDiff < -180) rotDiff += 360;
  if (Math.abs(rotDiff) > 0.5) {
    const rotStep = Math.min(Math.abs(rotDiff), speedDt);
    return current + Math.sign(rotDiff) * rotStep;
  }
  return target;
}

function initPlayers() {
  state.players = [];

  // Add main player
  const myChar = window.init?.myCharacter || player;

  const p = {
    id: myChar.id || player.id,
    isLocalPlayer: true,
    name: myChar.name || player.name || 'You',
    x: 0,
    y: 0,
    z: 0,
    width: 40,
    height: 40,
    rotation: 90,
    gender: myChar.gender || 'male',
    shirtColor: myChar.shirtColor || '#3498db',
    pantsColor: myChar.pantsColor || '#2c3e50',
    armColor: myChar.armColor || '#3498db',
    shoeColor: myChar.shoeColor || '#111111',
    hairStyle: myChar.hairStyle || 'short',
    hairColor: myChar.hairColor || '#000000',
    legTimer: 0,
    speed: BASE_PLAYER_SPEED
  };
  state.players.push(p);

  // Generate 5 NPCs
  const names = ['Tommy', 'Sarah', 'Billy', 'Emily', 'Hector'];
  const colors = ['#e74c3c', '#f1c40f', '#2ecc71', '#9b59b6', '#e67e22'];
  const spawnPoints = [
    { x: -100, y: -100 },
    { x: 100, y: -100 },
    { x: -100, y: 100 },
    { x: 100, y: 100 },
    { x: 0, y: 150 }
  ];

  for (let i = 0; i < 5; i++) {
    // Spawn in a safe ring clustered around the center player position (0,0)
    state.players.push({
      id: 990 + i,
      isLocalPlayer: false,
      name: names[i],
      x: spawnPoints[i].x,
      y: spawnPoints[i].y,
      z: 0,
      width: 35,
      height: 35,
      rotation: Math.random() * 360,
      gender: i % 2 === 0 ? 'male' : 'female',
      shirtColor: colors[i],
      pantsColor: '#2c3e50',
      armColor: colors[i],
      shoeColor: '#111111',
      hairStyle: i % 2 === 0 ? 'messy' : 'ponytail',
      hairColor: '#000000',
      legTimer: 0,
      speed: BASE_NPC_SPEED
    });
  }

  // Randomly select who is "IT"
  const randIndex = Math.floor(Math.random() * state.players.length);
  state.itId = state.players[randIndex].id;
}

export function initMinigame() {
  if (minigameActive) {
    gameLoop.registerFunction(run);
    return;
  }
  console.log('[Tag] Initializing Minigame...');
  minigameActive = true;

  state.round = 1;
  state.timeRemaining = ROUND_TIME;
  state.invincibleTime = 0;
  state.lastTime = Date.now();

  initPlayers();

  // Background music
  soundManager.playBackground('/media/playground_sound_effect.mp3', 0.4);

  // Setup camera
  camera.x = state.players[0].x;
  camera.y = state.players[0].y;
  camera.zoom = 1.2;

  // Setup UI
  const mapBtn = document.getElementById('map-button');
  const exitBtn = document.getElementById('exit-button');
  if (mapBtn) mapBtn.style.display = 'none';
  if (exitBtn) {
    exitBtn.style.display = 'flex';
    exitBtn.onclick = () => {
      const dialogOverlay = document.getElementById('action-dialog');
      const dialogText = document.getElementById('action-dialog-text');
      const btnYes = document.getElementById('action-dialog-yes');
      const btnNo = document.getElementById('action-dialog-no');

      if (dialogOverlay && dialogText && btnYes && btnNo) {
        dialogText.textContent = 'Leave Game?';
        dialogOverlay.style.display = 'block';

        btnNo.onclick = () => {
          dialogOverlay.style.display = 'none';
        };

        btnYes.onclick = () => {
          dialogOverlay.style.display = 'none';
          import('../network.js').then(({ networkClient }) => {
            networkClient.send({ type: 'change_map', mapId: 0 }); // Back to Junior School
          });
        };
      }
    };
  }

  gameLoop.registerFunction(run);
}

function processNPCLogic(npc, itPlayer, dt) {
  const isIt = (npc.id === state.itId);
  let dx = 0, dy = 0;
  let targetAngle = null;
  let shouldMove = true;

  if (isIt) {
    // If IT, chase the closest player
    let closestDist = Infinity;
    let target = null;

    for (const p of state.players) {
      if (p.id === npc.id) continue;
      // Tag cooldown logic check: don't chase if invincible
      if (state.invincibleTime > 0) continue; 
      
      const dist = Math.sqrt((p.x - npc.x) ** 2 + (p.y - npc.y) ** 2);
      if (dist < closestDist) {
        closestDist = dist;
        target = p;
      }
    }

    if (target) {
      targetAngle = Math.atan2(target.y - npc.y, target.x - npc.x);
    } else {
      shouldMove = false; // No one to chase? Rest!
    }
  } else {
    // Flee from IT
    if (itPlayer) {
      const dist = Math.sqrt((itPlayer.x - npc.x) ** 2 + (itPlayer.y - npc.y) ** 2);
      
      // State machine logic
      if (!npc.tagState) npc.tagState = 'idle';
      
      if (dist < 300) {
        npc.tagState = 'flee';
      } else if (dist > 450 || state.invincibleTime > 0) {
        npc.tagState = 'idle';
      }

      if (npc.tagState === 'idle') {
        shouldMove = false; // Resting
      } else {
        // Fleeing
        targetAngle = Math.atan2(npc.y - itPlayer.y, npc.x - itPlayer.x); // Away from IT
      }
    }
  }

  // Avoid walls / obstacle steering
  if (shouldMove && targetAngle !== null) {
    // We sample angles increasingly far from the "ideal" target angle to find the best walkable path
    const angleOffsets = [0, 25, -25, 50, -50, 75, -75, 100, -100, 130, -130];
    let bestAngle = targetAngle;

    // We project a point 60+ pixels ahead to see if it's clear
    // Since we're just steering, 60 pixels is a good detection radius for "corners"
    for (const offset of angleOffsets) {
      const testAngle = targetAngle + (offset * Math.PI / 180);
      const testX = npc.x + Math.cos(testAngle) * 60;
      const testY = npc.y + Math.sin(testAngle) * 60;

      // Ensure that spot is playable and not colliding with clip mask boundary
      if (physicsEngine.checkClipMask(testX, testY, 15)) {
        bestAngle = testAngle;
        break; // Found the best unobstructed angle closest to our intention!
      }
    }

    dx = Math.cos(bestAngle);
    dy = Math.sin(bestAngle);
  }

  if (shouldMove && (dx !== 0 || dy !== 0)) {
    // Normalize and apply speed
    const len = Math.sqrt(dx * dx + dy * dy) || 1;
    let finalSpeed = npc.speed + (state.round - 1) * 20; // Increase speed per round
    if (isIt) finalSpeed *= 1.1; // IT is slightly faster

    const moveX = (dx / len) * finalSpeed * dt;
    const moveY = (dy / len) * finalSpeed * dt;

    // Natively handle physical barriers using the engine's standard sliding logic!
    const result = physicsEngine.processMovement(
      npc,
      moveX,
      moveY,
      window.init?.objects || [],
      window.init?.mapData,
      false,
      state.players
    );

    npc.x = result.newX;
    npc.y = result.newY;

    if (moveX !== 0 || moveY !== 0) {
      const newRotAngle = Math.atan2(moveY, moveX) * (180 / Math.PI);
      npc.rotation = lerpRotation(npc.rotation, newRotAngle, 600 * dt);
      npc.legTimer += 10 * dt;
    }
  }
}

function processLocalPlayerLogic(localP, dt) {
  let moveX = 0; let moveY = 0;

  if (inputManager.isPressed('TouchMove')) {
    moveX = inputManager.joystickVector.x;
    moveY = inputManager.joystickVector.y;
  } else {
    if (inputManager.isPressed('ArrowUp') || inputManager.isPressed('KeyW')) moveY -= 1;
    if (inputManager.isPressed('ArrowDown') || inputManager.isPressed('KeyS')) moveY += 1;
    if (inputManager.isPressed('ArrowLeft') || inputManager.isPressed('KeyA')) moveX -= 1;
    if (inputManager.isPressed('ArrowRight') || inputManager.isPressed('KeyD')) moveX += 1;
  }

  const len = Math.sqrt(moveX * moveX + moveY * moveY);
  if (len > 0.001) {
    let pSpeed = localP.speed;
    if (state.itId === localP.id) pSpeed *= 1.1; // IT is faster

    let finalMoveX = (moveX / len) * pSpeed * dt;
    let finalMoveY = (moveY / len) * pSpeed * dt;

    // Unify Player physics and sliding constraints to identical collision geometry
    const result = physicsEngine.processMovement(
      localP,
      finalMoveX,
      finalMoveY,
      window.init?.objects || [],
      window.init?.mapData,
      false,
      state.players
    );

    localP.x = result.newX;
    localP.y = result.newY;

    if (finalMoveX !== 0 || finalMoveY !== 0) {
      const targetAngle = Math.atan2(finalMoveY, finalMoveX) * (180 / Math.PI);
      localP.rotation = lerpRotation(localP.rotation, targetAngle, 800 * dt);
      localP.legTimer += 10 * dt;
    }
  }

  // Update camera smoothly
  camera.x += (localP.x - camera.x) * 5 * dt;
  camera.y += (localP.y - camera.y) * 5 * dt;
}

function processTagCollisions() {
  if (state.invincibleTime <= 0) {
    const currentIt = state.players.find(p => p.id === state.itId);
    if (currentIt) {
      for (const p of state.players) {
        if (p.id === currentIt.id) continue;

        const dist = Math.sqrt((p.x - currentIt.x) ** 2 + (p.y - currentIt.y) ** 2);
        if (dist < 45) {
          // Tagged!
          state.itId = p.id;
          state.invincibleTime = 1.5; // 1.5 seconds cooldown
          soundManager.playPooled('/media/jump.mp3', 0.8);
          break; // only one tag per frame
        }
      }
    }
  }
}

function run(dt) {
  if (!minigameActive) return;

  const now = Date.now();
  const realDt = (now - state.lastTime) / 1000;
  state.lastTime = now;

  state.timeRemaining -= realDt;
  if (state.invincibleTime > 0) state.invincibleTime -= realDt;

  if (state.timeRemaining <= 0) {
    state.round++;
    state.timeRemaining = ROUND_TIME;
    state.invincibleTime = 3; // Pause tags temporarily
  }

  const localP = state.players.find(p => p.isLocalPlayer);
  const itPlayer = state.players.find(p => p.id === state.itId);

  // 1. Process local player movement
  if (localP) {
    processLocalPlayerLogic(localP, dt);
  }

  // 2. Process NPCs
  for (const p of state.players) {
    if (!p.isLocalPlayer) {
      processNPCLogic(p, itPlayer, dt);
    }
  }

  // 3. Collision / Tag Logic
  processTagCollisions();

  draw();
}

function drawCharacter(ctx, p, isIt) {
  ctx.save();
  ctx.translate(p.x, p.y);

  // Shadow
  ctx.fillStyle = 'rgba(0,0,0,0.3)';
  ctx.beginPath();
  ctx.ellipse(0, 5, 12, 6, 0, 0, Math.PI * 2);
  ctx.fill();

  // It indicator
  if (isIt) {
    ctx.strokeStyle = '#e74c3c';
    ctx.lineWidth = 3;
    ctx.beginPath();
    ctx.ellipse(0, 5, 20, 10, 0, 0, Math.PI * 2);
    ctx.stroke();

    // Text
    ctx.fillStyle = '#e74c3c';
    ctx.font = 'bold 16px Arial';
    ctx.textAlign = 'center';
    ctx.fillText('IT', 0, -45);
  }

  // Prepare structural limbs based on legTimer
  const legSwing = Math.sin(p.legTimer);
  const legStride = 6;
  const bodyRotRad = p.rotation * (Math.PI / 180);

  ctx.rotate(bodyRotRad);

  // Limbs defined in local rotated space
  const limbs = {
    leftArmX: 4 - legSwing * 5, leftArmY: -14,
    rightArmX: 4 + legSwing * 5, rightArmY: 14,
    leftLegStartX: -2, leftLegStartY: -6,
    leftLegEndX: -2 + 6 + (legSwing * legStride), leftLegEndY: -6,
    rightLegStartX: -2, rightLegStartY: 6,
    rightLegEndX: -2 + 6 - (legSwing * legStride), rightLegEndY: 6
  };

  // Draw Shoes (Fixed perspective)
  // Tilted Perspective Rendering for the legs:
  const drawStretchingLeg = (sx, sy, ex, ey, isLeft) => {
    ctx.strokeStyle = p.pantsColor || '#2c3e50';
    ctx.lineWidth = 5;
    ctx.lineCap = 'round';
    ctx.beginPath();
    ctx.save();
    // Torso Anchor (Shifted up visually on the screen)
    ctx.rotate(-bodyRotRad);
    ctx.translate(0, -15);
    ctx.rotate(bodyRotRad);
    ctx.moveTo(sx, sy);
    ctx.restore();
    // Shoe Ground Anchor
    ctx.lineTo(ex, ey);
    ctx.stroke();

    // Render native hyper-realistic shoe
    characterManager.drawShoe(ctx, ex, ey, p.shoeColor || '#111111', isLeft);
  };

  drawStretchingLeg(limbs.leftLegStartX, limbs.leftLegStartY, limbs.leftLegEndX, limbs.leftLegEndY, true);
  drawStretchingLeg(limbs.rightLegStartX, limbs.rightLegStartY, limbs.rightLegEndX, limbs.rightLegEndY, false);

  // Torso Perspective Shift
  ctx.rotate(-bodyRotRad);
  ctx.translate(0, -15); // Torso altitude raise
  ctx.rotate(bodyRotRad);

  characterManager.drawHumanoidUpperBody(ctx, p, limbs);

  ctx.restore();
}

function drawHUD(ctx, viewportWidth) {
  // Timer & Round
  ctx.fillStyle = 'white';
  ctx.font = 'bold 24px Arial';
  ctx.textAlign = 'left';
  ctx.fillText(`Round: ${state.round}`, 20, 40);
  ctx.fillText(`Time: ${Math.ceil(state.timeRemaining)}s`, 20, 70);

  // You Are IT warning
  if (state.itId === player.id) {
    ctx.fillStyle = '#e74c3c';
    ctx.font = 'bold 36px Arial';
    ctx.textAlign = 'center';
    ctx.fillText('YOU ARE IT!', viewportWidth / 2, 60);
  }
}

/** Draws the entire game state */
function draw() {
  const dpr = window.devicePixelRatio || 1;
  const viewportWidth = canvas.clientWidth;
  const viewportHeight = canvas.clientHeight;

  ctx.fillStyle = '#7bed9f';
  ctx.fillRect(0, 0, canvas.width, canvas.height);

  ctx.save();
  ctx.scale(dpr, dpr);
  ctx.translate((viewportWidth / 2) | 0, (viewportHeight / 2) | 0);
  ctx.scale(camera.zoom, camera.zoom);
  ctx.translate(-(camera.x | 0), -(camera.y | 0));

  // Draw Map
  if (bgImage.complete) {
    // Assuming map is centered
    ctx.drawImage(bgImage, -bgImage.width / 2, -bgImage.height / 2);
  }

  // Sort players by Y coordinate for depth sorting
  const sortedPlayers = [...state.players].sort((a, b) => a.y - b.y);

  for (const p of sortedPlayers) {
    const isIt = p.id === state.itId;
    drawCharacter(ctx, p, isIt);
  }

  // Draw overlay trees with dynamic point-light camera shadow
  if (treesImage.complete) {
    ctx.save();
    // Shadow setup - more diffuse and softer
    ctx.shadowColor = 'rgba(0, 0, 0, 0.4)';
    ctx.shadowBlur = 10;

    // The camera is the sun.
    // Factor in a base south offset to match the isometric map perspective.
    const heightFactor = 0.15;
    const baseSouthOffset = 400; // Sun is conceptually 800px further "south"
    ctx.shadowOffsetX = (-camera.x - 200) * heightFactor;
    ctx.shadowOffsetY = -(camera.y + baseSouthOffset) * heightFactor;

    // Stylized semi-transparency for visibility
    ctx.globalAlpha = 0.9;

    // Draw directly over the same dimensions as the map
    ctx.drawImage(treesImage, -treesImage.width / 2, -treesImage.height / 2);
    ctx.restore();
  }

  ctx.restore();

  // Draw HUD Overlays (Fixed to screen)
  ctx.save();
  ctx.scale(dpr, dpr);

  drawHUD(ctx, viewportWidth);

  ctx.restore();
}

/** Stop minigame loop externally if needed */
export function cleanupMinigame() {
  minigameActive = false;
  soundManager.stopBackground();
}
