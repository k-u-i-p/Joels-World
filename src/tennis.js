/**
 * Joels World - Tennis Minigame
 * 
 * Handles the logic, physics, and rendering for the top-down 3D tennis minigame.
 * Features realistic 3D parabolic ball trajectories, elliptical racket collisions,
 * and AI opponent tracking.
 */

import { gameLoop } from './gameloop.js';
import { inputManager } from './input.js';
import { characterManager } from './characters.js';
import { player, camera } from './main.js';

// ==========================================
// CONSTANTS & CONFIGURATION
// ==========================================
const canvas = document.getElementById('gameCanvas');
const ctx = canvas.getContext('2d');

const GAME_HEIGHT = 800;
const PLAYABLE_HALF_WIDTH = 225; // Defines the lateral boundaries for characters
const PADDLE_SPEED = 250;        // Player movement speed
const NPC_SPEED = 200;           // NPC movement speed
const BALL_SPEED = 300;          // Base horizontal ball speed
const BALL_RADIUS = 3;           // Collision and drawing radius of the ball
const GRAVITY = 800;             // Gravity affecting the ball Z-axis (pixels/s^2)
const SWING_DURATION = 0.25;     // Duration of a racket swing in seconds

const COURT_INNER_BOUNDS = { x: -78, y: 264, width: 100, height: 272 };

// Character specific positioning
const PLAYER_BASE_Y = GAME_HEIGHT - 170;
const NPC_BASE_Y = 170;

// ==========================================
// GAME STATE
// ==========================================
let minigameActive = false;
let npc = null;
let bgImage = new Image();
bgImage.src = '/minigames/tennis/map.png';

/** 
 * Central state object tracking real-time mutable variables for physics, 
 * positions, and animation timings.
 */
let state = {
  // Ball planar (2D) coordinates
  ballOffsetX: 0,
  ballY: GAME_HEIGHT / 2,
  ballVX: BALL_SPEED * 0.7,
  ballVY: BALL_SPEED * 0.7,
  
  // Ball spatial (Z-axis) physics
  ballCurrentVelocity: BALL_SPEED * 0.7,
  ballCurrentPitchAngle: 0,
  ballCurrentHeight: 0,
  
  // Character active offsets
  playerOffsetX: 0,
  playerOffsetY: 0,
  npcOffsetX: 0,
  
  // Animation timers
  playerSwingTimer: 0,
  npcSwingTimer: 0,
  playerLegTimer: 0,
  npcLegTimer: 0,
  
  // Volley locks (prevents rapid-fire swinging)
  playerHasSwung: false,
  npcHasSwung: false,
};

// ==========================================
// UTILITIES & PURE FUNCTIONS
// ==========================================

/** Calculates player Y position including their vertical movement offset. */
function getPlayerY() {
  return PLAYER_BASE_Y + state.playerOffsetY;
}

/** Standard numeric clamp function. */
const clamp = (val, min, max) => Math.min(Math.max(val, min), max);

/**
 * Calculates the exact procedural angle and reach of the character's arm during a stroke.
 * @param {number} timer - Current countdown of the swing timer.
 * @param {boolean} isApproaching - Whether the ball is incoming within range.
 * @returns {{angle: number, reach: number}}
 */
function getSwingState(timer, isApproaching) {
  if (timer > 0) {
    // Actively swinging
    const progress = 1 - (timer / SWING_DURATION); // 0.0 to 1.0
    // Transition from completely cocked back (1.0) into a fast forward stroke crossing the body
    const angle = 1.0 - progress * 2.2;
    // Push the racket dynamically forward during the arc
    const reach = 4 + Math.sin(progress * Math.PI) * 10;
    return { angle, reach };
  } else if (isApproaching) {
    // Prepare for incoming ball (cock racket backwards)
    return { angle: 1.0, reach: 4 };
  } else {
    // Idle state
    return { angle: 0, reach: 4 };
  }
}

/**
 * Mathematically determines the exact world coordinates of the tennis racket head,
 * taking into account local hand position, arm reach, swing rotation, and camera zoom.
 * 
 * @param {boolean} isPlayer - Whether calculating for the player or the NPC.
 * @param {number} offsetX - Current X offset of the character.
 * @param {number} y - Current Y position of the character.
 * @param {object} swingState - Current {angle, reach} from getSwingState().
 * @param {number} sideReach - Current lateral extension of the arm.
 * @returns {{x: number, y: number}} The precise structural center of the racket strings.
 */
function getRacketWorldPos(isPlayer, offsetX, y, swingState, sideReach) {
  // Baseline graphic rotation (Math.PI / 2) + idle rotation (1.0) + dynamic swing angle
  const racketAngle = Math.PI / 2 + 1.0 + swingState.angle;
  
  // Calculate relative structural center of the racket head strings 
  // (the drawRacket graphic renders the ellipse centered at 0, -18 locally)
  const racketHeadLocalX = 18 * Math.sin(racketAngle);
  const racketHeadLocalY = -18 * Math.cos(racketAngle);
  
  const totalLocalX = swingState.reach + racketHeadLocalX;
  const totalLocalY = sideReach + racketHeadLocalY;
  
  if (isPlayer) {
    // Player faces North (visually rotated 270 degrees in canvas space)
    return {
      x: offsetX + totalLocalY * camera.zoom,
      y: y - totalLocalX * camera.zoom
    };
  } else {
    // NPC faces South (visually rotated 90 degrees in canvas space)
    return {
      x: offsetX - totalLocalY * camera.zoom,
      y: y + totalLocalX * camera.zoom
    };
  }
}

/**
 * Mathematically derives the required trajectory angles and speeds to land 
 * the ball precisely at the given target coordinate, and sets the game state.
 * 
 * @param {number} targetX - Destination X coordinate.
 * @param {number} targetY - Destination Y coordinate.
 * @param {number} velocity - The driving physical 3D velocity of the ball.
 */
function hitBallToTarget(targetX, targetY, velocity) {
  state.ballCurrentVelocity = velocity;

  const dx = targetX - state.ballOffsetX;
  const dy = targetY - state.ballY;
  const dist = Math.sqrt(dx * dx + dy * dy);

  // Parabolic Physics calculation establishing the necessary starting vertical Z velocity (vZ)
  const timeToTarget = dist / state.ballCurrentVelocity;
  const vZ = (0.5 * GRAVITY * timeToTarget * timeToTarget - state.ballCurrentHeight) / timeToTarget;
  
  // Derive new spatial pitch vector
  state.ballCurrentPitchAngle = Math.atan2(vZ, state.ballCurrentVelocity);

  // Set normalized 2D movement planar slice
  state.ballVX = (dx / dist) * state.ballCurrentVelocity;
  state.ballVY = (dy / dist) * state.ballCurrentVelocity;
}

// ==========================================
// CORE GAME LOGIC
// ==========================================

/**
 * Initializes and starts the Tennis Minigame.
 * Called externally when launching into the map.
 */
export function initMinigame() {
  console.log('[Tennis] Initializing Minigame...');
  minigameActive = true;

  if (window.init && window.init.npcs && window.init.npcs.length > 0) {
    npc = window.init.npcs[0];
  } else {
    npc = { id: 999, name: 'Opponent', width: 40, height: 40, gender: 'male', shirtColor: '#e74c3c' };
  }

  // Reset core tracking values
  state.playerOffsetX = 0;
  state.playerOffsetY = 0;
  state.npcOffsetX = 0;
  state.playerSwingTimer = 0;
  state.npcSwingTimer = 0;
  state.playerLegTimer = 0;
  state.npcLegTimer = 0;

  serveBall(false); // NPC serves first

  // Setup overhead perspective
  camera.x = 0;
  camera.y = GAME_HEIGHT / 2;
  camera.zoom = 1.8;

  gameLoop.registerFunction(update);
  gameLoop.registerFunction(draw);
}

/**
 * Mechanically serves the ball from the respective character towards a valid court zone.
 * Automatically computes 3D pitch/velocity required to lob into the target destination.
 * 
 * @param {boolean} playerServing - True if player serves, false if NPC serves.
 */
function serveBall(playerServing) {
  const playerY = getPlayerY();
  
  state.ballOffsetX = playerServing ? state.playerOffsetX : state.npcOffsetX;
  state.ballY = playerServing ? playerY : NPC_BASE_Y;

  const targetX = COURT_INNER_BOUNDS.x + Math.random() * COURT_INNER_BOUNDS.width;
  let targetY;
  
  // Decide strict serving zones
  if (playerServing) {
    targetY = COURT_INNER_BOUNDS.y + Math.random() * (COURT_INNER_BOUNDS.height / 2);
  } else {
    // NPC serves restrictively into the front-third so the arc is flatter
    targetY = COURT_INNER_BOUNDS.y + (COURT_INNER_BOUNDS.height / 2) + Math.random() * (COURT_INNER_BOUNDS.height / 3);
  }

  state.ballCurrentHeight = 40; // Characters throw the ball to waist height for serve
  let serveVelocity = playerServing ? BALL_SPEED * 0.7 : BALL_SPEED * 0.65;
  hitBallToTarget(targetX, targetY, serveVelocity);

  // Renew locks allowing exactly one swing per volley
  state.playerHasSwung = false;
  state.npcHasSwung = false;

  // Force character to animate hitting the serve
  if (playerServing) {
    state.playerSwingTimer = SWING_DURATION;
    state.playerHasSwung = true;
  } else {
    state.npcSwingTimer = SWING_DURATION;
    state.npcHasSwung = true;
  }
}

/**
 * Core logical tick, executing Player Input, AI calculations, 3D Physics logic, and collision.
 * 
 * @param {number} dt - Delta time in seconds since last frame.
 */
function update(dt) {
  if (!minigameActive) return;

  const playerY = getPlayerY();

  // 1. Process Swing Timers
  if (state.playerSwingTimer > 0) {
    state.playerSwingTimer = Math.max(0, state.playerSwingTimer - dt);
  }
  if (state.npcSwingTimer > 0) {
    state.npcSwingTimer = Math.max(0, state.npcSwingTimer - dt);
  }

  // Define approach proximities for pre-cocking animations
  const isPlayerApproaching = state.ballVY > 0 && Math.abs(state.ballOffsetX - state.playerOffsetX) < 150 && (playerY - state.ballY) > 0 && (playerY - state.ballY) < 150;
  const isNpcApproaching = state.ballVY < 0 && Math.abs(state.ballOffsetX - state.npcOffsetX) < 150 && (state.ballY - NPC_BASE_Y) > 0 && (state.ballY - NPC_BASE_Y) < 150;

  const playerSwing = getSwingState(state.playerSwingTimer, isPlayerApproaching);
  const npcSwing = getSwingState(state.npcSwingTimer, isNpcApproaching);

  // Character arms dynamically stretch slightly if ball is just outside character center
  const playerSideReach = 14 + (isPlayerApproaching || state.playerSwingTimer > 0 ? clamp(state.ballOffsetX - state.playerOffsetX, -12, 12) : 0);
  const npcSideReach = 14 + (isNpcApproaching || state.npcSwingTimer > 0 ? clamp(-(state.ballOffsetX - state.npcOffsetX), -12, 12) : 0);

  // Absolute world coordinates of both racket hitboxes
  const playerRacketPos = getRacketWorldPos(true, state.playerOffsetX, playerY, playerSwing, playerSideReach);
  const npcRacketPos = getRacketWorldPos(false, state.npcOffsetX, NPC_BASE_Y, npcSwing, npcSideReach);

  // Define elliptical mathematical geometry of hitboxes exactly matching visual size
  const racketHitHalfWidth = 15 * camera.zoom; 
  const racketHitDepth = 10 * camera.zoom;

  // The actual collision checks test against visually elevated (Z-adjusted) Y coord 
  const visualBallY = state.ballY - state.ballCurrentHeight;
  
  // Calculate specific collision boundaries
  const triggerW = racketHitHalfWidth + 30 * camera.zoom;
  const triggerH = 25 * camera.zoom;

  // 2. Automated Swing Triggers
  // Swing initiates only if the racket will successfully intersect the ball's trajectory
  if (state.ballVY > 0 && state.playerSwingTimer === 0 && !state.playerHasSwung) {
    if (Math.pow(state.ballOffsetX - playerRacketPos.x, 2) / Math.pow(triggerW, 2) + Math.pow(visualBallY - playerRacketPos.y, 2) / Math.pow(triggerH, 2) <= 1) {
      state.playerSwingTimer = SWING_DURATION;
      state.playerHasSwung = true;
    }
  }

  if (state.ballVY < 0 && state.npcSwingTimer === 0 && !state.npcHasSwung) {
    if (Math.pow(state.ballOffsetX - npcRacketPos.x, 2) / Math.pow(triggerW, 2) + Math.pow(visualBallY - npcRacketPos.y, 2) / Math.pow(triggerH, 2) <= 1) {
      state.npcSwingTimer = SWING_DURATION;
      state.npcHasSwung = true;
    }
  }

  // 3. Process Player Inputs & Movement
  let playerMoved = false;
  if (inputManager.isPressed('ArrowUp') || inputManager.isPressed('KeyW')) {
    state.playerOffsetY -= PADDLE_SPEED * dt;
    playerMoved = true;
  }
  if (inputManager.isPressed('ArrowDown') || inputManager.isPressed('KeyS')) {
    state.playerOffsetY += PADDLE_SPEED * dt;
    playerMoved = true;
  }
  // Vertical bounds (-100 forward into court, 50 backward behind baseline)
  state.playerOffsetY = clamp(state.playerOffsetY, -100, 50);

  if (inputManager.isPressed('ArrowLeft') || inputManager.isPressed('KeyA')) {
    state.playerOffsetX -= PADDLE_SPEED * dt;
    playerMoved = true;
  }
  if (inputManager.isPressed('ArrowRight') || inputManager.isPressed('KeyD')) {
    state.playerOffsetX += PADDLE_SPEED * dt;
    playerMoved = true;
  }
  
  // Update local animation timers specifically decoupled from generic engine
  if (playerMoved) {
    state.playerLegTimer += PADDLE_SPEED * dt * 0.05;
  } else {
    state.playerLegTimer = 0;
  }
  state.playerOffsetX = clamp(state.playerOffsetX, -PLAYABLE_HALF_WIDTH + 50, PLAYABLE_HALF_WIDTH - 50);

  // 4. Process Simple AI NPC Movement
  let npcMoved = false;
  // Intelligently calculate what lateral position the AI needs to stand at 
  // so their actual racket sweet-spot intercepts the ball, tracking offset.
  const racketOffsetToBody = npcRacketPos.x - state.npcOffsetX;
  
  // Follow ball if approaching, otherwise smoothly reset back to baseline center
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
  state.npcOffsetX = clamp(state.npcOffsetX, -PLAYABLE_HALF_WIDTH + 50, PLAYABLE_HALF_WIDTH - 50);

  // 5. 3D Spatial Ball Physics Processing
  const vZ = state.ballCurrentVelocity * Math.tan(state.ballCurrentPitchAngle);
  
  // Elevate ball
  state.ballCurrentHeight += vZ * dt;
  // Rotate velocity downward due to continuous gravity
  state.ballCurrentPitchAngle = Math.atan2(vZ - GRAVITY * dt, state.ballCurrentVelocity);

  // Handle floor bounce
  if (state.ballCurrentHeight < 0) {
    state.ballCurrentHeight = 0;
    // Reflect vertical kinetic energy mathematically and absorb 40% (0.6 multiplier) into the court
    state.ballCurrentPitchAngle = Math.atan2(Math.abs(vZ - GRAVITY * dt) * 0.6, state.ballCurrentVelocity);
  }

  // Handle Planar XY movement
  state.ballOffsetX += state.ballVX * dt;
  state.ballY += state.ballVY * dt;

  // 6. Racket Deflections
  
  // Process Player Racket Geometry Interception
  if (
    state.ballVY > 0 &&
    // Strict Elliptical Intersection Boolean Matrix Check over standard Box Radius Check
    (Math.pow(state.ballOffsetX - playerRacketPos.x, 2) / Math.pow(racketHitHalfWidth + BALL_RADIUS, 2)) +
    (Math.pow(visualBallY - playerRacketPos.y, 2) / Math.pow(racketHitDepth + BALL_RADIUS, 2)) <= 1
  ) {
    let targetX = COURT_INNER_BOUNDS.x + Math.random() * COURT_INNER_BOUNDS.width;
    let targetY = COURT_INNER_BOUNDS.y + Math.random() * (COURT_INNER_BOUNDS.height / 2);

    // Apply slight directional spin off center hits
    const hitOffset = state.ballOffsetX - playerRacketPos.x;
    targetX += hitOffset * 1.5;

    hitBallToTarget(targetX, targetY, BALL_SPEED * 0.9);

    state.ballCurrentHeight = Math.max(10, state.ballCurrentHeight); // Simulate ground strike lift 
    
    // Un-flag the opponent permitting them to strike the returned volley
    state.npcHasSwung = false;
  }

  // Process NPC Racket Geometry Interception
  if (
    state.ballVY < 0 &&
    (Math.pow(state.ballOffsetX - npcRacketPos.x, 2) / Math.pow(racketHitHalfWidth + BALL_RADIUS, 2)) +
    (Math.pow(visualBallY - npcRacketPos.y, 2) / Math.pow(racketHitDepth + BALL_RADIUS, 2)) <= 1
  ) {
    const targetX = COURT_INNER_BOUNDS.x + Math.random() * COURT_INNER_BOUNDS.width;
    const targetY = COURT_INNER_BOUNDS.y + (COURT_INNER_BOUNDS.height / 2) + Math.random() * (COURT_INNER_BOUNDS.height / 2);

    hitBallToTarget(targetX, targetY, BALL_SPEED * 0.9);

    state.ballCurrentHeight = Math.max(10, state.ballCurrentHeight);

    state.playerHasSwung = false;
  }

  // 7. Bounds Checking / Out Checks
  // Point resolving (scoring logic) currently automatically re-serves the ball
  if (state.ballY < 0) {
    serveBall(false); // Player scored
  } else if (state.ballY > GAME_HEIGHT) {
    serveBall(true);  // NPC scored
  }
}

// ==========================================
// RENDERING
// ==========================================

/**
 * Procedurally draws a tennis racket starting from the wrist location.
 * @param {CanvasRenderingContext2D} ctx - Canvas context.
 * @param {Object} limbs - Current Limb positions. 
 * @param {number} swingAngle - Rotational swing adjustment.
 */
function drawRacket(ctx, limbs, swingAngle = 0) {
  ctx.save();
  ctx.translate(limbs.rightArmX, limbs.rightArmY); 

  ctx.rotate(Math.PI / 2 + 1.0 + swingAngle);

  // Draw handle
  ctx.fillStyle = '#2c3e50';
  ctx.fillRect(-2, -10, 4, 15);

  // Draw structural frame
  ctx.strokeStyle = '#e74c3c';
  ctx.lineWidth = 2;
  ctx.beginPath();
  if (ctx.ellipse) {
    ctx.ellipse(0, -18, 8, 12, 0, 0, Math.PI * 2);
  } else {
    ctx.arc(0, -18, 10, 0, Math.PI * 2);
  }
  ctx.stroke();

  // Draw strings
  ctx.strokeStyle = 'rgba(236, 240, 241, 0.5)';
  ctx.lineWidth = 0.5;
  ctx.beginPath();
  for (let i = -5; i <= 5; i += 3) {
    ctx.moveTo(i, -28);
    ctx.lineTo(i, -8);
  }
  for (let i = -26; i <= -10; i += 3) {
    ctx.moveTo(-6, i);
    ctx.lineTo(6, i);
  }
  ctx.stroke();

  ctx.restore();
}

/**
 * Calculates generic structural offsets for limbs based on leg animation and arm reach.
 */
function getLimbs(legTimer, reach, sideReach) {
  const legSwing = Math.sin(legTimer || 0);
  const legStride = 9;
  const armStride = 8;
  return {
    leftArmX: 4 - legSwing * armStride, leftArmY: -14,
    rightArmX: reach, rightArmY: sideReach,
    leftLegStartX: -2, leftLegStartY: -6, leftLegEndX: -2 + 6 + legSwing * legStride, leftLegEndY: -6,
    rightLegStartX: -2, rightLegStartY: 6, rightLegEndX: -2 + 6 - legSwing * legStride, rightLegEndY: 6
  };
}

/**
 * Handles all visual translation and rasterization per-frame.
 */
function draw() {
  if (!minigameActive) return;

  const playerY = getPlayerY();
  const dpr = window.devicePixelRatio || 1;
  const viewportWidth = window.innerWidth;
  const viewportHeight = window.visualViewport ? window.visualViewport.height : window.innerHeight;

  // Render out-of-bounds grass
  ctx.fillStyle = '#7bed9f';
  ctx.fillRect(0, 0, canvas.width, canvas.height);

  ctx.save();

  if (!bgImage.complete || bgImage.height === 0) {
    ctx.restore();
    return;
  }

  // Responsively scale to viewport real-estate seamlessly covering edges
  const renderHeight = viewportHeight * dpr;
  const imageAspect = bgImage.width / bgImage.height;
  const renderWidth = renderHeight * imageAspect;

  const offsetX = (viewportWidth * dpr - renderWidth) / 2;
  const offsetY = 0;

  ctx.drawImage(bgImage, offsetX, offsetY, renderWidth, renderHeight);
  ctx.translate(offsetX, offsetY);

  const scale = renderHeight / GAME_HEIGHT;
  ctx.scale(scale, scale);

  const gameWidth = GAME_HEIGHT * imageAspect;
  const centerX = gameWidth / 2;

  // Process logic parameters exactly as update tick evaluates them
  const isPlayerApproaching = state.ballVY > 0 && Math.abs(state.ballOffsetX - state.playerOffsetX) < 150 && (playerY - state.ballY) > 0 && (playerY - state.ballY) < 150;
  const isNpcApproaching = state.ballVY < 0 && Math.abs(state.ballOffsetX - state.npcOffsetX) < 150 && (state.ballY - NPC_BASE_Y) > 0 && (state.ballY - NPC_BASE_Y) < 150;

  const npcSwing = getSwingState(state.npcSwingTimer, isNpcApproaching);
  const playerSwing = getSwingState(state.playerSwingTimer, isPlayerApproaching);

  const playerSideReach = 14 + (isPlayerApproaching || state.playerSwingTimer > 0 ? clamp(state.ballOffsetX - state.playerOffsetX, -12, 12) : 0);
  const npcSideReach = 14 + (isNpcApproaching || state.npcSwingTimer > 0 ? clamp(-(state.ballOffsetX - state.npcOffsetX), -12, 12) : 0);

  // 1. Render NPC
  ctx.save();
  ctx.translate(centerX + state.npcOffsetX, NPC_BASE_Y);
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

  // 2. Render Player
  ctx.save();
  ctx.translate(centerX + state.playerOffsetX, playerY);
  ctx.scale(camera.zoom, camera.zoom);

  // Drop shadow
  ctx.fillStyle = 'rgba(0, 0, 0, 0.25)';
  ctx.beginPath();
  ctx.arc(2, 4, 14, 0, Math.PI * 2);
  ctx.fill();

  ctx.rotate(270 * (Math.PI / 180));
  let playerCharacter = window.init.myCharacter;
  const playerLimbs = getLimbs(state.playerLegTimer, playerSwing.reach, playerSideReach);
  playerCharacter.rotation = 270;
  drawRacket(ctx, playerLimbs, playerSwing.angle);
  characterManager.drawHumanoid(ctx, playerCharacter, playerLimbs);
  ctx.restore();

  // 3. Render Ball Physics Elements
  
  // Ball's vertical Ground Shadow
  ctx.save();
  ctx.fillStyle = 'rgba(0, 0, 0, 0.25)';
  ctx.beginPath();
  // Shrink shadow exponentially based on elevation altitude
  const shadowRadius = Math.max(2, BALL_RADIUS * 2 - state.ballCurrentHeight * 0.05);
  ctx.arc(centerX + state.ballOffsetX, state.ballY, shadowRadius, 0, Math.PI * 2);
  ctx.fill();
  ctx.restore();

  // Physical Ball Emoji
  ctx.save();
  ctx.font = `${BALL_RADIUS * 3}px sans-serif`;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  // Translate ball spatially along actual true Z-axis
  ctx.translate(centerX + state.ballOffsetX, state.ballY - state.ballCurrentHeight);
  ctx.rotate(state.ballOffsetX * 0.05); // Cosmetic spin based on horizontal slice 
  ctx.fillText('🎾', 0, 0);
  ctx.restore();

  // 4. Admin Hitbox Diagnostic Visualization Overlay
  if (window.isAdmin) {
    const pHitbox = getRacketWorldPos(true, state.playerOffsetX, playerY, playerSwing, playerSideReach);
    const nHitbox = getRacketWorldPos(false, state.npcOffsetX, NPC_BASE_Y, npcSwing, npcSideReach);

    const racketHitHalfWidth = 15 * camera.zoom;
    const racketHitDepth = 10 * camera.zoom;
    
    ctx.save();
    ctx.strokeStyle = 'rgba(255, 0, 0, 0.8)';
    ctx.lineWidth = 1;
    
    // Draw Elliptical Target Hitbox representations exactly identical to logic
    ctx.beginPath();
    ctx.ellipse(centerX + pHitbox.x, pHitbox.y, racketHitHalfWidth, racketHitDepth, 0, 0, Math.PI * 2);
    ctx.stroke();

    ctx.beginPath();
    ctx.ellipse(centerX + nHitbox.x, nHitbox.y, racketHitHalfWidth, racketHitDepth, 0, 0, Math.PI * 2);
    ctx.stroke();
    
    // Calculate and render crosshairs onto the destination surface exactly where ball's geometry will collide
    const vZTargetCheck = state.ballCurrentVelocity * Math.tan(state.ballCurrentPitchAngle);
    const det = vZTargetCheck * vZTargetCheck + 2 * GRAVITY * state.ballCurrentHeight;
    let tLand = 0;
    if (det >= 0) {
        tLand = (vZTargetCheck + Math.sqrt(det)) / GRAVITY;
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
