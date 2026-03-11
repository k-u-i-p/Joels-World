export const emotes = {
  dance: {
    duration: 5000,
    setup: (ctx, emote, c) => {},
    updateLimbs: (limbs, emote) => {
      const danceTime = (Date.now() - emote.startTime) / 100;
      const swing = Math.sin(danceTime) * 12;
      const hipSwing = -swing * 0.4;

      limbs.leftLegStartY = -6 + hipSwing;
      limbs.leftLegEndY = -6 + hipSwing + 10;
      limbs.leftLegEndX = -2;
      limbs.rightLegStartY = 6 + hipSwing;
      limbs.rightLegEndY = 6 + hipSwing + 10;
      limbs.rightLegEndX = -2;

      limbs.leftArmX = 0; limbs.leftArmY = -14 + swing;
      limbs.rightArmX = 0; limbs.rightArmY = 14 + swing;
    },
    draw: (ctx, emote) => {}
  },
  fart: {
    duration: 2000,
    setup: (ctx, emote, c) => {},
    updateLimbs: (limbs, emote) => {},
    draw: (ctx, emote) => {
      const fartAge = Date.now() - emote.startTime;
      if (fartAge > 1000) return;
      
      ctx.save();
      ctx.globalAlpha = Math.max(0, 1 - (fartAge / 1000));
      ctx.fillStyle = '#2ecc71'; // Greenish cloud
      ctx.beginPath();
      ctx.arc(-20 - (fartAge / 50), 0, 10 + (fartAge / 30), 0, Math.PI * 2);
      ctx.fill();

      ctx.beginPath();
      ctx.arc(-15 - (fartAge / 40), 10, 6 + (fartAge / 40), 0, Math.PI * 2);
      ctx.fill();

      ctx.beginPath();
      ctx.arc(-15 - (fartAge / 40), -10, 6 + (fartAge / 40), 0, Math.PI * 2);
      ctx.fill();

      ctx.restore();
    }
  },
  dead: {
    duration: 10000,
    setup: (ctx, emote, c) => {
      ctx.globalAlpha = 0.5;
    },
    updateLimbs: (limbs, emote) => {
      limbs.leftArmX = -4; limbs.leftArmY = -22;
      limbs.rightArmX = -4; limbs.rightArmY = 22;
      limbs.leftLegStartX = -8; limbs.leftLegStartY = -4;
      limbs.leftLegEndX = -22; limbs.leftLegEndY = -10;
      limbs.rightLegStartX = -8; limbs.rightLegStartY = 4;
      limbs.rightLegEndX = -22; limbs.rightLegEndY = 10;
    },
    draw: (ctx, emote) => {
      ctx.save();
      ctx.beginPath();
      ctx.moveTo(3, -3); ctx.lineTo(7, 1);
      ctx.moveTo(7, -3); ctx.lineTo(3, 1);
      ctx.moveTo(3, -1); ctx.lineTo(7, 3);
      ctx.moveTo(7, -1); ctx.lineTo(3, 3);
      ctx.strokeStyle = 'rgba(0,0,0,0.8)';
      ctx.lineWidth = 1;
      ctx.stroke();
      ctx.restore();
    }
  },
  cry: {
    duration: 5000,
    setup: (ctx, emote, c) => {},
    updateLimbs: (limbs, emote) => {},
    draw: (ctx, emote) => {
      ctx.save();
      // Draw eyes
      ctx.fillStyle = '#111';
      ctx.beginPath(); ctx.arc(5, -1, 1, 0, Math.PI * 2); ctx.fill();
      ctx.beginPath(); ctx.arc(5, 1, 1, 0, Math.PI * 2); ctx.fill();

      // Animated tears
      const tearProgress1 = (Date.now() % 1000) / 1000;
      const tearProgress2 = ((Date.now() + 500) % 1000) / 1000;

      ctx.fillStyle = '#3498db'; // blue tear

      // Left cheek tears
      ctx.beginPath(); ctx.arc(4 - tearProgress1 * 6, -2 - tearProgress1 * 2, 1.5, 0, Math.PI * 2); ctx.fill();
      ctx.beginPath(); ctx.arc(4 - tearProgress2 * 6, -2 - tearProgress2 * 2, 1.5, 0, Math.PI * 2); ctx.fill();

      // Right cheek tears
      ctx.beginPath(); ctx.arc(4 - tearProgress1 * 6, 2 + tearProgress1 * 2, 1.5, 0, Math.PI * 2); ctx.fill();
      ctx.beginPath(); ctx.arc(4 - tearProgress2 * 6, 2 + tearProgress2 * 2, 1.5, 0, Math.PI * 2); ctx.fill();
      ctx.restore();
    }
  },
  gritty: {
    duration: 5000,
    setup: (ctx, emote, c) => {
      const danceTime = (Date.now() - emote.startTime) / 150;
      const fastSwing = Math.sin(danceTime * 2);
      ctx.translate(fastSwing * 2, -Math.abs(fastSwing * 4)); // bobbing
    },
    updateLimbs: (limbs, emote) => {
      const danceTime = (Date.now() - emote.startTime) / 150;
      const swing = Math.sin(danceTime);

      // Alternating heel taps
      if (swing > 0) {
        limbs.leftLegStartY = -6; limbs.leftLegEndY = -2; limbs.leftLegEndX = -4; 
        limbs.rightLegStartY = 6; limbs.rightLegEndY = 6 + 10; limbs.rightLegEndX = -2; 
      } else {
        limbs.leftLegStartY = -6; limbs.leftLegEndY = -6 + 10; limbs.leftLegEndX = -2; 
        limbs.rightLegStartY = 6; limbs.rightLegEndY = 2; limbs.rightLegEndX = -4; 
      }

      // Arms swinging back and forth in front
      limbs.leftArmX = 10 + swing * 8; limbs.leftArmY = -6;
      limbs.rightArmX = 10 - swing * 8; limbs.rightArmY = 6;
    },
    draw: (ctx, emote) => {}
  }
};
