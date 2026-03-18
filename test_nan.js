import { initMinigame, serveBall, update } from './src/tennis.js';

// Setup Mock DOM Environment
global.document = { getElementById: () => ({ style: {} }), addEventListener: () => {} };
global.window = { location: {}, innerWidth: 800, innerHeight: 600, isAdmin: true, 
  init: { npcs: [{ id: 999 }] }
};
global.camera = { x: 0, y: 0, zoom: 1 };
global.soundManager = { playBackground: () => {}, playSound: () => {} };
global.gameLoop = { registerFunction: () => {} };

// Mock canvas and characters
global.CTX = {};
global.characterManager = { 
  drawShoe: () => {}, drawHumanoidUpperBody: () => {} 
};

initMinigame();
serveBall(true);

console.log("After serveBall:");
import { state } from './src/tennis.js';
for (const key of Object.keys(state)) {
  if (typeof state[key] === 'number' && Number.isNaN(state[key])) {
    console.log(`NaN found directly in state on serve: ${key}`);
  }
}
console.log("ballVX:", state.ballVX);
console.log("ballVY:", state.ballVY);
console.log("ballCurrentVelocity:", state.ballCurrentVelocity);
console.log("ballCurrentPitchAngle:", state.ballCurrentPitchAngle);
console.log("ballOffsetX:", state.ballOffsetX);
console.log("ballY:", state.ballY);

update(0.016);
console.log("After update:");
for (const key of Object.keys(state)) {
  if (typeof state[key] === 'number' && Number.isNaN(state[key])) {
    console.log(`NaN found in state after update: ${key}`);
  }
}
