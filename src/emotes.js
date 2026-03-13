export const emotes = {
  bounce: {
    duration: 3600000, // 1 hour duration
    message: "{name} is bouncing",
    setup: (ctx, emote, c) => {
      const danceTime = (Date.now() - emote.startTime) / 150;
      const bounce = Math.abs(Math.sin(danceTime)) * -15;
      const tilt = Math.sin(danceTime * 0.8) * 0.3;

      ctx.translate(0, bounce);
      ctx.rotate(tilt);
    },
    updateLimbs: (limbs, emote) => { },
    draw: (ctx, emote) => { }
  },
  wet: {
    duration: 10000,
    message: "{name} is dripping wet",
    setup: (ctx, emote, c) => {
      window.footprints = window.footprints || [];
      if (!c._lastFootprintCoords) {
        c._lastFootprintCoords = { x: c.x, y: c.y, leg: 'left' };
      }

      const dx = c.x - c._lastFootprintCoords.x;
      const dy = c.y - c._lastFootprintCoords.y;
      const distSq = dx * dx + dy * dy;

      // Drop footprint every 15 pixels of movement
      if (distSq > Math.pow(15, 2)) {
        const isLeft = c._lastFootprintCoords.leg === 'left';
        window.footprints.push({
          x: c.x,
          y: c.y,
          rot: c.rotation,
          time: Date.now(),
          isLeft
        });
        c._lastFootprintCoords = { x: c.x, y: c.y, leg: isLeft ? 'right' : 'left' };
      }

      // Render constant dripping effect on character
      const swimTime = Date.now() - emote.startTime;
      ctx.save();
      ctx.fillStyle = '#3498db';
      ctx.globalAlpha = 0.6;
      for (let i = 0; i < 3; i++) {
        const offset = i * 333;
        const progress = ((swimTime + offset) % 1000) / 1000;
        ctx.beginPath();
        const dropX = (i - 1) * 8;
        const dropY = -15 + progress * 30;
        ctx.arc(dropX, dropY, 2 * (1 - progress), 0, Math.PI * 2);
        ctx.fill();
      }
      ctx.restore();
    },
    updateLimbs: (limbs, emote) => { },
    draw: (ctx, emote) => { }
  },
  eat: {
    duration: 5000,
    message: "{name} is eating an apple",
    setup: (ctx, emote, c) => {
      const eatTime = (Date.now() - emote.startTime) / 150;
      // Head bobbing as if chewing
      const bringToMouth = Math.max(0, Math.sin(eatTime));
      if (bringToMouth > 0) {
        // Chew animation
        const chew = Math.abs(Math.sin(eatTime * 5)) * 1.5;
        // The character faces the positive 'x' direction.
        ctx.translate(chew, 0); 
      }
    },
    updateLimbs: (limbs, emote) => {
      const eatTime = (Date.now() - emote.startTime) / 150;
      // Bring arm up in a sine wave
      const bringToMouth = Math.max(0, Math.sin(eatTime));

      // Right arm holds food and brings to face
      limbs.rightArmX = 4 + bringToMouth * 3;
      limbs.rightArmY = 14 - bringToMouth * 12; // Bring towards centerline

      // Left arm stays at rest
      limbs.leftArmX = 4; limbs.leftArmY = -14;
    },
    draw: (ctx, emote) => {
      ctx.save();
      const eatTime = (Date.now() - emote.startTime) / 150;
      const bringToMouth = Math.max(0, Math.sin(eatTime));
      
      // Calculate hand coordinates (same as updateLimbs)
      const handX = 4 + bringToMouth * 3;
      const handY = 14 - bringToMouth * 12;

      ctx.translate(handX, handY);
      
      // Draw an apple
      ctx.fillStyle = '#e74c3c'; // red
      ctx.beginPath();
      ctx.arc(4, 0, 3, 0, Math.PI * 2);
      ctx.fill();
      
      // Draw leaf/stem
      ctx.strokeStyle = '#27ae60';
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(4, -3);
      ctx.lineTo(6, -5);
      ctx.stroke();
      
      ctx.restore();

      // Crumbs / apple pieces flying from face
      if (bringToMouth > 0.8) {
        ctx.save();
        ctx.fillStyle = '#e74c3c'; // red crumbs
        for (const i of [0, 1, 2]) {
          const crumbTime = ((Date.now() - emote.startTime) % (200 + i * 50)) / 250;
          ctx.globalAlpha = 1 - crumbTime;
          const dropX = 8 + crumbTime * (5 + i); // Fly forward
          const dropY = (i - 1) * 3 + crumbTime * 4; // Spread out slightly
          ctx.beginPath();
          ctx.arc(dropX, dropY, 1.5, 0, Math.PI * 2);
          ctx.fill();
        }
        ctx.restore();
      }
    }
  },
  jump: {
    duration: 800,
    message: "{name} leaps forward",
    setup: (ctx, emote, c) => {
      const age = Date.now() - emote.startTime;
      if (age < 800) {
        // Parabolic jump arc: max height at 400ms
        const progress = age / 800;
        // y = -x * (x - 1) * 4 * height
        const height = progress * (1 - progress) * 4 * 50; // 50 pixels high

        // Draw shadow on the ground before translating up
        ctx.save();
        ctx.globalAlpha = 0.3 * (1 - height / 60);
        ctx.fillStyle = '#000';
        ctx.beginPath();
        // Since ctx.ellipse might not be supported on very old browsers, we use arc + scale
        ctx.scale(1, 0.5);
        ctx.arc(0, 0, Math.max(0.1, 20 - height / 3), 0, Math.PI * 2);
        ctx.fill();
        ctx.restore();

        ctx.translate(0, -height);

        // Slight lean forward while jumping
        const tilt = Math.sin(progress * Math.PI) * 0.4;
        ctx.rotate(tilt);
      }
    },
    updateLimbs: (limbs, emote) => {
      const age = Date.now() - emote.startTime;
      if (age < 800) {
        const progress = age / 800;

        // Easing function for tucking knees (smooth instead of sharp)
        // A parabola that peaks at 0.5
        const tuck = Math.sin(progress * Math.PI);

        // Smoothly tuck knees up toward the body
        limbs.leftLegStartY = -6;
        limbs.leftLegEndY = -6 - 2 * tuck;
        limbs.leftLegEndX = -2 - 12 * tuck;

        limbs.rightLegStartY = 6;
        limbs.rightLegEndY = 6 + 2 * tuck;
        limbs.rightLegEndX = -2 - 12 * tuck;

        // Arms swing forward on jump, throw back in air, forward on land.
        // Let's make arms follow a cosine wave.
        const armSwing = Math.cos(progress * Math.PI * 2);

        limbs.leftArmX = 4 + armSwing * 10;
        limbs.leftArmY = -14 + armSwing * 4;

        limbs.rightArmX = 4 + armSwing * 10;
        limbs.rightArmY = 14 - armSwing * 4;
      }
    },
    draw: (ctx, emote) => {
      const age = Date.now() - emote.startTime;
      if (age < 800) {
        const progress = age / 800;
        // Draw little motion lines trailing behind
        ctx.save();
        ctx.globalAlpha = 0.5 * (1 - progress);
        const trailOffset = -20 * progress;
        ctx.beginPath();
        ctx.moveTo(-15 + trailOffset, -10); ctx.lineTo(-35 + trailOffset, -15);
        ctx.moveTo(-15 + trailOffset, 10); ctx.lineTo(-35 + trailOffset, 15);
        ctx.strokeStyle = '#ecf0f1';
        ctx.lineWidth = 2;
        ctx.stroke();

        // Dust clouds on takeoff and landing
        if (progress < 0.25) {
          const dustP = progress / 0.25;
          ctx.globalAlpha = Math.max(0, 1 - dustP * 1.5);
          ctx.fillStyle = '#bdc3c7';
          ctx.beginPath();
          ctx.arc(-10 - dustP * 20, 10 + dustP * 10, 4 + dustP * 4, 0, Math.PI * 2);
          ctx.arc(-10 - dustP * 20, -10 - dustP * 10, 4 + dustP * 4, 0, Math.PI * 2);
          ctx.arc(-5 - dustP * 10, 0 + dustP * 4, 5 + dustP * 6, 0, Math.PI * 2);
          ctx.fill();
        } else if (progress > 0.75) {
          const dustP = (progress - 0.75) / 0.25;
          ctx.globalAlpha = Math.max(0, 1 - dustP * 1.5);
          ctx.fillStyle = '#bdc3c7';
          ctx.beginPath();
          ctx.arc(10 + dustP * 20, 10 + dustP * 10, 5 + dustP * 5, 0, Math.PI * 2);
          ctx.arc(10 + dustP * 20, -10 - dustP * 10, 5 + dustP * 5, 0, Math.PI * 2);
          ctx.arc(5 + dustP * 10, 0 + dustP * 4, 6 + dustP * 7, 0, Math.PI * 2);
          ctx.fill();
        }
        ctx.restore();
      }
    }
  },
  dance: {
    duration: 8000,
    message: "{name} is busting a move",
    setup: (ctx, emote, c) => {
      const danceTime = (Date.now() - emote.startTime) / 150;
      const bob = Math.abs(Math.sin(danceTime * 2)) * -4; // bounce up and down
      const tilt = Math.sin(danceTime) * 0.2; // slight sway

      ctx.translate(0, bob);
      ctx.rotate(tilt);
    },
    updateLimbs: (limbs, emote) => {
      const danceTime = (Date.now() - emote.startTime) / 150;
      const armSwing = Math.sin(danceTime * 2);
      const legStep = Math.cos(danceTime * 2);

      // Arms alternating up and down disco style
      limbs.leftArmX = 8 + armSwing * 6;
      limbs.leftArmY = -14 - armSwing * 6;

      limbs.rightArmX = 8 - armSwing * 6;
      limbs.rightArmY = 14 + armSwing * 6;

      // Legs stepping out side to side
      limbs.leftLegStartX = -2; limbs.leftLegStartY = -6;
      limbs.leftLegEndX = -2 + Math.max(0, legStep * 8);
      limbs.leftLegEndY = -6 - Math.max(0, -legStep * 6);

      limbs.rightLegStartX = -2; limbs.rightLegStartY = 6;
      limbs.rightLegEndX = -2 + Math.max(0, -legStep * 8);
      limbs.rightLegEndY = 6 + Math.max(0, legStep * 6);
    },
    draw: (ctx, emote) => {
      ctx.save();
      const timeActive = Date.now() - emote.startTime;

      // Emit floating music notes
      for (let i = 0; i < 3; i++) {
        const offset = i * 400;
        const noteAge = (timeActive + offset) % 1200;
        const progress = noteAge / 1200;

        ctx.globalAlpha = 1 - progress;

        // Float up and drift sinusoidally
        const noteX = Math.sin(progress * Math.PI * 4 + i) * 15;
        const noteY = -20 - progress * 40;

        ctx.font = `${10 + progress * 10}px sans-serif`;
        const symbol = i % 2 === 0 ? '🎵' : '🎶';

        ctx.fillText(symbol, noteX, noteY);
      }
      ctx.restore();
    }
  },
  fart: {
    duration: 2000,
    message: "{name} is farting",
    setup: (ctx, emote, c) => { },
    updateLimbs: (limbs, emote) => { },
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
    message: "{name} is dead",
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
    message: "{name} is crying",
    setup: (ctx, emote, c) => { },
    updateLimbs: (limbs, emote) => { },
    draw: (ctx, emote) => {
      ctx.save();
      // Draw eyes
      ctx.fillStyle = '#111';
      ctx.beginPath(); ctx.arc(5, -1, 1, 0, Math.PI * 2); ctx.fill();
      ctx.beginPath(); ctx.arc(5, 1, 1, 0, Math.PI * 2); ctx.fill();

      // Animated tears
      ctx.fillStyle = '#3498db'; // blue tear

      for (let i = 0; i < 6; i++) {
        const offset = i * (1000 / 6);
        const progress = ((Date.now() + offset) % 1000) / 1000;

        // Fade out as they move
        ctx.globalAlpha = 1 - Math.pow(progress, 2);
        const tearSize = 4 * (1 - progress * 0.5);

        // Spread much further back and outward
        const curX = 4 - progress * 25;
        const leftY = -2 - progress * 15;
        const rightY = 2 + progress * 15;

        ctx.beginPath(); ctx.arc(curX, leftY, tearSize, 0, Math.PI * 2); ctx.fill();
        ctx.beginPath(); ctx.arc(curX, rightY, tearSize, 0, Math.PI * 2); ctx.fill();
      }
      ctx.restore();
    }
  },
  gritty: {
    duration: 5000,
    message: "{name} is doing the gritty",
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
    draw: (ctx, emote) => { }
  },
  laugh: {
    duration: 5000,
    message: "{name} is rolling on the floor laughing",
    setup: (ctx, emote, c) => {
      const laughTime = (Date.now() - emote.startTime) / 150;
      const rock = Math.sin(laughTime) * 0.2;
      // Rotate 90 degrees to lay on the ground, plus some rocking back and forth
      ctx.rotate(Math.PI / 2 + rock);
      // Translate down slightly to appear "on the floor"
      ctx.translate(0, 10);
    },
    updateLimbs: (limbs, emote) => {
      const laughTime = (Date.now() - emote.startTime) / 100;
      const kick = Math.sin(laughTime * 2) * 4;

      // Arms clutching stomach (moved inwards towards center)
      limbs.leftArmX = 2; limbs.leftArmY = 0;
      limbs.rightArmX = 2; limbs.rightArmY = 0;

      // Legs bent and kicking erratically
      limbs.leftLegStartX = -8; limbs.leftLegStartY = -4;
      limbs.leftLegEndX = -16 + kick; limbs.leftLegEndY = -10 + kick;

      limbs.rightLegStartX = -8; limbs.rightLegStartY = 4;
      limbs.rightLegEndX = -16 - kick; limbs.rightLegEndY = 10 + kick;
    },
    draw: (ctx, emote) => {
      ctx.save();

      // Draw closed laughing eyes (^ ^)
      ctx.beginPath();
      // Left eye
      ctx.moveTo(4, -2); ctx.lineTo(5, -3); ctx.lineTo(6, -2);
      // Right eye
      ctx.moveTo(4, 2); ctx.lineTo(5, 1); ctx.lineTo(6, 2);
      ctx.strokeStyle = 'rgba(0,0,0,0.8)';
      ctx.lineWidth = 1;
      ctx.stroke();

      // BIG laughing open mouth
      ctx.beginPath();
      ctx.arc(6, 0, 2.5, 0, Math.PI * 2);
      ctx.fillStyle = '#c0392b'; // Dark red/mouth color
      ctx.fill();

      // Optional tears of joy!
      const progress = ((Date.now() - emote.startTime) % 1000) / 1000;
      ctx.fillStyle = '#3498db';
      ctx.globalAlpha = 1 - progress;
      ctx.beginPath(); ctx.arc(4, -5 - progress * 5, 1.5, 0, Math.PI * 2); ctx.fill();
      ctx.beginPath(); ctx.arc(4, 5 + progress * 5, 1.5, 0, Math.PI * 2); ctx.fill();

      ctx.restore();
    }
  },
  love: {
    duration: 5000,
    message: "{name} is in love",
    setup: (ctx, emote, c) => {
      const hover = Math.sin((Date.now() - emote.startTime) / 150) * 2;
      ctx.translate(hover, 0); // slight rhythmic bobbing
    },
    updateLimbs: (limbs, emote) => {
      // Arms clasped forward
      limbs.leftArmX = 8; limbs.leftArmY = -2;
      limbs.rightArmX = 8; limbs.rightArmY = 2;

      // Legs together, kicking back adorably
      const kick = Math.sin((Date.now() - emote.startTime) / 150) * 3;
      limbs.leftLegStartX = -2; limbs.leftLegStartY = -3;
      limbs.leftLegEndX = -4 + kick; limbs.leftLegEndY = -3;

      limbs.rightLegStartX = -2; limbs.rightLegStartY = 3;
      limbs.rightLegEndX = -4 + kick; limbs.rightLegEndY = 3;
    },
    draw: (ctx, emote) => {
      ctx.save();

      // Heart eyes
      ctx.font = '8px sans-serif';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillText('❤️', 5, -3);
      ctx.fillText('❤️', 5, 3);

      // Smiling mouth
      ctx.beginPath();
      ctx.arc(6, 0, 1.5, -Math.PI / 2, Math.PI / 2);
      ctx.strokeStyle = 'rgba(0,0,0,0.8)';
      ctx.lineWidth = 1;
      ctx.stroke();

      // Floating hearts effect
      for (let i = 0; i < 4; i++) {
        const offset = i * (2000 / 4);
        const timeActive = Date.now() - emote.startTime + offset;
        const progress = (timeActive % 2000) / 2000;

        ctx.globalAlpha = 1 - Math.pow(progress, 2);
        const heartSize = 14 * (1 - progress * 0.3);

        // Bubbling outwards and wavy
        const curX = 8 + progress * 35;
        const curY = Math.sin(progress * Math.PI * 6 + i) * 20;

        ctx.font = `${heartSize}px sans-serif`;
        ctx.fillText('❤️', curX, curY);
      }

      ctx.restore();
    }
  },
  rugby: {
    duration: 3600000, // Lasts for 1 hour, or until player moves
    message: "{name} is holding a rugby ball",
    setup: (ctx, emote, c) => { },
    updateLimbs: (limbs, emote) => {
      // Hold ball under right arm
      limbs.rightArmX = 4; limbs.rightArmY = 12; // arm tucked
    },
    draw: (ctx, emote) => {
      ctx.save();
      // Draw a white english rugby ball at the right arm position
      ctx.translate(6, 10); // move to right arm area
      ctx.rotate(Math.PI / 4); // tilt the ball

      // White ball body
      ctx.fillStyle = '#f0f0f0';
      ctx.beginPath();
      if (ctx.ellipse) {
        ctx.ellipse(0, 0, 7, 4.5, 0, 0, Math.PI * 2);
      } else {
        ctx.arc(0, 0, 6, 0, Math.PI * 2);
      }
      ctx.fill();

      // Dark outline for visibility
      ctx.strokeStyle = '#333333';
      ctx.lineWidth = 1;
      ctx.stroke();

      // Subtle seams along the length typical of a rugby ball
      ctx.strokeStyle = '#aaaaaa';
      ctx.lineWidth = 0.5;
      ctx.beginPath();
      ctx.moveTo(-7, 0);
      ctx.quadraticCurveTo(0, -2.5, 7, 0);
      ctx.stroke();

      ctx.beginPath();
      ctx.moveTo(-7, 0);
      ctx.quadraticCurveTo(0, 2.5, 7, 0);
      ctx.stroke();

      // Colored grips/patterns on the ends (like standard Gilbert balls)
      ctx.fillStyle = '#2ecc71'; // green accent
      ctx.beginPath();
      if (ctx.ellipse) {
        ctx.ellipse(-5, 0, 2, 3, 0, -Math.PI / 2, Math.PI / 2);
      }
      ctx.fill();

      ctx.beginPath();
      if (ctx.ellipse) {
        ctx.ellipse(5, 0, 2, 3, 0, Math.PI / 2, -Math.PI / 2);
      }
      ctx.fill();

      ctx.restore();
    }
  },
  sit: {
    duration: 3600000, // Lasts for 1 hour, or until player moves
    message: "{name} sat down",
    setup: (ctx, emote, c) => {
      // Translate slightly to look lower to the ground
      ctx.translate(-2, 0);
    },
    updateLimbs: (limbs, emote) => {
      // Legs spread out straight in front (thighs visible)
      limbs.leftLegStartX = 0; limbs.leftLegStartY = -6;
      limbs.leftLegEndX = 16; limbs.leftLegEndY = -6;

      limbs.rightLegStartX = 0; limbs.rightLegStartY = 6;
      limbs.rightLegEndX = 16; limbs.rightLegEndY = 6;

      // Arms resting on sides
      limbs.leftArmX = 2; limbs.leftArmY = -12;
      limbs.rightArmX = 2; limbs.rightArmY = 12;
    },
    draw: (ctx, emote) => { }
  },
  swim: {
    duration: 3600000, // 1 hour duration or until moved/canceled
    message: "{name} is swimming",
    setup: (ctx, emote, c) => {
      const swimTime = (Date.now() - emote.startTime) / 200;
      const bob = Math.sin(swimTime) * 3;

      // and bob them slightly.
      ctx.translate(0, bob);
    },
    updateLimbs: (limbs, emote) => {
      const swimTime = (Date.now() - emote.startTime) / 200;
      const stroke = Math.sin(swimTime);
      const sweep = Math.cos(swimTime);
      const kick = Math.sin(swimTime * 3) * 5;

      // Breaststroke arms sweeping back and forth
      // Forward push
      limbs.leftArmX = 14 - stroke * 8;
      limbs.leftArmY = -6 - sweep * 5;

      limbs.rightArmX = 14 - stroke * 8;
      limbs.rightArmY = 6 + sweep * 5;

      // Flutter kicks pushed further back down the body to look elongated
      limbs.leftLegStartX = -10; limbs.leftLegStartY = -4;
      limbs.leftLegEndX = -24; limbs.leftLegEndY = -4 + kick;

      limbs.rightLegStartX = -10; limbs.rightLegStartY = 4;
      limbs.rightLegEndX = -24; limbs.rightLegEndY = 4 - kick;
    },
    draw: (ctx, emote) => {
      ctx.save();
      // Draw splash particles / water ripples at the feet and hands
      const swimTime = Date.now() - emote.startTime;

      ctx.strokeStyle = 'rgba(255, 255, 255, 0.4)';
      ctx.lineWidth = 1.5;

      for (let i = 0; i < 3; i++) {
        const offset = i * 400;
        const progress = ((swimTime + offset) % 1200) / 1200;

        ctx.globalAlpha = 1 - progress;
        const rippleSize = 5 + progress * 15;

        // Feet splashes moved further back
        ctx.beginPath();
        ctx.arc(-22, 0, rippleSize, -Math.PI / 2, Math.PI / 2);
        ctx.stroke();

        // Arm splashes
        ctx.beginPath();
        ctx.arc(10, 0, rippleSize * 1.5, Math.PI / 2, Math.PI * 1.5);
        ctx.stroke();
      }
      ctx.restore();
    }
  }
};
