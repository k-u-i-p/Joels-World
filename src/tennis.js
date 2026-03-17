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
import { soundManager } from './sound.js';

// ==========================================
// CONSTANTS & CONFIGURATION
// ==========================================
const canvas = document.getElementById('gameCanvas');
const ctx = canvas.getContext('2d');

const GAME_HEIGHT = 800;
const PADDLE_SPEED = 250;        // Player movement speed
const NPC_SPEED = 200;           // NPC movement speed
const BALL_SPEED = 220;          // Base horizontal ball speed
const MAXIMUM_BALL_SPEED = 300;  // Absolute engine speed ceiling for rallying
const BALL_RADIUS = 3;           // Collision and drawing radius of the ball
const GRAVITY = 800;             // Gravity affecting the ball Z-axis (pixels/s^2)
const SWING_DURATION = 0.25;     // Duration of a racket swing in seconds
const NET_HEIGHT = 45;           // Minimum Z-altitude required to cross the court

const COURT_INNER_BOUNDS = { x: -125, y: 180, width: 255, height: 440 };
const PLAYABLE_HALF_WIDTH = (COURT_INNER_BOUNDS.width / 2) + 100; // Lateral character bounds naturally scale with the court

// Character specific positioning
const PLAYER_BASE_Y = COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height + 10;
const NPC_BASE_Y = COURT_INNER_BOUNDS.y - 10;

// ==========================================
// GAME STATE
// ==========================================
let minigameActive = false;
let npc = null;
let bgImage = new Image();
bgImage.src = '/minigames/tennis/map.svg';

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

  playerOffsetX: 0,
  playerOffsetY: 0,
  npcOffsetX: 0,
  npcOffsetY: 0,

  // Animation timers
  playerSwingTimer: 0,
  npcSwingTimer: 0,
  playerDirection: 1, // Default direction for player (e.g., facing right)
  npcDirection: 1,    // Default direction for NPC
  playerDirectionY: 1, // Default Y direction for player (e.g., facing down)
  npcDirectionY: 1,    // Default Y direction for NPC

  playerRotation: 270, // Initial player rotation (facing up)
  npcRotation: 90,     // Initial NPC rotation (facing down)

  playerLegTimer: 0,
  npcLegTimer: 0,

  // Volley locks (prevents rapid-fire swinging)
  playerHasSwung: false,
  npcHasSwung: false,
  bounceCount: 0,
  resetting: false,
  resetDelayTimer: 0,
  rallyCount: 0,
  introPhase: 'walkToNet',
  introTimer: 0,
  nextServerIsPlayer: false,
  playerScore: 0,
  npcScore: 0,
  lastHitter: null,
  faultFlag: false,
  playerRacketPos: { x: 0, y: 0, groundY: 0, z: 0, w: 1, h: 1, angle: 0 },
  npcRacketPos: { x: 0, y: 0, groundY: 0, z: 0, w: 1, h: 1, angle: 0 },
  playerAimYaw: 0,
  playerAimPitch: 0,
  npcAimYaw: 0,
  npcAimPitch: 0,
};

// ==========================================
// UTILITIES & PURE FUNCTIONS
// ==========================================

/** Calculates player Y position including their vertical movement offset. */
function getPlayerY() {
  return PLAYER_BASE_Y + state.playerOffsetY;
}

/** Calculates NPC Y position including their vertical movement offset. */
function getNpcY() {
  return NPC_BASE_Y + state.npcOffsetY;
}

/** Standard numeric clamp function. */
const clamp = (val, min, max) => Math.min(Math.max(val, min), max);

/**
 * Calculates the exact procedural angle and reach of the character's arm during a stroke, considering aim.
 * @param {number} timer - Current countdown of the swing timer.
 * @param {boolean} isApproaching - Whether the ball is incoming within range.
 * @returns {{pitch: number, yaw: number, roll: number}}
 */
function getSwingState(timer, isApproaching, aimYaw = 0, aimPitch = 0) {
  let yaw = 0;
  let pitch = 0;
  let roll = 0;

  if (timer > 0) {
    const progress = 1 - (timer / SWING_DURATION); // 0.0 to 1.0
    // Transition from completely cocked back (right) into a fast forward stroke crossing the body (left)
    const sweepStart = Math.PI * 0.4;
    const sweepEnd = -Math.PI * 0.6;
    let baseYaw = sweepStart + (sweepEnd - sweepStart) * progress;

    yaw = baseYaw + aimYaw;
    pitch = aimPitch;
    roll = Math.max(0.1, Math.abs(Math.cos(progress * Math.PI)));
  } else if (isApproaching) {
    yaw = Math.PI * 0.4 + aimYaw;
    pitch = aimPitch;
    roll = 0.8;
  } else {
    yaw = Math.PI * 0.2; // Idle slightly right
    pitch = 0.1;
    roll = 0.3;
  }

  return { pitch, yaw, roll };
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
function getRacketWorldPos(isPlayer) {
  // Return the statically cached hitbox matrix derived natively from the canvas renderer
  // This guarantees 100% parity between physics boundaries and painted pixels!
  return isPlayer ? state.playerRacketPos : state.npcRacketPos;
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
  state.ballCurrentVelocity = Math.min(velocity, MAXIMUM_BALL_SPEED);
  state.bounceCount = 0;

  const dx = targetX - state.ballOffsetX;
  const dy = targetY - state.ballY;
  const dist = Math.sqrt(dx * dx + dy * dy);

  // Parabolic Physics calculation establishing the necessary starting vertical Z velocity (vZ)
  let timeToTarget = dist / state.ballCurrentVelocity;

  // Cap the flight time to prevent extreme "moonball" lobs. 
  // If the target requires a longer flight, we forcefully drive the ball harder and flatter to reach it.
  const maxFlightTime = 1.3;
  if (timeToTarget > maxFlightTime) {
    timeToTarget = maxFlightTime;
    // Boost the 2D planar velocity to cover the distance in the compressed time frame
    state.ballCurrentVelocity = dist / timeToTarget;
  }

  let vZ = (0.5 * GRAVITY * timeToTarget * timeToTarget - state.ballCurrentHeight) / timeToTarget;

  // Ensure the ball arcs high enough to clear the physical net structure if the target crosses the net
  const netY = GAME_HEIGHT / 2;
  const crossesNet = (state.ballY < netY && targetY > netY) || (state.ballY > netY && targetY < netY);

  if (crossesNet) {
    // Rough estimation of how long it takes to reach the net
    const timeToNet = (Math.abs(netY - state.ballY) / Math.abs(dy)) * timeToTarget;
    // Calculate the minimum Z-velocity needed to be exactly above NET_HEIGHT when t = timeToNet
    const requiredClearanceHeight = NET_HEIGHT + BALL_RADIUS + 5; // adding 5px buffer
    const minVZ = (requiredClearanceHeight - state.ballCurrentHeight + 0.5 * GRAVITY * timeToNet * timeToNet) / timeToNet;

    // If the flat stroke calculations predict crashing into the net, boost the arc
    if (vZ < minVZ) {
      vZ = minVZ;
    }
  }

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
  state.serveSide = -1;
  const serveOffset = COURT_INNER_BOUNDS.width * 0.4;
  state.playerOffsetX = state.serveSide * -serveOffset;
  state.playerOffsetY = 0;
  state.npcOffsetX = state.serveSide * serveOffset;
  state.npcOffsetY = 0;
  state.npcSwingTimer = 0;
  state.playerLegTimer = 0;
  state.npcLegTimer = 0;
  state.resetDelayTimer = 0;
  state.playerElevateZ = 0;
  state.npcElevateZ = 0;
  state.npcTargetX = 0;
  state.npcTargetY = NPC_BASE_Y;
  state.resetting = false;

  // Start cinematic intro instead of immediately serving
  state.introPhase = 'walkToNet';
  state.introTimer = 0;
  // Place characters far back initially
  state.playerOffsetY = 30;
  state.npcOffsetY = -30;
  // Put the ball somewhere hidden temporarily
  state.ballCurrentHeight = -100;
  state.ballVX = 0;
  state.ballVY = 0;

  // Start background music
  soundManager.playBackground('/media/hushed_crowd.mp3', 0.5);

  // Setup overhead perspective
  camera.x = 0;
  camera.y = GAME_HEIGHT / 2;
  camera.zoom = 1.8;

  const scoreboard = document.getElementById('tennis-scoreboard');
  if (scoreboard) scoreboard.style.display = 'flex';
  updateScoreboardDOM();

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
  state.resetting = false;
  const playerY = getPlayerY();

  state.ballOffsetX = playerServing ? state.playerOffsetX : state.npcOffsetX;
  state.ballY = playerServing ? playerY : getNpcY();

  const targetX = COURT_INNER_BOUNDS.x + Math.random() * COURT_INNER_BOUNDS.width;
  let targetY;

  // Decide strict serving zones
  if (playerServing) {
    targetY = COURT_INNER_BOUNDS.y + Math.random() * (COURT_INNER_BOUNDS.height / 2);
  } else {
    // NPC serves restrictively into the front-third so the arc is flatter
    targetY = COURT_INNER_BOUNDS.y + (COURT_INNER_BOUNDS.height / 2) + Math.random() * (COURT_INNER_BOUNDS.height / 3);
  }

  state.lastHitter = playerServing ? 'player' : 'npc';
  state.ballCurrentHeight = 40; // Characters throw the ball to waist height for serve
  let serveVelocity = playerServing ? BALL_SPEED * 0.7 : BALL_SPEED * 0.65;
  hitBallToTarget(targetX, targetY, serveVelocity);

  // Add random variance to volume and pitch for organic audio
  let soundSrc = playerServing ? '/media/hit_tennis_ball.mp3' : '/media/hit_tennis_ball2.mp3';
  let sound = soundManager.playPooled(soundSrc, 0.7 + Math.random() * 0.5);
  sound.setRate(0.85 + Math.random() * 0.3);

  // Renew locks allowing exactly one swing per volley
  state.playerHasSwung = false;
  state.npcHasSwung = false;
  state.bounceCount = 0;
  state.rallyCount = 0;
  state.faultFlag = false;

  // Force character to animate hitting the serve
  if (playerServing) {
    state.playerSwingTimer = SWING_DURATION;
    state.playerHasSwung = true;
  } else {
    state.npcSwingTimer = SWING_DURATION;
    state.npcHasSwung = true;
  }
}

/** Formats numerical points into tennis scoring phrases. Returns object with { playerStr, npcStr, winner } */
function getTennisScore(p, n) {
  const points = ['Love', '15', '30', '40'];
  if (p >= 4 || n >= 4) {
    if (Math.abs(p - n) >= 2) return { winner: p > n ? 'player' : 'npc' };
    if (p === n) return { playerStr: 'Deuce', npcStr: 'Deuce' };
    return { playerStr: p > n ? 'Ad' : '-', npcStr: n > p ? 'Ad' : '-' };
  }
  if (p === 3 && n === 3) return { playerStr: 'Deuce', npcStr: 'Deuce' };
  return { playerStr: points[p], npcStr: points[n] };
}

function updateScoreboardDOM() {
  const currentScore = getTennisScore(state.playerScore, state.npcScore);
  const npcEl = document.getElementById('tennis-score-npc');
  const playerEl = document.getElementById('tennis-score-player');
  if (npcEl) npcEl.innerText = 'NPC: ' + (currentScore.npcStr || '');
  if (playerEl) playerEl.innerText = 'YOU: ' + (currentScore.playerStr || '');
}

/**
 * Triggers the end of a point, forcing characters to automatically
 * walk back to their default service baseline coordinates.
 * 
 * @param {boolean} nextPlayerServing - True if player serves next.
 */
function triggerPointReset(nextPlayerServing) {
  if (state.resetting) return;
  state.resetting = true;

  // Award point based on who is serving next (loser of the rally serves)
  if (nextPlayerServing) {
    state.npcScore++;
  } else {
    state.playerScore++;
  }

  const scoreData = getTennisScore(state.playerScore, state.npcScore);
  if (scoreData.winner) {
    // Game won, reset points for the next game
    state.playerScore = 0;
    state.npcScore = 0;
  }
  updateScoreboardDOM();

  state.nextServerIsPlayer = nextPlayerServing;
  // Always serve from Deuce (-1) on Even total points, Ad (1) on Odd total points
  state.serveSide = ((state.playerScore + state.npcScore) % 2 === 0) ? -1 : 1;
  state.resetDelayTimer = 1.5; // Brief intermission before next serve
  if (state.rallyCount >= 4) {
    soundManager.playPooled('/media/clap.mp3', 0.8);
  }
}

/**
 * Core logical tick, executing Player Input, AI calculations, 3D Physics logic, and collision.
 * 
 * @param {number} dt - Delta time in seconds since last frame.
 */
function update(dt) {
  if (!minigameActive) return;

  // Cinematic Intro Sequence
  if (state.introPhase && state.introPhase !== 'playing') {
    if (state.introPhase === 'walkToNet') {
      const targetPlayerY = (GAME_HEIGHT / 2) + 25;
      const targetNpcY = (GAME_HEIGHT / 2) - 25;

      const pDist = targetPlayerY - getPlayerY();
      const nDist = targetNpcY - getNpcY();
      const pDistX = 0 - state.playerOffsetX;
      const nDistX = 0 - state.npcOffsetX;

      const speed = PADDLE_SPEED * dt * 0.5;

      if (Math.abs(pDist) > 2) {
        state.playerOffsetY += Math.sign(pDist) * speed;
        state.playerLegTimer += speed * 0.1;
      }
      if (Math.abs(pDistX) > 2) {
        state.playerOffsetX += Math.sign(pDistX) * speed;
        state.playerLegTimer += speed * 0.1;
      } else {
        state.playerOffsetX = 0;
      }

      if (Math.abs(nDist) > 2) {
        state.npcOffsetY += Math.sign(nDist) * speed;
        state.npcLegTimer += speed * 0.1;
      }
      if (Math.abs(nDistX) > 2) {
        state.npcOffsetX += Math.sign(nDistX) * speed;
        state.npcLegTimer += speed * 0.1;
      } else {
        state.npcOffsetX = 0;
      }

      // Face each other
      state.playerRotation = 270;
      state.npcRotation = 90;

      if (Math.abs(pDist) <= 2 && Math.abs(nDist) <= 2 && Math.abs(pDistX) <= 2 && Math.abs(nDistX) <= 2) {
        state.introPhase = 'shakeHands';
        state.introTimer = 2.0; // 2 seconds of shaking hands
        state.playerLegTimer = 0;
        state.npcLegTimer = 0;
      }
    } else if (state.introPhase === 'shakeHands') {
      state.introTimer -= dt;
      // Simulate hand shake by oscillating rotation slightly
      state.playerRotation = 270 + Math.sin(state.introTimer * 20) * 10;
      state.npcRotation = 90 - Math.sin(state.introTimer * 20) * 10;

      if (state.introTimer <= 0) {
        state.introPhase = 'walkToBaseline';
      }
    } else if (state.introPhase === 'walkToBaseline') {
      const serveOffset = COURT_INNER_BOUNDS.width * 0.4;
      const targetPX = state.nextServerIsPlayer ? state.serveSide * serveOffset : state.serveSide * -serveOffset;
      const targetNX = state.nextServerIsPlayer ? state.serveSide * -serveOffset : state.serveSide * serveOffset;

      const pDistY = -state.playerOffsetY; // target 0
      const pDistX = targetPX - state.playerOffsetX;
      const nDistY = -state.npcOffsetY; // target 0
      const nDistX = targetNX - state.npcOffsetX;

      const speed = PADDLE_SPEED * dt * 0.6;
      let pMoved = false;
      let nMoved = false;

      if (Math.abs(pDistY) > 2) {
        state.playerOffsetY += Math.sign(pDistY) * speed;
        pMoved = true;
      }
      if (Math.abs(pDistX) > 2) {
        state.playerOffsetX += Math.sign(pDistX) * speed;
        pMoved = true;
      }

      if (pMoved) {
        state.playerLegTimer += speed * 0.1;
        state.playerRotation = 90; // Face away while walking back
      } else {
        state.playerRotation = 270; // Turn around when at baseline
        state.playerOffsetX = targetPX;
        state.playerOffsetY = 0;
      }

      if (Math.abs(nDistY) > 2) {
        state.npcOffsetY += Math.sign(nDistY) * speed;
        nMoved = true;
      }
      if (Math.abs(nDistX) > 2) {
        state.npcOffsetX += Math.sign(nDistX) * speed;
        nMoved = true;
      }

      if (nMoved) {
        state.npcLegTimer += speed * 0.1;
        state.npcRotation = 270; // Face away while walking back
      } else {
        state.npcRotation = 90; // Turn around when at baseline
        state.npcOffsetX = targetNX;
        state.npcOffsetY = 0;
      }

      if (!pMoved && !nMoved) {
        state.playerLegTimer = 0;
        state.npcLegTimer = 0;
        state.introPhase = 'playing';
        serveBall(state.nextServerIsPlayer);
      }
    }
    return; // Block the rest of the game update loop during intro
  }

  const playerY = getPlayerY();
  const npcY = getNpcY();

  // 1. Process Swing Timers
  if (state.playerSwingTimer > 0) {
    state.playerSwingTimer = Math.max(0, state.playerSwingTimer - dt);
  }
  if (state.npcSwingTimer > 0) {
    state.npcSwingTimer = Math.max(0, state.npcSwingTimer - dt);
  }

  // Define approach proximities for pre-cocking animations
  const isPlayerApproaching = state.ballVY > 0 && !state.playerHasSwung && Math.abs(state.ballOffsetX - state.playerOffsetX) < 150 && (playerY - state.ballY) > 0 && (playerY - state.ballY) < 150;
  const isNpcApproaching = state.ballVY < 0 && !state.npcHasSwung && Math.abs(state.ballOffsetX - state.npcOffsetX) < 150 && (state.ballY - npcY) > 0 && (state.ballY - npcY) < 150;

  const playerSwing = getSwingState(state.playerSwingTimer, isPlayerApproaching);
  const npcSwing = getSwingState(state.npcSwingTimer, isNpcApproaching);

  // Character arms dynamically stretch slightly if ball is just outside character center
  const playerSideReach = 14 + (isPlayerApproaching || state.playerSwingTimer > 0 ? clamp(state.ballOffsetX - state.playerOffsetX, -12, 12) : 0);
  const npcSideReach = 14 + (isNpcApproaching || state.npcSwingTimer > 0 ? clamp(-(state.ballOffsetX - state.npcOffsetX), -12, 12) : 0);

  // Compute Z-axis reach elevation for high-bouncing shots only when ball in Y-proximity
  const playerDistY = Math.abs(state.ballY - playerY);
  const playerZMult = clamp(1 - (playerDistY / 80), 0, 1);
  state.playerElevateZ = (isPlayerApproaching || state.playerSwingTimer > 0) ? clamp(state.ballCurrentHeight - 20, 0, 70) * playerZMult : 0;

  const npcDistY = Math.abs(state.ballY - npcY);
  const npcZMult = clamp(1 - (npcDistY / 80), 0, 1);
  state.npcElevateZ = (isNpcApproaching || state.npcSwingTimer > 0) ? clamp(state.ballCurrentHeight - 20, 0, 70) * npcZMult : 0;

  // Absolute world coordinates of both racket hitboxes (calculated strictly from canvas renderer payload)
  const playerRacketPos = getRacketWorldPos(true);
  const npcRacketPos = getRacketWorldPos(false);

  // The actual collision checks test against visually elevated (Z-adjusted) Y coord 
  const visualBallY = state.ballY - state.ballCurrentHeight;

  // Calculate specific collision boundaries
  const playerTriggerW = playerRacketPos.w + 30 * camera.zoom;
  const playerTriggerH = playerRacketPos.h + 15 * camera.zoom;

  const npcTriggerW = npcRacketPos.w + 30 * camera.zoom;
  const npcTriggerH = npcRacketPos.h + 15 * camera.zoom;

  // 2. Automated Swing Triggers
  // Swing initiates only if the racket will successfully intersect the ball's trajectory, and it is physically in reach
  if (!state.resetting && state.ballVY > 0 && state.playerSwingTimer === 0 && !state.playerHasSwung) {
    const dx = state.ballOffsetX - playerRacketPos.x;
    const dy = visualBallY - playerRacketPos.y;
    const localDx = dx * Math.cos(-playerRacketPos.angle) - dy * Math.sin(-playerRacketPos.angle);
    const localDy = dx * Math.sin(-playerRacketPos.angle) + dy * Math.cos(-playerRacketPos.angle);

    if (
      Math.abs(state.ballY - playerRacketPos.groundY) < 50 &&
      state.ballCurrentHeight >= playerRacketPos.z - 15 && state.ballCurrentHeight <= playerRacketPos.z + 50 &&
      Math.pow(localDx, 2) / Math.pow(playerTriggerW, 2) + Math.pow(localDy, 2) / Math.pow(playerTriggerH, 2) <= 1
    ) {
      state.playerSwingTimer = SWING_DURATION;
      state.playerHasSwung = true;
    }
  }

  if (!state.resetting && state.ballVY < 0 && state.npcSwingTimer === 0 && !state.npcHasSwung) {
    const dx = state.ballOffsetX - npcRacketPos.x;
    const dy = visualBallY - npcRacketPos.y;
    const localDx = dx * Math.cos(-npcRacketPos.angle) - dy * Math.sin(-npcRacketPos.angle);
    const localDy = dx * Math.sin(-npcRacketPos.angle) + dy * Math.cos(-npcRacketPos.angle);

    if (
      Math.abs(state.ballY - npcRacketPos.groundY) < 50 &&
      state.ballCurrentHeight >= npcRacketPos.z - 15 && state.ballCurrentHeight <= npcRacketPos.z + 50 &&
      Math.pow(localDx, 2) / Math.pow(npcTriggerW, 2) + Math.pow(localDy, 2) / Math.pow(npcTriggerH, 2) <= 1
    ) {
      state.npcSwingTimer = SWING_DURATION;
      state.npcHasSwung = true;
    }
  }

  // 3. Process Player Inputs & Movement
  const prevPlayerX = state.playerOffsetX;
  const prevPlayerY = state.playerOffsetY;

  if (state.resetting) {
    const serveOffset = COURT_INNER_BOUNDS.width * 0.4;
    const targetX = state.nextServerIsPlayer ? state.serveSide * serveOffset : state.serveSide * -serveOffset;
    const distToX = targetX - state.playerOffsetX;
    const distToY = -state.playerOffsetY;
    if (Math.abs(distToX) > 2 || Math.abs(distToY) > 2) {
      const moveStepP = PADDLE_SPEED * dt;
      let pMovedX = 0, pMovedY = 0;
      if (Math.abs(distToX) > 2) {
        pMovedX = Math.sign(distToX) * Math.min(moveStepP, Math.abs(distToX));
        state.playerOffsetX += pMovedX;
      }
      if (Math.abs(distToY) > 2) {
        pMovedY = Math.sign(distToY) * Math.min(moveStepP, Math.abs(distToY));
        state.playerOffsetY += pMovedY;
      }
    } else {
      const diffP = 270 - state.playerRotation;
      let shortestP = (diffP + 540) % 360 - 180;
      state.playerRotation += shortestP * 0.2;
    }
  } else {
    const isLeft = inputManager.isPressed('ArrowLeft') || inputManager.isPressed('KeyA') || (inputManager.keys.TouchMove && inputManager.joystickVector.x < -0.3);
    const isRight = inputManager.isPressed('ArrowRight') || inputManager.isPressed('KeyD') || (inputManager.keys.TouchMove && inputManager.joystickVector.x > 0.3);
    const isUp = inputManager.isPressed('ArrowUp') || inputManager.isPressed('KeyW') || (inputManager.keys.TouchMove && inputManager.joystickVector.y < -0.3);
    const isDown = inputManager.isPressed('ArrowDown') || inputManager.isPressed('KeyS') || (inputManager.keys.TouchMove && inputManager.joystickVector.y > 0.3);

    // Dynamic Player Aim Calculation
    let pAimYaw = 0;
    let pAimPitch = 0;
    if (isLeft) pAimYaw = -Math.PI / 5;
    if (isRight) pAimYaw = Math.PI / 5;
    if (isUp) pAimPitch = Math.PI / 8; // Lob aim
    if (isDown) pAimPitch = -Math.PI / 12; // Slice aim
    state.playerAimYaw = pAimYaw;
    state.playerAimPitch = pAimPitch;

    let playerMoveX = 0;
    let playerMoveY = 0;

    // Read from analog mobile joystick first if active
    if (inputManager.keys.TouchMove) {
      playerMoveX = inputManager.joystickVector.x * PADDLE_SPEED * dt;
      playerMoveY = inputManager.joystickVector.y * PADDLE_SPEED * dt;
    } else {
      if (inputManager.isPressed('ArrowUp') || inputManager.isPressed('KeyW')) {
        playerMoveY = -PADDLE_SPEED * dt;
      }
      if (inputManager.isPressed('ArrowDown') || inputManager.isPressed('KeyS')) {
        playerMoveY = PADDLE_SPEED * dt;
      }
      if (inputManager.isPressed('ArrowLeft') || inputManager.isPressed('KeyA')) {
        playerMoveX = -PADDLE_SPEED * dt;
      }
      if (inputManager.isPressed('ArrowRight') || inputManager.isPressed('KeyD')) {
        playerMoveX = PADDLE_SPEED * dt;
      }
    }

    if (playerMoveX !== 0 || playerMoveY !== 0) {
      // Normalize diagonal keyboard strafe speed so you don't move 1.41x faster
      if (playerMoveX !== 0 && playerMoveY !== 0 && !inputManager.keys.TouchMove) {
        const length = Math.sqrt(playerMoveX * playerMoveX + playerMoveY * playerMoveY);
        playerMoveX = (playerMoveX / length) * PADDLE_SPEED * dt;
        playerMoveY = (playerMoveY / length) * PADDLE_SPEED * dt;
      }

      if (playerMoveX !== 0) {
        state.playerOffsetX += playerMoveX;
        state.playerDirection = Math.sign(playerMoveX);
      }
      if (playerMoveY !== 0) {
        state.playerOffsetY += playerMoveY;
        state.playerDirectionY = Math.sign(playerMoveY);
      }
    }

    // Smoothly rotate player based on movement
    let targetPlayerRotation = 270; // Default facing net
    if (playerMoveX > 0 && playerMoveY === 0) targetPlayerRotation = 0;
    else if (playerMoveX < 0 && playerMoveY === 0) targetPlayerRotation = 180;
    else if (playerMoveX > 0 && playerMoveY < 0) targetPlayerRotation = 315;
    else if (playerMoveX < 0 && playerMoveY < 0) targetPlayerRotation = 225;
    else if (playerMoveX > 0 && playerMoveY > 0) targetPlayerRotation = 45;
    else if (playerMoveX < 0 && playerMoveY > 0) targetPlayerRotation = 135;

    // Soft angular interpolation
    const diffP = targetPlayerRotation - state.playerRotation;
    // Normalize shortest path
    let shortestP = (diffP + 540) % 360 - 180;
    state.playerRotation += shortestP * 0.2;
  }

  // Enforce rigid physical boundaries
  state.playerOffsetX = clamp(state.playerOffsetX, -PLAYABLE_HALF_WIDTH + 50, PLAYABLE_HALF_WIDTH - 50);
  // Vertical bounds (-100 forward into court, 50 backward behind baseline)
  state.playerOffsetY = clamp(state.playerOffsetY, -100, 50);

  // Character legs only animate if they mathematically changed coordinate after clamping
  const playerMoved = (state.playerOffsetX !== prevPlayerX) || (state.playerOffsetY !== prevPlayerY);

  // Update local animation timers specifically decoupled from generic engine
  const playerStrideSpeed = PADDLE_SPEED * dt * 0.05;
  if (playerMoved) {
    state.playerLegTimer += playerStrideSpeed;
  } else if (state.playerLegTimer > 0) {
    // Allow legs to gracefully finish their stride loop back to a neutral stance
    const phase = state.playerLegTimer % Math.PI;
    if (phase > 0.1 && phase < Math.PI - 0.1) {
      state.playerLegTimer += playerStrideSpeed;
    } else {
      state.playerLegTimer = 0;
    }
  }

  // 4. Process Simple AI NPC Movement
  const prevNpcX = state.npcOffsetX;
  const prevNpcY = state.npcOffsetY;

  if (state.resetting) {
    const serveOffset = COURT_INNER_BOUNDS.width * 0.4;
    const targetX = state.nextServerIsPlayer ? state.serveSide * -serveOffset : state.serveSide * serveOffset;
    const distToX = targetX - state.npcOffsetX;
    const distToY = -state.npcOffsetY;
    if (Math.abs(distToX) > 2 || Math.abs(distToY) > 2) {
      const moveStepN = NPC_SPEED * dt;
      let nMovedX = 0, nMovedY = 0;
      if (Math.abs(distToX) > 2) {
        nMovedX = Math.sign(distToX) * Math.min(moveStepN, Math.abs(distToX));
        state.npcOffsetX += nMovedX;
        state.npcDirection = Math.sign(nMovedX);
      }
      if (Math.abs(distToY) > 2) {
        nMovedY = Math.sign(distToY) * Math.min(moveStepN, Math.abs(distToY));
        state.npcOffsetY += nMovedY;
      }

      let targetRot = 90;
      if (nMovedX > 0 && nMovedY === 0) targetRot = 0;
      else if (nMovedX < 0 && nMovedY === 0) targetRot = 180;
      else if (nMovedX > 0 && nMovedY < 0) targetRot = 315;
      else if (nMovedX < 0 && nMovedY < 0) targetRot = 225;
      else if (nMovedX > 0 && nMovedY > 0) targetRot = 45;
      else if (nMovedX < 0 && nMovedY > 0) targetRot = 135;
      else if (nMovedX === 0 && nMovedY < 0) targetRot = 270;

      const diffN = targetRot - state.npcRotation;
      let shortestN = (diffN + 540) % 360 - 180;
      state.npcRotation += shortestN * 0.2;
    } else {
      const diffN = 90 - state.npcRotation;
      let shortestN = (diffN + 540) % 360 - 180;
      state.npcRotation += shortestN * 0.2;
    }
  } else {
    // Simple procedural NPC Aim
    if (state.ballOffsetX < 0 && state.npcOffsetX > 0) state.npcAimYaw = Math.PI/6;
    else if (state.ballOffsetX > 0 && state.npcOffsetX < 0) state.npcAimYaw = -Math.PI/6;
    else state.npcAimYaw = 0;
    state.npcAimPitch = 0;

    if (state.ballVY < 0) {
      if (!state.npcHasTarget) {
        // Because the NPC physically holds the racket in their right hand, but faces DOWN (90 degrees) when swinging,
        // their racket sweeps dynamically from their screen-left (-X) towards their center body over the SWING_DURATION arc.
        // Therefore, the NPC must mathematically target slightly to the screen-right (+X) of the ball's incoming trajectory.
        const approximatedRacketOffset = 40 * camera.zoom;
        // Predict trajectory where ball lands based on vertical physics
        let predictedLandY = NPC_BASE_Y;
        const vZTargetCheck = state.ballCurrentVelocity * Math.tan(state.ballCurrentPitchAngle);
        const det = vZTargetCheck * vZTargetCheck + 2 * GRAVITY * state.ballCurrentHeight;
        if (det >= 0) {
          const tLand = (vZTargetCheck + Math.sqrt(det)) / GRAVITY;
          predictedLandY = state.ballY + state.ballVY * tLand;
        }

        // Position NPC physically behind the ball's bounce depth, clamped to their playable area
        const targetY = clamp(predictedLandY - 15, NPC_BASE_Y - 50, NPC_BASE_Y + 50);

        // Calculate intercept trajectory when ball crosses that specific Y-depth plane
        const timeToIntercept = Math.abs((targetY - state.ballY) / state.ballVY);

        // Calculate raw X trajectory
        let absoluteTargetX = state.ballOffsetX + (state.ballVX * timeToIntercept);

        state.npcTargetX = absoluteTargetX + approximatedRacketOffset;
        state.npcTargetY = targetY;
        state.npcHasTarget = true;
      }
    } else {
      // Ball is moving away toward player, reset to center gracefully
      state.npcTargetX = 0;
      state.npcTargetY = NPC_BASE_Y;
      state.npcHasTarget = false;
    }

    const distToTarget = state.npcTargetX - state.npcOffsetX;

    // Use a soft deadzone and prevent overshooting frame-by-frame
    if (Math.abs(distToTarget) > 2) {
      const moveStep = Math.min(NPC_SPEED * dt, Math.abs(distToTarget));
      state.npcOffsetX += Math.sign(distToTarget) * moveStep;
      state.npcDirection = Math.sign(distToTarget);
    }

    // Track dynamically on the Y axis
    const distToTargetY = state.npcTargetY - npcY;

    if (Math.abs(distToTargetY) > 2) {
      const moveStepY = Math.min(NPC_SPEED * dt, Math.abs(distToTargetY));
      state.npcOffsetY += Math.sign(distToTargetY) * moveStepY;
      state.npcDirectionY = Math.sign(distToTargetY);
    }

    // Smoothly rotate NPC based on movement
    let targetNpcRotation = 90; // Default facing net

    // Determine movement intent
    const isMovingX = Math.abs(distToTarget) > 2;
    const isMovingY = Math.abs(distToTargetY) > 2;

    if (isMovingX && !isMovingY) targetNpcRotation = state.npcDirection > 0 ? 0 : 180;
    else if (!isMovingX && isMovingY) targetNpcRotation = state.npcDirectionY > 0 ? 90 : 270;
    else if (isMovingX && isMovingY) {
      if (state.npcDirection > 0 && state.npcDirectionY > 0) targetNpcRotation = 45;
      else if (state.npcDirection < 0 && state.npcDirectionY > 0) targetNpcRotation = 135;
      else if (state.npcDirection < 0 && state.npcDirectionY < 0) targetNpcRotation = 225;
      else if (state.npcDirection > 0 && state.npcDirectionY < 0) targetNpcRotation = 315;
    }

    const diffN = targetNpcRotation - state.npcRotation;
    let shortestN = (diffN + 540) % 360 - 180;
    state.npcRotation += shortestN * 0.2;
  }

  // Enforce rigid physical boundaries
  state.npcOffsetX = clamp(state.npcOffsetX, -PLAYABLE_HALF_WIDTH + 50, PLAYABLE_HALF_WIDTH - 50);
  // Vertical bounds (-50 backward behind baseline, 50 forward into court)
  state.npcOffsetY = clamp(state.npcOffsetY, -50, 50);

  // Character legs only animate if they mathematically changed coordinate after clamping
  const npcMoved = (state.npcOffsetX !== prevNpcX) || (state.npcOffsetY !== prevNpcY);

  const npcStrideSpeed = NPC_SPEED * dt * 0.05;
  if (npcMoved) {
    state.npcLegTimer += npcStrideSpeed;
  } else if (state.npcLegTimer > 0) {
    const phase = state.npcLegTimer % Math.PI;
    if (phase > 0.1 && phase < Math.PI - 0.1) {
      state.npcLegTimer += npcStrideSpeed;
    } else {
      state.npcLegTimer = 0;
    }
  }

  if (state.resetting && !playerMoved && !npcMoved) {
    if (state.resetDelayTimer > 0) {
      state.resetDelayTimer -= dt;
    } else {
      serveBall(state.nextServerIsPlayer);
    }
    // Allow physics payload to execute while anticipating serve!
  }

  // 5. 3D Spatial Ball Physics Processing
  const vZ = state.ballCurrentVelocity * Math.tan(state.ballCurrentPitchAngle);

  // Elevate ball
  state.ballCurrentHeight += vZ * dt;
  // Rotate velocity downward due to continuous gravity
  state.ballCurrentPitchAngle = Math.atan2(vZ - GRAVITY * dt, state.ballCurrentVelocity);

  // Handle floor bounce
  if (state.ballCurrentHeight < 0) {
    state.ballCurrentHeight = 0;
    state.bounceCount++;

    if (state.bounceCount === 1 && !state.resetting && state.lastHitter) {
      const minX = COURT_INNER_BOUNDS.x;
      const maxX = COURT_INNER_BOUNDS.x + COURT_INNER_BOUNDS.width;
      const minY = COURT_INNER_BOUNDS.y;
      const maxY = COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height;
      const netY = GAME_HEIGHT / 2;

      const inBoundsX = state.ballOffsetX >= minX && state.ballOffsetX <= maxX;
      let validBounce = false;

      if (state.lastHitter === 'player') {
        validBounce = inBoundsX && state.ballY >= minY && state.ballY <= netY; // NPC's half
      } else if (state.lastHitter === 'npc') {
        validBounce = inBoundsX && state.ballY >= netY && state.ballY <= maxY; // Player's half
      } else {
        validBounce = true;
      }

      // If the first bounce is out of bounds, flag it as a fault, but let the point continue in case the opponent still returns it
      if (!validBounce) {
        state.faultFlag = true;
      }
    }

    // Double-bounce rule: If it lands twice before being intercepted, the point is over
    if (state.bounceCount === 2 && !state.resetting) {
      if (state.faultFlag) {
        // The first bounce was out of bounds, so the last hitter loses
        triggerPointReset(state.lastHitter === 'player');
      } else {
        // The first bounce was IN bounds, so the person who failed to return it loses
        if (state.ballY > GAME_HEIGHT / 2) {
          triggerPointReset(true);  // Bounced twice on Player's side -> NPC scored
        } else {
          triggerPointReset(false); // Bounced twice on NPC's side -> Player scored
        }
      }
    }

    // Reflect vertical kinetic energy mathematically and absorb 40% (0.6 multiplier) into the court
    state.ballCurrentPitchAngle = Math.atan2(Math.abs(vZ - GRAVITY * dt) * 0.6, state.ballCurrentVelocity);
  }

  // 6. Handle Planar XY movement and Structural Net Collision
  state.ballOffsetX += state.ballVX * dt;

  const prevBallY = state.ballY;
  state.ballY += state.ballVY * dt;

  // Check if ball mathematically crossed the Y-center of the court during this frame
  const netY = GAME_HEIGHT / 2;
  if ((prevBallY < netY && state.ballY >= netY) || (prevBallY >= netY && state.ballY < netY)) {
    if (state.ballCurrentHeight < NET_HEIGHT) {
      // Ball hit the physical net structure!
      state.ballVY *= -0.3; // Rebound weakly back towards the hitter
      state.ballCurrentVelocity *= 0.3; // Kill most kinetic energy
      state.ballY = netY + Math.sign(state.ballVY) * 5; // Snap off the net
    }
  }

  // 7. Racket Deflections

  const pDx = state.ballOffsetX - playerRacketPos.x;
  const pDy = visualBallY - playerRacketPos.y;
  const pLocalDx = pDx * Math.cos(-playerRacketPos.angle) - pDy * Math.sin(-playerRacketPos.angle);
  const pLocalDy = pDx * Math.sin(-playerRacketPos.angle) + pDy * Math.cos(-playerRacketPos.angle);

  if (
    !state.resetting &&
    state.ballVY > 0 &&
    state.playerSwingTimer > 0 &&
    Math.abs(state.ballY - playerRacketPos.groundY) < 50 && 
    state.ballCurrentHeight >= playerRacketPos.z - 15 && state.ballCurrentHeight <= playerRacketPos.z + 50 &&
    // Strict Elliptical Intersection Boolean Matrix Check over standard Box Radius Check
    (Math.pow(pLocalDx, 2) / Math.pow(playerRacketPos.w + BALL_RADIUS, 2)) +
    (Math.pow(pLocalDy, 2) / Math.pow(playerRacketPos.h + BALL_RADIUS, 2)) <= 1
  ) {
    let targetX = COURT_INNER_BOUNDS.x + Math.random() * COURT_INNER_BOUNDS.width;
    let targetY = COURT_INNER_BOUNDS.y + Math.random() * (COURT_INNER_BOUNDS.height / 2);

    // Dynamically drive ball trajectory via spatial aiming limits
    if (state.playerAimYaw < 0) targetX = COURT_INNER_BOUNDS.x + COURT_INNER_BOUNDS.width * 0.15 + (Math.random() * 20); // Aim left sideline
    else if (state.playerAimYaw > 0) targetX = COURT_INNER_BOUNDS.x + COURT_INNER_BOUNDS.width * 0.85 - (Math.random() * 20); // Aim right sideline
    
    // Slight directional spin to reward center hits
    const hitOffset = state.ballOffsetX - playerRacketPos.x;
    targetX += hitOffset * 1.5;

    if (state.playerAimPitch > 0) targetY = COURT_INNER_BOUNDS.y + 20; // Aim deep lob
    else if (state.playerAimPitch < 0) targetY = COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height/2 - 20; // Aim short smash

    // Standard baseline rally acceleration
    let returnSpeed = state.ballCurrentVelocity * 1.05;

    // Power Shot Mechanic: If the player aims laterally or heavily steps into the shot
    if (Math.abs(state.playerAimYaw) > 0 || state.playerAimPitch < 0) {
      returnSpeed *= 1.35; // Power boost!
    }

    state.rallyCount++;
    state.lastHitter = 'player';
    state.bounceCount = 0; // Hitting the ball rests the bounce count
    state.faultFlag = false;
    hitBallToTarget(targetX, targetY, returnSpeed);

    // Add random variance to volume and pitch for organic audio
    let soundP = soundManager.playPooled('/media/hit_tennis_ball.mp3', 0.7 + Math.random() * 0.5);
    soundP.setRate(0.85 + Math.random() * 0.3);

    state.ballCurrentHeight = Math.max(10, state.ballCurrentHeight); // Simulate ground strike lift 

    // Un-flag the opponent permitting them to strike the returned volley
    state.npcHasSwung = false;
  }

  const nDx = state.ballOffsetX - npcRacketPos.x;
  const nDy = visualBallY - npcRacketPos.y;
  const nLocalDx = nDx * Math.cos(-npcRacketPos.angle) - nDy * Math.sin(-npcRacketPos.angle);
  const nLocalDy = nDx * Math.sin(-npcRacketPos.angle) + nDy * Math.cos(-npcRacketPos.angle);

  if (
    !state.resetting &&
    state.ballVY < 0 &&
    state.npcSwingTimer > 0 &&
    Math.abs(state.ballY - npcRacketPos.groundY) < 50 && 
    state.ballCurrentHeight >= npcRacketPos.z - 15 && state.ballCurrentHeight <= npcRacketPos.z + 50 &&
    (Math.pow(nLocalDx, 2) / Math.pow(npcRacketPos.w + BALL_RADIUS, 2)) +
    (Math.pow(nLocalDy, 2) / Math.pow(npcRacketPos.h + BALL_RADIUS, 2)) <= 1
  ) {
    let targetX = COURT_INNER_BOUNDS.x + Math.random() * COURT_INNER_BOUNDS.width;
    let targetY = COURT_INNER_BOUNDS.y + (COURT_INNER_BOUNDS.height / 2) + Math.random() * (COURT_INNER_BOUNDS.height / 2);

    // NPC procedural aim application
    if (state.npcAimYaw < 0) targetX = COURT_INNER_BOUNDS.x + COURT_INNER_BOUNDS.width * 0.15;
    else if (state.npcAimYaw > 0) targetX = COURT_INNER_BOUNDS.x + COURT_INNER_BOUNDS.width * 0.85;

    const returnSpeed = state.ballCurrentVelocity * 1.1;
    state.rallyCount++;
    state.lastHitter = 'npc';
    state.bounceCount = 0; // Hitting the ball resets bounce count
    state.faultFlag = false;
    hitBallToTarget(targetX, targetY, returnSpeed);

    // Add random variance to volume and pitch for organic audio
    let soundN = soundManager.playPooled('/media/hit_tennis_ball2.mp3', 0.7 + Math.random() * 0.5);
    soundN.setRate(0.85 + Math.random() * 0.3);

    state.ballCurrentHeight = Math.max(10, state.ballCurrentHeight);

    state.playerHasSwung = false;
  }

  // 8. Bounds Checking / Out Checks
  // Point resolving (scoring logic) automatically triggers walkback
  if (!state.resetting) {
    const isOffScreenX = Math.abs(state.ballOffsetX) > PLAYABLE_HALF_WIDTH + 150;
    const isOffScreenY = state.ballY < -50 || state.ballY > GAME_HEIGHT + 50;

    if (isOffScreenX || isOffScreenY) {
      if (state.bounceCount === 0) {
        // Flew off-screen without ever bouncing (Out of bounds)
        triggerPointReset(state.lastHitter === 'player');
      } else if (state.bounceCount === 1) {
        if (state.faultFlag) {
          // Bounced out of bounds, then flew off screen
          triggerPointReset(state.lastHitter === 'player');
        } else {
          // Bounced validly in the opponent's court, then went completely off-screen (Winner)
          triggerPointReset(state.lastHitter === 'npc');
        }
      }
    }
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
function drawRacket(ctx, limbs, pitch = 0, yaw = 0, roll = 1.0, transformData = null) {
  const pitchMult = Math.cos(pitch);
  const rx = Math.max(1, 8 * roll);
  
  if (ctx && limbs) {
    ctx.save();
    ctx.translate(limbs.rightArmX, limbs.rightArmY);

    // Point the racket purely using the target yaw vector!
    ctx.rotate(yaw);

    // Draw handle
    ctx.fillStyle = '#2c3e50';
    const handleLen = 15 * pitchMult;
    ctx.fillRect(-2, -handleLen + 5 * pitchMult, 4, handleLen);

    // Draw structural frame
    ctx.strokeStyle = '#e74c3c';
    ctx.lineWidth = 2;
    ctx.beginPath();
    const headCy = -18 * pitchMult;
    const headRy = 12 * pitchMult;
    if (ctx.ellipse) {
      ctx.ellipse(0, headCy, rx, Math.max(1, headRy), 0, 0, Math.PI * 2);
    } else {
      ctx.arc(0, headCy, Math.max(rx, 10 * pitchMult), 0, Math.PI * 2);
    }
    ctx.stroke();

    // Draw strings
    ctx.strokeStyle = 'rgba(236, 240, 241, 0.5)';
    ctx.lineWidth = 0.5;
    ctx.beginPath();

    // Horizontal strings (across the width of the face)
    for (let i = -5; i <= 5; i += 3) {
      ctx.moveTo(i * roll, headCy - headRy + 2);
      ctx.lineTo(i * roll, headCy + headRy - 2);
    }
    // Vertical strings (down the length of the face)
    for (let i = headCy - headRy + 2; i <= headCy + headRy - 2; i += 4 * pitchMult) {
      ctx.moveTo(-rx + 1, i);
      ctx.lineTo(rx - 1, i);
    }
    ctx.stroke();

    // Extract raw rendering matrix transformations natively
    if (transformData && ctx.getTransform) {
      const transform = ctx.getTransform();
      const pt = transform.transformPoint(new DOMPoint(0, headCy));
      
      // Invert the canvas viewport scaling to save pure internal game engine coordinates
      const gameX = ((pt.x - transformData.offsetX) / transformData.scale) - transformData.centerX;
      const gameY = (pt.y - transformData.offsetY) / transformData.scale;
      
      transformData.targetStateObj.x = gameX;
      transformData.targetStateObj.y = gameY;
      transformData.targetStateObj.groundY = gameY + transformData.elevateZ;
      transformData.targetStateObj.z = transformData.elevateZ + (20 * Math.sin(pitch)); // Raise structural bounds via arm pitch altitude!
      transformData.targetStateObj.w = Math.max(1, rx * camera.zoom);
      transformData.targetStateObj.h = Math.max(1, headRy * camera.zoom);
      transformData.targetStateObj.angle = transformData.baseRotation * (Math.PI / 180) + yaw;
    }

    ctx.restore();
  }

  // Always mathematically inform caller of the exact ellipse bounds rendered if they care
  return { w: rx, h: 12 * pitchMult };
}

/**
 * Calculates generic structural offsets for limbs based on leg animation and arm reach.
 */
function getLimbs(legTimer, directionX = 1, directionY = 1, rightArmX, rightArmY) {
  const legSwing = Math.sin(legTimer || 0);
  const legStride = 9;
  const armStride = 8;
  const safeDirX = directionX || 1;
  const safeDirY = directionY || 1;
  return {
    leftArmX: 4 - legSwing * armStride, leftArmY: -14,
    rightArmX: rightArmX, rightArmY: rightArmY,
    leftLegStartX: -2 + (safeDirY * legSwing * legStride), leftLegStartY: -6 + (-safeDirX * legSwing * legStride),
    leftLegEndX: -2 + (safeDirY * legSwing * legStride), leftLegEndY: -6 + (-safeDirX * legSwing * legStride),
    rightLegStartX: -2 - (safeDirY * legSwing * legStride), rightLegStartY: 6 - (-safeDirX * legSwing * legStride),
    rightLegEndX: -2 - (safeDirY * legSwing * legStride), rightLegEndY: 6 - (-safeDirX * legSwing * legStride)
  };
}

/**
 * Handles all visual translation and rasterization per-frame.
 */
function draw() {
  if (!minigameActive) return;

  const playerY = getPlayerY();
  const npcY = getNpcY();
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
  const isPlayerApproaching = state.ballVY > 0 && !state.playerHasSwung && Math.abs(state.ballOffsetX - state.playerOffsetX) < 150 && (playerY - state.ballY) > 0 && (playerY - state.ballY) < 150;
  const isNpcApproaching = state.ballVY < 0 && !state.npcHasSwung && Math.abs(state.ballOffsetX - state.npcOffsetX) < 150 && (state.ballY - npcY) > 0 && (state.ballY - npcY) < 150;

  const npcSwing = getSwingState(state.npcSwingTimer, isNpcApproaching, state.npcAimYaw, state.npcAimPitch);
  const playerSwing = getSwingState(state.playerSwingTimer, isPlayerApproaching, state.playerAimYaw, state.playerAimPitch);

  const pArmL = 16 * Math.cos(playerSwing.pitch);
  const pRightArmX = 6 + pArmL * Math.sin(playerSwing.yaw);
  const pRightArmY = -pArmL * Math.cos(playerSwing.yaw);

  const nArmL = 16 * Math.cos(npcSwing.pitch);
  const nRightArmX = 6 + nArmL * Math.sin(-npcSwing.yaw); // NPC faces screen so we mirror graphical yaw
  const nRightArmY = -nArmL * Math.cos(npcSwing.yaw);

  // 1. Render NPC
  ctx.save();
  ctx.translate(centerX + state.npcOffsetX, npcY);
  ctx.scale(camera.zoom, camera.zoom);

  // Drop shadow
  ctx.fillStyle = 'rgba(0, 0, 0, 0.25)';
  ctx.beginPath();
  ctx.arc(2, 4, 14, 0, Math.PI * 2);
  ctx.fill();

  ctx.rotate(state.npcRotation * (Math.PI / 180));
  const npcLimbs = getLimbs(state.npcLegTimer, state.npcDirection, state.npcDirectionY, nRightArmX, nRightArmY);
  characterManager.drawShoe(ctx, npcLimbs.leftLegEndX, npcLimbs.leftLegEndY, npc.shoeColor || '#1a252f', true);
  characterManager.drawShoe(ctx, npcLimbs.rightLegEndX, npcLimbs.rightLegEndY, npc.shoeColor || '#1a252f', false);

  // Evaluate visual translation mapping spatial Z elevation to the World -Y axis natively
  ctx.rotate(-state.npcRotation * (Math.PI / 180));
  ctx.translate(0, -state.npcElevateZ / camera.zoom);
  ctx.rotate(state.npcRotation * (Math.PI / 180));

  const transformN = { offsetX, offsetY, scale, centerX, baseRotation: state.npcRotation, elevateZ: state.npcElevateZ, targetStateObj: state.npcRacketPos };
  drawRacket(ctx, npcLimbs, npcSwing.pitch, npcSwing.yaw, npcSwing.roll, transformN);
  characterManager.drawHumanoidUpperBody(ctx, { ...npc, rotation: state.npcRotation, x: 0, y: 0 }, npcLimbs);
  ctx.restore();

  // 2. Render Ball Physics Elements (Drawn before player to prevent top-overlap)

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

  // Calculate and render crosshairs onto the destination surface exactly where ball's geometry will collide
  const vZTargetCheck = state.ballCurrentVelocity * Math.tan(state.ballCurrentPitchAngle);
  const det = vZTargetCheck * vZTargetCheck + 2 * GRAVITY * state.ballCurrentHeight;
  let tLand = 0;
  if (det >= 0) {
    tLand = (vZTargetCheck + Math.sqrt(det)) / GRAVITY;
  }
  const landX = centerX + state.ballOffsetX + state.ballVX * tLand;
  const landY = state.ballY + state.ballVY * tLand;

  // Only show the landing X to non-admins if the ball is moving towards the player
  if (window.isAdmin || state.ballVY > 0) {
    ctx.save();
    ctx.strokeStyle = 'rgba(255, 0, 0, 0.8)';
    ctx.lineWidth = 2; // Made slightly thicker for regular players

    ctx.beginPath();
    ctx.moveTo(landX - 5, landY - 5);
    ctx.lineTo(landX + 5, landY + 5);
    ctx.moveTo(landX + 5, landY - 5);
    ctx.lineTo(landX - 5, landY + 5);
    ctx.stroke();

    ctx.restore();
  }

  // 3. Render Player
  ctx.save();
  ctx.translate(centerX + state.playerOffsetX, playerY);
  ctx.scale(camera.zoom, camera.zoom);

  // Drop shadow
  ctx.fillStyle = 'rgba(0, 0, 0, 0.25)';
  ctx.beginPath();
  ctx.arc(2, 4, 14, 0, Math.PI * 2);
  ctx.fill();

  ctx.rotate(state.playerRotation * (Math.PI / 180));
  let playerCharacter = window.init.myCharacter;
  const playerLimbs = getLimbs(state.playerLegTimer, state.playerDirection, state.playerDirectionY, pRightArmX, pRightArmY);
  playerCharacter.rotation = state.playerRotation;
  characterManager.drawShoe(ctx, playerLimbs.leftLegEndX, playerLimbs.leftLegEndY, playerCharacter.shoeColor || '#1a252f', true);
  characterManager.drawShoe(ctx, playerLimbs.rightLegEndX, playerLimbs.rightLegEndY, playerCharacter.shoeColor || '#1a252f', false);

  ctx.rotate(-state.playerRotation * (Math.PI / 180));
  ctx.translate(0, -state.playerElevateZ / camera.zoom);
  ctx.rotate(state.playerRotation * (Math.PI / 180));

  const transformP = { offsetX, offsetY, scale, centerX, baseRotation: state.playerRotation, elevateZ: state.playerElevateZ, targetStateObj: state.playerRacketPos };
  drawRacket(ctx, playerLimbs, playerSwing.pitch, playerSwing.yaw, playerSwing.roll, transformP);
  characterManager.drawHumanoidUpperBody(ctx, playerCharacter, playerLimbs);
  ctx.restore();

  // 3. Admin Hitbox Diagnostic Visualization Overlay
  if (window.isAdmin) {
    const pHitbox = getRacketWorldPos(true);
    const nHitbox = getRacketWorldPos(false);

    ctx.save();
    ctx.strokeStyle = 'rgba(255, 0, 0, 0.8)';
    ctx.lineWidth = 1;

    // Draw Elliptical Target Hitbox representations exactly identical to logic
    ctx.beginPath();
    ctx.ellipse(centerX + pHitbox.x, pHitbox.y, pHitbox.w, pHitbox.h, pHitbox.angle, 0, Math.PI * 2);
    ctx.stroke();

    ctx.beginPath();
    ctx.ellipse(centerX + nHitbox.x, nHitbox.y, nHitbox.w, nHitbox.h, nHitbox.angle, 0, Math.PI * 2);
    ctx.stroke();

    // Draw Court Bounds
    ctx.strokeStyle = 'rgba(0, 255, 255, 0.5)'; // Cyan for bounds
    ctx.lineWidth = 2;
    ctx.strokeRect(centerX + COURT_INNER_BOUNDS.x, COURT_INNER_BOUNDS.y, COURT_INNER_BOUNDS.width, COURT_INNER_BOUNDS.height);

    // Draw the halfway net line within the bounds
    ctx.beginPath();
    ctx.moveTo(centerX + COURT_INNER_BOUNDS.x, GAME_HEIGHT / 2);
    ctx.lineTo(centerX + COURT_INNER_BOUNDS.x + COURT_INNER_BOUNDS.width, GAME_HEIGHT / 2);
    ctx.stroke();

    ctx.restore();
  }

  ctx.restore(); // Restore from world/camera zoom and offset
}
