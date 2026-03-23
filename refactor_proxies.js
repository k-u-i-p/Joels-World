const fs = require('fs');

const files = [
  'client/public/src/characters.js',
  'client/public/src/emotes.js',
  'client/public/src/physics.js',
  'client/public/src/main.js',
  'client/public/src/network.js',
  'client/public/src/admin.js'
];

const charVars = new Set(['c', 'char', 'player', 'oldNpc', 'n', 'npc', 'prevNpc', 'hitNpc', 'activeNpc', 'serverChar', 'entity']);
const objVars = new Set(['obj', 'hitObj', 'o']);

files.forEach(f => {
  if (!fs.existsSync(f)) return;
  let text = fs.readFileSync(f, 'utf8');
  let original = text;
  
  text = text.replace(/window\.getVis\(([a-zA-Z0-9_]+)\)/g, (match, v) => {
    if (charVars.has(v)) {
      return `getCharacterProxy(${v}.id)`;
    } else if (objVars.has(v)) {
      return `getObjectProxy(${v}.id)`;
    } else {
       return `getCharacterProxy(${v}.id)`;
    }
  });

  text = text.replace(/window\.clearVis\(([a-zA-Z0-9_]+)\)/g, (match, v) => {
    if (charVars.has(v)) {
      return `clearCharacterProxy(${v}.id)`;
    } else if (objVars.has(v)) {
      return `clearObjectProxy(${v}.id)`;
    } else {
       return `clearCharacterProxy(${v}.id)`;
    }
  });
  
  if (text !== original) {
    fs.writeFileSync(f, text);
    console.log(`Updated ${f}`);
  }
});
