const fs = require('fs');

const files = [
  'client/public/src/characters.js',
  'client/public/src/emotes.js',
  'client/public/src/physics.js',
  'client/public/src/main.js',
  'client/public/src/network.js',
  'client/public/src/admin.js'
];

const vars = [
  'c', 'char', 'player', 'oldNpc', 'n', 'npc', 'prevNpc', 'hitNpc', 'entity', 'obj', 'hitObj', 'o', 'activeNpc'
];

const props = [
  'walkingAudio',
  '_startRotation'
];

const varPattern = vars.join('|');
const propPattern = props.join('|');
const regex = new RegExp(`\\b(${varPattern})\\.\\b(${propPattern})\\b`, 'g');

files.forEach(f => {
  if (!fs.existsSync(f)) {
    return;
  }
  let text = fs.readFileSync(f, 'utf8');
  let original = text;
  
  text = text.replace(regex, (match, v, p) => {
    return `window.getVis(${v}).${p}`;
  });
  
  if (text !== original) {
    fs.writeFileSync(f, text);
    console.log(`Updated ${f}`);
  }
});
console.log('Second pass complete.');
