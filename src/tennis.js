import { gameLoop } from './gameloop.js';
import { inputManager } from './input.js';
import { characterManager } from './characters.js';
import { player, camera } from './main.js';

const canvas = document.getElementById('gameCanvas');
const ctx = canvas.getContext('2d');

let minigameActive = false;
let npc = null;
let bgImage = new Image();
bgImage.src = '/minigames/tennis/map.png';

const GAME_HEIGHT = 800;
const PADDLE_SPEED = 250;
const NPC_SPEED = 200;
const BALL_SPEED = 300;
const BALL_RADIUS = 3;
const COURT_INNER_BOUNDS = { x: -78, y: 264, width: 100, height: 272 };

let state = {
  ballOffsetX: 0,
  ballY: GAME_HEIGHT / 2,
  ballVX: BALL_SPEED * 0.7,
  ballVY: BALL_SPEED * 0.7,
  playerOffsetX: 0,
  playerOffsetY: 0,
  npcOffsetX: 0,
  playerSwingTimer: 0,
  npcSwingTimer: 0,
  playerLegTimer: 0,
  npcLegTimer: 0,
  ballCurrentVelocity: BALL_SPEED * 0.7,
  ballCurrentPitchAngle: 0,
  ballCurrentHeight: 0,
};

// Player bounds
const PLAYER_BASE_Y = GAME_HEIGHT - 170;
function getPlayerY() {
  return PLAYER_BASE_Y + state.playerOffsetY;
}

// NPC bounds
const npcY = 170;

export function initMinigame() {
  console.log('[Tennis] Initializing Minigame...');
  minigameActive = true;

  // Find the opponent NPC if defined in map JSON, or create a dummy one
  if (window.init && window.init.npcs && window.init.npcs.length > 0) {
    npc = window.init.npcs[0];
  } else {
    npc = { id: 999, name: 'Opponent', width: 40, height: 40, gender: 'male', shirtColor: '#e74c3c' };
  }

  // Reset State
  state.playerOffsetX = 0;
  state.playerOffsetY = 0;
  state.npcOffsetX = 0;
  state.playerSwingTimer = 0;
  state.npcSwingTimer = 0;
  state.playerLegTimer = 0;
  state.npcLegTimer = 0;

  serveBall(false); // NPC serves first

  // Set camera roughly over the arena
  camera.x = 0;
  camera.y = GAME_HEIGHT / 2;
  camera.zoom = 1.8;

  gameLoop.registerFunction(update);
  gameLoop.registerFunction(draw);
}

function drawRacket(ctx, limbs, swingAngle = 0) {
  ctx.save();
  ctx.translate(limbs.rightArmX, limbs.rightArmY); // Position at the right hand explicitly

  // Rotate racket to point forward (local +X) and slightly outward (local +Y)
  // Math.PI / 2 correctly rotates the racket from drawing upright (-Y) to pointing forward (+X).
  // This single robust offset handles any arbitrary character rotation dynamically!
  ctx.rotate(Math.PI / 2 + 1.0 + swingAngle);

  // Handle
  ctx.fillStyle = '#2c3e50';
  ctx.fillRect(-2, -10, 4, 15);

  // Head frame
  ctx.strokeStyle = '#e74c3c';
  ctx.lineWidth = 2;
  ctx.beginPath();
  if (ctx.ellipse) {
    ctx.ellipse(0, -18, 8, 12, 0, 0, Math.PI * 2);
  } else {
    ctx.arc(0, -18, 10, 0, Math.PI * 2);
  }
  ctx.stroke();

  // Strings
  ctx.strokeStyle = 'rgba(236, 240, 241, 0.5)'; // Faint white strings
  ctx.lineWidth = 0.5;
  ctx.beginPath();
  // Vertical strings
  for (let i = -5; i <= 5; i += 3) {
    ctx.moveTo(i, -28);
    ctx.lineTo(i, -8);
  }
  // Horizontal strings
  for (let i = -26; i <= -10; i += 3) {
    ctx.moveTo(-6, i);
    ctx.lineTo(6, i);
  }
  ctx.stroke();

  ctx.restore();
}

function serveBall(playerServing) {
  const playerY = getPlayerY();
  // Start ball at the server
  state.ballOffsetX = playerServing ? state.playerOffsetX : state.npcOffsetX;
  state.ballY = playerServing ? playerY : npcY;

  // Pick a random spot in the designated inner court target
  const targetX = COURT_INNER_BOUNDS.x + Math.random() * COURT_INNER_BOUNDS.width;
  let targetY;
  if (playerServing) {
    // Player serves to NPC side (top half)
    targetY = COURT_INNER_BOUNDS.y + Math.random() * (COURT_INNER_BOUNDS.height / 2);
  } else {
    // NPC serves to Player side (bottom half)
    targetY = COURT_INNER_BOUNDS.y + (COURT_INNER_BOUNDS.height / 2) + Math.random() * (COURT_INNER_BOUNDS.height / 2);
  }

  // Calculate velocity to hit target
  state.ballCurrentHeight = 40; // Serve from waist height
  state.ballCurrentVelocity = BALL_SPEED * 0.7;

  const dx = targetX - state.ballOffsetX;
  const dy = targetY - state.ballY;
  const dist = Math.sqrt(dx * dx + dy * dy);

  const timeToTarget = dist / state.ballCurrentVelocity;
  const gravity = 800; // pixels per second squared
  const vZ = (0.5 * gravity * timeToTarget * timeToTarget - state.ballCurrentHeight) / timeToTarget;
  state.ballCurrentPitchAngle = Math.atan2(vZ, state.ballCurrentVelocity);

  state.ballVX = (dx / dist) * state.ballCurrentVelocity;
  state.ballVY = (dy / dist) * state.ballCurrentVelocity;

  // Trigger swing animation visually showing the serve
  if (playerServing) {
    state.playerSwingTimer = 0.25;
  } else {
    state.npcSwingTimer = 0.25;
  }
}

function getSwingState(timer, isApproaching) {
  if (timer > 0) {
    const progress = 1 - (timer / 0.25); // 0 to 1
    let angle = 0;
    let reach = 4;
    if (progress < 0.4) {
      const t = progress / 0.4;
      angle = t * 1.0; // Cock back (positive angle = backward/outward)
      reach = 4 + t * 4; // Slight pull
    } else {
      const t = (progress - 0.4) / 0.6;
      angle = 1.0 - t * 2.2; // Swing forcefully forward across the body
      reach = 8 + Math.sin(t * Math.PI) * 6; // Extend arm gracefully through the stroke
    }
    return { angle, reach };
  } else if (isApproaching) {
    return { angle: 1.0, reach: 4 }; // Hold cocked position
  } else {
    return { angle: 0, reach: 4 }; // Idle
  }
}

function update(dt) {
  if (!minigameActive) return;

  const playerY = getPlayerY();
  const PLAYABLE_HALF_WIDTH = 225; // 450 width total
  const SWING_DURATION = 0.25;

  if (state.playerSwingTimer > 0) {
    state.playerSwingTimer -= dt;
    if (state.playerSwingTimer < 0) state.playerSwingTimer = 0;
  }
  if (state.npcSwingTimer > 0) {
    state.npcSwingTimer -= dt;
    if (state.npcSwingTimer < 0) state.npcSwingTimer = 0;
  }

  const clamp = (val, min, max) => Math.min(Math.max(val, min), max);
  const isPlayerApproaching = state.ballVY > 0 && Math.abs(state.ballOffsetX - state.playerOffsetX) < 150 && (playerY - state.ballY) > 0 && (playerY - state.ballY) < 150;
  const isNpcApproaching = state.ballVY < 0 && Math.abs(state.ballOffsetX - state.npcOffsetX) < 150 && (state.ballY - npcY) > 0 && (state.ballY - npcY) < 150;

  const playerSwing = getSwingState(state.playerSwingTimer, isPlayerApproaching);
  const npcSwing = getSwingState(state.npcSwingTimer, isNpcApproaching);

  function getRacketWorldPos(isPlayer, offsetX, y, swingState, sideReach) {
    const racketAngle = Math.PI / 2 + 1.0 + swingState.angle;
    // Racket ellipse center is drawn at (0, -18) locally
    const racketHeadLocalX = 18 * Math.sin(racketAngle);
    const racketHeadLocalY = -18 * Math.cos(racketAngle);
    
    const totalLocalX = swingState.reach + racketHeadLocalX;
    const totalLocalY = sideReach + racketHeadLocalY;
    
    if (isPlayer) {
      // Player is rotated 270deg (facing up)
      return {
        x: offsetX + totalLocalY * camera.zoom,
        y: y - totalLocalX * camera.zoom
      };
    } else {
      // NPC is rotated 90deg (facing down)
      return {
        x: offsetX - totalLocalY * camera.zoom,
        y: y + totalLocalX * camera.zoom
      };
    }
  }

  const playerSideReach = 14 + (isPlayerApproaching || state.playerSwingTimer > 0 ? clamp(state.ballOffsetX - state.playerOffsetX, -12, 12) : 0);
  const playerRacketPos = getRacketWorldPos(true, state.playerOffsetX, playerY, playerSwing, playerSideReach);

  const npcSideReach = 14 + (isNpcApproaching || state.npcSwingTimer > 0 ? clamp(-(state.ballOffsetX - state.npcOffsetX), -12, 12) : 0);
  const npcRacketPos = getRacketWorldPos(false, state.npcOffsetX, npcY, npcSwing, npcSideReach);

  const racketHitHalfWidth = 15 * camera.zoom; // Exact collision radius of the racket head
  const racketHitDepth = 10 * camera.zoom;

  // Trigger player swing
  if (state.ballVY > 0 && state.playerSwingTimer === 0) {
    if (playerRacketPos.y - state.ballY < 25 * camera.zoom && playerRacketPos.y - state.ballY > -10 * camera.zoom && Math.abs(state.ballOffsetX - playerRacketPos.x) < racketHitHalfWidth + 30 * camera.zoom) {
      state.playerSwingTimer = SWING_DURATION;
    }
  }

  // Trigger NPC swing
  if (state.ballVY < 0 && state.npcSwingTimer === 0) {
    if (state.ballY - npcRacketPos.y < 25 * camera.zoom && state.ballY - npcRacketPos.y > -10 * camera.zoom && Math.abs(state.ballOffsetX - npcRacketPos.x) < racketHitHalfWidth + 30 * camera.zoom) {
      state.npcSwingTimer = SWING_DURATION;
    }
  }

  // --- Player Movement ---
  let playerMoved = false;
  if (inputManager.isPressed('ArrowUp') || inputManager.isPressed('KeyW')) {
    state.playerOffsetY -= PADDLE_SPEED * dt;
    playerMoved = true;
  }
  if (inputManager.isPressed('ArrowDown') || inputManager.isPressed('KeyS')) {
    state.playerOffsetY += PADDLE_SPEED * dt;
    playerMoved = true;
  }
  // Clamp player to vertical reach (-100 forward, 50 backward)
  state.playerOffsetY = Math.max(-100, Math.min(50, state.playerOffsetY));

  if (inputManager.isPressed('ArrowLeft') || inputManager.isPressed('KeyA')) {
    state.playerOffsetX -= PADDLE_SPEED * dt;
    playerMoved = true;
  }
  if (inputManager.isPressed('ArrowRight') || inputManager.isPressed('KeyD')) {
    state.playerOffsetX += PADDLE_SPEED * dt;
    playerMoved = true;
  }
  if (playerMoved) {
    state.playerLegTimer += PADDLE_SPEED * dt * 0.05;
  } else {
    state.playerLegTimer = 0;
  }
  // Clamp player to court width
  state.playerOffsetX = Math.max(-PLAYABLE_HALF_WIDTH + 50, Math.min(PLAYABLE_HALF_WIDTH - 50, state.playerOffsetX));

  // --- NPC Movement (Simple AI tracking the ball) ---
  let npcMoved = false;
  
  // Account for the distance between the NPC's center and its actual racket's sweet spot
  const racketOffsetToBody = npcRacketPos.x - state.npcOffsetX;
  
  // If the ball is moving towards the NPC, intercept it with the racket.
  // Otherwise, neatly return to the center of the baseline.
  const targetTrackingX = state.ballVY < 0 ? state.ballOffsetX - racketOffsetToBody : 0;

  if (state.npcOffsetX < targetTrackingX - 5) {
    state.npcOffsetX += NPC_SPEED * dt;
    npcMoved = true;
  } else if (state.npcOffsetX > targetTrackingX + 5) {
    state.npcOffsetX -= NPC_SPEED * dt;
    npcMoved = true;
  }
  if (npcMoved) {
    state.npcLegTimer += NPC_SPEED * dt * 0.05;
  } else {
    state.npcLegTimer = 0;
  }
  // Clamp NPC to court width
  state.npcOffsetX = Math.max(-PLAYABLE_HALF_WIDTH + 50, Math.min(PLAYABLE_HALF_WIDTH - 50, state.npcOffsetX));

  // --- Ball Physics ---
  const gravity = 800;
  const vZ = state.ballCurrentVelocity * Math.tan(state.ballCurrentPitchAngle);
  
  state.ballCurrentHeight += vZ * dt;
  state.ballCurrentPitchAngle = Math.atan2(vZ - gravity * dt, state.ballCurrentVelocity);

  if (state.ballCurrentHeight < 0) {
    state.ballCurrentHeight = 0;
    // Visually bounce the ball upon striking the floor court
    state.ballCurrentPitchAngle = Math.atan2(Math.abs(vZ - gravity * dt) * 0.6, state.ballCurrentVelocity);
  }

  state.ballOffsetX += state.ballVX * dt;
  state.ballY += state.ballVY * dt;

  // Racket Collisions (Player - Bottom)
  if (
    state.ballVY > 0 &&
    state.ballY + BALL_RADIUS >= playerRacketPos.y - racketHitDepth &&
    state.ballY - BALL_RADIUS <= playerRacketPos.y + racketHitDepth &&
    state.ballOffsetX >= playerRacketPos.x - racketHitHalfWidth &&
    state.ballOffsetX <= playerRacketPos.x + racketHitHalfWidth
  ) {
    // Player returns to the NPC side (top half of inner bounds)
    let targetX = COURT_INNER_BOUNDS.x + Math.random() * COURT_INNER_BOUNDS.width;
    let targetY = COURT_INNER_BOUNDS.y + Math.random() * (COURT_INNER_BOUNDS.height / 2);

    const hitOffset = state.ballOffsetX - playerRacketPos.x;
    targetX += hitOffset * 1.5;

    const dx = targetX - state.ballOffsetX;
    const dy = targetY - state.ballY;
    const dist = Math.sqrt(dx * dx + dy * dy);

    state.ballCurrentVelocity = BALL_SPEED * 0.9;
    state.ballCurrentHeight = Math.max(10, state.ballCurrentHeight);
    
    const timeToTarget = dist / state.ballCurrentVelocity;
    const vZTarget = (0.5 * gravity * timeToTarget * timeToTarget - state.ballCurrentHeight) / timeToTarget;
    state.ballCurrentPitchAngle = Math.atan2(vZTarget, state.ballCurrentVelocity);

    state.ballVX = (dx / dist) * state.ballCurrentVelocity;
    state.ballVY = (dy / dist) * state.ballCurrentVelocity;
  }

  // Racket Collisions (NPC - Top)
  if (
    state.ballVY < 0 &&
    state.ballY - BALL_RADIUS <= npcRacketPos.y + racketHitDepth &&
    state.ballY + BALL_RADIUS >= npcRacketPos.y - racketHitDepth &&
    state.ballOffsetX >= npcRacketPos.x - racketHitHalfWidth &&
    state.ballOffsetX <= npcRacketPos.x + racketHitHalfWidth
  ) {
    // NPC returns to the Player side (bottom half of inner bounds)
    const targetX = COURT_INNER_BOUNDS.x + Math.random() * COURT_INNER_BOUNDS.width;
    const targetY = COURT_INNER_BOUNDS.y + (COURT_INNER_BOUNDS.height / 2) + Math.random() * (COURT_INNER_BOUNDS.height / 2);

    const dx = targetX - state.ballOffsetX;
    const dy = targetY - state.ballY;
    const dist = Math.sqrt(dx * dx + dy * dy);

    state.ballCurrentVelocity = BALL_SPEED * 0.9;
    state.ballCurrentHeight = Math.max(10, state.ballCurrentHeight);

    const timeToTarget = dist / state.ballCurrentVelocity;
    const vZTarget = (0.5 * gravity * timeToTarget * timeToTarget - state.ballCurrentHeight) / timeToTarget;
    state.ballCurrentPitchAngle = Math.atan2(vZTarget, state.ballCurrentVelocity);

    state.ballVX = (dx / dist) * state.ballCurrentVelocity;
    state.ballVY = (dy / dist) * state.ballCurrentVelocity;
  }

  // Scoring/Reset (Top/Bottom Walls)
  if (state.ballY < 0) {
    // Player scored, NPC serves to restart
    serveBall(false);
  } else if (state.ballY > GAME_HEIGHT) {
    // NPC scored, Player serves to restart
    serveBall(true);
  }
}

function draw() {
  if (!minigameActive) return;

  const playerY = getPlayerY();
  const dpr = window.devicePixelRatio || 1;
  const viewportWidth = window.innerWidth;
  const viewportHeight = window.visualViewport ? window.visualViewport.height : window.innerHeight;

  // Base background fill
  ctx.fillStyle = '#7bed9f';
  ctx.fillRect(0, 0, canvas.width, canvas.height);

  ctx.save();

  if (!bgImage.complete || bgImage.height === 0) {
    ctx.restore();
    return;
  }

  // The image should be rendered to the maxmium height of the user's viewport
  const renderHeight = viewportHeight * dpr;
  const imageAspect = bgImage.width / bgImage.height;
  const renderWidth = renderHeight * imageAspect;

  // Center horizontally
  const offsetX = (viewportWidth * dpr - renderWidth) / 2;
  const offsetY = 0;

  // Draw Map Background
  ctx.drawImage(bgImage, offsetX, offsetY, renderWidth, renderHeight);

  // Translate to the top-left of the drawn image
  ctx.translate(offsetX, offsetY);

  // Scale context from the logical 800 game height to the rendered height
  const scale = renderHeight / GAME_HEIGHT;
  ctx.scale(scale, scale);

  const gameWidth = GAME_HEIGHT * imageAspect;
  const centerX = gameWidth / 2;

  function getLimbs(legTimer, reach, sideReach) {
    const legSwing = Math.sin(legTimer || 0);
    const legStride = 9;
    const armStride = 8;
    return {
      leftArmX: 4 - legSwing * armStride, leftArmY: -14,
      rightArmX: reach, rightArmY: sideReach, // dynamic reach forward and sideway reach
      leftLegStartX: -2, leftLegStartY: -6, leftLegEndX: -2 + 6 + legSwing * legStride, leftLegEndY: -6,
      rightLegStartX: -2, rightLegStartY: 6, rightLegEndX: -2 + 6 - legSwing * legStride, rightLegEndY: 6
    };
  }

  const isPlayerApproaching = state.ballVY > 0 && Math.abs(state.ballOffsetX - state.playerOffsetX) < 150 && (playerY - state.ballY) > 0 && (playerY - state.ballY) < 150;
  const isNpcApproaching = state.ballVY < 0 && Math.abs(state.ballOffsetX - state.npcOffsetX) < 150 && (state.ballY - npcY) > 0 && (state.ballY - npcY) < 150;

  const npcSwing = getSwingState(state.npcSwingTimer, isNpcApproaching);
  const playerSwing = getSwingState(state.playerSwingTimer, isPlayerApproaching);

  // Dynamic side reach for racket
  const clamp = (val, min, max) => Math.min(Math.max(val, min), max);
  const playerSideReach = 14 + (isPlayerApproaching || state.playerSwingTimer > 0 ? clamp(state.ballOffsetX - state.playerOffsetX, -12, 12) : 0);
  const npcSideReach = 14 + (isNpcApproaching || state.npcSwingTimer > 0 ? clamp(-(state.ballOffsetX - state.npcOffsetX), -12, 12) : 0);

  // Draw NPC
  ctx.save();
  ctx.translate(centerX + state.npcOffsetX, npcY);
  ctx.scale(camera.zoom, camera.zoom);

  // Drop shadow
  ctx.fillStyle = 'rgba(0, 0, 0, 0.25)';
  ctx.beginPath();
  ctx.arc(2, 4, 14, 0, Math.PI * 2);
  ctx.fill();

  ctx.rotate(90 * (Math.PI / 180));
  const npcLimbs = getLimbs(state.npcLegTimer, npcSwing.reach, npcSideReach);
  drawRacket(ctx, npcLimbs, npcSwing.angle);
  characterManager.drawHumanoid(ctx, { ...npc, rotation: 90, x: 0, y: 0 }, npcLimbs);
  ctx.restore();

  // Draw Player
  ctx.save();
  ctx.translate(centerX + state.playerOffsetX, playerY);
  ctx.scale(camera.zoom, camera.zoom);

  // Drop shadow
  ctx.fillStyle = 'rgba(0, 0, 0, 0.25)';
  ctx.beginPath();
  ctx.arc(2, 4, 14, 0, Math.PI * 2);
  ctx.fill();

  ctx.rotate(270 * (Math.PI / 180));
  let player = window.init.myCharacter;
  const playerLimbs = getLimbs(state.playerLegTimer, playerSwing.reach, playerSideReach);
  player.rotation = 270;
  drawRacket(ctx, playerLimbs, playerSwing.angle);
  characterManager.drawHumanoid(ctx, player, playerLimbs);
  ctx.restore();

  // Draw Ball Shadow
  ctx.save();
  ctx.fillStyle = 'rgba(0, 0, 0, 0.25)';
  ctx.beginPath();
  const shadowRadius = Math.max(2, BALL_RADIUS * 2 - state.ballCurrentHeight * 0.05);
  ctx.arc(centerX + state.ballOffsetX, state.ballY, shadowRadius, 0, Math.PI * 2);
  ctx.fill();
  ctx.restore();

  // Draw Ball (Elevated along true Z-axis natively)
  ctx.save();
  ctx.font = `${BALL_RADIUS * 3}px sans-serif`;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.translate(centerX + state.ballOffsetX, state.ballY - state.ballCurrentHeight);
  ctx.rotate(state.ballOffsetX * 0.05);
  ctx.fillText('🎾', 0, 0);
  ctx.restore();

  // Admin debug hitboxes
  if (window.isAdmin) {
    function getHitboxPos(isPlayer, offsetX, y, swingState, sideReach) {
        const racketAngle = Math.PI / 2 + 1.0 + swingState.angle;
        const racketHeadLocalX = 18 * Math.sin(racketAngle);
        const racketHeadLocalY = -18 * Math.cos(racketAngle);
        const totalLocalX = swingState.reach + racketHeadLocalX;
        const totalLocalY = sideReach + racketHeadLocalY;
        if (isPlayer) {
            return { x: offsetX + totalLocalY * camera.zoom, y: y - totalLocalX * camera.zoom };
        } else {
            return { x: offsetX - totalLocalY * camera.zoom, y: y + totalLocalX * camera.zoom };
        }
    }
    const pHitbox = getHitboxPos(true, state.playerOffsetX, playerY, playerSwing, playerSideReach);
    const nHitbox = getHitboxPos(false, state.npcOffsetX, npcY, npcSwing, npcSideReach);

    const racketHitHalfWidth = 15 * camera.zoom;
    const racketHitDepth = 10 * camera.zoom;
    ctx.save();
    ctx.strokeStyle = 'rgba(255, 0, 0, 0.8)';
    ctx.lineWidth = 1;
    ctx.strokeRect(centerX + pHitbox.x - racketHitHalfWidth, pHitbox.y - racketHitDepth, racketHitHalfWidth * 2, racketHitDepth * 2);
    ctx.strokeRect(centerX + nHitbox.x - racketHitHalfWidth, nHitbox.y - racketHitDepth, racketHitHalfWidth * 2, racketHitDepth * 2);
    
    // Draw target X exactly where trajectory intercepts the Z-axis natively
    const gravity = 800;
    const vZTargetCheck = state.ballCurrentVelocity * Math.tan(state.ballCurrentPitchAngle);
    const det = vZTargetCheck * vZTargetCheck + 2 * gravity * state.ballCurrentHeight;
    let tLand = 0;
    if (det >= 0) {
        tLand = (vZTargetCheck + Math.sqrt(det)) / gravity;
    }
    const landX = centerX + state.ballOffsetX + state.ballVX * tLand;
    const landY = state.ballY + state.ballVY * tLand;

    ctx.beginPath();
    ctx.moveTo(landX - 5, landY - 5);
    ctx.lineTo(landX + 5, landY + 5);
    ctx.moveTo(landX + 5, landY - 5);
    ctx.lineTo(landX - 5, landY + 5);
    ctx.stroke();

    ctx.restore();
  }

  ctx.restore();
}
