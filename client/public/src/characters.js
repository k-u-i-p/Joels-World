import { emotes } from './emotes.js';
import { physicsEngine } from './physics.js';
import * as THREE from 'three';

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

export class CharacterManager {
  disposeCharacter(c, scene) {
    if (c.meshGroup) {
      scene.remove(c.meshGroup);
      c.meshGroup.traverse((child) => {
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
      c.meshGroup = null;
    }
    if (c.nameElement && c.nameElement.parentNode) c.nameElement.parentNode.removeChild(c.nameElement);
    if (c.chatElement && c.chatElement.parentNode) c.chatElement.parentNode.removeChild(c.chatElement);
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

  drawLine(ctxObj, sx, sy, ex, ey) {
    ctxObj.beginPath();
    ctxObj.moveTo(sx, sy);
    ctxObj.lineTo(ex, ey);
    ctxObj.stroke();
  }

  drawShoe(ctxObj, x, y, color, isLeft) {
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

  drawHumanoid(ctx, c, limbs) {
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

    this.drawHumanoidLowerBody(ctx, c, limbs, isVisible);
    this.drawHumanoidUpperBody(ctx, c, limbs, isVisible, getRaycastEnd);
  }

  drawHumanoidLowerBody(ctx, c, limbs, isVisible) {
    if (!isVisible) isVisible = () => true;

    if (!c.emote || (c.emote.name !== 'sit' && c.emote.name !== 'lunch' && c.emote.name !== 'write')) {
      const shoeColor = c.shoeColor || '#1a252f';
      if (isVisible(limbs.leftLegEndX, limbs.leftLegEndY)) {
        this.drawShoe(ctx, limbs.leftLegEndX, limbs.leftLegEndY, shoeColor, true);
      }
      if (isVisible(limbs.rightLegEndX, limbs.rightLegEndY)) {
        this.drawShoe(ctx, limbs.rightLegEndX, limbs.rightLegEndY, shoeColor, false);
      }
    }
  }

  drawHumanoidUpperBody(ctx, c, limbs, isVisible, getRaycastEnd) {
    if (!isVisible) isVisible = () => true;
    if (!getRaycastEnd) getRaycastEnd = (sx, sy, tx, ty) => ({ x: tx, y: ty, hit: false });

    const armOffset = 11;

    const leftArmEnd = getRaycastEnd(0, -armOffset, limbs.leftArmX, limbs.leftArmY);
    const rightArmEnd = getRaycastEnd(0, armOffset, limbs.rightArmX, limbs.rightArmY);

    const armGradient = ctx.createLinearGradient(0, -armOffset, 0, limbs.leftArmY);
    armGradient.addColorStop(0, c.armColor || '#3498db');
    armGradient.addColorStop(1, shadeColor(c.armColor || '#3498db', -30));

    ctx.lineWidth = 5;
    ctx.strokeStyle = armGradient;

    this.drawLine(ctx, 0, -armOffset, leftArmEnd.x, leftArmEnd.y);

    const rightArmGradient = ctx.createLinearGradient(0, armOffset, 0, limbs.rightArmY);
    rightArmGradient.addColorStop(0, c.armColor || '#3498db');
    rightArmGradient.addColorStop(1, shadeColor(c.armColor || '#3498db', -30));
    ctx.strokeStyle = rightArmGradient;
    this.drawLine(ctx, 0, armOffset, rightArmEnd.x, rightArmEnd.y);

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
    bodyGradient.addColorStop(0, c.shirtColor || '#3498db');
    bodyGradient.addColorStop(0.5, shadeColor(c.shirtColor || '#3498db', 20)); 
    bodyGradient.addColorStop(1, shadeColor(c.shirtColor || '#3498db', -40));  
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

    let hairColor = c.hairColor;
    if (!hairColor && c.gender === 'female') hairColor = '#e67e22';

    if (hairColor && hairColor !== 'none' && hairColor !== 'bald' && c.hairStyle !== 'bald') {
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

      const style = c.hairStyle || (c.gender === 'female' ? 'long' : 'short');

      if (style === 'short') {
        ctx.arc(1, 0, 7.5, PI_HALF + 0.3, PI_ONE_HALF - 0.3, false);
        ctx.fill();
      } else if (style === 'spiky') {
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
      } else if (style === 'ponytail') {
        ctx.arc(1, 0, 7.5, PI_HALF, PI_ONE_HALF, false);
        ctx.fill();
        ctx.beginPath();
        if (ctx.ellipse) {
          ctx.ellipse(-9, 0, 4, 3, 0, 0, PI2);
        } else {
          ctx.arc(-9, 0, 3.5, 0, PI2);
        }
        ctx.fill();
      } else if (style === 'messy') {
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

  ensureThreeSetup(c, scene) {
    if (!c.meshGroup) {
      c.meshGroup = new THREE.Group();
      scene.add(c.meshGroup);

      const baseScale = window.init?.mapData?.character_scale || 1;
      const widthScale = (c.width || 40) / 40;
      const heightScale = (c.height || 40) / 40;
      const maxScale = baseScale * Math.max(widthScale, heightScale);

      const logicalSize = Math.max(120, 120 * maxScale);

      // Procedural character canvas backing
      // WebGL Materials naturally evaluate basic HTML5 string-formatted colors!
      const skinMat = new THREE.MeshLambertMaterial({ color: c.color || '#f1c40f' });
      const shirtMat = new THREE.MeshLambertMaterial({ color: c.shirtColor || '#3498db' });
      const armMat = new THREE.MeshLambertMaterial({ color: c.armColor || c.shirtColor || '#3498db' });
      const pantsMat = new THREE.MeshLambertMaterial({ color: c.pantsColor || '#2c3e50' });
      const shoeMat = new THREE.MeshLambertMaterial({ color: c.shoeColor || '#7f8c8d' });

      // Core skeleton rig (Scaled to match old R=14 Canvas Paths)
      c.rig = {
         bodyPivot: new THREE.Group(),
         head: new THREE.Mesh(new THREE.SphereGeometry(10.5, 16, 16), skinMat),
         torso: new THREE.Mesh(new THREE.CylinderGeometry(13, 13, 22, 16), shirtMat),
         leftArm: new THREE.Group(),
         rightArm: new THREE.Group(),
         leftLeg: new THREE.Group(),
         rightLeg: new THREE.Group()
      };

      c.meshGroup.add(c.rig.bodyPivot);
      c.rig.bodyPivot.add(c.rig.torso);

      // Torso stands UP along the Z axis
      c.rig.torso.rotation.x = Math.PI / 2;
      c.rig.torso.position.set(0, 0, 20);

      // Head is placed above the torso on the Z axis
      c.rig.head.position.set(2, 0, 36); // Slightly forward on X (face points X+)
      c.rig.bodyPivot.add(c.rig.head);

      // Build Hair
      const style = c.hairStyle || (c.gender === 'female' ? 'long' : 'short');
      const hairMat = new THREE.MeshLambertMaterial({ color: c.hairColor || '#8e44ad' });
      
      const hairGroup = new THREE.Group();
      hairGroup.position.set(0, 0, 0); // Local to Head
      
      const baseHairGeo = new THREE.SphereGeometry(11, 16, 16, 0, Math.PI, 0, Math.PI);
      
      if (style === 'spiky') {
          const spikeGeo = new THREE.ConeGeometry(3.5, 10, 6);
          for (let i = 0; i < 5; i++) {
              const spike = new THREE.Mesh(spikeGeo, hairMat);
              spike.rotation.y = (Math.PI / 4) * (i - 2);
              spike.rotation.x = Math.PI / 2;
              spike.position.set(-1.5, (i - 2) * 2.0, 9); 
              hairGroup.add(spike);
          }
      } else if (style === 'ponytail') {
          const baseHair = new THREE.Mesh(baseHairGeo, hairMat);
          baseHair.rotation.y = -Math.PI / 2; // Cover back half of head
          hairGroup.add(baseHair);
          
          const tailGeo = new THREE.ConeGeometry(4, 18, 8);
          const tail = new THREE.Mesh(tailGeo, hairMat);
          tail.rotation.z = Math.PI / 2;
          tail.position.set(-14, 0, 3); // Drooping off the back
          hairGroup.add(tail);
      } else if (style === 'messy') {
          const baseHair = new THREE.Mesh(baseHairGeo, hairMat);
          baseHair.rotation.y = -Math.PI / 2;
          hairGroup.add(baseHair);
          
          const tuftGeo = new THREE.ConeGeometry(3.5, 10, 5);
          
          // Replicate the zig-zag sawtooth path of the original 2D stroke
          const t1 = new THREE.Mesh(tuftGeo, hairMat);
          t1.rotation.y = -Math.PI / 5; // Angle outward left
          t1.rotation.x = Math.PI / 2;
          t1.position.set(-8, -7, 5);
          hairGroup.add(t1);

          const t2 = new THREE.Mesh(tuftGeo, hairMat);
          t2.rotation.y = Math.PI / 12; // Angle backward
          t2.rotation.x = Math.PI / 2;
          t2.position.set(-11, -1, 4);
          hairGroup.add(t2);

          const t3 = new THREE.Mesh(tuftGeo, hairMat);
          t3.rotation.y = Math.PI / 5; // Angle outward right
          t3.rotation.x = Math.PI / 2;
          t3.position.set(-8, 6, 7);
          hairGroup.add(t3);
      } else if (style === 'long') {
          const baseHair = new THREE.Mesh(baseHairGeo, hairMat);
          baseHair.rotation.y = -Math.PI / 2;
          hairGroup.add(baseHair);
          
          // Long flowing locks down the back/sides
          const lockGeo = new THREE.ConeGeometry(4.5, 16, 6);
          const rightLock = new THREE.Mesh(lockGeo, hairMat);
          rightLock.rotation.z = Math.PI / 2;
          rightLock.position.set(-10, 8, -1);
          hairGroup.add(rightLock);
          
          const leftLock = new THREE.Mesh(lockGeo, hairMat);
          leftLock.rotation.z = Math.PI / 2;
          leftLock.position.set(-10, -8, -1);
          hairGroup.add(leftLock);
      } else {
          // 'short' / Base flat cap style hair
          const baseHair = new THREE.Mesh(baseHairGeo, hairMat);
          baseHair.rotation.y = -Math.PI / 2;
          hairGroup.add(baseHair);
      }
      c.rig.head.add(hairGroup);

      // Build Arms (Cylinders point along Y natively, we rotate them to point along Z)
      const armGeo = new THREE.CylinderGeometry(5.5, 5.5, 16, 10);
      const handGeo = new THREE.SphereGeometry(6.5, 12, 12);
      const shoulderGeo = new THREE.SphereGeometry(5.5, 12, 12);
      
      const lArmMesh = new THREE.Mesh(armGeo, armMat);
      lArmMesh.rotation.x = Math.PI / 2;
      lArmMesh.position.set(0, 0, -8); // Drop down from shoulder pivot
      c.rig.leftArm.add(lArmMesh);
      
      const lHand = new THREE.Mesh(handGeo, skinMat);
      lHand.position.set(0, 0, -17); // Terminus of the sleeve
      c.rig.leftArm.add(lHand);
      
      const lShoulder = new THREE.Mesh(shoulderGeo, armMat);
      lShoulder.position.set(0, 0, 0); // Anchors precisely at the joint rotation pivot
      c.rig.leftArm.add(lShoulder);
      
      c.rig.leftArm.position.set(0, -15, 26); // Shift left on Y, up on Z
      c.rig.bodyPivot.add(c.rig.leftArm);

      const rArmMesh = new THREE.Mesh(armGeo, armMat);
      rArmMesh.rotation.x = Math.PI / 2;
      rArmMesh.position.set(0, 0, -8);
      c.rig.rightArm.add(rArmMesh);
      
      const rHand = new THREE.Mesh(handGeo, skinMat);
      rHand.position.set(0, 0, -17);
      c.rig.rightArm.add(rHand);
      
      const rShoulder = new THREE.Mesh(shoulderGeo, armMat);
      rShoulder.position.set(0, 0, 0);
      c.rig.rightArm.add(rShoulder);
      
      c.rig.rightArm.position.set(0, 15, 26); // Shift right on Y
      c.rig.bodyPivot.add(c.rig.rightArm);

      // Build Legs
      const legGeo = new THREE.CylinderGeometry(6, 5, 16, 10);
      const lLegMesh = new THREE.Mesh(legGeo, pantsMat);
      lLegMesh.rotation.x = Math.PI / 2;
      lLegMesh.position.set(0, 0, -8);
      
      const shoeGeo = new THREE.BoxGeometry(10, 6, 8);
      const lShoe = new THREE.Mesh(shoeGeo, shoeMat);
      lShoe.position.set(3, 0, -16); // Toes point forward (+X)
      c.rig.leftLeg.add(lLegMesh);
      c.rig.leftLeg.add(lShoe);
      c.rig.leftLeg.position.set(0, -7, 16); // Hips
      c.rig.bodyPivot.add(c.rig.leftLeg);

      const rLegMesh = new THREE.Mesh(legGeo, pantsMat);
      rLegMesh.rotation.x = Math.PI / 2;
      rLegMesh.position.set(0, 0, -8);
      
      const rShoe = new THREE.Mesh(shoeGeo, shoeMat);
      rShoe.position.set(3, 0, -16);
      c.rig.rightLeg.add(rLegMesh);
      c.rig.rightLeg.add(rShoe);
      c.rig.rightLeg.position.set(0, 7, 16);
      c.rig.bodyPivot.add(c.rig.rightLeg);
      
      // Apply Master Scale and Base Elevation
      c.meshGroup.scale.set(maxScale, maxScale, maxScale);
      c.rig.bodyPivot.position.set(0, 0, 5); // Lift entire rig off the ground map

      // Shadow Mesh
      const shadowSize = 28; // Scale is handled by meshGroup now
      const shadowGeo = new THREE.PlaneGeometry(shadowSize, shadowSize);
      const shadowCanvas = document.createElement('canvas');
      shadowCanvas.width = 30; shadowCanvas.height = 30;
      const sctx = shadowCanvas.getContext('2d');
      sctx.fillStyle = 'rgba(0, 0, 0, 0.25)';
      sctx.beginPath();
      sctx.arc(15, 15, 14, 0, Math.PI*2);
      sctx.fill();
      const shadowTex = new THREE.CanvasTexture(shadowCanvas);
      const shadowMat = new THREE.MeshBasicMaterial({ map: shadowTex, transparent: true, depthWrite: false });
      c.shadowMesh = new THREE.Mesh(shadowGeo, shadowMat);
      c.shadowMesh.position.set(0, 0, 1); // Ground flush
      c.meshGroup.add(c.shadowMesh);
    }
    
    if (c.name && !c.hide_nameplate && !c.nameElement) {
        c.nameElement = document.createElement('div');
        c.nameElement.textContent = c.name;
        c.nameElement.style.position = 'absolute';
        c.nameElement.style.color = 'white';
        c.nameElement.style.fontWeight = 'bold';
        c.nameElement.style.fontSize = '12px';
        c.nameElement.style.fontFamily = '"Segoe UI", Tahoma, Geneva, Verdana, sans-serif';
        c.nameElement.style.textShadow = '-1px -1px 0 rgba(0,0,0,0.8), 1px -1px 0 rgba(0,0,0,0.8), -1px 1px 0 rgba(0,0,0,0.8), 1px 1px 0 rgba(0,0,0,0.8)';
        c.nameElement.style.transform = 'translate(-50%, -50%)';
        c.nameElement.style.pointerEvents = 'none';
        c.nameElement.style.zIndex = '50';
        document.body.appendChild(c.nameElement);
    }

    if (!c.chatElement) {
        c.chatElement = document.createElement('div');
        c.chatElement.style.position = 'absolute';
        c.chatElement.style.background = 'white';
        c.chatElement.style.color = '#2c3e50';
        c.chatElement.style.padding = '6px 10px';
        c.chatElement.style.borderRadius = '8px';
        c.chatElement.style.fontWeight = 'normal';
        c.chatElement.style.fontSize = '14px';
        c.chatElement.style.fontFamily = '"Segoe UI", Tahoma, Geneva, Verdana, sans-serif';
        c.chatElement.style.boxShadow = '0 3px 6px rgba(0,0,0,0.25)';
        c.chatElement.style.transform = 'translate(-50%, -100%)';
        c.chatElement.style.pointerEvents = 'none';
        c.chatElement.style.zIndex = '51';
        c.chatElement.style.display = 'none';
        c.chatElement.style.textAlign = 'center';
        c.chatElement.style.minWidth = '50px';
        
        // Tooltip arrow
        const arrow = document.createElement('div');
        arrow.style.position = 'absolute';
        arrow.style.bottom = '-8px';
        arrow.style.left = '50%';
        arrow.style.transform = 'translateX(-50%)';
        arrow.style.borderWidth = '8px 6px 0 6px';
        arrow.style.borderStyle = 'solid';
        arrow.style.borderColor = 'white transparent transparent transparent';
        c.chatElement.appendChild(arrow);
        
        c.chatTextNode = document.createElement('span');
        c.chatElement.appendChild(c.chatTextNode);
        
        document.body.appendChild(c.chatElement);
    }
  }

  updateCharacter3D(c, isNpc, player, syncPlayerToJSON) {
    if (!c.rig) return;

    // Apply entire body rotation on the Z-axis (Top-Down perspective)
    // WebGL Z-rotation is counter-clockwise, HTML5 Canvas is clockwise. We must invert the angle!
    c.rig.bodyPivot.rotation.z = -c.rotation * (Math.PI / 180);

    // Emote Handling
    const isActualNpc = isNpc;
    if (isActualNpc && !c.emote && c.default_emote) {
      c.emote = JSON.parse(JSON.stringify(c.default_emote));
    }

    let currentEmote = c.emote;
    let emoteDef = null;
    
    if (currentEmote && emotes[currentEmote.name]) {
      emoteDef = emotes[currentEmote.name];
      if (currentEmote.startTime !== 0 && Date.now() - currentEmote.startTime > emoteDef.duration) {
        if (c.activeEmoteAudio) {
          c.activeEmoteAudio.fadeOut(500);
          c.activeEmoteAudio = null;
        }
        if (isActualNpc && c.default_emote) {
          c.emote = JSON.parse(JSON.stringify(c.default_emote));
        } else {
          c.emote = null;
          if (c === player && syncPlayerToJSON) syncPlayerToJSON();
        }
      }
    }

    // Walking Animation (Limb Oscillation)
    const legSwing = Math.sin(c.legAnimationTime || 0);
    const strideAngle = 0.6; // ~35 degrees

    // Reset default idle pose (A-Pose to make hands visible from top-down orthographic camera)
    const restPitch = -0.3; // Swing forward slightly (+X axis)
    const restRoll = 0.4;   // Splay outward laterally (-/+ Y axis)
    
    // Invert the signs so the rotation pushes them outwards geometrically
    c.rig.leftArm.rotation.set(-restRoll, restPitch, 0);
    c.rig.rightArm.rotation.set(restRoll, restPitch, 0);
    c.rig.leftLeg.rotation.set(0, 0, 0);
    c.rig.rightLeg.rotation.set(0, 0, 0);

    // If moving, oscillate limbs opposite to each other.
    if ((c.legAnimationTime || 0) > 0) {
       // Y axis pivots the limbs longitudinally (forward/backward stride)
       c.rig.leftArm.rotation.y = restPitch - legSwing * strideAngle;
       c.rig.rightArm.rotation.y = restPitch + legSwing * strideAngle;
       c.rig.leftLeg.rotation.y = legSwing * strideAngle;
       c.rig.rightLeg.rotation.y = -legSwing * strideAngle;
    }

    // Emote overrides for 3D skeleton
    if (emoteDef && emoteDef.updateLimbs3D) {
       emoteDef.updateLimbs3D(c.rig, currentEmote);
    } else if (c.emoji) {
       // Basic cheer pose fallback for string emojis
       c.rig.leftArm.rotation.y = -2.0; // Raise arms forward
       c.rig.rightArm.rotation.y = -2.0;
       c.rig.leftArm.rotation.x = -0.5; // Splay slightly outwards laterally
       c.rig.rightArm.rotation.x = 0.5; 
    }
  }

  drawCharacter(c, isNpc, layerType, scene, player, syncPlayerToJSON, cameraZoom, viewportWidth, viewportHeight, threeCamera) {
    if (layerType === 'all' || layerType === 'base') {
      this.ensureThreeSetup(c, scene);
      
      // Update position (WebGL Y is UP, so we negate game Y)
      c.meshGroup.position.set(c.x, -c.y, 0);

      const hasMovement = c.legAnimationTime && c.legAnimationTime > 0;
      let isEmoteAnimating = false;
      if (c.emote && emotes[c.emote.name] && c.emote.startTime > 0) {
        const age = Date.now() - c.emote.startTime;
        if (age <= emotes[c.emote.name].duration) {
           isEmoteAnimating = true;
        }
      }

      const isRedrawForced = isEmoteAnimating || hasMovement || c._lastRenderedEmote !== JSON.stringify(c.emote) || c._lastRenderedRot !== c.rotation || !c._hasInitialRender;
      
      if (isRedrawForced) {
         this.updateCharacter3D(c, isNpc, player, syncPlayerToJSON);
         c._lastRenderedEmote = JSON.stringify(c.emote);
         c._lastRenderedRot = c.rotation;
         c._hasInitialRender = true;
      }
    }

    if (layerType === 'all' || layerType === 'overlay' || layerType === 'chat') {
      if (c.meshGroup) {
         const vec = new THREE.Vector3(c.x, -c.y, 0);
         vec.project(threeCamera);
         // Map -1 to 1 to exact screen pixels
         const screenX = (vec.x * 0.5 + 0.5) * viewportWidth;
         const screenY = (-(vec.y * 0.5) + 0.5) * viewportHeight;

         if (c.nameElement) {
             c.nameElement.style.left = `${screenX}px`;
             // Raise nameplate above head
             const nameOffsetY = 45 * cameraZoom;
             c.nameElement.style.top = `${screenY - nameOffsetY}px`;
         }

         if (c.chatElement) {
             if (c.chatMessage && Date.now() - (c.chatTime || 0) < 5000) {
                 this.currentFrameChatCount++;
                 if (this.currentFrameChatCount <= 3) {
                     c.chatElement.style.display = 'block';
                     if (c.chatTextNode.innerText !== c.chatMessage) {
                        c.chatTextNode.innerText = c.chatMessage;
                     }
                     c.chatElement.style.left = `${screenX}px`;
                     const chatOffsetY = 55 * cameraZoom;
                     c.chatElement.style.top = `${screenY - chatOffsetY}px`;
                 } else {
                     c.chatElement.style.display = 'none';
                 }
             } else {
                 c.chatElement.style.display = 'none';
             }
         }
      }
    }
  }

  drawCharacters(layerType = 'all', scene, player, syncPlayerToJSON, cameraX, cameraY, cameraZoom, viewportWidth, viewportHeight, threeCamera) {
    this.currentFrameChatCount = 0;
    const viewHalfW = ((viewportWidth / cameraZoom) / 2);
    const viewHalfH = ((viewportHeight / cameraZoom) / 2);

    const margin = 100;
    const minX = (cameraX - viewHalfW - margin);
    const maxX = (cameraX + viewHalfW + margin);
    const minY = (cameraY - viewHalfH - margin);
    const maxY = (cameraY + viewHalfH + margin);

    const processDraw = (char, isNpc) => {
      const c = (char.id === player.id) ? player : char;
      const isVisible = (c.x >= minX && c.x <= maxX && c.y >= minY && c.y <= maxY);

      if (isVisible) {
        if (c.meshGroup) c.meshGroup.visible = true;
        if (c.nameElement) c.nameElement.style.display = 'block';
        this.drawCharacter(c, isNpc, layerType, scene, player, syncPlayerToJSON, cameraZoom, viewportWidth, viewportHeight, threeCamera);
      } else {
        // Hide immediately to save DOM and GPU
        if (c.meshGroup) c.meshGroup.visible = false;
        if (c.nameElement) c.nameElement.style.display = 'none';
        if (c.chatElement) c.chatElement.style.display = 'none';
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

    if (npc.roam_radius !== undefined && typeof npc.roam_radius === 'number') {
      if (npc.waitTimer === undefined) {
        npc._startX = npc.x !== undefined ? npc.x : 0;
        npc._startY = npc.y !== undefined ? npc.y : 0;
        npc._startRotation = npc.rotation || 0;
        npc.waitTimer = 1.0 + Math.random() * 3.0;
      }

      if (npc.waitTimer > 0) {
        npc.waitTimer -= dt;
      }

      if (npc.waitTimer <= 0) {
        if (npc._pendingRoamX !== undefined) {
          npc.targetX = npc._pendingRoamX;
          npc.targetY = npc._pendingRoamY;
          delete npc._pendingRoamX;
          delete npc._pendingRoamY;
          npc.waitTimer = 2.0 + (Math.random() * 3.0);
        } else {
          const angle = Math.random() * Math.PI * 2;
          const distance = Math.random() * npc.roam_radius;
          const destX = npc._startX + (Math.cos(angle) * distance);
          const destY = npc._startY + (Math.sin(angle) * distance);
          const dx = destX - npc.x;
          const dy = destY - npc.y;
          let destRotation = Math.atan2(dy, dx) * (180 / Math.PI);
          destRotation = (destRotation + 360) % 360;

          npc.targetRotation = Math.round(destRotation);
          npc._pendingRoamX = destX;
          npc._pendingRoamY = destY;
          npc.waitTimer = 0.5;
        }
      }
    } else if (npc.waypoints && Array.isArray(npc.waypoints) && npc.waypoints.length > 0) {
      if (npc.waitTimer === undefined) {
        npc._startX = npc.x !== undefined ? npc.x : 0;
        npc._startY = npc.y !== undefined ? npc.y : 0;
        npc._startRotation = npc.rotation || 0;
        npc._moveIdx = 0;
        npc.waitTimer = 0;
      }

      if (npc.waitTimer > 0) {
        npc.waitTimer -= dt;
      }

      if (npc.waitTimer <= 0) {
        npc._moveIdx = (npc._moveIdx + 1) % (npc.waypoints.length + 2);
        npc._currentOffsetX = npc._currentOffsetX || 0;
        npc._currentOffsetY = npc._currentOffsetY || 0;
        npc._currentOffsetRotation = npc._currentOffsetRotation || 0;

        let offset = { x: 0, y: 0, rotation: 0 };
        let nodeWaitTime = npc.move_time || 3000;

        if (npc._moveIdx > 0 && npc._moveIdx <= npc.waypoints.length) {
          offset = npc.waypoints[npc._moveIdx - 1];
          if (offset.move_time !== undefined) nodeWaitTime = offset.move_time;
        } else if (npc._moveIdx === npc.waypoints.length + 1) {
          offset = { x: -npc._currentOffsetX, y: -npc._currentOffsetY };
        } else if (npc._moveIdx === 0) {
          offset = { rotation: -npc._currentOffsetRotation };
        }

        if (offset.x !== undefined) npc._currentOffsetX += offset.x;
        if (offset.y !== undefined) npc._currentOffsetY += offset.y;
        if (offset.rotation !== undefined) npc._currentOffsetRotation += offset.rotation;

        if (npc._moveIdx === 0) {
          npc._currentOffsetX = 0;
          npc._currentOffsetY = 0;
          npc._currentOffsetRotation = 0;
        }

        npc.targetX = npc._startX + npc._currentOffsetX;
        npc.targetY = npc._startY + npc._currentOffsetY;
        npc.targetRotation = npc._startRotation + npc._currentOffsetRotation;

        npc.waitTimer = nodeWaitTime / 1000;
      }
    }
  }
}
