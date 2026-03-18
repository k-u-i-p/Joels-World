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
  player: {
    x: 0,
    y: 0,
    z: 0,
    rotation: 270,
    score: 0,
    movementDirection: { x: 1, y: 1 },
    racketPosition: { x: 0, y: 0, groundY: 0, z: 0, w: 1, h: 1, angle: 0 },
    legTimer: 0
  },
  npc: {
    x: 0,
    y: 0,
    z: 0,
    rotation: 90,
    score: 0,
    movementDirection: { x: 1, y: 1 },
    racketPosition: { x: 0, y: 0, groundY: 0, z: 0, w: 1, h: 1, angle: 0 },
    legTimer: 0,
    targetX: 0,
    targetY: COURT_INNER_BOUNDS.y - 10,
    hasTarget: false
  },
  ball: {
    x: 0,
    y: COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height / 2,
    z: 0,
    vx: BALL_SPEED * 0.7,
    vy: BALL_SPEED * 0.7,
    velocity: BALL_SPEED * 0.7,
    pitchAngle: 0
  },

  bounceCount: 0,
  resetting: false,
  resetDelayTimer: 0,
  rallyCount: 0,
  introPhase: 'walkToNet',
  introTimer: 0,
  nextServerIsPlayer: false,
  lastHitter: null,
  isServe: false,
  servePhase: 'idle', // 'idle', 'live'
  faults: 0,
  trajectoryPoints: [],
  totalElapsedTime: 0,
  trajectoryFrozen: false
};

// ==========================================
// UTILITIES & PURE FUNCTIONS
// ==========================================

/** Calculates player Y position including their vertical movement offset. */
function getPlayerY() {
  return PLAYER_BASE_Y + state.player.y;
}

/** Calculates NPC Y position including their vertical movement offset. */
function getNpcY() {
  return NPC_BASE_Y + state.npc.y;
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
  let simX = state.ball.x;
  let simY = state.ball.y;
  let simZ = state.ball.z;
  let simVX = state.ball.vx;
  let simVY = state.ball.vy;
  let simVZ = state.ball.velocity * Math.tan(state.ball.pitchAngle);

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
  return isPlayer ? state.player.racketPosition : state.npc.racketPosition;
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
  state.ball.velocity = Math.min(velocity, MAXIMUM_BALL_SPEED);
  state.bounceCount = 0;

  if (!state.isServe) {
    state.trajectoryPoints = []; // Clear history on physical strike during a live rally
  }

  state.trajectoryFrozen = false; // Unfreeze tracking

  const dx = targetX - state.ball.x;
  const dy = targetY - state.ball.y;
  const dist = Math.sqrt(dx * dx + dy * dy);

  // Parabolic Physics calculation establishing the necessary starting vertical Z velocity (vZ)
  let timeToTarget = dist / state.ball.velocity;

  // Cap the flight time to prevent extreme "moonball" lobs. 
  // If the target requires a longer flight, we forcefully drive the ball harder and flatter to reach it.
  const maxFlightTime = 1.3;
  if (timeToTarget > maxFlightTime) {
    timeToTarget = maxFlightTime;
    // Boost the 2D planar velocity to cover the distance in the compressed time frame
    state.ball.velocity = dist / timeToTarget;
  }

  let vZ = (0.5 * GRAVITY * timeToTarget * timeToTarget - state.ball.z) / timeToTarget;

  // Ensure the ball arcs high enough to clear the physical net structure if the target crosses the net
  const netY = COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height / 2;
  const crossesNet = (state.ball.y < netY && targetY > netY) || (state.ball.y > netY && targetY < netY);

  if (crossesNet) {
    // Rough estimation of how long it takes to reach the net
    const timeToNet = (Math.abs(netY - state.ball.y) / Math.abs(dy)) * timeToTarget;
    // Calculate the minimum Z-velocity needed to be exactly above NET_HEIGHT when t = timeToNet
    const requiredClearanceHeight = NET_HEIGHT + BALL_RADIUS + 5; // adding 5px buffer
    const minVZ = (requiredClearanceHeight - state.ball.z + 0.5 * GRAVITY * timeToNet * timeToNet) / timeToNet;

    // If the flat stroke calculations predict crashing into the net, boost the arc!
    // However, if the ball is hit very low to the ground, or driven very fast and flat, we reduce the "auto-clearance" assist
    // naturally allowing the ball to smash into the net!
    if (vZ < minVZ) {
      let assist = 1.0;

      // Hard flat shots resist upward correction
      if (state.ball.velocity > 250) assist -= 0.2;

      // Balls hit late/low to the ground are physically harder to scoop over the net
      if (state.ball.z < 20) assist -= 0.4;

      // Add slight organic variance (+/- 10%)
      assist = clamp(assist + (Math.random() * 0.2 - 0.1), 0, 1);

      vZ = vZ + (minVZ - vZ) * assist;
    }
  }

  // Derive new spatial pitch vector
  state.ball.pitchAngle = Math.atan2(vZ, state.ball.velocity);

  // Set normalized 2D movement planar slice
  state.ball.vx = (dx / dist) * state.ball.velocity;
  state.ball.vy = (dy / dist) * state.ball.velocity;
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
  state.player.x = state.serveSide * -serveOffset;
  state.player.y = 0;
  state.npc.x = state.serveSide * serveOffset;
  state.npc.y = 0;
  state.resetDelayTimer = 0;
  state.player.z = 0;
  state.npc.z = 0;
  state.npc.targetX = 0;
  state.npc.targetY = NPC_BASE_Y;
  state.resetting = false;

  // Start cinematic intro instead of immediately serving
  state.introPhase = 'walkToNet';
  state.introTimer = 0;
  // Place characters far back initially
  state.player.y = 30;
  state.npc.y = -30;
  // Put the ball somewhere hidden temporarily
  state.ball.z = -100;
  state.ball.vx = 0;
  state.ball.vy = 0;

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
 * Calculates a valid or purely random fault service box coordinate organically.
 */
function calculateServeTarget(isPlayer) {
  const box = state.activeServiceBox;
  if (!box) return { x: 0, y: 0 };

  if (Math.random() < 0.9) {
    const aimWide = Math.random() > 0.5;
    const safeLeft = box.minX + 15;
    const safeRight = box.maxX - 15;
    const safeY = isPlayer ? box.minY + 20 : box.maxY - 20;

    let tx = aimWide ? safeLeft : safeRight;
    let ty = safeY;

    tx += (Math.random() * 10 - 5);
    ty += (Math.random() * 10 - 5);
    return { x: tx, y: ty };
  } else {
    // 10% chance: Hit a fault!
    return {
      x: box.minX + Math.random() * (box.maxX - box.minX) + (Math.random() * 60 - 30),
      y: box.minY + Math.random() * (box.maxY - box.minY) + (isPlayer ? -40 : 40)
    };
  }
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

  state.lastHitter = playerServing ? 'player' : 'npc';

  // Wipe the graph array so the new serve correctly starts a blank trajectory chart
  state.trajectoryPoints = [];

  // Transition cleanly into the organic physics simulation!
  const sideDir = state.serveSide * (playerServing ? -1 : 1);
  const tossTarget = {
    x: (playerServing ? state.player.x : state.npc.x) + (sideDir * 20 * GAME_SCALE),
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
  state.tossTarget = tossTarget;

  // Physically start the ball strictly inside the pre-calculated left hand geometry over the baseline!
  state.ball.z = 25;

  const startX = playerServing ? state.player.x : state.npc.x;
  const startY = playerServing ? getPlayerY() : getNpcY();

  // Shift ball physically to the server body to prevent visual snapping
  state.ball.x = startX;
  state.ball.y = startY;

  // Calculate the physics required to apex perfectly at tossTarget.z
  const dz = Math.max(1, tossTarget.z - state.ball.z);
  const vZ = Math.sqrt(2 * GRAVITY * dz);
  const tApex = vZ / GRAVITY;

  // Assign planar velocity to span the horizontal gap exactly during tApex
  state.ball.vx = (tossTarget.x - startX) / tApex;
  state.ball.vy = (tossTarget.y - startY) / tApex;

  state.ball.velocity = Math.max(0.1, Math.sqrt(state.ball.vx * state.ball.vx + state.ball.vy * state.ball.vy));
  state.ball.pitchAngle = Math.atan2(vZ, state.ball.velocity);

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
  const currentScore = getTennisScore(state.player.score, state.npc.score);
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
    state.npc.score++;
  } else {
    state.player.score++;
  }

  // Clear faults for the next point
  state.faults = 0;

  const scoreData = getTennisScore(state.player.score, state.npc.score);
  if (scoreData.winner) {
    // Game won, reset points for the next game
    state.player.score = 0;
    state.npc.score = 0;
  }
  updateScoreboardDOM();

  state.nextServerIsPlayer = nextPlayerServing;
  // Always serve from Deuce (-1) on Even total points, Ad (1) on Odd total points
  state.serveSide = ((state.player.score + state.npc.score) % 2 === 0) ? -1 : 1;
  state.resetDelayTimer = 1.5; // Brief intermission before next serve
  if (state.rallyCount >= 4) {
    soundManager.playPooled('/media/clap.mp3', 0.8);
  }
}

function processRacketDeflections(playerRacketPos, npcRacketPos, visualBallY) {
  if (state.resetting) return;

  // Inner abstract helper to condense and document the dense spatial 3D bounds and boolean logic
  function evaluateHit(racketPos, isPlayer) {
    const dx = state.ball.x - racketPos.x;
    const dy = visualBallY - racketPos.y;
    const localDx = dx * Math.cos(-racketPos.angle) - dy * Math.sin(-racketPos.angle);
    const localDy = dx * Math.sin(-racketPos.angle) + dy * Math.cos(-racketPos.angle);

    const isCorrectDirection = isPlayer
      ? (state.ball.vy > 0 || (state.isServe && state.lastHitter === 'player'))
      : (state.ball.vy < 0 || (state.isServe && state.lastHitter === 'npc'));

    const isWithinReach = Math.abs(state.ball.y - racketPos.groundY) < 50;
    const isCorrectHeight = state.ball.z >= racketPos.z - 15 && state.ball.z <= racketPos.z + 50;

    // Strict Elliptical Intersection Boolean Matrix Check over standard Box Radius Check
    const isInHitbox = (Math.pow(localDx, 2) / Math.pow(racketPos.w + BALL_RADIUS, 2)) +
      (Math.pow(localDy, 2) / Math.pow(racketPos.h + BALL_RADIUS, 2)) <= 1;

    return isCorrectDirection && isWithinReach && isCorrectHeight && isInHitbox;
  }

  if (evaluateHit(playerRacketPos, true)) {
    let targetX = COURT_INNER_BOUNDS.x + Math.random() * COURT_INNER_BOUNDS.width;
    let targetY = COURT_INNER_BOUNDS.y + Math.random() * (COURT_INNER_BOUNDS.height / 2);
    let returnSpeed = state.ball.velocity * 1.05;

    if (state.isServe) {
      const serveTarget = calculateServeTarget(true);
      targetX = serveTarget.x;
      targetY = serveTarget.y;
      returnSpeed = BALL_SPEED * 0.8;
    } else {
      targetX += (state.ball.x - playerRacketPos.x) * 1.5; // Organic center hit variance
    }

    state.rallyCount++;
    state.lastHitter = 'player';
    state.bounceCount = 0; // Hitting the ball resets the bounce count
    state.isServe = false; // The rally is live!
    hitBallToTarget(targetX, targetY, returnSpeed);

    // Add random variance to volume and pitch for organic audio
    let soundP = soundManager.playPooled('/media/hit_tennis_ball.mp3', 0.7 + Math.random() * 0.5);
    soundP.setRate(0.85 + Math.random() * 0.3);

    state.ball.z = Math.max(10, state.ball.z); // Simulate ground strike lift 

  } else if (evaluateHit(npcRacketPos, false)) {
    let targetX = COURT_INNER_BOUNDS.x + Math.random() * COURT_INNER_BOUNDS.width;
    let targetY = COURT_INNER_BOUNDS.y + (COURT_INNER_BOUNDS.height / 2) + Math.random() * (COURT_INNER_BOUNDS.height / 2);
    let returnSpeed = state.ball.velocity * 1.1;

    if (state.isServe) {
      const serveTarget = calculateServeTarget(false);
      targetX = serveTarget.x;
      targetY = serveTarget.y;
      returnSpeed = BALL_SPEED * 0.65;
    } else {
      // NPC procedural aim application
      targetX = COURT_INNER_BOUNDS.x + (state.ball.x < 0 ? COURT_INNER_BOUNDS.width * 0.85 : COURT_INNER_BOUNDS.width * 0.15);
    }

    state.rallyCount++;
    state.lastHitter = 'npc';
    state.bounceCount = 0; // Hitting the ball resets bounce count
    state.isServe = false; // The rally is live!
    hitBallToTarget(targetX, targetY, returnSpeed);

    // Add random variance to volume and pitch for organic audio
    let soundN = soundManager.playPooled('/media/hit_tennis_ball2.mp3', 0.7 + Math.random() * 0.5);
    soundN.setRate(0.85 + Math.random() * 0.3);

    state.ball.z = Math.max(10, state.ball.z);
  }
}

/**
 * Drives character movement explicitly towards local offset coordinates.
 * Handles bounds, distance interpolation, vector math, and compass rotation!
 * 
 * @param {Object} charState - The character state tracking object (e.g. state.player)
 * @param {number} targetX - Destination X component. 
 * @param {number} targetY - Destination Y component (local offset).
 * @param {number} speed - The max velocity allowed this tick.
 * @returns {boolean} True if the character mathematically moved this frame.
 */
function moveCharacterToLocal(charState, targetX, targetY, speed) {
  const distX = targetX - charState.x;
  const distY = targetY - charState.y;
  let movedX = 0, movedY = 0;
  let moved = false;

  if (Math.abs(distX) > 2) {
    movedX = Math.sign(distX) * Math.min(speed, Math.abs(distX));
    charState.x += movedX;
    charState.movementDirection.x = Math.sign(movedX);
    moved = true;
  }

  if (Math.abs(distY) > 2) {
    movedY = Math.sign(distY) * Math.min(speed, Math.abs(distY));
    charState.y += movedY;
    charState.movementDirection.y = Math.sign(movedY);
    moved = true;
  }

  if (moved) {
    let targetRot = charState.rotation;
    if (movedX > 0 && movedY === 0) targetRot = 0;
    else if (movedX < 0 && movedY === 0) targetRot = 180;
    else if (movedX > 0 && movedY < 0) targetRot = 315;
    else if (movedX < 0 && movedY < 0) targetRot = 225;
    else if (movedX > 0 && movedY > 0) targetRot = 45;
    else if (movedX < 0 && movedY > 0) targetRot = 135;
    else if (movedX === 0 && movedY < 0) targetRot = 270;
    else if (movedX === 0 && movedY > 0) targetRot = 90;

    let shortest = ((targetRot - charState.rotation) + 540) % 360 - 180;
    charState.rotation += shortest * 0.2;
  }
  return moved;
}

/**
 * Handles the animated walk-to-net handshake sequence before serving begins.
 * @param {number} dt Delta time.
 */
function handleIntroSequence(dt) {
  if (state.introPhase === 'walkToNet') {
    const netY = COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height / 2;
    const targetPlayerY = netY + 25;
    const targetNpcY = netY - 25;

    const targetPlayerLocalY = targetPlayerY - PLAYER_BASE_Y;
    const targetNpcLocalY = targetNpcY - NPC_BASE_Y;

    const speed = PADDLE_SPEED * dt * 0.5;
    const pMoved = moveCharacterToLocal(state.player, 0, targetPlayerLocalY, speed);
    const nMoved = moveCharacterToLocal(state.npc, 0, targetNpcLocalY, speed);

    if (pMoved) state.player.legTimer += speed * 0.1;
    if (nMoved) state.npc.legTimer += speed * 0.1;

    // Face each other tightly
    state.player.rotation = 270;
    state.npc.rotation = 90;

    if (!pMoved && !nMoved) {
      state.introPhase = 'shakeHands';
      state.introTimer = 2.0; // 2 seconds of shaking hands
      state.player.legTimer = 0;
      state.npc.legTimer = 0;
    }
  } else if (state.introPhase === 'shakeHands') {
    state.introTimer -= dt;
    // Simulate hand shake by oscillating rotation slightly
    state.player.rotation = 270 + Math.sin(state.introTimer * 20) * 10;
    state.npc.rotation = 90 - Math.sin(state.introTimer * 20) * 10;

    if (state.introTimer <= 0) {
      state.introPhase = 'walkToBaseline';
    }
  } else if (state.introPhase === 'walkToBaseline') {
    const serveOffset = COURT_INNER_BOUNDS.width * 0.4;
    const targetPX = state.nextServerIsPlayer ? state.serveSide * serveOffset : state.serveSide * -serveOffset;
    const targetNX = state.nextServerIsPlayer ? state.serveSide * -serveOffset : state.serveSide * serveOffset;

    const speed = PADDLE_SPEED * dt * 0.6;
    const pMoved = moveCharacterToLocal(state.player, targetPX, 0, speed);
    const nMoved = moveCharacterToLocal(state.npc, targetNX, 0, speed);

    if (pMoved) {
      state.player.legTimer += speed * 0.1;
      state.player.rotation = 90; // Face away while walking back
    } else {
      state.player.rotation = 270; // Turn around when at baseline
    }

    if (nMoved) {
      state.npc.legTimer += speed * 0.1;
      state.npc.rotation = 270; // Face away while walking back
    } else {
      state.npc.rotation = 90; // Turn around when at baseline
    }

    if (!pMoved && !nMoved) {
      state.player.legTimer = 0;
      state.npc.legTimer = 0;
      state.introPhase = 'playing';
      serveBall(state.nextServerIsPlayer);
    }
  }
}

/**
 * Handles aim tracking, boundary logic, Z-leaps, and walk animation timers identically for characters.
 */
function processCharacter(charState, isPlayer, prevX, prevY, dt, charY) {
  // 1. Process Approach Proximities & Leaps
  const isApproaching = isPlayer ? (state.ball.vy > 0) : (state.ball.vy < 0);
  const distY = Math.abs(state.ball.y - charY);
  const zMult = clamp(1 - (distY / 80), 0, 1);
  
  if (isApproaching) {
    const requiredJump = Math.max(0, state.ball.z - 35);
    charState.z = clamp(requiredJump, 0, 70) * zMult;
  } else {
    charState.z = 0;
  }

  // 2. Procedural Auto-Aim tracking
  let aimYaw = Math.PI * 0.25;
  let aimPitch = 0.0;
  
  if (isApproaching || (state.isServe && state.lastHitter === (isPlayer ? 'player' : 'npc'))) {
    const intercept = calculateOptimalInterceptPoint({ x: charState.x, y: charY + (isPlayer ? -15 : 15), z: charState.z + 30 });
    const tracking = calculateAimAngles(charState.x, charState.z, intercept, isPlayer);
    aimYaw = tracking.aimYaw;
    aimPitch = tracking.aimPitch;
  }

  // 3. Enforce structural court bounds
  charState.x = clamp(charState.x, -PLAYABLE_HALF_WIDTH, PLAYABLE_HALF_WIDTH);
  if (isPlayer) {
    charState.y = clamp(charState.y, -(COURT_INNER_BOUNDS.height / 2 + 10), PLAYABLE_OVERSHOOT - 10);
  } else {
    charState.y = clamp(charState.y, -(PLAYABLE_OVERSHOOT - 10), (COURT_INNER_BOUNDS.height / 2) + 10);
  }

  // 4. Update organic animation loops (walk cycles)
  const charMoved = (charState.x !== prevX) || (charState.y !== prevY);
  const strideSpeed = (isPlayer ? PADDLE_SPEED : NPC_SPEED) * dt * 0.05;

  if (charMoved) {
    charState.legTimer += strideSpeed;
  } else if (charState.legTimer > 0) {
    const phase = charState.legTimer % Math.PI;
    if (phase > 0.1 && phase < Math.PI - 0.1) {
      charState.legTimer += strideSpeed;
    } else {
      charState.legTimer = 0;
    }
  }

  return { yaw: aimYaw, pitch: aimPitch, moved: charMoved };
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
    handleIntroSequence(dt);
    return; // Block the rest of the game update loop during intro
  }

  const playerY = getPlayerY();
  const npcY = getNpcY();

  // Track coordinates BEFORE movement processes run
  const prevPlayerX = state.player.x;
  const prevPlayerY = state.player.y;

  // 1. Process Player Inputs & Movement

  if (state.resetting) {
    const serveOffset = COURT_INNER_BOUNDS.width * 0.4;
    const targetX = state.nextServerIsPlayer ? state.serveSide * serveOffset : state.serveSide * -serveOffset;
    if (!moveCharacterToLocal(state.player, targetX, 0, PADDLE_SPEED * dt)) {
      const diffP = 270 - state.player.rotation;
      state.player.rotation += ((diffP + 540) % 360 - 180) * 0.2;
    }
  } else {
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
        state.player.x += playerMoveX;
        state.player.movementDirection.x = Math.sign(playerMoveX);
      }
      if (playerMoveY !== 0) {
        state.player.y += playerMoveY;
        state.player.movementDirection.y = Math.sign(playerMoveY);
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
    const diffP = targetPlayerRotation - state.player.rotation;
    // Normalize shortest path
    let shortestP = (diffP + 540) % 360 - 180;
    state.player.rotation += shortestP * 0.2;
  }

  const pAim = processCharacter(state.player, true, prevPlayerX, prevPlayerY, dt, playerY);
  const pAimYaw = pAim.yaw;
  const pAimPitch = pAim.pitch;
  const playerMoved = pAim.moved;

  // 2. Process Simple AI NPC Movement
  const prevNpcX = state.npc.x;
  const prevNpcY = state.npc.y;

  if (state.resetting) {
    const serveOffset = COURT_INNER_BOUNDS.width * 0.4;
    const targetX = state.nextServerIsPlayer ? state.serveSide * -serveOffset : state.serveSide * serveOffset;
    if (!moveCharacterToLocal(state.npc, targetX, 0, NPC_SPEED * dt)) {
      const diffN = 90 - state.npc.rotation;
      state.npc.rotation += ((diffN + 540) % 360 - 180) * 0.2;
    }
  } else {
    if (state.ball.vy < 0) {
      if (!state.npc.hasTarget) {
        // Because the NPC physically holds the racket in their right hand, but faces DOWN (90 degrees) when swinging,
        // their racket sweeps dynamically from their screen-left (-X) towards their center body over the SWING_DURATION arc.
        // Therefore, the NPC must mathematically target slightly to the screen-right (+X) of the ball's incoming trajectory.
        const approximatedRacketOffset = 40 * camera.zoom * GAME_SCALE;
        // Predict trajectory where ball lands based on vertical physics
        let predictedLandY = NPC_BASE_Y;
        let tLand = 0;
        const vZTargetCheck = state.ball.velocity * Math.tan(state.ball.pitchAngle);
        const det = vZTargetCheck * vZTargetCheck + 2 * GRAVITY * state.ball.z;
        if (det >= 0) {
          tLand = (vZTargetCheck + Math.sqrt(det)) / GRAVITY;
          predictedLandY = state.ball.y + state.ball.vy * tLand;
        }

        // Position NPC physically behind the ball's bounce depth, clamped to their playable half-court area
        const targetY = clamp(predictedLandY - (15 * GAME_SCALE), NPC_BASE_Y - PLAYABLE_OVERSHOOT + 10, COURT_INNER_BOUNDS.y + 10);

        // Calculate raw X trajectory directly from physics air-time!
        let absoluteTargetX = state.ball.x + (state.ball.vx * tLand);

        state.npc.targetX = clamp(absoluteTargetX + approximatedRacketOffset, -PLAYABLE_HALF_WIDTH + 10, PLAYABLE_HALF_WIDTH - 10);
        state.npc.targetY = targetY;
        state.npc.hasTarget = true;
      }
    } else {
      // Ball is moving away toward player, reset to center gracefully
      state.npc.targetX = 0;
      state.npc.targetY = NPC_BASE_Y;
      state.npc.hasTarget = false;
    }

    const targetLocalY = state.npc.targetY - NPC_BASE_Y;
    if (!moveCharacterToLocal(state.npc, state.npc.targetX, targetLocalY, NPC_SPEED * dt)) {
      const diffN = 90 - state.npc.rotation;
      state.npc.rotation += ((diffN + 540) % 360 - 180) * 0.2;
    }
  }

  const nAim = processCharacter(state.npc, false, prevNpcX, prevNpcY, dt, npcY);
  const nAimYaw = nAim.yaw;
  const nAimPitch = nAim.pitch;
  const npcMoved = nAim.moved;

  // Ensure logical collision trackers properly pull the latest bounds exactly here
  const playerRacketPos = getRacketWorldPos(true);
  const npcRacketPos = getRacketWorldPos(false);
  const visualBallY = state.ball.y - state.ball.z;

  if (state.resetting && !playerMoved && !npcMoved) {
    if (state.resetDelayTimer > 0) {
      state.resetDelayTimer -= dt;
    } else {
      serveBall(state.nextServerIsPlayer);
    }
    // Allow physics payload to execute while anticipating serve!
  }

  // 5. 3D Spatial Ball Physics Processing
  const vZ = state.ball.velocity * Math.tan(state.ball.pitchAngle);

  // Elevate ball
  state.ball.z += vZ * dt;
  // Rotate velocity downward due to continuous gravity
  state.ball.pitchAngle = Math.atan2(vZ - GRAVITY * dt, state.ball.velocity);

  // Handle floor bounce
  if (state.ball.z < 0) {
    state.ball.z = 0;
    state.bounceCount++;

    if (state.bounceCount === 1 && !state.resetting && state.lastHitter) {
      const minX = COURT_INNER_BOUNDS.x;
      const maxX = COURT_INNER_BOUNDS.x + COURT_INNER_BOUNDS.width;
      const minY = COURT_INNER_BOUNDS.y;
      const maxY = COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height;
      const netY = COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height / 2;

      const inBoundsX = state.ball.x >= minX && state.ball.x <= maxX;
      let validBounce = false;

      if (state.isServe) {
        // Enforce rigid Service Box intersections!
        const box = state.activeServiceBox;
        if (state.ball.x >= box.minX && state.ball.x <= box.maxX && state.ball.y >= box.minY && state.ball.y <= box.maxY) {
          validBounce = true;
          state.isServe = false; // Valid serve, rally is now organically open
        }
      } else {
        // Enforce total half-court bounds!
        if (state.lastHitter === 'player') {
          validBounce = inBoundsX && state.ball.y >= minY && state.ball.y <= netY; // NPC's half
        } else if (state.lastHitter === 'npc') {
          validBounce = inBoundsX && state.ball.y >= netY && state.ball.y <= maxY; // Player's half
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
      if (state.ball.y > COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height / 2) {
        triggerPointReset(true);  // Bounced twice on Player's side -> NPC scored
      } else {
        triggerPointReset(false); // Bounced twice on NPC's side -> Player scored
      }
    }

    // Reflect vertical kinetic energy mathematically and absorb 40% (0.6 multiplier) into the court
    state.ball.pitchAngle = Math.atan2(Math.abs(vZ - GRAVITY * dt) * 0.6, state.ball.velocity);
  }

  // 6. Handle Planar XY movement and Structural Net Collision
  state.ball.x += state.ball.vx * dt;

  const prevBallY = state.ball.y;
  state.ball.y += state.ball.vy * dt;

  // Progress global point timer monotonically (freeze while waiting for serves to start)
  if (state.resetDelayTimer <= 0) state.totalElapsedTime += dt;

  // Explicitly permit tracking during live gameplay
  if (minigameActive && !state.trajectoryFrozen) {
    state.trajectoryPoints.push({
      x: state.ball.x,
      y: state.ball.y,
      t: state.totalElapsedTime,
      z: state.ball.z,
      pZ: playerRacketPos.z + 25, // Align to physical shoulder height (25px above floor)
      nZ: npcRacketPos.z + 25
    });
    // Keep array from growing infinitely if the ball gets stuck out of bounds
    if (state.trajectoryPoints.length > 300) state.trajectoryPoints.shift();
  }

  // Check if ball mathematically crossed the Y-center of the court during this frame
  const netY = COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height / 2;
  if ((prevBallY < netY && state.ball.y >= netY) || (prevBallY >= netY && state.ball.y < netY)) {
    if (state.ball.z < NET_HEIGHT) {
      // Ball hit the physical net structure!
      state.ball.vy *= -0.3; // Rebound weakly back towards the hitter
      state.ball.velocity *= 0.3; // Kill most kinetic energy
      state.ball.y = netY + Math.sign(state.ball.vy) * 5; // Snap off the net
    }
  }

  // 7. Racket Deflections
  processRacketDeflections(playerRacketPos, npcRacketPos, visualBallY);

  // 8. Bounds Checking / Out Checks
  // Point resolving (scoring logic) automatically triggers walkback
  if (!state.resetting) {
    const isOffScreenX = Math.abs(state.ball.x) > PLAYABLE_HALF_WIDTH + 150;
    const courtMaxY = COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height;
    const isOffScreenY = state.ball.y < COURT_INNER_BOUNDS.y - 150 || state.ball.y > courtMaxY + 150;

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
  ctx.translate(centerX + state.npc.x, npcY);
  ctx.scale(camera.zoom * COURT_SCALE, camera.zoom * COURT_SCALE);

  // Drop shadow
  ctx.fillStyle = 'rgba(0, 0, 0, 0.25)';
  ctx.beginPath();
  ctx.arc(2, 4, 14, 0, Math.PI * 2);
  ctx.fill();

  ctx.rotate(state.npc.rotation * (Math.PI / 180));

  const npcLimbs = getLimbs(state.npc.legTimer, state.npc.movementDirection.x, state.npc.movementDirection.y, nRightArmX, nRightArmY);

  characterManager.drawShoe(ctx, npcLimbs.leftLegEndX, npcLimbs.leftLegEndY, npc.shoeColor || '#1a252f', true);
  characterManager.drawShoe(ctx, npcLimbs.rightLegEndX, npcLimbs.rightLegEndY, npc.shoeColor || '#1a252f', false);

  // Evaluate visual translation mapping spatial Z elevation to the World -Y axis natively
  ctx.rotate(-state.npc.rotation * (Math.PI / 180));
  ctx.translate(0, -state.npc.z / camera.zoom);
  ctx.rotate(state.npc.rotation * (Math.PI / 180));

  const transformN = { offsetX, offsetY, scale, centerX, baseRotation: state.npc.rotation, elevateZ: state.npc.z, targetStateObj: state.npc.racketPosition, courtScale: COURT_SCALE };
  if (!window.isAdmin) drawRacket(ctx, npcLimbs, nAimPitch, nAimYaw, 0.3, transformN);
  characterManager.drawHumanoidUpperBody(ctx, { ...npc, rotation: state.npc.rotation, x: 0, y: 0 }, npcLimbs);
  if (window.isAdmin) drawRacket(ctx, npcLimbs, nAimPitch, nAimYaw, 0.3, transformN);
  ctx.restore();

  // 2. Render Ball Physics Elements (Drawn before player to prevent top-overlap)

  // Ball's vertical Ground Shadow
  ctx.save();
  ctx.fillStyle = 'rgba(0, 0, 0, 0.25)';
  ctx.beginPath();
  // Shrink shadow exponentially based on elevation altitude
  const shadowRadius = Math.max(2 * COURT_SCALE, (BALL_RADIUS * 2 - state.ball.z * 0.05) * COURT_SCALE);
  ctx.arc(centerX + state.ball.x, state.ball.y, shadowRadius, 0, Math.PI * 2);
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
    const baseRotation = isPlayerServing ? state.player.rotation : state.npc.rotation;
    const rotRad = baseRotation * (Math.PI / 180);
    const limbs = isPlayerServing ? playerLimbs : npcLimbs;
    const serverX = isPlayerServing ? state.player.x : state.npc.x;
    const serverY = isPlayerServing ? getPlayerY() : getNpcY();
    const serverZ = isPlayerServing ? state.player.z : state.npc.z;

    // Map local leftArm coordinates exactly how `drawHumanoidUpperBody` does natively
    const armWorldX = (limbs.leftArmX * Math.cos(rotRad) - limbs.leftArmY * Math.sin(rotRad)) * camera.zoom * COURT_SCALE;
    const armWorldY = (limbs.leftArmX * Math.sin(rotRad) + limbs.leftArmY * Math.cos(rotRad)) * camera.zoom * COURT_SCALE;

    ctx.translate(centerX + serverX + armWorldX, serverY + armWorldY - serverZ);
    ctx.rotate(rotRad); // Spin with their localized body rotation while held
  } else {
    // Translate ball spatially along actual true Z-axis
    ctx.translate(centerX + state.ball.x, state.ball.y - state.ball.z);
    ctx.rotate(state.ball.x * 0.05); // Cosmetic spin based on horizontal slice 
  }

  ctx.fillText('🎾', 0, 0);
  ctx.restore();

  // Calculate and render crosshairs onto the destination surface exactly where ball's geometry will collide
  const vZTargetCheck = state.ball.velocity * Math.tan(state.ball.pitchAngle);
  const det = vZTargetCheck * vZTargetCheck + 2 * GRAVITY * state.ball.z;
  let tLand = 0;
  if (det >= 0) {
    tLand = (vZTargetCheck + Math.sqrt(det)) / GRAVITY;
  }
  const landX = centerX + state.ball.x + state.ball.vx * tLand;
  const landY = state.ball.y + state.ball.vy * tLand;

  // Only show the landing X to non-admins if the ball is moving towards the player
  if (window.isAdmin || state.ball.vy > 0) {
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
  if (state.ball.vy !== 0) {
    let interceptTarget;
    if (state.ball.vy > 0) {
      interceptTarget = { x: state.player.x, y: playerY - 15, z: state.player.z + 30 };
    } else {
      interceptTarget = { x: state.npc.x, y: npcY + 15, z: state.npc.z + 30 };
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
  ctx.translate(centerX + state.player.x, playerY);
  ctx.scale(camera.zoom * COURT_SCALE, camera.zoom * COURT_SCALE);

  // Drop shadow
  ctx.fillStyle = 'rgba(0, 0, 0, 0.25)';
  ctx.beginPath();
  ctx.arc(2, 4, 14, 0, Math.PI * 2);
  ctx.fill();

  ctx.rotate(state.player.rotation * (Math.PI / 180));
  let playerCharacter = window.init.myCharacter;
  const playerLimbs = getLimbs(state.player.legTimer, state.player.movementDirection.x, state.player.movementDirection.y, pRightArmX, pRightArmY);
  playerCharacter.rotation = state.player.rotation;
  characterManager.drawShoe(ctx, playerLimbs.leftLegEndX, playerLimbs.leftLegEndY, playerCharacter.shoeColor || '#1a252f', true);
  characterManager.drawShoe(ctx, playerLimbs.rightLegEndX, playerLimbs.rightLegEndY, playerCharacter.shoeColor || '#1a252f', false);

  ctx.rotate(-state.player.rotation * (Math.PI / 180));
  ctx.translate(0, -state.player.z / camera.zoom);
  ctx.rotate(state.player.rotation * (Math.PI / 180));

  const transformP = { offsetX, offsetY, scale, centerX, baseRotation: state.player.rotation, elevateZ: state.player.z, targetStateObj: state.player.racketPosition, courtScale: COURT_SCALE };
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
