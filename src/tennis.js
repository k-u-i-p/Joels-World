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

const COURT_INNER_BOUNDS = { x: -59, y: 85, width: 120, height: 205 };
const GAME_SCALE = COURT_INNER_BOUNDS.width / 255; // Used to normalize velocities against court shrinks

const PADDLE_SPEED = 250 * GAME_SCALE;        // Player movement speed
const NPC_SPEED = 200 * GAME_SCALE;           // NPC movement speed
const BALL_SPEED = 220 * GAME_SCALE;          // Base horizontal ball speed
const MAXIMUM_BALL_SPEED = 300 * GAME_SCALE;  // Absolute engine speed ceiling for rallying
const BALL_RADIUS = 3;                        // Collision and drawing radius of the ball
const GRAVITY = 800 * GAME_SCALE;             // Gravity affecting the ball Z-axis (pixels/s^2)
const SWING_DURATION = 0.25;                  // Duration of a racket swing in seconds
const NET_HEIGHT = 45 * GAME_SCALE;           // Minimum Z-altitude required to cross the court

const PLAYABLE_OVERSHOOT = 75; // How far characters can physically run out of bounds beyond the court lines
const PLAYABLE_HALF_WIDTH = (COURT_INNER_BOUNDS.width / 2) + PLAYABLE_OVERSHOOT; // Lateral character bounds naturally scale with the court

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
  ballY: COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height / 2,
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

  playerDirection: 1, // Default direction for player (e.g., facing right)
  npcDirection: 1,    // Default direction for NPC
  playerDirectionY: 1, // Default Y direction for player (e.g., facing down)
  npcDirectionY: 1,    // Default Y direction for NPC

  playerRotation: 270, // Initial player rotation (facing up)
  npcRotation: 90,     // Initial NPC rotation (facing down)

  playerLegTimer: 0,
  npcLegTimer: 0,
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
  isServe: false,
  servePhase: 'idle', // 'idle', 'toss', 'jump', 'strike'
  servePhaseTimer: 0,
  serverTargetX: 0,
  serverTargetY: 0,
  serverReturnSpeed: 0,
  faults: 0,
  trajectoryPoints: [],
  totalElapsedTime: 0,
  trajectoryFrozen: false,
  playerRacketPos: { x: 0, y: 0, groundY: 0, z: 0, w: 1, h: 1, angle: 0 },
  npcRacketPos: { x: 0, y: 0, groundY: 0, z: 0, w: 1, h: 1, angle: 0 }
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
 * Procedurally calculates the exact 3D Cartesian rotation required 
 * for a character's shoulder to point their arm directly at a given target point.
 * 
 * @param {number} charX - Current X map coordinate of the character.
 * @param {number} charElevZ - Current Z physical altitude of the character's feet.
 * @param {{x: number, y: number, z: number}} targetPoint - The pre-calculated optimal intercept target.
 * @param {boolean} isPlayer - True if calculating for the bottom-court player.
 * @returns {{aimYaw: number, aimPitch: number}}
 */
function calculateAimAngles(charX, charElevZ, targetPoint, isPlayer) {
  // Map coordinates relative to exactly where the character's physical shoulder socket is attached
  const shoulderX = charX;
  const shoulderZ = charElevZ + 30; // Shoulder is essentially 30px off the physical floor height

  // Diff absolute Cartesian distances (NPC mirror handles X inversion natively)
  const dx = isPlayer ? (targetPoint.x - shoulderX) : (shoulderX - targetPoint.x);
  const dz = targetPoint.z - shoulderZ;

  // Calculate exact anatomical rotation angles required to point the 20-pixel arm towards the delta!
  const targetYaw = clamp(Math.atan2(dx, 40), -Math.PI / 2.5, Math.PI / 2.5);
  const targetPitch = clamp(Math.asin(clamp(dz / 40, -1, 1)), -Math.PI / 3, Math.PI / 3);

  return { aimYaw: targetYaw, aimPitch: targetPitch };
}

/**
 * Predicts the optimal intercept point along the ball's current trajectory 
 * relative to a specific 3D target coordinate.
 * 
 * @param {{x: number, y: number, z: number}} target - The target 3D Cartesian coordinates.
 * @returns {{x: number, y: number, z: number, t: number}} - The closest trajectory coordinate and its timestamp.
 */
function calculateOptimalInterceptPoint(target) {
  let simX = state.ballOffsetX;
  let simY = state.ballY;
  let simZ = state.ballCurrentHeight;
  let simVX = state.ballVX;
  let simVY = state.ballVY;
  let simVZ = state.ballCurrentVelocity * Math.tan(state.ballCurrentPitchAngle);

  let closestDistSq = Infinity;
  let bestT = 0;
  let bestX = simX;
  let bestY = simY;
  let bestZ = simZ;

  let currentT = 0;
  const simDt = 0.016; // 60fps procedural resolution
  const maxT = 2.0;    // Cap prediction strictly at 2.0 seconds

  while (currentT <= maxT) {
    const distSq = (simX - target.x) ** 2 + (simY - target.y) ** 2 + (simZ - target.z) ** 2;

    if (distSq < closestDistSq) {
      closestDistSq = distSq;
      bestT = currentT;
      bestX = simX;
      bestY = simY;
      bestZ = simZ;
    }

    // Step the deterministic physics model natively by one slice
    simX += simVX * simDt;
    simY += simVY * simDt;
    simVZ -= GRAVITY * simDt;
    simZ += simVZ * simDt;

    // Process procedural floor deflections
    if (simZ < 0) {
      simZ = 0;
      simVZ = -simVZ * 0.6; // 0.6 standard court dampening multiplier
    }

    currentT += simDt;

    // Prune evaluation loop immediately if ball mechanically escapes active bounding volume
    if (Math.abs(simX) > PLAYABLE_HALF_WIDTH + 50 ||
      simY < COURT_INNER_BOUNDS.y - 100 ||
      simY > COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height + 100) {
      break;
    }
  }

  return { x: bestX, y: bestY, z: bestZ, t: bestT };
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

  if (!state.isServe) {
    state.trajectoryPoints = []; // Clear history on physical strike during a live rally
  }

  state.trajectoryFrozen = false; // Unfreeze tracking

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
  const netY = COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height / 2;
  const crossesNet = (state.ballY < netY && targetY > netY) || (state.ballY > netY && targetY < netY);

  if (crossesNet) {
    // Rough estimation of how long it takes to reach the net
    const timeToNet = (Math.abs(netY - state.ballY) / Math.abs(dy)) * timeToTarget;
    // Calculate the minimum Z-velocity needed to be exactly above NET_HEIGHT when t = timeToNet
    const requiredClearanceHeight = NET_HEIGHT + BALL_RADIUS + 5; // adding 5px buffer
    const minVZ = (requiredClearanceHeight - state.ballCurrentHeight + 0.5 * GRAVITY * timeToNet * timeToNet) / timeToNet;

    // If the flat stroke calculations predict crashing into the net, boost the arc!
    // However, if the ball is hit very low to the ground, or driven very fast and flat, we reduce the "auto-clearance" assist
    // naturally allowing the ball to smash into the net!
    if (vZ < minVZ) {
      let assist = 1.0;

      // Hard flat shots resist upward correction
      if (state.ballCurrentVelocity > 250) assist -= 0.2;

      // Balls hit late/low to the ground are physically harder to scoop over the net
      if (state.ballCurrentHeight < 20) assist -= 0.4;

      // Add slight organic variance (+/- 10%)
      assist = clamp(assist + (Math.random() * 0.2 - 0.1), 0, 1);

      vZ = vZ + (minVZ - vZ) * assist;
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
  camera.y = COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height / 2;
  camera.zoom = 1.8;

  const scoreboard = document.getElementById('tennis-scoreboard');
  if (scoreboard) scoreboard.style.display = 'flex';
  updateScoreboardDOM();

  gameLoop.registerFunction(run);
}

/**
 * Mechanically serves the ball from the respective character towards a valid court zone.
 * Automatically computes 3D pitch/velocity required to lob into the target destination.
 * 
 * @param {boolean} playerServing - True if player serves, false if NPC serves.
 */
function serveBall(playerServing) {
  state.resetting = false;
  state.isServe = true;
  // Calculate strict service box zones (Tennis Service line is approx 53.8% of the 39ft half-court distance)
  const centerX = COURT_INNER_BOUNDS.x + COURT_INNER_BOUNDS.width / 2;
  const serviceBoxDepth = COURT_INNER_BOUNDS.height * 0.27; // ~118.8
  const netY = COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height / 2;

  let boxMinX, boxMaxX, boxMinY, boxMaxY;

  // Serves are strictly cross-court
  if (playerServing) {
    boxMinY = netY - serviceBoxDepth;
    boxMaxY = netY;
    boxMinX = (state.serveSide === -1) ? COURT_INNER_BOUNDS.x : centerX;
    boxMaxX = (state.serveSide === -1) ? centerX : COURT_INNER_BOUNDS.x + COURT_INNER_BOUNDS.width;
  } else {
    boxMinY = netY;
    boxMaxY = netY + serviceBoxDepth;
    boxMinX = (state.serveSide === -1) ? centerX : COURT_INNER_BOUNDS.x;
    boxMaxX = (state.serveSide === -1) ? COURT_INNER_BOUNDS.x + COURT_INNER_BOUNDS.width : centerX;
  }

  state.activeServiceBox = { minX: boxMinX, maxX: boxMaxX, minY: boxMinY, maxY: boxMaxY };

  let targetX, targetY;
  if (Math.random() < 0.9) {
    // 90% chance: serve successfully hits the box, clustered organically to the T or Wide corners!
    const aimWide = Math.random() > 0.5;
    const safeLeft = boxMinX + 15;
    const safeRight = boxMaxX - 15;
    const safeY = playerServing ? boxMinY + 20 : boxMaxY - 20; // Deep towards the service line

    targetX = aimWide ? safeLeft : safeRight;
    targetY = safeY;

    // Very slight organic variance for human error
    targetX += (Math.random() * 10 - 5);
    targetY += (Math.random() * 10 - 5);
  } else {
    // 10% chance: Hit a fault! (Hits the net, long, wide, or completely the wrong box)
    targetX = boxMinX + Math.random() * (boxMaxX - boxMinX) + (Math.random() * 60 - 30);
    targetY = boxMinY + Math.random() * (boxMaxY - boxMinY) + (playerServing ? -40 : 40);
  }

  state.lastHitter = playerServing ? 'player' : 'npc';

  // Wipe the graph array so the new serve correctly starts a blank trajectory chart
  state.trajectoryPoints = [];

  // Pre-compute and cache the serve target coordinates for when the strike phase triggers!
  state.serverTargetX = targetX;
  state.serverTargetY = targetY;
  state.serverReturnSpeed = playerServing ? BALL_SPEED * 0.8 : BALL_SPEED * 0.65;

  // Transition cleanly into the organic physics simulation!
  const sideDir = state.serveSide * (playerServing ? -1 : 1);
  const tossTarget = {
    x: (playerServing ? state.playerOffsetX : state.npcOffsetX) + (sideDir * 20 * GAME_SCALE),
    y: playerServing ? (COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height - (10 * GAME_SCALE)) : (COURT_INNER_BOUNDS.y + (10 * GAME_SCALE)),
    z: 85 * GAME_SCALE
  };

  throwBall(playerServing, tossTarget);
}

/**
 * Physically throws the ball organically from the character's hand using true gravity.
 * @param {boolean} playerServing - True if player serves, false if NPC serves.
 * @param {{x: number, y: number, z: number}} tossTarget - The target apex coordinates.
 */
function throwBall(playerServing, tossTarget) {
  state.servePhase = 'live';
  state.servePhaseTimer = 0;
  state.tossTarget = tossTarget;

  // Physically start the ball strictly inside the pre-calculated left hand geometry over the baseline!
  state.ballCurrentHeight = 25;

  const startX = playerServing ? state.playerOffsetX : state.npcOffsetX;
  const startY = playerServing ? getPlayerY() : getNpcY();

  // Shift ball physically to the server body to prevent visual snapping
  state.ballOffsetX = startX;
  state.ballY = startY;

  // Calculate the physics required to apex perfectly at tossTarget.z
  const dz = Math.max(1, tossTarget.z - state.ballCurrentHeight);
  const vZ = Math.sqrt(2 * GRAVITY * dz);
  const tApex = vZ / GRAVITY;

  // Assign planar velocity to span the horizontal gap exactly during tApex
  state.ballVX = (tossTarget.x - startX) / tApex;
  state.ballVY = (tossTarget.y - startY) / tApex;

  state.ballCurrentVelocity = Math.max(0.1, Math.sqrt(state.ballVX * state.ballVX + state.ballVY * state.ballVY));
  state.ballCurrentPitchAngle = Math.atan2(vZ, state.ballCurrentVelocity);

  state.trajectoryFrozen = false; // Ignite the tracker immediately

  state.bounceCount = 0;
  state.rallyCount = 0;
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

function triggerFault(playerServing) {
  if (state.resetting) return;
  state.faults++;
  soundManager.playPooled('/media/hit_tennis_ball2.mp3', 0.5); // Thud representing bad shot

  if (state.faults >= 2) {
    // Double Fault!
    triggerPointReset(!playerServing);
  } else {
    // Single fault! Reset physics but keep point alive
    state.resetting = true;
    state.trajectoryFrozen = true;
    state.resetDelayTimer = 1.0;
    state.nextServerIsPlayer = playerServing; // Same person serves again
  }
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
  state.trajectoryFrozen = true; // Freeze the graph to display the concluding shot!

  // Award point based on who is serving next (loser of the rally serves)
  if (nextPlayerServing) {
    state.npcScore++;
  } else {
    state.playerScore++;
  }

  // Clear faults for the next point
  state.faults = 0;

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
 * Core logical loop unifying Inputs, AI, Physics, Collision, and complete Scene Rasterization.
 * 
 * @param {number} dt - Delta time in seconds since last frame.
 */
function run(dt) {
  if (!minigameActive) return;

  // Cinematic Intro Sequence
  if (state.introPhase && state.introPhase !== 'playing') {
    if (state.introPhase === 'walkToNet') {
      const netY = COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height / 2;
      const targetPlayerY = netY + 25;
      const targetNpcY = netY - 25;

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

  // 1. Process Approach Proximities
  const isPlayerApproaching = state.ballVY > 0;
  const isNpcApproaching = state.ballVY < 0;

  // Compute Z-axis leaps only for high lobs that exceed standing arm reach (> 40px altitude)
  const playerDistY = Math.abs(state.ballY - playerY);
  const playerZMult = clamp(1 - (playerDistY / 80), 0, 1);
  if (isPlayerApproaching) {
    const requiredJump = Math.max(0, state.ballCurrentHeight - 35);
    state.playerElevateZ = clamp(requiredJump, 0, 70) * playerZMult;
  } else {
    state.playerElevateZ = 0;
  }

  const npcDistY = Math.abs(state.ballY - npcY);
  const npcZMult = clamp(1 - (npcDistY / 80), 0, 1);
  if (isNpcApproaching) {
    const requiredJump = Math.max(0, state.ballCurrentHeight - 35);
    state.npcElevateZ = clamp(requiredJump, 0, 70) * npcZMult;
  } else {
    state.npcElevateZ = 0;
  }

  // Absolute world coordinates of both racket hitboxes (calculated strictly from canvas renderer payload)
  const playerRacketPos = getRacketWorldPos(true);
  const npcRacketPos = getRacketWorldPos(false);

  // The actual collision checks test against visually elevated (Z-adjusted) Y coord 
  const visualBallY = state.ballY - state.ballCurrentHeight;

  // 3. Process Player Inputs & Movement
  let pAimYaw = Math.PI * 0.25;
  let pAimPitch = 0.0;
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
    // Procedurally Auto-Aim the Player's racket to physically intercept the ball's 3D coordinates!
    // Track either when actively approaching or when tossing a serve!
    if (state.ballVY > 0 || (state.isServe && state.lastHitter === 'player')) {
      // Procedurally Auto-Aim the Player's racket using unified physics tracking!
      const intercept = calculateOptimalInterceptPoint({ x: state.playerOffsetX, y: playerY - 15, z: state.playerElevateZ + 30 });
      const tracking = calculateAimAngles(state.playerOffsetX, state.playerElevateZ, intercept, true);
      pAimYaw = tracking.aimYaw;
      pAimPitch = tracking.aimPitch;
    }

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

  // Enforce rigid physical boundaries (100px past court lines)
  state.playerOffsetX = clamp(state.playerOffsetX, -PLAYABLE_HALF_WIDTH, PLAYABLE_HALF_WIDTH);
  // Vertical bounds (to the net, and outside baseline)
  state.playerOffsetY = clamp(state.playerOffsetY, -(COURT_INNER_BOUNDS.height / 2 + 10), PLAYABLE_OVERSHOOT - 10);

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
  let nAimYaw = Math.PI * 0.25;
  let nAimPitch = 0.0;
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
    // Procedurally Auto-Aim the NPC's racket to physically intercept the ball's 3D coordinates!
    // Track either when actively approaching or when tossing a serve!
    if (state.ballVY < 0 || (state.isServe && state.lastHitter === 'npc')) {
      // Procedurally Auto-Aim the NPC's racket using unified physics tracking!
      const intercept = calculateOptimalInterceptPoint({ x: state.npcOffsetX, y: npcY + 15, z: state.npcElevateZ + 30 });
      const tracking = calculateAimAngles(state.npcOffsetX, state.npcElevateZ, intercept, false);
      nAimYaw = tracking.aimYaw;
      nAimPitch = tracking.aimPitch;
    }
    if (state.ballVY < 0) {
      if (!state.npcHasTarget) {
        // Because the NPC physically holds the racket in their right hand, but faces DOWN (90 degrees) when swinging,
        // their racket sweeps dynamically from their screen-left (-X) towards their center body over the SWING_DURATION arc.
        // Therefore, the NPC must mathematically target slightly to the screen-right (+X) of the ball's incoming trajectory.
        const approximatedRacketOffset = 40 * camera.zoom * GAME_SCALE;
        // Predict trajectory where ball lands based on vertical physics
        let predictedLandY = NPC_BASE_Y;
        let tLand = 0;
        const vZTargetCheck = state.ballCurrentVelocity * Math.tan(state.ballCurrentPitchAngle);
        const det = vZTargetCheck * vZTargetCheck + 2 * GRAVITY * state.ballCurrentHeight;
        if (det >= 0) {
          tLand = (vZTargetCheck + Math.sqrt(det)) / GRAVITY;
          predictedLandY = state.ballY + state.ballVY * tLand;
        }

        // Position NPC physically behind the ball's bounce depth, clamped to their playable half-court area
        const targetY = clamp(predictedLandY - (15 * GAME_SCALE), NPC_BASE_Y - PLAYABLE_OVERSHOOT + 10, COURT_INNER_BOUNDS.y + 10);

        // Calculate raw X trajectory directly from physics air-time!
        let absoluteTargetX = state.ballOffsetX + (state.ballVX * tLand);

        state.npcTargetX = clamp(absoluteTargetX + approximatedRacketOffset, -PLAYABLE_HALF_WIDTH + 10, PLAYABLE_HALF_WIDTH - 10);
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

  // Enforce rigid physical boundaries (100px past court lines)
  state.npcOffsetX = clamp(state.npcOffsetX, -PLAYABLE_HALF_WIDTH, PLAYABLE_HALF_WIDTH);
  // Vertical bounds (outside baseline, to the net)
  state.npcOffsetY = clamp(state.npcOffsetY, -(PLAYABLE_OVERSHOOT - 10), (COURT_INNER_BOUNDS.height / 2) + 10);

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
      const netY = COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height / 2;

      const inBoundsX = state.ballOffsetX >= minX && state.ballOffsetX <= maxX;
      let validBounce = false;

      if (state.isServe) {
        // Enforce rigid Service Box intersections!
        const box = state.activeServiceBox;
        if (state.ballOffsetX >= box.minX && state.ballOffsetX <= box.maxX && state.ballY >= box.minY && state.ballY <= box.maxY) {
          validBounce = true;
          state.isServe = false; // Valid serve, rally is now organically open
        }
      } else {
        // Enforce total half-court bounds!
        if (state.lastHitter === 'player') {
          validBounce = inBoundsX && state.ballY >= minY && state.ballY <= netY; // NPC's half
        } else if (state.lastHitter === 'npc') {
          validBounce = inBoundsX && state.ballY >= netY && state.ballY <= maxY; // Player's half
        } else {
          validBounce = true;
        }
      }

      // If the first bounce is out of bounds, the point is instantly dead!
      if (!validBounce) {
        if (state.isServe) {
          triggerFault(state.lastHitter === 'player');
        } else {
          triggerPointReset(state.lastHitter === 'player');
        }
      }
    }

    // Double-bounce rule: If it lands twice validly before being intercepted, the person who failed to return it loses
    if (state.bounceCount === 2 && !state.resetting) {
      if (state.ballY > COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height / 2) {
        triggerPointReset(true);  // Bounced twice on Player's side -> NPC scored
      } else {
        triggerPointReset(false); // Bounced twice on NPC's side -> Player scored
      }
    }

    // Reflect vertical kinetic energy mathematically and absorb 40% (0.6 multiplier) into the court
    state.ballCurrentPitchAngle = Math.atan2(Math.abs(vZ - GRAVITY * dt) * 0.6, state.ballCurrentVelocity);
  }

  // 6. Handle Planar XY movement and Structural Net Collision
  state.ballOffsetX += state.ballVX * dt;

  const prevBallY = state.ballY;
  state.ballY += state.ballVY * dt;

  // Progress global point timer monotonically (freeze while waiting for serves to start)
  if (state.resetDelayTimer <= 0) state.totalElapsedTime += dt;

  // Explicitly permit tracking during the pre-strike serve animations
  const trackingServe = state.isServe && (state.servePhase === 'toss' || state.servePhase === 'jump');
  if ((minigameActive && !state.trajectoryFrozen) || trackingServe) {
    state.trajectoryPoints.push({
      x: state.ballOffsetX,
      y: state.ballY,
      t: state.totalElapsedTime,
      z: state.ballCurrentHeight,
      pZ: playerRacketPos.z + 25, // Align to physical shoulder height (25px above floor)
      nZ: npcRacketPos.z + 25
    });
    // Keep array from growing infinitely if the ball gets stuck out of bounds
    if (state.trajectoryPoints.length > 300) state.trajectoryPoints.shift();
  }

  // Check if ball mathematically crossed the Y-center of the court during this frame
  const netY = COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height / 2;
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

  // Calculate spatial velocity to enforce valid serve drop heights
  const currentVZ = state.ballCurrentVelocity * Math.tan(state.ballCurrentPitchAngle);

  // Only permit serving hits if the ball has crested the apex of the toss and is falling (currentVZ <= 0)
  if (
    !state.resetting &&
    (state.ballVY > 0 || (state.isServe && state.lastHitter === 'player' && currentVZ <= 0)) &&
    Math.abs(state.ballY - playerRacketPos.groundY) < 50 &&
    state.ballCurrentHeight >= playerRacketPos.z - 15 && state.ballCurrentHeight <= playerRacketPos.z + 50 &&
    // Strict Elliptical Intersection Boolean Matrix Check over standard Box Radius Check
    (Math.pow(pLocalDx, 2) / Math.pow(playerRacketPos.w + BALL_RADIUS, 2)) +
    (Math.pow(pLocalDy, 2) / Math.pow(playerRacketPos.h + BALL_RADIUS, 2)) <= 1
  ) {
    let targetX = COURT_INNER_BOUNDS.x + Math.random() * COURT_INNER_BOUNDS.width;
    let targetY = COURT_INNER_BOUNDS.y + Math.random() * (COURT_INNER_BOUNDS.height / 2);
    let returnSpeed = state.ballCurrentVelocity * 1.05;

    if (state.isServe) {
      targetX = state.serverTargetX;
      targetY = state.serverTargetY;
      returnSpeed = state.serverReturnSpeed;
    } else {
      // Organic center hit variance
      const hitOffset = state.ballOffsetX - playerRacketPos.x;
      targetX += hitOffset * 1.5;
    }

    state.rallyCount++;
    state.lastHitter = 'player';
    state.bounceCount = 0; // Hitting the ball rests the bounce count
    state.isServe = false; // The rally is live!
    hitBallToTarget(targetX, targetY, returnSpeed);

    // Add random variance to volume and pitch for organic audio
    let soundP = soundManager.playPooled('/media/hit_tennis_ball.mp3', 0.7 + Math.random() * 0.5);
    soundP.setRate(0.85 + Math.random() * 0.3);

    state.ballCurrentHeight = Math.max(10, state.ballCurrentHeight); // Simulate ground strike lift 

  }

  const nDx = state.ballOffsetX - npcRacketPos.x;
  const nDy = visualBallY - npcRacketPos.y;
  const nLocalDx = nDx * Math.cos(-npcRacketPos.angle) - nDy * Math.sin(-npcRacketPos.angle);
  const nLocalDy = nDx * Math.sin(-npcRacketPos.angle) + nDy * Math.cos(-npcRacketPos.angle);

  if (
    !state.resetting &&
    (state.ballVY < 0 || (state.isServe && state.lastHitter === 'npc' && currentVZ <= 0)) &&
    Math.abs(state.ballY - npcRacketPos.groundY) < 50 &&
    state.ballCurrentHeight >= npcRacketPos.z - 15 && state.ballCurrentHeight <= npcRacketPos.z + 50 &&
    (Math.pow(nLocalDx, 2) / Math.pow(npcRacketPos.w + BALL_RADIUS, 2)) +
    (Math.pow(nLocalDy, 2) / Math.pow(npcRacketPos.h + BALL_RADIUS, 2)) <= 1
  ) {
    let targetX = COURT_INNER_BOUNDS.x + Math.random() * COURT_INNER_BOUNDS.width;
    let targetY = COURT_INNER_BOUNDS.y + (COURT_INNER_BOUNDS.height / 2) + Math.random() * (COURT_INNER_BOUNDS.height / 2);
    let returnSpeed = state.ballCurrentVelocity * 1.1;

    if (state.isServe) {
      targetX = state.serverTargetX;
      targetY = state.serverTargetY;
      returnSpeed = state.serverReturnSpeed;
    } else {
      // NPC procedural aim application
      if (state.ballOffsetX < 0) targetX = COURT_INNER_BOUNDS.x + COURT_INNER_BOUNDS.width * 0.85; // Hit away
      else targetX = COURT_INNER_BOUNDS.x + COURT_INNER_BOUNDS.width * 0.15;
    }
    state.rallyCount++;
    state.lastHitter = 'npc';
    state.bounceCount = 0; // Hitting the ball resets bounce count
    state.isServe = false; // The rally is live!
    hitBallToTarget(targetX, targetY, returnSpeed);

    // Add random variance to volume and pitch for organic audio
    let soundN = soundManager.playPooled('/media/hit_tennis_ball2.mp3', 0.7 + Math.random() * 0.5);
    soundN.setRate(0.85 + Math.random() * 0.3);

    state.ballCurrentHeight = Math.max(10, state.ballCurrentHeight);
  }

  // 8. Bounds Checking / Out Checks
  // Point resolving (scoring logic) automatically triggers walkback
  if (!state.resetting) {
    const isOffScreenX = Math.abs(state.ballOffsetX) > PLAYABLE_HALF_WIDTH + 150;
    const courtMaxY = COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height;
    const isOffScreenY = state.ballY < COURT_INNER_BOUNDS.y - 150 || state.ballY > courtMaxY + 150;

    if (isOffScreenX || isOffScreenY) {
      if (state.bounceCount === 0) {
        // Flew off-screen without ever bouncing (Out of bounds)
        if (state.isServe) triggerFault(state.lastHitter === 'player');
        else triggerPointReset(state.lastHitter === 'player');
      } else if (state.bounceCount === 1) {
        // Bounced validly in the opponent's court, then went completely off-screen (Winner)
        triggerPointReset(state.lastHitter === 'npc');
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
  const pitchMult = Math.max(0.05, Math.abs(Math.cos(pitch)));
  const rx = Math.max(1, 8 * roll);

  if (ctx && limbs) {
    ctx.save();
    ctx.translate(limbs.rightArmX, limbs.rightArmY);

    // Align the racket 90 degrees to point along the +X forward vector natively
    ctx.rotate(yaw + Math.PI / 2);

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
      transformData.targetStateObj.w = Math.max(1, rx * camera.zoom * (transformData.courtScale || 1));
      transformData.targetStateObj.h = Math.max(1, headRy * camera.zoom * (transformData.courtScale || 1));
      transformData.targetStateObj.angle = transformData.baseRotation * (Math.PI / 180) + yaw + Math.PI / 2;
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
    leftArmX: -2 - legSwing * armStride, leftArmY: -14,
    rightArmX: rightArmX, rightArmY: rightArmY,
    leftLegStartX: -2 + (safeDirY * legSwing * legStride), leftLegStartY: -6 + (-safeDirX * legSwing * legStride),
    leftLegEndX: -2 + (safeDirY * legSwing * legStride), leftLegEndY: -6 + (-safeDirX * legSwing * legStride),
    rightLegStartX: -2 - (safeDirY * legSwing * legStride), rightLegStartY: 6 - (-safeDirX * legSwing * legStride),
    rightLegEndX: -2 - (safeDirY * legSwing * legStride), rightLegEndY: 6 - (-safeDirX * legSwing * legStride)
  };
}

  // ==========================================
  // RENDERING PHASE
  // ==========================================

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

  const imageAspect = bgImage.width / bgImage.height;

  // Game native virtual layout dimension based on total inner court height plus baseline runoffs
  const virtualGameHeight = COURT_INNER_BOUNDS.height + (PLAYABLE_OVERSHOOT * 2) + 20;

  const renderHeight = viewportHeight * dpr;
  const renderWidth = renderHeight * imageAspect;

  const offsetX = (viewportWidth * dpr - renderWidth) / 2;
  const offsetY = 0;

  ctx.drawImage(bgImage, offsetX, offsetY, renderWidth, renderHeight);
  ctx.translate(offsetX, offsetY);

  const scale = renderHeight / virtualGameHeight;
  ctx.scale(scale, scale);

  const gameWidth = virtualGameHeight * imageAspect;
  const centerX = gameWidth / 2;

  // Derive visual scaling metric from the customized bounding area
  const COURT_SCALE = COURT_INNER_BOUNDS.width / 255;

  const pArmL = 4 * Math.cos(pAimPitch);
  const pRightArmX = -2 + pArmL * Math.cos(pAimYaw);
  const pRightArmY = 14 + pArmL * Math.sin(pAimYaw);

  const nArmL = 4 * Math.cos(nAimPitch);
  const nRightArmX = -2 + nArmL * Math.cos(nAimYaw);
  const nRightArmY = 14 + nArmL * Math.sin(nAimYaw);

  // 1. Render NPC
  ctx.save();
  ctx.translate(centerX + state.npcOffsetX, npcY);
  ctx.scale(camera.zoom * COURT_SCALE, camera.zoom * COURT_SCALE);

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

  const transformN = { offsetX, offsetY, scale, centerX, baseRotation: state.npcRotation, elevateZ: state.npcElevateZ, targetStateObj: state.npcRacketPos, courtScale: COURT_SCALE };
  if (!window.isAdmin) drawRacket(ctx, npcLimbs, nAimPitch, nAimYaw, 0.3, transformN);
  characterManager.drawHumanoidUpperBody(ctx, { ...npc, rotation: state.npcRotation, x: 0, y: 0 }, npcLimbs);
  if (window.isAdmin) drawRacket(ctx, npcLimbs, nAimPitch, nAimYaw, 0.3, transformN);
  ctx.restore();

  // 2. Render Ball Physics Elements (Drawn before player to prevent top-overlap)

  // Ball's vertical Ground Shadow
  ctx.save();
  ctx.fillStyle = 'rgba(0, 0, 0, 0.25)';
  ctx.beginPath();
  // Shrink shadow exponentially based on elevation altitude
  const shadowRadius = Math.max(2 * COURT_SCALE, (BALL_RADIUS * 2 - state.ballCurrentHeight * 0.05) * COURT_SCALE);
  ctx.arc(centerX + state.ballOffsetX, state.ballY, shadowRadius, 0, Math.PI * 2);
  ctx.fill();
  ctx.restore();

  // Physical Ball Emoji
  ctx.save();
  ctx.font = `${Math.max(6, BALL_RADIUS * 2 * COURT_SCALE)}px sans-serif`;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';

  if (state.isServe && state.servePhase === 'idle') {
    // If waiting to serve, geometrically track the ball to the localized left hand of the server!
    const isPlayerServing = state.nextServerIsPlayer;
    const baseRotation = isPlayerServing ? state.playerRotation : state.npcRotation;
    const rotRad = baseRotation * (Math.PI / 180);
    const limbs = isPlayerServing ? playerLimbs : npcLimbs;
    const serverX = isPlayerServing ? state.playerOffsetX : state.npcOffsetX;
    const serverY = isPlayerServing ? getPlayerY() : getNpcY();
    const serverZ = isPlayerServing ? state.playerElevateZ : state.npcElevateZ;

    // Map local leftArm coordinates exactly how `drawHumanoidUpperBody` does natively
    const armWorldX = (limbs.leftArmX * Math.cos(rotRad) - limbs.leftArmY * Math.sin(rotRad)) * camera.zoom * COURT_SCALE;
    const armWorldY = (limbs.leftArmX * Math.sin(rotRad) + limbs.leftArmY * Math.cos(rotRad)) * camera.zoom * COURT_SCALE;

    ctx.translate(centerX + serverX + armWorldX, serverY + armWorldY - serverZ);
    ctx.rotate(rotRad); // Spin with their localized body rotation while held
  } else {
    // Translate ball spatially along actual true Z-axis
    ctx.translate(centerX + state.ballOffsetX, state.ballY - state.ballCurrentHeight);
    ctx.rotate(state.ballOffsetX * 0.05); // Cosmetic spin based on horizontal slice 
  }

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
    ctx.lineWidth = Math.max(1, 2 * COURT_SCALE); // Scale thickness

    ctx.beginPath();
    const crossSize = 5 * COURT_SCALE; // Scale crosshair structural size
    ctx.moveTo(landX - crossSize, landY - crossSize);
    ctx.lineTo(landX + crossSize, landY + crossSize);
    ctx.moveTo(landX + crossSize, landY - crossSize);
    ctx.lineTo(landX - crossSize, landY + crossSize);
    ctx.stroke();

    ctx.restore();
  }

  // Draw the optimal 3D intercept prediction as a Green X
  if (state.ballVY !== 0) {
    let interceptTarget;
    if (state.ballVY > 0) {
      interceptTarget = { x: state.playerOffsetX, y: playerY - 15, z: state.playerElevateZ + 30 };
    } else {
      interceptTarget = { x: state.npcOffsetX, y: npcY + 15, z: state.npcElevateZ + 30 };
    }

    const bestPoint = calculateOptimalInterceptPoint(interceptTarget);

    // Only draw the visual if it securely predicts an approach within 1 second
    if (bestPoint.t > 0 && bestPoint.t < 1.0) {
      ctx.save();
      ctx.strokeStyle = 'rgba(46, 204, 113, 0.9)'; // Vibrant Green
      ctx.lineWidth = Math.max(1, 2 * COURT_SCALE); // Consistent with the Red X

      const hitX = centerX + bestPoint.x;
      // Map the 3D 'Z' altitude physically to the screen's vertical 'Y' axis to match the ball's rendering height exactly
      const hitY = bestPoint.y - bestPoint.z;

      ctx.beginPath();
      const hitSize = 5 * COURT_SCALE; // Consistent with the Red X
      ctx.moveTo(hitX - hitSize, hitY - hitSize);
      ctx.lineTo(hitX + hitSize, hitY + hitSize);
      ctx.moveTo(hitX + hitSize, hitY - hitSize);
      ctx.lineTo(hitX - hitSize, hitY + hitSize);
      ctx.stroke();

      ctx.restore();
    }
  }

  // Draw the yellow X for the Toss Target
  if (state.isServe && state.tossTarget) {
    ctx.save();
    ctx.strokeStyle = 'rgba(241, 196, 15, 0.9)'; // Bright Yellow
    ctx.lineWidth = Math.max(1, 2 * COURT_SCALE);

    const hitX = centerX + state.tossTarget.x;
    const hitY = state.tossTarget.y - state.tossTarget.z; // Match the visual altitude tracking!

    ctx.beginPath();
    const hitSize = 5 * COURT_SCALE;
    ctx.moveTo(hitX - hitSize, hitY - hitSize);
    ctx.lineTo(hitX + hitSize, hitY + hitSize);
    ctx.moveTo(hitX + hitSize, hitY - hitSize);
    ctx.lineTo(hitX - hitSize, hitY + hitSize);
    ctx.stroke();

    ctx.restore();
  }

  // 3. Render Player
  ctx.save();
  ctx.translate(centerX + state.playerOffsetX, playerY);
  ctx.scale(camera.zoom * COURT_SCALE, camera.zoom * COURT_SCALE);

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

  const transformP = { offsetX, offsetY, scale, centerX, baseRotation: state.playerRotation, elevateZ: state.playerElevateZ, targetStateObj: state.playerRacketPos, courtScale: COURT_SCALE };
  if (!window.isAdmin) drawRacket(ctx, playerLimbs, pAimPitch, pAimYaw, 0.3, transformP);
  characterManager.drawHumanoidUpperBody(ctx, playerCharacter, playerLimbs);
  if (window.isAdmin) drawRacket(ctx, playerLimbs, pAimPitch, pAimYaw, 0.3, transformP);
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
    const netY = COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height / 2;
    ctx.beginPath();
    ctx.moveTo(centerX + COURT_INNER_BOUNDS.x, netY);
    ctx.lineTo(centerX + COURT_INNER_BOUNDS.x + COURT_INNER_BOUNDS.width, netY);
    ctx.stroke();

    ctx.restore();
  }

  ctx.restore(); // Restore from world/camera zoom and offset

  // 4. Draw HUD Overlays (Mapped directly to absolute canvas container size)
  drawDiagnosticsOverlay(pAimPitch, pAimYaw);
}

/**
 * Renders the diagnostic graphs and HUD panels over the 3D court.
 * @param {number} pAimPitch - Raw mathematical aim pitch for the diagram context.
 * @param {number} pAimYaw - Raw mathematical aim yaw for the diagram context.
 */
function drawDiagnosticsOverlay(pAimPitch, pAimYaw) {
  // Trajectory Profile Panel (Bottom Center)
  if (state.trajectoryPoints.length > 1) {
    ctx.save();

    const panelW = 550; // Increased width for better read
    const panelH = 250; // Significantly taller graph
    const panelX = (canvas.width - panelW) / 2;
    const panelY = canvas.height - panelH - 20; // Float 20px off bottom

    // Draw Glassmorphic Backdrop
    ctx.fillStyle = 'rgba(25, 30, 40, 0.7)';
    ctx.beginPath();
    ctx.roundRect(panelX, panelY, panelW, panelH, 12);
    ctx.fill();
    ctx.strokeStyle = 'rgba(255, 255, 255, 0.2)';
    ctx.lineWidth = 1;
    ctx.stroke();

    // Map 3D points to 2D side-profile display box
    // Elapsed Time (T) maps to X axis, and Altitude (Z) maps to Y axis
    const pixelsPerSecond = 200; // Fixed horizontal plotting speed!
    const startT = state.trajectoryPoints[0].t;

    // Confine graph lines strictly inside the glassmorphic panel!
    ctx.save();
    ctx.beginPath();
    ctx.roundRect(panelX, panelY, panelW, panelH, 12);
    ctx.clip();

    // Draw curve
    ctx.beginPath();
    ctx.strokeStyle = '#f1c40f'; // Bright yellow
    ctx.lineWidth = 3;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';

    for (let i = 0; i < state.trajectoryPoints.length; i++) {
      const pt = state.trajectoryPoints[i];

      // Map to graph box horizontally by physical elapsed time
      const graphX = panelX + ((pt.t - startT) * pixelsPerSecond);
      // Map height inversely (subtract from bottom)
      const graphY = panelY + panelH - (pt.z * 0.9);

      if (i === 0) ctx.moveTo(graphX, graphY);
      else ctx.lineTo(graphX, graphY);
    }

    ctx.stroke();

    // Secondary line: Player's historical racket altitude tracking
    ctx.beginPath();
    ctx.strokeStyle = 'rgba(52, 152, 219, 0.7)'; // Transparent blue
    ctx.lineWidth = 2;
    for (let i = 0; i < state.trajectoryPoints.length; i++) {
      const pt = state.trajectoryPoints[i];
      const graphX = panelX + ((pt.t - startT) * pixelsPerSecond);
      const graphY = panelY + panelH - (pt.pZ * 0.9);

      if (i === 0) ctx.moveTo(graphX, graphY);
      else ctx.lineTo(graphX, graphY);
    }
    ctx.stroke();

    // Tertiary line: NPC's historical racket altitude tracking
    ctx.beginPath();
    ctx.strokeStyle = 'rgba(231, 76, 60, 0.7)'; // Transparent red
    ctx.lineWidth = 2;
    for (let i = 0; i < state.trajectoryPoints.length; i++) {
      const pt = state.trajectoryPoints[i];
      const graphX = panelX + ((pt.t - startT) * pixelsPerSecond);
      const graphY = panelY + panelH - (pt.nZ * 0.9);

      if (i === 0) ctx.moveTo(graphX, graphY);
      else ctx.lineTo(graphX, graphY);
    }
    ctx.stroke();

    // Draw current ball blip
    const lastPt = state.trajectoryPoints[state.trajectoryPoints.length - 1];
    const ballX = panelX + ((lastPt.t - startT) * pixelsPerSecond);
    const ballY = panelY + panelH - (lastPt.z * 0.9);

    ctx.fillStyle = '#f39c12';
    ctx.beginPath();
    ctx.arc(ballX, ballY, 5, 0, Math.PI * 2);
    ctx.fill();

    ctx.restore(); // Remove clipping mask

    ctx.fillStyle = 'rgba(255, 255, 255, 0.5)';
    ctx.font = '10px sans-serif';
    ctx.textAlign = 'center';
    ctx.fillText('SIDE PROFILE', panelX + panelW / 2, panelY + 15);

    // Racket Stance Diagnostic Widget
    const stanceW = 100;
    const stanceH = 100;
    const stanceX = panelX - stanceW - 10;
    const stanceY = panelY;

    // Background
    ctx.fillStyle = 'rgba(25, 30, 40, 0.7)';
    ctx.beginPath();
    ctx.roundRect(stanceX, stanceY, stanceW, stanceH, 12);
    ctx.fill();
    ctx.strokeStyle = 'rgba(255, 255, 255, 0.2)';
    ctx.lineWidth = 1;
    ctx.stroke();

    // Title
    ctx.fillStyle = 'rgba(255, 255, 255, 0.5)';
    ctx.font = '10px sans-serif';
    ctx.fillText('RACKET STANCE', stanceX + stanceW / 2, stanceY + 15);

    // Racket Diagram
    const dCenterX = stanceX + stanceW / 2;
    const dCenterY = stanceY + stanceH / 2 + 5;

    ctx.save();
    ctx.translate(dCenterX, dCenterY);
    // 1st Person Perspective (Behind the player, looking net-ward):
    // If the racket sweeps right-to-left, yaw maps to screen X.
    // If the racket tilts up/down, pitch maps to screen Y.
    // The handle vector on screen maps to the perceived visual angle.
    let screenHandleX = Math.cos(pAimYaw) * Math.cos(pAimPitch);
    let screenHandleY = -Math.sin(pAimPitch); // -Y is Up on canvas

    let angleOnScreen = Math.atan2(screenHandleY, screenHandleX);
    ctx.rotate(angleOnScreen);

    // Foreshortening length modifier for extreme away/towards pointing
    let lengthMult = Math.sqrt(screenHandleX * screenHandleX + screenHandleY * screenHandleY);

    let rx = 30 * Math.max(0.1, lengthMult); // Length of head
    let ry = 20 * Math.max(0.1, Math.abs(1.0 - 0.3)); // Width of face

    // Handle length
    let handleL = 25 * Math.max(0.1, lengthMult);

    // Draw handle (along negative X so 0-angle points Right on canvas)
    ctx.fillStyle = '#2c3e50';
    ctx.fillRect(-(rx + handleL - 5), -3, handleL, 6);

    // Draw Face
    ctx.strokeStyle = '#e74c3c';
    ctx.lineWidth = 3;
    ctx.beginPath();
    ctx.ellipse(0, 0, rx, ry, 0, 0, Math.PI * 2);
    ctx.stroke();

    // Draw Cross Strings
    ctx.strokeStyle = 'rgba(236, 240, 241, 0.5)';
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(0, -ry + 2);
    ctx.lineTo(0, ry - 2);
    ctx.moveTo(-rx + 2, 0);
    ctx.lineTo(rx - 2, 0);
    ctx.stroke();

    ctx.restore();

    ctx.restore();
  }
}
