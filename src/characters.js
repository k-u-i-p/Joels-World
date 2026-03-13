import { emotes } from './emotes.js';

const DEG_TO_RAD = Math.PI / 180;
const PI2 = Math.PI * 2;
const PI_HALF = Math.PI / 2;
const PI_ONE_HALF = Math.PI * 1.5;

export class CharacterManager {
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
      leftLegEndX: 8, leftLegEndY: -6,
      rightLegStartX: -2, rightLegStartY: 6,
      rightLegEndX: 8, rightLegEndY: 6
    };

    const drawLine = (ctxObj, sx, sy, ex, ey) => {
      ctxObj.beginPath();
      ctxObj.moveTo(sx, sy);
      ctxObj.lineTo(ex, ey);
      ctxObj.stroke();
    };

    octx.lineWidth = 7;
    octx.lineCap = 'round';
    octx.strokeStyle = c.pantsColor || '#2c3e50';

    drawLine(octx, limbs.leftLegStartX, limbs.leftLegStartY, limbs.leftLegEndX, limbs.leftLegEndY);
    drawLine(octx, limbs.rightLegStartX, limbs.rightLegStartY, limbs.rightLegEndX, limbs.rightLegEndY);

    octx.lineWidth = 5;
    octx.strokeStyle = c.armColor || '#3498db';

    drawLine(octx, 0, -11, limbs.leftArmX, limbs.leftArmY);
    drawLine(octx, 0, 11, limbs.rightArmX, limbs.rightArmY);

    octx.fillStyle = '#f1c27d';
    octx.beginPath();
    octx.arc(limbs.leftArmX, limbs.leftArmY, 3, 0, PI2);
    octx.fill();

    octx.beginPath();
    octx.arc(limbs.rightArmX, limbs.rightArmY, 3, 0, PI2);
    octx.fill();

    octx.fillStyle = c.shirtColor || '#3498db';
    if (octx.roundRect) {
      octx.beginPath();
      octx.roundRect(-8, -12, 16, 24, 6);
      octx.fill();
    } else {
      octx.fillRect(-8, -12, 16, 24);
    }

    octx.beginPath();
    octx.arc(2, 0, 8, 0, PI2);
    octx.fillStyle = '#f1c27d';
    octx.fill();

    if (c.gender === 'female') {
      octx.fillStyle = '#e67e22';
      octx.beginPath();
      octx.arc(1, 0, 7, PI_HALF, PI_ONE_HALF, true);
      octx.fill();
    }

    octx.lineWidth = 2;
    octx.strokeStyle = 'rgba(0,0,0,0.4)';
    octx.stroke();

    c.prerenderedScaleX = scaleX;
    c.prerenderedScaleY = scaleY;
    c.prerenderedCanvas = canvas;
    return canvas;
  }

  /**
   * Master rendering component for an individual character.
   * @param {Object} c - The character data including positions, colors, and roles.
   */
  drawCharacter(c, isNpc, layerType, ctx, player, syncPlayerToJSON) {
    if (layerType === 'all' || layerType === 'base') {
      ctx.save();
      ctx.translate(c.x, c.y);
      ctx.rotate(c.rotation * DEG_TO_RAD);

      const baseScale = window.init?.mapData?.character_scale || 1;
      const widthScale = (c.width || 40) / 40;
      const heightScale = (c.height || 40) / 40;
      const scaleX = baseScale * widthScale;
      const scaleY = baseScale * heightScale;
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
          const legStride = 15;
          const armStride = 8;

          let limbs = {
            leftArmX: 4 - legSwing * armStride,
            leftArmY: -14,
            rightArmX: 4 + legSwing * armStride,
            rightArmY: 14,
            leftLegStartX: -2,
            leftLegStartY: -6,
            leftLegEndX: -2 + 10 + legSwing * legStride,
            leftLegEndY: -6,
            rightLegStartX: -2,
            rightLegStartY: 6,
            rightLegEndX: -2 + 10 - legSwing * legStride,
            rightLegEndY: 6
          };

          if (emoteDef && emoteDef.updateLimbs) {
            emoteDef.updateLimbs(limbs, currentEmote);
          }

          const drawLine = (ctxObj, sx, sy, ex, ey) => {
            ctxObj.beginPath();
            ctxObj.moveTo(sx, sy);
            ctxObj.lineTo(ex, ey);
            ctxObj.stroke();
          };

          ctx.lineWidth = 7;
          ctx.lineCap = 'round';
          ctx.strokeStyle = c.pantsColor || '#2c3e50';

          drawLine(ctx, limbs.leftLegStartX, limbs.leftLegStartY, limbs.leftLegEndX, limbs.leftLegEndY);
          drawLine(ctx, limbs.rightLegStartX, limbs.rightLegStartY, limbs.rightLegEndX, limbs.rightLegEndY);

          ctx.lineWidth = 5;
          ctx.strokeStyle = c.armColor || '#3498db';

          drawLine(ctx, 0, -11, limbs.leftArmX, limbs.leftArmY);
          drawLine(ctx, 0, 11, limbs.rightArmX, limbs.rightArmY);

          ctx.beginPath();
          ctx.arc(limbs.leftArmX, limbs.leftArmY, 3, 0, PI2);
          ctx.fill();

          ctx.beginPath();
          ctx.arc(limbs.rightArmX, limbs.rightArmY, 3, 0, PI2);
          ctx.fill();

          ctx.fillStyle = c.shirtColor || '#3498db';
          if (ctx.roundRect) {
            ctx.beginPath();
            ctx.roundRect(-8, -12, 16, 24, 6);
            ctx.fill();
          } else {
            ctx.fillRect(-8, -12, 16, 24);
          }

          ctx.beginPath();
          ctx.arc(2, 0, 8, 0, PI2);
          ctx.fillStyle = '#f1c27d'; // Skin tone
          ctx.fill();

          if (c.gender === 'female') {
            ctx.fillStyle = '#e67e22'; // Default hair color example
            ctx.beginPath();
            ctx.arc(1, 0, 7, PI_HALF, PI_ONE_HALF, true);
            ctx.fill();
          }

          ctx.lineWidth = 2;
          ctx.strokeStyle = 'rgba(0,0,0,0.4)';
          ctx.stroke();

          if (emoteDef && emoteDef.draw) {
            emoteDef.draw(ctx, currentEmote);
          }
        }
      }

      ctx.restore();
    }

    if (layerType === 'all' || layerType === 'overlay') {
      if (c.name) {
        const prevFillStyle = ctx.fillStyle;
        const prevFont = ctx.font;
        const prevTextAlign = ctx.textAlign;
        const prevShadowColor = ctx.shadowColor;
        const prevShadowBlur = ctx.shadowBlur;
        const prevShadowOffsetX = ctx.shadowOffsetX;
        const prevShadowOffsetY = ctx.shadowOffsetY;

        ctx.fillStyle = 'rgba(255, 255, 255, 0.9)';
        ctx.font = 'bold 12px "Segoe UI", Tahoma, Geneva, Verdana, sans-serif';
        ctx.textAlign = 'center';

        ctx.shadowColor = 'rgba(0, 0, 0, 0.8)';
        ctx.shadowBlur = 3;
        ctx.shadowOffsetX = 1;
        ctx.shadowOffsetY = 1;

        const baseScale = window.init?.mapData?.character_scale || 1;
        const nameYOffset = ((c.height || 40) / 2) * baseScale + 15;

        // draw raw instead of translating matrix
        ctx.fillText(c.name, c.x, c.y + nameYOffset);

        ctx.fillStyle = prevFillStyle;
        ctx.font = prevFont;
        ctx.textAlign = prevTextAlign;
        ctx.shadowColor = prevShadowColor;
        ctx.shadowBlur = prevShadowBlur;
        ctx.shadowOffsetX = prevShadowOffsetX;
        ctx.shadowOffsetY = prevShadowOffsetY;
      }

      if (c.chatMessage && Date.now() - (c.chatTime || 0) < 5000) {
        const prevFillStyle = ctx.fillStyle;
        const prevFont = ctx.font;
        const prevTextAlign = ctx.textAlign;
        const prevTextBaseline = ctx.textBaseline;
        const prevShadowColor = ctx.shadowColor;
        const prevShadowBlur = ctx.shadowBlur;
        const prevShadowOffsetY = ctx.shadowOffsetY;

        ctx.font = '14px "Segoe UI", Tahoma, Geneva, Verdana, sans-serif';
        const textWidth = ctx.measureText(c.chatMessage).width;
        const bubbleWidth = textWidth + 24;
        const bubbleHeight = 32;
        const baseScale = window.init?.mapData?.character_scale || 1;

        // compute offset coordinates physically
        const bX = c.x - bubbleWidth / 2;
        const bY = c.y - (((c.height || 40) / 2) * baseScale + 10) - bubbleHeight;

        ctx.shadowColor = 'rgba(0, 0, 0, 0.25)';
        ctx.shadowBlur = 6;
        ctx.shadowOffsetY = 3;

        ctx.fillStyle = '#ffffff';
        ctx.beginPath();
        if (ctx.roundRect) {
          ctx.roundRect(bX, bY, bubbleWidth, bubbleHeight, 8);
        } else {
          ctx.rect(bX, bY, bubbleWidth, bubbleHeight);
        }
        ctx.fill();

        ctx.beginPath();
        // The little arrow tooltip at bottom middle
        const arrowCenterX = c.x;
        const arrowTopY = bY + bubbleHeight;
        ctx.moveTo(arrowCenterX - 6, arrowTopY);
        ctx.lineTo(arrowCenterX + 6, arrowTopY);
        ctx.lineTo(arrowCenterX, arrowTopY + 8);
        ctx.fill();

        ctx.shadowColor = 'transparent';
        ctx.shadowBlur = 0;
        ctx.shadowOffsetY = 0;

        ctx.fillStyle = '#2c3e50';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.fillText(c.chatMessage, c.x, bY + bubbleHeight / 2);

        ctx.fillStyle = prevFillStyle;
        ctx.font = prevFont;
        ctx.textAlign = prevTextAlign;
        ctx.textBaseline = prevTextBaseline;
        ctx.shadowColor = prevShadowColor;
        ctx.shadowBlur = prevShadowBlur;
        ctx.shadowOffsetY = prevShadowOffsetY;
      }
    }
  }

  /**
   * Iterates through all players and NPCs and renders the ones currently visible
   * within the camera bounds.
   */
  drawCharacters(layerType = 'all', ctx, canvas, player, syncPlayerToJSON, cameraX, cameraY, cameraZoom) {
    const viewHalfW = (canvas.width / cameraZoom) / 2;
    const viewHalfH = (canvas.height / cameraZoom) / 2;

    const margin = 100;
    const minX = cameraX - viewHalfW - margin;
    const maxX = cameraX + viewHalfW + margin;
    const minY = cameraY - viewHalfH - margin;
    const maxY = cameraY + viewHalfH + margin;

    const processDraw = (char, isNpc) => {
      const c = (char.id === player.id) ? player : char;

      if (c.x >= minX && c.x <= maxX && c.y >= minY && c.y <= maxY) {
        this.drawCharacter(c, isNpc, layerType, ctx, player, syncPlayerToJSON);
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
