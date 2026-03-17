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
  isServe: false,
  faults: 0,
  trajectoryPoints: [],
  trajectoryFrozen: false,
  playerRacketPos: { x: 0, y: 0, groundY: 0, z: 0, w: 1, h: 1, angle: 0 },
  npcRacketPos: { x: 0, y: 0, groundY: 0, z: 0, w: 1, h: 1, angle: 0 },
  playerAimYaw: 0,
  playerAimPitch: 0,
  npcAimYaw: 0,
  playerSwingAnim: { pitch: 0.1, yaw: Math.PI * 0.35, roll: 0.3, reach: 4 },
  npcSwingAnim: { pitch: 0.1, yaw: Math.PI * 0.35, roll: 0.3, reach: 4 }
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
  let reach = 4;

  if (timer > 0) {
    const progress = 1 - (timer / SWING_DURATION); // 0.0 to 1.0
    // Transition from completely cocked back (right) into a fast forward stroke crossing the body (left)
    const sweepStart = Math.PI * 0.4;
    const sweepEnd = -Math.PI * 0.6;
    let baseYaw = sweepStart + (sweepEnd - sweepStart) * progress;

    yaw = baseYaw + aimYaw;

    // Vertical Swoop: Stroke from low to high
    const pitchStart = aimPitch - 0.4;
    const pitchEnd = aimPitch + 0.4;
    pitch = pitchStart + (pitchEnd - pitchStart) * progress;

    roll = Math.max(0.1, Math.abs(Math.cos(progress * Math.PI)));
    reach = 4 + Math.sin(progress * Math.PI) * 12; // Fully extend dynamically through the swing arc center
  } else if (isApproaching) {
    yaw = Math.PI * 0.4 + aimYaw;
    pitch = aimPitch - 0.4; // Cocked lower ready to swoop up
    roll = 0.8;
    reach = 4; // Cocked back elbow bent
  } else {
    yaw = Math.PI * 0.35; // Idle rotated backwards slightly
    pitch = (state.resetting || !!state.introPhase) ? -1.0 : 0.1; // Point racket deeply down towards the ground between points or during intro
    roll = 0.3;
    reach = 4; // Relaxed elbow bent
  }

  return { pitch, yaw, roll, reach };
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
  state.trajectoryPoints = []; // Clear history on physical strike
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
  camera.y = COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height / 2;
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
  state.isServe = true;
  const playerY = getPlayerY();

  state.ballOffsetX = playerServing ? state.playerOffsetX : state.npcOffsetX;
  state.ballY = playerServing ? playerY : getNpcY();

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
  state.ballCurrentHeight = 40; // Characters throw the ball to waist height for serve
  let serveVelocity = playerServing ? BALL_SPEED * 0.8 : BALL_SPEED * 0.65;
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
 * Core logical tick, executing Player Input, AI calculations, 3D Physics logic, and collision.
 * 
 * @param {number} dt - Delta time in seconds since last frame.
 */
function update(dt) {
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

  // Calculate true physical target states
  const targetPlayerSwing = getSwingState(state.playerSwingTimer, isPlayerApproaching, state.playerAimYaw, state.playerAimPitch);
  const targetNpcSwing = getSwingState(state.npcSwingTimer, isNpcApproaching, state.npcAimYaw, state.npcAimPitch);

  // Animate the actual arm states towards the target geometries using dt-scaled lerp.
  // Snap instantly to the procedural stroke arc during active swing (timer > 0) to preserve precise hit collision physics.
  const pLerp = state.playerSwingTimer > 0 ? 1.0 : clamp(12 * dt, 0, 1);
  state.playerSwingAnim.pitch += (targetPlayerSwing.pitch - state.playerSwingAnim.pitch) * pLerp;
  state.playerSwingAnim.yaw += (targetPlayerSwing.yaw - state.playerSwingAnim.yaw) * pLerp;
  state.playerSwingAnim.roll += (targetPlayerSwing.roll - state.playerSwingAnim.roll) * pLerp;
  state.playerSwingAnim.reach += (targetPlayerSwing.reach - state.playerSwingAnim.reach) * pLerp;

  const nLerp = state.npcSwingTimer > 0 ? 1.0 : clamp(12 * dt, 0, 1);
  state.npcSwingAnim.pitch += (targetNpcSwing.pitch - state.npcSwingAnim.pitch) * nLerp;
  state.npcSwingAnim.yaw += (targetNpcSwing.yaw - state.npcSwingAnim.yaw) * nLerp;
  state.npcSwingAnim.roll += (targetNpcSwing.roll - state.npcSwingAnim.roll) * nLerp;
  state.npcSwingAnim.reach += (targetNpcSwing.reach - state.npcSwingAnim.reach) * nLerp;

  // Compute Z-axis leaps only for high lobs that exceed standing arm reach (> 40px altitude)
  const playerDistY = Math.abs(state.ballY - playerY);
  const playerZMult = clamp(1 - (playerDistY / 80), 0, 1);
  if (isPlayerApproaching || state.playerSwingTimer > 0) {
    // Only leave the ground if the ball is too high to simply reach
    const requiredJump = Math.max(0, state.ballCurrentHeight - 35);
    state.playerElevateZ = clamp(requiredJump, 0, 70) * playerZMult;
  } else {
    state.playerElevateZ = 0;
  }

  const npcDistY = Math.abs(state.ballY - npcY);
  const npcZMult = clamp(1 - (npcDistY / 80), 0, 1);
  if (isNpcApproaching || state.npcSwingTimer > 0) {
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
    // Procedurally Auto-Aim the Player's racket to physically intercept the ball's 3D coordinates!
    if (state.playerSwingTimer > 0) {
      // Calculate Yaw (lateral reach)
      const diffX = state.ballOffsetX - state.playerOffsetX;
      state.playerAimYaw = clamp(diffX * 0.015, -Math.PI / 4, Math.PI / 4);

      // Calculate Pitch (vertical reach)
      // Player's shoulder is roughly 20px off the ground.
      const trueZDiff = state.ballCurrentHeight - 20;
      state.playerAimPitch = clamp(trueZDiff * 0.015, -Math.PI / 3, Math.PI / 4);
    } else {
      // Relax back to neutral when not actively swinging
      state.playerAimYaw *= 0.8;
      state.playerAimPitch *= 0.8;
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
    if (state.npcSwingTimer > 0) {
      // Calculate Yaw (lateral reach) Note: NPC faces opposite direction so diff is inverted
      const diffX = state.npcOffsetX - state.ballOffsetX;
      state.npcAimYaw = clamp(diffX * 0.015, -Math.PI / 4, Math.PI / 4);

      // Calculate Pitch (vertical reach)
      const trueZDiff = state.ballCurrentHeight - 20;
      state.npcAimPitch = clamp(trueZDiff * 0.015, -Math.PI / 3, Math.PI / 4);
    } else {
      state.npcAimYaw *= 0.8;
      state.npcAimPitch *= 0.8;
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

  if (minigameActive && !state.trajectoryFrozen) {
    state.trajectoryPoints.push({ x: state.ballOffsetX, y: state.ballY, z: state.ballCurrentHeight });
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

    // Standard baseline rally acceleration
    let returnSpeed = state.ballCurrentVelocity * 1.05;

    // Apply slight directional spin off center hits manually controlled by the player leaning into the ball
    const isLeaningLeft = inputManager.isPressed('ArrowLeft') || inputManager.isPressed('KeyA') || (inputManager.keys.TouchMove && inputManager.joystickVector.x < -0.3);
    const isLeaningRight = inputManager.isPressed('ArrowRight') || inputManager.isPressed('KeyD') || (inputManager.keys.TouchMove && inputManager.joystickVector.x > 0.3);

    if (isLeaningLeft) {
      targetX = COURT_INNER_BOUNDS.x + COURT_INNER_BOUNDS.width * 0.15 + (Math.random() * 20); // Aim left sideline
      returnSpeed *= 1.2; // Power boost!
    } else if (isLeaningRight) {
      targetX = COURT_INNER_BOUNDS.x + COURT_INNER_BOUNDS.width * 0.85 - (Math.random() * 20); // Aim right sideline
      returnSpeed *= 1.2; // Power boost!
    } else {
      // Organic center hit variance
      const hitOffset = state.ballOffsetX - playerRacketPos.x;
      targetX += hitOffset * 1.5;
    }

    const isAimingUp = inputManager.isPressed('ArrowUp') || inputManager.isPressed('KeyW') || (inputManager.keys.TouchMove && inputManager.joystickVector.y < -0.3);
    const isAimingDown = inputManager.isPressed('ArrowDown') || inputManager.isPressed('KeyS') || (inputManager.keys.TouchMove && inputManager.joystickVector.y > 0.3);

    if (isAimingUp) {
      targetY = COURT_INNER_BOUNDS.y + 20; // Aim deep lob
      returnSpeed *= 0.9;
    } else if (isAimingDown) {
      targetY = COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height / 2 - 20; // Aim short smash
      returnSpeed *= 1.3;
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
    if (state.ballOffsetX < 0) targetX = COURT_INNER_BOUNDS.x + COURT_INNER_BOUNDS.width * 0.85; // Hit away
    else targetX = COURT_INNER_BOUNDS.x + COURT_INNER_BOUNDS.width * 0.15;

    const returnSpeed = state.ballCurrentVelocity * 1.1;
    state.rallyCount++;
    state.lastHitter = 'npc';
    state.bounceCount = 0; // Hitting the ball resets bounce count
    state.isServe = false; // The rally is live!
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

  const npcSwing = state.npcSwingAnim;
  const playerSwing = state.playerSwingAnim;

  const pArmL = playerSwing.reach * Math.cos(playerSwing.pitch);
  const pRightArmX = 4 + pArmL * Math.cos(playerSwing.yaw);
  const pRightArmY = 14 + pArmL * Math.sin(playerSwing.yaw);

  const nArmL = npcSwing.reach * Math.cos(npcSwing.pitch);
  const nRightArmX = 4 + nArmL * Math.cos(npcSwing.yaw);
  const nRightArmY = 14 + nArmL * Math.sin(npcSwing.yaw);

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
  drawRacket(ctx, npcLimbs, npcSwing.pitch, npcSwing.yaw, npcSwing.roll, transformN);
  characterManager.drawHumanoidUpperBody(ctx, { ...npc, rotation: state.npcRotation, x: 0, y: 0 }, npcLimbs);
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
    const netY = COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height / 2;
    ctx.beginPath();
    ctx.moveTo(centerX + COURT_INNER_BOUNDS.x, netY);
    ctx.lineTo(centerX + COURT_INNER_BOUNDS.x + COURT_INNER_BOUNDS.width, netY);
    ctx.stroke();

    ctx.restore();
  }

  ctx.restore(); // Restore from world/camera zoom and offset

  // 4. Draw HUD Overlays (Mapped directly to absolute canvas container size)

  // Trajectory Profile Panel (Bottom Center)
  if (state.trajectoryPoints.length > 1) {
    ctx.save();

    const panelW = 400;
    const panelH = 100;
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
    // Distance (Y-Depth) maps to X axis, and Altitude (Z) maps to Y axis

    // Auto-scale the graph viewport based on the total distance the ball has traveled since hit
    const startY = state.trajectoryPoints[0].y;
    const endY = state.trajectoryPoints[state.trajectoryPoints.length - 1].y;
    const totalDistance = Math.max(100, Math.abs(endY - startY)); // Prevent divide by zero on idle

    // Draw Net marker
    const netY = COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height / 2;
    const netProfileX = panelX + (Math.abs(netY - Math.min(startY, endY)) / totalDistance) * panelW;
    if (netProfileX > panelX && netProfileX < panelX + panelW) {
      ctx.strokeStyle = 'rgba(255, 255, 255, 0.3)';
      ctx.lineDashOffset = 0;
      ctx.setLineDash([4, 4]);
      ctx.beginPath();
      ctx.moveTo(netProfileX, panelY + panelH);
      ctx.lineTo(netProfileX, panelY + panelH - (NET_HEIGHT * 0.5)); // Scale net height representation
      ctx.stroke();
      ctx.setLineDash([]);
    }

    // Draw curve
    ctx.beginPath();
    ctx.strokeStyle = '#f1c40f'; // Bright yellow
    ctx.lineWidth = 3;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';

    for (let i = 0; i < state.trajectoryPoints.length; i++) {
      const pt = state.trajectoryPoints[i];

      // Calculate progress percentage through total distance
      const distProgress = Math.abs(pt.y - startY) / totalDistance;

      // Map to graph box width
      const graphX = panelX + (distProgress * panelW);
      // Map height inversely (subtract from bottom)
      const graphY = panelY + panelH - (pt.z * 0.5);

      if (i === 0) ctx.moveTo(graphX, graphY);
      else ctx.lineTo(graphX, graphY);
    }

    ctx.stroke();

    // Draw current ball blip
    const lastPt = state.trajectoryPoints[state.trajectoryPoints.length - 1];
    const ballX = panelX + (Math.abs(lastPt.y - startY) / totalDistance * panelW);
    const ballY = panelY + panelH - (lastPt.z * 0.5);

    ctx.fillStyle = '#f39c12';
    ctx.beginPath();
    ctx.arc(ballX, ballY, 5, 0, Math.PI * 2);
    ctx.fill();

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
    const pSwing = state.playerSwingAnim;
    const dCenterX = stanceX + stanceW / 2;
    const dCenterY = stanceY + stanceH / 2 + 5;

    ctx.save();
    ctx.translate(dCenterX, dCenterY);
    // 1st Person Perspective:
    // - Roll translates directly to 2D graphic rotation (twisting wrist side to side)
    // - Pitch translates to vertical squash (tilting racket forward/backward)
    // - Yaw translates to a slight horizontal squash (turning racket left/right)
    ctx.rotate((pSwing.roll - 1) * Math.PI); // Roll is 0.5 to 1.5, map 1.0 to 0 degrees rotation

    // Calculate ellipse boundaries based on dynamic physics stance
    const pitchMult = Math.max(0.1, Math.abs(Math.sin(pSwing.pitch)));
    const yawMult = Math.max(0.1, Math.abs(Math.cos(pSwing.yaw)));

    const rx = 20 * yawMult;
    const ry = 30 * pitchMult;

    // Draw handle
    ctx.fillStyle = '#2c3e50';
    ctx.fillRect(-3, ry + 2, 6, 25);

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
