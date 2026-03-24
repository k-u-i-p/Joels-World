import { emotes } from './emotes.js';
import { physicsEngine } from './physics.js';
import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { uiManager } from './ui.js';

export var sharedShoeMeshL = null;
export var sharedShoeMeshR = null;

const awaitingShoeRigs = [];

const cachedHeads = {};
const pendingHeads = {};

const cachedHoldingModels = {};
const pendingHoldingModels = {};

export const MALE_HEADS = {
  'male_hair_long': { scale: 90, z: -10.5 },
  'male_hair_messy': { scale: 90, z: -10.5 },
  'male_hair_short': { scale: 90, z: -10.5 },
  'male_hair_short_2': { scale: 90, z: -10.5 },
  'male_hair_spiky': { scale: 90, z: -10.5 },
  'male_hair_bald': { scale: 90, z: -10.5 }
};

export const FEMALE_HEADS = {
  'female_hair_bun': { scale: 85, z: -10.5 },
  'female_hair_long': { scale: 85, z: -10.5 },
  'female_hair_long_2': { scale: 85, z: -10.5 },
  'female_hair_long_3': { scale: 85, z: -10.5 },
  'female_hair_messy': { scale: 85, z: -10.5 },
  'female_hair_neat': { scale: 85, z: -10.5 },
  'female_hair_pigtails': { scale: 85, z: -10.5 },
  'female_hair_pigtails_2': { scale: 85, z: -10.5 },
  'female_hair_ponytail': { scale: 32, z: -10.5 },
  'female_hair_short': { scale: 85, z: -10.5 },
  'female_hair_short_2': { scale: 85, z: -10.5 }
};

const HOLDABLE_OBJECTS = {
  tennis_racket: {
    path: './models/tennis_racquet.glb',
    x: 0,
    y: 0,
    z: 0,
    rx: 0,
    ry: 0,
    rz: 0,
    scale: 3
  }
};

export const HAIR_COLOR_MAP = {
  'blonde': '#efca41',
  'grey': '#5d5d5d',
  'black': '#222222',
  'red': '#9a3e10',
  'brown': '#6e2c00'
};
export const HAIR_COLORS = Object.values(HAIR_COLOR_MAP);

export function getConsistentRandom(idStr, max) {
  let hash = 0;
  const str = String(idStr || 'guest');
  for (let i = 0; i < str.length; i++) {
    hash = ((hash << 5) - hash) + str.charCodeAt(i);
    hash |= 0;
  }
  return Math.abs(hash) % max;
}

export function loadSharedModels() {
  if (sharedShoeMeshL) return;

  const loader = new GLTFLoader();
  loader.load('./models/slip_on_shoes.glb', (gltf) => {
    // Attempt to load explicit left/right shoe instances, otherwise gracefully clone the primary mesh
    const baseR = gltf.scene.getObjectByName('shoes_r') || gltf.scene.children[0];
    const baseL = gltf.scene.getObjectByName('shoes_l') || (baseR ? baseR.clone() : null);

    const prepShoe = (node) => {
      if (!node) return null;
      node.removeFromParent();
      node.scale.setScalar(60);
      node.traverse((child) => {
        if (child.isMesh) {
          child.castShadow = true;
          child.receiveShadow = true;
          if (child.material) child.material.color.setHex(0xffffff);
        }
      });
      return node;
    };

    const wrapperL = new THREE.Group();
    const nodeL = prepShoe(baseL);
    if (nodeL) wrapperL.add(nodeL);

    const wrapperR = new THREE.Group();
    const nodeR = prepShoe(baseR);
    // Explicitly do not share identical material references if cloned
    if (nodeR && baseL === baseR) {
      const clonedR = baseR.clone();
      clonedR.traverse((child) => {
        if (child.isMesh && child.material) child.material = child.material.clone();
      });
      wrapperR.add(clonedR);
    } else if (nodeR) {
      wrapperR.add(nodeR);
    }

    sharedShoeMeshL = wrapperL;
    sharedShoeMeshR = wrapperR;

    console.log("Cached Slip-on shoes locally!");

    // Asynchronously backfill any avatars spawned prior to loader resolving
    for (const data of awaitingShoeRigs) {
      applyShoeModel(data.rig, data.mats, data.c);
    }
    awaitingShoeRigs.length = 0;
  });

  // Heads are now loaded dynamically via loadHeadModel!
}

export function loadHeadModel(headName, callback) {
  if (cachedHeads[headName]) return callback(cachedHeads[headName]);

  if (!pendingHeads[headName]) {
    pendingHeads[headName] = [callback];
    const loader = new GLTFLoader();
    loader.load(`./models/heads/${headName}.glb`, (gltf) => {
      cachedHeads[headName] = gltf.scene;
      for (const cb of pendingHeads[headName]) cb(gltf.scene);
      delete pendingHeads[headName];
    });
  } else {
    pendingHeads[headName].push(callback);
  }
}

export function loadHoldingModel(modelName, callback) {
  if (cachedHoldingModels[modelName]) return callback(cachedHoldingModels[modelName]);

  const config = HOLDABLE_OBJECTS[modelName];
  if (!config) return;

  if (!pendingHoldingModels[modelName]) {
    pendingHoldingModels[modelName] = [callback];
    const loader = new GLTFLoader();
    loader.load(config.path, (gltf) => {
      cachedHoldingModels[modelName] = gltf.scene;
      for (const cb of pendingHoldingModels[modelName]) cb(gltf.scene);
      delete pendingHoldingModels[modelName];
    });
  } else {
    pendingHoldingModels[modelName].push(callback);
  }
}

function applyHeadModel(rig, mats, c) {
  if (!c || !rig.head) return;

  // Clear existing head models to allow live reloading or swapping
  for (let i = rig.head.children.length - 1; i >= 0; i--) {
    if (rig.head.children[i].userData.isHeadModel) {
      rig.head.children[i].removeFromParent();
    }
  }

  const isFemale = c.gender === 'female';
  const headList = isFemale ? FEMALE_HEADS : MALE_HEADS;
  const headKeys = Object.keys(headList);

  // Pick random head deterministically
  let headName = headKeys[getConsistentRandom(c.id + '_head', headKeys.length)];

  // Explicit overrides support
  if (c.head) {
    headName = c.head.replace('.glb', '');
  }

  const headConfig = headList[headName] || FEMALE_HEADS['female_hair_ponytail'];
  loadHeadModel(headName, (loadedScene) => {
    // If character was deleted before load finished
    if (!rig.head) return;

    const headClone = loadedScene.clone();
    headClone.userData.isHeadModel = true;

    headClone.traverse(child => {
      if (child.isMesh) {
        // Prevent coloring the eyes/eyelashes by skipping their native materials
        const matName = child.material?.name?.toLowerCase() || "";
        if (matName.includes('eye') || matName.includes('animetest')) return;

        const name = child.name.toLowerCase();
        if (name.includes('hair')) {
          if (mats.hair) {
            child.material = mats.hair;
          }
        } else if (name.includes('face') || name.includes('head') || name.includes('skin')) {
          child.material = mats.skin;
        }
        child.castShadow = true;
        child.receiveShadow = true;
      }
    });

    // Apply the explicit hardcoded configurations from the unified dictionary arrays
    const scale = headConfig.scale;
    headClone.scale.set(scale, scale, scale);
    headClone.rotation.x = Math.PI / 2;
    headClone.rotation.y = Math.PI / 2;
    headClone.position.z = headConfig.z;

    rig.head.add(headClone);
  });
}

function applyShoeModel(rig, mats, c) {
  if (!c) return;
  const vis = getCharacterProxy(c.id);
  if (!sharedShoeMeshL || !sharedShoeMeshR) return;

  for (let i = rig.lShoe.children.length - 1; i >= 0; i--) {
    if (rig.lShoe.children[i].userData.isFallback) rig.lShoe.children[i].removeFromParent();
  }
  for (let i = rig.rShoe.children.length - 1; i >= 0; i--) {
    if (rig.rShoe.children[i].userData.isFallback) rig.rShoe.children[i].removeFromParent();
  }

  const cloneL = sharedShoeMeshL.clone();
  const cloneR = sharedShoeMeshR.clone();

  const tintShoe = (shoe) => {
    shoe.traverse(child => {
      if (child.isMesh && child.material) {
        child.material = child.material.clone();
        // Override raw GLTF diffuse relying exclusively on character's cosmetic config!
        child.material.color.set(mats.shoe.color);
      }
    });
  };
  tintShoe(cloneL);
  tintShoe(cloneR);

  rig.lShoe.add(cloneL);
  rig.rShoe.add(cloneR);
}

// --- 2-BONE INVERSE KINEMATICS (IK) SOLVER ---
/*
 * Fast 2-Bone Inverse Kinematics utilizing Trigonometry (Law of Cosines)
 * Extracts the exact interior angles necessary for a limb to physically reach a target coordinate,
 * explicitly locking the articulation plane using a constant `bendingNormal` to prevent horizon-flip breaking.
 */
function solve2BoneIK(startPos, endPos, L1, L2, bendingNormal) {
  let dVector = new THREE.Vector3().subVectors(endPos, startPos);
  let d = dVector.length();

  const maxReach = L1 + L2 - 0.01;
  const minReach = Math.abs(L1 - L2) + 0.01;

  if (d > maxReach) {
    dVector.normalize().multiplyScalar(maxReach);
    endPos.copy(startPos).add(dVector);
    d = maxReach;
  } else if (d < minReach) {
    // Prevent collapsing singularities by forcing a minimum distance vector
    if (d < 0.001) dVector.set(0, 0, 1);
    dVector.normalize().multiplyScalar(minReach);
    endPos.copy(startPos).add(dVector);
    d = minReach;
  }

  // Law of Cosines to find inner angle
  let cosTheta = (L1 * L1 + d * d - L2 * L2) / (2 * L1 * d);
  cosTheta = Math.max(-1, Math.min(1, cosTheta));
  const theta = Math.acos(cosTheta);

  // Constant bending plane constraint explicitly guarantees no inverted chicken-wing elbows!
  const dir = dVector.clone().normalize();
  return new THREE.Vector3().copy(startPos).add(dir.applyAxisAngle(bendingNormal, theta).multiplyScalar(L1));
}

// Aligns a limb segment linearly between two localized coordinates without distortion
function pointLimbSegment(sleeveMesh, startPos, endPos) {
  const dist = startPos.distanceTo(endPos);
  if (dist < 0.1) return;
  sleeveMesh.position.copy(startPos).lerp(endPos, 0.5);
  const dir = new THREE.Vector3().subVectors(endPos, startPos).normalize();
  const up = new THREE.Vector3(0, 1, 0); // Native capsule +Y alignment
  const quat = new THREE.Quaternion().setFromUnitVectors(up, dir);
  sleeveMesh.quaternion.copy(quat);
}
const DEG_TO_RAD = Math.PI / 180;
const PI2 = Math.PI * 2;
const PI_HALF = Math.PI / 2;
const PI_ONE_HALF = Math.PI * 1.5;

const colorCache = {};

function shadeColor(color, percent) {
  const cacheKey = color + percent;
  if (colorCache[cacheKey]) return colorCache[cacheKey];

  let R = parseInt(color.substring(1, 3), 16);
  let G = parseInt(color.substring(3, 5), 16);
  let B = parseInt(color.substring(5, 7), 16);

  R = parseInt(R * (100 + percent) / 100);
  G = parseInt(G * (100 + percent) / 100);
  B = parseInt(B * (100 + percent) / 100);

  R = (R < 255) ? R : 255;
  G = (G < 255) ? G : 255;
  B = (B < 255) ? B : 255;

  R = Math.max(0, R);
  G = Math.max(0, G);
  B = Math.max(0, B);

  let RR = ((R.toString(16).length == 1) ? "0" + R.toString(16) : R.toString(16));
  let GG = ((G.toString(16).length == 1) ? "0" + G.toString(16) : G.toString(16));
  let BB = ((B.toString(16).length == 1) ? "0" + B.toString(16) : B.toString(16));

  colorCache[cacheKey] = "#" + RR + GG + BB;
  return colorCache[cacheKey];
}

export const characterVisuals = {};

export function getCharacterProxy(id) {
  if (id === undefined || id === null) return {};
  const isPlayer = id === 0 || (typeof id === 'string' && id.startsWith('player')) || (typeof id === 'string' && id.length > 10);
  const key = (isPlayer ? 'char_' : 'npc_') + id;
  if (!characterVisuals[key]) characterVisuals[key] = {};
  return characterVisuals[key];
}

export function clearCharacterProxy(id) {
  if (id === undefined || id === null) return;
  const isPlayer = id === 0 || (typeof id === 'string' && id.startsWith('player')) || (typeof id === 'string' && id.length > 10);
  const key = (isPlayer ? 'char_' : 'npc_') + id;
  delete characterVisuals[key];
}

export class CharacterManager {
  disposeCharacter(c, scene) {
    if (!c) return;
    const vis = getCharacterProxy(c.id);
    if (vis.meshGroup) {
      if (vis.meshGroup.parent) vis.meshGroup.parent.remove(vis.meshGroup);
      vis.meshGroup.traverse((child) => {
        if (child.isMesh) {
          if (child.geometry) child.geometry.dispose();
          if (child.material) {
            if (Array.isArray(child.material)) {
              child.material.forEach(m => {
                if (m.map) m.map.dispose();
                m.dispose();
              });
            } else {
              if (child.material.map) child.material.map.dispose();
              child.material.dispose();
            }
          }
        }
      });
      vis.meshGroup = null;
    }
    if (vis.nameElement && vis.nameElement.parentNode) vis.nameElement.parentNode.removeChild(vis.nameElement);
    if (vis.chatElement && vis.chatElement.parentNode) vis.chatElement.parentNode.removeChild(vis.chatElement);
    if (vis.walkingAudio) {
      vis.walkingAudio.pause();
      vis.walkingAudio = null;
    }
    if (vis.activeEmoteAudio) {
      vis.activeEmoteAudio.fadeOut(500);
      vis.activeEmoteAudio = null;
    }
    clearCharacterProxy(c.id);
  }

  clearScene(scene, oldInitData) {
    if (!oldInitData) return;
    if (oldInitData.characters) {
      oldInitData.characters.forEach(c => this.disposeCharacter(c, scene));
    }
    if (oldInitData.npcs) {
      oldInitData.npcs.forEach(n => this.disposeCharacter(n, scene));
    }
  }

  drawLine2D(ctxObj, sx, sy, ex, ey) {
    ctxObj.beginPath();
    ctxObj.moveTo(sx, sy);
    ctxObj.lineTo(ex, ey);
    ctxObj.stroke();
  }

  drawShoe2D(ctxObj, x, y, color, isLeft) {
    const dirY = isLeft ? -1 : 1;

    ctxObj.fillStyle = '#7f8c8d';
    ctxObj.beginPath();
    ctxObj.moveTo(x - 2, y - 3.5);
    ctxObj.lineTo(x + 5.5, y - 3.5);
    ctxObj.bezierCurveTo(x + 10, y - 3.5 * dirY, x + 10, y + 3.5, x + 5.5, y + 3.5);
    ctxObj.lineTo(x - 2, y + 3.5);
    ctxObj.quadraticCurveTo(x - 3.5, y + 3.5, x - 3.5, y - 3.5, x - 2, y - 3.5);
    ctxObj.fill();

    const bodyGrad = ctxObj.createRadialGradient(x + 2, y - 1 * dirY, 0.5, x + 3, y, 6);
    bodyGrad.addColorStop(0, shadeColor(color, 40));
    bodyGrad.addColorStop(0.5, color);
    bodyGrad.addColorStop(1, shadeColor(color, -40));

    ctxObj.fillStyle = bodyGrad;
    ctxObj.beginPath();
    ctxObj.moveTo(x - 1.5, y - 3);
    ctxObj.lineTo(x + 4.5, y - 3);
    ctxObj.bezierCurveTo(x + 9, y - 3 * dirY, x + 9, y + 3, x + 4.5, y + 3);
    ctxObj.lineTo(x - 1.5, y + 3);
    ctxObj.quadraticCurveTo(x - 2.5, y + 3, x - 2.5, y - 3, x - 1.5, y - 3);
    ctxObj.fill();

    ctxObj.fillStyle = '#34495e';
    ctxObj.beginPath();
    ctxObj.moveTo(x + 5, y - 2.5);
    ctxObj.bezierCurveTo(x + 9, y - 2.5 * dirY, x + 9, y + 2.5, x + 5, y + 2.5);
    ctxObj.quadraticCurveTo(x + 3.5, y, x + 5, y - 2.5);
    ctxObj.fill();

    ctxObj.fillStyle = shadeColor(color, -20);
    ctxObj.beginPath();
    ctxObj.moveTo(x - 1, y - 2);
    ctxObj.lineTo(x + 3, y - 2.5);
    ctxObj.lineTo(x + 3, y + 2.5);
    ctxObj.lineTo(x - 1, y + 2);
    ctxObj.fill();

    ctxObj.lineWidth = 1;
    ctxObj.strokeStyle = 'rgba(255,255,255,0.4)';
    ctxObj.beginPath();
    ctxObj.moveTo(x + 0.5, y - 2); ctxObj.lineTo(x + 2, y + 2);
    ctxObj.moveTo(x + 2, y - 2); ctxObj.lineTo(x + 0.5, y + 2);
    ctxObj.moveTo(x + 1.5, y - 2); ctxObj.lineTo(x + 3, y + 2);
    ctxObj.moveTo(x + 3, y - 2); ctxObj.lineTo(x + 1.5, y + 2);
    ctxObj.stroke();

    ctxObj.lineWidth = 0.5;
    ctxObj.strokeStyle = 'rgba(255,255,255,0.3)';
    ctxObj.beginPath();
    ctxObj.moveTo(x - 1, y - 2.5);
    ctxObj.quadraticCurveTo(x + 3, y - 2.5 * dirY, x + 4.5, y - 2.5);
    ctxObj.stroke();
  }

  drawHumanoid2D(ctx, c, limbs) {
    if (!c) return;
    const vis = getCharacterProxy(c.id);
    const angle = (c.rotation || 0) * DEG_TO_RAD;
    const cosA = Math.cos(angle);
    const sinA = Math.sin(angle);
    const baseScale = window.init?.mapData?.character_scale || 1;
    const widthScale = (c.width || 40) / 40;
    const heightScale = (c.height || 40) / 40;
    const scaleX = baseScale * widthScale;
    const scaleY = baseScale * heightScale;

    const isVisible = (localX, localY) => {
      const sx = localX * scaleX;
      const sy = localY * scaleY;
      const rotX = sx * cosA - sy * sinA;
      const rotY = sx * sinA + sy * cosA;
      return physicsEngine.checkClipMask((c.x || 0) + rotX, (c.y || 0) + rotY, 0);
    };

    const getRaycastEnd = (startX, startY, targetX, targetY) => {
      let dx = targetX - startX;
      let dy = targetY - startY;
      let dist = Math.sqrt(dx * dx + dy * dy);
      if (dist === 0) return { x: targetX, y: targetY, hit: !isVisible(targetX, targetY) };

      let stepX = dx / dist;
      let stepY = dy / dist;

      let currentX = startX;
      let currentY = startY;

      for (let i = 0; i < dist; i += 1) {
        if (!isVisible(currentX, currentY)) {
          return { x: currentX, y: currentY, hit: true };
        }
        currentX += stepX;
        currentY += stepY;
      }

      return { x: targetX, y: targetY, hit: !isVisible(targetX, targetY) };
    };

    this.drawHumanoidLowerBody2D(ctx, c, limbs, isVisible);
    this.drawHumanoidUpperBody2D(ctx, c, limbs, isVisible, getRaycastEnd);
  }

  drawHumanoidLowerBody2D(ctx, c, limbs, isVisible) {
    if (!c) return;
    const vis = getCharacterProxy(c.id);
    if (!isVisible) isVisible = () => true;

    if (!c.emote || (c.emote.name !== 'sit' && c.emote.name !== 'lunch' && c.emote.name !== 'write')) {
      const shoe_color = c.shoe_color || '#1a252f';
      if (isVisible(limbs.leftLegEndX, limbs.leftLegEndY)) {
        this.drawShoe2D(ctx, limbs.leftLegEndX, limbs.leftLegEndY, shoe_color, true);
      }
      if (isVisible(limbs.rightLegEndX, limbs.rightLegEndY)) {
        this.drawShoe2D(ctx, limbs.rightLegEndX, limbs.rightLegEndY, shoe_color, false);
      }
    }
  }

  drawHumanoidUpperBody2D(ctx, c, limbs, isVisible, getRaycastEnd) {
    if (!c) return;
    const vis = getCharacterProxy(c.id);
    if (!isVisible) isVisible = () => true;
    if (!getRaycastEnd) getRaycastEnd = (sx, sy, tx, ty) => ({ x: tx, y: ty, hit: false });

    const armOffset = 11;

    const leftArmEnd = getRaycastEnd(0, -armOffset, limbs.leftArmX, limbs.leftArmY);
    const rightArmEnd = getRaycastEnd(0, armOffset, limbs.rightArmX, limbs.rightArmY);

    const armGradient = ctx.createLinearGradient(0, -armOffset, 0, limbs.leftArmY);
    armGradient.addColorStop(0, c.arm_color || '#3498db');
    armGradient.addColorStop(1, shadeColor(c.arm_color || '#3498db', -30));

    ctx.lineWidth = 5;
    ctx.strokeStyle = armGradient;

    this.drawLine2D(ctx, 0, -armOffset, leftArmEnd.x, leftArmEnd.y);

    const rightArmGradient = ctx.createLinearGradient(0, armOffset, 0, limbs.rightArmY);
    rightArmGradient.addColorStop(0, c.arm_color || '#3498db');
    rightArmGradient.addColorStop(1, shadeColor(c.arm_color || '#3498db', -30));
    ctx.strokeStyle = rightArmGradient;
    this.drawLine2D(ctx, 0, armOffset, rightArmEnd.x, rightArmEnd.y);

    const leftHandGrad = ctx.createRadialGradient(limbs.leftArmX, limbs.leftArmY - 1, 0.5, limbs.leftArmX, limbs.leftArmY, 3);
    leftHandGrad.addColorStop(0, '#f5d39e');
    leftHandGrad.addColorStop(0.6, '#e0ab63');
    leftHandGrad.addColorStop(1, '#a67232');
    ctx.fillStyle = leftHandGrad;
    if (!leftArmEnd.hit) {
      ctx.beginPath();
      ctx.arc(limbs.leftArmX, limbs.leftArmY, 3, 0, PI2);
      ctx.fill();
    }

    const rightHandGrad = ctx.createRadialGradient(limbs.rightArmX, limbs.rightArmY - 1, 0.5, limbs.rightArmX, limbs.rightArmY, 3);
    rightHandGrad.addColorStop(0, '#f5d39e');
    rightHandGrad.addColorStop(0.6, '#e0ab63');
    rightHandGrad.addColorStop(1, '#a67232');
    ctx.fillStyle = rightHandGrad;
    if (!rightArmEnd.hit) {
      ctx.beginPath();
      ctx.arc(limbs.rightArmX, limbs.rightArmY, 3, 0, PI2);
      ctx.fill();
    }

    const bodyGradient = ctx.createLinearGradient(-8, 0, 8, 0);
    bodyGradient.addColorStop(0, c.shirt_color || '#3498db');
    bodyGradient.addColorStop(0.5, shadeColor(c.shirt_color || '#3498db', 20));
    bodyGradient.addColorStop(1, shadeColor(c.shirt_color || '#3498db', -40));
    ctx.fillStyle = bodyGradient;

    const bodyDepth = c.gender === 'female' ? 10 : 12;
    const bodyDepthOffset = -(bodyDepth / 2);

    if (ctx.roundRect) {
      ctx.beginPath();
      ctx.roundRect(bodyDepthOffset, -12, bodyDepth, 24, 6);
      ctx.fill();
    } else {
      ctx.fillRect(bodyDepthOffset, -12, bodyDepth, 24);
    }

    ctx.beginPath();
    ctx.arc(2, 0, 8, 0, PI2);
    const headGradient = ctx.createRadialGradient(0, -2, 2, 2, 0, 8);
    headGradient.addColorStop(0, '#f5d39e');
    headGradient.addColorStop(0.6, '#e0ab63');
    headGradient.addColorStop(1, '#a67232');
    ctx.fillStyle = headGradient;
    ctx.fill();

    ctx.lineWidth = 2;
    ctx.strokeStyle = 'rgba(0,0,0,0.4)';
    ctx.stroke();

    let hairColor = c.hair_color;
    if (!hairColor && c.gender === 'female') hairColor = 'blonde';

    if (hairColor && hairColor !== 'none' && hairColor !== 'bald' && (!c.head || !c.head.includes('bald'))) {
      if (HAIR_COLOR_MAP[hairColor]) {
        hairColor = HAIR_COLOR_MAP[hairColor];
      } else {
        hairColor = HAIR_COLOR_MAP['blonde'];
      }

      let shineColor = hairColor;
      let shadowColor = hairColor;
      try {
        shineColor = shadeColor(hairColor, 30);
        shadowColor = shadeColor(hairColor, -40);
      } catch (e) { }

      const hairGradient = ctx.createLinearGradient(-6, -7, 6, 7);
      hairGradient.addColorStop(0, hairColor);
      hairGradient.addColorStop(0.4, shineColor);
      hairGradient.addColorStop(1, shadowColor);
      ctx.fillStyle = hairGradient;
      ctx.beginPath();

      const style = c.head || (c.gender === 'female' ? 'long' : 'short');

      if (style.includes('short')) {
        ctx.arc(1, 0, 7.5, PI_HALF + 0.3, PI_ONE_HALF - 0.3, false);
        ctx.fill();
      } else if (style.includes('spiky')) {
        ctx.arc(1, 0, 7.5, PI_HALF, PI_ONE_HALF, false);
        ctx.fill();
        ctx.beginPath();
        ctx.moveTo(1, -7.5);
        ctx.lineTo(-4, -7);
        ctx.lineTo(-12, -4);
        ctx.lineTo(-6, -2);
        ctx.lineTo(-14, 1);
        ctx.lineTo(-5, 3);
        ctx.lineTo(-11, 6);
        ctx.lineTo(-4, 7);
        ctx.lineTo(1, 7.5);
        ctx.fill();
      } else if (style.includes('ponytail')) {
        ctx.arc(1, 0, 7.5, PI_HALF, PI_ONE_HALF, false);
        ctx.fill();
        ctx.beginPath();
        if (ctx.ellipse) {
          ctx.ellipse(-9, 0, 4, 3, 0, 0, PI2);
        } else {
          ctx.arc(-9, 0, 3.5, 0, PI2);
        }
        ctx.fill();
      } else if (style.includes('messy')) {
        ctx.arc(1, 0, 7.5, PI_HALF, PI_ONE_HALF, false);
        ctx.fill();
        ctx.beginPath();
        ctx.moveTo(1, -7.5);
        ctx.lineTo(-8, -6);
        ctx.lineTo(-6, -3);
        ctx.lineTo(-9, -1);
        ctx.lineTo(-6, 2);
        ctx.lineTo(-8, 5);
        ctx.lineTo(1, 7.5);
        ctx.fill();
      } else {
        ctx.arc(1, 0, 7.5, PI_HALF, PI_ONE_HALF, false);
        ctx.fill();

        ctx.beginPath();
        ctx.moveTo(1, -5.5);
        ctx.bezierCurveTo(0, -6, -16, -6, -14, -1);
        ctx.bezierCurveTo(-12, 5, -6, 7, -2, 7.5);
        ctx.bezierCurveTo(-1, 7.5, 0, 7.5, 1, 7.5);
        ctx.fill();
      }
    }
  }

  buildSkeletonMaterials(c) {
    if (!c) return;
    const vis = getCharacterProxy(c.id);

    const randomColor = HAIR_COLORS[getConsistentRandom(c.id + '_color', HAIR_COLORS.length)];
    let finalHairColor = randomColor;

    if (c.hair_color && HAIR_COLOR_MAP[c.hair_color]) {
      finalHairColor = HAIR_COLOR_MAP[c.hair_color];
    }

    const mats = {
      skin: new THREE.MeshStandardMaterial({ color: c.color || '#f1c40f', roughness: 0.6, metalness: 0.1 }),
      shirt: new THREE.MeshStandardMaterial({ color: c.shirt_color || '#3498db', roughness: 0.8, metalness: 0.0 }),
      arm: new THREE.MeshStandardMaterial({ color: c.arm_color || c.shirt_color || '#3498db', roughness: 0.8, metalness: 0.0 }),
      pants: new THREE.MeshStandardMaterial({ color: c.pants_color || '#2c3e50', roughness: 0.9, metalness: 0.0 }),
      shoe: new THREE.MeshStandardMaterial({ color: c.shoe_color || '#7f8c8d', roughness: 0.7, metalness: 0.2 }),
      eye_white: new THREE.MeshStandardMaterial({ color: '#ffffff', roughness: 0.5, metalness: 0.0 }),
      eye_black: new THREE.MeshStandardMaterial({ color: '#000000', roughness: 0.5, metalness: 0.0 }),
      hair: new THREE.MeshStandardMaterial({ color: finalHairColor, roughness: 0.5, metalness: 0.1 })
    };

    return mats;
  }

  buildSkeletonRig(c, mats) {
    if (!c) return;
    const vis = getCharacterProxy(c.id);

    // Maintain total torso height of 26 natively (length 8 + radius 9*2). Widen Z by 25% natively matching the +/-11 arm anchor offsets!
    const torsoGeo = new THREE.CapsuleGeometry(9, 8, 10, 16);
    torsoGeo.scale(0.65, 1, 1.15);

    vis.rig = {
      bodyPivot: new THREE.Group(),
      emotePropsDirectional: new THREE.Group(),
      head: new THREE.Group(),
      torso: new THREE.Mesh(torsoGeo, mats.shirt),
      leftArm: new THREE.Group(), rightArm: new THREE.Group(),
      leftLeg: new THREE.Group(), rightLeg: new THREE.Group()
    };
    vis.rig.meshGroup = vis.meshGroup;
    vis.meshGroup.add(vis.rig.bodyPivot);
    vis.meshGroup.add(vis.rig.emotePropsDirectional);
    vis.rig.bodyPivot.add(vis.rig.torso);

    vis.rig.torso.rotation.x = Math.PI / 2;
    vis.rig.torso.position.set(0, 0, 20);

    vis.rig.head.position.set(2, 0, 36);
    vis.rig.head.scale.set(0.65, 0.65, 0.7);
    vis.rig.bodyPivot.add(vis.rig.head);

    applyHeadModel(vis.rig, mats, c);

    vis.rig.leftHandTarget = new THREE.Vector3(0, -15, 9);
    vis.rig.rightHandTarget = new THREE.Vector3(0, 15, 9);
    vis.rig.leftFootTarget = new THREE.Vector3(0, -6, -14);
    vis.rig.rightFootTarget = new THREE.Vector3(0, 6, -14);

    vis.rig.leftShoulderPos = new THREE.Vector3(3, -10, 26);
    vis.rig.rightShoulderPos = new THREE.Vector3(3, 10, 26);
    vis.rig.leftHipPos = new THREE.Vector3(0, -6, 10);
    vis.rig.rightHipPos = new THREE.Vector3(0, 6, 10);
  }

  buildSkeletonHair(c, mats) {
    // Procedural hair has been completely disabled and removed. The GLB heads now provide all hair meshes!
  }

  buildSkeletonLimbs(c, mats) {
    if (!c) return;
    const vis = getCharacterProxy(c.id);
    const upperArmGeo = new THREE.CapsuleGeometry(3.3, 8, 8, 10);
    const lowerArmGeo = new THREE.CapsuleGeometry(3.3, 8, 8, 10);
    const handGeo = new THREE.SphereGeometry(3.8, 12, 12);

    vis.rig.lUpperArm = new THREE.Mesh(upperArmGeo, mats.arm);
    vis.rig.lLowerArm = new THREE.Mesh(lowerArmGeo, mats.arm);
    vis.rig.lHand = new THREE.Mesh(handGeo, mats.skin);
    vis.rig.lUpperArm.castShadow = true; vis.rig.lLowerArm.castShadow = true; vis.rig.lHand.castShadow = true;
    vis.rig.bodyPivot.add(vis.rig.lUpperArm, vis.rig.lLowerArm, vis.rig.lHand);

    vis.rig.rUpperArm = new THREE.Mesh(upperArmGeo, mats.arm);
    vis.rig.rLowerArm = new THREE.Mesh(lowerArmGeo, mats.arm);
    vis.rig.rHand = new THREE.Mesh(handGeo, mats.skin);
    vis.rig.rUpperArm.castShadow = true; vis.rig.rLowerArm.castShadow = true; vis.rig.rHand.castShadow = true;
    vis.rig.bodyPivot.add(vis.rig.rUpperArm, vis.rig.rLowerArm, vis.rig.rHand);

    const upperLegGeo = new THREE.CapsuleGeometry(3.6, 12, 8, 10);
    const lowerLegGeo = new THREE.CapsuleGeometry(3.6, 9.7, 8, 10);

    const applyTaper = (geometry, topScale, bottomScale, isLower) => {
      const pos = geometry.attributes.position;
      const len = isLower ? 9.7 : 12;
      const halfLen = len / 2;
      for (let i = 0; i < pos.count; i++) {
        const y = pos.getY(i);
        let scale;
        if (y >= halfLen) {
          scale = topScale;
        } else if (y <= -halfLen) {
          scale = bottomScale;
        } else {
          // Progressively taper linearly across the cylindrical midsection
          const t = (y + halfLen) / len;
          scale = bottomScale + t * (topScale - bottomScale);
        }
        pos.setX(i, pos.getX(i) * scale);
        pos.setZ(i, pos.getZ(i) * scale);
      }
      geometry.computeVertexNormals();
    };

    // Thighs remain natively uniform preventing hip tapering.
    applyTaper(upperLegGeo, 1.0, 1.0, false);
    // Taper calves from interlocking 100% bounds down to 60% thin at the ankle
    applyTaper(lowerLegGeo, 1.0, 0.6, true);

    const shoeGeo = new THREE.BoxGeometry(11, 8, 5);

    vis.rig.lUpperLeg = new THREE.Mesh(upperLegGeo, mats.pants);
    vis.rig.lLowerLeg = new THREE.Mesh(lowerLegGeo, mats.pants);
    vis.rig.lUpperLeg.castShadow = true; vis.rig.lLowerLeg.castShadow = true;
    vis.rig.lShoe = new THREE.Group();
    vis.rig.bodyPivot.add(vis.rig.lUpperLeg, vis.rig.lLowerLeg, vis.rig.lShoe);

    vis.rig.rUpperLeg = new THREE.Mesh(upperLegGeo, mats.pants);
    vis.rig.rLowerLeg = new THREE.Mesh(lowerLegGeo, mats.pants);
    vis.rig.rUpperLeg.castShadow = true; vis.rig.rLowerLeg.castShadow = true;
    vis.rig.rShoe = new THREE.Group();
    vis.rig.bodyPivot.add(vis.rig.rUpperLeg, vis.rig.rLowerLeg, vis.rig.rShoe);

    if (sharedShoeMeshL && sharedShoeMeshR) {
      applyShoeModel(vis.rig, mats, c);
    } else {
      const leftBox = new THREE.Mesh(shoeGeo, mats.shoe);
      const rightBox = new THREE.Mesh(shoeGeo, mats.shoe);
      leftBox.userData.isFallback = true;
      rightBox.userData.isFallback = true;
      vis.rig.lShoe.add(leftBox);
      vis.rig.rShoe.add(rightBox);
      awaitingShoeRigs.push({ rig: vis.rig, mats, c });
    }
  }

  buildShadowBlob(c) {
    if (!c) return;
    const vis = getCharacterProxy(c.id);
    const shadowSize = 28;
    const shadowCanvas = document.createElement('canvas');
    shadowCanvas.width = 30; shadowCanvas.height = 30;
    const sctx = shadowCanvas.getContext('2d');
    sctx.fillStyle = 'rgba(0, 0, 0, 0.25)';
    sctx.beginPath(); sctx.arc(15, 15, 14, 0, Math.PI * 2); sctx.fill();

    const shadowTex = new THREE.CanvasTexture(shadowCanvas);
    const shadowMat = new THREE.MeshBasicMaterial({ map: shadowTex, transparent: true, depthWrite: false });
    vis.shadowMesh = new THREE.Mesh(new THREE.PlaneGeometry(shadowSize, shadowSize), shadowMat);
    vis.shadowMesh.position.set(0, 0, 0.5);
    vis.shadowMesh.renderOrder = 55;
    vis.meshGroup.add(vis.shadowMesh);
  }

  ensureDomElements(c) {
    if (!c) return;
    const vis = getCharacterProxy(c.id);
    if (c.name && !c.hide_nameplate && !vis.nameElement) {
      vis.nameElement = document.createElement('div');
      vis.nameElement.className = 'character-nameplate';
      vis.nameElement.textContent = c.name;
      document.body.appendChild(vis.nameElement);
    }

    if (!vis.chatElement) {
      vis.chatElement = document.createElement('div');
      vis.chatElement.className = 'character-chat-bubble';

      const arrow = document.createElement('div');
      arrow.className = 'character-chat-arrow';
      vis.chatElement.appendChild(arrow);

      vis.chatTextNode = document.createElement('span');
      vis.chatElement.appendChild(vis.chatTextNode);

      document.body.appendChild(vis.chatElement);
    }
  }

  ensureThreeSetup(c, scene) {
    if (!c) return;
    const vis = getCharacterProxy(c.id);
    if (!vis.meshGroup) {
      vis.meshGroup = new THREE.Group();
      scene.add(vis.meshGroup);

      const baseScale = window.init?.mapData?.character_scale || 1;
      const widthScale = (c.width || 40) / 40;
      const heightScale = (c.height || 40) / 40;
      const maxScale = baseScale * Math.max(widthScale, heightScale);

      const mats = this.buildSkeletonMaterials(c);

      this.buildSkeletonRig(c, mats);
      this.buildSkeletonHair(c, mats);
      this.buildSkeletonLimbs(c, mats);

      vis.meshGroup.scale.set(maxScale, maxScale, maxScale);
      vis.rig.bodyPivot.position.set(0, 0, 15.5);

      this.buildShadowBlob(c);

      vis.meshGroup.traverse((node) => {
        if (node.isMesh && node !== vis.shadowMesh) {
          node.castShadow = true;
          node.receiveShadow = true;
        }
      });
    }

    this.ensureDomElements(c);
  }

  applyWalkCycle(c, legTimer) {
    if (!c) return;
    const vis = getCharacterProxy(c.id);
    const legSwing = Math.sin(legTimer);
    const legVelocity = Math.cos(legTimer);

    const armSwingX = 6;
    const armLiftZ = 6;
    const legStrideX = 14;
    const stepLiftZ = 8; // Boost to 8 highlighting the alternating lift arch

    vis.rig.leftHandTarget.x += -legSwing * armSwingX;
    vis.rig.leftHandTarget.z += Math.abs(legSwing) * armLiftZ;
    vis.rig.rightHandTarget.x += legSwing * armSwingX;
    vis.rig.rightHandTarget.z += Math.abs(legSwing) * armLiftZ;

    vis.rig.leftFootTarget.x += legSwing * legStrideX;
    vis.rig.leftFootTarget.z += Math.max(0, legVelocity) * stepLiftZ;
    vis.rig.rightFootTarget.x += -legSwing * legStrideX;
    vis.rig.rightFootTarget.z += Math.max(0, -legVelocity) * stepLiftZ;
  }

  applyIdleSway(c, idleTime) {
    if (!c) return;
    const vis = getCharacterProxy(c.id);
    const armSwayZ = Math.sin(idleTime * 2.0) * 0.6;
    const armSwayX = Math.cos(idleTime * 1.5) * 0.4;

    vis.rig.leftHandTarget.z += armSwayZ;
    vis.rig.leftHandTarget.x += armSwayX;
    vis.rig.rightHandTarget.z += armSwayZ;
    vis.rig.rightHandTarget.x -= armSwayX;
  }

  applyEmoteOverrides(c, emoteDef, currentEmote) {
    if (!c) return;
    const vis = getCharacterProxy(c.id);
    if (emoteDef && emoteDef.updateLimbs3D) {
      vis.rig.bodyPivot.rotation.y = 0;
      emoteDef.updateLimbs3D(vis.rig, currentEmote, c);
    } else if (c.emoji) {
      vis.rig.bodyPivot.rotation.y = 0;
      vis.rig.leftHandTarget.set(5, -20, 35);
      vis.rig.rightHandTarget.set(5, 20, 35);
    }
  }

  resolveInverseKinematics(c) {
    if (!c) return;
    const vis = getCharacterProxy(c.id);

    const bendNormalArmL = new THREE.Vector3(0, 1, -0.5).normalize();
    const bendNormalArmR = new THREE.Vector3(0, 1, 0.5).normalize();
    const bendNormalLegL = new THREE.Vector3(0, -1, -0.2).normalize();
    const bendNormalLegR = new THREE.Vector3(0, -1, 0.2).normalize();

    // Raise ankles 19% (roughly 2.3 units relative to FootTarget) ensuring the calves don't clip through short slip_ons safely
    const leftAnklePos = new THREE.Vector3().copy(vis.rig.leftFootTarget);
    leftAnklePos.z += 2.3;
    const rightAnklePos = new THREE.Vector3().copy(vis.rig.rightFootTarget);
    rightAnklePos.z += 2.3;

    const leftElbow = solve2BoneIK(vis.rig.leftShoulderPos, vis.rig.leftHandTarget, 8.5, 8.5, bendNormalArmL);
    const rightElbow = solve2BoneIK(vis.rig.rightShoulderPos, vis.rig.rightHandTarget, 8.5, 8.5, bendNormalArmR);
    const leftKnee = solve2BoneIK(vis.rig.leftHipPos, leftAnklePos, 12, 9.7, bendNormalLegL);
    const rightKnee = solve2BoneIK(vis.rig.rightHipPos, rightAnklePos, 12, 9.7, bendNormalLegR);

    // Sync clamped coordinates
    vis.rig.lHand.position.copy(vis.rig.leftHandTarget);
    vis.rig.rHand.position.copy(vis.rig.rightHandTarget);

    vis.rig.leftFootTarget.copy(leftAnklePos);
    vis.rig.lShoe.position.copy(vis.rig.leftFootTarget);

    vis.rig.rightFootTarget.copy(rightAnklePos);
    vis.rig.rShoe.position.copy(vis.rig.rightFootTarget);

    pointLimbSegment(vis.rig.lUpperArm, vis.rig.leftShoulderPos, leftElbow);
    pointLimbSegment(vis.rig.lLowerArm, leftElbow, vis.rig.leftHandTarget);

    pointLimbSegment(vis.rig.rUpperArm, vis.rig.rightShoulderPos, rightElbow);
    pointLimbSegment(vis.rig.rLowerArm, rightElbow, vis.rig.rightHandTarget);

    pointLimbSegment(vis.rig.lUpperLeg, vis.rig.leftHipPos, leftKnee);
    pointLimbSegment(vis.rig.lLowerLeg, leftKnee, leftAnklePos);

    pointLimbSegment(vis.rig.rUpperLeg, vis.rig.rightHipPos, rightKnee);
    pointLimbSegment(vis.rig.rLowerLeg, rightKnee, rightAnklePos);

    vis.rig.lHand.quaternion.copy(vis.rig.lLowerArm.quaternion);
    vis.rig.rHand.quaternion.copy(vis.rig.rLowerArm.quaternion);

    // Rigidly map the pitch mechanically from the Lower Leg bone using the verified Y-Axis!
    const lDir = new THREE.Vector3().subVectors(leftAnklePos, leftKnee);
    vis.rig.lShoe.rotation.set(0, Math.atan2(lDir.y, -lDir.z), 0);

    const rDir = new THREE.Vector3().subVectors(rightAnklePos, rightKnee);
    vis.rig.rShoe.rotation.set(0, Math.atan2(rDir.y, -rDir.z), 0);
  }

  updateCharacter3D(c, isNpc, player, syncPlayerToJSON) {
    if (!c) return;
    const vis = getCharacterProxy(c.id);
    if (!vis.rig) return;

    vis.meshGroup.rotation.z = -c.rotation * (Math.PI / 180);
    vis.rig.bodyPivot.rotation.z = 0;
    vis.rig.emotePropsDirectional.rotation.z = 0;

    const isActualNpc = isNpc;
    if (isActualNpc && !c.emote && c.default_emote) {
      c.emote = JSON.parse(JSON.stringify(c.default_emote));
    }

    let currentEmote = c.emote;
    let emoteDef = null;

    const newEmoteName = currentEmote ? currentEmote.name : null;
    if (vis.rig.currentEmoteName !== newEmoteName) {
      if (vis.rig.currentEmoteName && emotes[vis.rig.currentEmoteName] && emotes[vis.rig.currentEmoteName].onEnd) {
        emotes[vis.rig.currentEmoteName].onEnd(c, vis.rig);
      }
      if (vis.rig.emoteProps) {
        vis.rig.emoteProps.removeFromParent();
        vis.rig.emoteProps = null;
      }
      if (vis.rig.crumbProps) {
        vis.rig.crumbProps.removeFromParent();
        vis.rig.crumbProps = null;
      }
      vis.rig.bodyPivot.position.set(0, 0, 15.5);
      vis.rig.bodyPivot.rotation.x = 0;
      vis.rig.bodyPivot.rotation.y = 0;
      if (vis.rig.head) vis.rig.head.rotation.set(0, 0, 0);
      vis.rig.currentEmoteName = newEmoteName;
    }

    if (currentEmote && emotes[currentEmote.name]) {
      emoteDef = emotes[currentEmote.name];
      if (currentEmote.startTime !== 0 && Date.now() - currentEmote.startTime > emoteDef.duration) {
        if (vis.activeEmoteAudio) {
          vis.activeEmoteAudio.fadeOut(500);
          vis.activeEmoteAudio = null;
        }
        if (emoteDef.onEnd) {
          emoteDef.onEnd(c, vis.rig);
        }
        if (isActualNpc && c.default_emote) {
          c.emote = JSON.parse(JSON.stringify(c.default_emote));
        } else {
          c.emote = null;
          if (c === player && syncPlayerToJSON) syncPlayerToJSON();
        }
      }
    }

    const baseLHand = new THREE.Vector3(9, -16, 12);
    const baseRHand = new THREE.Vector3(9, 16, 12);
    const baseLFoot = new THREE.Vector3(2, -6, -13);
    const baseRFoot = new THREE.Vector3(2, 6, -13);

    vis.rig.leftHandTarget.copy(baseLHand);
    vis.rig.rightHandTarget.copy(baseRHand);
    vis.rig.leftFootTarget.copy(baseLFoot);
    vis.rig.rightFootTarget.copy(baseRFoot);

    const timeNow = Date.now() / 1000;
    let hash = 0;
    const strId = String(c.id || 'npc');
    for (let i = 0; i < strId.length; i++) hash += strId.charCodeAt(i);
    const idleTime = timeNow + (hash * 0.1);

    const breathOffset = Math.sin(idleTime * 2) * 0.02;
    vis.rig.torso.scale.set(1 + breathOffset, 1 + breathOffset, 1);

    vis.rig.bodyPivot.rotation.y = Math.sin(idleTime * 1.5) * 0.05;

    const isWalking = (vis.legAnimationTime || 0) > 0;
    const legTimer = vis.legAnimationTime || 0;
    const legSwing = Math.sin(legTimer);

    if (isWalking) {
      // Procedurally bob vertical Z twice per sequence (when feet cross mid-stride)
      vis.rig.bodyPivot.position.z = 15.5 + Math.cos(legTimer * 2) * 0.5;
      // Shift natively Forward (+X) identically pulsing outward whenever the lifted stride leg passes the midpoint 
      vis.rig.bodyPivot.position.x = Math.cos(legTimer * 2) * 1.0;

      this.applyWalkCycle(c, legTimer);
    } else if (!emoteDef || !emoteDef.updateLimbs3D) {
      // Wipe dynamic strides and seamlessly restore neutral geometry during standstill
      vis.rig.bodyPivot.position.z = 15.5;
      vis.rig.bodyPivot.position.x = 0;

      this.applyIdleSway(c, idleTime);
    }

    if (c.holding !== vis.rig.currentHoldingKey) {
      for (let i = vis.rig.rHand.children.length - 1; i >= 0; i--) {
        if (vis.rig.rHand.children[i].userData.isHoldingModel) {
          vis.rig.rHand.children[i].removeFromParent();
        }
      }
      vis.rig.currentHoldingKey = c.holding;

      if (c.holding && HOLDABLE_OBJECTS[c.holding]) {
        const config = HOLDABLE_OBJECTS[c.holding];
        loadHoldingModel(c.holding, (loadedScene) => {
          if (vis.rig.currentHoldingKey !== c.holding) return;
          if (!vis.rig.rHand) return;

          const modelClone = loadedScene.clone();
          modelClone.userData.isHoldingModel = true;

          modelClone.position.set(config.x, config.y, config.z);
          modelClone.rotation.set(config.rx, config.ry, config.rz);
          modelClone.scale.setScalar(config.scale);

          modelClone.traverse(child => {
            if (child.isMesh) {
              child.castShadow = true;
              child.receiveShadow = true;
            }
          });

          vis.rig.rHand.add(modelClone);
        });
      }
    }

    this.applyEmoteOverrides(c, emoteDef, currentEmote);
    this.resolveInverseKinematics(c);
  }

  drawCharacter(c, isNpc, layerType, scene, player, syncPlayerToJSON, cameraZoom, viewportWidth, viewportHeight, threeCamera) {
    const vis = getCharacterProxy(c.id);
    if (layerType === 'all' || layerType === 'base') {
      this.ensureThreeSetup(c, scene);

      // Update position (WebGL Y is UP, so we negate game Y)
      const renderZ = (c.z !== undefined) ? c.z : 0;
      vis.meshGroup.position.set(c.x, -c.y, renderZ);

      const isRedrawForced = true; // Completely rip out the animation cull boundary allowing infinite evaluation mapping Native idle breathing.

      if (isRedrawForced) {
        this.updateCharacter3D(c, isNpc, player, syncPlayerToJSON);
        vis._lastRenderedEmote = JSON.stringify(c.emote);
        vis._lastRenderedRot = c.rotation;
        vis._hasInitialRender = true;
      }
    }

    if (layerType === 'all' || layerType === 'overlay' || layerType === 'chat') {
      if (vis.meshGroup) {
        const renderZ = (c.z !== undefined) ? c.z : 0;
        const vec = new THREE.Vector3(c.x, -c.y, renderZ);
        vec.project(threeCamera);
        // Map -1 to 1 to exact screen pixels
        const screenX = (vec.x * 0.5 + 0.5) * viewportWidth;
        const screenY = (-(vec.y * 0.5) + 0.5) * viewportHeight;

        if (vis.nameElement) {
          vis.nameElement.style.left = `${screenX}px`;
          // Raise nameplate above head
          const nameOffsetY = 45 * cameraZoom;
          vis.nameElement.style.top = `${screenY - nameOffsetY}px`;
        }

        if (vis.chatElement) {
          if (c.chatMessage && Date.now() - (c.chatTime || 0) < 5000) {
            this.currentFrameChatCount++;
            if (this.currentFrameChatCount <= 3) {
              vis.chatElement.style.display = 'block';
              if (vis.chatTextNode.innerText !== c.chatMessage) {
                vis.chatTextNode.innerText = c.chatMessage;
              }
              vis.chatElement.style.left = `${screenX}px`;
              const chatOffsetY = 55 * cameraZoom;
              vis.chatElement.style.top = `${screenY - chatOffsetY}px`;
            } else {
              vis.chatElement.style.display = 'none';
            }
          } else {
            vis.chatElement.style.display = 'none';
          }
        }
      }
    }
  }

  drawCharacters(layerType = 'all', scene, player, syncPlayerToJSON, cameraZoom, viewportWidth, viewportHeight, threeCamera) {
    this.currentFrameChatCount = 0;

    const processDraw = (char, isNpc) => {
      const c = (char.id === player.id) ? player : char;
      const renderZ = (c.z !== undefined) ? c.z : 0;
      const vec = new THREE.Vector3(c.x, -c.y, renderZ + 5).project(threeCamera);
      const isVisible = (vec.z <= 1 && Math.abs(vec.x) <= 1.3 && Math.abs(vec.y) <= 1.3);
      const vis = getCharacterProxy(c.id);

      if (isVisible) {
        if (vis.meshGroup) vis.meshGroup.visible = true;
        if (vis.nameElement) vis.nameElement.style.display = 'block';
        this.drawCharacter(c, isNpc, layerType, scene, player, syncPlayerToJSON, cameraZoom, viewportWidth, viewportHeight, threeCamera);
      } else {
        // Hide immediately to save DOM and GPU
        if (vis.meshGroup) vis.meshGroup.visible = false;
        if (vis.nameElement) vis.nameElement.style.display = 'none';
        if (vis.chatElement) vis.chatElement.style.display = 'none';
      }
    };

    if (window.init?.characters) {
      for (let i = 0; i < window.init.characters.length; i++) processDraw(window.init.characters[i], false);
    }
    if (window.init?.npcs) {
      for (let i = 0; i < window.init.npcs.length; i++) processDraw(window.init.npcs[i], true);
    }
  }
}

export const characterManager = new CharacterManager();

export function updateLocalNPCs(dt) {
  if (!window.init || !window.init.npcs) return;

  const npcs = window.init.npcs;
  for (let i = 0; i < npcs.length; i++) {
    const npc = npcs[i];
    const npcVis = getCharacterProxy(npc.id);

    if (npc.roam_radius !== undefined && typeof npc.roam_radius === 'number') {
      if (npc.waitTimer === undefined) {
        npcVis._startX = npc.x !== undefined ? npc.x : 0;
        npcVis._startY = npc.y !== undefined ? npc.y : 0;
        npcVis._startRotation = npc.rotation || 0;
        npc.waitTimer = 1.0 + Math.random() * 3.0;
      }

      if (npc.waitTimer > 0) {
        npc.waitTimer -= dt;
      }

      if (npc.waitTimer <= 0) {
        if (npcVis._pendingRoamX !== undefined) {
          npcVis.targetX = npcVis._pendingRoamX;
          npcVis.targetY = npcVis._pendingRoamY;
          delete npcVis._pendingRoamX;
          delete npcVis._pendingRoamY;
          npc.waitTimer = 2.0 + (Math.random() * 3.0);
        } else {
          const angle = Math.random() * Math.PI * 2;
          const distance = Math.random() * npc.roam_radius;
          const destX = npcVis._startX + (Math.cos(angle) * distance);
          const destY = npcVis._startY + (Math.sin(angle) * distance);
          const dx = destX - npc.x;
          const dy = destY - npc.y;
          let destRotation = Math.atan2(dy, dx) * (180 / Math.PI);
          destRotation = (destRotation + 360) % 360;

          npcVis.targetRotation = Math.round(destRotation);
          npcVis._pendingRoamX = destX;
          npcVis._pendingRoamY = destY;
          npc.waitTimer = 0.5;
        }
      }
    } else if (npc.waypoints && Array.isArray(npc.waypoints) && npc.waypoints.length > 0) {
      if (npc.waitTimer === undefined) {
        npcVis._startX = npc.x !== undefined ? npc.x : 0;
        npcVis._startY = npc.y !== undefined ? npc.y : 0;
        npcVis._startRotation = npc.rotation || 0;
        npcVis._moveIdx = 0;
        npc.waitTimer = 0;
      }

      if (npc.waitTimer > 0) {
        npc.waitTimer -= dt;
      }

      if (npc.waitTimer <= 0) {
        npcVis._moveIdx = (npcVis._moveIdx + 1) % (npc.waypoints.length + 2);
        npcVis._currentOffsetX = npcVis._currentOffsetX || 0;
        npcVis._currentOffsetY = npcVis._currentOffsetY || 0;
        npcVis._currentOffsetRotation = npcVis._currentOffsetRotation || 0;

        let offset = { x: 0, y: 0, rotation: 0 };
        let nodeWaitTime = npc.move_time || 3000;

        if (npcVis._moveIdx > 0 && npcVis._moveIdx <= npc.waypoints.length) {
          offset = npc.waypoints[npcVis._moveIdx - 1];
          if (offset.move_time !== undefined) nodeWaitTime = offset.move_time;
        } else if (npcVis._moveIdx === npc.waypoints.length + 1) {
          offset = { x: -npcVis._currentOffsetX, y: -npcVis._currentOffsetY };
        } else if (npcVis._moveIdx === 0) {
          offset = { rotation: -npcVis._currentOffsetRotation };
        }

        if (offset.x !== undefined) npcVis._currentOffsetX += offset.x;
        if (offset.y !== undefined) npcVis._currentOffsetY += offset.y;
        if (offset.rotation !== undefined) npcVis._currentOffsetRotation += offset.rotation;

        if (npcVis._moveIdx === 0) {
          npcVis._currentOffsetX = 0;
          npcVis._currentOffsetY = 0;
          npcVis._currentOffsetRotation = 0;
        }

        npcVis.targetX = npcVis._startX + npcVis._currentOffsetX;
        npcVis.targetY = npcVis._startY + npcVis._currentOffsetY;
        npcVis.targetRotation = npcVis._startRotation + npcVis._currentOffsetRotation;

        npc.waitTimer = nodeWaitTime / 1000;
      }
    }
  }
}
