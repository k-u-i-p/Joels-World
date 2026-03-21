/**
* Joels World - Tennis Minigame
* 
* Handles the logic, physics, and rendering for the top-down 3D tennis minigame.
* Features realistic 3D parabolic ball trajectories, elliptical racket collisions,
* and AI opponent tracking.
*/

import { gameLoop } from '../gameloop.js';
import { inputManager } from '../input.js';
import { characterManager } from '../characters.js';
import { camera } from '../main.js';
import { soundManager } from '../sound.js';

// ==========================================
// CONSTANTS & CONFIGURATION
// ==========================================
const canvas = document.getElementById('gameCanvas');
const ctx = canvas.getContext('2d');

const COURT_INNER_BOUNDS = { x: -60, y: 85, width: 120, height: 205 };
const GAME_SCALE = COURT_INNER_BOUNDS.width / 255; // Used to normalize velocities against court shrinks

const PLAYER_SPEED = 250 * GAME_SCALE;        // Player movement speed
const NPC_SPEED = 175 * GAME_SCALE;           // NPC movement speed
const BALL_SPEED = 220 * GAME_SCALE;          // Base horizontal ball speed
const MAXIMUM_BALL_SPEED = 300 * GAME_SCALE;  // engine speed ceiling for rallying
const BALL_RADIUS = 3;                        // Collision and drawing radius of the ball
const GRAVITY = 800 * GAME_SCALE;             // Gravity affecting the ball Z-axis (pixels/s^2)
const NET_HEIGHT = 45 * GAME_SCALE;           // Minimum Z-altitude required to cross the court
const DAMPING_MULTIPLIER = 0.6;               // Vertical velocity retained after a court bounce
const MAX_JUMP = 80;                         // Maximum aerial leap height extension for rackets
const MIN_CROUCH = 5;                         // Maximum downward racket crouch extension
const JUMP_Z = 15;                            // Minimum Z to count as a JUMP
const RESTING_Z = 10;                         // Resting Character Z
const RESTING_RACKET_ROLL = 0.6;             // Resting Racket Roll

const PLAYABLE_OVERSHOOT_X = 75; // How far characters can physically run laterally out of bounds
const PLAYABLE_OVERSHOOT_Y = 50; // How far characters can physically run vertically past the baselines
const PLAYABLE_HALF_WIDTH = (COURT_INNER_BOUNDS.width / 2) + PLAYABLE_OVERSHOOT_X; // Lateral character bounds naturally scale with the court

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
    currentPosition: { x: 0, y: 0, z: 0, rotation: 270 },
    targetPosition: { x: 0, y: 0, z: 0, rotation: 270 },
    racketCurrentPosition: { x: 0, y: 0, groundY: 0, z: 0, w: 1, h: 1, angle: 0, pitch: 0, yaw: Math.PI * 0.25, roll: RESTING_RACKET_ROLL, armX: -2 + 4 * Math.cos(Math.PI * 0.25), armY: 14 + 4 * Math.sin(Math.PI * 0.25) },
    racketTargetPosition: { pitch: 0, yaw: Math.PI * 0.25, roll: RESTING_RACKET_ROLL, armX: -2 + 4 * Math.cos(Math.PI * 0.25), armY: 14 + 4 * Math.sin(Math.PI * 0.25) },
    score: 0,
    movementDirection: { x: 1, y: 1 },
    legTimer: 0,
    lastInterceptPoint: null,
    lastHitTarget: null,
    lastJumpTime: 0,
    lastZChangeTime: 0,
  },
  npc: {
    currentPosition: { x: 0, y: 0, z: 0, rotation: 90 },
    targetPosition: { x: 0, y: COURT_INNER_BOUNDS.y - 10, z: 0, rotation: 90 },
    racketCurrentPosition: { x: 0, y: 0, groundY: 0, z: 0, w: 1, h: 1, angle: 0, pitch: 0, yaw: Math.PI * 0.25, roll: RESTING_RACKET_ROLL, armX: -2 + 4 * Math.cos(Math.PI * 0.25), armY: 14 + 4 * Math.sin(Math.PI * 0.25) },
    racketTargetPosition: { pitch: 0, yaw: Math.PI * 0.25, roll: RESTING_RACKET_ROLL, armX: -2 + 4 * Math.cos(Math.PI * 0.25), armY: 14 + 4 * Math.sin(Math.PI * 0.25) },
    score: 0,
    movementDirection: { x: 1, y: 1 },
    legTimer: 0,
    lastInterceptPoint: null,
    lastHitTarget: null,
    lastJumpTime: 0,
    lastZChangeTime: 0,
  },
  ball: {
    x: 0,
    y: COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height / 2,
    z: 0,
    vx: BALL_SPEED * 0.7,
    vy: BALL_SPEED * 0.7,
    vz: 0
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
  trajectoryFrozen: false,
  isJoystickActive: false
};

/** Standard numeric clamp function. */
const clamp = (val, min, max) => Math.min(Math.max(val, min), max);

/** Evaluates whether a character is mechanically authorized to natively strike or track the ball. */
function canCharacterHit(isPlayer) {
  if (state.resetting)
    return false;

  if (state.introPhase && state.introPhase !== 'playing')
    return false;

  let lastHitterWasPlayer = state.lastHitter === 'player';

  if (state.servePhase === 'idle')
    return false; // Prevent logic locks during manual ball holding

  if (isPlayer && lastHitterWasPlayer && state.isServe === 'in_play')
    return false; // Prevent double hits

  if (!isPlayer && !lastHitterWasPlayer && state.isServe === 'in_play')
    return false; // Prevent double hits

  if (isPlayer && state.isServe === 'player_serve' && state.servePhase === 'idle')
    return false; // Don't allow player to hit ball until the serve is thrown

  if (!isPlayer && state.isServe === 'npc_serve' && state.servePhase === 'idle')
    return false; // Don't allow npc to hit ball until the serve is thrown

  if (isPlayer && state.isServe === 'npc_serve' && state.servePhase !== 'live')
    return false; // Don't allow player to hit ball until the NPC hits on their serve

  if (!isPlayer && state.isServe === 'player_serve' && state.servePhase !== 'live')
    return false; // Don't allow npc to hit ball until the player hits on their serve

  if (isPlayer && state.isServe === 'player_serve' && state.servePhase === 'live' && (state.bounceCount > 0 || state.rallyCount > 0))
    return false; // Can't hit the ball if its our serve and its bounced

  if (!isPlayer && state.isServe === 'npc_serve' && state.servePhase === 'live' && (state.bounceCount > 0 || state.rallyCount > 0))
    return false; // Can't hit the ball if its our serve and its bounced

  if (isPlayer && state.isServe === 'npc_serve' && state.servePhase === 'live' && state.bounceCount == 0)
    return false; // Can't hit the ball if its the NPCs serve and it hasn't bounced yet

  if (!isPlayer && state.isServe === 'player_serve' && state.servePhase === 'live' && state.bounceCount == 0)
    return false; // Can't hit the ball if its the players serve and it hasn't bounced yet

  if (isPlayer && state.isServe === 'npc_serve' && state.servePhase !== 'live')
    return false; // Can't hit the ball until the NPC hits it on their serve

  if (!isPlayer && state.isServe === 'player_serve' && state.servePhase !== 'live')
    return false; // Can't hit the ball until the player hits it on their serve

  return true;
}

/**
 * Calculates the absolute 3D Euclidean distance from the character to the ball.
 * @param {Object} playerObj - The state tracking object for the character (state.player or state.npc)
 * @returns {number} The straight-line coordinate distance
 */
function distanceToBallXY(playerObj) {
  const dx = state.ball.x - playerObj.currentPosition.x;
  const dy = state.ball.y - playerObj.currentPosition.y;

  return Math.sqrt(dx * dx + dy * dy);
}

function distanceToBallZ(playerObj) {
  const dz = state.ball.z - playerObj.currentPosition.z;

  return Math.sqrt(dz * dz);
}

/**
* determines the required 2D limb offset (rightArmX, rightArmY) 
* for a character to reach out to an intercept point relative to their rotation.
* 
* @param {Object} player - The character state tracking object.
* @param {{x: number, y: number, z: number}} interceptPoint - Expected ball collision point.
* @returns {{x: number, y: number, z: number}} The calculated rightArm 2D offsets and world position bindings.
*/
function calculateArmReach(player, interceptPoint) {
  const worldY = player.currentPosition.y;

  const dx = interceptPoint.x - player.currentPosition.x;
  const dy = interceptPoint.y - worldY;

  const dist2D = Math.sqrt(dx * dx + dy * dy);

  // Angle to target in strictly 2D planar space
  const angleToBall = Math.atan2(dy, dx);
  const charFacingRad = player.currentPosition.rotation * (Math.PI / 180);

  // Angle relative to character's facing orientation
  let localAngle = angleToBall - charFacingRad;

  // Normalize to [-PI, +PI] 
  while (localAngle <= -Math.PI) localAngle += Math.PI * 2;
  while (localAngle > Math.PI) localAngle -= Math.PI * 2;

  // Anatomical Constraints: Prevent the arm from bending unnaturally into the character's back.
  // 0 is straight forward. PI/2 is straight right. -PI/2 is straight left across the body.
  const minAngle = -Math.PI * 0.6; // Max reach across body to the left backhand (-108 deg)
  const maxAngle = Math.PI * 0.75; // Max reach out to the right forehand (135 deg)

  // This continuous polar constraint natively respects character rotation!
  if (localAngle < minAngle) {
    localAngle = minAngle;
  } else if (localAngle > maxAngle) {
    localAngle = maxAngle;
  }

  const MAX_REACH = 14;
  const actualReach = Math.min(dist2D, MAX_REACH);

  return {
    x: -2 + actualReach * Math.cos(localAngle),
    y: 14 + actualReach * Math.sin(localAngle),
    z: interceptPoint.z
  };
}

/**
* calculates the 3D rotational vector required to hold the racket
* to aim for targetPoint the incoming velocity vector of the ball.
* 
* @param {Object} interceptPoint - The pre-calculated intercept target containing accurately simulated arrival velocities.
* @param {Object} charState - The character state.
* @returns {{roll: number, pitch: number, yaw: number}}
*/
function calculateRacketReturnAimAngle(interceptPoint, charState, targetPoint) {
  let bx = interceptPoint.vx || 0;
  let by = interceptPoint.vy || 0;
  const bz = interceptPoint.vz || 0;

  // Serve tosses have trivial horizontal velocities that shouldn't be "deflected" like 100mph rally shots.
  // Ignoring the toss drift allows the racket normal to aim perfectly horizontally at the actual target!
  if (state.isServe !== 'in_play') {
    bx = 0;
    by = 0;
  }

  // Calculate normalized incoming kinetic vector preventing zero division
  const inLen = Math.sqrt(bx * bx + by * by + bz * bz) || 1;
  const vInX = bx / inLen;
  const vInY = by / inLen;
  const vInZ = bz / inLen;

  // Calculate normalized outgoing targeting vector bridging coordinates
  const outDx = targetPoint.x - interceptPoint.x;
  const outDy = targetPoint.y - interceptPoint.y;
  const outDz = targetPoint.z - interceptPoint.z;
  const outLen = Math.sqrt(outDx * outDx + outDy * outDy + outDz * outDz) || 1;
  const vOutX = outDx / outLen;
  const vOutY = outDy / outLen;
  const vOutZ = outDz / outLen;

  // The perfect deflection normal bisects the incoming and outgoing kinetic vectors !
  let nx = vOutX - vInX;
  let ny = vOutY - vInY;
  let nz = vOutZ - vInZ;
  const nLen = Math.sqrt(nx * nx + ny * ny + nz * nz) || 1;
  nx /= nLen;
  ny /= nLen;
  nz /= nLen;

  // Align yaw to map parallel to the normal's horizontal layout tracking 
  let absoluteYaw = Math.atan2(ny, nx);

  // Rotate 90 degrees because the handle draws perpendicular to the strings' pushing normal !
  absoluteYaw += Math.PI / 2;

  // Elevate handle to track pitch relative to the Z requirements 
  const targetPitch = Math.asin(clamp(nz, -1, 1)) * 0.5;

  // Determine geometric roll scaling (0 makes the face vertical for linear low shots, 1 makes it completely horizontal/flat for upward scooping lobs)
  // maps the normal vector's Z axis completely mirroring isometric rendering!
  const roll = Math.abs(nz);

  const charFacingRad = charState.currentPosition.rotation * (Math.PI / 180);
  let localYaw = absoluteYaw - charFacingRad;

  while (localYaw <= -Math.PI) localYaw += Math.PI * 2;
  while (localYaw > Math.PI) localYaw -= Math.PI * 2;

  // Anatomical Constraints: Prevent the wrist from snapping into impossible > 90 degree bends
  // Resting racket yaw is naturally PI * 0.25 (45 deg)
  const minYaw = -Math.PI * 0.25; // Max inward backhand wrist bend (-45 deg)
  const maxYaw = Math.PI * 0.75;  // Max outward forehand wrist bend (135 deg)

  localYaw = clamp(localYaw, minYaw, maxYaw);

  return { roll: roll, pitch: targetPitch, yaw: localYaw };
}
/**
* Calculates structural offsets for limbs based on leg animation and arm reach referencing the character state .
*/
function getLimbs(playerObj, rightArmX, rightArmY) {
  const legTimer = playerObj.legTimer || 0;
  const directionX = playerObj.movementDirection ? playerObj.movementDirection.x : 1;
  const directionY = playerObj.movementDirection ? playerObj.movementDirection.y : 1;

  const legSwing = Math.sin(legTimer);
  const legStride = 5;
  const armStride = 8;
  const safeDirX = directionX || 1;
  const safeDirY = directionY || 1;

  return {
    leftArmX: -2 - legSwing * armStride, leftArmY: -14,
    rightArmX: rightArmX, rightArmY: rightArmY,
    leftLegStartX: -2, leftLegStartY: -6,
    leftLegEndX: -2 + (safeDirY * legSwing * legStride), leftLegEndY: -6 + (-safeDirX * legSwing * legStride),
    rightLegStartX: -2, rightLegStartY: 6,
    rightLegEndX: -2 - (safeDirY * legSwing * legStride), rightLegEndY: 6 - (-safeDirX * legSwing * legStride)
  };
}

/**
* Predicts the intercept point along the ball's current trajectory 
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
  let simVZ = state.ball.vz;
  let simBounces = state.bounceCount;

  let bestScore = -Infinity;
  let bestT = -1, bestX = simX, bestY = simY, bestZ = simZ, bestVX = simVX, bestVY = simVY, bestVZ = simVZ;

  let currentT = 0;
  const simDt = 0.016; // 60fps procedural resolution
  const maxT = 5.0;    // Cap prediction at 2.0 seconds

  while (currentT <= maxT) {
    // Only permit physics intercept tracking if the ball resolves physically inside valid playable geometry
    const isWithinCourtX = Math.abs(simX) <= PLAYABLE_HALF_WIDTH;
    const isWithinCourtY = simY >= (NPC_BASE_Y - PLAYABLE_OVERSHOOT_Y) && simY <= (PLAYER_BASE_Y + PLAYABLE_OVERSHOOT_Y);

    // Crucially restrict tracking so characters only lock onto intercept coordinates falling within their physical leaping/crouching limitations!
    const isWithinReachZ = simZ >= MIN_CROUCH && simZ <= MAX_JUMP;
    const isComfortableZ = simZ >= RESTING_Z && simZ <= JUMP_Z;

    if (isWithinCourtX && isWithinCourtY && isWithinReachZ) {
      const distSq = (simX - target.x) ** 2 + (simY - target.y) ** 2 + (simZ - target.z) ** 2;

      let score = -distSq; // Base Penalty: Spatial Distance to target

      // Comfort Bonus: Massive multiplier to enforce sticking to easily reachable vertical heights
      if (isComfortableZ) {
        score += 100000;
      }

      // Scooping Penalty: Strongly discourage hitting the ball while it's hurtling downwards
      if (simVZ < 0) {
        score -= Math.abs(simVZ) * 50;
      }

      // Apex / Float Bonus: Globally reward hitting the ball when its vertical kinetic energy is low 
      score -= Math.abs(simVZ) * 20;

      // Stall Penalty: Gently prefer intercepting the ball sooner rather than later
      score -= currentT * 2000;

      if (score > bestScore) {
        bestScore = score;
        bestT = currentT;
        bestX = simX;
        bestY = simY;
        bestZ = simZ;
        bestVX = simVX;
        bestVY = simVY;
        bestVZ = simVZ;
      }
    }

    // Step the deterministic physics model by one slice
    simZ += simVZ * simDt;
    simVZ -= GRAVITY * simDt;
    simX += simVX * simDt;
    simY += simVY * simDt;

    // Process procedural floor deflections
    if (simZ < 0) {
      simBounces++;
      if (simBounces + state.bounceCount > 1) {
        break; // A second bounce fundamentally kills the rally, prune prediction immediately
      }
      simZ = 0;
      simVZ = Math.abs(simVZ) * DAMPING_MULTIPLIER;
    }

    currentT += simDt;

    // Prune evaluation loop immediately if ball escapes active bounding volume
    if (Math.abs(simX) > PLAYABLE_HALF_WIDTH + 50 ||
      simY < COURT_INNER_BOUNDS.y - 100 ||
      simY > COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height + 100) {
      break;
    }
  }

  return { x: bestX, y: bestY, z: bestZ, t: bestT, vx: bestVX, vy: bestVY, vz: bestVZ };
}


/**
* Halts all kinetic physics and geometrically forces the ball onto a specific coordinate locally.
* 
* @param {{x: number, y: number, z: number}} target - Target spatial vector matrix 
*/
function moveBall(target) {
  state.ball.x = target.x;
  state.ball.y = target.y;
  state.ball.z = target.z;
  state.ball.vx = 0;
  state.ball.vy = 0;
  state.ball.vz = 0;
}

/**
 * Handles continuous physical coordinate resolution for the ball across space
 */
function processBallMovement(dt, onBounce) {
  const prevBallY = state.ball.y;

  //Ball in hand before serve
  if (state.servePhase === 'idle') {
    const serverObj = state.isServe === 'player_serve' ? state.player : state.npc;
    const rotRad = serverObj.currentPosition.rotation * (Math.PI / 180);
    const limbs = getLimbs(serverObj, 0, 0); // track limb anchoring
    const COURT_SCALE = COURT_INNER_BOUNDS.width / 255;

    const armWorldX = (limbs.leftArmX * Math.cos(rotRad) - limbs.leftArmY * Math.sin(rotRad)) * (camera.zoom || 1) * COURT_SCALE;
    const armWorldY = (limbs.leftArmX * Math.sin(rotRad) + limbs.leftArmY * Math.cos(rotRad)) * (camera.zoom || 1) * COURT_SCALE;

    moveBall({
      x: serverObj.currentPosition.x + armWorldX,
      y: serverObj.currentPosition.y + armWorldY,
      z: serverObj.currentPosition.z
    });
  } else {
    // Elevate ball 
    state.ball.z += state.ball.vz * dt;
    // Rotate velocity downward due to continuous gravity
    state.ball.vz -= GRAVITY * dt;

    // Handle Planar XY movement
    state.ball.x += state.ball.vx * dt;
    state.ball.y += state.ball.vy * dt;
  }

  // Progress global point timer monotonically (freeze while waiting for serves to start)
  if (state.resetDelayTimer <= 0) state.totalElapsedTime += dt;

  // permit tracking during live gameplay
  if (minigameActive && !state.trajectoryFrozen) {
    state.trajectoryPoints.push({
      x: state.ball.x,
      y: state.ball.y,
      t: state.totalElapsedTime,
      z: state.ball.z,
      pZ: state.player.racketCurrentPosition.z, // Align to physical shoulder height (25px above floor)
      nZ: state.npc.racketCurrentPosition.z
    });
    // Keep array from growing infinitely if the ball gets stuck out of bounds
    if (state.trajectoryPoints.length > 300) state.trajectoryPoints.shift();
  }

  // Handle Net Collision
  // Check if ball crossed the Y-center of the court during this frame
  const netY = COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height / 2;
  if ((prevBallY < netY && state.ball.y >= netY) || (prevBallY >= netY && state.ball.y < netY)) {
    if (state.ball.z < NET_HEIGHT) {
      // Ball hit the physical net structure!
      state.ball.vy *= -0.3; // Rebound weakly back towards the hitter
      state.ball.vx *= 0.3; // Kill most kinetic energy
      state.ball.y = netY + Math.sign(state.ball.vy) * 5; // Snap off the net
    }
  }

  if (state.ball.z < 0) {
    state.ball.z = 0;
    state.bounceCount++;

    // Handle Bounce
    state.ball.vz = Math.abs(state.ball.vz) * DAMPING_MULTIPLIER;

    onBounce(netY);
  }
}

/**
* derives the required trajectory angles and speeds to land 
* the ball precisely at the given target coordinate, and sets the game state.
* 
* @param {number} targetX - Destination X coordinate.
* @param {number} targetY - Destination Y coordinate.
* @param {number} velocity - The driving physical 3D velocity of the ball.
*/
function hitBallToTarget(targetX, targetY, targetVelocity) {
  let boundedVelocity = Math.min(targetVelocity, MAXIMUM_BALL_SPEED);
  state.bounceCount = 0;

  if (state.isServe === 'in_play') {
    state.trajectoryPoints = []; // Clear history on physical strike during a live rally
  }

  state.trajectoryFrozen = false; // Unfreeze tracking

  const dx = targetX - state.ball.x;
  const dy = targetY - state.ball.y;
  const dist = Math.sqrt(dx * dx + dy * dy);

  // Parabolic Physics calculation establishing the necessary starting vertical Z velocity (vZ)
  let timeToTarget = dist / boundedVelocity;

  // Cap the flight time to prevent extreme "moonball" lobs. 
  // If the target requires a longer flight, we forcefully drive the ball harder and flatter to reach it.
  const maxFlightTime = 1.3;
  if (timeToTarget > maxFlightTime) {
    timeToTarget = maxFlightTime;
    // Boost the 2D planar velocity to cover the distance in the compressed time frame
    boundedVelocity = dist / timeToTarget;
  }

  let vZ = (0.5 * GRAVITY * timeToTarget * timeToTarget - state.ball.z) / timeToTarget;

  // Ensure the ball arcs high enough to clear the physical net structure if the target crosses the net
  const netY = COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height / 2;
  const crossesNet = (state.ball.y < netY && targetY > netY) || (state.ball.y > netY && targetY < netY);

  if (crossesNet) {
    // Rough estimation of how long it takes to reach the net
    const timeToNet = (Math.abs(netY - state.ball.y) / Math.abs(dy)) * timeToTarget;
    // Calculate the minimum Z-velocity needed to be above NET_HEIGHT when t = timeToNet
    const requiredClearanceHeight = NET_HEIGHT + BALL_RADIUS + 5; // adding 5px buffer
    const minVZ = (requiredClearanceHeight - state.ball.z + 0.5 * GRAVITY * timeToNet * timeToNet) / timeToNet;

    // If the flat stroke calculations predict crashing into the net, boost the arc!
    // However, if the ball is hit very low to the ground, or driven very fast and flat, we reduce the "-clearance" assist
    // naturally allowing the ball to smash into the net!
    if (vZ < minVZ) {
      let assist = 1.0;

      // Hard flat shots resist upward correction
      if (boundedVelocity > 250) assist -= 0.2;

      // Balls hit late/low to the ground are physically harder to scoop over the net
      if (state.ball.z < 20) assist -= 0.4;

      // Add slight variance (+/- 10%)
      assist = clamp(assist + (Math.random() * 0.2 - 0.1), 0, 1);

      vZ = vZ + (minVZ - vZ) * assist;
    }
  }

  state.ball.vz = vZ;
  // Set normalized 2D movement planar slice
  state.ball.vx = (dx / dist) * boundedVelocity;
  state.ball.vy = (dy / dist) * boundedVelocity;
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
  state.player.currentPosition.x = state.serveSide * -serveOffset;
  state.player.currentPosition.y = PLAYER_BASE_Y;
  state.npc.currentPosition.x = state.serveSide * serveOffset;
  state.npc.currentPosition.y = NPC_BASE_Y;
  state.resetDelayTimer = 0;
  state.player.currentPosition.z = 0;
  state.npc.currentPosition.z = 0;
  state.npc.targetPosition = { x: state.npc.currentPosition.x, y: state.npc.currentPosition.y, z: 0, rotation: 90 };
  state.player.targetPosition = { x: state.player.currentPosition.x, y: state.player.currentPosition.y, z: 0, rotation: 270 };
  state.resetting = false;

  // Start cinematic intro instead of immediately serving
  state.introPhase = 'walkToNet';
  state.introTimer = 0;
  // Place characters far back initially
  state.player.currentPosition.y = PLAYER_BASE_Y + 30;
  state.npc.currentPosition.y = NPC_BASE_Y - 30;
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

  // Setup Exit Button
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
        dialogText.textContent = 'Return to the junior school?';
        dialogOverlay.style.display = 'block';

        const topUi = document.getElementById('top-center-ui');
        const wasHidden = topUi && topUi.style.display === 'none';
        if (wasHidden) topUi.style.display = 'flex';

        btnNo.onclick = () => {
          dialogOverlay.style.display = 'none';
          if (wasHidden && topUi) topUi.style.display = 'none';
        };

        btnYes.onclick = () => {
          dialogOverlay.style.display = 'none';
          import('../network.js').then(({ networkClient }) => {
            networkClient.send({ type: 'change_map', mapId: 0 });
          });
        };
      }
    };
  }

  gameLoop.registerFunction(run);
}

/**
* Generate a tar .
*/
function generateReturnBallHitCords(isPlayer, pRacketPos) {
  let targetX, targetY;

  if (state.isServe !== 'in_play') {
    const serveTarget = calculateServeTarget(isPlayer);
    targetX = serveTarget.x;
    targetY = serveTarget.y;
  } else {
    const courtCenterX = COURT_INNER_BOUNDS.x + COURT_INNER_BOUNDS.width / 2;

    if (isPlayer) {
      // Player aims deep into the NPC's side (top half of the court)
      targetY = COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height * (0.1 + Math.random() * 0.25);

      // Aim diagonally away from the NPC's current spot
      targetX = state.npc.currentPosition.x > courtCenterX
        ? COURT_INNER_BOUNDS.x + COURT_INNER_BOUNDS.width * (0.1 + Math.random() * 0.2) // Hit Left
        : COURT_INNER_BOUNDS.x + COURT_INNER_BOUNDS.width * (0.8 + Math.random() * 0.1); // Hit Right

      // Add simulation variance based on how clean the racket strike was 
      if (pRacketPos) {
        targetX += (state.ball.x - pRacketPos.x) * 1.5;
      }
    } else {
      // NPC aims moderately deep into the Player's side (bottom half of the court)
      targetY = COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height * (0.6 + Math.random() * 0.3);

      // NPC aims centrally, making it much easier for the player to reach
      targetX = COURT_INNER_BOUNDS.x + COURT_INNER_BOUNDS.width * (0.35 + Math.random() * 0.3);
    }

    // Strictly enforce bounds so the smart-aiming doesn't actively hit the ball out
    targetX = clamp(targetX, COURT_INNER_BOUNDS.x + 10, COURT_INNER_BOUNDS.x + COURT_INNER_BOUNDS.width - 10);
  }

  return { x: targetX, y: targetY };
}

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
* serves the ball from the respective character towards a valid court zone.
* Automatically computes 3D pitch/velocity required to lob into the target destination.
* 
* @param {Object} playerObj - The character object serving.
*/
function serveBall(playerObj) {
  const isPlayer = playerObj === state.player;
  state.resetting = false;
  state.isServe = isPlayer ? 'player_serve' : 'npc_serve';
  state.player.hasTarget = false;
  state.servePhase = 'idle';
  state.player.lastInterceptPoint = null;
  state.npc.lastInterceptPoint = null;
  state.npc.previousMoveToInterceptPoint = null;
  state.player.previousMoveToInterceptPoint = null;

  console.log("Serving ball for " + (isPlayer ? "player" : "npc"));

  const rotRad = playerObj.currentPosition.rotation * (Math.PI / 180);
  const limbs = getLimbs(playerObj, 0, 0);

  const COURT_SCALE = COURT_INNER_BOUNDS.width / 255;
  const armWorldX = (limbs.leftArmX * Math.cos(rotRad) - limbs.leftArmY * Math.sin(rotRad)) * (camera.zoom || 1) * COURT_SCALE;
  const armWorldY = (limbs.leftArmX * Math.sin(rotRad) + limbs.leftArmY * Math.cos(rotRad)) * (camera.zoom || 1) * COURT_SCALE;

  // Put the ball in the player's left hand
  moveBall({
    x: playerObj.currentPosition.x + armWorldX + 100,
    y: playerObj.currentPosition.y + armWorldY - 100,
    z: playerObj.currentPosition.z
  });

  // Calculate strict service box zones mapped to realistic canvas line artwork 
  const centerX = COURT_INNER_BOUNDS.x + COURT_INNER_BOUNDS.width / 2;
  const serviceBoxDepth = COURT_INNER_BOUNDS.height * 0.245; // ~50.2 ( hitting custom SVG T-line)
  const netY = COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height / 2;

  let boxMinX, boxMaxX, boxMinY, boxMaxY;

  // Apply standard physical tennis spacing: Doubles alleys are exactly 12.5% of total width each side
  const doublesAlleyWidth = COURT_INNER_BOUNDS.width * 0.125;
  const singlesMinX = COURT_INNER_BOUNDS.x + doublesAlleyWidth;
  const singlesMaxX = COURT_INNER_BOUNDS.x + COURT_INNER_BOUNDS.width - doublesAlleyWidth;

  // Serves are cross-court correctly mapped into strictly singles service boundaries
  if (isPlayer) {
    boxMinY = netY - serviceBoxDepth;
    boxMaxY = netY;
    boxMinX = (state.serveSide === -1) ? centerX : singlesMinX;
    boxMaxX = (state.serveSide === -1) ? singlesMaxX : centerX;
  } else {
    boxMinY = netY;
    boxMaxY = netY + serviceBoxDepth;
    boxMinX = (state.serveSide === 1) ? centerX : singlesMinX;
    boxMaxX = (state.serveSide === 1) ? singlesMaxX : centerX;
  }

  state.activeServiceBox = { minX: boxMinX, maxX: boxMaxX, minY: boxMinY, maxY: boxMaxY };

  state.lastHitter = isPlayer ? 'player' : 'npc';

  // Wipe the graph array so the new serve correctly starts a blank trajectory chart
  state.trajectoryPoints = [];

  setTimeout(() => {
    throwBall(playerObj, function () {
      state.servePhase = 'live';
      setNewInterceptPoints();
    });
  }, 1000);
}

function setNewInterceptPoints() {
  resetRacketToNeutral(state.player);
  resetRacketToNeutral(state.npc);

  state.player.lastInterceptPoint = calculateOptimalInterceptPoint(state.player.racketCurrentPosition);
  state.npc.lastInterceptPoint = calculateOptimalInterceptPoint(state.npc.racketCurrentPosition);
  state.player.previousMoveToInterceptPoint = null;
  state.npc.previousMoveToInterceptPoint = null;
}

/**
* Physically throws the ball from the character's hand using gravity.
* @param {Object} playerObj - The character object serving.
*/
function throwBall(playerObj, apex) {
  const isPlayer = playerObj === state.player;
  state.servePhase = 'just_thrown';

  // State.ball physics are identically continuously synchronized tightly sequentially inside run(dt) prior to executing toss !
  const startX = state.ball.x;
  const startY = state.ball.y;

  // Establish the 2D ground coordinate where the ball lands naturally
  state.tossTarget = {
    x: startX + (isPlayer ? 85 * GAME_SCALE : -85 * GAME_SCALE), // Land softly rightwards physically into racket swing coverage!
    y: startY + (isPlayer ? -15 * GAME_SCALE : 15 * GAME_SCALE), // Land slightly into the court
    z: 125 * GAME_SCALE // Encodes explicit physical apex altitude 
  };

  // 1. Calculate the initial vertical velocity required spanning to the tossTarget.z 
  const dz = Math.max(1, state.tossTarget.z - state.ball.z);
  const vZ = Math.sqrt(2 * GRAVITY * dz);

  // 2. Map precisely how long it takes to rise into the apex 
  const tApex = vZ / GRAVITY;

  // 3. Map precisely how long it takes to naturally fall down sequentially from the apex to the ground (Z=0)
  const tFall = Math.sqrt((2 * state.tossTarget.z) / GRAVITY);

  // 4. Derive total trajectory flight duration spanning physics 
  const tTotalFlight = tApex + tFall;

  // 5. Synthesize accurate constant trajectory velocity bridging start sequentially onto targeting gap 
  state.ball.vx = (state.tossTarget.x - startX) / tTotalFlight;
  state.ball.vy = (state.tossTarget.y - startY) / tTotalFlight;
  state.ball.vz = vZ;

  state.trajectoryFrozen = false; // Ignite the tracker immediately

  state.bounceCount = 0;
  state.rallyCount = 0;

  if (apex) {
    setTimeout(() => {
      apex();
    }, tApex * 1000);
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
  const currentScore = getTennisScore(state.player.score, state.npc.score);
  const npcEl = document.getElementById('tennis-score-npc');
  const playerEl = document.getElementById('tennis-score-player');
  if (npcEl) npcEl.innerText = 'NPC: ' + (currentScore.npcStr || '');
  if (playerEl) playerEl.innerText = 'YOU: ' + (currentScore.playerStr || '');
}

function triggerFault(playerServing) {
  if (state.resetting) return;
  state.faults++;

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

  //Update the intercept points for both players
  state.player.lastInterceptPoint = null;
  state.npc.lastInterceptPoint = null;
}

/**
* Triggers the end of a point, forcing characters to automatically
* walk back to their default service baseline coordinates.
* 
* @param {boolean} nextPlayerServing - if player serves next.
*/
function triggerPointReset(nextPlayerServing) {
  if (state.resetting) return;
  state.resetting = true;
  state.trajectoryFrozen = true; // Freeze the graph to display the concluding shot!
  state.player.previousMoveToInterceptPoint = null;
  state.npc.previousMoveToInterceptPoint = null;
  state.player.lastHitTarget = null;
  state.npc.lastHitTarget = null;

  // Award point based on who is serving next (loser of the rally serves)
  if (nextPlayerServing) {
    state.npc.score++;
  } else {
    state.player.score++;
  }

  // Clear faults for the next point
  state.faults = 0;

  let wonSet = false;
  const scoreData = getTennisScore(state.player.score, state.npc.score);
  if (scoreData.winner) {
    if (scoreData.winner === 'player') {
      onPlayerWinsSet();
      wonSet = true;
    }
    // Game won, reset points for the next game
    state.player.score = 0;
    state.npc.score = 0;
  }
  updateScoreboardDOM();

  state.nextServerIsPlayer = nextPlayerServing;
  // Always serve from Deuce (-1) on Even total points, Ad (1) on Odd total points
  state.serveSide = ((state.player.score + state.npc.score) % 2 === 0) ? -1 : 1;
  state.resetDelayTimer = 1.5; // Brief intermission before next serve
  if (wonSet) {
    soundManager.playPooled('/media/crowd_cheering.mp3', 1.0);
  } else if (state.rallyCount >= 4) {
    soundManager.playPooled('/media/clap.mp3', 0.7);
  }
}

export function onPlayerWinsSet() {
  import('../network.js').then(({ networkClient }) => {
    networkClient.send({ type: 'award_badge', badge: 'tennis' });
  });
}

function processRacketDeflections(visualBallY, processHit) {
  if (state.resetting) return;

  //Check if ball hits the racket bounding box visually
  function evaluateHit(racketPos) {
    const dx = state.ball.x - racketPos.x;
    const dy = visualBallY - racketPos.y;
    const localDx = dx * Math.cos(-racketPos.angle) - dy * Math.sin(-racketPos.angle);
    const localDy = dx * Math.sin(-racketPos.angle) + dy * Math.cos(-racketPos.angle);

    // Strict Elliptical Intersection Boolean Matrix Check over standard Box Radius Check
    return (Math.pow(localDx, 2) / Math.pow(racketPos.w + BALL_RADIUS, 2)) +
      (Math.pow(localDy, 2) / Math.pow(racketPos.h + BALL_RADIUS, 2)) <= 1;
  }

  if (canCharacterHit(true) && evaluateHit(state.player.racketCurrentPosition)) {
    processHit(true);
  } else if (canCharacterHit(false) && evaluateHit(state.npc.racketCurrentPosition)) {
    processHit(false);
  }
}

/**
* Interface to manually command the movement subsystem to target specific local offsets.
*/
function moveCharacterTo(charState, targetX, targetY, z = RESTING_Z) {
  charState.targetPosition.x = targetX;
  charState.targetPosition.y = targetY;
  charState.targetPosition.z = z;
  // Let the immediate execution context evaluate if they've practically arrived
  return Math.abs(targetX - charState.currentPosition.x) > 10 ||
    Math.abs(targetY - charState.currentPosition.y) > 10 ||
    Math.abs(z - charState.currentPosition.z) > 10;
}

// Point to position the characters body so the racket is at the intercept point
function getOptimalInterceptPosition(playerObj, interceptPoint) {
  const rotRad = playerObj.currentPosition.rotation * (Math.PI / 180);
  const rcp = playerObj.racketCurrentPosition;

  const armWorldX = rcp.armX * Math.cos(rotRad) - rcp.armY * Math.sin(rotRad);
  const armWorldY = rcp.armX * Math.sin(rotRad) + rcp.armY * Math.cos(rotRad);

  const MAX_REACH = 43;

  const absoluteYaw = rcp.yaw + rotRad;
  const handleWorldX = Math.cos(absoluteYaw);
  const handleWorldY = Math.sin(absoluteYaw);

  // Calculate the unjumpable altitude difference (requires arm to tilt up/down)
  // const expectedBodyZ = Math.max(MIN_CROUCH, Math.min(MAX_JUMP, interceptPoint.z));
  const dz = interceptPoint.z - playerObj.currentPosition.z;

  // Trigonometrically shrink the horizontal 2D footprint if the arm is forced to tilt vertically!
  const planarScale = Math.sqrt(Math.max(0.1, 1 - Math.pow(Math.min(Math.abs(dz), MAX_REACH) / MAX_REACH, 2)));

  const stringbedWorldX = (armWorldX + handleWorldX) * planarScale;
  const stringbedWorldY = (armWorldY + handleWorldY) * planarScale;

  return {
    x: interceptPoint.x - stringbedWorldX + (MAX_REACH / 2 * GAME_SCALE),
    y: interceptPoint.y - stringbedWorldY,
    z: interceptPoint.z
  };
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

    convergePhysics(state.player, dt, true, 0.5);
    convergePhysics(state.npc, dt, false, 0.5);

    // Override convergence rotational intent to face each other tightly
    state.player.targetPosition.rotation = 270;
    state.npc.targetPosition.rotation = 90;

    if (!pMoving && !nMoving) {
      state.introPhase = 'shakeHands';
      state.introTimer = 2.0; // 2 seconds of shaking hands
      state.player.legTimer = 0;
      state.npc.legTimer = 0;
    }
  } else if (state.introPhase === 'shakeHands') {
    state.introTimer -= dt;
    // Simulate hand shake by oscillating rotation slightly
    state.player.currentPosition.rotation = 270 + Math.sin(state.introTimer * 20) * 10;
    state.npc.currentPosition.rotation = 90 - Math.sin(state.introTimer * 20) * 10;

    if (state.introTimer <= 0) {
      state.introPhase = 'walkToBaseline';
    }
  } else if (state.introPhase === 'walkToBaseline') {
    const serveOffset = COURT_INNER_BOUNDS.width * 0.4;
    const targetPX = state.nextServerIsPlayer ? state.serveSide * serveOffset : state.serveSide * -serveOffset;
    const targetNX = state.nextServerIsPlayer ? state.serveSide * -serveOffset : state.serveSide * serveOffset;

    const pFar = moveCharacterTo(state.player, targetPX, PLAYER_BASE_Y);
    const nFar = moveCharacterTo(state.npc, targetNX, NPC_BASE_Y);

    convergePhysics(state.player, dt, true, 0.6);
    convergePhysics(state.npc, dt, false, 0.6);

    // If completely arrived back at baseline, turn to face the net utilizing standard defaults
    if (!pFar) state.player.targetPosition.rotation = 270;
    if (!nFar) state.npc.targetPosition.rotation = 90;

    if (!pFar && !nFar) {
      state.player.legTimer = 0;
      state.npc.legTimer = 0;
      state.introPhase = 'playing';
      serveBall(state.nextServerIsPlayer ? state.player : state.npc);
    }
  }
}

function getLandingSpot(ball) {
  // Calculate and render crosshairs onto the destination surface where ball's geometry will collide
  const vZTargetCheck = ball.vz;
  const det = vZTargetCheck * vZTargetCheck + 2 * GRAVITY * ball.z;
  let tLand = 0;
  if (det >= 0) {
    tLand = (vZTargetCheck + Math.sqrt(det)) / GRAVITY;
  }
  const landX = ball.x + ball.vx * tLand;
  const landY = ball.y + ball.vy * tLand;
  return { x: landX, y: landY };
}

function convergePhysics(charState, dt, isPlayer, speedMult = 1.0) {
  const prevX = charState.currentPosition.x;
  const prevY = charState.currentPosition.y;
  const speed = (isPlayer ? PLAYER_SPEED : NPC_SPEED) * dt * speedMult;

  let mx = 0;
  const dx = charState.targetPosition.x - charState.currentPosition.x;
  if (Math.abs(dx) > 1) {
    mx = Math.sign(dx) * Math.min(speed, Math.abs(dx));
    charState.currentPosition.x += mx;
  } else charState.currentPosition.x = charState.targetPosition.x;

  let my = 0;
  const dy = charState.targetPosition.y - charState.currentPosition.y;
  if (Math.abs(dy) > 1) {
    my = Math.sign(dy) * Math.min(speed, Math.abs(dy));
    charState.currentPosition.y += my;
  } else charState.currentPosition.y = charState.targetPosition.y;

  const moveLen = Math.sqrt(mx * mx + my * my);
  if (moveLen > 0) {
    charState.movementDirection.x = mx / moveLen;
    charState.movementDirection.y = my / moveLen;
  }

  const dz = charState.targetPosition.z - charState.currentPosition.z;
  if (Math.abs(dz) > 1) {
    const mz = Math.sign(dz) * Math.min(speed * 0.5, Math.abs(dz));
    charState.currentPosition.z += mz;
  } else {
    charState.currentPosition.z = charState.targetPosition.z;
  }

  // Only evaluate as 'moved' if the distance traveled is visually significant, 
  // preventing sub-pixel target smoothing from triggering the leg run cycle continuously.
  const charMoved = Math.abs(charState.currentPosition.x - prevX) > 0.5 || Math.abs(charState.currentPosition.y - prevY) > 0.5;

  if (charMoved) {
    charState.legTimer += speed * 0.1; // Progress leg run cycle !
    let targetRot = Math.atan2(charState.currentPosition.y - prevY, charState.currentPosition.x - prevX) * (180 / Math.PI);
    if (targetRot < 0)
      targetRot += 360;

    if (state.introPhase === 'playing') {
      // Prevent characters from turning their backs to the net when moving backwards
      if (isPlayer && targetRot > 0 && targetRot < 180) {
        targetRot = 270;
      } else if (!isPlayer && targetRot > 180 && targetRot < 360) {
        targetRot = 90;
      }
    }

    charState.targetPosition.rotation = targetRot;
  } else if (charState.legTimer > 0) {
    const phase = charState.legTimer % Math.PI;
    if (phase > 0.1 && phase < Math.PI - 0.1) charState.legTimer += speed * 0.1;
    else charState.legTimer = 0;
  }

  // Soft angular physical interpolation to targetPosition.rotation via modular shortest-path
  const diffRot = charState.targetPosition.rotation - charState.currentPosition.rotation;
  charState.currentPosition.rotation += ((diffRot + 540) % 360 - 180) * 0.1;

  // Converge racket at target position
  if (charState.racketTargetPosition && charState.racketCurrentPosition) {
    const rcp = charState.racketCurrentPosition;
    const rtp = charState.racketTargetPosition;

    rcp.pitch += (rtp.pitch - rcp.pitch) * 0.1;
    rcp.roll += (rtp.roll - rcp.roll) * 0.1;
    rcp.armX += (rtp.armX - rcp.armX) * 0.2;
    rcp.armY += (rtp.armY - rcp.armY) * 0.2;

    const dYaw = rtp.yaw - rcp.yaw;
    rcp.yaw += ((dYaw + Math.PI * 3) % (Math.PI * 2) - Math.PI) * 0.1;
  }

  return charMoved;
}

function resetRacketToNeutral(charState) {
  // Reset to neutral statically mapped 
  charState.racketTargetPosition.armX = -2 + 4 * Math.cos(Math.PI * 0.25);
  charState.racketTargetPosition.armY = 14 + 4 * Math.sin(Math.PI * 0.25);
  charState.racketTargetPosition.pitch = 0.0;
  charState.racketTargetPosition.yaw = Math.PI * 0.25;
  charState.racketTargetPosition.roll = RESTING_RACKET_ROLL;
}

/**
* Handles aim tracking, boundary logic, Z-leaps, and walk animation timers identically for characters.
*/
function processCharacter(charState, isPlayer, dt) {
  // 1. Process Approach Proximities & Leaps Target
  const isApproaching = isPlayer ? (state.ball.vy > 0) : (state.ball.vy < 0);

  // Clip characters to Court Bounds
  charState.targetPosition.x = clamp(charState.targetPosition.x, -PLAYABLE_HALF_WIDTH, PLAYABLE_HALF_WIDTH);
  if (isPlayer) {
    charState.targetPosition.y = clamp(charState.targetPosition.y, (COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height / 2) + 10, PLAYER_BASE_Y + PLAYABLE_OVERSHOOT_Y - 10);
  } else {
    charState.targetPosition.y = clamp(charState.targetPosition.y, NPC_BASE_Y - PLAYABLE_OVERSHOOT_Y + 10, (COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height / 2) - 10);
  }

  const intercept = charState.lastInterceptPoint;
  const now = Date.now();
  const distanceXY = distanceToBallXY(charState);
  // 3. Dynamic Limb Target Tracking
  if (canCharacterHit(isPlayer) && intercept && intercept.t >= 0 && distanceXY < 100) {

    function isRacketInRange(ballObject, racketPosition) {
      const speed = Math.sqrt(ballObject.vx * ballObject.vx + ballObject.vy * ballObject.vy);
      if (speed === 0) return true;

      const nx = ballObject.vx / speed;
      const ny = ballObject.vy / speed;

      // Vector from ball to racket
      const dx = racketPosition.x - ballObject.x;
      const dy = racketPosition.y - ballObject.y;

      // Project the distance vector onto the normalized velocity
      const dot = dx * nx + dy * ny;

      // If dot >= -10, the racket is behind the ball vector by no more than 10 units
      return dot <= 10;
    }

    const rotRad = charState.currentPosition.rotation * (Math.PI / 180);
    const armWorldX = charState.racketTargetPosition.armX * Math.cos(rotRad) - charState.racketTargetPosition.armY * Math.sin(rotRad);
    const armWorldY = charState.racketTargetPosition.armX * Math.sin(rotRad) + charState.racketTargetPosition.armY * Math.cos(rotRad);

    const racketWorldPos = {
      x: charState.currentPosition.x + armWorldX,
      y: charState.currentPosition.y + armWorldY
    };

    let reach = null;
    if (isRacketInRange(state.ball, racketWorldPos)) {
      reach = calculateArmReach(charState, state.ball);
    } else {
      reach = calculateArmReach(charState, intercept);
    }

    reach.z = clamp(reach.z, MIN_CROUCH, MAX_JUMP);

    const lastZChange = now - charState.lastZChangeTime;
    // Limit the characters vertical movement natively locking negative altitudes
    if (lastZChange > 150) {
      if (intercept.t < 0.3 && (now - charState.lastJumpTime > 500) && charState.currentPosition.z <= JUMP_Z) {
        charState.lastJumpTime = now;
        charState.targetPosition.z = reach.z; //Jump only when on the ground
        charState.lastZChangeTime = now;
      } else if (intercept.t < 0.25 && (now - charState.lastJumpTime > 500) && reach.z < RESTING_Z) {
        charState.targetPosition.z = reach.z; //Crouch
        charState.lastZChangeTime = now;
      } else if (reach.z >= RESTING_Z && reach.z < JUMP_Z) {
        charState.targetPosition.z = reach.z; //Not a jump, not a crouch
        charState.lastZChangeTime = now;
      } else {
        charState.targetPosition.z = RESTING_Z; //Else z is at rest
        charState.lastZChangeTime = now;
      }
    }

    charState.racketTargetPosition.armX = reach.x;
    charState.racketTargetPosition.armY = reach.y;

    // Direct racket targeting towards the center of the net anticipating the deflection arc identically
    const target = generateReturnBallHitCords(isPlayer, charState.racketCurrentPosition);

    target.z = (NET_HEIGHT * GAME_SCALE) + 5;

    charState.lastHitTarget = target;

    // Calculate the mathematical perfect aim unconditionally each frame
    let aim = null;

    if (isRacketInRange(state.ball, racketWorldPos)) {
      aim = calculateRacketReturnAimAngle(state.ball, charState, target);
    } else {
      aim = calculateRacketReturnAimAngle(intercept, charState, target);
    }

    charState.racketTargetPosition.pitch = aim.pitch;
    charState.racketTargetPosition.yaw = aim.yaw;
    charState.racketTargetPosition.roll = aim.roll;

  } else {
    charState.targetPosition.z = RESTING_Z;

    resetRacketToNeutral(charState);
  }

  // execute physical coordinate translations AFTER final dynamic Z bindings!
  const charMoved = convergePhysics(charState, dt, isPlayer);

  return { moved: charMoved };
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
  } else {
    // 1. Process Player Inputs & Movement
    if (state.resetting) {
      const serveOffset = COURT_INNER_BOUNDS.width * 0.4;
      const targetX = state.serveSide * serveOffset;
      moveCharacterTo(state.player, targetX, PLAYER_BASE_Y);
      moveCharacterTo(state.npc, -targetX, NPC_BASE_Y);
    } else {
      // Restrict active movement while idling awaiting the mechanical toss apex
      const isServingAndAwaitingToss = state.servePhase === 'idle' && state.isServe === 'player_serve';

      if (!isServingAndAwaitingToss) {
        if (inputManager.keys.TouchMove) {
          let joystickVectorX = inputManager.joystickVector.x;
          let joystickVectorY = inputManager.joystickVector.y;

          state.isJoystickActive = true;

          if (joystickVectorX !== 0 || joystickVectorY !== 0) {
            // Decrease Joystick sensitivity
            joystickVectorX = joystickVectorX / 3.0;
            joystickVectorY = joystickVectorY / 3.0;

            if (state.player.previousMoveToInterceptPoint && canCharacterHit(true)) {
              const target = state.player.previousMoveToInterceptPoint;
              const dx = target.x - state.player.targetPosition.x;
              const dy = target.y - state.player.targetPosition.y;
              const distToTarget = Math.sqrt(dx * dx + dy * dy);

              if (distToTarget > 5) {
                const idealX = dx / distToTarget;
                const idealY = dy / distToTarget;

                // Calculate how much the user is pushing towards the target (-1 to 1 depending on magnitude)
                const alignment = joystickVectorX * idealX + joystickVectorY * idealY;

                // If they are pushing functionally towards the target quadrant
                if (alignment > 0) {
                  const mag = Math.sqrt(joystickVectorX * joystickVectorX + joystickVectorY * joystickVectorY);

                  // 1. Gentle Trajectory Bend (80% user control, 20% perfect tracking)
                  joystickVectorX = (joystickVectorX * 0.8) + (idealX * mag * 0.2);
                  joystickVectorY = (joystickVectorY * 0.8) + (idealY * mag * 0.2);

                  // 2. Speed Amplification (Boosts vector length based on alignment accuracy)
                  joystickVectorX += idealX * (alignment * 0.3);
                  joystickVectorY += idealY * (alignment * 0.3);
                }
              }
            }

            state.previousPress = true;
            state.player.targetPosition.x = state.player.currentPosition.x + joystickVectorX * GAME_SCALE;
            state.player.targetPosition.y = state.player.currentPosition.y + joystickVectorY * GAME_SCALE;
          } else if (state.previousPress) {
            // Release snaps targetPosition to match feet instantly halting physics loops
            state.player.targetPosition.x = state.player.currentPosition.x;
            state.player.targetPosition.y = state.player.currentPosition.y;
            state.previousPress = false;
          }
        } else {
          let moveIntentX = 0;
          let moveIntentY = 0;

          state.isJoystickActive = false;

          if (inputManager.isPressed('ArrowUp') || inputManager.isPressed('KeyW')) moveIntentY -= 1;
          if (inputManager.isPressed('ArrowDown') || inputManager.isPressed('KeyS')) moveIntentY += 1;
          if (inputManager.isPressed('ArrowLeft') || inputManager.isPressed('KeyA')) moveIntentX -= 1;
          if (inputManager.isPressed('ArrowRight') || inputManager.isPressed('KeyD')) moveIntentX += 1;

          if (moveIntentX !== 0 || moveIntentY !== 0) {
            // Normalize diagonal vectors so the player doesn't move 1.4x faster
            const len = Math.sqrt(moveIntentX * moveIntentX + moveIntentY * moveIntentY);
            moveIntentX = (moveIntentX / len) * 40;
            moveIntentY = (moveIntentY / len) * 40;

            state.previousPress = true;
            state.player.targetPosition.x = state.player.currentPosition.x + moveIntentX * GAME_SCALE; // Extend convergence target against camera mapping
            state.player.targetPosition.y = state.player.currentPosition.y + moveIntentY * GAME_SCALE;
          } else if (state.previousPress) {
            // Release snaps targetPosition to match feet instantly halting physics loops
            state.player.targetPosition.x = state.player.currentPosition.x;
            state.player.targetPosition.y = state.player.currentPosition.y;
            state.previousPress = false;
          }
        }
      }
    }

    processBallMovement(dt, (netY) => {

      //Update the intercept points for both players
      setNewInterceptPoints()

      if (state.bounceCount === 1 && !state.resetting) {
        if (!state.lastHitter) {
          // Serve toss plummeted to the floor before the racket struck it
          triggerFault(state.isServe === 'player_serve');
        } else {
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
              state.isServe = 'in_play'; // Valid serve, rally is now open
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
      }

      // Double-bounce rule: If it lands twice validly before being intercepted, the person who failed to return it loses
      if (state.bounceCount === 2 && !state.resetting) {
        if (state.ball.y > COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height / 2) {
          triggerPointReset(true);  // Bounced twice on Player's side -> NPC scored
        } else {
          triggerPointReset(false); // Bounced twice on NPC's side -> Player scored
        }
      }
    });

    function moveToIntercept(character) {
      if (!character.lastInterceptPoint) {
        setNewInterceptPoints();
      }

      if (character.previousMoveToInterceptPoint) {
        if (character.lastInterceptPoint.x == character.previousMoveToInterceptPoint.x && character.lastInterceptPoint.y == character.previousMoveToInterceptPoint.y) {
          return;
        }
      }

      const target = getOptimalInterceptPosition(character, character.lastInterceptPoint);

      moveCharacterTo(character, target.x, target.y, RESTING_Z);

      character.previousMoveToInterceptPoint = character.lastInterceptPoint;
    }

    if (state.isJoystickActive && distanceToBallXY(state.player) < 100 && canCharacterHit(true)) {
      moveToIntercept(state.player);
    }

    const playerAim = processCharacter(state.player, true, dt);
    const playerMoved = playerAim.moved;

    if (!playerMoved) {
      state.player.targetPosition.rotation = 270;
    }

    //If we can hit it move to intercept of if the player has just hit the serve ball
    if (canCharacterHit(false)) {
      moveToIntercept(state.npc);
    }

    const npcAim = processCharacter(state.npc, false, dt);
    const npcMoved = npcAim.moved;

    if (!npcMoved) {
      state.npc.targetPosition.rotation = 90;
    }

    // Ensure logical collision trackers properly pull the latest bounds here
    const visualBallY = state.ball.y - state.ball.z;

    if (state.resetting && !playerMoved && !npcMoved) {
      if (state.resetDelayTimer > 0) {
        state.resetDelayTimer -= dt;
      } else {
        serveBall(state.nextServerIsPlayer ? state.player : state.npc);
      }
    }

    // 7. Racket Deflections
    // Process racket scoops BEFORE the floor formally terminates the rally if they collide on the exact same frame!
    processRacketDeflections(visualBallY, (isPlayer) => {

      let payload;
      if (isPlayer) {
        payload = state.player.lastHitTarget || generateReturnBallHitCords(isPlayer, state.player.racketCurrentPosition);
      } else {
        payload = state.npc.lastHitTarget || generateReturnBallHitCords(isPlayer, state.npc.racketCurrentPosition);
      }

      let returnSpeed = Math.sqrt(state.ball.vx * state.ball.vx + state.ball.vy * state.ball.vy) * (isPlayer ? 1.05 : 1.1);

      if (state.isServe !== 'in_play') {
        returnSpeed = BALL_SPEED * (isPlayer ? 0.8 : 0.65);
      }

      state.rallyCount++;
      state.lastHitter = isPlayer ? 'player' : 'npc';
      state.bounceCount = 0;
      hitBallToTarget(payload.x, payload.y, returnSpeed);

      const soundFile = isPlayer ? '/media/hit_tennis_ball.mp3' : '/media/hit_tennis_ball2.mp3';
      let sound = soundManager.playPooled(soundFile, 0.7 + Math.random() * 0.5);
      sound.setRate(0.85 + Math.random() * 0.3);

      state.ball.z = Math.max(10, state.ball.z); // Simulate ground strike lift 

      setNewInterceptPoints();

      if (isPlayer) {
        if (state.isServe === 'player_serve' && state.isServe !== 'in_play') {
          const landingSpot = getLandingSpot(state.ball);
          moveCharacterTo(state.npc, landingSpot.x + (40 * GAME_SCALE), landingSpot.y - (220 * GAME_SCALE * 0.7));
        } else {
          moveCharacterTo(state.npc, COURT_INNER_BOUNDS.x + (COURT_INNER_BOUNDS.width / 2) * (0.5 + Math.random()), NPC_BASE_Y + (50 * GAME_SCALE * (0.5 + Math.random())));
        }
      }
    });

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
  * draws a tennis racket starting from the wrist location.
  * @param {CanvasRenderingContext2D} ctx - Canvas context.
  * @param {Object} limbs - Current Limb positions. 
  * @param {number} swingAngle - Rotational swing adjustment.
  */
  function drawRacket(ctx, limbs, pitch = 0, yaw = 0, roll = 1.0, transformData = null, isShadow = false) {
    const pitchMult = Math.max(0.05, Math.abs(Math.cos(pitch)));
    const rx = Math.max(1, 8 * roll);

    if (ctx && limbs) {
      ctx.save();
      ctx.translate(limbs.rightArmX, limbs.rightArmY);

      // Align the racket 90 degrees to point along the +X forward vector 
      ctx.rotate(yaw + Math.PI / 2);

      // Draw handle
      const handleLen = 15 * pitchMult;
      if (!isShadow) {
        ctx.fillStyle = '#2c3e50';
        ctx.fillRect(-2, -handleLen + 5 * pitchMult, 4, handleLen);
      }

      // Draw structural frame
      if (!isShadow) {
        ctx.strokeStyle = '#e74c3c';
        ctx.lineWidth = 2;
      }
      ctx.beginPath();
      const headCy = -18 * pitchMult;
      const headRy = 12 * pitchMult;
      if (ctx.ellipse) {
        ctx.ellipse(0, headCy, rx, Math.max(1, headRy), 0, 0, Math.PI * 2);
      } else {
        ctx.arc(0, headCy, Math.max(rx, 10 * pitchMult), 0, Math.PI * 2);
      }

      if (isShadow) {
        const radius = Math.max(1, Math.max(rx, headRy)) + 10.0;
        const racketShadow = ctx.createRadialGradient(0, headCy, 0, 0, headCy, radius);
        racketShadow.addColorStop(0, 'rgba(0, 0, 0, 0.1)'); // Dark core
        racketShadow.addColorStop(1, 'rgba(0, 0, 0, 0)'); // Blurred feathered out edge

        ctx.fillStyle = racketShadow;
        ctx.fill();
        ctx.restore();
        return;
      }

      ctx.stroke();

      // Draw strings
      ctx.save();
      ctx.clip();
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
      ctx.restore();

      // Extract raw rendering matrix transformations 
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

    // Always inform caller of the exact ellipse bounds rendered if they care
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

  // Game native virtual layout dimension explicitly fixed to preserve the static PNG mapping projection independent of mechanical overshoot bounds
  const virtualGameHeight = COURT_INNER_BOUNDS.height + (75 * 2) + 20;

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

  const npcLimbs = getLimbs(state.npc, state.npc.racketCurrentPosition.armX, state.npc.racketCurrentPosition.armY);
  const playerLimbs = getLimbs(state.player, state.player.racketCurrentPosition.armX, state.player.racketCurrentPosition.armY);

  function drawCharacterShadowed(ctx, characterData, charState, limbs, aimPitch, aimYaw, aimRoll) {
    ctx.save();
    ctx.translate(centerX + charState.currentPosition.x, charState.currentPosition.y);
    ctx.scale(camera.zoom * COURT_SCALE, camera.zoom * COURT_SCALE);

    // Dynamic spherical gradient shadows replacing native filter arrays
    const bodyShadow = ctx.createRadialGradient(-2, 4, 3, -2, 4, 15);
    bodyShadow.addColorStop(0, 'rgba(0, 0, 0, 0.5)'); // Core dark opacity
    bodyShadow.addColorStop(1, 'rgba(0, 0, 0, 0)');   // Completely blurred edge

    ctx.fillStyle = bodyShadow;
    ctx.beginPath();
    ctx.arc(-2, 4, 15, 0, Math.PI * 2);
    ctx.fill();

    // Racket bounds casting (overhead 11am)
    ctx.save();
    ctx.translate(-2, 4); // Uniform shadow offset
    ctx.rotate(charState.currentPosition.rotation * (Math.PI / 180));
    drawRacket(ctx, limbs, aimPitch, aimYaw, aimRoll, null, true);
    ctx.restore();

    ctx.rotate(charState.currentPosition.rotation * (Math.PI / 180));
    characterData.rotation = charState.currentPosition.rotation;

    const shoeZ = Math.max(0, charState.currentPosition.z - JUMP_Z);
    const torsoZ = Math.max(0, charState.currentPosition.z) - shoeZ;

    if (shoeZ > 0) {
      ctx.save();
      // Apply uniform shadow offset un-rotated
      ctx.rotate(-charState.currentPosition.rotation * (Math.PI / 180));
      ctx.translate(-2, 4);
      ctx.rotate(charState.currentPosition.rotation * (Math.PI / 180));

      const shadowRadius = Math.max(1.0, 4 - (shoeZ * 0.05));
      const opacity = Math.max(0.1, 0.4 - (shoeZ * 0.005));
      ctx.fillStyle = `rgba(0, 0, 0, ${opacity})`;

      ctx.beginPath();
      ctx.ellipse(limbs.leftLegEndX, limbs.leftLegEndY, shadowRadius * 1.5, shadowRadius, 0, 0, Math.PI * 2);
      ctx.fill();

      ctx.beginPath();
      ctx.ellipse(limbs.rightLegEndX, limbs.rightLegEndY, shadowRadius * 1.5, shadowRadius, 0, 0, Math.PI * 2);
      ctx.fill();
      ctx.restore();
    }

    // Elevate the shoes vertically off the absolute floor if jumping (exceeding JUMP_Z leg extension)
    ctx.rotate(-charState.currentPosition.rotation * (Math.PI / 180));
    ctx.translate(0, -shoeZ / (camera.zoom * COURT_SCALE));
    ctx.rotate(charState.currentPosition.rotation * (Math.PI / 180));

    // Draw the shoes anchored to the translation floor
    characterManager.drawShoe(ctx, limbs.leftLegEndX, limbs.leftLegEndY, characterData.shoeColor || '#1a252f', true);
    characterManager.drawShoe(ctx, limbs.rightLegEndX, limbs.rightLegEndY, characterData.shoeColor || '#1a252f', false);

    // Dynamic Physics Legs: Draw stretching joint connections perfectly linking the jumping Torso cleanly down to the Shoes!
    const torsoOffsetScreen = -torsoZ / (camera.zoom * COURT_SCALE);
    ctx.strokeStyle = characterData.pantsColor || '#2980b9';
    ctx.lineWidth = 4.5;
    ctx.lineCap = 'round';

    const drawStretchingLeg = (startX, startY, endX, endY) => {
      ctx.beginPath();
      ctx.save();
      // Locate the hip anchor matrix seamlessly inside the unrotated Torso hovering frame
      ctx.rotate(-charState.currentPosition.rotation * (Math.PI / 180));
      ctx.translate(0, torsoOffsetScreen);
      ctx.rotate(charState.currentPosition.rotation * (Math.PI / 180));
      ctx.moveTo(startX, startY);
      ctx.restore();
      // Attach to the physically planted/sliding shoe origin
      ctx.lineTo(endX, endY);
      ctx.stroke();
    };

    drawStretchingLeg(limbs.leftLegStartX, limbs.leftLegStartY, limbs.leftLegEndX, limbs.leftLegEndY);
    drawStretchingLeg(limbs.rightLegStartX, limbs.rightLegStartY, limbs.rightLegEndX, limbs.rightLegEndY);

    // Elevate visual translation mapping exclusively on the World -Y axis for the upper torso natively!
    // The torso absorbs the initial altitude delta (unbending legs) capped at JUMP_Z
    ctx.rotate(-charState.currentPosition.rotation * (Math.PI / 180));
    ctx.translate(0, -torsoZ / (camera.zoom * COURT_SCALE));
    ctx.rotate(charState.currentPosition.rotation * (Math.PI / 180));

    const transform = {
      offsetX,
      offsetY,
      scale,
      centerX,
      baseRotation: charState.currentPosition.rotation,
      elevateZ: charState.currentPosition.z,
      targetStateObj: charState.racketCurrentPosition,
      courtScale: COURT_SCALE
    };
    drawRacket(ctx, limbs, aimPitch, aimYaw, aimRoll, transform);
    characterManager.drawHumanoidUpperBody(ctx, characterData, limbs);
    ctx.restore();
  }

  // 1. Render NPC
  drawCharacterShadowed(ctx, { ...npc, x: 0, y: 0 }, state.npc, npcLimbs, state.npc.racketCurrentPosition.pitch, state.npc.racketCurrentPosition.yaw, state.npc.racketCurrentPosition.roll);

  // 2. Render Ball Physics Elements (Drawn before player to prevent top-overlap)
  function drawBall(ctx, ballState, cx, courtScale) {
    // Ball's vertical Ground Shadow
    ctx.save();
    const shadowRadius = Math.max(0.1, Math.max(2 * courtScale, (BALL_RADIUS * 2 - ballState.z * 0.05) * courtScale));
    // Ensure the ball shadow respects the global 11am offset
    const sx = cx + ballState.x - 2;
    const sy = ballState.y + 4;

    const ballGrad = ctx.createRadialGradient(sx, sy, 0, sx, sy, shadowRadius);
    ballGrad.addColorStop(0, 'rgba(0, 0, 0, 0.6)');
    ballGrad.addColorStop(1, 'rgba(0, 0, 0, 0)');

    ctx.beginPath();
    ctx.fillStyle = ballGrad;
    ctx.arc(sx, sy, shadowRadius, 0, Math.PI * 2);
    ctx.fill();
    ctx.restore();

    // Physical Ball Emoji
    ctx.save();
    ctx.font = `${Math.max(6, BALL_RADIUS * 2 * courtScale)}px sans-serif`;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';

    // Translate ball from wherever the physical mechanics pipeline dictates 
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

  // Bounce crosshair for admins
  if (window.isAdmin) {
    const landingSpot = getLandingSpot(state.ball);

    const landX = centerX + landingSpot.x;
    const landY = landingSpot.y;

    const crosshairColor = state.resetting ? 'rgba(128, 128, 128, 0.8)' : 'rgba(255, 0, 0, 0.8)';
    drawCrosshair(ctx, landX, landY, crosshairColor);
  }

  // Draw the interpolated intercept prediction as a Green X
  if (canCharacterHit(true) && state.ball.vy !== 0 && !state.resetting) {
    const bestPoint = state.player.lastInterceptPoint;

    // Only draw the visual if it predicts an approach
    if (bestPoint && bestPoint.t >= 0) {
      const targetHitX = centerX + bestPoint.x;
      const targetHitY = bestPoint.y - bestPoint.z;

      // Smoothly track the raw physics target explicitly
      if (!state.player.visualInterceptTarget) {
        state.player.visualInterceptTarget = { x: targetHitX, y: targetHitY };
      } else {
        state.player.visualInterceptTarget.x += (targetHitX - state.player.visualInterceptTarget.x) * 0.25;
        state.player.visualInterceptTarget.y += (targetHitY - state.player.visualInterceptTarget.y) * 0.25;
      }

      drawCrosshair(ctx, state.player.visualInterceptTarget.x, state.player.visualInterceptTarget.y, 'rgba(46, 204, 113, 0.9)');
    } else {
      state.player.visualInterceptTarget = null;
    }
  } else {
    state.player.visualInterceptTarget = null;
  }

  // Draw the exact NPC intercept prediction as an Orange X for Admins
  if (window.isAdmin && canCharacterHit(false) && state.ball.vy !== 0 && !state.resetting) {
    const bestPoint = state.npc.lastInterceptPoint;
    if (bestPoint && bestPoint.t >= 0) {
      const hitX = centerX + bestPoint.x;
      const hitY = bestPoint.y - bestPoint.z;
      drawCrosshair(ctx, hitX, hitY, 'rgba(230, 126, 34, 0.9)');
    }
  }

  // Draw the yellow X for the Toss Ground Target
  if (window.isAdmin && state.isServe !== 'in_play' && state.tossTarget && !state.resetting) {
    const hitX = centerX + state.tossTarget.x;
    const hitY = state.tossTarget.y; // The tossTarget identically mirrors the ground geometry!
    drawCrosshair(ctx, hitX, hitY, 'rgba(241, 196, 15, 0.9)');
  }

  // 3. Render Player
  drawCharacterShadowed(ctx, window.init.myCharacter, state.player, playerLimbs, state.player.racketCurrentPosition.pitch, state.player.racketCurrentPosition.yaw, state.player.racketCurrentPosition.roll);

  if (state.introPhase === 'playing') {
    drawBall(ctx, state.ball, centerX, COURT_SCALE);
  }

  // 3. Admin Hitbox Diagnostic Visualization Overlay
  if (window.isAdmin) {
    const pHitbox = state.player.racketCurrentPosition;
    const nHitbox = state.npc.racketCurrentPosition;

    ctx.save();
    ctx.strokeStyle = 'rgba(255, 0, 0, 0.8)';
    ctx.lineWidth = 1;

    // Draw Elliptical Target Hitbox representations identical to logic
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

    // Draw Playable Overshoot Boundaries mapped exactly against physics clamps!
    ctx.strokeStyle = 'rgba(255, 165, 0, 0.5)'; // Orange dashed boundary 
    ctx.setLineDash([5, 5]);
    const overMinY = NPC_BASE_Y - PLAYABLE_OVERSHOOT_Y + 10;
    const overMaxY = PLAYER_BASE_Y + PLAYABLE_OVERSHOOT_Y - 10;
    ctx.strokeRect(centerX - PLAYABLE_HALF_WIDTH, overMinY, PLAYABLE_HALF_WIDTH * 2, overMaxY - overMinY);
    ctx.setLineDash([]);

    // Draw the halfway net line within the bounds
    const netY = COURT_INNER_BOUNDS.y + COURT_INNER_BOUNDS.height / 2;
    ctx.beginPath();
    ctx.moveTo(centerX + COURT_INNER_BOUNDS.x, netY);
    ctx.lineTo(centerX + COURT_INNER_BOUNDS.x + COURT_INNER_BOUNDS.width, netY);
    ctx.stroke();

    // Draw the active service box limits in purple
    if (state.activeServiceBox && state.isServe !== 'in_play' && state.servePhase !== 'idle') {
      const box = state.activeServiceBox;
      ctx.fillStyle = 'rgba(155, 89, 182, 0.4)'; // Vibrant purple
      ctx.fillRect(centerX + box.minX, box.minY, box.maxX - box.minX, box.maxY - box.minY);
    }

    ctx.restore();
  }

  ctx.restore(); // Restore from world/camera zoom and offset

  if (window.isAdmin) {
    // 4. Draw HUD Overlays (Mapped directly to canvas container size)
    drawDiagnosticsOverlay(state.player.racketCurrentPosition.pitch, state.player.racketCurrentPosition.yaw, state.player.racketCurrentPosition.roll);
  }
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

    // Confine graph lines inside the glassmorphic panel!
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
