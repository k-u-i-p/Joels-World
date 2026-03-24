import { gameLoop } from '../gameloop.js';
import { inputManager } from '../input.js';
import { characterManager } from '../characters.js';
import { physicsEngine } from '../physics.js';
import { camera, player, scene, threeCamera, renderer } from '../main.js';
import { mapManager } from '../maps.js';
import { soundManager } from '../sound.js';
import * as THREE from 'three';

const canvas = document.getElementById('uiCanvas');
const ctx = canvas.getContext('2d');

let minigameActive = false;

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
    currentPosition: { x: 0, y: 0, z: 0, rotation: 90 },
    targetPosition: { x: 0, y: 0, z: 0, rotation: 90 },
    width: 40,
    height: 40,
    gender: myChar.gender || 'male',
    shirt_color: myChar.shirt_color || '#3498db',
    pants_color: myChar.pants_color || '#2c3e50',
    arm_color: myChar.arm_color || '#3498db',
    shoe_color: myChar.shoe_color || '#111111',
    head: myChar.head || 'male_hair_short',
    hair_color: myChar.hair_color || '#000000',
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
      currentPosition: { x: spawnPoints[i].x, y: spawnPoints[i].y, z: 0, rotation: Math.random() * 360 },
      targetPosition: { x: spawnPoints[i].x, y: spawnPoints[i].y, z: 0, rotation: Math.random() * 360 },
      width: 35,
      height: 35,
      gender: i % 2 === 0 ? 'male' : 'female',
      shirt_color: colors[i],
      pants_color: '#2c3e50',
      arm_color: colors[i],
      shoe_color: '#111111',
      head: i % 2 === 0 ? 'male_hair_messy' : 'female_hair_ponytail',
      hair_color: '#000000',
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

  // Natively block out WebGL void using the playground grass color
  scene.background = new THREE.Color('#7bed9f');

  const minigameUi = document.getElementById('minigame-ui-container');
  if (minigameUi) minigameUi.style.display = 'block';

  const tagScoreboard = document.getElementById('tag-scoreboard');
  if (tagScoreboard) tagScoreboard.style.display = 'block';

  initPlayers();

  // Background music
  soundManager.playBackground('/media/playground_sound_effect.mp3', 0.4);

  // Setup camera
  camera.x = state.players[0].currentPosition.x;
  camera.y = state.players[0].currentPosition.y;
  camera.zoom = 1.2;

  // Setup UI
  const mapBtn = document.getElementById('map-button');
  const exitBtn = document.getElementById('exit-button');
  if (mapBtn) mapBtn.style.display = 'none';
  if (exitBtn) {
    exitBtn.style.display = 'flex';
    exitBtn.onclick = () => {
      import('../ui.js').then(({ uiManager }) => {
        uiManager.showActionDialog('Leave Game?', () => {
          import('../network.js').then(({ networkClient }) => {
            networkClient.send({ type: 'change_map', mapId: 0 }); // Back to Junior School
          });
        });
      });
    };
  }

  gameLoop.registerFunction(run);
}

function processNPCLogic(npc, itPlayer, dt) {
  const isIt = (npc.id === state.itId);
  let dx = 0, dy = 0;
  let targetAngle = null;
  let shouldMove = true;
  let speedMult = 1.0;

  if (isIt) {
    // If IT, chase the closest player
    let closestDist = Infinity;
    let target = null;

    for (const p of state.players) {
      if (p.id === npc.id) continue;
      // Tag cooldown logic check: don't chase if invincible
      if (state.invincibleTime > 0) continue;

      const dist = Math.sqrt((p.targetPosition.x - npc.targetPosition.x) ** 2 + (p.targetPosition.y - npc.targetPosition.y) ** 2);
      if (dist < closestDist) {
        closestDist = dist;
        target = p;
      }
    }

    if (target) {
      targetAngle = Math.atan2(target.targetPosition.y - npc.targetPosition.y, target.targetPosition.x - npc.targetPosition.x);
    } else {
      shouldMove = false; // No one to chase? Rest!
    }
  } else {
    // Flee from IT
    if (itPlayer) {
      const dist = Math.sqrt((itPlayer.targetPosition.x - npc.targetPosition.x) ** 2 + (itPlayer.targetPosition.y - npc.targetPosition.y) ** 2);

      // Initialize states
      if (!npc.tagState) npc.tagState = 'idle';
      if (!npc.tauntAngleOffset) npc.tauntAngleOffset = (Math.random() - 0.5) * Math.PI;

      // Pure state machine thresholds
      if (dist < 250) {
        npc.tagState = 'flee';
      } else if (dist > 350 && npc.tagState === 'flee') {
        npc.tagState = 'idle';
      } else if (dist > 550) {
        npc.tagState = 'taunt';
      } else if (dist < 400 && npc.tagState === 'taunt') {
        npc.tagState = 'idle';
        // Reroll offset for next taunt
        npc.tauntAngleOffset = (Math.random() - 0.5) * Math.PI;
      }

      // Purge the naive invincibility "idle" override. Fleers MUST physically run to escape the cooldown gap. 
      // Execute State Behaviors
      if (npc.tagState === 'idle') {
        shouldMove = false; // Resting / Catching breath

        // Ensure they causally gaze towards IT with some random shifting
        if (npc.idleGazeOffset === undefined || Math.random() < 1 * dt) {
          // Change gaze focus roughly once per second (+/- 45 degrees)
          npc.idleGazeOffset = (Math.random() - 0.5) * (Math.PI / 2);
        }

        const angleTowards = Math.atan2(itPlayer.targetPosition.y - npc.targetPosition.y, itPlayer.targetPosition.x - npc.targetPosition.x);
        const lookAngle = (angleTowards + npc.idleGazeOffset) * (180 / Math.PI);
        npc.targetPosition.rotation = lookAngle; // Turn head smoothly

      } else if (npc.tagState === 'flee') {
        targetAngle = Math.atan2(npc.targetPosition.y - itPlayer.targetPosition.y, npc.targetPosition.x - itPlayer.targetPosition.x); // Run strictly away from IT
        speedMult = 1.0; // Sprint
      } else if (npc.tagState === 'taunt') {
        // Move back towards IT, but slightly off-axis so they don't form a conga line!
        const angleTowards = Math.atan2(itPlayer.targetPosition.y - npc.targetPosition.y, itPlayer.targetPosition.x - npc.targetPosition.x);
        targetAngle = angleTowards + npc.tauntAngleOffset;
        speedMult = 0.6; // Jog/Walk
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
      const testX = npc.targetPosition.x + Math.cos(testAngle) * 60;
      const testY = npc.targetPosition.y + Math.sin(testAngle) * 60;

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

    // Apply state-specific speed multiplier
    finalSpeed *= speedMult;

    const moveX = (dx / len) * finalSpeed * dt;
    const moveY = (dy / len) * finalSpeed * dt;

    // Natively handle physical barriers using the engine's standard sliding logic!
    const mockEntity = { id: npc.id, x: npc.targetPosition.x, y: npc.targetPosition.y, width: npc.width, height: npc.height };
    const collisionPlayers = state.players.map(p => ({ id: p.id, x: p.targetPosition.x, y: p.targetPosition.y, width: p.width, height: p.height }));

    const result = physicsEngine.processMovement(
      mockEntity,
      moveX,
      moveY,
      window.init?.objects || [],
      window.init?.mapData,
      false,
      collisionPlayers
    );

    npc.targetPosition.x = result.newX;
    npc.targetPosition.y = result.newY;

    if (moveX !== 0 || moveY !== 0) {
      const newRotAngle = Math.atan2(moveY, moveX) * (180 / Math.PI);
      npc.targetPosition.rotation = newRotAngle;

    }
  }
}


function convergePhysics(charState, dt) {
  const speed = 600 * dt;
  const dx = charState.targetPosition.x - charState.currentPosition.x;
  const dy = charState.targetPosition.y - charState.currentPosition.y;
  const dz = charState.targetPosition.z - charState.currentPosition.z;

  if (Math.abs(dx) > 0.5) charState.currentPosition.x += Math.sign(dx) * Math.min(speed, Math.abs(dx));
  else charState.currentPosition.x = charState.targetPosition.x;

  if (Math.abs(dy) > 0.5) charState.currentPosition.y += Math.sign(dy) * Math.min(speed, Math.abs(dy));
  else charState.currentPosition.y = charState.targetPosition.y;

  if (Math.abs(dz) > 0.5) charState.currentPosition.z += Math.sign(dz) * Math.min(speed, Math.abs(dz));
  else charState.currentPosition.z = charState.targetPosition.z;

  charState.currentPosition.rotation = lerpRotation(charState.currentPosition.rotation, charState.targetPosition.rotation, 800 * dt);

  const moveLen = Math.sqrt(dx * dx + dy * dy);
  if (moveLen > 0.1) {
    charState.legTimer += 15 * dt;
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
    const mockEntity = { id: localP.id, x: localP.targetPosition.x, y: localP.targetPosition.y, width: localP.width, height: localP.height };
    const collisionPlayers = state.players.map(p => ({ id: p.id, x: p.targetPosition.x, y: p.targetPosition.y, width: p.width, height: p.height }));

    const result = physicsEngine.processMovement(
      mockEntity,
      finalMoveX,
      finalMoveY,
      window.init?.objects || [],
      window.init?.mapData,
      false,
      collisionPlayers
    );

    localP.targetPosition.x = result.newX;
    localP.targetPosition.y = result.newY;

    if (finalMoveX !== 0 || finalMoveY !== 0) {
      const targetAngle = Math.atan2(finalMoveY, finalMoveX) * (180 / Math.PI);
      localP.targetPosition.rotation = targetAngle;

    }
  }

  // Update camera smoothly
  camera.x += (localP.currentPosition.x - camera.x) * 5 * dt;
  camera.y += (localP.currentPosition.y - camera.y) * 5 * dt;
}

function processTagCollisions() {
  if (state.invincibleTime <= 0) {
    const currentIt = state.players.find(p => p.id === state.itId);
    if (currentIt) {
      for (const p of state.players) {
        if (p.id === currentIt.id) continue;

        const dist = Math.sqrt((p.currentPosition.x - currentIt.currentPosition.x) ** 2 + (p.currentPosition.y - currentIt.currentPosition.y) ** 2);
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

  for (const p of state.players) {
    convergePhysics(p, dt);
  }

  draw(dt);
}

function draw(dt) {
  const dpr = window.devicePixelRatio || 1;
  const ui = document.getElementById('uiCanvas');
  if (ui && (ui.width !== window.innerWidth * dpr)) {
    ui.width = window.innerWidth * dpr;
    ui.height = window.innerHeight * dpr;
    ui.style.width = window.innerWidth + 'px';
    ui.style.height = window.innerHeight + 'px';
  }
  const viewportWidth = canvas.clientWidth;
  const viewportHeight = canvas.clientHeight;

  // Erase the UI natively granting a transparent window piercing directly down into the hardware GameCanvas layer
  ctx.clearRect(0, 0, canvas.width, canvas.height);

  // Set THREE.js orthographic bounds matching the 2D scaling dynamically
  const camZoom = camera.zoom || 1;
  const aspectW = (viewportWidth / camZoom) / 2;
  const aspectH = (viewportHeight / camZoom) / 2;

  const pitchCos = Math.max(0.15, Math.cos(threeCamera.rotation.x));
  threeCamera.left = -aspectW;
  threeCamera.right = aspectW;
  // Account for pitch stretching the vertical height dynamically
  threeCamera.top = aspectH / pitchCos;
  threeCamera.bottom = -aspectH / pitchCos;

  threeCamera.position.set(camera.x, -camera.y, 1000);
  threeCamera.zoom = camera.zoom;
  threeCamera.updateProjectionMatrix();

  mapManager.updateDynamicModels(window.init?.objects);

  let drawnBaseChars = false;

  // Draw mapped Z layers from the native JSON loader mapping 3D arrays seamlessly!
  mapManager.layers.forEach((layerGroup, z) => {
    if (!layerGroup) return;

    if (z >= 5 && !drawnBaseChars) {
      const sortedPlayers = [...state.players].sort((a, b) => a.currentPosition.y - b.currentPosition.y);
      for (const p of sortedPlayers) {
        p.x = p.currentPosition.x;
        p.y = p.currentPosition.y;
        p.legAnimationTime = p.legTimer;
        p.rotation = p.currentPosition.rotation;
        characterManager.drawCharacter(p, !p.isLocalPlayer, 'base', scene, player, null, camera.zoom, viewportWidth, viewportHeight, threeCamera);
      }
      drawnBaseChars = true;
    }

    mapManager.drawLayer(z, scene);
  });

  if (!drawnBaseChars) {
    const sortedPlayers = [...state.players].sort((a, b) => a.currentPosition.y - b.currentPosition.y);
    for (const p of sortedPlayers) {
      p.x = p.currentPosition.x;
      p.y = p.currentPosition.y;
      p.legAnimationTime = p.legTimer;
      p.rotation = p.currentPosition.rotation;
      characterManager.drawCharacter(p, !p.isLocalPlayer, 'base', scene, player, null, camera.zoom, viewportWidth, viewportHeight, threeCamera);
    }
  }

  // Draw WebGL hardware rendering pipeline directly natively filling the window
  renderer.render(scene, threeCamera);

  // Update HTML DOM overlays natively replacing raw 2D Canvas injections
  const roundEl = document.getElementById('tag-round');
  if (roundEl) roundEl.innerText = `Round: ${state.round}`;

  const timeEl = document.getElementById('tag-time');
  if (timeEl) timeEl.innerText = `Time: ${Math.ceil(state.timeRemaining)}s`;

  const warningEl = document.getElementById('tag-it-warning');
  if (warningEl) warningEl.style.display = (state.itId === player.id) ? 'block' : 'none';

  const markerEl = document.getElementById('tag-it-marker');
  const currentIt = state.players.find(p => p.id === state.itId);

  if (currentIt && markerEl) {
    markerEl.style.display = 'block';
    const projected = new THREE.Vector3(currentIt.x, -currentIt.y, 35).project(threeCamera); // Lift marker directly above character geometry
    const screenX = (projected.x * 0.5 + 0.5) * viewportWidth;
    const screenY = (-(projected.y * 0.5) + 0.5) * viewportHeight;
    markerEl.style.left = `${screenX}px`;
    markerEl.style.top = `${screenY}px`;
  } else if (markerEl) {
    markerEl.style.display = 'none';
  }
}

/** Stop minigame loop externally if needed */
export function cleanupMinigame() {
  minigameActive = false;
  soundManager.stopBackground();
  const ui = document.getElementById('uiCanvas');
  if (ui) { const x = ui.getContext('2d'); x.clearRect(0, 0, ui.width, ui.height); }

  // Restoring global canvas conditions perfectly upon map transfer natively ensuring seamless handoffs
  scene.background = null;

  const tagScoreboard = document.getElementById('tag-scoreboard');
  if (tagScoreboard) tagScoreboard.style.display = 'none';
  const tagMarker = document.getElementById('tag-it-marker');
  if (tagMarker) tagMarker.style.display = 'none';

  const mapBtn = document.getElementById('map-button');
  const exitBtn = document.getElementById('exit-button');
  if (mapBtn) mapBtn.style.display = 'inline-block';
  if (exitBtn) exitBtn.style.display = 'none';

  state.players.forEach(p => {
    characterManager.disposeCharacter(p, scene);
  });
}
