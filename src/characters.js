import { emotes } from './emotes.js';

const DEG_TO_RAD = Math.PI / 180;
const PI2 = Math.PI * 2;
const PI_HALF = Math.PI / 2;
const PI_ONE_HALF = Math.PI * 1.5;

function shadeColor(color, percent) {
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

  return "#" + RR + GG + BB;
}

export class CharacterManager {
  /**
   * Helper method to stroke a path line between two coordinates.
   */
  drawLine(ctxObj, sx, sy, ex, ey) {
    ctxObj.beginPath();
    ctxObj.moveTo(sx, sy);
    ctxObj.lineTo(ex, ey);
    ctxObj.stroke();
  }

  /**
   * Helper method rendering hyper-realistic 3D shoes with lighting gradients.
   */
  drawShoe(ctxObj, x, y, color, isLeft) {
    const dirY = isLeft ? -1 : 1; // Used to mirror asymmetry

    // 1. Draw distinct Sole (Offset slightly down and back)
    ctxObj.fillStyle = '#7f8c8d'; // Dark grey sole
    ctxObj.beginPath();
    ctxObj.moveTo(x - 2, y - 3.5);
    ctxObj.lineTo(x + 5.5, y - 3.5);
    // Asymmetric toe point
    ctxObj.bezierCurveTo(x + 10, y - 3.5 * dirY, x + 10, y + 3.5, x + 5.5, y + 3.5);
    ctxObj.lineTo(x - 2, y + 3.5);
    ctxObj.quadraticCurveTo(x - 3.5, y + 3.5, x - 3.5, y - 3.5, x - 2, y - 3.5);
    ctxObj.fill();

    // 2. Draw Main Shoe Body (Scaled slightly smaller to leave the sole visible)
    // Main 3D spherical gradient
    const bodyGrad = ctxObj.createRadialGradient(x + 2, y - 1 * dirY, 0.5, x + 3, y, 6);
    bodyGrad.addColorStop(0, shadeColor(color, 40));
    bodyGrad.addColorStop(0.5, color);
    bodyGrad.addColorStop(1, shadeColor(color, -40));
    
    ctxObj.fillStyle = bodyGrad;
    ctxObj.beginPath();
    // Body path (slightly inset from sole)
    ctxObj.moveTo(x - 1.5, y - 3);
    ctxObj.lineTo(x + 4.5, y - 3);
    ctxObj.bezierCurveTo(x + 9, y - 3 * dirY, x + 9, y + 3, x + 4.5, y + 3);
    ctxObj.lineTo(x - 1.5, y + 3);
    ctxObj.quadraticCurveTo(x - 2.5, y + 3, x - 2.5, y - 3, x - 1.5, y - 3);
    ctxObj.fill();

    // 3. Draw Contrasting Toe Cap
    ctxObj.fillStyle = '#34495e'; // Dark slate grey toe
    ctxObj.beginPath();
    ctxObj.moveTo(x + 5, y - 2.5);
    ctxObj.bezierCurveTo(x + 9, y - 2.5 * dirY, x + 9, y + 2.5, x + 5, y + 2.5);
    ctxObj.quadraticCurveTo(x + 3.5, y, x + 5, y - 2.5);
    ctxObj.fill();

    // 4. Draw Tongue
    ctxObj.fillStyle = shadeColor(color, -20); // Darker shade of main color
    ctxObj.beginPath();
    ctxObj.moveTo(x - 1, y - 2);
    ctxObj.lineTo(x + 3, y - 2.5); // Slopes up/forward
    ctxObj.lineTo(x + 3, y + 2.5);
    ctxObj.lineTo(x - 1, y + 2);
    ctxObj.fill();

    // 5. Draw Laces (Crossing over the tongue)
    ctxObj.lineWidth = 1;
    ctxObj.strokeStyle = 'rgba(255,255,255,0.4)';
    ctxObj.beginPath();
    // X pattern 1
    ctxObj.moveTo(x + 0.5, y - 2); ctxObj.lineTo(x + 2, y + 2);
    ctxObj.moveTo(x + 2, y - 2); ctxObj.lineTo(x + 0.5, y + 2);
    // X pattern 2 (further forward)
    ctxObj.moveTo(x + 1.5, y - 2); ctxObj.lineTo(x + 3, y + 2);
    ctxObj.moveTo(x + 3, y - 2); ctxObj.lineTo(x + 1.5, y + 2);
    ctxObj.stroke();

    // 6. Specular Highlight (Rim lighting on top edge)
    ctxObj.lineWidth = 0.5;
    ctxObj.strokeStyle = 'rgba(255,255,255,0.3)';
    ctxObj.beginPath();
    ctxObj.moveTo(x - 1, y - 2.5);
    ctxObj.quadraticCurveTo(x + 3, y - 2.5 * dirY, x + 4.5, y - 2.5);
    ctxObj.stroke();
  }

  /**
   * Helper method rendering the shared visual anatomy of a human character based on limb positions.
   * @param {CanvasRenderingContext2D} ctx - The canvas graphics context.
   * @param {Object} c - The character data including colors and gender.
   * @param {Object} limbs - Pre-calculated limb position coordinates.
   */
  drawHumanoid(ctx, c, limbs) {
    if (!c.emote || (c.emote.name !== 'sit' && c.emote.name !== 'lunch' && c.emote.name !== 'write')) {
      const shoeColor = c.shoeColor || '#1a252f';
      this.drawShoe(ctx, limbs.leftLegEndX, limbs.leftLegEndY, shoeColor, true);
      this.drawShoe(ctx, limbs.rightLegEndX, limbs.rightLegEndY, shoeColor, false);
    }


    const armOffset = 11; // Restore normal wide shoulder anchors

    // Gradient for arms (cylindrical simulation)
    const armGradient = ctx.createLinearGradient(0, -armOffset, 0, limbs.leftArmY);
    armGradient.addColorStop(0, c.armColor || '#3498db');
    armGradient.addColorStop(1, shadeColor(c.armColor || '#3498db', -30));

    ctx.lineWidth = 5;
    ctx.strokeStyle = armGradient;

    this.drawLine(ctx, 0, -armOffset, limbs.leftArmX, limbs.leftArmY);

    const rightArmGradient = ctx.createLinearGradient(0, armOffset, 0, limbs.rightArmY);
    rightArmGradient.addColorStop(0, c.armColor || '#3498db');
    rightArmGradient.addColorStop(1, shadeColor(c.armColor || '#3498db', -30));
    ctx.strokeStyle = rightArmGradient;
    this.drawLine(ctx, 0, armOffset, limbs.rightArmX, limbs.rightArmY);

    const leftHandGrad = ctx.createRadialGradient(limbs.leftArmX, limbs.leftArmY - 1, 0.5, limbs.leftArmX, limbs.leftArmY, 3);
    leftHandGrad.addColorStop(0, '#f5d39e');
    leftHandGrad.addColorStop(0.6, '#e0ab63');
    leftHandGrad.addColorStop(1, '#a67232');
    ctx.fillStyle = leftHandGrad;
    ctx.beginPath();
    ctx.arc(limbs.leftArmX, limbs.leftArmY, 3, 0, PI2);
    ctx.fill();

    const rightHandGrad = ctx.createRadialGradient(limbs.rightArmX, limbs.rightArmY - 1, 0.5, limbs.rightArmX, limbs.rightArmY, 3);
    rightHandGrad.addColorStop(0, '#f5d39e');
    rightHandGrad.addColorStop(0.6, '#e0ab63');
    rightHandGrad.addColorStop(1, '#a67232');
    ctx.fillStyle = rightHandGrad;
    ctx.beginPath();
    ctx.arc(limbs.rightArmX, limbs.rightArmY, 3, 0, PI2);
    ctx.fill();

    // Gradient for the body (torso cylinder)
    const bodyGradient = ctx.createLinearGradient(-8, 0, 8, 0);
    bodyGradient.addColorStop(0, c.shirtColor || '#3498db');
    bodyGradient.addColorStop(0.5, shadeColor(c.shirtColor || '#3498db', 20)); // Highlight
    bodyGradient.addColorStop(1, shadeColor(c.shirtColor || '#3498db', -40));  // Core shadow
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
    // Spherical radial gradient for the head
    const headGradient = ctx.createRadialGradient(0, -2, 2, 2, 0, 8);
    headGradient.addColorStop(0, '#f5d39e'); // Specular highlight
    headGradient.addColorStop(0.6, '#e0ab63'); // Base skin tone
    headGradient.addColorStop(1, '#a67232'); // Shadow rim
    ctx.fillStyle = headGradient;
    ctx.fill();

    // Outline the head
    ctx.lineWidth = 2;
    ctx.strokeStyle = 'rgba(0,0,0,0.4)';
    ctx.stroke();

    let hairColor = c.hairColor;
    if (!hairColor && c.gender === 'female') hairColor = '#e67e22'; // legacy fallback

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
        ctx.arc(1, 0, 7.5, PI_HALF + 0.1, PI_ONE_HALF - 0.1, false);
        ctx.lineTo(-8, -6);
        ctx.lineTo(-6, -3);
        ctx.lineTo(-9, -1);
        ctx.lineTo(-6, 2);
        ctx.lineTo(-8, 5);
        ctx.fill();
      } else { // 'long'
        ctx.arc(1, 0, 7.5, PI_HALF - 0.2, PI_ONE_HALF + 0.2, false);
        ctx.fill();
      }
    }
  }

  /**
   * Optimizes static NPC rendering by painting them onto an OffscreenCanvas once, 
   * then returning that canvas to be cheaply drawn each frame.
   * @param {Object} c - The character object data.
   * @param {number} scaleX - The character horizontal scale multiplier.
   * @param {number} scaleY - The character vertical scale multiplier.
   * @returns {HTMLCanvasElement|OffscreenCanvas} Prerendered graphics context instance.
   */
  getPrerenderedNpc(c, scaleX = 1, scaleY = 1) {
    if (c.prerenderedCanvas && c.prerenderedScaleX === scaleX && c.prerenderedScaleY === scaleY) {
      return c.prerenderedCanvas;
    }

    const baseSize = 100;
    const width = baseSize * scaleX;
    const height = baseSize * scaleY;
    const canvas = window.OffscreenCanvas ? new OffscreenCanvas(width, height) : document.createElement('canvas');
    if (!window.OffscreenCanvas) {
      canvas.width = width;
      canvas.height = height;
    }
    const octx = canvas.getContext('2d');

    octx.translate(width / 2, height / 2);
    octx.scale(scaleX, scaleY);

    const limbs = {
      leftArmX: 4, leftArmY: -14,
      rightArmX: 4, rightArmY: 14,
      leftLegStartX: -2, leftLegStartY: -6,
      leftLegEndX: 4, leftLegEndY: -6,
      rightLegStartX: -2, rightLegStartY: 6,
      rightLegEndX: 4, rightLegEndY: 6
    };

    this.drawHumanoid(octx, c, limbs);

    c.prerenderedScaleX = scaleX;
    c.prerenderedScaleY = scaleY;
    c.prerenderedCanvas = canvas;
    return canvas;
  }

  /**
   * Master rendering component for an individual character.
   * @param {Object} c - The character data including positions, colors, and roles.
   */
  drawCharacter(c, isNpc, layerType, ctx, player, syncPlayerToJSON, cameraZoom = 1) {
    if (layerType === 'all' || layerType === 'base') {
      ctx.save();
      ctx.translate(c.x, c.y);

      const baseScale = window.init?.mapData?.character_scale || 1;
      const widthScale = (c.width || 40) / 40;
      const heightScale = (c.height || 40) / 40;
      const scaleX = baseScale * widthScale;
      const scaleY = baseScale * heightScale;

      // Draw shadow before rotation so it stays aligned with the world lighting
      ctx.save();
      ctx.scale(scaleX, scaleY);
      ctx.fillStyle = 'rgba(0, 0, 0, 0.25)';
      ctx.beginPath();
      ctx.arc(2, 4, 14, 0, PI2); // Offset slightly bottom-right
      ctx.fill();
      ctx.restore();

      ctx.rotate(c.rotation * DEG_TO_RAD);
      ctx.scale(scaleX, scaleY);

      if (c.emoji) {
        ctx.font = '60px sans-serif';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.rotate(-c.rotation * DEG_TO_RAD); // keep it upright

        let currentEmote = c.emote;
        let emoteDef = null;
        if (currentEmote && emotes[currentEmote.name]) {
          emoteDef = emotes[currentEmote.name];
          if (emoteDef.setup) {
            emoteDef.setup(ctx, currentEmote, c);
          }
        }

        ctx.fillText(c.emoji, 0, 0);
      } else {
        const isActualNpc = isNpc;
        const hasMovement = c.legAnimationTime && c.legAnimationTime > 0;

        if (isActualNpc && !hasMovement && !c.emote) {
          const prCnv = this.getPrerenderedNpc(c, scaleX, scaleY);
          ctx.save();
          ctx.scale(1 / scaleX, 1 / scaleY);
          ctx.drawImage(prCnv, -prCnv.width / 2, -prCnv.height / 2);
          ctx.restore();
        } else {
          let currentEmote = c.emote;
          let emoteDef = null;
          if (currentEmote && emotes[currentEmote.name]) {
            emoteDef = emotes[currentEmote.name];
            if (currentEmote.startTime !== 0 && Date.now() - currentEmote.startTime > emoteDef.duration) {
              c.emote = null;
              currentEmote = null;
              if (c === player && syncPlayerToJSON) syncPlayerToJSON();
              emoteDef = null;
            } else if (emoteDef.setup) {
              emoteDef.setup(ctx, currentEmote, c);
            }
          }

          const legSwing = Math.sin(c.legAnimationTime || 0);
          const legStride = 9;
          const armStride = 8;

          let limbs = {
            leftArmX: 4 - legSwing * armStride,
            leftArmY: -14,
            rightArmX: 4 + legSwing * armStride,
            rightArmY: 14,
            leftLegStartX: -2,
            leftLegStartY: -6,
            leftLegEndX: -2 + 6 + legSwing * legStride,
            leftLegEndY: -6,
            rightLegStartX: -2,
            rightLegStartY: 6,
            rightLegEndX: -2 + 6 - legSwing * legStride,
            rightLegEndY: 6
          };

          if (emoteDef && emoteDef.updateLimbs) {
            emoteDef.updateLimbs(limbs, currentEmote);
          }

          this.drawHumanoid(ctx, c, limbs);

          if (emoteDef && emoteDef.draw) {
            emoteDef.draw(ctx, currentEmote);
          }
        }
      }

      ctx.restore();
    }

    if (layerType === 'all' || layerType === 'overlay') {
      if (layerType === 'overlay' && c.name && !c.hideName) {
        ctx.save();
        ctx.translate(c.x, c.y);
        ctx.scale(1 / cameraZoom, 1 / cameraZoom);

        ctx.fillStyle = 'rgba(255, 255, 255, 0.9)';
        ctx.font = 'bold 12px "Segoe UI", Tahoma, Geneva, Verdana, sans-serif';
        ctx.textAlign = 'center';

        ctx.shadowColor = 'rgba(0, 0, 0, 0.8)';
        ctx.shadowBlur = 3;
        ctx.shadowOffsetX = 1;
        ctx.shadowOffsetY = 1;

        const baseScale = window.init?.mapData?.character_scale || 1;
        const nameYOffsetScreen = (((c.height || 40) / 2) * baseScale) * cameraZoom + 15;

        // draw at local 0 with scaled Y offset
        ctx.fillText(c.name, 0, nameYOffsetScreen);
        
        ctx.restore();
      }

      if (c.chatMessage && Date.now() - (c.chatTime || 0) < 5000) {
        ctx.save();
        ctx.translate(c.x, c.y);
        ctx.scale(1 / cameraZoom, 1 / cameraZoom);

        ctx.font = '14px "Segoe UI", Tahoma, Geneva, Verdana, sans-serif';
        const textWidth = ctx.measureText(c.chatMessage).width;
        const bubbleWidth = textWidth + 24;
        const bubbleHeight = 32;
        const baseScale = window.init?.mapData?.character_scale || 1;

        // compute offset coordinates physically
        const bXScreen = -bubbleWidth / 2;
        const bYScreen = -((((c.height || 40) / 2) * baseScale) * cameraZoom + 10) - bubbleHeight;

        ctx.shadowColor = 'rgba(0, 0, 0, 0.25)';
        ctx.shadowBlur = 6;
        ctx.shadowOffsetY = 3;

        ctx.fillStyle = '#ffffff';
        ctx.beginPath();
        if (ctx.roundRect) {
          ctx.roundRect(bXScreen, bYScreen, bubbleWidth, bubbleHeight, 8);
        } else {
          ctx.rect(bXScreen, bYScreen, bubbleWidth, bubbleHeight);
        }
        ctx.fill();

        ctx.beginPath();
        // The little arrow tooltip at bottom middle
        const arrowTopY = bYScreen + bubbleHeight;
        ctx.moveTo(-6, arrowTopY);
        ctx.lineTo(6, arrowTopY);
        ctx.lineTo(0, arrowTopY + 8);
        ctx.fill();

        ctx.shadowColor = 'transparent';
        ctx.shadowBlur = 0;
        ctx.shadowOffsetY = 0;

        ctx.fillStyle = '#2c3e50';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.fillText(c.chatMessage, 0, bYScreen + bubbleHeight / 2);
        
        ctx.restore();
      }
    }
  }

  /**
   * Iterates through all players and NPCs and renders the ones currently visible
   * within the camera bounds.
   */
  drawCharacters(layerType = 'all', ctx, canvas, player, syncPlayerToJSON, cameraX, cameraY, cameraZoom, viewportWidth, viewportHeight) {
    const viewHalfW = ((viewportWidth / cameraZoom) / 2) | 0;
    const viewHalfH = ((viewportHeight / cameraZoom) / 2) | 0;

    const margin = 100;
    const minX = (cameraX - viewHalfW - margin) | 0;
    const maxX = (cameraX + viewHalfW + margin) | 0;
    const minY = (cameraY - viewHalfH - margin) | 0;
    const maxY = (cameraY + viewHalfH + margin) | 0;

    const processDraw = (char, isNpc) => {
      const c = (char.id === player.id) ? player : char;

      if (c.x >= minX && c.x <= maxX && c.y >= minY && c.y <= maxY) {
        this.drawCharacter(c, isNpc, layerType, ctx, player, syncPlayerToJSON, cameraZoom);
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
