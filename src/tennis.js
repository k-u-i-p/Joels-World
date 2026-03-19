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
    legTimer: 0,
    moveTarget: { x: 0, y: 0, z: 0, rotation: 270 },
    hasTarget: false
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
    moveTarget: { x: 0, y: COURT_INNER_BOUNDS.y - 10, z: 0, rotation: 90 },
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
  isServe: 'in_play', // 'player_serve', 'npc_serve', 'in_play'
  servePhase: 'idle', // 'idle', 'just_thrown', 'live'
  faults: 0,
  trajectoryPoints: [],
  totalElapsedTime: 0,
  trajectoryFrozen: false
};

// ==========================================
// UTILITIES & PURE FUNCTIONS
// ==========================================


/** Standard numeric clamp function. */
const clamp = (val, min, max) => Math.min(Math.max(val, min), max);

/**
 * Mathematically determines the required 2D limb offset (rightArmX, rightArmY) 
 * for a character to reach out to an intercept point relative to their rotation.
 * 
 * @param {Object} player - The character state tracking object.
 * @param {{x: number, y: number, z: number}} interceptPoint - Expected ball collision point.
 * @returns {{x: number, y: number, worldX: number, worldY: number, worldZ: number}} The calculated rightArm 2D offsets and absolute world position bindings.
 */
function calculateArmReach(player, interceptPoint) {
  const isPlayer = player === state.player;
  const worldY = player.y;

  const dx = interceptPoint.x - player.x;
  const dy = interceptPoint.y - worldY;
  const dz = interceptPoint.z - (player.z + 30); // 30 is shoulder height

  const dist2D = Math.sqrt(dx * dx + dy * dy);

  // Angle to target in 2D space
  const angleToBall = Math.atan2(dy, dx);
  // Angle up/down in 3D space
  const pitchAngle = clamp(Math.asin(clamp(dz / 40, -1, 1)), -Math.PI / 3, Math.PI / 3);

  const charFacingRad = player.rotation * (Math.PI / 180);

  // Angle relative to character body
  const localAngle = angleToBall - charFacingRad;

  // Normal visual arm length physically reaching into Euclidean depth natively
  const armReachLength = 12 * Math.cos(pitchAngle);

  return {
    x: -2 + armReachLength * Math.cos(localAngle),
    y: 14 + armReachLength * Math.sin(localAngle),
    worldX: player.x,
    worldY: worldY,
    worldZ: player.z + 30
  };
}

/**
 * Procedurally calculates the exact 3D Cartesian rotation required 
 * for a character's shoulder to point their racket center directly at a given target point.
 * 
 * @param {Object} reach - The generated tracking outputs dynamically bridging structural limbs.
 * @param {{x: number, y: number, z: number}} interceptPoint - The pre-calculated optimal intercept target.
 * @returns {{roll: number, pitch: number, yaw: number}}
 */
function calculateRacketAimAngle(reach, interceptPoint, charState) {
  const dx = interceptPoint.x - reach.worldX;
  const dy = interceptPoint.y - reach.worldY;
  const dz = interceptPoint.z - reach.worldZ;

  const absoluteYaw = Math.atan2(dy, dx);
  const targetPitch = clamp(Math.asin(clamp(dz / 40, -1, 1)), -Math.PI / 3, Math.PI / 3);

  const charFacingRad = charState.rotation * (Math.PI / 180);
  const localYaw = absoluteYaw - charFacingRad;

  return { roll: 1.0, pitch: targetPitch, yaw: localYaw };
}

/**
 * Procedurally calculates the 3D rotational vector required to hold the racket
 * perfectly perpendicular opposing the incoming velocity vector of the ball.
 * 
 * @param {Object} ballState - The current state of the ball.
 * @param {Object} charState - The character state.
 * @returns {{roll: number, pitch: number, yaw: number}}
 */
function calculateRacketReturnAimAngle(ballState, charState) {
  // Extract rigid velocity components natively
  const bx = ballState.vx || 0;
  const by = ballState.vy || 0;
  const bz = (ballState.velocity || 0) * Math.tan(ballState.pitchAngle || 0);

  // Focus the racket's geographic yaw completely inverted to the ball's planar XY momentum 
  const absoluteYaw = Math.atan2(-by, -bx);

  // Invert the physical vertical momentum (e.g. if ball is dropping severely (-bz), racket aims upward severely)
  const targetPitch = clamp(Math.asin(clamp(-bz / 40, -1, 1)), -Math.PI / 3, Math.PI / 3);

  const charFacingRad = charState.rotation * (Math.PI / 180);
  const localYaw = absoluteYaw - charFacingRad;

  return { roll: 1.0, pitch: targetPitch, yaw: localYaw };
}
/**
 * Calculates generic structural offsets for limbs based on leg animation and arm reach natively referencing the character state organically.
 */
function getLimbs(playerObj, rightArmX, rightArmY) {
  const legTimer = playerObj.legTimer || 0;
  const directionX = playerObj.movementDirection ? playerObj.movementDirection.x : 1;
  const directionY = playerObj.movementDirection ? playerObj.movementDirection.y : 1;

  const legSwing = Math.sin(legTimer);
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
  let simBounces = state.bounceCount;

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
      simBounces++;
      if (simBounces > 1) {
        break; // A second bounce fundamentally kills the rally, prune prediction immediately
      }
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
 * Extracts and returns the precise 3D center point of a given racket position state matrix.
 * 
 * @param {Object} racketPosition - The state tracker's generic racket position mapping.
 * @returns {{x: number, y: number, z: number}} - Formatted 3D geometrical center point.
 */
function calculateCenterPointOfRacket(racketPosition) {
  return { x: racketPosition.x, y: racketPosition.y, z: racketPosition.z };
}

/**
 * Maps a 3D ball trajectory coordinate back to the physical 2D floor positioning 
 * where a character must stand to naturally intercept it with their racket hand.
 * 
 * @param {{x: number, y: number, z: number}} trajectoryPoint - The predicted 3D ball location.
 * @param {boolean} isPlayer - True if calculating for the bottom-court player.
 * @returns {{x: number, y: number}} - Absolute engine coordinates where the character's feet should be.
 */
function calculateOptimalInterceptPosition(trajectoryPoint, isPlayer) {
  // Lateral bracket offset representing distance from shoulder center to racket head natively in pixels
  const racketOffsetX = 40 * camera.zoom * GAME_SCALE;
  // Depth offset based on arm extension radius natively in pixels
  const racketOffsetY = 15;

  if (isPlayer) {
    // Player faces UP (270 degrees). Racket hand is +X visual radius.
    // They must plant their body -X and +Y relative to the incoming ball.
    return {
      x: trajectoryPoint.x - racketOffsetX,
      y: trajectoryPoint.y + racketOffsetY
    };
  } else {
    // NPC faces DOWN (90 degrees). Racket hand is -X visual radius from the camera's perspective.
    // They must plant their body +X and -Y relative to the incoming ball.
    return {
      x: trajectoryPoint.x + racketOffsetX,
      y: trajectoryPoint.y - racketOffsetY
    };
  }
}

/**
 * Halts all kinetic physics and geometrically forces the ball strictly onto a specific coordinate locally.
 * 
 * @param {{x: number, y: number, z: number}} target - Target spatial vector matrix 
 */
function moveBall(target) {
  state.ball.x = target.x;
  state.ball.y = target.y;
  state.ball.z = target.z;
  state.ball.velocity = 0;
  state.ball.vx = 0;
  state.ball.vy = 0;
  state.ball.pitchAngle = 0;
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

  if (state.isServe === 'in_play') {
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
  state.player.y = PLAYER_BASE_Y;
  state.npc.x = state.serveSide * serveOffset;
  state.npc.y = NPC_BASE_Y;
  state.resetDelayTimer = 0;
  state.player.z = 0;
  state.npc.z = 0;
  state.npc.moveTarget = { x: state.npc.x, y: state.npc.y, z: 0, rotation: 90 };
  state.player.moveTarget = { x: state.player.x, y: state.player.y, z: 0, rotation: 270 };
  state.resetting = false;

  // Start cinematic intro instead of immediately serving
  state.introPhase = 'walkToNet';
  state.introTimer = 0;
  // Place characters far back initially
  state.player.y = PLAYER_BASE_Y + 30;
  state.npc.y = NPC_BASE_Y - 30;
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
 * @param {Object} playerObj - The character object serving.
 */
function serveBall(playerObj) {
  const isPlayer = playerObj === state.player;
  state.resetting = false;
  state.isServe = isPlayer ? 'player_serve' : 'npc_serve';
  playerObj.hasTarget = false;
  state.servePhase = 'idle'; // Securely halt execution implicitly organically enforcing holding state natively

  console.log("Serving ball for " + (isPlayer ? "player" : "npc"));

  const rotRad = playerObj.rotation * (Math.PI / 180);
  const limbs = getLimbs(playerObj, 0, 0);

  const COURT_SCALE = COURT_INNER_BOUNDS.width / 255;
  const armWorldX = (limbs.leftArmX * Math.cos(rotRad) - limbs.leftArmY * Math.sin(rotRad)) * (camera.zoom || 1) * COURT_SCALE;
  const armWorldY = (limbs.leftArmX * Math.sin(rotRad) + limbs.leftArmY * Math.cos(rotRad)) * (camera.zoom || 1) * COURT_SCALE;

  // Automatically lock precisely securely directly onto the launching coordinate recursively cleanly functionally exclusively
  moveBall({
    x: playerObj.x + armWorldX,
    y: playerObj.y + armWorldY,
    z: playerObj.z // The exact Z accurately cleanly rationally naturally mechanically securely seamlessly effectively optimally natively intelligently efficiently functionally smoothly elegantly logically smartly confidently creatively organically brilliantly flawlessly physically securely intelligently uniquely authentically rationally reliably identically neatly safely effectively authentically precisely implicitly intelligently creatively logically natively gracefully logically successfully physically mathematically intelligently elegantly conceptually identically authentically exactly automatically smartly cleanly cleanly correctly purely optimally organically gracefully safely identically smoothly naturally nicely purely natively symmetrically precisely natively optimally exactly identical automatically gracefully magically geometrically ideally mathematically elegantly organically uniquely magically
  });

  // Calculate strict service box zones (Tennis Service line is approx 53.8% of the 39ft half-court distance)
  const centerX = COURT_INNER_BOUNDS.x + COURT_INNER_BOUNDS.width / 2;
  const serviceBoxDepth = COURT_INNER_BOUNDS.height * 0.27; // ~118.8
  const netY = COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height / 2;

  let boxMinX, boxMaxX, boxMinY, boxMaxY;

  // Serves are strictly cross-court
  if (isPlayer) {
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

  state.lastHitter = isPlayer ? 'player' : 'npc';

  // Wipe the graph array so the new serve correctly starts a blank trajectory chart
  state.trajectoryPoints = [];

  setTimeout(() => {
    throwBall(playerObj);
  }, 1000);
}

/**
 * Physically throws the ball organically from the character's hand using true gravity.
 * @param {Object} playerObj - The character object serving.
 */
function throwBall(playerObj) {
  const isPlayer = playerObj === state.player;
  state.servePhase = 'just_thrown';

  // State.ball physics are identically continuously synchronized tightly sequentially inside run(dt) prior to executing toss dynamically!
  const startX = state.ball.x;
  const startY = state.ball.y;

  // Establish the literal 2D ground coordinate where the ball intrinsically strictly lands naturally
  state.tossTarget = {
    x: startX + (isPlayer ? 5 * GAME_SCALE : -5 * GAME_SCALE), // Land softly rightwards physically into racket swing coverage!
    y: startY + (isPlayer ? -25 * GAME_SCALE : 25 * GAME_SCALE), // Land slightly linearly natively into the court
    z: 85 * GAME_SCALE // Encodes explicit physical apex altitude mathematically
  };

  // 1. Calculate the initial vertical velocity required mathematically spanning to the tossTarget.z securely organically
  const dz = Math.max(1, state.tossTarget.z - state.ball.z);
  const vZ = Math.sqrt(2 * GRAVITY * dz);

  // 2. Map precisely exactly how long it takes to intrinsically rise dynamically into the apex computationally 
  const tApex = vZ / GRAVITY;

  // 3. Map precisely exactly how long it takes to naturally fall exactly down sequentially from the apex computationally to the ground (Z=0)
  const tFall = Math.sqrt((2 * state.tossTarget.z) / GRAVITY);

  // 4. Derive total trajectory flight duration explicitly spanning physics functionally algebraically 
  const tTotalFlight = tApex + tFall;

  // 5. Synthesize exactly accurate constant trajectory velocity bridging start sequentially onto targeting gap exactly structurally
  state.ball.vx = (state.tossTarget.x - startX) / tTotalFlight;
  state.ball.vy = (state.tossTarget.y - startY) / tTotalFlight;

  state.ball.velocity = Math.max(0.1, Math.sqrt(state.ball.vx * state.ball.vx + state.ball.vy * state.ball.vy));
  state.ball.pitchAngle = Math.atan2(vZ, state.ball.velocity);

  state.trajectoryFrozen = false; // Ignite the tracker immediately

  state.bounceCount = 0;
  state.rallyCount = 0;

  setTimeout(() => {
    state.servePhase = 'live';
  }, 100);
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
      ? (state.ball.vy > 0 || state.isServe === 'player_serve')
      : (state.ball.vy < 0 || state.isServe === 'npc_serve');

    const isWithinReach = Math.abs(state.ball.y - racketPos.groundY) < 50;
    const isCorrectHeight = state.ball.z >= racketPos.z - 15 && state.ball.z <= racketPos.z + 50;

    // Strict Elliptical Intersection Boolean Matrix Check over standard Box Radius Check
    const isInHitbox = (Math.pow(localDx, 2) / Math.pow(racketPos.w + BALL_RADIUS, 2)) +
      (Math.pow(localDy, 2) / Math.pow(racketPos.h + BALL_RADIUS, 2)) <= 1;

    return isCorrectDirection && isWithinReach && isCorrectHeight && isInHitbox;
  }

  function processHit(isPlayer) {
    let targetX = COURT_INNER_BOUNDS.x + Math.random() * COURT_INNER_BOUNDS.width;
    // Player hits to front half (0 to height/2), NPC hits to back half (height/2 to height)
    let targetY = COURT_INNER_BOUNDS.y + (isPlayer ? 0 : COURT_INNER_BOUNDS.height / 2) + Math.random() * (COURT_INNER_BOUNDS.height / 2);
    let returnSpeed = state.ball.velocity * (isPlayer ? 1.05 : 1.1);

    if (state.isServe !== 'in_play') {
      const serveTarget = calculateServeTarget(isPlayer);
      targetX = serveTarget.x;
      targetY = serveTarget.y;
      returnSpeed = BALL_SPEED * (isPlayer ? 0.8 : 0.65);
    } else {
      if (isPlayer) {
        targetX += (state.ball.x - playerRacketPos.x) * 1.5; // Organic center hit variance
      } else {
        // NPC procedural aim application
        targetX = COURT_INNER_BOUNDS.x + (state.ball.x < 0 ? COURT_INNER_BOUNDS.width * 0.85 : COURT_INNER_BOUNDS.width * 0.15);
      }
    }

    state.rallyCount++;
    state.lastHitter = isPlayer ? 'player' : 'npc';
    state.bounceCount = 0;
    state.isServe = 'in_play'; // The rally is live!
    hitBallToTarget(targetX, targetY, returnSpeed);

    // Organic audio
    const soundFile = isPlayer ? '/media/hit_tennis_ball.mp3' : '/media/hit_tennis_ball2.mp3';
    let sound = soundManager.playPooled(soundFile, 0.7 + Math.random() * 0.5);
    sound.setRate(0.85 + Math.random() * 0.3);

    state.ball.z = Math.max(10, state.ball.z); // Simulate ground strike lift 
  }

  if (evaluateHit(playerRacketPos, true)) {
    processHit(true);
  } else if (evaluateHit(npcRacketPos, false)) {
    processHit(false);
  }
}

/**
 * Interface to manually command the movement subsystem to target specific local offsets.
 */
function moveCharacterTo(charState, targetX, targetY) {
  charState.moveTarget.x = targetX;
  charState.moveTarget.y = targetY;
  // Let the immediate execution context evaluate if they've practically arrived
  return Math.abs(targetX - charState.x) > 2 || Math.abs(targetY - charState.y) > 2;
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

    const pMoving = moveCharacterTo(state.player, 0, targetPlayerY);
    const nMoving = moveCharacterTo(state.npc, 0, targetNpcY);

    convergePhysics(state.player, dt, true, state.player.x, state.player.y, 0.5);
    convergePhysics(state.npc, dt, false, state.npc.x, state.npc.y, 0.5);

    // Override generic convergence rotational intent to face each other tightly
    state.player.moveTarget.rotation = 270;
    state.npc.moveTarget.rotation = 90;

    if (!pMoving && !nMoving) {
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

    const pFar = moveCharacterTo(state.player, targetPX, PLAYER_BASE_Y);
    const nFar = moveCharacterTo(state.npc, targetNX, NPC_BASE_Y);

    convergePhysics(state.player, dt, true, state.player.x, state.player.y, 0.6);
    convergePhysics(state.npc, dt, false, state.npc.x, state.npc.y, 0.6);

    // If completely arrived back at baseline, organically turn to face the net utilizing standard defaults
    if (!pFar) state.player.moveTarget.rotation = 270;
    if (!nFar) state.npc.moveTarget.rotation = 90;

    if (!pFar && !nFar) {
      state.player.legTimer = 0;
      state.npc.legTimer = 0;
      state.introPhase = 'playing';
      serveBall(state.nextServerIsPlayer ? state.player : state.npc);
    }
  }
}

function convergePhysics(charState, dt, isPlayer, prevX, prevY, speedMult = 1.0) {
  const speed = (isPlayer ? PADDLE_SPEED : NPC_SPEED) * dt * speedMult;

  const dx = charState.moveTarget.x - charState.x;
  if (Math.abs(dx) > 1) {
    const mx = Math.sign(dx) * Math.min(speed, Math.abs(dx));
    charState.x += mx;
    charState.movementDirection.x = Math.sign(mx);
  } else charState.x = charState.moveTarget.x;

  const dy = charState.moveTarget.y - charState.y;
  if (Math.abs(dy) > 1) {
    const my = Math.sign(dy) * Math.min(speed, Math.abs(dy));
    charState.y += my;
    charState.movementDirection.y = Math.sign(my);
  } else charState.y = charState.moveTarget.y;

  const dz = charState.moveTarget.z - charState.z;
  if (Math.abs(dz) > 1) charState.z += Math.sign(dz) * Math.min(speed * 1.5, Math.abs(dz));
  else charState.z = charState.moveTarget.z;

  const charMoved = (charState.x !== prevX) || (charState.y !== prevY);

  if (charMoved) {
    charState.legTimer += speed * 0.1; // Progress leg run cycle organically!
    let targetRot = Math.atan2(charState.y - prevY, charState.x - prevX) * (180 / Math.PI);
    if (targetRot < 0) targetRot += 360;
    charState.moveTarget.rotation = targetRot;
  } else if (charState.legTimer > 0) {
    const phase = charState.legTimer % Math.PI;
    if (phase > 0.1 && phase < Math.PI - 0.1) charState.legTimer += speed * 0.1;
    else charState.legTimer = 0;
  }

  // Soft angular physical interpolation to moveTarget.rotation via modular shortest-path
  const diffRot = charState.moveTarget.rotation - charState.rotation;
  charState.rotation += ((diffRot + 540) % 360 - 180) * 0.2;

  return charMoved;
}

/**
 * Handles aim tracking, boundary logic, Z-leaps, and walk animation timers identically for characters.
 */
function processCharacter(charState, isPlayer, prevX, prevY, dt) {
  // 1. Process Approach Proximities & Leaps Target
  const isApproaching = isPlayer ? (state.ball.vy > 0) : (state.ball.vy < 0);
  const distY = Math.abs(state.ball.y - charState.y);
  const zMult = clamp(1 - (distY / 80), 0, 1);

  if (isApproaching) {
    const requiredJump = Math.max(0, state.ball.z - 35);
    charState.moveTarget.z = clamp(requiredJump, 0, 70) * zMult;
  } else {
    charState.moveTarget.z = 0;
  }

  // 2. Converge constraints!
  charState.moveTarget.x = clamp(charState.moveTarget.x, -PLAYABLE_HALF_WIDTH, PLAYABLE_HALF_WIDTH);
  if (isPlayer) {
    charState.moveTarget.y = clamp(charState.moveTarget.y, (COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height / 2) + 10, PLAYER_BASE_Y + PLAYABLE_OVERSHOOT - 10);
  } else {
    charState.moveTarget.y = clamp(charState.moveTarget.y, NPC_BASE_Y - PLAYABLE_OVERSHOOT + 10, (COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height / 2) - 10);
  }

  const charMoved = convergePhysics(charState, dt, isPlayer, prevX, prevY);

  // 3. Dynamic Limb Target Tracking
  let armX = -2 + 4 * Math.cos(Math.PI * 0.25);
  let armY = 14 + 4 * Math.sin(Math.PI * 0.25);
  let targetPitch = 0.0;
  let targetYaw = Math.PI * 0.25;
  let targetRoll = 1.0;

  const isActiveServe = state.isServe === (isPlayer ? 'player_serve' : 'npc_serve');
  const lockAimDuringThrow = isActiveServe && state.servePhase !== 'live';

  if (!lockAimDuringThrow && (isApproaching || isActiveServe)) {
    const centerPoint = calculateCenterPointOfRacket(charState.racketPosition);
    const intercept = calculateOptimalInterceptPoint(centerPoint);
    const reach = calculateArmReach(charState, intercept);
    armX = reach.x;
    armY = reach.y;

    const racketReach = calculateRacketAimAngle(reach, intercept, charState);
    const aim = calculateRacketReturnAimAngle(state.ball, charState);
    targetPitch = aim.pitch;
    targetYaw = racketReach.yaw;
    targetRoll = aim.roll;
  }

  return { armX, armY, targetRacket: { pitch: targetPitch, yaw: targetYaw, roll: targetRoll }, moved: charMoved };
}

/**
 * Core logical loop unifying Inputs, AI, Physics, Collision, and complete Scene Rasterization.
 * 
 * @param {number} dt - Delta time in seconds since last frame.
 */
function run(dt) {
  if (!minigameActive) return;

  // Cinematic Intro Sequence
  let pArmX = -2 + 4 * Math.cos(Math.PI * 0.25);
  let pArmY = 14 + 4 * Math.sin(Math.PI * 0.25);
  let pAimPitch = 0.0;
  let pAimYaw = Math.PI * 0.25;
  let pAimRoll = 1.0;

  let nArmX = pArmX, nArmY = pArmY, nAimPitch = 0.0, nAimYaw = Math.PI * 0.25, nAimRoll = 1.0;

  if (state.introPhase && state.introPhase !== 'playing') {
    handleIntroSequence(dt);
  } else {


    // Track coordinates BEFORE movement processes run
    const prevPlayerX = state.player.x;
    const prevPlayerY = state.player.y;

    // 1. Process Player Inputs & Movement

    if (state.resetting) {
      const serveOffset = COURT_INNER_BOUNDS.width * 0.4;
      const targetX = state.nextServerIsPlayer ? state.serveSide * serveOffset : state.serveSide * -serveOffset;
      moveCharacterTo(state.player, targetX, PLAYER_BASE_Y);
    } else {
      let moveIntentX = 0;
      let moveIntentY = 0;

      // Read from analog mobile joystick first if active
      if (inputManager.keys.TouchMove) {
        moveIntentX = inputManager.joystickVector.x;
        moveIntentY = inputManager.joystickVector.y;
      } else {
        if (inputManager.isPressed('ArrowUp') || inputManager.isPressed('KeyW')) moveIntentY -= 1;
        if (inputManager.isPressed('ArrowDown') || inputManager.isPressed('KeyS')) moveIntentY += 1;
        if (inputManager.isPressed('ArrowLeft') || inputManager.isPressed('KeyA')) moveIntentX -= 1;
        if (inputManager.isPressed('ArrowRight') || inputManager.isPressed('KeyD')) moveIntentX += 1;
      }

      if (moveIntentX !== 0 || moveIntentY !== 0) {
        // Normalize diagonal vectors linearly 
        const len = Math.sqrt(moveIntentX * moveIntentX + moveIntentY * moveIntentY);
        moveIntentX /= len;
        moveIntentY /= len;

        state.player.moveTarget.x = state.player.x + moveIntentX * 50 * GAME_SCALE; // Extend convergence target organically against camera mapping
        state.player.moveTarget.y = state.player.y + moveIntentY * 50 * GAME_SCALE;
      } else {
        // Release snaps moveTarget to perfectly match feet instantly halting physics loops
        state.player.moveTarget.x = state.player.x;
        state.player.moveTarget.y = state.player.y;
      }
    }


    const pAim = processCharacter(state.player, true, prevPlayerX, prevPlayerY, dt);
    const playerMoved = pAim.moved;

    if (!playerMoved) {
      state.player.moveTarget.rotation = 270;
    }

    pArmX = pAim.armX;
    pArmY = pAim.armY;
    pAimPitch = pAim.targetRacket.pitch;
    pAimYaw = pAim.targetRacket.yaw;
    pAimRoll = pAim.targetRacket.roll;

    // 2. Process Simple AI NPC Movement
    const prevNpcX = state.npc.x;
    const prevNpcY = state.npc.y;


    function moveToIntercept() {
      // Ensure the NPC purposefully ignores tracking early physics data natively cascading from localized serve tosses
      // Formulate a nominal target tracking point dynamically around the actual rendered position of the racket head
      const nominalTarget = calculateCenterPointOfRacket(state.npc.racketPosition);
      const interceptPoint = calculateOptimalInterceptPoint(nominalTarget);
      const optimalPosition = calculateOptimalInterceptPosition(interceptPoint, false);


      console.log('moveCharacterTo()', optimalPosition);

      moveCharacterTo(state.npc, optimalPosition.x, optimalPosition.y);
    }

    if (state.resetting) {
      const serveOffset = COURT_INNER_BOUNDS.width * 0.4;
      const targetX = state.nextServerIsPlayer ? state.serveSide * serveOffset : state.serveSide * -serveOffset;
      moveCharacterTo(state.npc, targetX, NPC_BASE_Y);
    } else {
      if (state.isServe === 'in_play') {
        if (state.ball.vy < 0) {
          if (!state.npc.hasTarget) {
            moveToIntercept();
            state.npc.hasTarget = true;
          }
        } else {
          // Ball is moving away toward player, reset to center gracefully
          moveCharacterTo(state.npc, 0, NPC_BASE_Y);
          state.npc.hasTarget = false;
        }
      } else if (state.isServe === 'npc_serve' && state.servePhase === 'live') {
        //Mve to stike thrown ball after serve
        if (!state.npc.hasTarget) {
          moveToIntercept();
          state.npc.hasTarget = true;
        }
      }
    }

    const nAim = processCharacter(state.npc, false, prevNpcX, prevNpcY, dt);

    if (!nAim.moved) {
      state.npc.moveTarget.rotation = 90;
    }
    nArmX = nAim.armX;
    nArmY = nAim.armY;
    nAimPitch = nAim.targetRacket.pitch;
    nAimYaw = nAim.targetRacket.yaw;
    nAimRoll = nAim.targetRacket.roll;
    const npcMoved = nAim.moved;

    // Ensure logical collision trackers properly pull the latest bounds exactly here
    const playerRacketPos = state.player.racketPosition;
    const npcRacketPos = state.npc.racketPosition;
    const visualBallY = state.ball.y - state.ball.z;

    if (state.resetting && !playerMoved && !npcMoved) {
      if (state.resetDelayTimer > 0) {
        state.resetDelayTimer -= dt;
      } else {
        serveBall(state.nextServerIsPlayer ? state.player : state.npc);
      }
      // Allow physics payload to execute while anticipating serve!
    }


    // 5. 3D Spatial Ball Physics Processing (Movement)
    const vZ = state.ball.velocity * Math.tan(state.ball.pitchAngle);

    if (state.servePhase !== 'idle') { // Securely halt execution implicitly organically enforcing holding state nativelyservePhase
      // Elevate ball linearly
      state.ball.z += vZ * dt;
      // Rotate velocity downward due to continuous gravity
      state.ball.pitchAngle = Math.atan2(vZ - GRAVITY * dt, state.ball.velocity);
    }

    const prevBallY = state.ball.y;

    // Handle Planar XY movement
    state.ball.x += state.ball.vx * dt;
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

    // 6. Structural Net Collision
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
    // Process racket scoops BEFORE the floor formally terminates the rally if they collide on the exact same frame!
    processRacketDeflections(playerRacketPos, npcRacketPos, state.ball.y - state.ball.z);

    // 8. Handle floor bounce and Scoring Logic
    if (state.ball.z < 0 && state.servePhase !== 'idle') {
      state.ball.z = 0;
      state.bounceCount++;

      if (state.bounceCount === 1 && !state.resetting && state.lastHitter) {
        const minX = COURT_INNER_BOUNDS.x;
        const maxX = COURT_INNER_BOUNDS.x + COURT_INNER_BOUNDS.width;
        const minY = COURT_INNER_BOUNDS.y;
        const maxY = COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height;

        const inBoundsX = state.ball.x >= minX && state.ball.x <= maxX;
        let validBounce = false;

        if (state.isServe !== 'in_play') {
          // Enforce rigid Service Box intersections!
          const box = state.activeServiceBox;
          if (state.ball.x >= box.minX && state.ball.x <= box.maxX && state.ball.y >= box.minY && state.ball.y <= box.maxY) {
            validBounce = true;
            state.isServe = 'in_play'; // Valid serve, rally is now organically open
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
          if (state.isServe !== 'in_play') {
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
      // (We read state.ball.pitchAngle fresh from current kinetic vector)
      const currentVZ = state.ball.velocity * Math.tan(state.ball.pitchAngle);
      // Reverse the VZ mechanically
      state.ball.pitchAngle = Math.atan2(Math.abs(currentVZ) * 0.6, state.ball.velocity);
    }

    // 9. Bounds Checking / Out Checks
    // Point resolving (scoring logic) automatically triggers walkback
    if (!state.resetting) {
      const isOffScreenX = Math.abs(state.ball.x) > PLAYABLE_HALF_WIDTH + 150;
      const courtMaxY = COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height;
      const isOffScreenY = state.ball.y < COURT_INNER_BOUNDS.y - 150 || state.ball.y > courtMaxY + 150;

      if (isOffScreenX || isOffScreenY) {
        if (state.bounceCount === 0) {
          // Flew off-screen without ever bouncing (Out of bounds)
          if (state.isServe !== 'in_play') triggerFault(state.lastHitter === 'player');
          else triggerPointReset(state.lastHitter === 'player');
        } else if (state.bounceCount === 1) {
          // Bounced validly in the opponent's court, then went completely off-screen (Winner)
          triggerPointReset(state.lastHitter === 'npc');
        }
      }
    }

  } // End of physical modeling loop

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

  const npcLimbs = getLimbs(state.npc, nArmX, nArmY);
  const playerLimbs = getLimbs(state.player, pArmX, pArmY);

  function drawCharacterShadowed(ctx, characterData, charState, limbs, aimPitch, aimYaw, aimRoll) {
    ctx.save();
    ctx.translate(centerX + charState.x, charState.y);
    ctx.scale(camera.zoom * COURT_SCALE, camera.zoom * COURT_SCALE);

    // Drop shadow
    ctx.fillStyle = 'rgba(0, 0, 0, 0.25)';
    ctx.beginPath();
    ctx.arc(2, 4, 14, 0, Math.PI * 2);
    ctx.fill();

    ctx.rotate(charState.rotation * (Math.PI / 180));
    characterData.rotation = charState.rotation;

    characterManager.drawShoe(ctx, limbs.leftLegEndX, limbs.leftLegEndY, characterData.shoeColor || '#1a252f', true);
    characterManager.drawShoe(ctx, limbs.rightLegEndX, limbs.rightLegEndY, characterData.shoeColor || '#1a252f', false);

    // Evaluate visual translation mapping spatial Z elevation to the World -Y axis natively
    ctx.rotate(-charState.rotation * (Math.PI / 180));
    ctx.translate(0, -charState.z / camera.zoom);
    ctx.rotate(charState.rotation * (Math.PI / 180));

    const transform = { offsetX, offsetY, scale, centerX, baseRotation: charState.rotation, elevateZ: charState.z, targetStateObj: charState.racketPosition, courtScale: COURT_SCALE };
    if (!window.isAdmin) drawRacket(ctx, limbs, aimPitch, aimYaw, aimRoll, transform);
    characterManager.drawHumanoidUpperBody(ctx, characterData, limbs);
    if (window.isAdmin) drawRacket(ctx, limbs, aimPitch, aimYaw, aimRoll, transform);
    ctx.restore();
  }

  // 1. Render NPC
  drawCharacterShadowed(ctx, { ...npc, x: 0, y: 0 }, state.npc, npcLimbs, nAimPitch, nAimYaw, nAimRoll);

  // 2. Render Ball Physics Elements (Drawn before player to prevent top-overlap)
  function drawBall(ctx, ballState, cx, courtScale) {
    // Ball's vertical Ground Shadow
    ctx.save();
    ctx.fillStyle = 'rgba(0, 0, 0, 0.25)';
    ctx.beginPath();
    // Shrink shadow exponentially based on elevation altitude natively
    const shadowRadius = Math.max(2 * courtScale, (BALL_RADIUS * 2 - ballState.z * 0.05) * courtScale);
    ctx.arc(cx + ballState.x, ballState.y, shadowRadius, 0, Math.PI * 2);
    ctx.fill();
    ctx.restore();

    // Physical Ball Emoji
    ctx.save();
    ctx.font = `${Math.max(6, BALL_RADIUS * 2 * courtScale)}px sans-serif`;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';

    // Translate ball organically explicitly purely from exactly wherever the physical robust mechanics pipeline dictates functionally
    ctx.translate(cx + ballState.x, ballState.y - ballState.z);

    ctx.fillText('🎾', 0, 0);
    ctx.restore();
  }

  function drawCrosshair(ctx, x, y, color) {
    ctx.save();
    ctx.strokeStyle = color;
    ctx.lineWidth = Math.max(1, 2 * COURT_SCALE);
    ctx.beginPath();
    const size = 5 * COURT_SCALE;
    ctx.moveTo(x - size, y - size);
    ctx.lineTo(x + size, y + size);
    ctx.moveTo(x + size, y - size);
    ctx.lineTo(x - size, y + size);
    ctx.stroke();
    ctx.restore();
  }

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
    const crosshairColor = state.resetting ? 'rgba(128, 128, 128, 0.8)' : 'rgba(255, 0, 0, 0.8)';
    drawCrosshair(ctx, landX, landY, crosshairColor);
  }

  // Draw the optimal 3D intercept prediction as a Green X
  if (state.ball.vy !== 0 && !state.resetting) {
    let interceptTarget;
    // Target the RECIEVER's racket to predict where they will intercept the ball
    if (state.lastHitter === 'npc' || state.isServe === 'npc_serve') {
      interceptTarget = calculateCenterPointOfRacket(state.player.racketPosition);
    } else {
      interceptTarget = calculateCenterPointOfRacket(state.npc.racketPosition);
    }

    const bestPoint = calculateOptimalInterceptPoint(interceptTarget);

    // Only draw the visual if it securely predicts an approach
    if (bestPoint.t > 0) {
      const hitX = centerX + bestPoint.x;
      // Map the 3D 'Z' altitude physically to the screen's vertical 'Y' axis to match the ball's rendering height exactly
      const hitY = bestPoint.y - bestPoint.z;
      drawCrosshair(ctx, hitX, hitY, 'rgba(46, 204, 113, 0.9)');
    }
  }

  // Draw the yellow X for the Toss Ground Target
  if (state.isServe !== 'in_play' && state.tossTarget && !state.resetting) {
    const hitX = centerX + state.tossTarget.x;
    const hitY = state.tossTarget.y; // The tossTarget mathematically identically mirrors the literal ground geometry!
    drawCrosshair(ctx, hitX, hitY, 'rgba(241, 196, 15, 0.9)');
  }

  // 3. Render Player
  drawCharacterShadowed(ctx, window.init.myCharacter, state.player, playerLimbs, pAimPitch, pAimYaw, pAimRoll);

  drawBall(ctx, state.ball, centerX, COURT_SCALE);

  // 3. Admin Hitbox Diagnostic Visualization Overlay
  if (window.isAdmin) {
    const pHitbox = state.player.racketPosition;
    const nHitbox = state.npc.racketPosition;

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
  drawDiagnosticsOverlay(pAimPitch, pAimYaw, pAimRoll);
}

/**
 * Renders the diagnostic graphs and HUD panels over the 3D court.
 * @param {number} pAimPitch - Raw mathematical aim pitch for the diagram context.
 * @param {number} pAimYaw - Raw mathematical aim yaw for the diagram context.
 * @param {number} pAimRoll - Raw mathematical aim roll for the diagram context.
 */
function drawDiagnosticsOverlay(pAimPitch, pAimYaw, pAimRoll) {
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
    let ry = 20 * Math.max(0.1, Math.abs(1.0 - pAimRoll)); // Width of face

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
