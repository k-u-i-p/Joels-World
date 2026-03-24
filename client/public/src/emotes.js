import { getCharacterProxy } from './characters.js';
import { footprints } from './main.js';
import { physicsEngine } from './physics.js';
import * as THREE from 'three';

/**
 * Generates the chat message text for a given emote, automatically handling string templating
 * and nearest-target resolution for emotes that interact with surrounding entities.
 * 
 * @param {string} emoteName - The internal dictionary key for the emote (e.g. 'laugh', 'cry').
 * @param {string} sourceName - The display name of the character performing the emote.
 * @param {number} sourceX - The X-coordinate map position of the character performing the emote.
 * @param {number} sourceY - The Y-coordinate map position of the character performing the emote.
 * @param {string|number} sourceId - The unique session ID of the character performing the emote (to avoid self-targeting).
 * @param {Object} [playerObj=null] - Optional reference to the local human player entity to include in nearest-target calculation.
 * @returns {string|null} The fully processed message string, or null if the emote doesn't broadcast a message.
 */
export function getEmoteMessage(emoteName, sourceName, sourceX, sourceY, sourceId, playerObj = null) {
  const emoteObj = emotes[emoteName];
  if (!emoteObj || (!emoteObj.message && !emoteObj.message_when_near)) return null;

  let msgText = '';
  let targetName = null;

  if (window.init && emoteObj.message_when_near) {
    let minD = Infinity;

    const checkDist = (list) => {
      const results = physicsEngine.findCharacters(list, sourceX, sourceY, sourceId);
      for (const c of results) {
        if (c.id === sourceId) continue;
        if (c._distSq < minD) {
          minD = c._distSq;
          targetName = c.name;
        }
      }
    };

    checkDist(window.init.characters || []);
    checkDist(window.init.npcs || []);

    if (playerObj && playerObj.id !== sourceId) {
      const dx = playerObj.x - sourceX;
      const dy = playerObj.y - sourceY;
      const distSq = dx * dx + dy * dy;
      if (distSq < minD) {
        minD = distSq;
        targetName = playerObj.name || 'Someone';
      }
    }
  }

  if (targetName && emoteObj.message_when_near) {
    msgText = emoteObj.message_when_near
      .replace('{name}', sourceName || 'Someone')
      .replace('{target_name}', targetName || 'Someone');
  } else if (emoteObj.message) {
    msgText = emoteObj.message.replace('{name}', sourceName || 'Someone');
  }

  return msgText;
}

export const emotes = {
  laser: {
    duration: 5000,
    message: "{name} is firing backwards lasers!",
    message_when_near: "{name} shot a laser at {target_name}!",
    sound: "/media/laser.mp3",
    updateLimbs3D: (rig, emote) => {
      // Hover translation up
      const hover = Math.sin((Date.now() - emote.startTime) / 100) * 3;
      rig.bodyPivot.position.set(0, 0, 15.5 + hover + 10);

      // Arms out into a flat T-Pose for maximum laser stability
      rig.leftHandTarget.set(0, -25, 15);
      rig.rightHandTarget.set(0, 25, 15);

      // Legs dangling down and slightly forward
      rig.leftFootTarget.set(-4, -6, -20);
      rig.rightFootTarget.set(-4, 6, -20);

      // Look upwards slightly
      rig.bodyPivot.rotation.x = Math.PI / 16;

      // Lazy load 3D Laser Beam Meshes onto the active skeleton
      if (!rig.emoteProps) {
        rig.emoteProps = new THREE.Group();

        const beamGeo = new THREE.CylinderGeometry(0.5, 0.5, 300, 8);
        beamGeo.rotateZ(Math.PI / 2); // Point straight along the X axis
        const beamMat = new THREE.MeshBasicMaterial({ color: 0xff0000, transparent: true, opacity: 0.8 });

        const eyeL = new THREE.Mesh(beamGeo, beamMat);
        eyeL.position.set(150, -4.5, 3.5); // Originate deeply inside the sphere eyes
        rig.emoteProps.add(eyeL);

        const eyeR = new THREE.Mesh(beamGeo, beamMat);
        eyeR.position.set(150, 4.5, 3.5);
        rig.emoteProps.add(eyeR);

        // Anchor the lasers natively to the Head node so they rotate flawlessly with the user!
        rig.head.add(rig.emoteProps);
      }

      // Pulse opacity
      const alpha = 0.5 + Math.sin((Date.now() - emote.startTime) / 50) * 0.5;
      rig.emoteProps.children.forEach(c => c.material.opacity = alpha);
    }
  },
  bounce: {
    duration: 3600000, // 1 hour duration
    message: "{name} is bouncing",
    message_when_near: "{name} is bouncing with {target_name}",
    sound: "/media/jump.mp3",
    updateLimbs3D: (rig, emote) => {
      const danceTime = (Date.now() - emote.startTime) / 150;
      const bounce = Math.abs(Math.sin(danceTime)) * 20;
      const tilt = Math.sin(danceTime * 0.8) * 0.3;

      // Translate core hierarchy rapidly upward
      rig.bodyPivot.position.z = 25.5 + bounce;
      rig.bodyPivot.rotation.x = tilt;

      // Fling arms playfully upward upon liftoff
      rig.leftHandTarget.z += bounce * 0.5;
      rig.rightHandTarget.z += bounce * 0.5;

      // Legs drag heavily behind the leaping torso natively
      rig.leftFootTarget.z -= bounce;
      rig.rightFootTarget.z -= bounce;
    }
  },
  wave: {
    duration: 3000,
    message: "{name} waves",
    message_when_near: "{name} waved at {target_name}",
    sound: null,
    updateLimbs3D: (rig, emote) => {
      const waveTime = (Date.now() - emote.startTime) / 100;
      const armSwing = Math.sin(waveTime) * 10;

      // Rapidly oscillate the right hand sweeping side-to-side dynamically over the head!
      rig.rightHandTarget.set(10, 20 + armSwing, 32);
    }
  },
  wet: {
    duration: 10000,
    message: "{name} is dripping wet",
    message_when_near: "{name} dripped water all over {target_name}",
    sound: "/media/wet_footprints.mp3",
    updateLimbs3D: (rig, emote, c) => {
      // Procedurally drop 3D Blueprint decals into the Global Scene Root
      if (!rig.crumbProps) {
        rig.crumbProps = new THREE.Group();
        const printGeo = new THREE.CircleGeometry(6, 16); // 12-unit diameter circles
        const printMat = new THREE.MeshBasicMaterial({ color: 0x3498db, transparent: true, opacity: 0.6, depthWrite: false });
        for (let i = 0; i < 16; i++) {
          const print = new THREE.Mesh(printGeo, printMat);
          print.userData = { lastDrop: 0 };
          print.visible = false;
          rig.crumbProps.add(print);
        }
        // Global map root so footprints stay behind!
        if (getCharacterProxy(c.id).meshGroup && getCharacterProxy(c.id).meshGroup.parent) {
          getCharacterProxy(c.id).meshGroup.parent.add(rig.crumbProps);
        }
      }

      const elapsed = Date.now() - emote.startTime;
      const stepIdx = Math.floor(elapsed / 400) % 16;
      const print = rig.crumbProps.children[stepIdx];

      const worldPos = new THREE.Vector3();
      getCharacterProxy(c.id).meshGroup.getWorldPosition(worldPos);

      // We only drop if it's inactive, or if it's genuinely older than our cycle time to avoid jitter
      if (!print.visible || print.userData.lastDrop < elapsed - 6000) {
        // Offset Y slightly based on stepIdx (left/right foot steps)
        const sideOffset = (stepIdx % 2 === 0 ? 5 : -5);
        
        // Calculate the forward/right vector based on yaw rotation
        const yaw = c.rotation * Math.PI / 180;
        const offsetX = Math.cos(yaw + Math.PI/2) * sideOffset;
        const offsetY = Math.sin(yaw + Math.PI/2) * sideOffset;
        
        print.position.copy(worldPos);
        print.position.x += offsetX;
        print.position.y += offsetY;
        print.position.z = 0.5; // flush with the floor
        print.rotation.z = -yaw; // match footprint orientation to player yaw!
        print.visible = true;
        print.userData.lastDrop = elapsed;
      }

      rig.crumbProps.children.forEach(p => {
        if (p.visible) {
          const age = elapsed - p.userData.lastDrop;
          if (age > 6400) { p.visible = false; }
          else {
            p.material.opacity = 0.8 * (1 - age / 6400);
            p.scale.setScalar(1 - age / 12800);
          }
        }
      });

      // Prop Instantiate 3D Dripping Water Orbs
      if (!rig.emoteProps) {
        rig.emoteProps = new THREE.Group();
        const dropGeo = new THREE.SphereGeometry(1.5, 6, 6);
        const dropMat = new THREE.MeshStandardMaterial({ color: 0x3498db, transparent: true, opacity: 0.8, roughness: 0.1 });

        for (let i = 0; i < 3; i++) {
          rig.emoteProps.add(new THREE.Mesh(dropGeo, dropMat));
        }
        rig.emotePropsDirectional.add(rig.emoteProps);
      }

      const swimTime = Date.now() - emote.startTime;
      for (let i = 0; i < 3; i++) {
        const offset = i * 333;
        const progress = ((swimTime + offset) % 1000) / 1000;

        const dropY = (i - 1) * 8;
        const dropZ = 25 - progress * 30; // Shower straight down to the floor

        const drop = rig.emoteProps.children[i];
        drop.position.set(0, dropY, dropZ);
        drop.scale.setScalar(5 - progress);
      }
    }
  },
  eat: {
    duration: 5000,
    message: "{name} is eating an apple",
    message_when_near: "{name} is eating an apple in front of {target_name}",
    sound: "/media/chewing.mp3",
    updateLimbs3D: (rig, emote) => {
      const eatTime = (Date.now() - emote.startTime) / 150;
      const bringToMouth = Math.max(0, Math.sin(eatTime));

      // Right arm lifts the apple drastically up and inward to the Face (+Z, -Y)
      rig.rightHandTarget.set(10, 16 - bringToMouth * 16, 12 + bringToMouth * 24);

      if (!rig.emoteProps) {
        rig.emoteProps = new THREE.Group();

        const appleGeo = new THREE.SphereGeometry(3.5, 10, 10);
        const appleMat = new THREE.MeshStandardMaterial({ color: 0xe74c3c, roughness: 0.5 });
        const apple = new THREE.Mesh(appleGeo, appleMat);
        apple.position.set(0, 0, 0);
        rig.emoteProps.add(apple);

        const stemGeo = new THREE.CylinderGeometry(0.3, 0.3, 3, 5);
        const stemMat = new THREE.MeshStandardMaterial({ color: 0x27ae60 });
        const stem = new THREE.Mesh(stemGeo, stemMat);
        stem.position.set(0, 0, 3.5);
        rig.emoteProps.add(stem);

        // Apple rigidly anchored into the right hand primitive!
        rig.rHand.add(rig.emoteProps);
      }

      // Handle aggressive chewing particle physics (instanced as loose prop meshes)
      if (!rig.crumbProps) {
        rig.crumbProps = new THREE.Group();
        const crumbGeo = new THREE.BoxGeometry(1.5, 1.5, 1.5);
        const crumbMat = new THREE.MeshStandardMaterial({ color: 0xe74c3c });
        for (let i = 0; i < 3; i++) {
          rig.crumbProps.add(new THREE.Mesh(crumbGeo, crumbMat));
        }
        rig.head.add(rig.crumbProps);
      }

      if (bringToMouth > 0.8) {
        rig.crumbProps.visible = true;
        for (const i of [0, 1, 2]) {
          const crumbTime = ((Date.now() - emote.startTime) % (200 + i * 50)) / 250;
          const dropX = 8 + crumbTime * (5 + i * 2);
          const dropY = (i - 1) * 3 + crumbTime * 4;
          const dropZ = -crumbTime * 10;

          const crumb = rig.crumbProps.children[i];
          crumb.position.set(dropX, dropY, dropZ);
          crumb.material.opacity = 1 - crumbTime;
          crumb.material.transparent = true;
        }
      } else {
        rig.crumbProps.visible = false;
      }
    }
  },
  lunch: {
    duration: 3600000, // 1 hour duration or until moved
    message: "{name} is having lunch",
    message_when_near: "{name} is having lunch with {target_name}",
    sound: "/media/chewing.mp3",
    updateLimbs3D: (rig, emote) => {
      // Lower Torso to floor
      rig.bodyPivot.position.z = 8;

      // Sit legs out front (knees bent, feet raised to rest naturally)
      rig.leftFootTarget.set(12, -6, -5);
      rig.rightFootTarget.set(12, 6, -5);

      const eatTime = (Date.now() - emote.startTime) / 200;
      const armMove = Math.sin(eatTime);

      // Prop Instantiate: Plate, Steak, Utensils
      if (!rig.emoteProps) {
        rig.emoteProps = new THREE.Group();

        const plateGeo = new THREE.CylinderGeometry(8, 6, 1, 16);
        plateGeo.rotateX(Math.PI / 2);
        const plateMat = new THREE.MeshStandardMaterial({ color: 0xecf0f1, roughness: 0.3 });
        const plate = new THREE.Mesh(plateGeo, plateMat);
        plate.position.set(22, 0, 1);
        rig.emoteProps.add(plate);

        const steakGeo = new THREE.CylinderGeometry(4, 4, 1.2, 8);
        steakGeo.rotateX(Math.PI / 2);
        const steakMat = new THREE.MeshStandardMaterial({ color: 0x8e44ad, roughness: 0.8 });
        const steak = new THREE.Mesh(steakGeo, steakMat);
        steak.position.set(22, 0, 2.1);
        rig.emoteProps.add(steak);

        const knifeGeo = new THREE.BoxGeometry(0.5, 6, 2);
        const knifeMat = new THREE.MeshStandardMaterial({ color: 0xbdc3c7 });
        const knife = new THREE.Mesh(knifeGeo, knifeMat);
        knife.position.set(0, 0, 4);
        rig.rHand.add(knife);

        const fork = new THREE.Mesh(knifeGeo, knifeMat);
        fork.position.set(0, 0, 4);
        rig.lHand.add(fork);

        // Plate stays fixed relative to the body pivot bounds
        rig.emotePropsDirectional.add(rig.emoteProps);
      }

      // Animate oscillating utensil swing
      if (armMove > 0) {
        // Right hand to face
        rig.rightHandTarget.set(8 + armMove * 2, 8 - armMove * 8, 12 + armMove * 14);
        // Left hand to plate
        rig.leftHandTarget.set(20, -12, -6);
      } else {
        // Left hand to face
        rig.leftHandTarget.set(8 - armMove * 2, -8 - armMove * 8, 12 - armMove * 14);
        // Right hand to plate
        rig.rightHandTarget.set(20, 12, -6);
      }
    }
  },
  write: {
    duration: 3600000, // 1 hour duration or until moved
    message: "{name} is writing",
    message_when_near: "{name} is writing with {target_name}",
    updateLimbs3D: (rig, emote) => {
      // Lower Torso to floor
      rig.bodyPivot.position.z = 8;

      // Sit legs out front (knees bent, feet raised to rest naturally)
      rig.leftFootTarget.set(12, -6, -5);
      rig.rightFootTarget.set(12, 6, -5);

      const writeTime = (Date.now() - emote.startTime) / 100;
      const armMoveX = Math.sin(writeTime) * 3;
      const armMoveY = Math.cos(writeTime * 1.3) * 2;

      // Prop Instantiate: Book and Pen
      if (!rig.emoteProps) {
        rig.emoteProps = new THREE.Group();
        const bookGeo = new THREE.BoxGeometry(18, 14, 0.5);
        const bookMat = new THREE.MeshStandardMaterial({ color: 0xecf0f1, roughness: 0.9 });
        const book = new THREE.Mesh(bookGeo, bookMat);
        book.position.set(25, 0, 20);
        rig.emoteProps.add(book);

        const penGeo = new THREE.CylinderGeometry(0.5, 0.5, 6, 6);
        const penMat = new THREE.MeshStandardMaterial({ color: 0x3498db });
        const pen = new THREE.Mesh(penGeo, penMat);
        pen.position.set(0, 0, 5);
        pen.rotation.x = Math.PI / 4;
        rig.rHand.add(pen);

        rig.bodyPivot.add(rig.emoteProps);
      }

      // Writing right hand bounding
      rig.rightHandTarget.set(19 + armMoveX, 4 + armMoveY, 22);

      // Left arm resting firmly on paper
      rig.leftHandTarget.set(15, -8, 0);
    }
  },
  jump: {
    duration: 800,
    message: "{name} leaps forward",
    message_when_near: "{name} leaped over {target_name}!",
    sound: "/media/jump.mp3",
    updateLimbs3D: (rig, emote) => {
      const age = Date.now() - emote.startTime;

      if (!rig.emoteProps) {
        rig.emoteProps = new THREE.Group();
        const dustGeo = new THREE.SphereGeometry(4, 6, 6);
        const dustMat = new THREE.MeshStandardMaterial({ color: 0xbdc3c7, transparent: true, opacity: 0 });
        for (let i = 0; i < 4; i++) {
          rig.emoteProps.add(new THREE.Mesh(dustGeo, dustMat));
        }
        // Dust tracks player Yaw independently!
        rig.emotePropsDirectional.add(rig.emoteProps);
      }

      if (age < 800) {
        const progress = age / 800;
        const height = progress * (1 - progress) * 4 * 30; // Native Parabolic altitude lift

        rig.bodyPivot.position.z = 15.5 + height;
        rig.bodyPivot.rotation.y = Math.sin(progress * Math.PI) * 0.4;

        const tuck = Math.sin(progress * Math.PI);
        rig.leftFootTarget.set(-2, -6, -13 + tuck * 15);
        rig.rightFootTarget.set(-2, 6, -13 + tuck * 15);

        const armSwing = Math.cos(progress * Math.PI * 2);
        rig.leftHandTarget.set(10 * armSwing, -16, 20 - armSwing * 10);
        rig.rightHandTarget.set(10 * armSwing, 16, 20 - armSwing * 10);

        // Procedurally scale and evaluate Cloud dust opacity relative to lift progress
        if (progress < 0.25 || progress > 0.75) {
          const dustP = progress < 0.25 ? (progress / 0.25) : ((progress - 0.75) / 0.25);
          const opac = Math.max(0, 1 - dustP * 1.5);
          rig.emoteProps.children.forEach((c, idx) => {
            c.material.opacity = opac;
            c.position.set(-10 + (idx % 2) * 20 + dustP * 10, -10 + (Math.floor(idx / 2)) * 20, 0);
            c.scale.setScalar(1 + dustP * 2);
          });
        }
      } else {
        rig.emoteProps.children.forEach(c => c.material.opacity = 0);
      }
    }
  },
  dance: {
    duration: 8000,
    message: "{name} is busting a move",
    message_when_near: "{name} is dancing with {target_name}",
    updateLimbs3D: (rig, emote) => {
      const danceTime = (Date.now() - emote.startTime) / 150;
      const bob = Math.abs(Math.sin(danceTime * 2)) * 6; // bounce up
      const tilt = Math.sin(danceTime) * 0.3; // sway

      rig.bodyPivot.position.z = 15.5 + bob;
      rig.bodyPivot.rotation.x = tilt;

      const armSwing = Math.sin(danceTime * 2);
      const legStep = Math.cos(danceTime * 2);

      // Disco Pointing!
      rig.leftHandTarget.set(0, -20 - armSwing * 10, 20 + armSwing * 15);
      rig.rightHandTarget.set(0, 20 - armSwing * 10, 20 - armSwing * 15);

      // Legs swing dynamically out horizontally across the map grid
      rig.leftFootTarget.set(0, -6 - Math.max(0, -legStep * 10), -13);
      rig.rightFootTarget.set(0, 6 + Math.max(0, legStep * 10), -13);

      if (!rig.emoteProps) {
        rig.emoteProps = new THREE.Group();
        const noteGeo = new THREE.BoxGeometry(3, 3, 3);
        const noteMat = new THREE.MeshStandardMaterial({ color: 0x9b59b6 });
        for (let i = 0; i < 3; i++) {
          rig.emoteProps.add(new THREE.Mesh(noteGeo, noteMat));
        }
        rig.emotePropsDirectional.add(rig.emoteProps);
      }

      const timeActive = Date.now() - emote.startTime;
      for (let i = 0; i < 3; i++) {
        const offset = i * 400;
        const progress = ((timeActive + offset) % 1200) / 1200;

        const noteX = Math.sin(progress * Math.PI * 4 + i) * 15;
        const noteZ = 15 + progress * 40;

        const note = rig.emoteProps.children[i];
        note.position.set(noteX, 0, noteZ);
        note.rotation.x += 0.1;
        note.rotation.y += 0.1;

        note.scale.setScalar(Math.max(0.01, 1 - progress));
      }
    }
  },
  fart: {
    duration: 2000,
    message: "{name} is farting",
    message_when_near: "{name} farted on {target_name}",
    sound: "/media/fart.mp3",
    updateLimbs3D: (rig, emote) => {
      const fartAge = Date.now() - emote.startTime;

      if (!rig.emoteProps) {
        rig.emoteProps = new THREE.Group();
        const gasGeo = new THREE.SphereGeometry(8, 8, 8);
        const gasMat = new THREE.MeshBasicMaterial({ color: 0x2ecc71, transparent: true, opacity: 0.8 });
        for (let i = 0; i < 3; i++) {
          rig.emoteProps.add(new THREE.Mesh(gasGeo, gasMat));
        }
        rig.emotePropsDirectional.add(rig.emoteProps);
      }

      if (fartAge < 1000) {
        const progress = fartAge / 1000;
        const alpha = Math.max(0, 1 - progress);
        rig.emoteProps.children.forEach((cloud, i) => {
          cloud.material.opacity = alpha;
          cloud.position.set(-8 - progress * 15 - i * 5, (i - 1) * 5, 10 + progress * 5);
          cloud.scale.setScalar(1 + progress);
        });
      } else {
        rig.emoteProps.children.forEach(c => c.material.opacity = 0);
      }
    }
  },
  dead: {
    duration: 10000,
    message: "{name} is dead",
    message_when_near: "{name} died in front of {target_name}",
    updateLimbs3D: (rig, emote) => {
      // Lay flat on their back, completely lifeless
      rig.bodyPivot.position.set(0, 0, 4);
      rig.bodyPivot.rotation.y = -Math.PI / 2;

      // Arms splayed outwards heavily along the ground grid
      rig.leftHandTarget.set(10, -25, 4);
      rig.rightHandTarget.set(10, 25, 4);

      // Legs lazily splayed
      rig.leftFootTarget.set(-15, -15, 4);
      rig.rightFootTarget.set(-15, 15, 4);
    }
  },
  cry: {
    duration: 5000,
    message: "{name} is crying",
    message_when_near: "{name} cried on {target_name}",
    sound: "/media/violin.mp3",
    updateLimbs3D: (rig, emote) => {
      // Tilt head softly downward
      rig.bodyPivot.rotation.y = Math.PI / 16;

      // Hands rubbing eyes
      rig.leftHandTarget.set(16, -4, 20);
      rig.rightHandTarget.set(16, 4, 20);

      if (!rig.emoteProps) {
        rig.emoteProps = new THREE.Group();
        const tearGeo = new THREE.SphereGeometry(2, 6, 6);
        const tearMat = new THREE.MeshBasicMaterial({ color: 0x3498db, transparent: true, opacity: 0.8 });
        for (let i = 0; i < 6; i++) {
          rig.emoteProps.add(new THREE.Mesh(tearGeo, tearMat));
        }
        // Tears stream rigidly proportional to the native Head bone matrix!
        rig.head.add(rig.emoteProps);
      }

      for (let i = 0; i < 6; i++) {
        const offset = i * (1000 / 6);
        const progress = ((Date.now() + offset) % 1000) / 1000;

        const tearSize = 3.0 - progress * 1.0; // Start huge, shrink slightly
        const tearZ = 2 - Math.pow(progress, 2) * 45; // Parabolic jump/gravity-like fall down further
        const tearX = 6 + progress * 20; // Eject significantly forward
        const tearY = (i % 2 === 0 ? 1 : -1) * (8 + progress * 35); // Eject explosively sideways

        const tear = rig.emoteProps.children[i];
        tear.position.set(tearX, tearY, tearZ);
        tear.scale.setScalar(tearSize);
        tear.material.opacity = 1 - Math.pow(progress, 2);
      }
    }
  },
  gritty: {
    duration: 5000,
    message: "{name} is doing the gritty",
    message_when_near: "{name} hit the gritty on {target_name}!",
    updateLimbs3D: (rig, emote) => {
      const danceTime = (Date.now() - emote.startTime) / 150;
      const swing = Math.sin(danceTime);
      const fastSwing = Math.sin(danceTime * 2);

      // Rigorous core bobbing
      rig.bodyPivot.position.z = 15.5 - Math.abs(fastSwing * 4);
      rig.bodyPivot.position.x = fastSwing * 2;

      // Alternating forward heel taps!
      if (swing > 0) {
        rig.leftFootTarget.set(-2, -6, -13);
        rig.rightFootTarget.set(10, 16, -13); // Force heel outwards
      } else {
        rig.leftFootTarget.set(10, -16, -13);
        rig.rightFootTarget.set(-2, 6, -13);
      }

      // Aggressive rigid arm flailing
      rig.leftHandTarget.set(10 + swing * 8, -6, 12);
      rig.rightHandTarget.set(10 - swing * 8, 6, 12);
    }
  },
  laugh: {
    duration: 5000,
    message: "{name} is rolling on the floor laughing",
    message_when_near: "{name} laughed at {target_name}",
    sound: "/media/laugh.mp3",
    updateLimbs3D: (rig, emote) => {
      const laughTime = (Date.now() - emote.startTime) / 100;
      const rock = Math.sin(laughTime) * 6;
      const kick = Math.sin(laughTime * 2) * 8;

      // Fling body backward onto the floor, rolling slightly!
      rig.bodyPivot.position.set(0, rock, 8);
      rig.bodyPivot.rotation.x = -Math.PI / 4 + rock * 0.05;

      // Arms aggressively clasping the stomach
      rig.leftHandTarget.set(10, -4, 12 + kick * 0.5);
      rig.rightHandTarget.set(10, 4, 12 - kick * 0.5);

      // Legs violently kicking wildly in the air
      rig.leftFootTarget.set(15 + kick, -8, 8 - kick);
      rig.rightFootTarget.set(15 - kick, 8, 8 + kick);

      // Joyful Tears
      if (!rig.emoteProps) {
        rig.emoteProps = new THREE.Group();
        const tearGeo = new THREE.SphereGeometry(1.5, 4, 4);
        const tearMat = new THREE.MeshBasicMaterial({ color: 0x3498db, transparent: true, opacity: 0.8 });
        for (let i = 0; i < 2; i++) {
          rig.emoteProps.add(new THREE.Mesh(tearGeo, tearMat));
        }
        rig.head.add(rig.emoteProps);
      }

      const progress = ((Date.now() - emote.startTime) % 1000) / 1000;
      rig.emoteProps.children.forEach((tear, idx) => {
        tear.position.set(4, idx === 0 ? -5 - progress * 5 : 5 + progress * 5, 0);
        tear.material.opacity = 1 - progress;
      });
    }
  },
  love: {
    duration: 5000,
    message: "{name} is in love",
    sound: "/media/romance.mp3",
    message_when_near: "{name} blew a kiss to {target_name}",
    updateLimbs3D: (rig, emote) => {
      const age = Date.now() - emote.startTime;
      const hover = Math.sin(age / 150) * 2;

      rig.bodyPivot.position.z = 15.5 + hover;

      // Arms clasped beautifully forward
      rig.leftHandTarget.set(10, -2, 12);
      rig.rightHandTarget.set(10, 2, 12);

      // Legs kicking back in unison adorably (-Z trajectory)
      const kick = Math.max(0, -Math.sin(age / 150) * 8);
      rig.leftFootTarget.set(-kick, -3, -13 + kick * 0.5);
      rig.rightFootTarget.set(-kick, 3, -13 + kick * 0.5);

      if (!rig.emoteProps) {
        rig.emoteProps = new THREE.Group();

        const c2d = document.createElement('canvas');
        c2d.width = 128; c2d.height = 128;
        const c2dCtx = c2d.getContext('2d');
        c2dCtx.font = '100px sans-serif';
        c2dCtx.textAlign = 'center'; c2dCtx.textBaseline = 'middle';
        c2dCtx.fillText('❤️', 64, 64);
        const tex = new THREE.CanvasTexture(c2d);
        const heartMat = new THREE.SpriteMaterial({ map: tex, transparent: true, depthWrite: false });

        for (let i = 0; i < 4; i++) {
          rig.emoteProps.add(new THREE.Sprite(heartMat));
        }
        // Attach strictly to directional root for independent particle trajectories frontward!
        rig.emotePropsDirectional.add(rig.emoteProps);
      }

      for (let i = 0; i < 4; i++) {
        const offset = i * 500;
        const progress = ((age + offset) % 2000) / 2000;
        const heart = rig.emoteProps.children[i];

        heart.material.opacity = 1 - Math.pow(progress, 2);

        const curZ = 15 + progress * 40;
        const curY = Math.sin(progress * Math.PI * 6 + i) * 6;
        const curX = 20 + progress * 20;

        heart.position.set(curX, curY, curZ);
        heart.scale.setScalar(10 - progress * 2);
      }
    }
  },
  tennis: {
    duration: 3600000,
    message: "{name} is playing tennis",
    message_when_near: "{name} is playing tennis with {target_name}!",
    onEnd: (c, rig) => {
      if (c && c.holding === 'tennis_racket') c.holding = null;
    },
    updateLimbs3D: (rig, emote, c) => {
      if (c && c.holding !== 'tennis_racket') c.holding = 'tennis_racket';

      // Relaxed bouncing stance
      rig.bodyPivot.position.z = 15.5;
      rig.leftFootTarget.set(-2, -8, -13);
      rig.rightFootTarget.set(2, 10, -13);

      const elapsed = Date.now() - emote.startTime;
      const bounceCycle = (elapsed % 1000) / 1000;

      if (!rig.emoteProps) {
        rig.emoteProps = new THREE.Group();

        // Render isolated bouncing Tennis Ball primitive
        const ballGeo = new THREE.SphereGeometry(2.0, 20, 20);
        const ballMat = new THREE.MeshStandardMaterial({ color: 0xcaff28 });
        const ball = new THREE.Mesh(ballGeo, ballMat);
        rig.emoteProps.add(ball);

        // Attach Prop strictly to directional root
        rig.emotePropsDirectional.add(rig.emoteProps);
      }

      const ball = rig.emoteProps.children[0];

      // Native Parabolic Bounce math evaluated on the localized Z axis
      const bounceHeight = 50;
      const ballZ = -2 + 1.5 + (4 * bounceHeight * bounceCycle * (1 - bounceCycle));

      // Ball translates securely under the resting location of the left hand bounds
      ball.position.set(12, -10, ballZ);
      ball.visible = true;

      // Left hand follows the top curvature of the ball lazily
      const catchHover = Math.max(-1, ballZ + 3);
      rig.leftHandTarget.set(12, -10, catchHover);

      // Right hand sways the racket idly
      const swayTime = elapsed / 500;
      const sway = Math.sin(swayTime) * 3;
      rig.rightHandTarget.set(8 + sway, 12, 15);
    }
  },
  rugby: {
    duration: 3600000, // Lasts for 1 hour, or until player moves
    message: "{name} is holding a rugby ball",
    message_when_near: "{name} passed the ball to {target_name}!",
    updateLimbs3D: (rig, emote) => {
      // Hold ball tightly with BOTH hands centrally tracking the chest mass
      rig.rightHandTarget.set(12, 5, 12);
      rig.leftHandTarget.set(12, -5, 12);

      if (!rig.emoteProps) {
        rig.emoteProps = new THREE.Group();
        const ballGeo = new THREE.SphereGeometry(3.5, 12, 12);
        // Mutate origin primitive geometry scaling it dynamically to an Oblong format
        ballGeo.scale(1.5, 1, 1);
        const ballMat = new THREE.MeshStandardMaterial({ color: 0xf0f0f0 });
        const ball = new THREE.Mesh(ballGeo, ballMat);

        ball.position.set(10, 0, 12);
        ball.rotation.x = Math.PI / 2;

        rig.emoteProps.add(ball);
        rig.emotePropsDirectional.add(rig.emoteProps);
      }
    }
  },
  sit: {
    duration: 3600000, // Lasts for 1 hour, or until player moves
    message: "{name} sat down",
    message_when_near: "{name} sat next to {target_name}",
    updateLimbs3D: (rig, emote) => {
      rig.bodyPivot.position.z = 8;

      rig.leftFootTarget.set(12, -6, -1);
      rig.rightFootTarget.set(12, 6, -1);

      rig.leftHandTarget.set(8, -12, 13);
      rig.rightHandTarget.set(8, 12, 13);
    }
  },
  swim: {
    duration: 3600000, // 1 hour duration or until moved/canceled
    message: "{name} is swimming",
    message_when_near: "{name} splashed {target_name}!",
    sound: "/media/splash.mp3",
    updateLimbs3D: (rig, emote) => {
      const swimTime = (Date.now() - emote.startTime) / 200;
      const bob = Math.sin(swimTime) * 3;

      // Lie flat aggressively on stomach (+Y pitch projection)
      rig.bodyPivot.position.set(0, 0, 15.5 + bob);
      rig.bodyPivot.rotation.y = Math.PI / 2;

      // Raise the head higher above water
      rig.head.rotation.y = -Math.PI / 3;

      const stroke = Math.sin(swimTime);
      const sweep = Math.cos(swimTime);
      // Breast stroke arms sweeping back and forth relative to body
      rig.leftHandTarget.set(15 - stroke * 10, -8 - sweep * 10, 15.5);
      rig.rightHandTarget.set(15 - stroke * 10, 8 + sweep * 10, 15.5);

      // Highly exaggerated synchronized breaststroke frog kick
      const frogZ = sweep * 8;
      const spread = Math.max(0, stroke * 12);
      const frogX = Math.cos(swimTime * 2) * 3;

      rig.leftFootTarget.set(frogX, -4 - spread, -13 + frogZ);
      rig.rightFootTarget.set(frogX, 4 + spread, -13 + frogZ);

      // Procedural 3D Water Ripple Ring generation and Water surface
      if (!rig.emoteProps) {
        rig.emoteProps = new THREE.Group();
        const ripGeo = new THREE.TorusGeometry(5, 0.5, 4, 16);
        ripGeo.rotateX(Math.PI / 2);
        const ripMat = new THREE.MeshBasicMaterial({ color: 0x3498db, transparent: true, opacity: 0.8 });

        for (let i = 0; i < 3; i++) {
          rig.emoteProps.add(new THREE.Mesh(ripGeo, ripMat));
        }

        // Attach globally decoupled from skeletal pivot
        rig.emotePropsDirectional.add(rig.emoteProps);
      }

      for (let i = 0; i < 3; i++) {
        const offset = i * 400;
        const noteAge = (Date.now() - emote.startTime + offset) % 1200;
        const progress = noteAge / 1200;

        const ripple = rig.emoteProps.children[i];
        ripple.scale.setScalar(0.1 + progress * 3);
        ripple.material.opacity = 1 - progress;
        ripple.position.set(0, 0, 0.5);
      }

      // Gently bob the covering water plane
      const waterPlane = rig.emoteProps.getObjectByName("WaterPlane");
      if (waterPlane) {
        waterPlane.position.z = 18 + Math.sin(swimTime) * 1.5;
      }
    }
  },
  sleep: {
    duration: 3600000, // 1 hour duration or until moved
    message: "{name} fell asleep",
    message_when_near: "{name} fell asleep next to {target_name}",
    sound: "/media/snoring.mp3",
    updateLimbs3D: (rig, emote) => {
      // Recline beautifully tracking -90 degrees flat
      rig.bodyPivot.position.set(0, 0, 4);
      rig.bodyPivot.rotation.x = -Math.PI / 2;

      const breathe = Math.sin((Date.now() - emote.startTime) / 500) * 1;
      rig.bodyPivot.position.z += breathe;

      rig.leftHandTarget.set(10, -15, 4);
      rig.rightHandTarget.set(10, 15, 4);
      rig.leftFootTarget.set(-15, -6, 4);
      rig.rightFootTarget.set(-15, 6, 4);

      if (!rig.emoteProps) {
        rig.emoteProps = new THREE.Group();

        // Retro geometric compound rendering for the 'ZZZ' floating texts
        const zGroup = new THREE.Group();
        const zMat = new THREE.MeshStandardMaterial({ color: 0x2ecc71, transparent: true });

        const top = new THREE.Mesh(new THREE.BoxGeometry(4, 1, 1), zMat); top.position.set(0, 0, 2);
        const mid = new THREE.Mesh(new THREE.BoxGeometry(1, 4, 1), zMat); mid.rotation.y = Math.PI / 4;
        const bot = new THREE.Mesh(new THREE.BoxGeometry(4, 1, 1), zMat); bot.position.set(0, 0, -2);
        zGroup.add(top, mid, bot);

        for (let i = 0; i < 3; i++) {
          rig.emoteProps.add(zGroup.clone());
        }
        // Global mesh binding allowing letters to drift independently 
        rig.meshGroup.add(rig.emoteProps);
      }

      const timeActive = Date.now() - emote.startTime;
      for (let i = 0; i < 3; i++) {
        const offset = i * 800;
        const progress = ((timeActive + offset) % 2400) / 2400;

        const zX = -5 - progress * 30;
        const zY = Math.sin(progress * Math.PI * 4 + i * 2) * 8;
        const zZ = 10 + progress * 20;

        const zMesh = rig.emoteProps.children[i];
        zMesh.position.set(zX, zY, zZ);
        zMesh.scale.setScalar(0.5 + progress * 1.5);

        zMesh.children.forEach(c => c.material.opacity = 1 - Math.pow(progress, 2));
      }
    }
  }
};
